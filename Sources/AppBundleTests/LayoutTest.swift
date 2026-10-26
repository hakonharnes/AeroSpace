@testable import AppBundle
import Common
import XCTest

@MainActor
final class LayoutTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    /// Weights are absolute pixels of the monitor the layout was made on. On a smaller monitor they must shrink
    /// proportionally, not by an equal amount per window (which makes small windows negative)
    func testTilesKeepProportionsOnSmallerMonitor() async throws {
        let workspace = Workspace.get(byName: "a")
        let root = workspace.rootTilingContainer
        let big = TestWindow.new(id: 1, parent: root)
        let small = TestWindow.new(id: 2, parent: root)
        // A layout made on a 3440px wide monitor: 3000 + 440
        big.setWeight(.h, 3000)
        small.setWeight(.h, 440)
        try await workspace.layoutWorkspace() // The test monitor is much narrower

        let bigRectOrNil = try await big.getAxRect(.nonCancellable)
        let smallRectOrNil = try await small.getAxRect(.nonCancellable)
        let bigRect = try XCTUnwrap(bigRectOrNil)
        let smallRect = try XCTUnwrap(smallRectOrNil)
        XCTAssertGreaterThan(smallRect.width, 10, "the small window must stay visible")
        XCTAssertGreaterThan(bigRect.width, smallRect.width)
        assertEquals((bigRect.width / smallRect.width).rounded(), (3000.0 / 440.0).rounded())
        let available = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps.width
        assertEquals((bigRect.width + smallRect.width).rounded(), available.rounded()) // No gaps in the test config
    }

    func testNewWindowGetsAFairShare() async throws {
        let workspace = Workspace.get(byName: "a")
        let root = workspace.rootTilingContainer
        let w1 = TestWindow.new(id: 1, parent: root)
        let w2 = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        w1.setWeight(.h, w1.getWeight(.h) * 1.5)
        w2.setWeight(.h, w2.getWeight(.h) * 0.5)
        try await workspace.layoutWorkspace()
        let w3 = TestWindow.new(id: 3, parent: root, adaptiveWeight: WEIGHT_AUTO) // The average of the siblings
        try await workspace.layoutWorkspace()
        for w in [w1, w2, w3] {
            let rOrNil = try await w.getAxRect(.nonCancellable)
            let r = try XCTUnwrap(rOrNil)
            XCTAssertGreaterThan(r.width, 10)
        }
    }
}
