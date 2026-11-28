import XCTest

extension TetherUITestCase {
    /// Shows a Settings section's long help, which sits behind the (i) in the section's header (#349),
    /// and returns it. `section` names the (i), `<section>.info`, and `id` the help text.
    @discardableResult
    func showHelp(_ section: String, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let help = element(id)
        if !help.exists { reveal(element("\(section).info"), file: file, line: line).tap() }
        XCTAssertTrue(help.waitForExistence(timeout: 5), "\(id) did not show", file: file, line: line)
        return help
    }

    /// Flips one of Settings' ink switches (InkToggleStyle). Only the switch itself takes taps, at the
    /// row's right end, so a tap on the element's centre, which is the space after the label, does nothing.
    func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -25, dy: 0)).tap()
    }
}
