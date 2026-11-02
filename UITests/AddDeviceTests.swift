import XCTest

/// Adding a device: the button on the main screen and the sheet with its three steps.
final class AddDeviceTests: TetherUITestCase {
    func testBeforeAnyDeviceTheMainScreenOffersToAddOne() {
        launch(.waiting)
        XCTAssertEqual(reveal(element("add.open")).label, "Add a device")
        assertNowhere(element("add.qr"), message: "the code is in the sheet")
    }

    func testOnceADeviceExistsTheButtonSaysAddAnotherDevice() {
        launch(.sharing)
        XCTAssertEqual(reveal(element("add.open")).label, "Add another device")
    }

    /// With the hotspot off nothing is ticked, and the code is there anyway: a device can scan it first.
    func testTheSheetShowsTheStepsAndTheCode() {
        launch(.waiting)
        openAddDevice()
        XCTAssertEqual(label(of: "add.step1.mark"), "Step 1 of 3")
        XCTAssertEqual(label(of: "add.step2.mark"), "Step 2 of 3")
        XCTAssertEqual(label(of: "add.step3.mark"), "Step 3 of 3")
        XCTAssertEqual(label(of: "add.hotspotPath"), "Settings > Personal Hotspot > Allow Others to Join")
        XCTAssertEqual(element("add.qr").label, "QR code for the next device")
        XCTAssertEqual(reveal(element("add.scan")).label,
                       "iPhone or iPad: in WireGuard, tap + > Create from QR code. This ticks off once its tunnel is on.")
        XCTAssertEqual(reveal(element("add.laptop")).label,
                       "Mac, Windows or Linux: share the file, or open http://172.20.10.1 in its browser while Tether is on screen.")
        XCTAssertTrue(reveal(element("add.share")).label.contains("Share file"))
        assertNowhere(element("add.result"), element("add.done"), element("add.joinFirst"))
    }

    func testWithTheHotspotOnTheFirstStepIsTicked() {
        launch(.noDevices)
        openAddDevice()
        XCTAssertEqual(label(of: "add.step1.mark"), "Done")
        XCTAssertTrue(text(containing: "The hotspot is on.").exists)
        XCTAssertEqual(label(of: "add.step2.mark"), "Step 2 of 3")
        assertNowhere(element("add.hotspotPath"))
    }

    func testTheSheetCloses() {
        launch(.sharing)
        openAddDevice()
        element("add.close").tap()
        waitUntilGone(element("add.step1"))
        XCTAssertTrue(element("add.open").exists)
    }

    func testTheScreenshotScenarioOpensOnTheSheet() {
        launch(.addDeviceScreen)
        XCTAssertTrue(element("add.qr").waitForExistence(timeout: 5))
        XCTAssertEqual(label(of: "add.step1.mark"), "Done")
    }

    /// Once the code's device is listed, the code goes and the last step waits for its tunnel.
    func testADownloadedCodeWaitsForTheTunnel() {
        launch(.addDeviceWaiting)
        XCTAssertTrue(element("add.step1").waitForExistence(timeout: 5))
        XCTAssertEqual(label(of: "add.step2.mark"), "Done")
        XCTAssertTrue(text(containing: "Windows PC has its config.").exists)
        XCTAssertEqual(label(of: "add.step3.mark"), "Waiting")
        XCTAssertEqual(label(of: "add.result"), "Waiting for Windows PC to connect.")
        assertNowhere(element("add.qr"), element("add.share"), element("add.done"))
    }

    func testOnceItConnectsDoneClosesTheSheet() {
        launch(.addDeviceDone)
        XCTAssertTrue(element("add.step1").waitForExistence(timeout: 5))
        XCTAssertEqual(label(of: "add.step3.mark"), "Done")
        XCTAssertEqual(label(of: "add.result"), "iPad is connected. Rename it in the list.")
        reveal(element("add.done")).tap()
        waitUntilGone(element("add.step1"))
        XCTAssertTrue(reveal(element("device.iPad")).exists)
    }

    /// The devices it has still connect, so it's sharing. Only the next device has to wait.
    func testAQRCodeThatCantBeSavedSaysWhyAndOffersNoButton() {
        launch(.qrCodeUnsaved)
        XCTAssertEqual(label(of: "status.title"), "Sharing")
        XCTAssertEqual(reveal(staticText("add.problem")).label, "The code for the next device can't be saved: Keychain error -34018.")
        XCTAssertTrue(sectionHeader("ADD ANOTHER DEVICE").exists)
        XCTAssertTrue(reveal(element("device.iPad")).exists)
        assertNowhere(element("add.open"), element("wireguard.problem"))
    }

    func testNothingElseOffersToAddADevice() {
        launch(.sharing)
        assertNowhere(element("add.device"), element("add.failed"), element("devices.manage"), element("status.howToConnect"),
                      element("add.qr"))
    }
}
