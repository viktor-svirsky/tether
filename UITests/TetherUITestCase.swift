import XCTest

/// The fake app states a test can launch (`-TetherDemo <name>`, see Sources/DemoMode.swift).
/// Their fixed values are described there.
enum Scenario: String {
    case waiting, wireGuardLockedWaiting, noDevices, sharing, wireGuardLocked, wireGuardNeedsReset, wireGuardUnsaved, qrCodeUnsaved, expiring
}

/// Base class for the screen tests: launching, finding things by identifier, scrolling a List.
class TetherUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Launches Tether in a demo scenario, in English with US formats so every text is stable.
    /// Pass `scenario: nil` for a normal launch.
    @discardableResult
    func launch(_ scenario: Scenario?, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if let scenario { args += ["-TetherDemo", scenario.rawValue] }
        app.launchArguments = args + arguments
        app.launch()
        self.app = app
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 10), "main screen did not appear")
        return app
    }

    // MARK: finding

    /// Any element with this accessibility identifier, whatever its type.
    /// SwiftUI puts an identifier on the children too (a Label's icon, the two layers of a ProgressView),
    /// so several elements can match. The first one is the outermost.
    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// A List section header. Some iOS versions show headers in capitals and some don't, so the
    /// match ignores case.
    func sectionHeader(_ title: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", title)).firstMatch
    }

    /// Closes a confirmation dialog without choosing anything. Before iOS 26 it has a Cancel button.
    /// From iOS 26 it opens as a popover with no Cancel, and a tap outside it closes it.
    func cancelDialog() {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists {
            cancel.tap()
        } else {
            app.otherElements["PopoverDismissRegion"].firstMatch.tap()
        }
    }

    /// The static text with this identifier. For a Label (icon and text) the icon carries the identifier too.
    func staticText(_ id: String) -> XCUIElement {
        app.staticTexts.matching(identifier: id).firstMatch
    }

    /// A static text whose label starts with `prefix`. List rows merge several texts, so the full label is not always known.
    func text(startingWith prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func text(containing part: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }

    /// The label of an element that must exist.
    func label(of id: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let e = element(id)
        XCTAssertTrue(e.waitForExistence(timeout: 5), "\(id) not found", file: file, line: line)
        return e.label
    }

    /// The accessibility value of an element, as text.
    func value(of element: XCUIElement) -> String {
        (element.value as? String) ?? ""
    }

    // MARK: scrolling

    /// The main screen's List, or the List of whatever screen is showing.
    var list: XCUIElement { app.collectionViews.firstMatch }

    /// Scrolls until the element is fully on screen, clear of the navigation bar and the home indicator, so a tap lands on it.
    /// A List only keeps rows near the screen, so an element can exist and still be off screen: `isHittable` is not enough.
    /// Looks down the list first, then back up. Once the element exists, one drag moves it to the middle of the screen.
    /// Stops when a drag no longer moves the element (an end of the list), and then accepts an element that is at least tappable.
    @discardableResult
    func reveal(_ element: XCUIElement, maxSwipes: Int = 14, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let window = app.windows.firstMatch.frame
        let top: CGFloat = 110, bottom = window.maxY - 50
        let page = (bottom - top) * 0.8
        func inPlace() -> Bool {
            element.exists && element.isHittable && element.frame.minY >= top && element.frame.maxY <= bottom
        }
        var lastFrame: CGRect?
        var pagesDown = 0
        var turns = 0
        while !inPlace() && turns < 3 * maxSwipes {
            turns += 1
            if element.exists {
                let frame = element.frame
                if frame == lastFrame { break }
                lastFrame = frame
                // A row taller than the space lines up its top, so its first line is on screen.
                let target = frame.height > bottom - top ? top + frame.height / 2 : (top + bottom) / 2
                scroll(by: min(max(frame.midY - target, -page), page))
            } else if pagesDown < maxSwipes {
                pagesDown += 1
                scroll(by: page)
            } else {
                scroll(by: -page)
            }
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) could not be scrolled into view", file: file, line: line)
        waitUntilStill(element)
        return element
    }

    /// Moves the list's content up by `distance` points (down for a negative one), with a slow drag that holds still at the end,
    /// so the list doesn't keep going. A swipe flings it, and on a small screen with large text a fling jumps right past a row.
    /// The drag starts near the edge it moves away from and covers at most 60% of the list, so it stays on screen.
    func scroll(by distance: CGFloat) {
        let limit = list.frame.height * 0.6
        let distance = min(max(distance, -limit), limit)
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: distance > 0 ? 0.8 : 0.2))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    /// Waits until the element stops moving (a scroll or an expanding group still settling), so a tap lands where it was aimed.
    func waitUntilStill(_ element: XCUIElement, timeout: TimeInterval = 3) {
        var last = CGRect.null
        let still = NSPredicate { _, _ in
            let frame = element.frame
            defer { last = frame }
            return frame == last
        }
        _ = XCTWaiter().wait(for: [expectation(for: still, evaluatedWith: element)], timeout: timeout)
    }

    /// Waits until the element exists and is on screen. For things that scroll or animate into place.
    func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let done = expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: element)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: timeout), .completed, "\(element) never became tappable", file: file, line: line)
    }

    /// Fails if any of these elements is anywhere on the screen. A List only builds the rows near the screen, so `exists`
    /// is false for a row that is only scrolled away. This scrolls to the top of the list, then down to its end, and
    /// checks at every stop. Pass all the elements of a test at once: each call scrolls the whole list.
    func assertNowhere(_ elements: XCUIElement..., message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        func found() -> Bool {
            guard let e = elements.first(where: \.exists) else { return false }
            XCTFail("\(e) is on the screen. \(message)", file: file, line: line)
            return true
        }
        let page = list.frame.height * 0.6
        var turns = 0
        while turns < 30, drag(by: -page) { turns += 1 }
        if turns == 30 { return XCTFail("the list never reached its top", file: file, line: line) }
        if found() { return }
        turns = 0
        while drag(by: page) {
            turns += 1
            if found() { return }
            if turns == 30 { return XCTFail("the list never ended", file: file, line: line) }
        }
    }

    /// Scrolls the list and says whether it moved. At an end it doesn't, or a screen without a list.
    private func drag(by distance: CGFloat) -> Bool {
        guard list.exists, list.cells.count > 0 else { return false }
        let before = listPosition()
        scroll(by: distance)
        waitUntilStill(list.cells.firstMatch)
        return listPosition() != before
    }

    /// Where the list's first and last built rows are, and how many there are. Any scroll changes one of them.
    private func listPosition() -> (rows: Int, first: CGRect, last: CGRect) {
        let cells = list.cells
        let count = cells.count
        guard count > 0 else { return (0, .zero, .zero) }
        return (count, cells.element(boundBy: 0).frame, cells.element(boundBy: count - 1).frame)
    }

    /// Waits until the element is gone.
    func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let done = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: timeout), .completed, "\(element) is still there", file: file, line: line)
    }

    // MARK: navigation

    /// From the main screen to one device's screen, through its row in the Devices section.
    func openDevice(_ name: String) {
        reveal(element("device.\(name)")).tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5), "\(name)'s screen did not open")
    }

    func goBack(to title: String) {
        let back = app.navigationBars.buttons[title]
        back.tap()
        waitUntilGone(back)
    }

    // MARK: accessibility audit

    /// The system accessibility audit on the screen that is showing, minus one known case (below).
    ///
    /// Left out of the audit entirely: Dynamic Type and clipped text. The audit flags text that certainly
    /// scales, so it cannot tell us anything here. The tests in
    /// AccessibilityTests launch at an accessibility text size and check the same screens directly.
    ///
    /// Let through, and listed in the test report (an attachment on the test): "Contrast nearly passed",
    /// iOS's own secondary text colour on the grouped background (section headers, footers, footnotes).
    /// It passes for large text only, and it is the system's colour, not ours. Only plain texts without an
    /// identifier qualify, plus the elements named in `systemStyled`, each checked to use only system styling.
    /// Any other element, an issue with no element, and every full contrast failure still fail the test.
    ///
    /// `types` defaults to everything but Dynamic Type and clipped text. Contrast reads the pixels, so it is only right for what
    /// is fully on screen: after scrolling, use `structuralAudit` for the rest.
    /// `underSheet`: a half-height sheet leaves the screen behind it visible and dimmed. Its text is hidden
    /// from VoiceOver on purpose while the sheet is open, and the audit reports it as "Potentially
    /// inaccessible text" with no element. Only that exact case is let through.
    ///
    /// `only`, when set, judges just the elements whose identifier starts with it, for a screen that is
    /// scrolled so that other texts are cut off at the edges.
    func audit(types: XCUIAccessibilityAuditType = XCUIAccessibilityAuditType.all.subtracting([.dynamicType, .textClipped]),
               underSheet: Bool = false, only prefix: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        var allowed: [String] = []
        try app.performAccessibilityAudit(for: types) { issue in
            let element = issue.element
            if let prefix, !(element?.identifier.hasPrefix(prefix) ?? false) { return true }
            let systemText = element?.elementType == .staticText && element?.identifier.isEmpty == true
            let systemStyled = Self.systemStyled.contains(element?.identifier ?? "")
                || (element?.elementType == .button && Self.systemButtons.contains(element?.label ?? ""))
            let known = (issue.compactDescription == "Contrast nearly passed" && (systemText || systemStyled))
                || (underSheet && issue.compactDescription == "Potentially inaccessible text" && element == nil)
            if known {
                allowed.append("\(issue.compactDescription): \(element?.label ?? "(no element)")")
            } else {
                // The failure itself names no element, so the log does.
                print("Audit issue: \(issue.compactDescription), id \(element?.identifier ?? "-"), label \(element?.label ?? "(no element)")")
            }
            return known
        }
        let note = XCTAttachment(string: allowed.isEmpty ? "nothing let through" : allowed.joined(separator: "\n"))
        note.name = "Audit issues let through"
        note.lifetime = .keepAlways
        add(note)
    }

    /// Toolbar buttons, drawn by the system in its own tint.
    static let systemButtons: Set<String> = ["Cancel", "Done"]
    /// Tether's elements that use only `.secondary` text, the plain button tint or the system's red for a destructive button.
    static let systemStyled: Set<String> = ["wireguard.reset", "device.remove", "add.steps"]

    /// The audit without contrast, for a screen that is scrolled (see `audit`).
    var structuralAudit: XCUIAccessibilityAuditType {
        XCUIAccessibilityAuditType.all.subtracting([.contrast, .dynamicType, .textClipped])
    }
}
