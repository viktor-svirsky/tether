import XCTest

/// Adding a device: the button on the main screen, the sheet's first question, the WireGuard way's four
/// steps on a line and the proxy's three.
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

    /// The first question says WireGuard is free and recommended, and the proxy is for a device
    /// that can't take an app (H4).
    func testTheFirstQuestionRecommendsWireGuard() {
        launch(.noDevices)
        openAddDeviceQuestion()
        XCTAssertEqual(label(of: "add.question"), "Can you install an app on the other device?")
        XCTAssertEqual(label(of: "add.way.wireGuard"),
                       "Yes, install WireGuard, Recommended. The app is free. Everything on it goes through Tether, games and calls too.")
        XCTAssertEqual(label(of: "add.way.proxy"),
                       "No, use the proxy, No app needed. For a TV, a console or a work laptop. Most apps go through Tether, some don't.")
        assertNowhere(element("add.wayHint"), message: "said in the proxy's answer now")
    }

    /// With the hotspot off or empty nothing is ticked, and a device can scan the code first. Join
    /// comes first: the hotspot gives the device the internet to install WireGuard (M12).
    func testTheSheetShowsTheStepsAndTheCode() {
        launch(.waiting)
        openAddDevice()
        // Each step is one stop for VoiceOver: its number, its title and how far it is (#175).
        XCTAssertEqual(label(of: "add.step1"), "Step 1 of 4, Join this iPhone's hotspot")
        XCTAssertEqual(value(of: element("add.step1")), "Current")
        XCTAssertEqual(label(of: "add.hotspotHint"), "Turn on Personal Hotspot, then join it from the other device. Tether starts when the first device joins.")
        XCTAssertEqual(label(of: "add.step2"), "Step 2 of 4, Install WireGuard on it")
        XCTAssertEqual(value(of: element("add.step2")), "")
        XCTAssertEqual(label(of: "add.install"), "The app is free: App Store, Google Play, or wireguard.com/install.")
        XCTAssertEqual(label(of: "add.step3"), "Step 3 of 4, Scan the code with WireGuard")
        XCTAssertEqual(value(of: element("add.step3")), "")
        XCTAssertEqual(reveal(element("add.step4")).label, "Step 4 of 4, Turn it on in WireGuard")
        XCTAssertEqual(value(of: element("add.step4")), "")
        XCTAssertTrue(text(containing: "In WireGuard, turn on the tunnel you just added. This ticks off by itself when it connects.").exists)
        XCTAssertEqual(label(of: "add.hotspotPath"), Copy.hotspotPath)
        XCTAssertTrue(app.segmentedControls.buttons["Phone or tablet"].isSelected, "a phone or tablet first")
        XCTAssertTrue(app.segmentedControls.buttons["Computer or router"].exists)
        XCTAssertEqual(element("add.qr").label, "QR code for the next device")
        // The iOS app's wording and the Android app's (#171).
        XCTAssertEqual(reveal(element("add.scan")).label, "In WireGuard, tap + and Create from QR code. On Android, tap + and Scan from QR code.")
        // It stops working later (#29), and nothing else would say so (#91).
        XCTAssertEqual(reveal(element("add.codeWindow")).label, Self.windowNote)
        assertNowhere(element("add.address"), element("add.share"), element("add.result"), element("add.done"), element("add.joinFirst"))
    }

    /// A computer gets the page's address as text, a button that copies it, and the file to share. Not a
    /// link: a tap would open the page on this iPhone (#184). A travel router imports the file (#171).
    func testAComputerOrRouterGetsTheAddressAndTheFile() {
        launch(.waiting)
        openAddDevice()
        app.segmentedControls.buttons["Computer or router"].tap()
        XCTAssertEqual(label(of: "add.step3"), "Step 3 of 4, Get the file into WireGuard")
        XCTAssertEqual(reveal(element("add.laptop")).label, "Open this in the computer's browser while Tether is on screen:")
        let address = reveal(element("add.address"))
        XCTAssertEqual(address.label, "Page address")
        XCTAssertEqual(address.value as? String, "http://172.20.10.1")
        XCTAssertEqual(address.elementType, .staticText, "not a link")
        XCTAssertEqual(element("add.copy").label, "Copy the address")
        XCTAssertEqual(value(of: element("add.copy")), "")
        XCTAssertTrue(reveal(element("add.share")).label.contains("Share the file"))
        XCTAssertEqual(reveal(element("add.airdrop")).label, "AirDrop it to a Mac, then open it in WireGuard.")
        XCTAssertEqual(reveal(element("add.router")).label, "On a travel router, import the file in its VPN settings, under WireGuard.")
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

    /// Copy says it worked for a moment: the icon turns into a tick, the Copied capsule shows at the
    /// bottom like on the other screens (L4), and VoiceOver hears "Copied" (#175). The test reads the
    /// button's value, which goes with the tick.
    func testCopyingTheAddressSaysCopied() {
        // The capsule stays long enough for a busy runner to see it.
        launch(.addDeviceComputer, arguments: ["-diagnostics.copiedShownFor", "60"])
        let copy = reveal(element("add.copy"))
        copy.tap()
        XCTAssertEqual(value(of: copy), "Copied")
        XCTAssertEqual(label(of: "add.copied"), "Copied")
        XCTAssertEqual(copy.label, "Copy the address")
        let cleared = expectation(for: NSPredicate(format: "value == ''"), evaluatedWith: copy)
        XCTAssertEqual(XCTWaiter().wait(for: [cleared], timeout: 10), .completed, "it goes back to the copy icon")
    }

    /// At the largest text size a segmented control stays small, so the two kinds are full-width
    /// buttons, one under the other. Each step's mark goes above its text, which gets the whole width
    /// instead of a word or two a line (#176).
    func testAtTheLargestTextSizeTheKindsAreButtonsAndTheStepsUseTheWidth() throws {
        launch(.waiting, arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openAddDevice(maxSwipes: 30)
        let install = element("add.install")
        let step1 = reveal(element("add.step1"), maxSwipes: 30)
        XCTAssertLessThan(abs(step1.frame.minX - install.frame.minX), 20, "the title starts at the card's edge, not after the mark")
        XCTAssertEqual(app.segmentedControls.count, 0)
        let phone = reveal(element("add.kind.phone"), maxSwipes: 30)
        XCTAssertTrue(phone.isSelected, "a phone or tablet first")
        XCTAssertEqual(phone.label, "Phone or tablet")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(phone.frame.width, window.width * 0.6, "full width")
        XCTAssertGreaterThan(phone.frame.height, 60, "it grows with the text")
        let computer = element("add.kind.computer")
        XCTAssertEqual(computer.label, "Computer or router")
        XCTAssertFalse(computer.isSelected)
        XCTAssertGreaterThanOrEqual(computer.frame.minY, phone.frame.maxY, "under it, not beside it")
        // Scrolled here, so the audit leaves contrast out (see audit), and the selected button's white
        // text is read from the pixels once it's still, like the other filled buttons.
        try audit(types: structuralAudit, only: "add.kind")
        waitUntilStill(phone)
        let ratio = textContrast(of: phone)
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "Phone or tablet, selected: \(ratio):1")
        waitUntilStill(reveal(computer, maxSwipes: 30)) // a tap while it still scrolls can miss
        computer.tap()
        let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: computer)
        XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 5), .completed, "the tap picks it")
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

    /// The whole walk from the code (#315): the sheet shows the code, a device scans it and connects a
    /// moment later, and the sheet moves on by itself to Connected and the name field.
    func testTheSheetGoesFromTheCodeToConnected() {
        launch(.addDeviceConnects)
        openAddDevice()
        XCTAssertTrue(element("add.qr").waitForExistence(timeout: 5))
        XCTAssertEqual(value(of: element("add.step1")), "Done")
        XCTAssertEqual(value(of: element("add.step3")), "")
        XCTAssertEqual(value(of: element("add.step4")), "")
        XCTAssertFalse(element("add.result").exists, "not connected yet")
        XCTAssertFalse(app.textFields["add.name"].exists)
        XCTAssertTrue(element("add.result").waitForExistence(timeout: 45), "it connects after a moment")
        XCTAssertEqual(label(of: "add.result"), "Connected")
        for step in 2...4 { XCTAssertEqual(value(of: element("add.step\(step)")), "Done", "step \(step)") }
        let field = app.textFields["add.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse((field.value as? String ?? "").isEmpty, "it has the name it got")
        assertNowhere(element("add.qr"))
    }

    /// Once the code's device is listed, the code goes and the last step waits for its tunnel.
    func testADownloadedCodeWaitsForTheTunnel() {
        launch(.addDeviceWaiting)
        XCTAssertTrue(element("add.step1").waitForExistence(timeout: 5))
        XCTAssertEqual(value(of: element("add.step2")), "Done", "the install ticks with the config")
        XCTAssertEqual(value(of: element("add.step3")), "Done")
        XCTAssertTrue(text(containing: "Windows PC has it").exists)
        XCTAssertEqual(value(of: element("add.step4")), "Waiting")
        XCTAssertTrue(text(containing: "Waiting for Windows PC to connect").exists)
        assertNowhere(element("add.qr"), element("add.kind"), element("add.done"), element("add.result"), element("add.name"))
    }

    /// Once it connects, the sheet asks for its name, with the keyboard up and the name it got
    /// selected (#173). Done without typing keeps that name.
    func testOnceItConnectsDoneClosesTheSheet() throws {
        launch(.addDeviceDone)
        XCTAssertTrue(element("add.step1").waitForExistence(timeout: 5))
        XCTAssertEqual(value(of: element("add.step4")), "Done")
        XCTAssertEqual(label(of: "add.result"), "Connected")
        let field = app.textFields["add.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.label, "Name")
        XCTAssertEqual(field.value as? String, "iPad")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard is up for the name")
        assertNowhere(text(containing: "rename it"), message: "it's named here now")
        assertNameBoxAboveDone()
        try audit(only: "add.")
        element("add.done").tap()
        waitUntilGone(element("add.step1"))
        XCTAssertTrue(reveal(element("device.iPad")).exists)
    }

    /// With the keyboard down too, scrolled to the end, the box stays above Done, at the usual and
    /// the largest text size.
    func testTheNameBoxClearsDoneWithTheKeyboardDown() {
        for arguments in [[], ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]] {
            launch(.addDeviceDone, arguments: arguments)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            waitUntilStill(element("add.nameBox"))
            lowerTheKeyboardAndCheckTheBox()
            app.terminate()
        }
    }

    /// A drag lowers the keyboard, then the sheet is scrolled to its end, where the box sits on Done.
    private func lowerTheKeyboardAndCheckTheBox(file: StaticString = #filePath, line: UInt = #line) {
        // In the sheet's upper part, on its scrolling content at every text size. Not on the
        // screen behind it, which has scroll views too.
        let window = app.windows.firstMatch
        func drag(from: CGFloat, to: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
        }
        drag(from: 0.3, to: 0.5)
        waitUntilGone(app.keyboards.firstMatch)
        for _ in 0..<4 { drag(from: 0.6, to: 0.2) }
        waitUntilStill(element("add.nameBox"))
        assertNameBoxAboveDone(file: file, line: line)
    }

    /// The whole box around the name shows, with space above Done: its bottom was under it (#173).
    private func assertNameBoxAboveDone(file: StaticString = #filePath, line: UInt = #line) {
        let box = element("add.nameBox"), done = element("add.done")
        XCTAssertTrue(box.waitForExistence(timeout: 5), file: file, line: line)
        // The sheet may still be scrolling the field above the keyboard, slower on a busy runner, so
        // the box has to end up above Done, not be there at the first look.
        let clear = expectation(for: NSPredicate { _, _ in box.frame.maxY <= done.frame.minY }, evaluatedWith: box)
        XCTAssertEqual(XCTWaiter().wait(for: [clear], timeout: 5), .completed,
                       "the name's box \(box.frame) runs under Done \(done.frame)", file: file, line: line)
        // And it stays there: a late layout pass could move it back under Done after the first clear look.
        let under = expectation(for: NSPredicate { _, _ in box.frame.maxY > done.frame.minY }, evaluatedWith: box)
        under.isInverted = true
        XCTAssertEqual(XCTWaiter().wait(for: [under], timeout: 2), .completed,
                       "the name's box \(box.frame) went back under Done \(done.frame)", file: file, line: line)
    }

    /// What's typed replaces the name, since it's selected, and Done saves it.
    func testANameTypedOnceItConnectsIsSaved() {
        launch(.addDeviceDone)
        let field = app.textFields["add.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        waitUntilStill(field)
        field.typeText("Living room")
        XCTAssertEqual(field.value as? String, "Living room", "the name it had was selected and replaced")
        element("add.done").tap()
        waitUntilGone(element("add.step1"))
        XCTAssertTrue(reveal(element("device.Living room")).exists)
        assertNowhere(element("device.iPad"))
    }

    /// A name that can't be saved says so in the sheet, which stays open with what was typed, to try
    /// again. Closing it keeps the old name, and the device's screen says why.
    func testANameThatCantBeSavedSaysSoAndKeepsTheSheetOpen() {
        launch(.addDeviceDoneUnsaved)
        let field = app.textFields["add.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        waitUntilStill(field)
        field.typeText("Living room")
        element("add.done").tap()
        let problem = staticText("add.nameProblem") // the warning icon carries the identifier too
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        XCTAssertEqual(problem.label, "The new name couldn't be saved.")
        XCTAssertTrue(element("add.step1").exists, "the sheet stays open")
        XCTAssertEqual(field.value as? String, "Living room", "what was typed stays")
        element("add.close").tap()
        waitUntilGone(element("add.step1"))
        openDevice("iPad")
        XCTAssertEqual(staticText("device.problem").label, "The new name couldn't be saved.")
    }

    /// The keyboard's Done saves and closes too.
    func testTheKeyboardsDoneSavesTheName() {
        launch(.addDeviceDone)
        let field = app.textFields["add.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        waitUntilStill(field)
        field.typeText("Kitchen\n")
        waitUntilGone(element("add.step1"))
        XCTAssertTrue(reveal(element("device.Kitchen")).exists)
    }

    /// At the largest text size the name field and Done stay reachable over the keyboard.
    func testTheNameFieldWorksAtTheLargestTextSize() throws {
        launch(.addDeviceDone, arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let field = app.textFields["add.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        waitUntilStill(field)
        XCTAssertTrue(field.isHittable, "the field scrolls above the keyboard")
        XCTAssertTrue(element("add.done").isHittable)
        assertNameBoxAboveDone()
        try audit(types: [.textClipped], only: "add.")
        field.typeText("Den")
        element("add.done").tap()
        waitUntilGone(element("add.step1"))
        XCTAssertTrue(reveal(element("device.Den"), maxSwipes: 30).exists)
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

    // MARK: a new config for a listed device (M1)

    /// From a device's screen, the sheet opens on the WireGuard steps for that device: no question,
    /// and its name in the title. It keeps its name, so the end has no name field.
    func testANewConfigOpensOnTheStepsForThatDevice() throws {
        launch(.replaceDevice)
        XCTAssertTrue(element("add.step1").waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["New config for Windows PC"].exists)
        XCTAssertEqual(label(of: "add.step3"), "Step 3 of 4, Scan the code with WireGuard")
        XCTAssertTrue(element("add.qr").exists, "a new code")
        assertNowhere(element("add.question"), element("add.result"), element("add.name"), element("add.done"))
        XCTAssertTrue(text(containing: "This ticks off by itself").exists, "the old config connecting is not the new one")
        try audit(only: "add.")
        element("add.close").tap()
        waitUntilGone(element("add.step1"))
        XCTAssertTrue(reveal(element("device.Windows PC")).exists, "closing changes nothing")
    }

    // MARK: the proxy (H5, L3)

    /// Opening the proxy's steps turns nothing on: step 2 says it's off, with the button that does.
    func testTheProxyStepsTurnNothingOnByThemselves() {
        launch(.addDeviceProxyOff, screen: "add.proxy.step1")
        XCTAssertEqual(label(of: "add.proxy.step2"), "Step 2 of 3, In its Wi-Fi settings, set the proxy")
        XCTAssertEqual(reveal(element("add.proxy.blocked")).label,
                       "The proxy has no password. While it's on, any device on the hotspot can use it.")
        assertNowhere(element("add.proxy.server"), element("add.proxy.isOn"), element("add.proxy.result"), message: "the proxy is off")
        element("add.close").tap()
        waitUntilGone(element("add.proxy.step1"))
        assertNowhere(element("proxy.row"), message: "looking at the steps didn't turn it on")
    }

    /// Turn on the proxy turns it on there: the server and port show, and the line that says it's on.
    func testTurnOnTheProxyShowsWhereItIs() throws {
        launch(.addDeviceProxyOff, screen: "add.proxy.step1")
        let button = reveal(element("add.proxy.turnOn"))
        XCTAssertEqual(button.label, "Turn on the proxy")
        button.tap()
        XCTAssertTrue(reveal(element("add.proxy.server")).exists)
        XCTAssertEqual(reveal(element("add.proxy.isOn")).label, "The proxy is on. To turn it off, tap Proxy under Devices.")
        XCTAssertEqual(reveal(element("add.proxy.result")).label, "Waiting for the first page")
        assertNowhere(element("add.proxy.turnOn"), element("add.proxy.blocked"))
        try audit(only: "add.proxy")
        element("add.close").tap()
        waitUntilGone(element("add.proxy.step1"))
        XCTAssertTrue(reveal(element("proxy.row")).exists)
    }

    /// Once a page goes through, the steps end like the WireGuard ones, and Done closes them (L3).
    func testTheProxyStepsEndWithDone() {
        launch(.addDeviceProxyWorking, screen: "add.proxy.step1")
        // A new device's page comes through each second, after the first 12 s, see `ProxyProgress`.
        XCTAssertTrue(element("add.proxy.end").waitForExistence(timeout: 25), "it never said Working")
        XCTAssertEqual(label(of: "add.proxy.end"), "Working")
        XCTAssertEqual(reveal(element("add.proxy.endDetail")).label,
                       "It uses this iPhone's data now. Other devices can use the same server and port.")
        element("add.proxy.done").tap()
        waitUntilGone(element("add.proxy.step1"))
        XCTAssertTrue(reveal(element("proxy.row")).exists)
    }

    /// The proxy's copy buttons show the same Copied capsule (L4).
    func testCopyingTheProxyServerShowsCopied() {
        launch(.addDeviceProxy, arguments: ["-diagnostics.copiedShownFor", "60"], screen: "add.proxy.step1")
        reveal(element("add.proxy.copyServer")).tap()
        XCTAssertEqual(label(of: "add.copied"), "Copied")
    }

    func testNothingElseOffersToAddADevice() {
        launch(.sharing)
        assertNowhere(element("add.qr"))
    }
}
