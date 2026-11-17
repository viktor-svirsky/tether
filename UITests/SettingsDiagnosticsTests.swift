import XCTest

/// Settings > Diagnostics (#256): the server's counters, and a tap that copies one. What each row
/// says is covered by the unit tests (DiagnosticsTests), and the counters by Go's.
final class SettingsDiagnosticsTests: TetherUITestCase {
    private func openDiagnostics() {
        launch(.sharing)
        openSettings()
        reveal(element("settings.diagnostics")).tap()
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 5), "Diagnostics did not open")
    }

    /// The demo's counters: the iPad's traffic, and one connection the iPhone couldn't make.
    func testDiagnosticsShowsTheServersCounters() throws {
        openDiagnostics()
        XCTAssertTrue(label(of: "diagnostics.listening").contains("172.20.10.1:51820"))
        XCTAssertTrue(label(of: "diagnostics.udpIn").contains("1,250"))
        XCTAssertTrue(label(of: "diagnostics.udpFrom").contains("172.20.10.2:52345"))
        XCTAssertTrue(sectionHeader("WireGuard port").exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "settings-diagnostics"
        shot.lifetime = .keepAlways
        add(shot)
        try audit()
        XCTAssertTrue(reveal(element("diagnostics.lastError")).label.contains("TCP to 203.0.113.9:443: connect: connection refused"))
    }

    /// A tap copies the row's value, and the screen says what it copied.
    func testATapCopiesAValue() {
        openDiagnostics()
        reveal(element("diagnostics.udpFrom")).tap()
        XCTAssertEqual(label(of: "diagnostics.copied"), "Copied 172.20.10.2:52345")
    }
}
