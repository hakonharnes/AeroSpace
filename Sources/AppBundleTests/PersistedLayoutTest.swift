@testable import AppBundle
import Common
import XCTest

@MainActor
final class PersistedLayoutTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testFrozenWorldSurvivesJsonRoundTrip() throws {
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

        let world = FrozenWorld(
            workspaces: Workspace.all.map { FrozenWorkspace($0) },
            monitors: monitorInfos.map(FrozenMonitor.init),
            windowIds: Workspace.all.flatMap { collectAllWindowIdsRecursive($0) }.toSet(),
            focusedWorkspace: focus.workspace.name,
            bootTime: 42,
        )
        let data = try JSONEncoder().encode(world)
        let decoded = try JSONDecoder().decode(FrozenWorld.self, from: data)

        assertEquals(decoded.bootTime, 42)
        assertEquals(decoded.focusedWorkspace, "a")
        assertEquals(decoded.windowIds, [1, 2, 3, 4, 5])
        let wsA = try XCTUnwrap(decoded.workspaces.first { $0.name == "a" })
        assertEquals(wsA.rootTilingNode.layout, .accordion)
        assertEquals(wsA.rootTilingNode.children.count, 2)
        guard case .window(let w1) = wsA.rootTilingNode.children[0] else { return XCTFail("window expected") }
        assertEquals(w1.id, 1)
        assertEquals(w1.weight, 2)
        assertEquals(w1.pid, TestApp.shared.pid)
        guard case .container(let c) = wsA.rootTilingNode.children[1] else { return XCTFail("container expected") }
        assertEquals(c.orientation, .v)
        assertEquals(c.children.count, 2)
        assertEquals(wsA.floatingWindows.map(\.id), [4])
        let wsB = try XCTUnwrap(decoded.workspaces.first { $0.name == "b" })
        assertEquals(wsB.rootTilingNode.children.count, 1)
    }

    func testOldSnapshotsWithoutNewFieldsStillDecode() throws {
        let json = #"{"workspaces":[],"monitors":[],"windowIds":[]}"#
        let decoded = try JSONDecoder().decode(FrozenWorld.self, from: Data(json.utf8))
        XCTAssertNil(decoded.bootTime)
        XCTAssertNil(decoded.focusedWorkspace)
    }
}
