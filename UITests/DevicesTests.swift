import XCTest

/// The speed row and the Devices section of the main screen.
final class DevicesTests: TetherUITestCase {
    func testDevicesAreListedByNameWithTheirState() {
        launch(.sharing)
        let ipad = reveal(element("device.iPad"))
        let pc = element("device.Windows PC")
        XCTAssertTrue(pc.exists)
        XCTAssertTrue(ipad.label.contains("iPad") && ipad.label.contains("Connected"), ipad.label)
        XCTAssertFalse(ipad.label.contains(Copy.notConnected), ipad.label)
        XCTAssertTrue(pc.label.contains("Windows PC") && pc.label.contains(Copy.notConnected), pc.label)
        XCTAssertTrue(sectionHeader("DEVICES").exists)
    }

    /// Each row says what it used this month (#73), or Not used this month rather than 0 bytes.
    func testEachRowSaysWhatItUsedThisMonth() {
        launch(.sharing)
        let ipad = reveal(element("device.iPad"))
        XCTAssertTrue(ipad.label.contains("3.12 GB this month"), ipad.label)
        let pc = reveal(element("device.Windows PC"))
        XCTAssertTrue(pc.label.contains("Not used this month"), pc.label)
    }

    func testDeviceRowsHaveNoAddresses() {
        launch(.sharing)
        reveal(element("device.iPad"))
        assertNowhere(text(containing: "172.20.10"), text(containing: "10.7.0"), text(containing: "Downloaded"),
                      app.staticTexts["Active"])
    }

    func testNoDevicesMeansNoDevicesSection() {
        launch(.noDevices)
        assertNowhere(sectionHeader("DEVICES"),
                      app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "device.")).firstMatch)
    }

    /// A device on the hotspot that isn't on WireGuard or the proxy is named by its address, and the
    /// line opens Add a device to set it up (#109).
    func testADeviceNotUsingTetherOpensAddADevice() {
        launch(.notUsingTether)
        let line = reveal(element("devices.notUsingTether"))
        XCTAssertEqual(line.label, "On your hotspot, not using Tether: 172.20.10.3")
        line.tap()
        XCTAssertTrue(element("add.question").waitForExistence(timeout: 5), "the sheet did not open")
    }

    func testShowsTheCurrentSpeeds() {
        launch(.sharing)
        XCTAssertEqual(reveal(element("traffic.speeds")).label, "Download 3.2 Mbit/s, upload 400 kbit/s")
    }

    func testIdleHotspotShowsZeroSpeeds() {
        launch(.noDevices)
        XCTAssertEqual(reveal(element("traffic.speeds")).label, "Download 0 bit/s, upload 0 bit/s")
    }
}
