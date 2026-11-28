import XCTest

/// Settings > Your devices: whether the devices reach the iPhone's own networks (#230). Named apart
/// from iOS's Local Network permission (M3). What the server does with
/// it is covered by the Go tests (local_test.go), and how it gets there by HotspotSessionTests.
final class SettingsLocalNetworksTests: TetherUITestCase {
    static let footer = "Off: your devices reach the internet, but not the iPhone's Wi-Fi network, a VPN's private addresses or a Tailscale network. Tether's page still opens."

    func testLocalNetworksIsASwitchKeptAfterClosing() throws {
        launch(.sharing)
        openSettings()
        let toggle = reveal(app.switches["localNetworks.toggle"].firstMatch)
        XCTAssertEqual(toggle.label, "The iPhone's Wi-Fi and VPN networks")
        XCTAssertTrue(sectionHeader("Your devices").exists)
        // One (i) for the section shows the DNS help and this one.
        XCTAssertEqual(showHelp("newDevices", "localNetworks.footer").label, Self.footer)
        XCTAssertTrue(element("newDevices.footer").exists)
        try audit(only: "localNetworks.")
        let before = value(of: toggle)
        flip(toggle)
        XCTAssertNotEqual(value(of: toggle), before, "the tap flipped it")
        let after = value(of: toggle)
        app.buttons["settings.done"].tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5))
        openSettings()
        XCTAssertEqual(value(of: reveal(app.switches["localNetworks.toggle"].firstMatch)), after, "kept after closing")
    }
}
