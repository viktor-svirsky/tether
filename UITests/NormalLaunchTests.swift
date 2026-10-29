import XCTest

/// A launch without `-TetherDemo` must run the real app. The simulator has no Personal Hotspot,
/// so what a person sees there is the waiting screen. The demo `waiting` scenario looks the same on
/// the main screen, so these tests also check that no demo argument leaks into a normal launch.
final class NormalLaunchTests: TetherUITestCase {
    func testWaitsForPersonalHotspotOnTheSimulator() {
        launch(nil)
        XCTAssertEqual(label(of: "status.title"), "Turn on Personal Hotspot")
        XCTAssertEqual(label(of: "status.hotspotPath"), "Settings > Personal Hotspot > Allow Others to Join")
        assertNowhere(element("status.headline"), element("traffic.speeds"))
    }

    func testUnrelatedArgumentsDoNotTurnDemoOn() {
        launch(nil, arguments: ["-SomethingElse", "sharing"])
        XCTAssertEqual(label(of: "status.title"), "Turn on Personal Hotspot")
    }
}
