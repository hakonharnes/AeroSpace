import AppKit
import Common

@MainActor
private var activeRefreshTask: Task<(), any Error>? = nil

@MainActor
func scheduleCancellableCompleteRefreshSession(
    _ event: RefreshSessionEvent,
) {
    activeRefreshTask?.cancel()
    activeRefreshTask = Task.startUnstructured { @MainActor in
        try checkCancellation()
        await runHeavyCompleteRefreshSession(
            event,
            assumeCancellable: true,
        )
    }
}

@MainActor
func runHeavyCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    assumeCancellable: Bool,
    layoutWorkspaces shouldLayoutWorkspaces: Bool = true,
) async {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    if !TrayMenuModel.shared.isEnabled { return }
    let res = await Result {
        try await $refreshSessionEvent.withValue(event) {
            let snapshot = NativeFocusSnapshot.current
            let nativeFocused = try await getNativeFocusedWindow(.cancellable)
            if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, .cancellable) }
            let deferredNativeFocus = updateFocusCache(nativeFocused, deferJumpToInvisibleWorkspace: true, snapshot)

            // Don't make the user wait for the slowest app before showing the result. The newly focused window is
            // already registered, and closed windows can be detected without asking the apps. The passes below only
            // fix what's left (frames that don't change are not re-applied, so extra passes are cheap)
            garbageCollectWindowsMissingInWindowServer()
            if shouldLayoutWorkspaces { try await layoutWorkspaces() }

            await refreshModel_nonCancellable()
            let treeChanged = try await refresh(deferredNativeFocus: deferredNativeFocus, layoutEagerly: shouldLayoutWorkspaces)
            if deferredNativeFocus != nil { await checkOnFocusChangedCallbacks_nonCancellable() }
            if shouldLayoutWorkspaces && treeChanged { try await layoutWorkspaces() }
            gcMonitors()

            updateTrayText()
            SecureInputPanel.shared.refresh()
            try await normalizeLayoutReason()
            if shouldLayoutWorkspaces { try await layoutWorkspaces() }
        }
    }
    switch res {
        case .success(()): break
        case .failure(let err as CancellationError): check(assumeCancellable, "Non cancellable refresh session was canceled: \(err) (\(type(of: err)))")
        case .failure(let err): die("Illegal error: \(err)")
    }
}

@MainActor
func runLightSession<T>(
    _ event: RefreshSessionEvent,
    _: RunSessionGuard,
    isReadOnly: Bool = false,
    body: @MainActor () async throws -> T,
) async throws -> T {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    if !isReadOnly { // Read-only sessions don't schedule a new complete refresh. Don't cancel the active one
        activeRefreshTask?.cancel() // Give priority to runSession
        activeRefreshTask = nil
    }
    return try await $refreshSessionEvent.withValue(event) {
        let focusBeforeSync = focus
        if !isNativeFocusKnownToBeInSync() {
            let snapshot = NativeFocusSnapshot.current
            let nativeFocused = try await getNativeFocusedWindow(.cancellable)
            if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, .cancellable) }
            // Queries don't garbage collect dead windows. Leave jumps to invisible workspaces to the complete refresh
            // session that is scheduled by the event that changed the native focus. See updateFocusCache
            if updateFocusCache(nativeFocused, deferJumpToInvisibleWorkspace: isReadOnly, snapshot) != nil {
                forgetLastKnownNativeFocusedWindow()
            }
        }
        let focusBefore = focus.windowOrNil

        await refreshModel_nonCancellable()
        let result = try await body()
        await refreshModel_nonCancellable()

        let focusAfter = focus.windowOrNil

        updateTrayText()
        SecureInputPanel.shared.refresh()
        // Queries (list-windows, list-workspaces, etc.) don't change anything. Status bars call them a lot,
        // don't re-layout all the windows and don't trigger a complete refresh session on every call
        // https://github.com/nikitabobko/AeroSpace/issues/104
        if isReadOnly && focus == focusBeforeSync { return result }
        if !event.isFocusFollowsMouse { try await layoutWorkspaces() }
        if focusBefore != focusAfter {
            focusAfter?.nativeFocus() // syncFocusToMacOs
        }
        if !event.isFocusFollowsMouse { scheduleCancellableCompleteRefreshSession(event) }
        return result
    }
}

struct RunSessionGuard: Sendable {
    @MainActor
    static var isServerEnabled: RunSessionGuard? { TrayMenuModel.shared.isEnabled ? forceRun : nil }
    @MainActor
    static func isServerEnabled(orIsEnableCommand command: (any Command)?) -> RunSessionGuard? {
        command is EnableCommand ? .forceRun : .isServerEnabled
    }
    @MainActor
    static func checkServerIsEnabledOrDie(
        file: StaticString = #fileID,
        line: Int = #line,
        column: Int = #column,
        function: String = #function,
    ) -> RunSessionGuard {
        .isServerEnabled ?? dieT("server is disabled", file: file, line: line, column: column, function: function)
    }
    static let forceRun = RunSessionGuard()
    private init() {}
}

@MainActor
func refreshModel_nonCancellable() async {
    if refreshSessionEvent?.isFocusFollowsMouse == true {
        await checkOnFocusChangedCallbacks_nonCancellable()
    } else {
        Workspace.garbageCollectUnusedWorkspaces()
        await checkOnFocusChangedCallbacks_nonCancellable()
        normalizeContainers()
    }
}

@MainActor
private func garbageCollectWindowsMissingInWindowServer() {
    let windows = MacWindow.allWindows
    let existing = windows.map(\.windowId).toSet().filterExistingInWindowServer()
    for window in windows where !existing.contains(window.windowId) {
        window.garbageCollect(skipClosedWindowsCache: false)
    }
}

/// Returns true if windows were garbage collected or registered
@MainActor
private func refresh(deferredNativeFocus: Window?, layoutEagerly: Bool) async throws -> Bool {
    // Garbage collect terminated apps and windows before working with all windows
    let mapping: [MacApp: [UInt32]]
    var treeChanged = false
    do {
        mapping = try await MacApp.refreshAllAndGetAliveWindowIds(frontmostAppBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) { app, windowIds in
            // Closed windows: re-layout as soon as the app answers, don't wait for slower apps
            let alive = windowIds.toSet().filterExistingInWindowServer()
            var isAnyWindowClosed = false
            for window in MacWindow.allWindows where window.macApp == app && !alive.contains(window.windowId) {
                window.garbageCollect(skipClosedWindowsCache: false)
                isAnyWindowClosed = true
            }
            if isAnyWindowClosed {
                treeChanged = true
                if layoutEagerly { try await layoutWorkspaces() }
            }
        }
    } catch {
        if deferredNativeFocus != nil { forgetLastKnownNativeFocusedWindow() } // Let the next session retry the sync
        throw error
    }
    // Ghost windows: on recent macOS versions, the AX element of a closed window might keep answering its window id.
    // A window that doesn't exist in WindowServer is dead for sure (minimized windows, windows of hidden apps, and
    // windows on other macOS Spaces do exist there). https://github.com/nikitabobko/AeroSpace/issues/1615
    let aliveWindowIds = mapping.values.flatMap(id).toSet().filterExistingInWindowServer()

    let windowsCountBefore = MacWindow.allWindowsMap.count
    for window in MacWindow.allWindows {
        if !aliveWindowIds.contains(window.windowId) {
            window.garbageCollect(skipClosedWindowsCache: false)
            treeChanged = true
        }
    }
    // Sync the native focus only after dead windows are garbage collected. See updateFocusCache
    if let deferredNativeFocus { applyDeferredNativeFocus(deferredNativeFocus) }
    for (app, windowIds) in mapping {
        for windowId in windowIds {
            try await MacWindow.getOrRegister(windowId: windowId, macApp: app)
        }
    }

    // Garbage collect workspaces after apps, because workspaces contain apps.
    Workspace.garbageCollectUnusedWorkspaces()
    return treeChanged || MacWindow.allWindowsMap.count != windowsCountBefore || deferredNativeFocus != nil
}

func refreshObs(_: AXObserver, _: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    nativeFocusEpoch.bump()
    Task.startUnstructured { @MainActor in
        if !TrayMenuModel.shared.isEnabled { return }
        scheduleCancellableCompleteRefreshSession(.ax(notif))
    }
}

enum OptimalHideCorner {
    case bottomLeftCorner, bottomRightCorner
}

@MainActor
private func layoutWorkspaces() async throws {
    if !TrayMenuModel.shared.isEnabled {
        for workspace in Workspace.all {
            workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
            try await workspace.layoutWorkspace() // Unhide tiling windows from corner
        }
        return
    }
    let monitors = monitorInfos
    var monitorToOptimalHideCorner: [CGPoint: OptimalHideCorner] = [:]
    for monitor in monitors {
        let xOff = monitor.width * 0.1
        let yOff = monitor.height * 0.1
        // brc = bottomRightCorner
        let brc1 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: -yOff)
        let brc2 = monitor.rect.bottomRightCorner + CGPoint(x: -xOff, y: 2)
        let brc3 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: 2)

        // blc = bottomLeftCorner
        let blc1 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: -yOff)
        let blc2 = monitor.rect.bottomLeftCorner + CGPoint(x: xOff, y: 2)
        let blc3 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: 2)

        func contains(_ monitor: MonitorInfo, _ point: CGPoint) -> Int { monitor.rect.contains(point) ? 1 : 0 }
        let important = 10

        let corner: OptimalHideCorner =
            monitors.sumOfInt { contains($0, blc1) + contains($0, blc2) + important * contains($0, blc3) } <
            monitors.sumOfInt { contains($0, brc1) + contains($0, brc2) + important * contains($0, brc3) }
            ? .bottomLeftCorner
            : .bottomRightCorner
        monitorToOptimalHideCorner[monitor.rect.topLeftCorner] = corner
    }

    // to reduce flicker, first unhide visible workspaces, then hide invisible ones
    var appsOfUnhiddenWindows: Set<MacApp> = []
    for monitor in monitors {
        let workspace = monitor.activeWorkspace
        for window in workspace.allLeafWindowsRecursive {
            let window = window as! MacWindow // todo as!
            if window.isHiddenInCorner { appsOfUnhiddenWindows.insert(window.macApp) }
            window.unhideFromCorner()
        }
        try await workspace.layoutWorkspace()
    }
    // Don't hide the windows of the previous workspace until the windows of the new workspace are in place.
    // Otherwise, the wallpaper flickers when the apps of the new workspace are slower at answering AX requests
    // https://github.com/nikitabobko/AeroSpace/issues/1305
    await waitForSubmittedAxJobs(appsOfUnhiddenWindows, timeout: .milliseconds(150))
    // Hide concurrently. Windows that are not hidden yet need an AX round trip to remember their position.
    // Doing it one by one makes the windows disappear one after another
    let toHide = HideRequests(Workspace.all.filter { !$0.isVisible }.flatMap { workspace in
        let corner = monitorToOptimalHideCorner[workspace.workspaceMonitor.rect.topLeftCorner] ?? .bottomRightCorner
        return workspace.allLeafWindowsRecursive.map { ($0 as! MacWindow, corner) } // todo as!
    })
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in toHide.requests.indices {
            group.addTask { @Sendable @MainActor in
                let (window, corner) = toHide.requests[index]
                try await window.hideInCorner(corner)
            }
        }
        try await group.waitForAll()
    }
}

@MainActor
private func waitForSubmittedAxJobs(_ apps: Set<MacApp>, timeout: Duration) async {
    if apps.isEmpty { return }
    let latch = CountDownLatch(apps.count)
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        latch.onDone = { cont.resume() }
        for app in apps {
            app.submitBarrier { Task.startUnstructured { @MainActor in latch.countDown() } }
        }
        Task.startUnstructured { @MainActor in
            try? await Task.sleep(for: timeout)
            latch.release()
        }
    }
}

@MainActor
private final class CountDownLatch {
    private var count: Int
    var onDone: (() -> ())? = nil
    init(_ count: Int) { self.count = count }
    func countDown() {
        count -= 1
        if count <= 0 { release() }
    }
    func release() {
        let onDone = onDone
        self.onDone = nil
        onDone?()
    }
}

/// Main actor isolated, hence Sendable. Allows passing windows to the task group children
@MainActor
private final class HideRequests {
    let requests: [(MacWindow, OptimalHideCorner)]
    init(_ requests: [(MacWindow, OptimalHideCorner)]) { self.requests = requests }
}

@MainActor
private func normalizeContainers() {
    // Can't do it only for visible workspace because most of the commands support --window-id and --workspace flags
    for workspace in Workspace.all {
        workspace.normalizeContainers()
    }
}
