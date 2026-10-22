@testable import AppBundle
import Common
import XCTest

@MainActor
final class FocusCacheTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func setUpTwoWorkspaces() -> (a: Workspace, window1: Window, b: Workspace, window2: Window) {
        let a = Workspace.get(byName: "a")
        let window1 = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        let b = Workspace.get(byName: "b")
        let window2 = TestWindow.new(id: 2, parent: b.rootTilingContainer)
        assertTrue(window1.focusWindow())
        _ = updateFocusCache(window1)
        assertTrue(a.isVisible)
        assertFalse(b.isVisible)
        return (a, window1, b, window2)
    }

    func testNativeFocusIsSyncedToAeroSpace() {
        let (_, _, b, window2) = setUpTwoWorkspaces()
        _ = updateFocusCache(window2)
        assertTrue(focus.windowOrNil === window2)
        assertEquals(focus.workspace, b)
    }

    // https://github.com/nikitabobko/AeroSpace/issues/1097
    func testMacosFocusingNextWindowAfterWindowCloseDoesntSwitchWorkspace() {
        let (a, window1, _, window2) = setUpTwoWorkspaces()
        let window3 = TestWindow.new(id: 3, parent: a.rootTilingContainer)
        assertTrue(window3.focusWindow())

        // window3 is closed. macOS focuses the next window of the app which happens to be on the invisible workspace
        window3.unbindFromParent()
        armFocusStealGuard(a)
        _ = updateFocusCache(window2)

        assertEquals(focus.workspace, a)
        assertTrue(focus.windowOrNil === window1)
        assertTrue(TestApp.shared.focusedWindow === window1) // The native focus is given back
    }

    func testFocusStealGuardDoesntBlockFocusOfVisibleWorkspaces() {
        let (a, window1, _, _) = setUpTwoWorkspaces()
        let window3 = TestWindow.new(id: 3, parent: a.rootTilingContainer)
        armFocusStealGuard(a)
        _ = updateFocusCache(window3)
        assertTrue(focus.windowOrNil === window3)
        _ = updateFocusCache(window1)
        assertTrue(focus.windowOrNil === window1)
    }

    func testDeferredJumpToInvisibleWorkspaceIsAppliedIfNoWindowWasClosed() {
        let (a, _, b, window2) = setUpTwoWorkspaces()
        let deferred = updateFocusCache(window2, deferJumpToInvisibleWorkspace: true)
        assertTrue(deferred === window2)
        assertEquals(focus.workspace, a) // Not yet

        applyDeferredNativeFocus(window2)
        assertEquals(focus.workspace, b)
    }

    func testDeferredJumpToInvisibleWorkspaceIsDroppedIfWindowWasClosed() {
        let (a, window1, _, window2) = setUpTwoWorkspaces()
        let deferred = updateFocusCache(window2, deferJumpToInvisibleWorkspace: true)
        assertTrue(deferred === window2)

        armFocusStealGuard(a) // Garbage collection of a window on the focused workspace
        applyDeferredNativeFocus(window2)
        assertEquals(focus.workspace, a)
        assertTrue(focus.windowOrNil === window1)
    }

    func testStaleNativeFocusIsIgnoredWhileFocusRequestIsPending() {
        let (a, window1, b, window2) = setUpTwoWorkspaces()
        _ = updateFocusCache(window2)
        assertEquals(focus.workspace, b)

        // `workspace a` command: AeroSpace focuses window1 and asks macOS to do the same
        assertTrue(window1.focusWindow())
        onNativeFocusRequested(window1.windowId)

        // macOS hasn't processed the request yet and still reports window2
        _ = updateFocusCache(window2)
        assertEquals(focus.workspace, a)

        // macOS has processed the request, but the previously focused app reports itself one more time
        _ = updateFocusCache(window1)
        _ = updateFocusCache(window2)
        assertEquals(focus.workspace, a)
        assertTrue(focus.windowOrNil === window1)
    }
}
