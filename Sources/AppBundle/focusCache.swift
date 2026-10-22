import AppKit
import Common

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
///
/// - Parameter deferJumpToInvisibleWorkspace: if the native focus moved to a window on an invisible workspace, don't
///   sync it right away, but return the window. The caller must pass it to ``applyDeferredNativeFocus`` once dead
///   windows are garbage collected. By that time, we know whether the focus change was caused by macOS reacting to
///   a closed window. https://github.com/nikitabobko/AeroSpace/issues/1097
@MainActor func updateFocusCache(_ nativeFocused: Window?, deferJumpToInvisibleWorkspace: Bool = false, _ snapshot: NativeFocusSnapshot? = nil) -> Window? {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return nil
    }
    if isStaleWhileNativeFocusRequestIsPending(nativeFocused) {
        return nil
    }
    var deferred: Window? = nil
    defer {
        syncedNativeFocus = deferred == nil ? snapshot : nil
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        if let nativeFocused, deferJumpToInvisibleWorkspace, nativeFocused.isOnInvisibleWorkspace {
            deferred = nativeFocused
        } else {
            syncNativeFocus(nativeFocused)
        }
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId
    return deferred
}

@MainActor func forgetLastKnownNativeFocusedWindow() {
    lastKnownNativeFocusedWindowId = nil
    syncedNativeFocus = nil
}

// Asking the frontmost app for its focused window is an AX round trip. It's the first thing every command does, and
// the command can't proceed until the app answers. Slow apps (Electron, etc) make every hotkey feel laggy.
// If no event that might change the native focus has happened since the last sync, the answer is already known.

/// Bumped on every event that might change the native focus. Bumped from AX threads too
let nativeFocusEpoch = NativeFocusEpoch()

final class NativeFocusEpoch: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var _value = 0
    var value: Int { lock.withLock { unsafe _value } }
    func bump() { lock.withLock { unsafe _value += 1 } }
}

struct NativeFocusSnapshot: Equatable {
    let epoch: Int
    let frontmostAppPid: pid_t?

    @MainActor static var current: NativeFocusSnapshot {
        NativeFocusSnapshot(epoch: nativeFocusEpoch.value, frontmostAppPid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }
}

@MainActor private var syncedNativeFocus: NativeFocusSnapshot? = nil

@MainActor func isNativeFocusKnownToBeInSync() -> Bool {
    guard !isUnitTest, let syncedNativeFocus else { return false }
    return pendingNativeFocusRequest == nil && syncedNativeFocus == .current
}

@MainActor func applyDeferredNativeFocus(_ window: Window) {
    if window.isOnInvisibleWorkspace { // Re-check. GC could change the tree
        syncNativeFocus(window)
    }
}

@MainActor private func syncNativeFocus(_ nativeFocused: Window?) {
    guard let nativeFocused else { return }
    if isFocusStolenByMacosAfterWindowClose(nativeFocused) {
        // Keep the AeroSpace focus. Give the focus back to the window that AeroSpace considers focused
        focus.windowOrNil?.nativeFocus()
    } else {
        _ = nativeFocused.focusWindow()
    }
}

extension Window {
    @MainActor fileprivate var isOnInvisibleWorkspace: Bool {
        visualWorkspace.map { !$0.isVisible } ?? false
    }
}

// When a window is closed or an app quits, macOS focuses "the next" window on its own (another window of the same
// app, or a window of the previously active app). Most of the time, that window is on an invisible workspace,
// and syncing the native focus to AeroSpace would make AeroSpace jump to that workspace.
// https://github.com/nikitabobko/AeroSpace/issues/1097
@MainActor private var focusStealGuard: (workspaceName: String, deadline: Date)? = nil
private let focusStealGuardDuration: TimeInterval = 1

/// Call it when a window on the focused `workspace` dies (closed, the app quits)
@MainActor func armFocusStealGuard(_ workspace: Workspace) {
    focusStealGuard = (workspace.name, .now + focusStealGuardDuration)
}

@MainActor private func isFocusStolenByMacosAfterWindowClose(_ nativeFocused: Window) -> Bool {
    guard let g = focusStealGuard else { return false }
    if Date.now > g.deadline {
        focusStealGuard = nil
        return false
    }
    // Only guard against jumps from the workspace where the window was closed to invisible workspaces.
    // Focusing a window on a visible workspace (e.g. a click on a window on a different monitor) is legit
    return focus.workspace.name == g.workspaceName && nativeFocused.isOnInvisibleWorkspace
}

/// pid -> name of the workspace that was focused when AeroSpace asked the app to quit
@MainActor private var appsQuitByAeroSpace: [pid_t: String] = [:]

@MainActor func rememberAppQuitByAeroSpace(_ pid: pid_t) {
    appsQuitByAeroSpace[pid] = focus.workspace.name
}

@MainActor private var lastActivatedAppPid: pid_t? = nil
@MainActor private var prevActivatedAppPid: pid_t? = nil
@MainActor private var lastActivationDate: Date = .distantPast

@MainActor func onAppActivated(_ pid: pid_t) {
    if pid == lastActivatedAppPid { return }
    prevActivatedAppPid = lastActivatedAppPid
    lastActivatedAppPid = pid
    lastActivationDate = .now
}

/// macOS might activate the next app before it reports the termination of the active app
@MainActor private func wasActiveRightBeforeTermination(_ pid: pid_t) -> Bool {
    pid == lastActivatedAppPid || pid == prevActivatedAppPid && lastActivationDate.distance(to: .now) < 1
}

/// macOS activates the next app only after the app is actually terminated, which can happen much later than
/// AeroSpace asked the app to quit. That's why the guard is armed (again) on termination.
/// When the active app terminates, macOS activates some other app, even if the terminated app didn't have windows
/// on the focused workspace
@MainActor func onAppTerminated(_ pid: pid_t) {
    let focusedWorkspace = focus.workspace
    let quitFrom = appsQuitByAeroSpace.removeValue(forKey: pid)
    if quitFrom == focusedWorkspace.name || wasActiveRightBeforeTermination(pid) ||
        MacWindow.allWindows.contains(where: { $0.app.pid == pid && $0.nodeWorkspace == focusedWorkspace })
    {
        armFocusStealGuard(focusedWorkspace)
    }
}

// AeroSpace asks macOS to focus a window (e.g. after `workspace` command), but macOS and the apps process the request
// asynchronously. For a short period of time, macOS might still report the previously focused window (sometimes
// even after it has already reported the requested window). Syncing that stale focus back to AeroSpace makes
// AeroSpace jump back to the previous workspace and then jump forward again. Status bars that call `aerospace list-*`
// on every workspace change hit it all the time.
@MainActor private var pendingNativeFocusRequest: (windowId: UInt32, deadline: Date)? = nil
@MainActor private var pendingNativeFocusRecheck: Task<(), Never>? = nil
private let nativeFocusRequestTimeout: TimeInterval = 0.5
private let nativeFocusRequestSettlePeriod: TimeInterval = 0.3

@MainActor func onNativeFocusRequested(_ windowId: UInt32) {
    pendingNativeFocusRequest = (windowId, .now + nativeFocusRequestTimeout)
    nativeFocusEpoch.bump()
}

@MainActor private func isStaleWhileNativeFocusRequestIsPending(_ nativeFocused: Window?) -> Bool {
    guard let request = pendingNativeFocusRequest else { return false }
    if Date.now >= request.deadline {
        pendingNativeFocusRequest = nil
        return false
    }
    guard let nativeFocused else { return false }
    if nativeFocused.windowId == request.windowId {
        // macOS has processed the request. But the previously focused app may still report itself for a moment
        pendingNativeFocusRequest = (request.windowId, max(request.deadline, .now + nativeFocusRequestSettlePeriod))
        return false
    }
    // Focusing a window on a visible workspace (e.g. a click) is never a stale report of the previous workspace
    if !nativeFocused.isOnInvisibleWorkspace { return false }
    // The focus change might be real (e.g. cmd-tab right after the workspace switch). Don't lose it, re-check later
    if pendingNativeFocusRecheck == nil && !isUnitTest {
        pendingNativeFocusRecheck = Task.startUnstructured { @MainActor in
            while let deadline = pendingNativeFocusRequest?.deadline, deadline > .now {
                try? await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow + 0.01))
            }
            pendingNativeFocusRecheck = nil
            if TrayMenuModel.shared.isEnabled {
                scheduleCancellableCompleteRefreshSession(.nativeFocusRequestExpired)
            }
        }
    }
    return true
}

@MainActor func resetNativeFocusGuardsForTests() {
    lastKnownNativeFocusedWindowId = nil
    syncedNativeFocus = nil
    focusStealGuard = nil
    appsQuitByAeroSpace = [:]
    lastActivatedAppPid = nil
    prevActivatedAppPid = nil
    lastActivationDate = .distantPast
    pendingNativeFocusRequest = nil
    pendingNativeFocusRecheck?.cancel()
    pendingNativeFocusRecheck = nil
}
