import XCTest

/// One device's screen (status, rename, remove) and the WireGuard problem section on the main screen.
final class DeviceViewTests: TetherUITestCase {
    private let lockedText = "Tether can't read its keys yet. iOS opens them after the first unlock since a restart. Tether tries again by itself. If this stays for a minute, restart the iPhone."
    private let resetText = "Tether can't read its saved keys. Start over with new keys. Every device has to be added again."
    private let unsavedText = "Tether can't save its keys. It tries again by itself. If this stays, share the log in a GitHub issue."

    // MARK: one device

    func testTappingADeviceOpensItsScreenWithStatusAndRemove() {
        launch(.sharing)
        openDevice("iPad")
        XCTAssertEqual(staticText("device.status").label, "Connected")
        // Below the screen on an iPhone SE.
        XCTAssertTrue(reveal(element("device.remove")).exists)
        assertNowhere(element("wireguard.qr"), text(containing: "10.7.0.2"), message: "no per-device code or address any more")
        assertNowhere(element("device.lastConnected"), message: "connected says it")
        // Where its handshake comes from, without the port (#73).
        XCTAssertEqual(reveal(staticText("device.connectsFrom")).label, "Connects from 172.20.10.2")
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
        // The card says when it resets, so the footer doesn't say it again (L7).
        XCTAssertEqual(reveal(element("device.limitFooter")).label,
                       "Counts data both ways. When iPad reaches it, Tether pauses iPad until the count resets. You can resume it sooner.")
        try audit(only: "device.")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openDevice("Windows PC")
        XCTAssertEqual(reveal(element("device.thisMonth")).label, "Not used this month", "no limit, no meter, no 0 bytes")
        XCTAssertEqual(reveal(element("device.limitFooter")).label,
                       "Counts data both ways. With a limit, Tether pauses Windows PC when it reaches it, until the count resets on November 1.")
    }

    /// The Data limit is a menu: None, 5, 10, 20, 50 GB and Other amount, which asks for GB.
    func testTheLimitIsAMenuWithOtherAmount() {
        launch(.sharing)
        openDevice("Windows PC")
        let menu = reveal(app.buttons["device.limit"].firstMatch)
        XCTAssertTrue(menu.label.contains(Copy.dataLimit) && (menu.label.contains("None") || value(of: menu) == "None"), menu.label)
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

    /// And when it last connected (#73): two hours before the demo's 6 PM. What to do on that device
    /// is under it (M1).
    func testAnUnconnectedDeviceSaysNotConnected() {
        launch(.sharing)
        openDevice("Windows PC")
        XCTAssertEqual(staticText("device.status").label, Copy.notConnected)
        XCTAssertEqual(staticText("device.notConnectedHint").label, Copy.notConnectedHint)
        let last = reveal(element("device.lastConnected")).label
        XCTAssertTrue(last.contains("Last connected") && last.contains("Today at 4:00"), last)
        assertNowhere(element("device.connectsFrom"), message: "only while connected")
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

    /// A paused device says why it can't connect, not when it last did or from where (#73).
    func testAPausedDeviceDoesntSayWhenItLastConnected() {
        launch(.paused)
        openDevice("iPad")
        XCTAssertEqual(staticText("device.status").label, "Paused")
        assertNowhere(element("device.lastConnected"), element("device.notConnectedHint"))
        assertNowhere(element("device.connectsFrom"), message: "its tunnel is up, but it isn't connected")
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

    /// A Rename row, since the title's menu is easy to miss (#173), next to Remove under the data, so
    /// Pause comes right after the status (L6). The name is selected, so typing replaces it.
    func testTheRenameRowRenamesTheDevice() {
        launch(.sharing)
        openDevice("Windows PC")
        let row = reveal(element("device.rename"))
        XCTAssertEqual(row.label, "Rename")
        // Frames read in one scroll position: a List drops rows far off screen, so each is checked
        // only while it's there.
        let remove = reveal(element("device.remove"))
        XCTAssertLessThan(row.frame.maxY, remove.frame.minY, "above Remove")
        let limit = app.buttons["device.limit"].firstMatch
        if limit.exists { XCTAssertGreaterThan(row.frame.minY, limit.frame.maxY, "under the data") }
        let pause = element("device.pause")
        if pause.exists, limit.exists { XCTAssertLessThan(pause.frame.maxY, limit.frame.minY, "Pause above the data") }
        row.tap()
        let alert = app.alerts["Rename"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields.firstMatch
        XCTAssertEqual(field.value as? String, "Windows PC")
        waitUntilStill(field)
        field.typeText("Work PC")
        alert.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Work PC"].waitForExistence(timeout: 5))
        assertNowhere(element("device.problem"))
        goBack(to: "Tether")
        XCTAssertTrue(reveal(element("device.Work PC")).exists)
        assertNowhere(element("device.Windows PC"))
    }

    func testCancellingRenameKeepsTheName() {
        launch(.sharing)
        openDevice("iPad")
        reveal(element("device.rename")).tap()
        let alert = app.alerts["Rename"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.typeText("Other")
        alert.buttons["Cancel"].tap()
        waitUntilGone(alert)
        XCTAssertTrue(app.navigationBars["iPad"].exists)
    }

    func testCancellingTheRemoveDialogKeepsTheDevice() {
        launch(.sharing)
        openDevice("iPad")
        reveal(element("device.remove")).tap()
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
        reveal(element("device.remove")).tap()
        app.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5), "back on the main screen")
        waitUntilGone(element("device.Windows PC"))
        XCTAssertTrue(reveal(element("device.iPad")).exists)
        assertNowhere(element("device.Windows PC"))
    }

    /// On an IPv6-only carrier the iPhone's address changes with the cellular session, and a device set
    /// up before points at the old one (#65). Its row and its screen say so, and only its own, and its
    /// screen gives it a new config (M1).
    func testADeviceWhoseConfigPointsAtAnOldAddressSaysToGiveItANewConfig() {
        launch(.oldAddress)
        let pc = reveal(element("device.Windows PC"))
        XCTAssertTrue(pc.label.contains("Its config points at an old address. Give it a new config."), pc.label)
        XCTAssertFalse(element("device.iPad").label.contains("old address"), element("device.iPad").label)
        openDevice("Windows PC")
        let warning = staticText("device.oldAddress") // the warning icon carries the identifier too
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertEqual(warning.label, "Its config points at an old address of this iPhone, so it can't connect.")
        XCTAssertEqual(reveal(element("device.newConfig")).label, Copy.giveNewConfig)
        assertNowhere(element("device.notConnectedHint"), message: "the warning says what to do")
        XCTAssertTrue(reveal(element("device.remove")).exists) // below the screen on an iPhone SE
        goBack(to: "Tether")
        openDevice("iPad")
        assertNowhere(element("device.oldAddress"), element("device.newConfig"))
    }

    /// Give it a new config opens Add a device over its screen. Closing it leaves the device as it was.
    func testGiveItANewConfigOpensAddADevice() {
        launch(.oldAddress)
        openDevice("Windows PC")
        reveal(element("device.newConfig")).tap()
        XCTAssertTrue(element("add.close").waitForExistence(timeout: 5), "Add a device did not open")
        element("add.close").tap()
        waitUntilGone(element("add.close"))
        XCTAssertTrue(app.navigationBars["Windows PC"].exists, "back on its screen")
        XCTAssertTrue(staticText("device.oldAddress").exists, "nothing changed")
    }

    /// A device whose config uses this iPhone's name, while the name isn't answered (taken by another
    /// device, say), says that, not that its address is old (#65).
    func testADeviceOnANameThatIsntAnsweredSaysSo() {
        launch(.nameNotAnswered)
        let pc = reveal(element("device.Windows PC"))
        XCTAssertTrue(pc.label.contains("Its config uses this iPhone's name, which isn't answering. Give it a new config."), pc.label)
        XCTAssertFalse(pc.label.contains("old address"), pc.label)
        openDevice("Windows PC")
        let warning = staticText("device.oldAddress")
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertEqual(warning.label, "Its config uses this iPhone's name, which isn't answering on the hotspot, so it can't connect.")
        XCTAssertTrue(reveal(element("device.newConfig")).exists)
    }

    /// A usual carrier's address never changes, so nothing says it did.
    func testNoDevicePointsAtAnOldAddressOnAUsualCarrier() {
        launch(.sharing)
        reveal(element("device.Windows PC"))
        assertNowhere(text(containing: "old address"))
        openDevice("Windows PC")
        assertNowhere(element("device.oldAddress"))
    }

    // MARK: a limit that pauses it at once (L1)

    /// Picks a limit from the Data limit menu.
    private func pickLimit(_ choice: String) {
        reveal(app.buttons["device.limit"].firstMatch).tap()
        XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 3), choice)
        app.buttons[choice].tap()
    }

    /// The demo's iPad used 9.5 GB of its 10 GB. 5 GB would pause it at once, so it asks first, and
    /// Cancel keeps the 10 GB.
    func testALimitUnderWhatItUsedAsksFirst() {
        launch(.limits)
        openDevice("iPad")
        pickLimit("5 GB")
        let alert = app.alerts["iPad already used 9.5 GB"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["With a 5 GB limit it pauses now, until the count resets on November 1."].exists)
        alert.buttons["Cancel"].tap()
        waitUntilGone(alert)
        XCTAssertTrue(reveal(element("device.thisMonth")).label.contains("of 10 GB"), "the limit stays")
        XCTAssertEqual(staticText("device.status").label, "Connected")
        pickLimit("5 GB")
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Set the limit and pause it"].tap()
        let status = staticText("device.status")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let paused = expectation(for: NSPredicate(format: "label == 'Paused at its limit'"), evaluatedWith: status)
        XCTAssertEqual(XCTWaiter().wait(for: [paused], timeout: 10), .completed, status.label)
        XCTAssertTrue(reveal(element("device.thisMonth")).label.contains("of 5 GB"))
    }

    /// A typed amount asks the same, and one over what it used doesn't ask.
    func testATypedLimitUnderWhatItUsedAsksToo() {
        launch(.limits)
        openDevice("iPad")
        pickLimit("Other amount")
        let typing = app.alerts["Data limit"]
        XCTAssertTrue(typing.waitForExistence(timeout: 3))
        let amount = typing.textFields.firstMatch
        amount.tap()
        amount.typeText("1")
        typing.buttons["Set"].tap()
        let alert = app.alerts["iPad already used 9.5 GB"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["With a 1 GB limit it pauses now, until the count resets on November 1."].exists)
        alert.buttons["Cancel"].tap()
        waitUntilGone(alert)
        pickLimit("20 GB")
        XCTAssertTrue(reveal(element("device.thisMonth")).label.contains("of 20 GB"), "set at once")
        XCTAssertFalse(app.alerts.firstMatch.exists)
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
        reveal(element("device.remove")).tap()
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
        XCTAssertEqual(label(of: "status.title"), Copy.waitingForDevice)
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

    /// It removes every device, so it asks first and says what it costs (#174).
    func testStartingOverAsksFirst() {
        launch(.wireGuardNeedsReset)
        reveal(element("wireguard.reset")).tap()
        XCTAssertTrue(app.staticTexts["Every device has to be added again. If you went back to an older Tether, update it instead."].waitForExistence(timeout: 5))
        // Cancelling keeps the keys: the problem and the way out are still there.
        cancelDialog()
        XCTAssertEqual(staticText("wireguard.problem").label, resetText)
    }

    func testStartingOverClearsTheProblemAndShowsTheQRCode() {
        launch(.wireGuardNeedsReset)
        reveal(element("wireguard.reset")).tap()
        app.buttons["Start Over"].firstMatch.tap()
        waitUntilGone(element("wireguard.problem"))
        assertNowhere(element("wireguard.reset"))
        XCTAssertEqual(reveal(element("add.open")).label, "Add a device", "no device yet after starting over")
    }
}
