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

    /// Write, then read: the windows get their places back, and the file stays readable by the previous versions
    @Test func testLayoutSurvivesWriteAndRead() throws {
        let a = Workspace.get(byName: "a")
        a.rootTilingContainer.layout = .accordion
        let window1 = TestWindow.new(id: 1, parent: a.rootTilingContainer, adaptiveWeight: 2)
        let nested = TilingContainer(parent: a.rootTilingContainer, adaptiveWeight: 1, .v, .tiles, index: INDEX_BIND_LAST)
        TestWindow.new(id: 2, parent: nested)
        TestWindow.new(id: 3, parent: nested)
        TestWindow.new(id: 4, parent: a.floatingWindowsContainer)
        let b = Workspace.get(byName: "b")
        TestWindow.new(id: 5, parent: b.rootTilingContainer)
        assertTrue(window1.focusWindow())

        // macOS window id = 100 + AeroSpace window id. Window 3 can't be persisted (e.g. its app has just quit)
        let data = try #require(encodePersistedLayout(bootTime: 42) { id in id.rawId == 3 ? nil : (UInt32(100 + id.rawId), 7) })

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        assertEquals((json["windowIds"] as? [UInt32])?.sorted(), [101, 102, 104, 105]) // Required by the previous versions

        let (world, focusedWorkspace) = try #require(decodePersistedLayout(data, expectedBootTime: 42))
        assertEquals(focusedWorkspace, "a")
        assertEquals(world.windowIds.count, 4)
        let workspaces = world.monitors.flatMap(\.workspaces)
        let wsA = try #require(workspaces.first { $0.name == "a" })
        assertEquals(wsA.rootTilingNode.layout, .accordion)
        guard case .window(let w1) = wsA.rootTilingNode.children[0] else { Issue.record("window expected"); return }
        assertEquals(w1.weight, 2)
        guard case .container(let c) = wsA.rootTilingNode.children[1] else { Issue.record("container expected"); return }
        assertEquals(c.orientation, .v)
        assertEquals(c.children.count, 1) // Window 3 is dropped
        assertEquals(takePersistedOpaqueWindowId(101, pid: 7), w1.id)
        assertEquals(takePersistedOpaqueWindowId(104, pid: 7), wsA.floatingWindows.singleOrNil()?.id)
        let wsB = try #require(workspaces.first { $0.name == "b" })
        assertEquals(wsB.rootTilingNode.children.count, 1)
    }

    @Test func testSnapshotIsIgnoredAfterReboot() {
        assertNil(decodePersistedLayout(Data(snapshot.utf8), expectedBootTime: 43))
        assertNil(takePersistedOpaqueWindowId(100, pid: 7))
    }
}
