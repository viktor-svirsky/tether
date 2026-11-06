import XCTest

/// Settings > New devices: the DNS server the next device's config names (#79). What each choice puts
/// on the config's DNS line is covered by the unit tests (DNSChoiceTests, HotspotSessionTests).
final class SettingsDNSTests: TetherUITestCase {
    static let footer = "Devices you add from now on use it. A device you already added keeps its DNS: change it in that device's WireGuard app, under DNS servers. It can see which sites your devices visit."

    func testDNSIsAMenuKeptAfterClosing() throws {
        launch(.sharing)
        openSettings()
        let menu = reveal(app.buttons["newDevices.dns"].firstMatch)
        XCTAssertTrue(menu.label.contains("DNS"), menu.label)
        let first = "Cloudflare (1.1.1.1, no filtering)"
        XCTAssertTrue(menu.label.contains(first) || value(of: menu) == first, "Cloudflare at first: \(menu.label)")
        XCTAssertEqual(label(of: "newDevices.footer"), Self.footer)
        XCTAssertTrue(sectionHeader("New devices").exists)
        try audit(only: "newDevices.")
        menu.tap()
        for choice in [first, "Cloudflare (1.1.1.2, blocks malware)", "Quad9 (9.9.9.9, blocks malware)",
                       "AdGuard (94.140.14.14, blocks ads)", "Other server"] {
            XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 3), choice)
        }
        app.buttons["AdGuard (94.140.14.14, blocks ads)"].tap()
        waitUntilGone(app.buttons["Other server"])
        let adGuard = "AdGuard (94.140.14.14, blocks ads)"
        XCTAssertTrue(menu.label.contains(adGuard) || value(of: menu) == adGuard, "picked: \(menu.label)")
        // Right under the menu, on screen. Not assertNowhere: its drag to the top closes the sheet.
        XCTAssertFalse(element("newDevices.other").exists, "the address field is only for Other")
        app.buttons["settings.done"].tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5))
        openSettings()
        let again = reveal(app.buttons["newDevices.dns"].firstMatch)
        XCTAssertTrue(again.label.contains(adGuard) || value(of: again) == adGuard, "kept after closing: \(again.label)")
    }

    /// Other asks for an address, and says what new devices get until it's a usable one.
    func testOtherTakesOneOrTwoIPv4Addresses() throws {
        launch(.sharing)
        openSettings()
        reveal(app.buttons["newDevices.dns"].firstMatch).tap()
        XCTAssertTrue(app.buttons["Other server"].waitForExistence(timeout: 3))
        app.buttons["Other server"].tap()
        let field = reveal(element("newDevices.other"))
        let problem = "One or two IPv4 addresses, like 9.9.9.10. Until then, new devices get 1.1.1.1."
        XCTAssertEqual(label(of: "newDevices.otherProblem"), problem, "nothing typed yet")
        field.tap()
        // Only digits and punctuation: the field's keyboard has no letters. A name is DNSChoiceTests' case.
        field.typeText("8.8.8")
        XCTAssertEqual(label(of: "newDevices.otherProblem"), problem, "three numbers aren't an address")
        field.typeText(".8, 8.8.4.4")
        waitUntilGone(element("newDevices.otherProblem"))
        try audit(only: "newDevices.")
    }
}
