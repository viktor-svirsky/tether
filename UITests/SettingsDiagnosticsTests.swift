import XCTest

/// Settings > Diagnostics (#256): the server's counters, and a tap that copies one. What each row
/// says is covered by the unit tests (DiagnosticsTests), and the counters by Go's.
final class SettingsDiagnosticsTests: TetherUITestCase {
    private func openDiagnostics(_ scenario: Scenario = .sharing) {
        launch(scenario)
        openSettings()
        reveal(element("settings.diagnostics")).tap()
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 5), "Diagnostics did not open")
    }

    /// A row's label without the zero-width spaces AddressText puts after each ":".
    private func plain(_ id: String) -> String {
        label(of: id).replacingOccurrences(of: "\u{200B}", with: "")
    }

    /// The demo's counters: the iPad's traffic, and one connection the iPhone couldn't make.
    func testDiagnosticsShowsTheServersCounters() throws {
        openDiagnostics()
        XCTAssertTrue(plain("diagnostics.listening").contains("172.20.10.1:51820"))
        XCTAssertTrue(label(of: "diagnostics.udpIn").contains("1,250"))
        XCTAssertTrue(plain("diagnostics.udpFrom").contains("172.20.10.2:52345"))
        XCTAssertTrue(sectionHeader("WireGuard port").exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "settings-diagnostics"
        shot.lifetime = .keepAlways
        add(shot)
        try audit()
        reveal(element("diagnostics.lastError"))
        XCTAssertTrue(plain("diagnostics.lastError").contains("TCP to 203.0.113.9:443: connect: connection refused"))
    }

    /// A tap copies the row's value, and the screen says so.
    func testATapCopiesAValue() {
        openDiagnostics()
        reveal(element("diagnostics.udpFrom")).tap()
        XCTAssertEqual(label(of: "diagnostics.copied"), "Copied")
    }

    /// A long press has Copy too, the way iOS copies elsewhere.
    func testALongPressOffersCopy() {
        openDiagnostics()
        reveal(element("diagnostics.udpFrom")).press(forDuration: 1)
        let copy = app.buttons["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "no Copy in the menu")
        copy.tap()
        XCTAssertEqual(label(of: "diagnostics.copied"), "Copied")
    }

    /// Not sharing, the screen says there's nothing to count, not that a device sends nothing.
    func testNotSharingSaysThereIsNothingToCount() {
        openDiagnostics(.waiting)
        XCTAssertEqual(label(of: "diagnostics.portFooter"), "Tether isn't sharing, so there's nothing to count. Start sharing, then come back.")
    }
}
