import XCTest

/// Local Network off for Tether: no device can connect, so the status card says so, with the way to Settings.
/// So does Add a device, since its sheet covers the card while a device is being set up.
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

    /// The last step is where a device waits to connect, so that's where it says why it never will.
    func testLocalNetworkOffShowsInAddADevicesLastStep() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            launch(.localNetworkDenied)
            openAddDevice()
            XCTAssertEqual(reveal(element("add.localNetwork.title")).label, "Local Network is off for Tether")
            XCTAssertEqual(label(of: "add.localNetwork.problem"), "iOS blocks Tether's answers to your devices until it's on.")
            XCTAssertEqual(reveal(element("add.localNetwork.open")).label, "Turn on in Settings")
            assertNowhere(text(containing: "This ticks off by itself"), message: "it won't, until Local Network is on")
            try audit()
            app.terminate()
        }
    }

    func testWithAccessThereIsNoWarning() {
        launch(.sharing)
        XCTAssertEqual(label(of: "status.title"), "Sharing")
        assertNowhere(element("localNetwork.problem"), element("localNetwork.open"))
        openAddDevice()
        reveal(element("add.step3"))
        XCTAssertTrue(text(containing: "This ticks off by itself when it connects.").exists)
        assertNowhere(element("add.localNetwork.title"), element("add.localNetwork.open"))
    }
}
