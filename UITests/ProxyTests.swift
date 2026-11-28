import XCTest

/// The HTTP proxy's screens (#78): Add a device's first question, the proxy's steps, its row under
/// Devices and its own screen.
final class ProxyTests: TetherUITestCase {
    private let largest = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    private let note = "Games, calls and apps that skip the proxy still go out as hotspot data. For those, use WireGuard on that device."

    /// From the main screen to the proxy's own screen.
    private func openProxy(maxSwipes: Int = 14) {
        reveal(element("proxy.row"), maxSwipes: maxSwipes).tap()
        XCTAssertTrue(app.navigationBars["Proxy"].waitForExistence(timeout: 5), "the proxy's screen did not open")
    }

    /// From the main screen to Add a device's proxy steps.
    private func openProxySteps(maxSwipes: Int = 14) {
        openAddDeviceQuestion(maxSwipes: maxSwipes)
        reveal(element("add.way.proxy"), maxSwipes: maxSwipes).tap()
        XCTAssertTrue(element("add.proxy.step1").waitForExistence(timeout: 5), "the proxy's steps did not open")
    }

    // MARK: Add a device

    func testAddADeviceAsksAboutWireGuardFirst() {
        launch(.noDevices)
        openAddDeviceQuestion()
        XCTAssertEqual(label(of: "add.question"), "Does the other device have the WireGuard app?")
        XCTAssertEqual(label(of: "add.way.wireGuard"), "Yes, use WireGuard, Everything on it goes through Tether, games and calls too.")
        XCTAssertEqual(label(of: "add.way.proxy"), "No, use the proxy, No app needed. Most apps go through Tether, some don't.")
        XCTAssertEqual(label(of: "add.wayHint"), "Can't install apps? A TV, a console or a work laptop can use the proxy.")
        // Yes opens the WireGuard steps as they were, and Back comes back to the question.
        element("add.way.wireGuard").tap()
        XCTAssertEqual(label(of: "add.step1"), "Step 1 of 3, Join this iPhone's hotspot")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("add.question").waitForExistence(timeout: 5))
        assertNowhere(element("proxy.row"), message: "nothing turned the proxy on")
    }

    func testTheQuestionPassesTheAccessibilityAuditInBothAppearances() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            launch(.sharing)
            openAddDeviceQuestion()
            try audit()
            app.terminate()
        }
    }

    /// The proxy turns on as its steps open: the server and port to type, with Copy, where each kind
    /// of device takes them, and the last step waits for the first page.
    func testTheProxyStepsShowWhereToSetIt() {
        launch(.noDevices)
        openProxySteps()
        XCTAssertEqual(label(of: "add.proxy.step1"), "Step 1 of 3, Join this iPhone's hotspot")
        XCTAssertEqual(value(of: element("add.proxy.step1")), "Done", "the demo's hotspot is on")
        XCTAssertEqual(label(of: "add.proxy.step2"), "Step 2 of 3, In its Wi-Fi settings, set the proxy")
        XCTAssertEqual(value(of: element("add.proxy.step2")), "Current")
        let server = reveal(element("add.proxy.server"))
        XCTAssertEqual(server.label, "Server")
        XCTAssertEqual(server.value as? String, "172.20.10.1")
        XCTAssertEqual(element("add.proxy.copyServer").label, "Copy the server")
        let port = reveal(element("add.proxy.port"))
        XCTAssertEqual(port.label, "Port")
        XCTAssertEqual(port.value as? String, "8118")
        XCTAssertEqual(element("add.proxy.copyPort").label, "Copy the port")
        let places = [
            "iPhone, iPad, Wi-Fi > (i) > Configure Proxy > Manual",
            "Mac, Wi-Fi > Details > Proxies > Web and Secure Web",
            "Windows, Settings > Network & internet > Proxy > Manual proxy setup",
            "Android, Wi-Fi > network > Edit > Proxy > Manual",
            "PlayStation, Switch, TV, In the network settings, Proxy",
        ]
        for (i, place) in places.enumerated() {
            XCTAssertEqual(reveal(element("add.proxy.where\(i + 1)")).label, place)
        }
        XCTAssertEqual(reveal(element("add.proxy.turnOff")).label,
                       "A Mac or a Windows PC keeps the proxy on other networks too. Turn it off on that device when you leave this hotspot.")
        XCTAssertEqual(label(of: "add.proxy.step3"), "Step 3 of 3, Open a page on it")
        XCTAssertEqual(value(of: element("add.proxy.step3")), "Waiting")
        XCTAssertEqual(reveal(element("add.proxy.result")).label, "Waiting for the first page")
        // The sheet's steps are a scroll view, built whole, so these would exist off screen too. Not
        // assertNowhere: its drag to the top closes the sheet.
        for id in ["add.proxy.serverIPv6", "add.proxy.ipv6Label", "add.qr"] {
            XCTAssertFalse(element(id).exists, "\(id): one server on a usual hotspot, and no WireGuard code")
        }
        // It stays on once the sheet closes, with its row under Devices.
        element("add.close").tap()
        waitUntilGone(element("add.proxy.step1"))
        XCTAssertTrue(reveal(element("proxy.row")).label.hasPrefix("Proxy"))
    }

    func testCopyingTheServerSaysCopied() {
        launch(.addDeviceProxy, screen: "add.proxy.step1")
        let copy = reveal(element("add.proxy.copyServer"))
        copy.tap()
        XCTAssertEqual(value(of: copy), "Copied")
    }

    func testTheLastStepSaysWorkingOnceAPageGoesThrough() {
        launch(.addDeviceProxyWorking, screen: "add.proxy.step1")
        // A new device's page comes through each second, see `DemoState.loadAPage`. It counts once
        // the first 12 s, which only learn who is already on the proxy, are over.
        let done = expectation(for: NSPredicate(format: "value == 'Done'"), evaluatedWith: element("add.proxy.step3"))
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 25), .completed, "the last step never ticked")
        XCTAssertEqual(value(of: element("add.proxy.step2")), "Done")
        XCTAssertEqual(reveal(element("add.proxy.result")).label, "Working")
    }

    /// On a hotspot that gives Apple devices IPv6 only, the proxy listens at both addresses, IPv4
    /// first, and the second says it's for them.
    func testOnAnIPv6HotspotBothServersShow() throws {
        launch(.proxyIPv6)
        openProxySteps()
        XCTAssertEqual(reveal(element("add.proxy.server")).value as? String, "172.20.10.1")
        XCTAssertEqual(reveal(element("add.proxy.ipv6Label")).label, "An iPhone, iPad or Mac gets only IPv6 on this hotspot, so on those:")
        let ipv6 = reveal(element("add.proxy.serverIPv6"))
        XCTAssertEqual(ipv6.label, "Server for an iPhone, iPad or Mac")
        XCTAssertEqual(ipv6.value as? String, "2001:db8:9e74:4eaa:459:5cd0:7ec7:f792")
        XCTAssertEqual(element("add.proxy.copyServerIPv6").label, "Copy that server")
        XCTAssertGreaterThan(element("add.proxy.port").frame.minY, ipv6.frame.minY, "the port under both")
        try audit(only: "add.")
    }

    func testTheProxyStepsPassTheAccessibilityAuditInBothAppearances() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            launch(.addDeviceProxy, screen: "add.proxy.step1")
            try audit()
            reveal(element("add.proxy.where5"))
            try audit(only: "add.")
            app.terminate()
        }
    }

    /// At the largest text size every step, the server, its copy button and the places stay whole and
    /// reachable, the copy button under the address.
    func testTheProxyStepsWorkAtTheLargestTextSize() throws {
        launch(.addDeviceProxy, arguments: largest, screen: "add.proxy.step1")
        let server = reveal(element("add.proxy.server"), maxSwipes: 30)
        let copy = reveal(element("add.proxy.copyServer"), maxSwipes: 30)
        XCTAssertGreaterThan(copy.frame.minY, server.frame.midY, "the copy button is under the address")
        XCTAssertTrue(reveal(element("add.proxy.port"), maxSwipes: 30).isHittable)
        XCTAssertTrue(reveal(element("add.proxy.where5"), maxSwipes: 30).isHittable)
        XCTAssertTrue(reveal(element("add.proxy.result"), maxSwipes: 30).isHittable)
        try audit(types: [.textClipped], only: "add.proxy")
    }

    // MARK: The row and the screen

    func testTheRowShowsOpenConnectionsAndTheMonthsData() {
        launch(.proxy)
        let row = reveal(element("proxy.row"))
        XCTAssertTrue(row.label.contains("Proxy"), row.label)
        XCTAssertTrue(row.label.contains("2 connections open"), row.label)
        XCTAssertTrue(row.label.contains("85 MB this month"), row.label)
        XCTAssertGreaterThan(row.frame.minY, element("device.Windows PC").frame.minY, "under the devices")
        // Its open connections count as using Tether, next to the iPad.
        XCTAssertEqual(label(of: "status.headline"), "1 device connected and the proxy in use")
    }

    /// Built like a device's screen (M4): Pause after the status, the data card with last month and
    /// the Data limit, then where it is.
    func testTheProxysScreenShowsWhatADevicesDoes() {
        launch(.proxy)
        openProxy()
        XCTAssertEqual(label(of: "proxy.status"), "Status, 2 connections open")
        let pause = reveal(element("proxy.pause"))
        XCTAssertEqual(pause.label, "Pause")
        XCTAssertGreaterThan(pause.frame.minY, element("proxy.status").frame.maxY, "under the status")
        XCTAssertTrue(app.staticTexts[Copy.proxyPauseFooter].exists)
        XCTAssertTrue(sectionHeader("Data through Tether").exists)
        XCTAssertEqual(label(of: "proxy.thisMonth"), "85 MB this month, 80 MB down, 5 MB up")
        let lastMonth = reveal(element("proxy.lastMonth"))
        XCTAssertTrue(lastMonth.label.contains("Last month") && lastMonth.label.contains("0 bytes"), lastMonth.label)
        let limit = reveal(app.buttons["proxy.limit"].firstMatch)
        XCTAssertTrue(limit.label.contains(Copy.dataLimit) && (limit.label.contains("None") || value(of: limit) == "None"), limit.label)
        XCTAssertEqual(reveal(element("proxy.server")).value as? String, "172.20.10.1")
        XCTAssertEqual(element("proxy.server.copy").label, "Copy the server")
        XCTAssertEqual(reveal(element("proxy.port")).value as? String, "8118")
        XCTAssertEqual(element("proxy.port.copy").label, "Copy the port")
        XCTAssertEqual(reveal(element("proxy.note")).label, note)
        XCTAssertEqual(reveal(element("proxy.off")).label, "Turn off the proxy")
        assertNowhere(element("proxy.serverIPv6"), element("proxy.problem"), element("proxy.statusDetail"), element("proxy.resume"))
    }

    func testOnAnIPv6HotspotItsScreenShowsBothServers() {
        launch(.proxyIPv6)
        openProxy()
        XCTAssertEqual(reveal(element("proxy.server")).value as? String, "172.20.10.1")
        let ipv6 = reveal(element("proxy.serverIPv6"))
        XCTAssertEqual(ipv6.label, "Server for an iPhone, iPad or Mac")
        XCTAssertEqual(ipv6.value as? String, "2001:db8:9e74:4eaa:459:5cd0:7ec7:f792")
    }

    /// Copy says so the one way every screen does (L4): "Copied" at the bottom for a moment.
    func testCopyingTheServerSaysCopiedAtTheBottom() {
        launch(.proxy, arguments: ["-diagnostics.copiedShownFor", "10"])
        openProxy()
        let button = reveal(element("proxy.server.copy"))
        button.tap()
        // The button's tick lasts 2 s, so it's read first.
        XCTAssertEqual(value(of: button), "Copied", "the button keeps its tick")
        let copied = element("proxy.copied")
        XCTAssertTrue(copied.waitForExistence(timeout: 5))
        XCTAssertEqual(copied.label, Copy.copied)
    }

    /// Pause, then how long from its menu, as for a device (M4).
    private func pause(for length: String) {
        let pause = reveal(element("proxy.pause"))
        waitUntilStill(pause)
        pause.tap()
        XCTAssertTrue(app.buttons[length].waitForExistence(timeout: 5), length)
        app.buttons[length].tap()
        waitUntilGone(app.buttons[length])
    }

    func testPauseStopsItAndTheRowSaysSo() {
        launch(.proxy)
        openProxy()
        let place = reveal(element("proxy.pause")).frame.minY
        pause(for: Copy.untilResumed)
        XCTAssertEqual(label(of: "proxy.status"), "Status, Paused")
        XCTAssertEqual(label(of: "proxy.statusDetail"), "Nothing goes through it until you resume it.")
        let resume = element("proxy.resume")
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertEqual(resume.label, "Resume")
        XCTAssertEqual(resume.frame.minY, place, accuracy: 30, "the same spot")
        assertNowhere(element("proxy.pause"), app.staticTexts[Copy.proxyPauseFooter])
        goBack(to: "Tether")
        XCTAssertTrue(reveal(element("proxy.row")).label.contains("Paused"))
    }

    func testResumeLetsItWorkAgain() {
        launch(.proxy)
        openProxy()
        pause(for: Copy.untilResumed)
        reveal(element("proxy.resume")).tap()
        waitUntilGone(element("proxy.resume"))
        XCTAssertEqual(label(of: "proxy.status"), "Status, 2 connections open")
        XCTAssertTrue(reveal(element("proxy.pause")).exists)
    }

    func testAPauseForATimeSaysUntilWhen() {
        launch(.proxy)
        openProxy()
        pause(for: "For 1 hour")
        XCTAssertTrue(label(of: "proxy.status").hasPrefix("Status, Paused until "), label(of: "proxy.status"))
        XCTAssertEqual(label(of: "proxy.statusDetail"), "It works again then, or when you resume it.")
        goBack(to: "Tether")
        XCTAssertTrue(reveal(element("proxy.row")).label.contains("Paused until "))
    }

    func testALimitPickedFromTheMenuShowsWithTheData() {
        launch(.proxy)
        openProxy()
        reveal(app.buttons["proxy.limit"].firstMatch).tap()
        XCTAssertTrue(app.buttons["5 GB"].waitForExistence(timeout: 3))
        app.buttons["5 GB"].tap()
        XCTAssertEqual(label(of: "proxy.thisMonth"), "85 MB of 5 GB this month, 80 MB down, 5 MB up, Resets on November 1")
    }

    /// A typed limit under its 85 MB would pause it at once, so it asks first (L1).
    func testALimitUnderWhatItUsedAsksFirst() {
        launch(.proxy)
        openProxy()
        reveal(app.buttons["proxy.limit"].firstMatch).tap()
        XCTAssertTrue(app.buttons["Other amount"].waitForExistence(timeout: 3))
        app.buttons["Other amount"].tap()
        let typing = app.alerts["Data limit"]
        XCTAssertTrue(typing.waitForExistence(timeout: 3))
        let amount = typing.textFields.firstMatch
        amount.tap()
        amount.typeText("0.05")
        typing.buttons["Set"].tap()
        let alert = app.alerts["Proxy already used 85 MB"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["With a 50 MB limit it pauses now, until the count resets on November 1."].exists)
        alert.buttons["Set the limit and pause it"].tap()
        let paused = expectation(for: NSPredicate(format: "label == 'Status, Paused at its limit'"), evaluatedWith: element("proxy.status"))
        XCTAssertEqual(XCTWaiter().wait(for: [paused], timeout: 10), .completed, label(of: "proxy.status"))
        XCTAssertTrue(reveal(element("proxy.resume")).exists)
    }

    /// Turn off asks first (M4), and says what's kept.
    func testTurningItOffAsksFirst() {
        launch(.proxy)
        openProxy()
        reveal(element("proxy.off")).tap()
        XCTAssertTrue(app.staticTexts[Copy.turnOffProxyTitle].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[Copy.turnOffProxyMessage].exists)
        cancelDialog()
        waitUntilGone(app.buttons[Copy.turnOffProxyButton].firstMatch)
        XCTAssertTrue(app.navigationBars["Proxy"].exists, "still on its screen")
    }

    func testTurningItOffTakesItsRowAway() {
        launch(.proxy)
        openProxy()
        reveal(element("proxy.off")).tap()
        let turnOff = app.buttons[Copy.turnOffProxyButton].firstMatch
        XCTAssertTrue(turnOff.waitForExistence(timeout: 5))
        turnOff.tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5), "back on the main screen")
        assertNowhere(element("proxy.row"))
        XCTAssertTrue(reveal(element("device.iPad")).exists, "the devices stay")
    }

    func testTheProxysScreenPassesTheAccessibilityAuditInBothAppearances() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            launch(.proxy)
            openProxy()
            try audit()
            reveal(element("proxy.off"))
            try audit(only: "proxy.")
            app.terminate()
        }
    }

    /// At the largest text size the row and the screen stay whole and reachable.
    func testTheRowAndTheScreenWorkAtTheLargestTextSize() throws {
        launch(.proxyIPv6, arguments: largest)
        let row = reveal(element("proxy.row"), maxSwipes: 30)
        XCTAssertTrue(row.label.contains("2 connections open"), row.label)
        try audit(types: [.textClipped], only: "proxy.")
        openProxy(maxSwipes: 30)
        for id in ["proxy.status", "proxy.pause", "proxy.thisMonth", "proxy.lastMonth", "proxy.server", "proxy.serverIPv6", "proxy.port", "proxy.note", "proxy.off"] {
            XCTAssertTrue(reveal(element(id), maxSwipes: 30).exists, id)
        }
        let window = app.windows.firstMatch.frame
        let ipv6 = reveal(element("proxy.serverIPv6"), maxSwipes: 30)
        XCTAssertTrue(ipv6.frame.minX >= window.minX && ipv6.frame.maxX <= window.maxX, "\(ipv6.frame) outside \(window)")
        XCTAssertTrue(reveal(element("proxy.pause"), maxSwipes: 30).isHittable)
        try audit(types: [.textClipped], only: "proxy.")
    }
}
