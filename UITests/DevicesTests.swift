import XCTest

/// The speed row and the Devices section of the main screen.
final class DevicesTests: TetherUITestCase {
    func testDevicesAreListedByNameWithTheirState() {
        launch(.sharing)
        let ipad = reveal(element("device.iPad"))
        let mac = element("device.MacBook")
        XCTAssertTrue(mac.exists)
        XCTAssertTrue(ipad.label.contains("iPad") && ipad.label.contains("Connected"), ipad.label)
        XCTAssertFalse(ipad.label.contains("Not connected"), ipad.label)
        XCTAssertTrue(mac.label.contains("MacBook") && mac.label.contains("Not connected"), mac.label)
        XCTAssertTrue(sectionHeader("DEVICES").exists)
    }

    func testDeviceRowsHaveNoAddressesOrByteLines() {
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

    func testShowsTheCurrentSpeeds() {
        launch(.sharing)
        XCTAssertEqual(reveal(element("traffic.speeds")).label, "Download 3.2 Mbit/s, upload 400 kbit/s")
    }

    func testIdleHotspotShowsZeroSpeeds() {
        launch(.noDevices)
        XCTAssertEqual(reveal(element("traffic.speeds")).label, "Download 0 bit/s, upload 0 bit/s")
    }
}
