@testable import AppBundle
import Common
import Foundation
import Testing

@MainActor
@Suite(.serializedGlobally)
struct PersistedLayoutTest {
    init() {
        setUpWorkspacesForTests()
        forgetPersistedLayout()
    }

    /// The format written by the previous AeroSpace versions (macOS window ids, `[x, y]` points, enums with `_0`)
    private let snapshot = #"""
        {"bootTime":42,"focusedWorkspace":"b",
         "monitors":[{"topLeftCorner":[0,0],"visibleWorkspace":"a"}],
         "windowIds":[100,200,300,400],
         "workspaces":[
           {"name":"a","monitor":{"topLeftCorner":[0,0],"visibleWorkspace":"a"},
            "floatingWindows":[{"id":400,"pid":7,"weight":1}],"macosUnconventionalWindows":[],
            "rootTilingNode":{"layout":"accordion","orientation":{"h":{}},"weight":1,"children":[
              {"window":{"_0":{"id":100,"pid":7,"weight":2}}},
              {"container":{"_0":{"layout":"tiles","orientation":{"v":{}},"weight":1,"children":[
                {"window":{"_0":{"id":200,"pid":7,"weight":1}}}]}}}]}},
           {"name":"b","monitor":{"topLeftCorner":[0,0],"visibleWorkspace":"a"},
            "floatingWindows":[],"macosUnconventionalWindows":[],
            "rootTilingNode":{"layout":"tiles","orientation":{"h":{}},"weight":1,"children":[
              {"window":{"_0":{"id":300,"pid":8,"weight":1}}}]}}]}
        """#

    @Test func testSnapshotOfPreviousVersionIsDecoded() throws {
        let (world, focusedWorkspace) = try #require(decodePersistedLayout(Data(snapshot.utf8), expectedBootTime: 42))
        assertEquals(focusedWorkspace, "b")
        assertEquals(world.windowIds.count, 4)
        let monitor = try #require(world.monitors.singleOrNil())
        assertEquals(monitor.visibleWorkspace, "a")
        assertEquals(monitor.workspaces.map(\.name), ["a", "b"])
        let wsA = monitor.workspaces[0]
        assertEquals(wsA.rootTilingNode.layout, .accordion)
        guard case .window(let w1) = wsA.rootTilingNode.children[0] else { Issue.record("window expected"); return }
        assertEquals(w1.weight, 2)
        guard case .container(let c) = wsA.rootTilingNode.children[1] else { Issue.record("container expected"); return }
        assertEquals(c.orientation, .v)

        // The windows get the ids of the snapshot once they are detected
        assertEquals(takePersistedOpaqueWindowId(100, pid: 7), w1.id)
        assertNil(takePersistedOpaqueWindowId(100, pid: 7)) // Taken
        assertNil(takePersistedOpaqueWindowId(300, pid: 9)) // Another app reuses the id
        assertEquals(takePersistedOpaqueWindowId(400, pid: 7), wsA.floatingWindows.singleOrNil()?.id)
    }

    @Test func testSnapshotIsIgnoredAfterReboot() {
        assertNil(decodePersistedLayout(Data(snapshot.utf8), expectedBootTime: 43))
        assertNil(takePersistedOpaqueWindowId(100, pid: 7))
    }
}
