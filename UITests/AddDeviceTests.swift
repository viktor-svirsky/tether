import XCTest

/// Adding a device: the QR code, the shared file and the steps that are always on the main screen.
final class AddDeviceTests: TetherUITestCase {
    private let steps = "Scan it with WireGuard: + > Create from QR code."

    func testBeforeAnyDeviceTheMainScreenShowsTheQRCodeTheFileAndTheSteps() {
        launch(.waiting)
        XCTAssertTrue(reveal(element("add.qr")).exists)
        XCTAssertEqual(element("add.qr").label, "QR code for the next device")
        let share = reveal(element("add.share"))
        XCTAssertTrue(share.label.contains("Share file"), share.label)
        XCTAssertEqual(reveal(element("add.steps")).label, steps)
        XCTAssertTrue(sectionHeader("ADD A DEVICE").exists)
        assertNowhere(sectionHeader("ADD ANOTHER DEVICE"))
    }

    func testTheQRCodeShowsWithTheHotspotOnButNoDevice() {
        launch(.noDevices)
        XCTAssertTrue(reveal(element("add.qr")).exists)
        XCTAssertTrue(sectionHeader("ADD A DEVICE").exists)
    }

    func testOnceADeviceExistsTheHeaderSaysAddAnotherDevice() {
        launch(.sharing)
        XCTAssertTrue(reveal(element("add.qr")).exists, "the code stays for the next device")
        XCTAssertTrue(sectionHeader("ADD ANOTHER DEVICE").exists)
        assertNowhere(sectionHeader("ADD A DEVICE"))
        XCTAssertTrue(reveal(element("add.share")).exists)
        XCTAssertTrue(reveal(element("add.steps")).exists)
    }

    /// The devices it has still connect, so it's sharing. Only the next device has to wait.
    func testAQRCodeThatCantBeSavedIsntShownAndSaysWhy() {
        launch(.qrCodeUnsaved)
        XCTAssertEqual(label(of: "status.title"), "Sharing")
        XCTAssertEqual(reveal(staticText("add.problem")).label, "The code for the next device can't be saved: Keychain error -34018.")
        XCTAssertTrue(sectionHeader("ADD ANOTHER DEVICE").exists)
        XCTAssertTrue(reveal(element("device.iPad")).exists)
        assertNowhere(element("add.qr"), element("add.share"), element("add.page"), element("add.steps"), element("wireguard.problem"))
    }

    /// The two ways besides the code sit side by side, so the card stays short.
    func testWhileSharingTheFileAndBrowserButtonsShareARow() {
        launch(.sharing)
        let page = reveal(element("add.page"))
        let share = element("add.share")
        XCTAssertTrue(page.label.contains("Browser"), page.label)
        XCTAssertEqual(share.frame.midY, page.frame.midY, accuracy: 2)
        XCTAssertLessThan(share.frame.maxX, page.frame.minX)
    }

    func testTheBrowserButtonGivesThePageAddress() {
        launch(.sharing)
        reveal(element("add.page")).tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["Join this iPhone's hotspot on the device, then open http://172.20.10.1 in its browser. Keep Tether on screen."].exists)
        alert.buttons["OK"].tap()
        assertNowhere(app.alerts.firstMatch)
    }

    /// The page runs with WireGuard, on the hotspot.
    func testWithTheHotspotOffThereIsNoPageAddress() {
        launch(.waiting)
        XCTAssertTrue(reveal(element("add.qr")).exists)
        assertNowhere(element("add.page"))
    }

    func testNothingElseOffersToAddADevice() {
        launch(.sharing)
        assertNowhere(element("add.device"), element("add.failed"), element("devices.manage"), element("status.howToConnect"),
                      app.buttons["Add a device"])
    }
}
