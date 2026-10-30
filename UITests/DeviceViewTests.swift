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
    }

    func testAnUnconnectedDeviceSaysNotConnected() {
        launch(.sharing)
        openDevice("MacBook")
        XCTAssertEqual(staticText("device.status").label, "Not connected")
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
        openDevice("MacBook")
        rename("MacBook", to: "Work Mac")
        XCTAssertTrue(app.navigationBars["Work Mac"].waitForExistence(timeout: 5))
        assertNowhere(element("device.problem"))
        goBack(to: "Tether")
        XCTAssertTrue(reveal(element("device.Work Mac")).exists)
        assertNowhere(element("device.MacBook"))
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
        XCTAssertTrue(element("device.MacBook").exists)
    }

    func testRemovingADeviceTakesItOffTheListAndKeepsTheOther() {
        launch(.sharing)
        openDevice("MacBook")
        element("device.remove").tap()
        app.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5), "back on the main screen")
        waitUntilGone(element("device.MacBook"))
        XCTAssertTrue(reveal(element("device.iPad")).exists)
        assertNowhere(element("device.MacBook"))
    }

    // MARK: problems

    func testARenameThatCantBeSavedSaysSoAndKeepsTheName() {
        launch(.qrCodeUnsaved)
        openDevice("MacBook")
        rename("MacBook", to: "Work Mac")
        let problem = staticText("device.problem") // the warning icon carries the identifier too
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        XCTAssertEqual(problem.label, "The new name couldn't be saved.")
        // The title shows the saved name. The bar's identifier keeps what was typed, so the test reads the title itself.
        XCTAssertTrue(app.navigationBars.buttons["MacBook"].waitForExistence(timeout: 5), "the old name stays")
        XCTAssertFalse(app.navigationBars.buttons["Work Mac"].exists)
        goBack(to: "Tether")
        XCTAssertTrue(reveal(element("device.MacBook")).exists)
        openDevice("iPad")
        assertNowhere(element("device.problem"), message: "it belongs to the MacBook")
    }

    func testARemovalThatCantBeSavedStaysOnTheDeviceAndSaysSo() {
        launch(.qrCodeUnsaved)
        openDevice("MacBook")
        element("device.remove").tap()
        app.buttons["Remove"].firstMatch.tap()
        let problem = staticText("device.problem")
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        XCTAssertEqual(problem.label, "The device couldn't be removed.")
        XCTAssertTrue(app.navigationBars["MacBook"].exists, "still on the device's screen")
        goBack(to: "Tether")
        XCTAssertTrue(reveal(element("device.MacBook")).exists)
    }

    func testLockedKeysShowTheProblemAndNoQRCode() {
        launch(.wireGuardLocked)
        let banner = staticText("wireguard.problem") // the warning icon carries the identifier too
        XCTAssertTrue(reveal(banner).exists)
        XCTAssertEqual(banner.label, lockedText)
        XCTAssertTrue(sectionHeader("WIREGUARD ISN'T RUNNING").exists)
        assertNowhere(element("wireguard.reset"), message: "a locked Keychain gets better by unlocking, not by starting over")
        assertNowhere(element("add.qr"), element("add.share"))
    }

    /// A code for keys that aren't saved could never connect, since the next launch makes new ones.
    func testNewKeysThatCantBeSavedSaySoAndShowNoQRCode() {
        launch(.wireGuardUnsaved)
        let banner = staticText("wireguard.problem")
        XCTAssertTrue(reveal(banner).exists)
        XCTAssertEqual(banner.label, unsavedText)
        XCTAssertEqual(label(of: "status.title"), "Tether can't share yet")
        assertNowhere(element("add.qr"), element("add.share"), element("add.problem"), element("wireguard.reset"))
    }

    /// Without the hotspot there's no QR code either, so a new user would have no way to add a device and no reason why.
    func testLockedKeysShowBeforeTheHotspotIsOn() {
        launch(.wireGuardLockedWaiting)
        XCTAssertEqual(label(of: "status.title"), "Turn on Personal Hotspot")
        let banner = staticText("wireguard.problem")
        XCTAssertTrue(reveal(banner).exists)
        XCTAssertEqual(banner.label, lockedText)
        assertNowhere(element("add.qr"), element("add.share"), element("wireguard.reset"))
    }

    func testUnreadableKeysOfferToStartOver() {
        launch(.wireGuardNeedsReset)
        XCTAssertEqual(staticText("wireguard.problem").label, resetText)
        XCTAssertEqual(reveal(element("wireguard.reset")).label, "Start over with new keys")
        assertNowhere(element("add.qr"))
    }

    func testStartingOverClearsTheProblemAndShowsTheQRCode() {
        launch(.wireGuardNeedsReset)
        reveal(element("wireguard.reset")).tap()
        waitUntilGone(element("wireguard.problem"))
        assertNowhere(element("wireguard.reset"))
        XCTAssertTrue(reveal(element("add.qr")).exists)
        XCTAssertTrue(sectionHeader("ADD A DEVICE").exists, "no device yet after starting over")
    }
}
