import XCTest

/// The card at the top of the main screen: is the phone sharing, and is anyone using it.
final class StatusCardTests: TetherUITestCase {
    func testWaitingExplainsTheHotspotMayBeOffOrEmpty() {
        launch(.waiting)
        XCTAssertEqual(label(of: "status.title"), Copy.waitingForDevice)
        XCTAssertEqual(label(of: "status.hotspotHint"), "Turn on Personal Hotspot, then join it from the other device. Tether starts when the first device joins.")
        XCTAssertEqual(label(of: "status.hotspotPath"), Copy.hotspotPath)
        assertNowhere(element("status.headline"))
    }

    func testWaitingHidesTheSharingSections() {
        launch(.waiting)
        assertNowhere(element("traffic.speeds"), element("traffic.history"), sectionHeader("DEVICES"))
        XCTAssertTrue(reveal(element("add.open")).exists, "it leads with adding a device")
    }

    func testSharingShowsSpeedHistoryForBothDirections() {
        launch(.sharing)
        let history = element("traffic.history")
        XCTAssertTrue(history.exists)
        XCTAssertEqual(history.label, "Speed history, last 30 seconds")
        XCTAssertEqual(history.value as? String, "Peak download 3.2 Mbit/s, peak upload 400 kbit/s")
    }

    func testNoDevicesSaysNobodyUsesTetherYet() {
        launch(.noDevices)
        XCTAssertEqual(label(of: "status.title"), "Sharing")
        XCTAssertEqual(label(of: "status.headline"), Copy.noDeviceYet)
    }

    /// The hotspot is on but WireGuard can't start (keys locked after a restart), so nothing is shared.
    func testLockedKeysDontSaySharing() {
        launch(.wireGuardLocked)
        XCTAssertEqual(label(of: "status.title"), "Tether can't share yet")
        XCTAssertEqual(label(of: "status.headline"), "Personal Hotspot is on, but WireGuard isn't running.")
        assertNowhere(element("status.stopHint"), element("status.hotspotPath"), element("status.hotspotHint"), message: "a device has joined the hotspot")
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

    func testSharingSaysHowToStop() {
        launch(.sharing)
        XCTAssertEqual(label(of: "status.stopHint"), "To stop, turn off Personal Hotspot.")
        assertNowhere(element("status.hotspotHint"), element("status.hotspotPath"))
        assertNowhere(element("sharing.switch"), message: "no switch: the hotspot is the switch")
    }

    func testWaitingHasNoStopHint() {
        launch(.waiting)
        assertNowhere(element("status.stopHint"))
    }
}
