import AppKit
import Common

/// Hiding whole apps instead of moving their windows to a corner.
///
/// Moving a window is an AX request that the owning app processes on its main thread, so a workspace switch is as
/// slow as the slowest app on either workspace. Unhiding an app (`NSRunningApplication.unhide`) is handled by the
/// system: ~2ms, all windows of the app appear in the same frame, even if the app's main thread is busy. Hiding
/// takes longer (the app processes it), but it happens after the new workspace is already shown.
///
/// Only apps whose every managed window is on an invisible workspace can be hidden. Apps with windows on several
/// workspaces keep using the corner.

/// pids hidden by AeroSpace (as opposed to apps hidden by the user with cmd-h)
@MainActor private var appsHiddenByAeroSpace: Set<pid_t> = []

@MainActor func isAppHiddenByAeroSpace(_ pid: pid_t) -> Bool { appsHiddenByAeroSpace.contains(pid) }

/// macOS unhid the app (cmd-tab, Dock click) or the app terminated
@MainActor func forgetAppHiddenByAeroSpace(_ pid: pid_t) { appsHiddenByAeroSpace.remove(pid) }

/// Called before laying out visible workspaces. Returns the apps that were unhidden
@MainActor func unhideAppsOfVisibleWorkspaces() -> Set<MacApp> {
    var unhidden: Set<MacApp> = []
    for pid in appsHiddenByAeroSpace {
        guard let app = MacApp.allAppsMap[pid] else { appsHiddenByAeroSpace.remove(pid); continue }
        if !app.nsApp.isHidden { // The user unhid it in the meantime
            appsHiddenByAeroSpace.remove(pid)
            continue
        }
        let hasVisibleWindow = MacWindow.allWindows.contains { $0.macApp == app && $0.visualWorkspace?.isVisible == true }
        if hasVisibleWindow {
            app.nsApp.unhide()
            appsHiddenByAeroSpace.remove(pid)
            unhidden.insert(app)
        }
    }
    return unhidden
}

/// The frontmost app can't be hidden right away: macOS would activate some other app in response, which races with
/// the focus request AeroSpace is about to make. Its windows are left in place for a moment (instead of being moved
/// to the corner, which the app would have to process) and the app is hidden by the next refresh session, once the
/// new workspace's app is frontmost. If that doesn't happen within this time, the windows go to the corner
@MainActor private var frontmostHideDeferredSince: (pid: pid_t, since: Date)? = nil
private let frontmostHideDeferral: TimeInterval = 0.3

/// Hides the apps whose every window is on an invisible workspace. Returns the windows that still need the corner
@MainActor func hideAppsOfInvisibleWorkspaces(_ invisibleWindows: [MacWindow]) -> [MacWindow] {
    if !config.hideAppsOnInvisibleWorkspaces { return invisibleWindows }
    let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    var remaining: [MacWindow] = []
    let byApp = Dictionary(grouping: invisibleWindows, by: { $0.macApp })
    for (app, windows) in byApp {
        let allInvisible = app.pid != myPid &&
            MacWindow.allWindows.filter { $0.macApp == app }.allSatisfy { $0.visualWorkspace?.isVisible == false }
        if !allInvisible {
            remaining += windows
        } else if app.pid == frontmostPid {
            // Another app is about to become frontmost (the focused window belongs to it): wait for that
            let anotherAppGetsFocus = focus.windowOrNil.map { $0.app.pid != app.pid } ?? false
            if let d = frontmostHideDeferredSince, d.pid == app.pid, d.since.distance(to: .now) > frontmostHideDeferral {
                remaining += windows // Took too long, give up on hiding for now
            } else if anotherAppGetsFocus {
                if frontmostHideDeferredSince?.pid != app.pid { frontmostHideDeferredSince = (app.pid, .now) }
            } else {
                remaining += windows
            }
        } else if !appsHiddenByAeroSpace.contains(app.pid) {
            app.nsApp.hide()
            appsHiddenByAeroSpace.insert(app.pid)
        }
    }
    if let d = frontmostHideDeferredSince, d.pid != frontmostPid { frontmostHideDeferredSince = nil }
    return remaining
}

/// AeroSpace quits or gets disabled: give the apps back
@MainActor func unhideAllAppsHiddenByAeroSpace() {
    for pid in appsHiddenByAeroSpace {
        MacApp.allAppsMap[pid]?.nsApp.unhide()
    }
    appsHiddenByAeroSpace = []
}
