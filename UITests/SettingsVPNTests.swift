import XCTest

/// Settings: Only share through a VPN (#277). What the session does with it, and which interface
/// counts as a VPN, is covered by HotspotSessionTests. A demo launch never has a VPN, so turning the
/// switch on keeps its devices out, and the main screen says so.
final class SettingsVPNTests: TetherUITestCase {
    static let blocked = "No VPN is on, so no device gets through until one is. Turn your VPN on, or turn off Only share through a VPN in Settings."
    static let footer = "When it's on and no VPN carries this iPhone's internet, no device gets through. Tether pauses the devices when it sees the VPN go, which can take a few seconds. Turn a VPN on in its app, or with Set VPN in Shortcuts: Tether can't pick one."

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
        XCTAssertEqual(label(of: "vpn.blocked"), Self.blocked)
        try audit(only: "vpn.")
        openSettings()
        let again = reveal(app.switches["vpn.only"].firstMatch)
        XCTAssertEqual(value(of: again), "1", "kept after closing")
        again.switches.firstMatch.exists ? again.switches.firstMatch.tap() : again.tap()
        app.buttons["settings.done"].tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5))
        XCTAssertFalse(element("vpn.blocked").exists, "off again, the line goes")
    }

    /// A VPN that carries IPv4 only isn't one, and both screens say so, and what to turn on (#334).
    func testAVPNForIPv4OnlySaysWhyItDoesntCount() throws {
        launch(.vpnIPv4Only)
        openSettings()
        let toggle = reveal(app.switches["vpn.only"].firstMatch)
        XCTAssertEqual(label(of: "vpn.now"), "Now, VPN for IPv4 only")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        app.buttons["settings.done"].tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5))
        XCTAssertEqual(label(of: "vpn.blocked"), "Your VPN carries only IPv4, and this iPhone's IPv6 goes around it, so no device gets through. Turn on IPv6 in your VPN, or turn off Only share through a VPN in Settings.")
        try audit(only: "vpn.")
    }
}
