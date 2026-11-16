@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct MonitorTest {
    init() { setUpWorkspacesForTests() }

    // Clamshell mode with a wide monitor -> the lid is opened and the wide monitor is disconnected. Still one
    // monitor at (0, 0), but a different one
    @Test func testMonitorReplacedAtTheSameCornerIsRefreshed() {
        let workspace = globalFocus.workspace
        let narrow = Rect(topLeftX: 0, topLeftY: 0, width: 1728, height: 1117)
        let wide = Rect(topLeftX: 0, topLeftY: 0, width: 3440, height: 1440)
        defer { gcMonitors() } // Back to the test monitor
        gcMonitors([FakeMonitorInfo(rect: wide)])
        #expect(workspace.workspaceMonitorInfo.width == 3440)
        gcMonitors([FakeMonitorInfo(rect: narrow)])
        #expect(workspace.workspaceMonitorInfo.width == 1728)
        #expect(workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps.width <= 1728)
    }
}

private struct FakeMonitorInfo: MonitorInfo {
    let rect: Rect
    var monitorAppKitNsScreenScreensId: Int { 1 }
    var name: String { "Fake" }
    var visibleRect: Rect { rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    var isMain: Bool { true }
}
