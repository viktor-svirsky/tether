import XCTest

/// Local Network off for Tether: no device can connect, so the main screen says so, with the way to Settings.
final class LocalNetworkWarningTests: TetherUITestCase {
    func testLocalNetworkOffSaysSoWithTheWayToSettings() throws {
        launch(.localNetworkDenied)
        XCTAssertEqual(reveal(staticText("localNetwork.problem")).label,
                       "Local Network is off for Tether, so no device can connect. Turn it on in Settings.")
        XCTAssertTrue(sectionHeader("DEVICES CAN'T CONNECT").exists)
        XCTAssertEqual(reveal(element("localNetwork.open")).label, "Open Settings")
        try audit()
    }

    func testWithAccessThereIsNoWarning() {
        launch(.sharing)
        assertNowhere(element("localNetwork.problem"), element("localNetwork.open"))
    }
}
