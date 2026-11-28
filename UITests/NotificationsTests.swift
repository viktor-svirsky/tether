import XCTest

/// The Settings sheet behind the gear: its Notifications page (M6), the When to stop menus and About,
/// and one notice posted in the background. Its Help section is in SettingsHelpTests.
/// When to post is covered by the unit tests (NotifierTests), since a demo launch connects no device.
final class NotificationsTests: TetherUITestCase {
    static let kinds = ["connected", "disconnected", "sharingStopped", "idleStopped", "lowBattery", "limit", "closed", "expiring"]

    private func toggle(_ kind: String) -> XCUIElement {
        app.switches["notices.\(kind)"].firstMatch
    }

    /// From Settings to the Notifications page. `notificationsScreen` opens on Settings by itself.
    private func openNotifications(_ scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) {
        launch(scenario)
        if scenario == .notificationsScreen {
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), file: file, line: line)
        } else {
            openSettings(file: file, line: line)
        }
        reveal(element("settings.notifications"), file: file, line: line).tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5), "the Notifications page did not open", file: file, line: line)
    }

    /// Back from the Notifications page to Settings.
    private func back() {
        app.navigationBars["Notifications"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "back on Settings")
    }

    /// Allowed: the row counts the switches, and the page has one for each kind, all on, with no
    /// permission rows above them.
    func testTheNotificationsRowCountsTheSwitchesAndOpensThem() {
        launch(.notificationsScreen)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertEqual(reveal(element("settings.notifications")).label, "Notifications, 8 on")
        element("settings.notifications").tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5), "the Notifications page did not open")
        for kind in Self.kinds {
            // Eight switches can run past the screen on a small iPhone.
            XCTAssertTrue(reveal(toggle(kind)).exists, kind)
            XCTAssertEqual(value(of: toggle(kind)), "1", kind)
            XCTAssertTrue(toggle(kind).isEnabled, kind)
        }
        XCTAssertEqual(toggle("connected").label, "A device connects")
        XCTAssertEqual(toggle("closed").label, "iOS stops Tether in the background")
        XCTAssertEqual(toggle("idleStopped").label, "Sharing stops while idle")
        XCTAssertEqual(toggle("lowBattery").label, "Sharing stops at low battery")
        XCTAssertEqual(toggle("expiring").label, "Tether stops opening soon")
        XCTAssertEqual(toggle("limit").label, "A device nears or reaches its limit")
        XCTAssertEqual(label(of: "notices.footer"), "Only while Tether is in the background. While it's open, you see it on screen.")
        assertNowhere(element("notices.allow"), element("notices.denied"))
    }

    /// Settings > When to stop (#76): Never at first, the four choices, and the choice kept.
    func testSharingStopsWhenIdleIsAMenu() throws {
        launch(.sharing)
        openSettings()
        let menu = app.buttons["sharing.idleStop"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(menu.label.contains("Stop sharing when idle"), menu.label)
        XCTAssertTrue(menu.label.contains("After no device is connected for this long."), menu.label)
        XCTAssertTrue(menu.label.contains("Never") || value(of: menu) == "Never", "Never at first: \(menu.label)")
        XCTAssertEqual(showHelp("sharing", "sharing.footer").label, Self.whenToStopHelp)
        try audit()
        menu.tap()
        for choice in ["Never", "After 10 min", "After 30 min", "After 1 hour"] {
            XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 3), choice)
        }
        app.buttons["After 30 min"].tap()
        waitUntilGone(app.buttons["After 1 hour"])
        XCTAssertTrue(menu.label.contains("After 30 min") || value(of: menu) == "After 30 min", "kept: \(menu.label)")
        app.buttons["settings.done"].tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5))
        openSettings()
        XCTAssertTrue(menu.label.contains("After 30 min") || value(of: menu) == "After 30 min", "kept after closing: \(menu.label)")
    }

    /// Settings > When to stop (#311): Never at first, the four choices, the choice kept, and the line under it says when.
    func testSharingStopsAtLowBatteryIsAMenu() throws {
        launch(.sharing)
        openSettings()
        let menu = app.buttons["sharing.lowBattery"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(menu.label.contains("Stop sharing at low battery"), menu.label)
        XCTAssertTrue(menu.label.contains("Only while the iPhone isn't charging."), menu.label)
        XCTAssertTrue(menu.label.contains("Never") || value(of: menu) == "Never", "Never at first: \(menu.label)")
        XCTAssertEqual(showHelp("sharing", "sharing.footer").label, Self.whenToStopHelp)
        try audit()
        menu.tap()
        for choice in ["Never", "At 10%", "At 20%", "At 30%"] {
            XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 3), choice)
        }
        app.buttons["At 20%"].tap()
        waitUntilGone(app.buttons["At 30%"])
        XCTAssertTrue(menu.label.contains("At 20%") || value(of: menu) == "At 20%", "kept: \(menu.label)")
        app.buttons["settings.done"].tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5))
        openSettings()
        XCTAssertTrue(menu.label.contains("At 20%") || value(of: menu) == "At 20%", "kept after closing: \(menu.label)")
    }

    func testTheTitleIsNotAButton() {
        launch(.sharing)
        app.staticTexts["Tether"].firstMatch.tap()
        XCTAssertFalse(app.navigationBars["Settings"].waitForExistence(timeout: 2), "a tap on the title opened Settings")
    }

    static let whenToStopHelp = "Idle means no device is connected and nothing goes through the proxy. Stopping saves battery, and at low battery only happens while the iPhone isn't charging. Open Tether to share again."

    /// Off stays off after the sheet closes, and the row counts one fewer.
    func testASwitchTurnedOffStaysOff() {
        openNotifications(.notificationsScreen)
        flip(reveal(toggle("connected")))
        XCTAssertEqual(value(of: toggle("connected")), "0")
        back()
        XCTAssertEqual(reveal(element("settings.notifications")).label, "Notifications, 7 on")
        app.buttons["settings.done"].tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5), "back on the main screen")
        openSettings()
        reveal(element("settings.notifications")).tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        XCTAssertEqual(value(of: reveal(toggle("connected"))), "0")
        XCTAssertEqual(value(of: reveal(toggle("disconnected"))), "1", "only that one")
    }

    /// Before Tether asked: the row says so, Allow is the page's first row, and the switches keep
    /// their values but can't be changed until iOS allows them.
    func testBeforeTetherAskedTheSwitchesWaitForAllow() {
        launch(.askNotifications)
        openSettings()
        XCTAssertEqual(reveal(element("settings.notifications")).label, "Notifications, Not allowed yet")
        reveal(element("settings.notifications")).tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("notices.allow").isHittable)
        XCTAssertEqual(label(of: "notices.allowFooter"), "Until you allow them, Tether sends none. Tether also offers this on its main screen the first time it has something to tell you.")
        XCTAssertLessThan(element("notices.allow").frame.maxY, reveal(toggle("connected")).frame.minY, "Allow comes first")
        for kind in Self.kinds {
            XCTAssertFalse(reveal(toggle(kind)).isEnabled, kind)
            XCTAssertEqual(value(of: toggle(kind)), "1", "kept: \(kind)")
        }
        flip(toggle("connected"))
        XCTAssertEqual(value(of: toggle("connected")), "1", "a tap does nothing until iOS allows them")
        reveal(element("notices.footer"))
        XCTAssertEqual(label(of: "notices.footer"), "Only while Tether is in the background. While it's open, you see it on screen.")
        assertNowhere(element("notices.denied"))
    }

    func testNotificationsOffInSettingsSaysSoWithTheWayThere() {
        launch(.notificationsOff)
        openSettings()
        XCTAssertEqual(reveal(element("settings.notifications")).label, "Notifications, Off in iOS Settings")
        reveal(element("settings.notifications")).tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        XCTAssertEqual(label(of: "notices.denied"), "Notifications are off for Tether in iOS Settings.")
        XCTAssertTrue(element("notices.settings").isHittable)
        XCTAssertFalse(reveal(toggle("connected")).isEnabled)
        assertNowhere(element("notices.allow"))
    }

    /// The real notification center: the question on screen (Allow, the first time on this simulator),
    /// then leaving the screen shows the notice as a banner.
    func testAskedOnScreenThenLeavingTheScreenPostsANotice() {
        launch(.notifying)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        waitUntilNotificationsAreAllowed(springboard)
        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "iPad connected")).firstMatch
        // Usually a few seconds. Under the full suite, iOS can take 9 s to move Tether to the background,
        // then up to 10 s more in the notification's own steps (its Intelligence step times out at 10 s).
        XCTAssertTrue(banner.waitForExistence(timeout: 60), "no notification")
    }

    /// Waits on the Notifications page until iOS has told Tether it may notify, tapping Allow if the
    /// simulator asks. Allow notifications shows there until iOS answers.
    /// A simulator just cloned for parallel testing doesn't answer at first: in one failing run its
    /// SpringBoard started the notification server 97 s after booting, and until then every call to
    /// the notification center waited, the one Tether makes in the background too. Its notice posted
    /// only after the test had given up (#116).
    private func waitUntilNotificationsAreAllowed(_ springboard: XCUIApplication, timeout: TimeInterval = 180) {
        // The question can come up at any moment after launch and cover the gear. A tap it blocks
        // runs this first, so it's answered on the way to Settings too, not only in the loop below.
        let monitor = addUIInterruptionMonitor(withDescription: "notification permission") { alert in
            let allow = alert.buttons["Allow"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        defer { removeUIInterruptionMonitor(monitor) }
        openSettings()
        reveal(element("settings.notifications")).tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5), "the Notifications page did not open")
        // A switch, so the page has drawn its list before the button can count as gone.
        XCTAssertTrue(toggle("connected").waitForExistence(timeout: 5))
        let allow = springboard.buttons["Allow"]
        let deadline = Date().addingTimeInterval(timeout)
        while element("notices.allow").exists {
            if allow.exists { allow.tap() }
            guard Date() < deadline else { return XCTFail("iOS didn't say whether Tether may notify in \(Int(timeout)) s") }
            _ = allow.waitForExistence(timeout: 1)
        }
        XCTAssertFalse(element("notices.denied").exists, "Notifications for Tether are off in the simulator's Settings")
        XCTAssertTrue(toggle("connected").isEnabled, "allowed, the switches can change")
        back()
        app.buttons["settings.done"].tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5), "back on the main screen")
    }

    // MARK: accessibility

    /// The Notifications page before Tether asked (the Allow button), with notifications off in
    /// Settings, and allowed, in both appearances.
    func testTheNotificationsPagePassesTheAccessibilityAuditInBothAppearances() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            for (scenario, id) in [(Scenario.askNotifications, "notices.allow"), (.notificationsOff, "notices.denied"),
                                   (.notificationsScreen, "notices.connected")] {
                openNotifications(scenario)
                XCTAssertTrue(element(id).exists, id)
                if scenario == .notificationsScreen {
                    try audit()
                } else {
                    // The switches are dimmed until iOS allows them, and inactive controls are
                    // exempt from contrast (WCAG 1.4.3): contrast for the permission rows only.
                    for prefix in scenario == .askNotifications ? ["notices.allow"] : ["notices.denied", "notices.settings"] {
                        try audit(only: prefix)
                    }
                    try audit(types: structuralAudit)
                }
                app.terminate()
            }
        }
    }

    /// The title, the gear and the status card, the top of the restyled main screen, in both appearances.
    func testTheTopOfTheMainScreenPassesTheAccessibilityAuditInBothAppearances() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            launch(.sharing)
            XCTAssertTrue(element("settings.open").isHittable)
            try audit()
            app.terminate()
        }
    }

    /// The screenshot's scenario opens on the Settings sheet, with every notification on.
    func testTheScreenshotScenarioOpensOnTheSettingsSheet() {
        launch(.notificationsScreen)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertEqual(reveal(element("settings.notifications")).label, "Notifications, 8 on")
    }

    func testAboutSaysTheVersionAndLinksTheSource() {
        launch(.sharing)
        openSettings()
        let version = reveal(element("settings.version")).label
        XCTAssertNotNil(version.range(of: #"^Version\D*\d+(\.\d+)+ \(\d+\)$"#, options: .regularExpression), version)
        XCTAssertTrue(reveal(element("settings.help")).isHittable)
        assertNowhere(element("settings.expires"), message: "no date to show: a demo build has none")
    }

    func testAboutSaysWhenThisBuildStopsOpening() {
        launch(.expiring)
        openSettings()
        let expires = reveal(element("settings.expires")).label
        XCTAssertNotNil(expires.range(of: #"^Stops opening.*\d"#, options: .regularExpression), expires)
        XCTAssertEqual(reveal(element("settings.expiresFooter")).label,
                       "With a free Apple ID, Tether stops opening after 7 days. Refresh it in SideStore or AltStore, or reinstall it, before then.")
    }
}
