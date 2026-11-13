import XCTest

/// The Settings sheet's Help section: the log to share for a bug report, and the source link.
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
        XCTAssertEqual(label(of: "settings.logFooter"), Self.footer)
        XCTAssertTrue(sectionHeader("Help").exists)
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
            reveal(element("settings.logFooter"))
            // Only the Help section: scrolled down to it, the list runs under the bar, and the system's
            // Done button over it is no part of this.
            try audit(only: "settings.log")
            try audit(only: "settings.help")
            try audit(types: structuralAudit)
            app.terminate()
        }
    }
}
