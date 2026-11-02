import XCTest

/// Local Network off for Tether: no device can connect, so the status card says so, with the way to Settings.
final class LocalNetworkWarningTests: TetherUITestCase {
    func testLocalNetworkOffTurnsTheStatusCardIntoTheWarning() throws {
        launch(.localNetworkDenied)
        XCTAssertEqual(label(of: "status.title"), "Devices can't connect", "not Sharing: nothing reaches the devices")
        XCTAssertEqual(label(of: "status.headline"), "Local Network is off for Tether")
        XCTAssertEqual(label(of: "localNetwork.problem"), "iOS blocks Tether's answers to your devices until it's on.")
        XCTAssertEqual(element("localNetwork.open").label, "Turn on in Settings")
        assertNowhere(element("traffic.speeds"), element("status.stopHint"))
        try audit()
    }

    func testWithAccessThereIsNoWarning() {
        launch(.sharing)
        XCTAssertEqual(label(of: "status.title"), "Sharing")
        assertNowhere(element("localNetwork.problem"), element("localNetwork.open"))
    }
}
