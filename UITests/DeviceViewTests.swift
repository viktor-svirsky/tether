import XCTest

/// One device's screen (status, rename, remove) and the WireGuard problem section on the main screen.
final class DeviceViewTests: TetherUITestCase {
    private let lockedText = "Its keys can't be read yet. Unlock this iPhone once."
    private let resetText = "Its saved keys can't be read. Start over with new keys to use it."
    private let unsavedText = "Its new keys can't be saved: Keychain error -34018."

    // MARK: one device

    func testTappingADeviceOpensItsScreenWithStatusAndRemove() {
        launch(.sharing)
        openDevice("iPad")
        XCTAssertEqual(staticText("device.status").label, "Connected")
        XCTAssertTrue(element("device.remove").exists)
        assertNowhere(element("wireguard.qr"), text(containing: "10.7.0.2"), message: "no per-device code or address any more")
        assertNowhere(element("device.lastConnected"), message: "connected says it")
    }

    /// What a device used this month and last, through Tether (#75), with down and up under it (#73).
    /// The demo's iPad used 3.12 GB of its 10 GB limit, and the Windows PC has no limit and used nothing.
    func testADeviceShowsItsDataThisMonthAndLast() throws {
        launch(.sharing)
        openDevice("iPad")
        let thisMonth = reveal(element("device.thisMonth"))
        XCTAssertTrue(thisMonth.label.contains("3.12 GB of 10 GB this month") && thisMonth.label.contains("Resets on November 1"), thisMonth.label)
        XCTAssertTrue(thisMonth.label.contains("3 GB down, 120 MB up"), "read as words, not arrows: \(thisMonth.label)")
        let lastMonth = reveal(element("device.lastMonth"))
        XCTAssertTrue(lastMonth.label.contains("Last month") && lastMonth.label.contains("0 bytes"), lastMonth.label)
        XCTAssertTrue(sectionHeader("Data through Tether").exists)
        let footer = reveal(element("device.limitFooter")).label
        XCTAssertTrue(footer.hasPrefix("Counts data both ways. When iPad reaches it, Tether pauses iPad until the count resets on November 1"), footer)
        XCTAssertTrue(footer.hasSuffix(". You can resume it sooner."), footer)
        try audit(only: "device.")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openDevice("Windows PC")
        XCTAssertEqual(reveal(element("device.thisMonth")).label, "Not used this month", "no limit, no meter, no 0 bytes")
        XCTAssertEqual(reveal(element("device.limitFooter")).label,
                       "Counts data both ways. With a limit, Tether pauses Windows PC when it reaches it, until the count resets on November 1.")
    }

    /// The limit is a menu: None, 5, 10, 20, 50 GB and Other amount, which asks for GB.
    func testTheLimitIsAMenuWithOtherAmount() {
        launch(.sharing)
        openDevice("Windows PC")
        let menu = reveal(app.buttons["device.limit"].firstMatch)
        XCTAssertTrue(menu.label.contains("Limit") && (menu.label.contains("None") || value(of: menu) == "None"), menu.label)
        menu.tap()
        for choice in ["None", "5 GB", "10 GB", "20 GB", "50 GB", "Other amount"] {
            XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 3), choice)
        }
        app.buttons["Other amount"].tap()
        // A SwiftUI alert doesn't pass its text field's identifier on, so it's found in the alert.
        let alert = app.alerts["Data limit"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let amount = alert.textFields.firstMatch
        amount.tap()
        amount.typeText("7.5")
        alert.buttons["Set"].tap()
        let meter = reveal(element("device.thisMonth"))
        XCTAssertTrue(meter.label.contains("0 bytes of 7.5 GB this month"), meter.label)
        XCTAssertTrue(reveal(app.buttons["device.limit"].firstMatch).label.contains("7.5 GB") || value(of: app.buttons["device.limit"].firstMatch) == "7.5 GB")
    }

    /// And when it last connected (#73): two hours before the demo's 6 PM.
    func testAnUnconnectedDeviceSaysNotConnected() {
        launch(.sharing)
        openDevice("Windows PC")
        XCTAssertEqual(staticText("device.status").label, "Not connected")
        let last = reveal(element("device.lastConnected")).label
        XCTAssertTrue(last.contains("Last connected") && last.contains("Today at 4:00"), last)
    }

    /// Without a limit, this month is a big number with down and up under it (#73).
    func testWithoutALimitThisMonthIsABigNumberWithDownAndUp() {
        launch(.sharing)
        openDevice("iPad")
        reveal(app.buttons["device.limit"].firstMatch).tap()
        XCTAssertTrue(app.buttons["None"].waitForExistence(timeout: 3))
        app.buttons["None"].tap()
        let thisMonth = reveal(element("device.thisMonth")).label
        XCTAssertTrue(thisMonth.contains("3.12 GB") && thisMonth.contains("this month") && thisMonth.contains("3 GB down, 120 MB up"), thisMonth)
        assertNowhere(text(containing: "of 10 GB"), text(containing: "Resets on"), message: "no meter without a limit")
    }

    /// A paused device says why it can't connect, not when it last did (#73).
    func testAPausedDeviceDoesntSayWhenItLastConnected() {
        launch(.paused)
        openDevice("iPad")
        XCTAssertEqual(staticText("device.status").label, "Paused")
        assertNowhere(element("device.lastConnected"))
    }

    func testBackReturnsToTheMainScreen() {
        launch(.sharing)
        openDevice("iPad")
        goBack(to: "Tether")
        waitUntilHittable(element("status.title"))
        XCTAssertTrue(element("device.iPad").waitForExistence(timeout: 5))
    }

    /// On the device's screen, through the title: tapping it opens a menu with Rename.
    private func rename(_ name: String, to newName: String) {
        app.navigationBars[name].buttons[name].tap()
        app.buttons["Rename"].firstMatch.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: name.count) + newName + "\n")
    }

    func testRenamingADeviceChangesItsRow() {
        launch(.sharing)
        openDevice("Windows PC")
        rename("Windows PC", to: "Work PC")
        XCTAssertTrue(app.navigationBars["Work PC"].waitForExistence(timeout: 5))
        assertNowhere(element("device.problem"))
        goBack(to: "Tether")
        XCTAssertTrue(reveal(element("device.Work PC")).exists)
        assertNowhere(element("device.Windows PC"))
    }

    func testCancellingTheRemoveDialogKeepsTheDevice() {
        launch(.sharing)
        openDevice("iPad")
        element("device.remove").tap()
        XCTAssertTrue(app.buttons["Remove"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Remove iPad?"].exists)
        cancelDialog()
        waitUntilGone(app.buttons["Remove"].firstMatch)
        XCTAssertTrue(app.navigationBars["iPad"].exists, "still on the device's screen")
        goBack(to: "Tether")
        XCTAssertTrue(reveal(element("device.iPad")).exists)
        XCTAssertTrue(element("device.Windows PC").exists)
    }

    func testRemovingADeviceTakesItOffTheListAndKeepsTheOther() {
        launch(.sharing)
        openDevice("Windows PC")
        element("device.remove").tap()
        app.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5), "back on the main screen")
        waitUntilGone(element("device.Windows PC"))
        XCTAssertTrue(reveal(element("device.iPad")).exists)
        assertNowhere(element("device.Windows PC"))
    }

    /// On an IPv6-only carrier the iPhone's address changes with the cellular session, and a device set
    /// up before points at the old one (#65). Its row and its screen say so, and only its own.
    func testADeviceWhoseConfigPointsAtAnOldAddressSaysToAddItAgain() {
        launch(.oldAddress)
        let pc = reveal(element("device.Windows PC"))
        XCTAssertTrue(pc.label.contains("Its config points at an old address. Add it again."), pc.label)
        XCTAssertFalse(element("device.iPad").label.contains("old address"), element("device.iPad").label)
        openDevice("Windows PC")
        let warning = staticText("device.oldAddress") // the warning icon carries the identifier too
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertEqual(warning.label, "Its config points at an old address of this iPhone, so it can't connect. Remove it, then add it again.")
        XCTAssertTrue(element("device.remove").exists)
        goBack(to: "Tether")
        openDevice("iPad")
        assertNowhere(element("device.oldAddress"))
    }

    /// A usual carrier's address never changes, so nothing says it did.
    func testNoDevicePointsAtAnOldAddressOnAUsualCarrier() {
        launch(.sharing)
        reveal(element("device.Windows PC"))
        assertNowhere(text(containing: "old address"))
        openDevice("Windows PC")
        assertNowhere(element("device.oldAddress"))
    }

    // MARK: problems

    func testARenameThatCantBeSavedSaysSoAndKeepsTheName() {
        launch(.qrCodeUnsaved)
        openDevice("Windows PC")
        rename("Windows PC", to: "Work PC")
        let problem = staticText("device.problem") // the warning icon carries the identifier too
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        XCTAssertEqual(problem.label, "The new name couldn't be saved.")
        // The title shows the saved name. The bar's identifier keeps what was typed, so the test reads the title itself.
        XCTAssertTrue(app.navigationBars.buttons["Windows PC"].waitForExistence(timeout: 5), "the old name stays")
        XCTAssertFalse(app.navigationBars.buttons["Work PC"].exists)
        goBack(to: "Tether")
        XCTAssertTrue(reveal(element("device.Windows PC")).exists)
        openDevice("iPad")
        assertNowhere(element("device.problem"), message: "it belongs to the Windows PC")
    }

    func testARemovalThatCantBeSavedStaysOnTheDeviceAndSaysSo() {
        launch(.qrCodeUnsaved)
        openDevice("Windows PC")
        element("device.remove").tap()
        app.buttons["Remove"].firstMatch.tap()
        let problem = staticText("device.problem")
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        XCTAssertEqual(problem.label, "The device couldn't be removed.")
        XCTAssertTrue(app.navigationBars["Windows PC"].exists, "still on the device's screen")
        goBack(to: "Tether")
        XCTAssertTrue(reveal(element("device.Windows PC")).exists)
    }

    func testLockedKeysShowTheProblemAndNoQRCode() {
        launch(.wireGuardLocked)
        let banner = staticText("wireguard.problem") // the warning icon carries the identifier too
        XCTAssertTrue(reveal(banner).exists)
        XCTAssertEqual(banner.label, lockedText)
        XCTAssertTrue(sectionHeader("WIREGUARD ISN'T RUNNING").exists)
        assertNowhere(element("wireguard.reset"), message: "a locked Keychain gets better by unlocking, not by starting over")
        assertNowhere(element("add.open"))
    }

    /// A code for keys that aren't saved could never connect, since the next launch makes new ones.
    func testNewKeysThatCantBeSavedSaySoAndShowNoQRCode() {
        launch(.wireGuardUnsaved)
        let banner = staticText("wireguard.problem")
        XCTAssertTrue(reveal(banner).exists)
        XCTAssertEqual(banner.label, unsavedText)
        XCTAssertEqual(label(of: "status.title"), "Tether can't share yet")
        assertNowhere(element("add.open"), element("add.problem"), element("wireguard.reset"))
    }

    /// Without the hotspot there's no QR code either, so a new user would have no way to add a device and no reason why.
    func testLockedKeysShowBeforeTheHotspotIsOn() {
        launch(.wireGuardLockedWaiting)
        XCTAssertEqual(label(of: "status.title"), "Turn on Personal Hotspot")
        let banner = staticText("wireguard.problem")
        XCTAssertTrue(reveal(banner).exists)
        XCTAssertEqual(banner.label, lockedText)
        assertNowhere(element("add.open"), element("wireguard.reset"))
    }

    func testUnreadableKeysOfferToStartOver() {
        launch(.wireGuardNeedsReset)
        XCTAssertEqual(staticText("wireguard.problem").label, resetText)
        XCTAssertEqual(reveal(element("wireguard.reset")).label, "Start over with new keys")
        assertNowhere(element("add.open"))
    }

    func testStartingOverClearsTheProblemAndShowsTheQRCode() {
        launch(.wireGuardNeedsReset)
        reveal(element("wireguard.reset")).tap()
        waitUntilGone(element("wireguard.problem"))
        assertNowhere(element("wireguard.reset"))
        XCTAssertEqual(reveal(element("add.open")).label, "Add a device", "no device yet after starting over")
    }
}
