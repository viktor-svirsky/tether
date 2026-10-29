import XCTest

/// Adding a device: the QR code, the shared file and the steps that are always on the main screen.
final class AddDeviceTests: TetherUITestCase {
    private let steps = "Install WireGuard on it, tap + > Create from QR code and scan this. Then edit the tunnel and turn On-Demand on for this iPhone's hotspot only. A travel router imports the file and turns its VPN on."

    func testBeforeAnyDeviceTheMainScreenShowsTheQRCodeTheFileAndTheSteps() {
        launch(.waiting)
        XCTAssertTrue(reveal(element("add.qr")).exists)
        XCTAssertEqual(element("add.qr").label, "QR code for the next device")
        let share = reveal(element("add.share"))
        XCTAssertTrue(share.label.contains("Share as a file, for a Mac or a router"), share.label)
        XCTAssertEqual(reveal(element("add.steps")).label, steps)
        XCTAssertTrue(sectionHeader("ADD A DEVICE").exists)
        assertNowhere(sectionHeader("ADD ANOTHER DEVICE"))
    }

    func testTheQRCodeShowsWithTheHotspotOnButNoDevice() {
        launch(.noDevices)
        XCTAssertTrue(reveal(element("add.qr")).exists)
        XCTAssertTrue(sectionHeader("ADD A DEVICE").exists)
    }

    func testOnceADeviceExistsTheHeaderSaysAddAnotherDevice() {
        launch(.sharing)
        XCTAssertTrue(reveal(element("add.qr")).exists, "the code stays for the next device")
        XCTAssertTrue(sectionHeader("ADD ANOTHER DEVICE").exists)
        assertNowhere(sectionHeader("ADD A DEVICE"))
        XCTAssertTrue(reveal(element("add.share")).exists)
        XCTAssertTrue(reveal(element("add.steps")).exists)
    }

    func testNothingElseOffersToAddADevice() {
        launch(.sharing)
        assertNowhere(element("add.device"), element("add.failed"), element("devices.manage"), element("status.howToConnect"),
                      app.buttons["Add a device"])
    }
}
