import XCTest

/// The Settings sheet behind the gear (the notification switches and About), and one notice posted in the background.
/// When to post is covered by the unit tests (NotifierTests), since a demo launch connects no device.
final class NotificationsTests: TetherUITestCase {
    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    private func openSettings() {
        element("settings.open").tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "the Settings sheet did not open")
    }

    private func toggle(_ kind: String) -> XCUIElement {
        app.switches["notices.\(kind)"].firstMatch
    }

    func testTheGearOpensASwitchForEachKindAllOn() {
        launch(.sharing)
        openSettings()
        for kind in ["connected", "disconnected", "sharingStopped", "expiring"] {
            XCTAssertTrue(toggle(kind).waitForExistence(timeout: 5), kind)
            XCTAssertEqual(value(of: toggle(kind)), "1", kind)
        }
        XCTAssertEqual(toggle("connected").label, "A device connects")
        XCTAssertEqual(toggle("expiring").label, "Tether stops opening soon")
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
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "no notification. Notifications for Tether may be off in the simulator's Settings")
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
