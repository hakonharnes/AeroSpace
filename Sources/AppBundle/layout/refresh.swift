import AppKit
import Common

@MainActor
private var activeRefreshTask: Task<(), any Error>? = nil

/// - Parameter targetPid: the app that caused the event. Only this app is refreshed (new windows, closed windows,
///   minimized/fullscreen state), the rest of the apps are not asked anything. macOS events are not reliable, that's
///   why a complete refresh of all the apps follows after a short delay (safety net), once the events calm down
@MainActor
func scheduleCancellableCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    targetPid: pid_t? = nil,
) {
    activeRefreshTask?.cancel()
    let targetApp = targetPid.flatMap { MacApp.allAppsMap[$0] }
    if targetApp != nil {
        scheduleSafetyNetRefresh()
    } else {
        safetyNetRefreshTask?.cancel() // The complete refresh makes it redundant
        safetyNetRefreshTask = nil
    }
    activeRefreshTask = Task.startUnstructured { @MainActor in
        try checkCancellation()
        await runHeavyCompleteRefreshSession(
            event,
            assumeCancellable: true,
            targetApp: targetApp,
        )
    }
}

@MainActor
private var safetyNetRefreshTask: Task<(), any Error>? = nil

@MainActor
private func scheduleSafetyNetRefresh() {
    safetyNetRefreshTask?.cancel()
    safetyNetRefreshTask = Task.startUnstructured { @MainActor in
        try await Task.sleep(for: .seconds(1))
        try checkCancellation()
        safetyNetRefreshTask = nil
        if TrayMenuModel.shared.isEnabled {
            scheduleCancellableCompleteRefreshSession(.safetyNetRefresh)
        }
    }
}

@MainActor
func runHeavyCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    assumeCancellable: Bool,
    layoutWorkspaces shouldLayoutWorkspaces: Bool = true,
    targetApp: MacApp? = nil,
) async {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    if !TrayMenuModel.shared.isEnabled { return }
    let res = await Result {
        try await $refreshSessionEvent.withValue(event) {
            var deferredNativeFocus: Window? = nil
            // Asking the frontmost app for its focused window is an AX round trip that the whole session waits for.
            // Skip it if no event that could change the native focus happened since the last sync
            if !isNativeFocusKnownToBeInSync() {
                let snapshot = NativeFocusSnapshot.current
                let nativeFocused = try await getNativeFocusedWindow(.cancellable)
                if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, .cancellable) }
                deferredNativeFocus = updateFocusCache(nativeFocused, deferJumpToInvisibleWorkspace: true, snapshot)
            }

            // Don't make the user wait for the slowest app before showing the result. The newly focused window is
            // already registered, and closed windows can be detected without asking the apps. The passes below only
            // fix what's left (frames that don't change are not re-applied, so extra passes are cheap)
            garbageCollectWindowsMissingInWindowServer()
            if shouldLayoutWorkspaces { try await layoutWorkspaces() }

            await refreshModel_nonCancellable()
            let treeChanged = if let targetApp {
                try await refresh(onlyApp: targetApp, deferredNativeFocus: deferredNativeFocus)
            } else {
                try await refresh(deferredNativeFocus: deferredNativeFocus, layoutEagerly: shouldLayoutWorkspaces)
            }
            if deferredNativeFocus != nil { await checkOnFocusChangedCallbacks_nonCancellable() }
            if shouldLayoutWorkspaces && treeChanged { try await layoutWorkspaces() }
            gcMonitors()

            updateTrayText()
            SecureInputPanel.shared.refresh()
            try await normalizeLayoutReason(onlyApp: targetApp)
            try await syncActiveTabs()
            if shouldLayoutWorkspaces { try await layoutWorkspaces() }
            persistLayoutIfNeeded()
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
        let focusBeforeSync = globalFocus
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
        let focusBefore = globalFocus.windowOrNil

        await refreshModel_nonCancellable()
        let result = try await body()
        await refreshModel_nonCancellable()

        let focusAfter = globalFocus.windowOrNil

        updateTrayText()
        SecureInputPanel.shared.refresh()
        // Queries (list-windows, list-workspaces, etc.) don't change anything. Status bars call them a lot,
        // don't re-layout all the windows and don't trigger a complete refresh session on every call
        // https://github.com/nikitabobko/AeroSpace/issues/104
        if isReadOnly && globalFocus == focusBeforeSync { return result }
        if !event.isFocusFollowsMouse { try await layoutWorkspaces() }
        if focusBefore != focusAfter {
            focusAfter?.nativeFocus() // syncFocusToMacOs
        }
        persistLayoutIfNeeded()
        if !event.isFocusFollowsMouse { scheduleCancellableCompleteRefreshSession(event) }
        return result
    }
}

enum RunSessionGuard: Sendable {
    case forceRun

    @MainActor
    static var isServerEnabled: Self? { TrayMenuModel.shared.isEnabled ? forceRun : nil }
    @MainActor
    static func isServerEnabled(orIsEnableCommand command: (any Command)?) -> Self? {
        command is EnableCommand ? .forceRun : .isServerEnabled
    }
    @MainActor
    static func checkServerIsEnabledOrDie(fileId: MyFileId = #myFileId) -> Self {
        .isServerEnabled ?? dieT("server is disabled", fileId: fileId)
    }
}

@MainActor
func refreshModel_nonCancellable() async {
    if refreshSessionEvent?.isFocusFollowsMouse == true {
        await checkOnFocusChangedCallbacks_nonCancellable()
    } else {
        Workspace.garbageCollectUnusedWorkspaces()
        Workspace.forceAssignWorkspaces()
        await checkOnFocusChangedCallbacks_nonCancellable()
        normalizeContainers()
    }
}

@MainActor
private func garbageCollectWindowsMissingInWindowServer() {
    let windows = MacWindow.allWindows.compactMap { w in w.nativeWindowId.map { (w, $0) } }
    let existing = windows.map(\.1).toSet().filterExistingInWindowServer()
    let missing = windows.filter { !existing.contains($0.1) }
    if missing.isEmpty { return }
    let windowServer = WindowServerSnapshot.current()
    // A closed native tab hands its window id over to the next tab. Leave it to the regular refresh
    for (window, _) in missing where !window.mightBeActiveNativeTab(windowServer) {
        window.lifeStatus = .dead
        window.garbageCollect(skipClosedWindowsCache: false)
    }
}

/// Refreshes the windows of a single app. Returns true if windows were garbage collected or registered
@MainActor
private func refresh(onlyApp app: MacApp, deferredNativeFocus: Window?) async throws -> Bool {
    let windowsCountBefore = MacWindow.allWindowsMap.count
    var treeChanged = false
    let windows: [OpaqueWindowId: WindowLifeStatus]
    do {
        windows = try await app.refreshAndGetAliveWindowIds(frontmostAppBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    } catch {
        if deferredNativeFocus != nil { forgetLastKnownNativeFocusedWindow() } // Let the next session retry the sync
        throw error
    }
    for window in MacWindow.allWindows where window.macApp == app && windows[window.windowId] == nil {
        window.lifeStatus = .dead
        window.garbageCollect(skipClosedWindowsCache: false)
        treeChanged = true
    }
    if let deferredNativeFocus { applyDeferredNativeFocus(deferredNativeFocus) }
    for (windowId, lifeStatus) in windows {
        try await MacWindow.getOrRegister(windowId: windowId, macApp: app).lifeStatus = lifeStatus
    }
    Workspace.garbageCollectUnusedWorkspaces()
    return treeChanged || MacWindow.allWindowsMap.count != windowsCountBefore || deferredNativeFocus != nil
}

/// Returns true if windows were garbage collected or registered
@MainActor
private func refresh(deferredNativeFocus: Window?, layoutEagerly: Bool) async throws -> Bool {
    // Garbage collect terminated apps and windows before working with all windows
    let mapping: [MacApp: [OpaqueWindowId: WindowLifeStatus]]
    var treeChanged = false
    do {
        mapping = try await MacApp.refreshAllAndGetAliveWindowIds(frontmostAppBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) { app, windows in
            // Closed windows: re-layout as soon as the app answers, don't wait for slower apps
            var isAnyWindowClosed = false
            for window in MacWindow.allWindows where window.macApp == app && windows[window.windowId] == nil {
                window.lifeStatus = .dead
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
    let aliveWindowIds = mapping.values.flatMap(\.keys).toSet()

    let windowsCountBefore = MacWindow.allWindowsMap.count
    for window in MacWindow.allWindows {
        if !aliveWindowIds.contains(window.windowId) {
            window.lifeStatus = .dead
            window.garbageCollect(skipClosedWindowsCache: false)
            treeChanged = true
        }
    }
    // Sync the native focus only after dead windows are garbage collected. See updateFocusCache
    if let deferredNativeFocus { applyDeferredNativeFocus(deferredNativeFocus) }
    for (app, windows) in mapping {
        for (windowId, lifeStatus) in windows {
            try await MacWindow.getOrRegister(windowId: windowId, macApp: app).lifeStatus = lifeStatus
        }
    }

    // Garbage collect workspaces after apps, because workspaces contain apps.
    Workspace.garbageCollectUnusedWorkspaces()
    return treeChanged || MacWindow.allWindowsMap.count != windowsCountBefore || deferredNativeFocus != nil
}

func refreshObs(_: AXObserver, ax: AXUIElement, notif: CFString, refcon: UnsafeMutableRawPointer?) {
    let notif = notif as String
    let pid = axTaskLocalAppThreadToken?.pid // The observer is called on the AX thread of the app
    nativeFocusEpoch.bump()
    // The notification says which window is destroyed, no need to ask the app for its windows to find out.
    // The element can't be asked anything anymore (that's the confirmation that it's dead), the id comes from refcon
    let destroyedWindowId: UInt32? = notif == kAXUIElementDestroyedNotification && ax.containingNativeWindowId() == nil
        ? unsafe refconToWindowId(refcon)
        : nil
    Task.startUnstructured { @MainActor in
        if !TrayMenuModel.shared.isEnabled { return }
        // WindowServer still shows the window for a while (it fades out), so it can't confirm the death. If an app
        // ever recreates the AX element of a live window, the window is re-detected by the refresh session below and
        // closedWindowsCache puts it back where it was
        // A closed native tab hands its window id over to the next tab (see nonidempotentNativeTabSwapHeuristic),
        // the regular refresh session sorts that out
        if let destroyedWindowId, let pid, let window = Window.get(byNativeId: destroyedWindowId, pid: pid) as? MacWindow,
           !window.mightBeActiveNativeTab(.current())
        {
            window.lifeStatus = .dead
            window.garbageCollect(skipClosedWindowsCache: false)
        }
        scheduleCancellableCompleteRefreshSession(.ax(notif), targetPid: pid)
    }
}

enum OptimalHideCorner {
    case bottomLeftCorner, bottomRightCorner
}

@MainActor
private func layoutWorkspaces() async throws {
    if !TrayMenuModel.shared.isEnabled {
        unhideAllAppsHiddenByAeroSpace()
        for workspace in Workspace.all {
            workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
            try await workspace.layoutWorkspace() // Unhide tiling windows from corner
        }
        return
    }
    let monitors = globalUnsortedMonitorInfos
    var monitorToOptimalHideCorner: [Point: OptimalHideCorner] = [:]
    for monitor in monitors {
        let xOff = monitor.width * 0.1
        let yOff = monitor.height * 0.1
        // brc = bottomRightCorner
        let brc1 = monitor.rect.bottomRightCorner + Point(x: 2, y: -yOff)
        let brc2 = monitor.rect.bottomRightCorner + Point(x: -xOff, y: 2)
        let brc3 = monitor.rect.bottomRightCorner + Point(x: 2, y: 2)

        // blc = bottomLeftCorner
        let blc1 = monitor.rect.bottomLeftCorner + Point(x: -2, y: -yOff)
        let blc2 = monitor.rect.bottomLeftCorner + Point(x: xOff, y: 2)
        let blc3 = monitor.rect.bottomLeftCorner + Point(x: -2, y: 2)

        func contains(_ monitor: MonitorInfo, _ point: Point) -> Int { monitor.rect.contains(point) ? 1 : 0 }
        let important = 10

        let corner: OptimalHideCorner =
            monitors.sumOfInt { contains($0, blc1) + contains($0, blc2) + important * contains($0, blc3) } <
            monitors.sumOfInt { contains($0, brc1) + contains($0, brc2) + important * contains($0, brc3) }
            ? .bottomLeftCorner
            : .bottomRightCorner
        monitorToOptimalHideCorner[monitor.rect.topLeftCorner] = corner
    }

    // to reduce flicker, first unhide visible workspaces, then hide invisible ones
    var appsOfUnhiddenWindows: Set<MacApp> = unhideAppsOfVisibleWorkspaces() // ~2ms per app, handled by the system
    for monitor in monitors {
        let workspace = monitor.visibleWorkspace
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
    let invisibleWindows = Workspace.all.filter { !$0.isVisible }.flatMap { $0.allLeafWindowsRecursive.map { $0 as! MacWindow } } // todo as!
    let cornerWindows = hideAppsOfInvisibleWorkspaces(invisibleWindows)
    let toHide = HideRequests(cornerWindows.map { window in
        let corner = window.nodeWorkspace.flatMap { monitorToOptimalHideCorner[$0.workspaceMonitorInfo.rect.topLeftCorner] } ?? .bottomRightCorner
        return (window, corner)
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
