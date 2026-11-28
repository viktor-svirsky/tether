import XCTest

/// The Settings sheet's Help section: the ways to wake Tether without opening it (H2), the log to
/// share for a bug report, and the source link.
/// What the log holds and leaves out is covered by the unit tests (DebugLogTests, LogRedactionTests).
final class SettingsHelpTests: TetherUITestCase {
    static let footer = "The log is a text file of what Tether did lately, for a bug report. Keys and full addresses are left out."

    func testHelpOffersTheLogAboveTheSourceLink() {
        launch(.sharing)
        openSettings()
        let share = reveal(element("settings.log"))
        XCTAssertTrue(share.label.contains("Share the log"), share.label)
        XCTAssertEqual(share.elementType, .button)
        let help = reveal(element("settings.help"))
        XCTAssertLessThan(share.frame.maxY, help.frame.minY + 1, "Share the log is above Help and source code")
        XCTAssertEqual(showHelp("help", "settings.logFooter").label, Self.footer)
        XCTAssertTrue(sectionHeader("Help").exists)
    }

    /// Start without opening Tether shows the three ways, and how long each keeps Tether awake.
    func testStartWithoutOpeningTetherShowsTheWays() {
        launch(.sharing)
        openSettings()
        let wake = reveal(element("settings.wake"))
        XCTAssertTrue(wake.label.contains("Start without opening Tether"), wake.label)
        XCTAssertLessThan(wake.frame.maxY, reveal(element("settings.log")).frame.minY + 1, "above Share the log")
        XCTAssertFalse(element("settings.wakeHelp").exists, "hidden at first")
        reveal(element("settings.wake")).tap()
        let ways = reveal(element("settings.wakeHelp")).label
        for line in ["Shortcuts: put Start Tether after Set Personal Hotspot, and run that shortcut.",
                     "Widget: add the Tether widget and tap Start.",
                     "Control Center: add the Tether button and turn it on.",
                     "Each one wakes Tether for 10 minutes, the same as opening it."] {
            XCTAssertTrue(ways.contains(line), "\(line) in \(ways)")
        }
        reveal(element("settings.wake")).tap()
        waitUntilGone(element("settings.wakeHelp"))
    }

    /// The share sheet opens with the log in it.
    func testShareTheLogOpensTheShareSheet() {
        launch(.sharing)
        openSettings()
        reveal(element("settings.log")).tap()
        let sheet = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no share sheet:\n\(app.debugDescription)")
        // The sheet's title is a text on some runs and a plain element on others.
        let title = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Tether log")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the sheet names the log")
    }

    /// The Help section, scrolled into view, in both appearances.
    func testTheHelpSectionPassesTheAccessibilityAuditInBothAppearances() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            launch(.sharing)
            openSettings()
            reveal(showHelp("help", "settings.logFooter"))
            // Only the Help section: scrolled down to it, the list runs under the bar, and the system's
            // Done button over it is no part of this.
            try audit(only: "settings.log")
            try audit(only: "settings.help")
            try audit(types: structuralAudit)
            app.terminate()
        }
    }
}
