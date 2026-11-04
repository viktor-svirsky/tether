import XCTest

/// Accessibility: the system audit on the screens, Dynamic Type at an accessibility size, and dark mode.
final class AccessibilityTests: TetherUITestCase {
    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    // MARK: audit

    func testMainScreenPassesTheAccessibilityAudit() throws {
        launch(.sharing)
        try audit()
    }

    func testLowerPartOfTheMainScreenPassesTheStructuralAudit() throws {
        launch(.sharing)
        reveal(element("add.open"))
        try audit(types: structuralAudit)
    }

    // MARK: Dynamic Type

    private let accessibilityXL = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]

    func testLargeTextKeepsTheKeyTexts() {
        launch(.sharing, arguments: accessibilityXL)
        let window = app.windows.firstMatch.frame
        for id in ["status.title", "status.headline"] {
            let e = element(id)
            XCTAssertTrue(e.waitForExistence(timeout: 5), id)
            XCTAssertFalse(e.label.isEmpty, id)
            XCTAssertGreaterThan(e.frame.height, 10, "\(id) collapsed")
            XCTAssertGreaterThan(e.frame.width, 40, "\(id) collapsed")
            XCTAssertGreaterThanOrEqual(e.frame.minX, window.minX - 1, "\(id) is cut off on the left")
            XCTAssertLessThanOrEqual(e.frame.maxX, window.maxX + 1, "\(id) is cut off on the right")
        }
        XCTAssertEqual(label(of: "status.headline"), "1 device connected")
    }

    func testLargeTextWrapsInsteadOfShrinking() {
        launch(.sharing)
        let normal = element("status.headline").frame.height
        app.terminate()
        launch(.sharing, arguments: accessibilityXL)
        let large = element("status.headline").frame.height
        XCTAssertGreaterThan(large, normal * 1.5, "the headline should grow with the text size, not stay the same")
    }

    // MARK: dark mode

    func testDarkModeShowsTheMainScreenAndPassesTheContrastAudit() throws {
        XCUIDevice.shared.appearance = .dark
        launch(.sharing)
        XCTAssertEqual(label(of: "status.headline"), "1 device connected")
        try audit()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Main screen, dark mode"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The orange card holds a button, so the waiting screen gets its own contrast check.
    func testWaitingScreenPassesTheAccessibilityAudit() throws {
        launch(.waiting)
        try audit()
    }

    /// The upload colour is Tether's own, so it gets a contrast check where it shows, in both appearances.
    func testTrafficSpeedsPassTheContrastAudit() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            launch(.sharing)
            reveal(element("traffic.speeds"))
            try audit(types: .contrast, only: "traffic.")
            app.terminate()
        }
    }

    // MARK: devices and the QR code

    /// The button and the sheet's steps and Share file button get the full audit, in both appearances.
    func testAddDevicePassesTheAccessibilityAuditInBothAppearances() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            launch(.sharing)
            XCTAssertTrue(reveal(element("add.open")).isHittable)
            try audit(only: "add.")
            openAddDevice()
            try audit()
            app.segmentedControls.buttons["Computer"].tap()
            XCTAssertTrue(reveal(element("add.share")).isHittable)
            try audit(only: "add.")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Add a device, \(appearance == .dark ? "dark" : "light")"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    /// The filled buttons' white text keeps 4.5:1 on their blue in both appearances: Add a device
    /// before any device, and Done once one connects. The accent is light in dark mode, too light
    /// under white text (#68). Read from the pixels: the audit doesn't look at a button's own label.
    func testFilledButtonsKeepTheirContrastInBothAppearances() {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            for (scenario, id) in [(Scenario.noDevices, "add.open"), (.addDeviceDone, "add.done")] {
                launch(scenario)
                let button = reveal(element(id))
                waitUntilStill(button)
                let ratio = textContrast(of: button)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(id) in \(appearance == .dark ? "dark" : "light") mode: \(ratio):1")
                app.terminate()
            }
        }
    }

    func testAddDeviceSheetPassesTheStructuralAudit() throws {
        launch(.noDevices)
        openAddDevice()
        reveal(element("add.step3"))
        try audit(types: structuralAudit)
    }

    func testWireGuardProblemSectionPassesTheAccessibilityAudit() throws {
        launch(.wireGuardNeedsReset)
        XCTAssertTrue(element("wireguard.reset").waitForExistence(timeout: 5))
        try audit()
    }

    func testQRCodeProblemPassesTheStructuralAudit() throws {
        launch(.qrCodeUnsaved)
        reveal(staticText("add.problem")) // the warning icon carries the identifier too, and comes first on iOS 18
        try audit(types: structuralAudit)
    }

    /// A device that isn't connected says so in text that passes, in both appearances (#32). The
    /// other device test opens the iPad, which is connected.
    func testAnUnconnectedDeviceScreenPassesTheAccessibilityAudit() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            launch(.sharing)
            openDevice("Windows PC")
            XCTAssertEqual(staticText("device.status").label, "Not connected")
            try audit()
            app.terminate()
        }
    }

    func testDeviceScreenPassesTheAccessibilityAudit() throws {
        launch(.sharing)
        openDevice("iPad")
        XCTAssertTrue(element("device.status").waitForExistence(timeout: 5))
        try audit()
    }

    func testADeviceProblemPassesTheAccessibilityAudit() throws {
        launch(.qrCodeUnsaved)
        openDevice("iPad")
        removeOpenDevice()
        XCTAssertTrue(staticText("device.problem").waitForExistence(timeout: 5))
        try audit()
    }

    /// Remove, and Remove again in the confirmation dialog.
    private func removeOpenDevice() {
        reveal(element("device.remove"), maxSwipes: 30).tap()
        app.buttons["Remove"].firstMatch.tap()
    }

    func testLargeTextGrowsTheDeviceRows() {
        launch(.sharing)
        let normal = reveal(element("device.iPad")).frame.height
        app.terminate()
        launch(.sharing, arguments: accessibilityXL)
        XCTAssertGreaterThan(reveal(element("device.iPad"), maxSwipes: 30).frame.height, normal * 1.3)
    }

    func testLargeTextKeepsTheQRSectionAndDeviceRowsReachable() {
        launch(.sharing, arguments: accessibilityXL)
        XCTAssertTrue(reveal(element("device.iPad"), maxSwipes: 30).isHittable)
        XCTAssertTrue(reveal(element("device.Windows PC"), maxSwipes: 30).isHittable)
        reveal(element("add.open"), maxSwipes: 30).tap()
        XCTAssertTrue(element("add.step1").waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(element("add.qr"), maxSwipes: 30).isHittable)
        XCTAssertTrue(reveal(element("add.step3"), maxSwipes: 30).exists)
        reveal(app.segmentedControls.buttons["Computer"], maxSwipes: 30).tap()
        XCTAssertTrue(reveal(element("add.address"), maxSwipes: 30).isHittable)
        XCTAssertTrue(reveal(element("add.share"), maxSwipes: 30).isHittable)
    }

    func testLargeTextKeepsTheProblemAndResetReachable() {
        launch(.wireGuardNeedsReset, arguments: accessibilityXL)
        let banner = staticText("wireguard.problem")
        XCTAssertTrue(reveal(banner, maxSwipes: 30).exists)
        XCTAssertGreaterThan(banner.frame.height, 40, "the banner wraps instead of shrinking")
        XCTAssertTrue(reveal(element("wireguard.reset"), maxSwipes: 30).isHittable)
    }

    func testLargeTextKeepsADeviceProblemReadable() {
        launch(.qrCodeUnsaved, arguments: accessibilityXL)
        reveal(element("device.Windows PC"), maxSwipes: 30).tap()
        XCTAssertTrue(app.navigationBars["Windows PC"].waitForExistence(timeout: 5))
        removeOpenDevice()
        let problem = staticText("device.problem")
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(problem, maxSwipes: 30).exists)
        XCTAssertGreaterThan(problem.frame.height, 40, "the message wraps instead of shrinking")
    }

    func testLargeTextKeepsTheDeviceScreenReachable() {
        launch(.sharing, arguments: accessibilityXL)
        reveal(element("device.iPad"), maxSwipes: 30).tap()
        XCTAssertTrue(element("device.status").waitForExistence(timeout: 5))
        let thisMonth = reveal(element("device.thisMonth"), maxSwipes: 30)
        XCTAssertGreaterThan(thisMonth.frame.height, 40, "the big number grows with the text size")
        XCTAssertTrue(reveal(element("device.downAndUp"), maxSwipes: 30).exists)
        XCTAssertTrue(reveal(element("device.lastMonth"), maxSwipes: 30).exists)
        XCTAssertTrue(reveal(element("device.remove"), maxSwipes: 30).isHittable)
    }

    func testDarkModeProblemSection() throws {
        XCUIDevice.shared.appearance = .dark
        launch(.wireGuardNeedsReset)
        XCTAssertTrue(element("wireguard.problem").waitForExistence(timeout: 5))
        try audit()
    }

    func testDarkModeDeviceScreen() throws {
        XCUIDevice.shared.appearance = .dark
        launch(.sharing)
        openDevice("iPad")
        try audit()
    }

    func testDarkModeWaitingScreen() {
        XCUIDevice.shared.appearance = .dark
        launch(.waiting)
        XCTAssertEqual(label(of: "status.title"), "Turn on Personal Hotspot")
    }
}
