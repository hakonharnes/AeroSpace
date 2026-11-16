@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct LayoutTest {
    init() { setUpWorkspacesForTests() }

    /// Weights are absolute pixels of the monitor the layout was made on. On a smaller monitor they must shrink
    /// proportionally, not by an equal amount per window (which makes small windows negative)
    @Test func testTilesKeepProportionsOnSmallerMonitor() async throws {
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
        let bigRect = try #require(bigRectOrNil)
        let smallRect = try #require(smallRectOrNil)
        #expect(smallRect.width > 10, "the small window must stay visible")
        #expect(bigRect.width > smallRect.width)
        assertEquals((bigRect.width / smallRect.width).rounded(), (3000.0 / 440.0).rounded())
        let available = workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps.width
        assertEquals((bigRect.width + smallRect.width).rounded(), available.rounded()) // No gaps in the test config
    }

    @Test func testNewWindowGetsAFairShare() async throws {
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
            let r = try #require(rOrNil)
            #expect(r.width > 10)
        }
    }
}
