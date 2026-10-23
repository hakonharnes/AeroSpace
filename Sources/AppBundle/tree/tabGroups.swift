import AppKit
import Common

/// Native macOS tabs: several NSWindows that share one frame, of which the user sees one at a time.
/// Accessibility reports every tab as a window. https://github.com/nikitabobko/AeroSpace/issues/68
///
/// Two flavors exist:
/// - AppKit tab bar (Finder, Terminal, Skim, JetBrains): only the selected tab is on screen, the others are ordered out
///   and even disappear from the app's AX windows list.
/// - Stacked windows (Ghostty with a hidden title bar): all tabs stay on screen at the same frame, the selected one on top.
///
/// A tab group is laid out as one tile: one member (the active tab) lives in the tree, the others are parked in
/// macosPopupWindowsContainer, and every frame applied to the active member is mirrored to the siblings, so that
/// they stay stacked (and go to the corner together). When the user selects another tab, that member takes the
/// active member's place in the tree.
final class TabGroup {
    private(set) var members: [MacWindow] = []
    private(set) weak var active: MacWindow?

    @MainActor var siblings: [MacWindow] { members.filter { $0 !== active } }

    @MainActor fileprivate init(active: MacWindow) {
        self.active = active
        members = [active]
        active.tabGroup = self
    }

    @MainActor fileprivate func add(_ window: MacWindow) {
        if !members.contains(where: { $0 === window }) { members.append(window) }
        window.tabGroup = self
    }

    @MainActor fileprivate func remove(_ window: MacWindow) {
        members.removeAll { $0 === window }
        window.tabGroup = nil
        if members.count == 1, let last = members.first { // No longer a group
            last.tabGroup = nil
            members = []
        }
    }

    /// Make `window` the member that lives in the tree, in the place of the current active member
    @MainActor fileprivate func activate(_ window: MacWindow) {
        guard let active, active !== window, let data = active.unbindFromParentIfBound() else { return }
        active.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        window.lastAppliedLayoutPhysicalRect = active.lastAppliedLayoutPhysicalRect
        window.lastAppliedLayoutVirtualRect = active.lastAppliedLayoutVirtualRect
        window.isFullscreen = active.isFullscreen
        self.active = window
        window.markAsMostRecentChild()
    }
}

extension MacWindow {
    /// The window of this app that `rect` is a new tab of: a managed window at exactly the same frame. New windows of
    /// an app never appear at a pixel-identical frame to an existing one otherwise, macOS cascades them
    @MainActor static func findTabAnchor(for windowId: UInt32, app: MacApp, rect: Rect?) async throws -> MacWindow? {
        // At startup, the windows of the previous session are wherever it left them (several of them in the corner,
        // at the same position), and the persisted layout needs every window to go through the regular path
        guard config.detectNativeTabs, !isStartup, let rect, rect.isMostlyOnScreen else { return nil }
        let candidates = MacWindow.allWindows.filter { $0.macApp == app && $0.windowId != windowId && $0.isConventionalWindow }
        for candidate in candidates {
            let anchor = candidate.tabGroup?.active ?? candidate
            // Only a visible window can get a new tab. Windows hidden in the corner all share the same position
            guard anchor.isConventionalWindow, !anchor.isHiddenInCorner, anchor.visualWorkspace?.isVisible == true else { continue }
            let applied = anchor.lastAppliedLayoutPhysicalRect
            // Fast path: the exact tile that AeroSpace assigned to the anchor
            if let applied, applied.almostEquals(rect) { return anchor }
            // Floating windows and windows that weren't laid out yet (startup): ask the app
            if applied == nil || anchor.isFloating, let actual = try await anchor.getAxRect(.cancellable), actual.almostEquals(rect) {
                return anchor
            }
        }
        return nil
    }

    @MainActor var isConventionalWindow: Bool {
        switch windowParentCases {
            case .tilingContainer, .floatingWindowsContainer: true
            case .unbound, .macosMinimizedWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer, .macosPopupWindowsContainer: false
        }
    }

    /// `self` is a newly detected tab of `anchor`. The new tab is the selected one, it takes the anchor's place
    @MainActor func joinTabGroup(of anchor: MacWindow) {
        let group = anchor.tabGroup ?? TabGroup(active: anchor)
        group.add(self)
        group.activate(self)
    }

    /// Called when the window dies. If it was the active tab, a sibling takes its place in the tree and is returned
    @MainActor func leaveTabGroupOnDeath() -> MacWindow? {
        guard let group = tabGroup else { return nil }
        let wasActive = group.active === self
        let heir = group.members.first { $0 !== self }
        group.remove(self)
        guard wasActive, let heir, let data = unbindFromParentIfBound() else { return nil }
        _ = heir.unbindFromParentIfBound()
        heir.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        heir.lastAppliedLayoutPhysicalRect = lastAppliedLayoutPhysicalRect
        heir.lastAppliedLayoutVirtualRect = lastAppliedLayoutVirtualRect
        heir.tabGroup?.activateAfterDeath(heir)
        heir.markAsMostRecentChild()
        return heir
    }
}

extension TabGroup {
    @MainActor fileprivate func activateAfterDeath(_ heir: MacWindow) {
        active = heir
        heir.markAsMostRecentChild()
    }

    /// The user selected another tab (cmd-shift-], a click on the tab bar). For AppKit tab bars, the newly selected tab
    /// is the only member on screen; for stacked windows, it's the app's focused window
    @MainActor func syncActiveTab(frontmostPid: pid_t?, axFocusedWindowId: UInt32?, onScreen: Set<UInt32>) {
        guard let active, members.count > 1 else { return }
        var candidate: MacWindow? = nil
        if active.app.pid == frontmostPid, let axFocusedWindowId, let focused = members.first(where: { $0.windowId == axFocusedWindowId }) {
            candidate = focused
        } else {
            let visible = members.filter { onScreen.contains($0.windowId) }
            if visible.count == 1 { candidate = visible[0] }
        }
        if let candidate, candidate !== active { activate(candidate) }
    }

    @MainActor static var all: [TabGroup] {
        var seen: [ObjectIdentifier: TabGroup] = [:]
        for w in MacWindow.allWindows { if let g = w.tabGroup { seen[ObjectIdentifier(g)] = g } }
        return Array(seen.values)
    }
}

/// Once per refresh session: follow tab switches made by the user
@MainActor func syncActiveTabs() async throws {
    let groups = TabGroup.all
    if groups.isEmpty { return }
    let onScreen = onScreenWindowIds()
    let frontmost = NSWorkspace.shared.frontmostApplication
    var axFocused: UInt32? = nil
    if let frontmost, let app = MacApp.allAppsMap[frontmost.processIdentifier], groups.contains(where: { $0.active?.app.pid == app.pid }) {
        axFocused = try await app.getFocusedWindow(.cancellable)?.windowId
    }
    for group in groups {
        group.syncActiveTab(frontmostPid: frontmost?.processIdentifier, axFocusedWindowId: axFocused, onScreen: onScreen)
    }
}

/// The user focused a parked tab natively (cmd-shift-], tab bar click): make it the active member before the focus
/// is synced, so that it has a workspace to be focused in
@MainActor func activateTabIfParked(_ window: Window) {
    guard let window = window as? MacWindow, let group = window.tabGroup, group.active !== window else { return }
    group.activate(window)
}

@MainActor private func onScreenWindowIds() -> Set<UInt32> {
    let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [NSDictionary] ?? []
    return infos.compactMap { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value }.toSet()
}

extension TreeNode {
    @MainActor func unbindFromParentIfBound() -> BindingData? {
        parent == nil ? nil : unbindFromParent()
    }
}

extension Rect {
    /// More than half of the rect is on some monitor (windows hidden in the corner show a single pixel)
    @MainActor var isMostlyOnScreen: Bool {
        let area = width * height
        if area <= 0 { return false }
        let visible = monitorInfos.map { m -> CGFloat in
            let r = m.rect
            let w = max(0, min(maxX, r.maxX) - max(minX, r.minX)), h = max(0, min(maxY, r.maxY) - max(minY, r.minY))
            return w * h
        }.reduce(0, +)
        return visible / area > 0.5
    }

    func almostEquals(_ other: Rect, tolerance: CGFloat = 2) -> Bool {
        abs(topLeftX - other.topLeftX) <= tolerance && abs(topLeftY - other.topLeftY) <= tolerance &&
            abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
