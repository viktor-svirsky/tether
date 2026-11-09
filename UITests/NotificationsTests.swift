import XCTest

/// The Settings sheet behind the gear (the notification switches and About), and one notice posted in the background.
/// Its Help section is in SettingsHelpTests.
/// When to post is covered by the unit tests (NotifierTests), since a demo launch connects no device.
final class NotificationsTests: TetherUITestCase {
    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    private func toggle(_ kind: String) -> XCUIElement {
        app.switches["notices.\(kind)"].firstMatch
    }

    func testTheGearOpensASwitchForEachKindAllOn() {
        launch(.sharing)
        openSettings()
        for kind in ["connected", "disconnected", "sharingStopped", "idleStopped", "limit", "closed", "expiring"] {
            // Seven switches run past the screen, under New devices.
            XCTAssertTrue(reveal(toggle(kind)).exists, kind)
            XCTAssertEqual(value(of: toggle(kind)), "1", kind)
        }
        XCTAssertEqual(toggle("connected").label, "A device connects")
        XCTAssertEqual(toggle("closed").label, "iOS stops Tether in the background")
        XCTAssertEqual(toggle("idleStopped").label, "Sharing stops while idle")
        XCTAssertEqual(toggle("expiring").label, "Tether stops opening soon")
        XCTAssertEqual(toggle("limit").label, "A device nears or reaches its limit")
    }

    /// Settings > Sharing (#76): Never at first, the four choices, and the choice kept.
    func testSharingStopsWhenIdleIsAMenu() throws {
        launch(.sharing)
        openSettings()
        let menu = app.buttons["sharing.idleStop"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(menu.label.contains("Stop sharing when idle"), menu.label)
        XCTAssertTrue(menu.label.contains("Never") || value(of: menu) == "Never", "Never at first: \(menu.label)")
        XCTAssertEqual(label(of: "sharing.footer"), "Idle means no device is connected. Stopping saves battery. Open Tether to share again.")
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

    func testTheTitleIsNotAButton() {
        launch(.sharing)
        app.staticTexts["Tether"].firstMatch.tap()
        XCTAssertFalse(app.navigationBars["Settings"].waitForExistence(timeout: 2), "a tap on the title opened Settings")
    }

    func testASwitchTurnedOffStaysOff() {
        launch(.sharing)
        openSettings()
        toggle("connected").switches.firstMatch.tap()
        XCTAssertEqual(value(of: toggle("connected")), "0")
        app.buttons["settings.done"].tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5), "back on the main screen")
        openSettings()
        XCTAssertEqual(value(of: toggle("connected")), "0")
        XCTAssertEqual(value(of: toggle("disconnected")), "1", "only that one")
    }

    func testBeforeTetherAskedThereIsAButtonToAllow() {
        launch(.sharing)
        openSettings()
        XCTAssertTrue(element("notices.allow").waitForExistence(timeout: 5))
        reveal(element("notices.footer")) // below New devices
        XCTAssertEqual(label(of: "notices.footer"), "Only while Tether is in the background. On screen, the screen shows it.")
        assertNowhere(element("notices.denied"))
    }

    func testNotificationsOffInSettingsSaysSoWithTheWayThere() {
        launch(.notificationsOff)
        openSettings()
        XCTAssertEqual(label(of: "notices.denied"), "Notifications are off for Tether in iOS Settings.")
        XCTAssertTrue(element("notices.settings").isHittable)
        assertNowhere(element("notices.allow"))
    }

    /// The real notification center: the question on screen (Allow, the first time on this simulator),
    /// then leaving the screen shows the notice as a banner.
    func testAskedOnScreenThenLeavingTheScreenPostsANotice() {
        launch(.notifying)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "iPad connected")).firstMatch
        // Usually a few seconds. Under the full suite, iOS can take 9 s to move Tether to the background,
        // then up to 10 s more in the notification's own steps (its Intelligence step times out at 10 s).
        XCTAssertTrue(banner.waitForExistence(timeout: 60), "no notification. Notifications for Tether may be off in the simulator's Settings")
    }

    // MARK: accessibility

    /// Before Tether asked (the Allow button) and with notifications off in Settings, in both appearances.
    func testTheNotificationsScreenPassesTheAccessibilityAuditInBothAppearances() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            for (scenario, id) in [(Scenario.sharing, "notices.allow"), (.notificationsOff, "notices.denied")] {
                launch(scenario)
                openSettings()
                XCTAssertTrue(element(id).waitForExistence(timeout: 5), id)
                try audit()
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

    /// The screenshot's scenario opens on the Settings sheet, with nothing to allow.
    func testTheScreenshotScenarioOpensOnTheSettingsSheet() {
        launch(.notificationsScreen)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        assertNowhere(element("notices.allow"), element("notices.denied"))
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
    }
}
