import XCTest

/// Another region format, and landscape (#186). Tether is iPhone only (#182), so there's no iPad test.
final class RegionAndOrientationTests: TetherUITestCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    /// A German region writes decimals with a comma, with the words still in English: the speeds and the
    /// data counts follow it, and they still fit the screen.
    func testAGermanRegionWritesNumbersItsWay() {
        launch(.sharing, locale: "de_DE")
        let speeds = reveal(element("traffic.speeds"))
        XCTAssertEqual(speeds.label, "Download 3,2 Mbit/s, upload 400 kbit/s")
        let ipad = reveal(element("device.iPad"))
        XCTAssertTrue(ipad.label.contains("3,12 GB this month"), ipad.label)
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(screen.contains(speeds.frame), "the speeds fit the width: \(speeds.frame)")
        XCTAssertTrue(screen.contains(ipad.frame), "the row fits the width: \(ipad.frame)")
    }

    /// The day the data counts start on is a day of the month in the region's own way.
    func testAGermanRegionWritesTheResetDayItsWay() {
        launch(.sharing, arguments: ["-usage.resetDay", "15"], locale: "de_DE")
        openSettings()
        let menu = app.buttons["sharing.resetDay"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        // The region writes the numbers, the language the words: an English 15th, not a German "15.".
        XCTAssertTrue(menu.label.contains("15th"), menu.label)
    }

    /// The main screen still works turned sideways: the card says it shares and a device row can be tapped.
    func testTheMainScreenWorksInLandscape() {
        launch(.sharing)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(label(of: "status.title"), "Sharing")
        XCTAssertTrue(element("traffic.speeds").exists)
        // `reveal` drags by the list's portrait frame, so plain swipes here.
        let ipad = element("device.iPad")
        for _ in 0..<6 where !ipad.isHittable { app.swipeUp() }
        XCTAssertTrue(ipad.isHittable, "the device rows can be reached sideways")
    }
}
