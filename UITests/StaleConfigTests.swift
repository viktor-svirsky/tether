import XCTest

/// A device keeps trying to connect with a config that no longer works (#89): the main screen says
/// so, and so does Add a device's last step, where someone adding it again would be.
final class StaleConfigTests: TetherUITestCase {
    func testTheMainScreenSaysADeviceHasAConfigThatNoLongerWorks() throws {
        launch(.staleConfig)
        XCTAssertEqual(reveal(element("stale.warning")).label,
                       "A device is trying to connect with a config that no longer works. Delete its tunnel in WireGuard and add it again.")
        XCTAssertEqual(label(of: "status.title"), "Sharing", "the devices that work still do")
        try audit()
    }

    func testAddADevicesLastStepSaysSoToo() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            launch(.staleConfig)
            openAddDevice()
            XCTAssertEqual(reveal(element("add.stale")).label,
                           "A device is trying to connect with a config that no longer works. If it's this one, delete its tunnel in WireGuard and give it the config again.")
            assertNowhere(text(containing: "This ticks off by itself"))
            try audit()
            app.terminate()
        }
    }

    func testNoKnockNoWarning() {
        launch(.sharing)
        assertNowhere(element("stale.warning"))
        openAddDevice()
        assertNowhere(element("add.stale"))
    }
}
