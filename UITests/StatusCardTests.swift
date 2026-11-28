import XCTest

/// The card at the top of the main screen: is the phone sharing, and is anyone using it.
final class StatusCardTests: TetherUITestCase {
    func testWaitingExplainsTheHotspotMayBeOffOrEmpty() {
        launch(.waiting)
        XCTAssertEqual(label(of: "status.title"), Copy.waitingForDevice)
        XCTAssertEqual(label(of: "status.hotspotHint"), "Turn on Personal Hotspot, then join it from the other device. Tether starts when the first device joins.")
        XCTAssertEqual(label(of: "status.hotspotPath"), Copy.hotspotPath)
        // Tether sleeps 10 minutes after it's left, which nothing said (H2).
        XCTAssertEqual(reveal(element("status.sleepHint")).label,
                       "Open Tether before you turn the hotspot on. It waits 10 minutes after you leave it, then sleeps. To wake it without opening it, see Settings > Help.")
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
    /// The reason is the title, one line says what to do, and nothing repeats it under the card (M9).
    func testLockedKeysDontSaySharing() {
        launch(.wireGuardLocked)
        XCTAssertEqual(label(of: "status.title"), "Tether can't read its keys yet")
        XCTAssertEqual(label(of: "wireguard.problem"),
                       "iOS opens them after the first unlock since a restart. Tether tries again by itself. If this stays for a minute, restart the iPhone.")
        assertNowhere(element("status.stopHint"), element("status.hotspotPath"), element("status.hotspotHint"), message: "a device has joined the hotspot")
        assertNowhere(element("wireguard.reset"), element("wireguard.shareLog"), message: "unlocking fixes it, not a button")
        assertNowhere(text(containing: "WireGuard isn't running"), text(containing: "can't share yet"))
    }

    /// The saved keys can't be read: the way out is the card's one button, after the same question as before.
    func testUnreadableKeysOfferToStartOver() {
        launch(.wireGuardNeedsReset)
        XCTAssertEqual(label(of: "status.title"), "Tether can't read its saved keys")
        XCTAssertEqual(label(of: "wireguard.problem"), "Start over with new keys. Every device has to be added again.")
        reveal(element("wireguard.reset")).tap()
        XCTAssertTrue(app.buttons["Start Over"].waitForExistence(timeout: 5), "it asks first")
        cancelDialog()
        assertNowhere(element("wireguard.shareLog"))
    }

    /// New keys can't be saved: share the log, with where to send it under the button.
    func testUnsavedKeysOfferTheLog() {
        launch(.wireGuardUnsaved)
        XCTAssertEqual(label(of: "status.title"), "Tether can't save its keys")
        XCTAssertEqual(label(of: "wireguard.problem"), "It tries again by itself. If this stays, share the log in a GitHub issue.")
        XCTAssertEqual(reveal(element("wireguard.shareLog")).label, "Share the log")
        XCTAssertEqual(reveal(element("wireguard.issues")).label, Copy.issuesLink)
        assertNowhere(element("wireguard.reset"))
    }

    /// Only share through a VPN is on and no VPN is: the card says the devices are kept out, not
    /// Sharing, with what to do and the way to the switch (H1).
    func testNoVPNKeepsTheDevicesOut() {
        launch(.vpnBlocked)
        XCTAssertEqual(label(of: "status.title"), Copy.keptOut)
        XCTAssertEqual(label(of: "status.headline"), "No VPN is on")
        XCTAssertEqual(label(of: "vpn.blocked"),
                       "No device gets through until a VPN is on. Turn your VPN on, or turn off Only share through a VPN in Settings.")
        assertNowhere(element("traffic.speeds"), element("traffic.history"), message: "nothing gets through, so no speeds")
        let ipad = reveal(element("device.iPad"))
        XCTAssertTrue(ipad.label.contains(Copy.keptOutRow), ipad.label)
        XCTAssertEqual(reveal(element("status.stopHint")).label, Copy.stopHint, "it still shares")
        reveal(element("status.openSettings")).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "the link did not open Settings")
    }

    /// A stop leaves a note until Got it (H3): Tether starts again when it's opened, so the stop itself is gone.
    func testAStopLeavesANoteUntilGotIt() {
        launch(.stoppedIdle)
        let note = reveal(element("note.lastStop"))
        XCTAssertTrue(note.label.hasPrefix("Sharing stopped today at 4:00"), note.label)
        XCTAssertTrue(note.label.hasSuffix("No device was connected for 30 minutes."), note.label)
        XCTAssertEqual(label(of: "status.title"), "Sharing", "open again, it shares again")
        reveal(element("note.lastStop.gotIt")).tap()
        waitUntilGone(element("note.lastStop"))
    }

    func testABatteryStopSaysTheLevel() {
        launch(.stoppedBattery)
        let note = reveal(element("note.lastStop"))
        XCTAssertTrue(note.label.hasPrefix("Sharing stopped today at 4:00"), note.label)
        XCTAssertTrue(note.label.hasSuffix("The battery reached 20%."), note.label)
    }

    /// Three or more warnings and notes fold behind one link, warnings first (M13).
    func testManyWarningsFoldBehindALink() {
        launch(.manyWarnings)
        XCTAssertEqual(reveal(element("battery.low")).label,
                       "Battery is at 15%, at or below your 20% stop level. Sharing stops when you leave Tether.")
        assertNowhere(element("stale.warning"), element("app.expiry"), element("note.lastStop"))
        let more = reveal(element("notes.more"))
        XCTAssertEqual(more.label, "3 more")
        more.tap()
        for id in ["stale.warning", "app.expiry", "note.lastStop"] {
            XCTAssertTrue(reveal(element(id)).exists, id)
        }
        assertNowhere(element("notes.more"))
        XCTAssertLessThan(element("battery.low").frame.maxY, element("stale.warning").frame.minY, "warnings in one order")
        XCTAssertLessThan(element("app.expiry").frame.maxY, element("note.lastStop").frame.minY, "notes after warnings")
    }

    /// Tether offers notifications on Home instead of iOS asking by itself (M7). Not now hides it
    /// (for good, which `NoticeOffer`'s unit tests cover: a demo always offers).
    func testHomeOffersNotifications() {
        launch(.askNotifications)
        XCTAssertEqual(reveal(element("note.notifications")).label, Copy.offerNotifications)
        XCTAssertEqual(label(of: "note.notifications.allow"), Copy.allowNotifications)
        reveal(element("note.notifications.notNow")).tap()
        waitUntilGone(element("note.notifications"))
    }

    /// A sideloaded build stops opening when its 7-day profile runs out, so the main screen says so first.
    func testAnExpiringBuildSaysToRefreshIt() {
        launch(.expiring)
        XCTAssertEqual(label(of: "app.expiry"), "Tether stops opening in 2 days. Refresh it in SideStore or AltStore, or reinstall it, before then.")
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
        // At the foot of the screen, below the devices.
        XCTAssertEqual(reveal(element("status.stopHint")).label, Copy.stopHint)
        assertNowhere(element("status.hotspotHint"), element("status.hotspotPath"))
        assertNowhere(element("sharing.switch"), message: "no switch: the hotspot is the switch")
    }

    func testWaitingHasNoStopHint() {
        launch(.waiting)
        assertNowhere(element("status.stopHint"))
    }
}
