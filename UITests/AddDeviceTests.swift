import XCTest

/// Adding a device: the button on the main screen and the sheet with its three steps on a line.
final class AddDeviceTests: TetherUITestCase {
    /// How long the code and the shared file work, under each.
    static let windowNote = "Works while this screen is open, and for 10 minutes after you close it or leave Tether."

    func testBeforeAnyDeviceTheMainScreenOffersToAddOne() {
        launch(.waiting)
        XCTAssertEqual(reveal(element("add.open")).label, "Add a device")
        XCTAssertEqual(label(of: "add.hint"), "An iPad, a laptop or a travel router. It takes a minute.")
        assertNowhere(element("add.qr"), message: "the code is in the sheet")
    }

    func testOnceADeviceExistsTheButtonSaysAddAnotherDevice() {
        launch(.sharing)
        XCTAssertEqual(reveal(element("add.open")).label, "Add another device")
        assertNowhere(element("add.hint"))
    }

    /// With the hotspot off or empty nothing is ticked, and a device can scan the code first.
    func testTheSheetShowsTheStepsAndTheCode() {
        launch(.waiting)
        openAddDevice()
        XCTAssertEqual(label(of: "add.install"), "Install the free WireGuard app on the other device: App Store, Google Play, or wireguard.com/install.")
        // Each step is one stop for VoiceOver: its number, its title and how far it is (#175).
        XCTAssertEqual(label(of: "add.step1"), "Step 1 of 3, Join this iPhone's hotspot")
        XCTAssertEqual(value(of: element("add.step1")), "Current")
        XCTAssertEqual(label(of: "add.hotspotHint"), "Turn on Personal Hotspot, then join it from the other device. Tether starts when the first device joins.")
        XCTAssertEqual(label(of: "add.step2"), "Step 2 of 3, Give it the config")
        XCTAssertEqual(value(of: element("add.step2")), "")
        XCTAssertEqual(label(of: "add.step3"), "Step 3 of 3, Turn its tunnel on")
        XCTAssertEqual(value(of: element("add.step3")), "")
        XCTAssertEqual(label(of: "add.hotspotPath"), "Settings > Personal Hotspot > Allow Others to Join")
        XCTAssertTrue(app.segmentedControls.buttons["iPhone or iPad"].isSelected, "a phone or tablet first")
        XCTAssertEqual(element("add.qr").label, "QR code for the next device")
        XCTAssertEqual(reveal(element("add.scan")).label, "In WireGuard, tap + and Create from QR code.")
        // It stops working later (#29), and nothing else would say so (#91).
        XCTAssertEqual(reveal(element("add.codeWindow")).label, Self.windowNote)
        assertNowhere(element("add.address"), element("add.share"), element("add.result"), element("add.done"), element("add.joinFirst"))
    }

    /// A computer gets the page's address as text, a button that copies it, and the file to share. Not a
    /// link: a tap would open the page on this iPhone (#184).
    func testAComputerGetsTheAddressAndTheFile() {
        launch(.waiting)
        openAddDevice()
        app.segmentedControls.buttons["Computer"].tap()
        XCTAssertEqual(reveal(element("add.laptop")).label, "Open this in the computer's browser while Tether is on screen:")
        let address = reveal(element("add.address"))
        XCTAssertEqual(address.label, "Page address")
        XCTAssertEqual(address.value as? String, "http://172.20.10.1")
        XCTAssertEqual(address.elementType, .staticText, "not a link")
        XCTAssertEqual(element("add.copy").label, "Copy the address")
        XCTAssertEqual(value(of: element("add.copy")), "")
        XCTAssertTrue(reveal(element("add.share")).label.contains("Share the file"))
        XCTAssertEqual(reveal(element("add.airdrop")).label, "AirDrop it to a Mac, then open it in WireGuard.")
        // The file stops working like the code. A download from the page is listed at once, so it doesn't.
        XCTAssertEqual(reveal(element("add.fileWindow")).label, Self.windowNote)
        assertNowhere(element("add.qr"), element("add.codeWindow"), element("add.macLabel"), element("add.addressMac"), element("add.ipv6"),
                      message: "172.20.10.1 is all there is on a usual carrier")
    }

    /// On a carrier that gives the iPhone IPv6 only, a Windows PC still takes IPv4 on the hotspot and
    /// reaches 172.20.10.1, while a Mac takes none and needs the IPv6 address (#98), with IPv6 on for
    /// that network (#94). Both addresses show, 172.20.10.1 first.
    func testOnAnIPv6CarrierAMacGetsItsOwnAddress() throws {
        launch(.addDeviceComputerIPv6)
        XCTAssertEqual(reveal(element("add.address")).value as? String, "http://172.20.10.1")
        XCTAssertEqual(reveal(element("add.macLabel")).label, "On a Mac, or if that one doesn't open:")
        let mac = reveal(element("add.addressMac"))
        XCTAssertEqual(mac.label, "Page address")
        XCTAssertEqual(mac.value as? String, "http://[2001:db8:9e74:4eaa:459:5cd0:7ec7:f792]")
        XCTAssertEqual(element("add.copyMac").label, "Copy the address")
        XCTAssertEqual(reveal(element("add.ipv6")).label, "If neither opens, turn on IPv6 for the computer's Wi-Fi.")
        try audit(only: "add.")
    }

    /// The address is typed into another device, so all of it shows, also at the largest text size,
    /// where the copy button goes under it (#170). The audit's clipped-text check sees an ellipsis.
    func testTheWholeAddressShowsAtTheLargestTextSize() throws {
        launch(.addDeviceComputerIPv6, arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let mac = reveal(element("add.addressMac"))
        let copy = reveal(element("add.copyMac"))
        // Taller than the screen at this size, so only its width is checked: it wraps instead of running off.
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(mac.frame.minX >= window.minX && mac.frame.maxX <= window.maxX, "\(mac.frame) outside \(window)")
        // Under it, not beside it. The text's frame runs past its last line at this size, so it isn't
        // compared with the button's top.
        XCTAssertLessThan(copy.frame.minX, mac.frame.maxX, "the copy button is under the address, not beside it")
        XCTAssertGreaterThan(copy.frame.minY, mac.frame.midY)
        try audit(types: [.textClipped], only: "add.address")
    }

    /// Copy says it worked for a moment: the icon turns into a tick, and VoiceOver hears "Copied" (#175).
    /// The test reads the button's value, which goes with the tick.
    func testCopyingTheAddressSaysCopied() {
        launch(.addDeviceComputer)
        let copy = reveal(element("add.copy"))
        copy.tap()
        XCTAssertEqual(value(of: copy), "Copied")
        XCTAssertEqual(copy.label, "Copy the address")
        let cleared = expectation(for: NSPredicate(format: "value == ''"), evaluatedWith: copy)
        XCTAssertEqual(XCTWaiter().wait(for: [cleared], timeout: 5), .completed, "it goes back to the copy icon")
    }

    /// At the largest text size a segmented control stays small, so the two kinds are full-width
    /// buttons, one under the other. Each step's mark goes above its text, which gets the whole width
    /// instead of a word or two a line (#176).
    func testAtTheLargestTextSizeTheKindsAreButtonsAndTheStepsUseTheWidth() throws {
        launch(.waiting, arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        reveal(element("add.open"), maxSwipes: 30).tap()
        XCTAssertTrue(element("add.step1").waitForExistence(timeout: 5))
        let install = element("add.install")
        let step1 = reveal(element("add.step1"), maxSwipes: 30)
        XCTAssertLessThan(abs(step1.frame.minX - install.frame.minX), 20, "the title starts at the card's edge, not after the mark")
        XCTAssertEqual(app.segmentedControls.count, 0)
        let phone = reveal(element("add.kind.phone"), maxSwipes: 30)
        XCTAssertTrue(phone.isSelected, "a phone or tablet first")
        XCTAssertEqual(phone.label, "iPhone or iPad")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(phone.frame.width, window.width * 0.6, "full width")
        XCTAssertGreaterThan(phone.frame.height, 60, "it grows with the text")
        let computer = element("add.kind.computer")
        XCTAssertEqual(computer.label, "Computer")
        XCTAssertFalse(computer.isSelected)
        XCTAssertGreaterThanOrEqual(computer.frame.minY, phone.frame.maxY, "under it, not beside it")
        try audit(only: "add.kind")
        reveal(computer, maxSwipes: 30).tap()
        XCTAssertTrue(computer.isSelected)
        XCTAssertTrue(reveal(element("add.address"), maxSwipes: 30).isHittable)
        XCTAssertTrue(reveal(element("add.share"), maxSwipes: 30).label.contains("Share the file"))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Share the file at the largest text size"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testWithADeviceOnTheHotspotTheFirstStepIsTicked() {
        launch(.noDevices)
        openAddDevice()
        XCTAssertEqual(value(of: element("add.step1")), "Done")
        XCTAssertTrue(text(containing: "The hotspot is on. Join it on the new device too.").exists)
        XCTAssertEqual(value(of: element("add.step2")), "Current")
        assertNowhere(element("add.hotspotPath"), element("add.hotspotHint"))
    }

    func testTheSheetCloses() {
        launch(.sharing)
        openAddDevice()
        element("add.close").tap()
        waitUntilGone(element("add.step1"))
        XCTAssertTrue(element("add.open").exists)
    }

    func testTheScreenshotScenariosOpenOnTheSheet() {
        launch(.addDeviceScreen)
        XCTAssertTrue(element("add.qr").waitForExistence(timeout: 5))
        XCTAssertEqual(value(of: element("add.step1")), "Done")
        app.terminate()
        launch(.addDeviceComputer)
        XCTAssertTrue(element("add.address").waitForExistence(timeout: 5))
    }

    /// Once the code's device is listed, the code goes and the last step waits for its tunnel.
    func testADownloadedCodeWaitsForTheTunnel() {
        launch(.addDeviceWaiting)
        XCTAssertTrue(element("add.step1").waitForExistence(timeout: 5))
        XCTAssertEqual(value(of: element("add.step2")), "Done")
        XCTAssertTrue(text(containing: "Windows PC has it").exists)
        XCTAssertEqual(value(of: element("add.step3")), "Waiting")
        XCTAssertTrue(text(containing: "Waiting for Windows PC to connect").exists)
        assertNowhere(element("add.qr"), element("add.kind"), element("add.done"), element("add.result"))
    }

    func testOnceItConnectsDoneClosesTheSheet() {
        launch(.addDeviceDone)
        XCTAssertTrue(element("add.step1").waitForExistence(timeout: 5))
        XCTAssertEqual(value(of: element("add.step3")), "Done")
        XCTAssertEqual(label(of: "add.result"), "iPad is connected")
        element("add.done").tap()
        waitUntilGone(element("add.step1"))
        XCTAssertTrue(reveal(element("device.iPad")).exists)
    }

    /// The devices it has still connect, so it's sharing. Only the next device has to wait.
    func testAQRCodeThatCantBeSavedSaysWhyAndOffersNoButton() {
        launch(.qrCodeUnsaved)
        XCTAssertEqual(label(of: "status.title"), "Sharing")
        XCTAssertEqual(reveal(staticText("add.problem")).label, "The code for the next device can't be saved. Tether tries again by itself. If this stays, share the log from Settings.")
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
