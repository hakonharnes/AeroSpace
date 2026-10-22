@MainActor
func normalizeLayoutReason() async throws {
    let workspaceWindows = Workspace.all.map { ($0, $0.allLeafWindowsRecursive) }
    let minimizedWindows = macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self)
    // Query all the windows concurrently. Windows of different apps are served by different AX threads,
    // querying them one by one makes every refresh session as slow as the sum of all apps' AX latencies
    // https://github.com/nikitabobko/AeroSpace/issues/1615
    let states = try await fetchMacosNativeStates(workspaceWindows.flatMap { $0.1 } + minimizedWindows)
    for (workspace, windows) in workspaceWindows {
        try await _normalizeLayoutReason(workspace: workspace, windows: windows, states)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: minimizedWindows, states)
    try await validateStillPopups()
}

private struct MacosNativeState {
    let isFullscreen: Bool
    let isMinimized: Bool
}

/// Main actor isolated, hence Sendable. Allows passing windows to the task group children
@MainActor
private final class WindowsRef {
    let windows: [Window]
    init(_ windows: [Window]) { self.windows = windows }
}

@MainActor
private func fetchMacosNativeStates(_ windows: [Window]) async throws -> [UInt32: MacosNativeState] {
    let ref = WindowsRef(windows)
    return try await withThrowingTaskGroup(of: (UInt32, MacosNativeState).self) { group in
        for index in ref.windows.indices {
            group.addTask { @Sendable @MainActor in
                let window = ref.windows[index]
                let isFullscreen = try await window.isMacosFullscreen(.cancellable)
                let isMinimized = try await (!isFullscreen).andAsync { @MainActor @Sendable in try await window.isMacosMinimized(.cancellable) }
                return (window.windowId, MacosNativeState(isFullscreen: isFullscreen, isMinimized: isMinimized))
            }
        }
        var result: [UInt32: MacosNativeState] = [:]
        for try await (windowId, state) in group {
            result[windowId] = state
        }
        return result
    }
}

@MainActor
private func validateStillPopups() async throws {
    for node in macosPopupWindowsContainer.children {
        let popup = (node as! MacWindow)
        let windowLevel = getWindowLevel(for: popup.windowId)
        if try await popup.isWindowHeuristic(windowLevel, .cancellable) {
            try await popup.relayoutWindow(on: focus.workspace, .cancellable)
            await runOnWindowDetected(ifConventional: popup)
        }
    }
}

@MainActor
private func _normalizeLayoutReason(workspace: Workspace, windows: [Window], _ states: [UInt32: MacosNativeState]) async throws {
    for window in windows {
        guard let state = states[window.windowId] else { continue }
        let isMacosFullscreen = state.isFullscreen
        let isMacosMinimized = state.isMinimized
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.macAppUnsafe.nsApp.isHidden
        switch window.layoutReason {
            case .standard:
                guard let parent = window.parent else { continue }
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

@MainActor
func exitMacOsNativeUnconventionalState(
    window: Window,
    prevParentKind: NonLeafTreeNodeKind,
    workspace: Workspace,
    _ cm: CancellationMode,
) async throws {
    window.layoutReason = .standard
    switch prevParentKind {
        case .floatingWindowsContainer:
            window.bindAsFloatingWindow(to: workspace)
        case .workspace:
            break // Not possible
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, cm, forceTile: true)
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace, cm)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace, cm)
    }
}
