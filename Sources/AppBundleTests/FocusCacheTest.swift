@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct FocusCacheTest {
    init() { setUpWorkspacesForTests() }

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

    @Test func testNativeFocusIsSyncedToAeroSpace() {
        let (_, _, b, window2) = setUpTwoWorkspaces()
        _ = updateFocusCache(window2)
        assertTrue(globalFocus.windowOrNil === window2)
        assertEquals(globalFocus.workspace, b)
    }

    // https://github.com/nikitabobko/AeroSpace/issues/1097
    @Test func testMacosFocusingNextWindowAfterWindowCloseDoesntSwitchWorkspace() {
        let (a, window1, _, window2) = setUpTwoWorkspaces()
        let window3 = TestWindow.new(id: 3, parent: a.rootTilingContainer)
        assertTrue(window3.focusWindow())

        // window3 is closed. macOS focuses the next window of the app which happens to be on the invisible workspace
        window3.unbindFromParent()
        armFocusStealGuard(a)
        _ = updateFocusCache(window2)

        assertEquals(globalFocus.workspace, a)
        assertTrue(globalFocus.windowOrNil === window1)
        assertTrue(TestApp.shared.focusedWindow === window1) // The native focus is given back
    }

    @Test func testFocusStealGuardDoesntBlockFocusOfVisibleWorkspaces() {
        let (a, window1, _, _) = setUpTwoWorkspaces()
        let window3 = TestWindow.new(id: 3, parent: a.rootTilingContainer)
        armFocusStealGuard(a)
        _ = updateFocusCache(window3)
        assertTrue(globalFocus.windowOrNil === window3)
        _ = updateFocusCache(window1)
        assertTrue(globalFocus.windowOrNil === window1)
    }

    @Test func testDeferredJumpToInvisibleWorkspaceIsAppliedIfNoWindowWasClosed() {
        let (a, _, b, window2) = setUpTwoWorkspaces()
        let deferred = updateFocusCache(window2, deferJumpToInvisibleWorkspace: true)
        assertTrue(deferred === window2)
        assertEquals(globalFocus.workspace, a) // Not yet

        applyDeferredNativeFocus(window2)
        assertEquals(globalFocus.workspace, b)
    }

    @Test func testDeferredJumpToInvisibleWorkspaceIsDroppedIfWindowWasClosed() {
        let (a, window1, _, window2) = setUpTwoWorkspaces()
        let deferred = updateFocusCache(window2, deferJumpToInvisibleWorkspace: true)
        assertTrue(deferred === window2)

        armFocusStealGuard(a) // Garbage collection of a window on the focused workspace
        applyDeferredNativeFocus(window2)
        assertEquals(globalFocus.workspace, a)
        assertTrue(globalFocus.windowOrNil === window1)
    }

    @Test func testStaleNativeFocusIsIgnoredWhileFocusRequestIsPending() {
        let (a, window1, b, window2) = setUpTwoWorkspaces()
        _ = updateFocusCache(window2)
        assertEquals(globalFocus.workspace, b)

        // `workspace a` command: AeroSpace focuses window1 and asks macOS to do the same
        assertTrue(window1.focusWindow())
        onNativeFocusRequested(window1.windowId)

        // macOS hasn't processed the request yet and still reports window2
        _ = updateFocusCache(window2)
        assertEquals(globalFocus.workspace, a)

        // macOS has processed the request, but the previously focused app reports itself one more time
        _ = updateFocusCache(window1)
        _ = updateFocusCache(window2)
        assertEquals(globalFocus.workspace, a)
        assertTrue(globalFocus.windowOrNil === window1)
    }

    @Test func testTerminationOfActiveAppDoesntSwitchWorkspace() {
        let (a, window1, _, window2) = setUpTwoWorkspaces()
        onAppActivated(1234) // An app without windows on the focused workspace
        onAppTerminated(1234)
        _ = updateFocusCache(window2) // macOS activates some other app
        assertEquals(globalFocus.workspace, a)
        assertTrue(globalFocus.windowOrNil === window1)
    }

    @Test func testTerminationOfInactiveAppDoesntArmTheGuard() {
        let (_, _, b, window2) = setUpTwoWorkspaces()
        onAppActivated(1234)
        onAppTerminated(4321)
        _ = updateFocusCache(window2)
        assertEquals(globalFocus.workspace, b)
    }

    @Test func testMacosActivatesNextAppBeforeReportingTermination() {
        let (a, window1, _, window2) = setUpTwoWorkspaces()
        onAppActivated(1234)
        onAppActivated(4321) // macOS activates the next app first
        onAppTerminated(1234) // and only then reports the termination of the previously active app
        _ = updateFocusCache(window2)
        assertEquals(globalFocus.workspace, a)
        assertTrue(globalFocus.windowOrNil === window1)
    }
}

@MainActor
@Suite(.serializedGlobally)
struct SetFrameOrderTest {
    @Test func testExitFullscreenOfTheRightWindowMovesFirst() {
        let fullscreen = Rect(topLeftX: 0, topLeftY: 0, width: 2000, height: 1000)
        let rightHalf = Rect(topLeftX: 1000, topLeftY: 0, width: 1000, height: 1000)
        assertTrue(shouldMoveBeforeResize(fullscreen, rightHalf))
    }

    @Test func testEnterFullscreenOfTheRightWindowResizesFirst() {
        let fullscreen = Rect(topLeftX: 0, topLeftY: 0, width: 2000, height: 1000)
        let rightHalf = Rect(topLeftX: 1000, topLeftY: 0, width: 1000, height: 1000)
        assertFalse(shouldMoveBeforeResize(rightHalf, fullscreen))
    }

    @Test func testMoveToAnotherMonitorKeepsTheDefaultOrder() {
        let left = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 1000)
        let otherMonitor = Rect(topLeftX: 3000, topLeftY: 0, width: 500, height: 500)
        assertFalse(shouldMoveBeforeResize(left, otherMonitor))
    }
}
