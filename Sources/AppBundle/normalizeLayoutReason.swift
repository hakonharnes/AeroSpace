import Common


@MainActor func normalizeLayoutReason(onlyApp: MacApp? = nil) async throws {
    func ofTheApp(_ window: Window) -> Bool { onlyApp == nil || window.app.pid == onlyApp?.pid }
    let workspaceWindows = Workspace.all.map { ($0, $0.allLeafWindowsRecursive.filter(ofTheApp)) }
    let minimizedWindows = macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self).filter(ofTheApp)
    // Query all the windows concurrently. Windows of different apps are served by different AX threads,
    // querying them workspace by workspace makes every refresh session slower
    // https://github.com/nikitabobko/AeroSpace/issues/1615
    let allWindows = workspaceWindows.flatMap { $0.1 } + minimizedWindows
    let allStates = try await allWindows.mapConcurrently { try await $0.getMacosWindowNativeState(.cancellable) }
    var states: [OpaqueWindowId: MacosWindowNativeState] = [:]
    for (window, state) in zip(allWindows, allStates) {
        states[window.windowId] = state
    }
    for (workspace, windows) in workspaceWindows {
        try await _normalizeLayoutReason(workspace: workspace, windows: windows, states)
    }
    try await _normalizeLayoutReason(workspace: globalFocus.workspace, windows: minimizedWindows, states)
    try await validateStillPopups(ofTheApp)
}

@MainActor private func validateStillPopups(_ filter: (Window) -> Bool) async throws {
    for node in macosPopupWindowsContainer.children where filter(node as! MacWindow) && (node as! MacWindow).tabGroup == nil {
        let popup = (node as! MacWindow)
        let windowLevel = try await popup.getWindowLevel(.cancellable)
        if try await popup.isWindowHeuristic(windowLevel, .cancellable) {
            try await popup.relayoutWindow(on: globalFocus.workspace, .cancellable)
            await runOnWindowDetected(ifConventional: popup)
        }
    }
}

@MainActor private func _normalizeLayoutReason(workspace: Workspace, windows: [Window], _ states: [OpaqueWindowId: MacosWindowNativeState]) async throws {
    for window in windows {
        guard let state = states[window.windowId] else { continue }
        let isMacosFullscreen = state == .nativeFullscreen
        let isMacosMinimized = state == .nativeMinimized
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.macAppUnsafe.nsApp.isHidden &&
            !isAppHiddenByAeroSpace(window.app.pid)
        switch window.layoutReason {
            case .standard:
                guard let parent = window.windowParentCases else { continue }
                switch true {
                    case isMacosFullscreen:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    case isMacosMinimized:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                    case isMacosWindowOfHiddenApp:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    default: break
                }
            case .macos(let prevParentKind):
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp {
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
                }
        }
    }
}

@MainActor func exitMacOsNativeUnconventionalState(
    window: Window,
    prevParentKind: WindowParentCases.Kind,
    workspace: Workspace,
    _ cm: CancellationMode,
) async throws {
    window.layoutReason = .standard
    switch prevParentKind {
        case .floatingWindowsContainer:
            window.bindAsFloatingWindow(to: workspace)
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, cm, forceTile: true)
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace, cm)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace, cm)
    }
}
