import XCTest

/// Settings: Only share through a VPN (#277). What the session does with it, and which interface
/// counts as a VPN, is covered by HotspotSessionTests. A demo launch never has a VPN.
final class SettingsVPNTests: TetherUITestCase {
    static let footer = "When it's on and no VPN carries this iPhone's internet, no device gets through, so nothing leaves without the VPN. Turn a VPN on in its app, or with Set VPN in Shortcuts: Tether can't pick one."

    func testOnlyShareThroughAVPNIsASwitchOffAtFirstAndKeptAfterClosing() throws {
        launch(.sharing)
        openSettings()
        let toggle = reveal(app.switches["vpn.only"].firstMatch)
        XCTAssertEqual(toggle.label, "Only share through a VPN")
        XCTAssertEqual(value(of: toggle), "0", "off at first")
        XCTAssertTrue(sectionHeader("VPN").exists)
        XCTAssertEqual(label(of: "vpn.now"), "Now, No VPN")
        XCTAssertEqual(label(of: "vpn.footer"), Self.footer)
        try audit(only: "vpn.")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertEqual(value(of: toggle), "1", "the tap turned it on")
        app.buttons["settings.done"].tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5))
        openSettings()
        XCTAssertEqual(value(of: reveal(app.switches["vpn.only"].firstMatch)), "1", "kept after closing")
    }
}
