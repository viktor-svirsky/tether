import XCTest

/// One device's screen (status, rename, remove) and the WireGuard problem section on the main screen.
final class DeviceViewTests: TetherUITestCase {
    private let lockedText = "Its keys can't be read yet. Unlock this iPhone once."
    private let resetText = "Its saved keys can't be read. Start over with new keys to use it."

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

    func testRenamingADeviceChangesItsRow() {
        launch(.sharing)
        openDevice("MacBook")
        // Tapping the title opens a menu with Rename.
        app.navigationBars["MacBook"].buttons["MacBook"].tap()
        app.buttons["Rename"].firstMatch.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "MacBook".count) + "Work Mac\n")
        XCTAssertTrue(app.navigationBars["Work Mac"].waitForExistence(timeout: 5))
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

    func testLockedKeysShowTheProblemAndNoQRCode() {
        launch(.wireGuardLocked)
        let banner = staticText("wireguard.problem") // the warning icon carries the identifier too
        XCTAssertTrue(reveal(banner).exists)
        XCTAssertEqual(banner.label, lockedText)
        XCTAssertTrue(sectionHeader("WIREGUARD ISN'T RUNNING").exists)
        assertNowhere(element("wireguard.reset"), message: "a locked Keychain gets better by unlocking, not by starting over")
        assertNowhere(element("add.qr"), element("add.share"))
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
