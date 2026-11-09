import XCTest

/// Settings > Devices: where Tether sends the devices' lookups (#79, #121). Where each choice sends
/// lookups, and the config's DNS line, are covered by the unit tests (DNSChoiceTests, HotspotSessionTests).
final class SettingsDNSTests: TetherUITestCase {
    static let footer = "Your devices ask Tether, and Tether asks this server, so a change reaches them at once. A device whose DNS in WireGuard isn't 10.7.0.1 keeps its own: set it to 10.7.0.1 there, or add the device again. The server can see which sites your devices visit."

    func testDNSIsAMenuKeptAfterClosing() throws {
        launch(.sharing)
        openSettings()
        let menu = reveal(app.buttons["newDevices.dns"].firstMatch)
        XCTAssertTrue(menu.label.contains("DNS"), menu.label)
        let first = "Cloudflare (1.1.1.1, no filtering)"
        XCTAssertTrue(menu.label.contains(first) || value(of: menu) == first, "Cloudflare at first: \(menu.label)")
        XCTAssertEqual(label(of: "newDevices.footer"), Self.footer)
        XCTAssertTrue(sectionHeader("Devices").exists)
        try audit(only: "newDevices.")
        menu.tap()
        for choice in [first, "Cloudflare (1.1.1.2, blocks malware)", "Quad9 (9.9.9.9, blocks malware)",
                       "AdGuard (94.140.14.14, blocks ads)", "Control D (your profile, over HTTPS)", "Other server"] {
            XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 3), choice)
        }
        app.buttons["AdGuard (94.140.14.14, blocks ads)"].tap()
        waitUntilGone(app.buttons["Other server"])
        let adGuard = "AdGuard (94.140.14.14, blocks ads)"
        XCTAssertTrue(menu.label.contains(adGuard) || value(of: menu) == adGuard, "picked: \(menu.label)")
        // Right under the menu, on screen. Not assertNowhere: its drag to the top closes the sheet.
        XCTAssertFalse(element("newDevices.other").exists, "the address field is only for Other")
        XCTAssertFalse(element("newDevices.controlD").exists, "the profile field is only for Control D")
        app.buttons["settings.done"].tap()
        XCTAssertTrue(element("status.title").waitForExistence(timeout: 5))
        openSettings()
        let again = reveal(app.buttons["newDevices.dns"].firstMatch)
        XCTAssertTrue(again.label.contains(adGuard) || value(of: again) == adGuard, "kept after closing: \(again.label)")
    }

    /// Other asks for an address, and says what Tether asks until it's a usable one.
    func testOtherTakesOneOrTwoIPv4Addresses() throws {
        launch(.sharing)
        openSettings()
        reveal(app.buttons["newDevices.dns"].firstMatch).tap()
        XCTAssertTrue(app.buttons["Other server"].waitForExistence(timeout: 3))
        app.buttons["Other server"].tap()
        let field = reveal(element("newDevices.other"))
        let problem = "One or two IPv4 addresses, like 9.9.9.10. Until then, Tether asks 1.1.1.1."
        XCTAssertEqual(label(of: "newDevices.otherProblem"), problem, "nothing typed yet")
        field.tap()
        // Only digits and punctuation: the field's keyboard has no letters. A name is DNSChoiceTests' case.
        field.typeText("8.8.8")
        XCTAssertEqual(label(of: "newDevices.otherProblem"), problem, "three numbers aren't an address")
        field.typeText(".8, 8.8.4.4")
        waitUntilGone(element("newDevices.otherProblem"))
        try audit(only: "newDevices.")
    }

    /// Control D asks for the profile (#100), says what Tether asks until it holds one, and its
    /// footer then says where lookups go and how a device added before follows.
    func testControlDTakesAProfile() throws {
        launch(.sharing)
        openSettings()
        reveal(app.buttons["newDevices.dns"].firstMatch).tap()
        let controlD = "Control D (your profile, over HTTPS)"
        XCTAssertTrue(app.buttons[controlD].waitForExistence(timeout: 3))
        app.buttons[controlD].tap()
        let field = reveal(element("newDevices.controlD"))
        XCTAssertEqual(label(of: "newDevices.controlDProblem"),
                       "Your profile's resolver ID or DoH link, from Control D's dashboard. Until then, Tether asks 1.1.1.1.")
        XCTAssertEqual(label(of: "newDevices.footer"), Self.footer, "nothing typed, so nothing changes yet")
        field.tap()
        field.typeText("https://dns.controld.com/abcd1234")
        waitUntilGone(element("newDevices.controlDProblem"))
        XCTAssertEqual(label(of: "newDevices.footer"), Self.controlDFooter)
        try audit(only: "newDevices.")
    }

    static let controlDFooter = "Your devices ask Tether, and Tether asks your Control D profile over HTTPS. Pick the country sites see in Control D, under Redirect (a paid plan). A device whose DNS in WireGuard isn't 10.7.0.1 keeps its own: set it to 10.7.0.1 there. Control D can see which sites your devices visit."
}
