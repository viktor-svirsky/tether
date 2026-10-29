import XCTest

/// The card at the top of the main screen: is the phone sharing, and is anyone using it.
final class StatusCardTests: TetherUITestCase {
    func testWaitingTellsWhereToTurnOnTheHotspot() {
        launch(.waiting)
        XCTAssertEqual(label(of: "status.title"), "Turn on Personal Hotspot")
        XCTAssertEqual(label(of: "status.hotspotPath"), "Settings > Personal Hotspot > Allow Others to Join")
        XCTAssertFalse(element("status.headline").exists)
        XCTAssertFalse(element("status.howToConnect").exists)
    }

    func testWaitingHidesTheSharingSections() {
        launch(.waiting)
        XCTAssertFalse(element("traffic.speeds").exists)
        XCTAssertFalse(app.staticTexts["DEVICES"].exists)
        XCTAssertTrue(reveal(element("add.qr")).exists, "it leads with the code for a device")
    }

    func testNoDevicesSaysNobodyUsesTetherYet() {
        launch(.noDevices)
        XCTAssertEqual(label(of: "status.title"), "Sharing")
        XCTAssertEqual(label(of: "status.headline"), "Hotspot is on, no device is using Tether yet")
        XCTAssertFalse(element("status.howToConnect").exists, "the code is on the main screen, so nothing to open")
    }

    /// The hotspot is on but WireGuard can't start (keys locked after a restart), so nothing is shared.
    func testLockedKeysDontSaySharing() {
        launch(.wireGuardLocked)
        XCTAssertEqual(label(of: "status.title"), "Tether can't share yet")
        XCTAssertEqual(label(of: "status.headline"), "Personal Hotspot is on, but WireGuard isn't running.")
        XCTAssertFalse(element("status.stopHint").exists)
        XCTAssertFalse(element("status.hotspotPath").exists, "the hotspot is already on")
    }

    /// A sideloaded build stops opening when its 7-day profile runs out, so the main screen says so first.
    func testAnExpiringBuildSaysToRefreshIt() {
        launch(.expiring)
        XCTAssertEqual(label(of: "app.expiry"), "Tether stops opening in 2 days. Refresh or reinstall it before then.")
    }

    func testNoExpiryWarningWithDaysToGo() {
        launch(.sharing)
        XCTAssertFalse(element("app.expiry").exists)
    }

    func testSharingCountsOnlyConnectedDevices() {
        // The iPad's tunnel is up and the MacBook's is not, so this is one device, not two.
        launch(.sharing)
        XCTAssertEqual(label(of: "status.title"), "Sharing")
        XCTAssertEqual(label(of: "status.headline"), "Sharing with 1 device")
    }

    func testSharingHasNoHowToConnectButton() {
        launch(.sharing)
        XCTAssertTrue(element("status.headline").exists)
        XCTAssertFalse(element("status.howToConnect").exists)
    }

    func testSharingSaysHowToStop() {
        launch(.sharing)
        XCTAssertEqual(label(of: "status.stopHint"), "To stop, turn off Personal Hotspot.")
        XCTAssertFalse(element("sharing.switch").exists, "no switch: the hotspot is the switch")
    }

    func testWaitingHasNoStopHint() {
        launch(.waiting)
        XCTAssertFalse(element("status.stopHint").exists)
    }
}
