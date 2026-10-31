import XCTest

/// The card at the top of the main screen: is the phone sharing, and is anyone using it.
final class StatusCardTests: TetherUITestCase {
    func testWaitingTellsWhereToTurnOnTheHotspot() {
        launch(.waiting)
        XCTAssertEqual(label(of: "status.title"), "Turn on Personal Hotspot")
        XCTAssertEqual(label(of: "status.hotspotPath"), "Settings > Personal Hotspot > Allow Others to Join")
        assertNowhere(element("status.headline"), element("status.howToConnect"))
    }

    func testWaitingHidesTheSharingSections() {
        launch(.waiting)
        assertNowhere(element("traffic.speeds"), sectionHeader("DEVICES"))
        XCTAssertTrue(reveal(element("add.qr")).exists, "it leads with the code for a device")
    }

    func testNoDevicesSaysNobodyUsesTetherYet() {
        launch(.noDevices)
        XCTAssertEqual(label(of: "status.title"), "Sharing")
        XCTAssertEqual(label(of: "status.headline"), "No device is using Tether yet")
        assertNowhere(element("status.howToConnect"), message: "the code is on the main screen, so nothing to open")
    }

    /// The hotspot is on but WireGuard can't start (keys locked after a restart), so nothing is shared.
    func testLockedKeysDontSaySharing() {
        launch(.wireGuardLocked)
        XCTAssertEqual(label(of: "status.title"), "Tether can't share yet")
        XCTAssertEqual(label(of: "status.headline"), "Personal Hotspot is on, but WireGuard isn't running.")
        assertNowhere(element("status.stopHint"), element("status.hotspotPath"), message: "the hotspot is already on")
    }

    /// A sideloaded build stops opening when its 7-day profile runs out, so the main screen says so first.
    func testAnExpiringBuildSaysToRefreshIt() {
        launch(.expiring)
        XCTAssertEqual(label(of: "app.expiry"), "Tether stops opening in 2 days. Refresh or reinstall it before then.")
    }

    func testNoExpiryWarningWithDaysToGo() {
        launch(.sharing)
        assertNowhere(element("app.expiry"))
    }

    func testSharingCountsOnlyConnectedDevices() {
        // The iPad's tunnel is up and the Windows PC's is not, so this is one device, not two.
        launch(.sharing)
        XCTAssertEqual(label(of: "status.title"), "Sharing")
        XCTAssertEqual(label(of: "status.headline"), "1 device connected")
    }

    func testSharingHasNoHowToConnectButton() {
        launch(.sharing)
        XCTAssertTrue(element("status.headline").exists)
        assertNowhere(element("status.howToConnect"))
    }

    func testSharingSaysHowToStop() {
        launch(.sharing)
        XCTAssertEqual(label(of: "status.stopHint"), "To stop, turn off Personal Hotspot.")
        assertNowhere(element("sharing.switch"), message: "no switch: the hotspot is the switch")
    }

    func testWaitingHasNoStopHint() {
        launch(.waiting)
        assertNowhere(element("status.stopHint"))
    }
}
