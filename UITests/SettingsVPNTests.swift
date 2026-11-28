import XCTest

/// Settings: Only share through a VPN (#277). What the session does with it, and which interface
/// counts as a VPN, is covered by HotspotSessionTests. A demo launch never has a VPN, so turning the
/// switch on keeps its devices out, and the main screen says so.
final class SettingsVPNTests: TetherUITestCase {
    static let blocked = "No device gets through until a VPN is on. Turn your VPN on, or turn off Only share through a VPN in Settings."
    static let footer = "When it's on and no VPN carries this iPhone's internet, no device gets through. Tether pauses the devices when it sees the VPN go, which can take a few seconds. Turn a VPN on in its app, or with Set VPN in Shortcuts: Tether can't pick one."

    func testOnlyShareThroughAVPNIsASwitchOffAtFirstAndKeptAfterClosing() throws {
        launch(.sharing)
        openSettings()
        let toggle = reveal(app.switches["vpn.only"].firstMatch)
        XCTAssertEqual(toggle.label, "Only share through a VPN")
        XCTAssertEqual(value(of: toggle), "0", "off at first")
        XCTAssertTrue(sectionHeader("VPN").exists)
        XCTAssertEqual(label(of: "vpn.now"), "Now, No VPN")
        XCTAssertEqual(showHelp("vpn", "vpn.footer").label, Self.footer)
        try audit(only: "vpn.")
        flip(toggle)
        XCTAssertEqual(value(of: toggle), "1", "the tap turned it on")
        // Right where it's turned on, the effect (M8).
        XCTAssertEqual(label(of: "vpn.now"), "Now, No VPN, devices kept out")
        app.buttons["settings.done"].tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5))
        XCTAssertEqual(label(of: "vpn.blocked"), Self.blocked)
        try audit(only: "vpn.")
        openSettings()
        let again = reveal(app.switches["vpn.only"].firstMatch)
        XCTAssertEqual(value(of: again), "1", "kept after closing")
        flip(again)
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
        flip(toggle)
        XCTAssertEqual(label(of: "vpn.now"), "Now, VPN for IPv4 only, devices kept out")
        app.buttons["settings.done"].tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5))
        XCTAssertEqual(label(of: "vpn.blocked"), "This iPhone's IPv6 goes around it, so no device gets through. Turn on IPv6 in your VPN, or turn off Only share through a VPN in Settings.")
        try audit(only: "vpn.")
    }
}
