import XCTest

/// The Notifications screen at the bottom of the main screen, and one notice posted in the background.
/// When to post is covered by the unit tests (NotifierTests), since a demo launch connects no device.
final class NotificationsTests: TetherUITestCase {
    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    private func openNotifications() {
        reveal(element("notices.open")).tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5), "the Notifications screen did not open")
    }

    private func toggle(_ kind: String) -> XCUIElement {
        app.switches["notices.\(kind)"].firstMatch
    }

    func testTheBottomRowOpensASwitchForEachKindAllOn() {
        launch(.sharing)
        openNotifications()
        for kind in ["connected", "disconnected", "sharingStopped", "expiring"] {
            XCTAssertTrue(toggle(kind).waitForExistence(timeout: 5), kind)
            XCTAssertEqual(value(of: toggle(kind)), "1", kind)
        }
        XCTAssertEqual(toggle("connected").label, "A device connects")
        XCTAssertEqual(toggle("expiring").label, "Tether stops opening soon")
    }

    func testASwitchTurnedOffStaysOff() {
        launch(.sharing)
        openNotifications()
        toggle("connected").switches.firstMatch.tap()
        XCTAssertEqual(value(of: toggle("connected")), "0")
        goBack(to: "Tether")
        openNotifications()
        XCTAssertEqual(value(of: toggle("connected")), "0")
        XCTAssertEqual(value(of: toggle("disconnected")), "1", "only that one")
    }

    func testBeforeTetherAskedThereIsAButtonToAllow() {
        launch(.sharing)
        openNotifications()
        XCTAssertTrue(element("notices.allow").waitForExistence(timeout: 5))
        XCTAssertEqual(label(of: "notices.footer"), "Only while Tether is in the background. On screen, the screen shows it.")
        assertNowhere(element("notices.denied"))
    }

    func testNotificationsOffInSettingsSaysSoWithTheWayThere() {
        launch(.notificationsOff)
        openNotifications()
        XCTAssertEqual(label(of: "notices.denied"), "Notifications are off for Tether in Settings.")
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
                openNotifications()
                XCTAssertTrue(element(id).waitForExistence(timeout: 5), id)
                try audit()
                app.terminate()
            }
        }
    }

    func testTheNotificationsRowPassesTheStructuralAudit() throws {
        launch(.sharing)
        reveal(element("notices.open"))
        try audit(types: structuralAudit)
    }

    /// The screenshot's scenario opens on the Notifications screen, with nothing to allow.
    func testTheScreenshotScenarioOpensOnTheNotificationsScreen() {
        launch(.notificationsScreen)
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        assertNowhere(element("notices.allow"), element("notices.denied"))
    }
}
