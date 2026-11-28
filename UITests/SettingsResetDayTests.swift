import XCTest

/// Settings > Sharing: the day the data counts and limits start over (#187), and how the screens
/// name the count then. The periods themselves are covered by the unit tests (MonthlyUsageTests,
/// LimitTests), and the words by FormatTests.
final class SettingsResetDayTests: TetherUITestCase {
    static let footer = "Idle means no device is connected and nothing goes through the proxy. Stopping saves battery, and at low battery only happens while the iPhone isn't charging. Open Tether to share again. Data counts start again on this day each month. Set it to your plan's billing day so the limits match your carrier."
    /// Starts the demo on the 15th. Read through the launch arguments, so the menu can't change it.
    private let onThe15th = ["-usage.resetDay", "15"]
    private let accessibilityXL = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]

    private func says(_ menu: XCUIElement, _ choice: String) -> Bool {
        menu.label.contains(choice) || value(of: menu) == choice
    }

    /// The 1st at first, the first choices in order, and the choice kept. The demo's day is
    /// October 17, so a change to the 15th ends the running count on November 15 (see
    /// MonthlyUsage.setResetDay), and the screens say so as soon as Settings closes.
    func testDataCountsStartOnIsAMenuKeptAfterClosing() throws {
        launch(.sharing)
        openSettings()
        let menu = app.buttons["sharing.resetDay"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(menu.label.contains("Data counts start on"), menu.label)
        XCTAssertTrue(says(menu, "1st"), "the 1st at first: \(menu.label)")
        XCTAssertEqual(showHelp("sharing", "sharing.footer").label, Self.footer)
        add(screenshot("settings-reset-day"))
        try audit()
        menu.tap()
        for choice in ["1st", "2nd", "3rd", "4th"] {
            XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 3), choice)
        }
        // A menu this long scrolls, and a drag in a menu picks what it ends on, so the test stays with
        // the choices in view. Last day has its own test below.
        app.buttons["15th"].tap()
        waitUntilGone(app.buttons["2nd"])
        XCTAssertTrue(says(menu, "15th"), "kept: \(menu.label)")
        app.buttons["settings.done"].tap()
        let ipad = reveal(element("device.iPad"))
        XCTAssertTrue(ipad.label.contains("3.12 GB since Oct 1"), "not this month any more: \(ipad.label)")
        XCTAssertFalse(ipad.label.contains("since Oct 15"), "the running count started on October 1: \(ipad.label)")
        openDevice("iPad")
        let meter = reveal(element("device.thisMonth")).label
        XCTAssertTrue(meter.contains("3.12 GB of 10 GB since Oct 1") && meter.contains("Resets on November 15"), meter)
        XCTAssertFalse(meter.contains("since Oct 15"), meter)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openSettings()
        XCTAssertTrue(says(app.buttons["sharing.resetDay"].firstMatch, "15th"), "kept after closing: \(menu.label)")
    }

    /// Saved as 31, the last day shows as Last day, and the count runs from the last day of the
    /// month before: September 30 for the demo's October 17.
    func testLastDayIs31() {
        launch(.sharing, arguments: ["-usage.resetDay", "31"])
        XCTAssertTrue(reveal(element("device.iPad")).label.contains("3.12 GB since Sep 30"))
        openSettings()
        let menu = app.buttons["sharing.resetDay"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(says(menu, "Last day"), menu.label)
    }

    /// On the 15th, a device's row and screen count since October 15, and the limit's words name
    /// November 15. The screen passes the audit.
    func testAnotherDaySaysSinceItOnTheDevice() throws {
        launch(.sharing, arguments: onThe15th)
        let ipad = reveal(element("device.iPad"))
        XCTAssertTrue(ipad.label.contains("3.12 GB since Oct 15"), ipad.label)
        XCTAssertTrue(reveal(element("device.Windows PC")).label.contains("Nothing used since Oct 15"))
        openDevice("iPad")
        let meter = reveal(element("device.thisMonth")).label
        XCTAssertTrue(meter.contains("3.12 GB of 10 GB since Oct 15") && meter.contains("Resets on November 15"), meter)
        XCTAssertFalse(meter.contains("this month"), meter)
        let lastPeriod = reveal(element("device.lastMonth")).label
        XCTAssertTrue(lastPeriod.contains("Sep 15 to Oct 14") && !lastPeriod.contains("Last month"), lastPeriod)
        add(screenshot("device-day-15"))
        let footer = reveal(element("device.limitFooter")).label
        XCTAssertTrue(footer.contains("until the count resets on November 15"), footer)
        try audit(only: "device.")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openDevice("Windows PC")
        XCTAssertEqual(reveal(element("device.thisMonth")).label, "Nothing used since Oct 15")
    }

    /// The same at an accessibility text size: the words wrap and stay whole.
    func testAnotherDayAtALargeTextSize() {
        launch(.sharing, arguments: onThe15th + accessibilityXL)
        reveal(element("device.iPad"), maxSwipes: 30).tap()
        XCTAssertTrue(app.navigationBars["iPad"].waitForExistence(timeout: 5))
        let meter = reveal(element("device.thisMonth"), maxSwipes: 30).label
        XCTAssertTrue(meter.contains("since Oct 15") && meter.contains("Resets on November 15"), meter)
        XCTAssertTrue(reveal(element("device.lastMonth"), maxSwipes: 30).label.contains("Sep 15 to Oct 14"))
        reveal(element("device.thisMonth"), maxSwipes: 30)
        add(screenshot("device-day-15-large-text"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // At this size the gear's row scrolls away with the list.
        reveal(element("settings.open"), maxSwipes: 30).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let menu = reveal(app.buttons["sharing.resetDay"].firstMatch, maxSwipes: 30)
        XCTAssertTrue(says(menu, "15th"), menu.label)
        add(screenshot("settings-reset-day-large-text"))
    }

    private func screenshot(_ name: String) -> XCTAttachment {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        return shot
    }
}
