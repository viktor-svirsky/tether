import XCTest

/// Pausing a device on its screen (#74): Pause under its status, then Paused with Resume in the same
/// spot, its row on the main screen, and the footer.
final class DevicePauseTests: TetherUITestCase {
    private let footer = "Pause stops it from connecting until you resume it."

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    func testADeviceHasPauseUnderItsStatusWithTheFooter() {
        launch(.sharing)
        openDevice("iPad")
        let status = staticText("device.status")
        let pause = reveal(element("device.pause"))
        XCTAssertEqual(pause.label, "Pause")
        XCTAssertGreaterThan(pause.frame.minY, status.frame.maxY, "under the status")
        XCTAssertTrue(app.staticTexts[footer].exists)
        assertNowhere(element("device.resume"), element("device.statusDetail"))
    }

    func testPausingSaysPausedAndPutsResumeInItsPlace() {
        launch(.sharing)
        openDevice("iPad")
        XCTAssertEqual(staticText("device.status").label, "Connected")
        let place = element("device.pause").frame.minY
        element("device.pause").tap()
        let status = staticText("device.status")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Paused")
        XCTAssertEqual(staticText("device.statusDetail").label, "It can't connect until you resume it.")
        let resume = element("device.resume")
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertEqual(resume.label, "Resume")
        XCTAssertEqual(resume.frame.minY, place, accuracy: 30, "the same spot")
        assertNowhere(element("device.pause"), app.staticTexts[footer])
        goBack(to: "Tether")
        let row = reveal(element("device.iPad"))
        XCTAssertTrue(row.label.contains("Paused"), row.label)
        XCTAssertFalse(row.label.contains("Connected"), row.label)
        XCTAssertEqual(label(of: "status.headline"), "No device is using Tether yet", "a paused device doesn't count as connected")
    }

    func testResumeConnectsItAgain() {
        launch(.paused)
        openDevice("iPad")
        XCTAssertEqual(staticText("device.status").label, "Paused")
        reveal(element("device.resume")).tap()
        XCTAssertTrue(element("device.pause").waitForExistence(timeout: 5))
        XCTAssertEqual(staticText("device.status").label, "Connected", "its tunnel stayed up")
        XCTAssertTrue(app.staticTexts[footer].exists)
        assertNowhere(element("device.resume"), element("device.statusDetail"))
        goBack(to: "Tether")
        let row = reveal(element("device.iPad"))
        XCTAssertTrue(row.label.contains("Connected") && !row.label.contains("Paused"), row.label)
        XCTAssertEqual(label(of: "status.headline"), "1 device connected")
    }

    func testAPausedDeviceIsListedAsPaused() {
        launch(.paused)
        let ipad = reveal(element("device.iPad"))
        XCTAssertTrue(ipad.label.contains("iPad") && ipad.label.contains("Paused"), ipad.label)
        XCTAssertFalse(ipad.label.contains("Connected"), ipad.label)
        XCTAssertTrue(element("device.Windows PC").label.contains("Not connected"), "only the iPad")
        XCTAssertEqual(label(of: "status.headline"), "No device is using Tether yet")
        openDevice("Windows PC")
        XCTAssertTrue(reveal(element("device.pause")).exists)
    }

    // MARK: accessibility

    func testAPausedDeviceScreenPassesTheAccessibilityAuditInBothAppearances() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            launch(.paused)
            openDevice("iPad")
            XCTAssertTrue(element("device.resume").waitForExistence(timeout: 5))
            try audit()
            app.terminate()
        }
    }

    func testAPausedRowPassesTheAccessibilityAuditInBothAppearances() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            launch(.paused)
            reveal(element("device.iPad"))
            try audit()
            app.terminate()
        }
    }

    /// Resume's white text keeps 4.5:1 on its blue, read from the pixels as for the other filled buttons.
    func testResumeKeepsItsContrastInBothAppearances() {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            launch(.paused)
            openDevice("iPad")
            let button = reveal(element("device.resume"))
            waitUntilStill(button)
            let ratio = textContrast(of: button)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "device.resume in \(appearance == .dark ? "dark" : "light") mode: \(ratio):1")
            app.terminate()
        }
    }

    func testLargeTextKeepsPausedAndResumeReadable() {
        launch(.paused, arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        reveal(element("device.iPad"), maxSwipes: 30).tap()
        XCTAssertTrue(app.navigationBars["iPad"].waitForExistence(timeout: 5))
        let detail = staticText("device.statusDetail")
        XCTAssertTrue(reveal(detail, maxSwipes: 30).exists)
        XCTAssertGreaterThan(detail.frame.height, 40, "the line wraps instead of shrinking")
        XCTAssertTrue(reveal(element("device.resume"), maxSwipes: 30).isHittable)
    }
}
