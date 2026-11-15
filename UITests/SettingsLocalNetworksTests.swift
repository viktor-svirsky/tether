import XCTest

/// Settings: whether the devices reach the iPhone's local networks (#230). What the server does with
/// it is covered by the Go tests (local_test.go), and how it gets there by HotspotSessionTests.
final class SettingsLocalNetworksTests: TetherUITestCase {
    static let footer = "Off: your devices reach the internet, but not the iPhone's Wi-Fi network, a VPN's private addresses or a Tailscale network. Tether's page still opens."

    func testLocalNetworksIsASwitchKeptAfterClosing() throws {
        launch(.sharing)
        openSettings()
        let toggle = reveal(app.switches["localNetworks.toggle"].firstMatch)
        XCTAssertEqual(toggle.label, "Local networks")
        XCTAssertTrue(sectionHeader("What your devices can reach").exists)
        XCTAssertEqual(label(of: "localNetworks.footer"), Self.footer)
        try audit(only: "localNetworks.")
        let before = value(of: toggle)
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertNotEqual(value(of: toggle), before, "the tap flipped it")
        let after = value(of: toggle)
        app.buttons["settings.done"].tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5))
        openSettings()
        XCTAssertEqual(value(of: reveal(app.switches["localNetworks.toggle"].firstMatch)), after, "kept after closing")
    }
}
