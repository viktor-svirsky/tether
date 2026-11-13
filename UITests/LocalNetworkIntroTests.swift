import XCTest

/// The first launch says what Local Network access is for before iOS asks, since a Don't Allow there
/// means no device can connect (#92). Its Continue is what makes iOS ask.
final class LocalNetworkIntroTests: TetherUITestCase {
    func testTheFirstLaunchSaysWhyBeforeIOSAsks() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            launch(.localNetworkIntro, screen: "intro.title")
            XCTAssertEqual(label(of: "intro.title"), "Tether needs Local Network")
            XCTAssertEqual(label(of: "intro.why"), "Your devices connect to Tether over the hotspot.")
            XCTAssertEqual(label(of: "intro.ask"),
                           "iOS may ask if Tether can find and connect to devices on your local network. Tap Allow. Without it, no device can connect.")
            XCTAssertEqual(element("intro.continue").label, "Continue")
            try audit()
            let ratio = textContrast(of: element("intro.continue"))
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "Continue in \(appearance == .dark ? "dark" : "light") mode: \(ratio):1")
            app.terminate()
        }
    }

    func testContinueGoesToTheMainScreen() {
        launch(.localNetworkIntro, screen: "intro.title")
        element("intro.continue").tap()
        waitUntilGone(element("intro.title"))
        XCTAssertEqual(label(of: "status.title"), "Waiting for a device on the hotspot")
    }

    /// Swiping down doesn't close it: only Continue does, so the check never waits for a later launch.
    func testItCantBeSwipedAway() {
        launch(.localNetworkIntro, screen: "intro.title")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(element("intro.continue").isHittable)
    }

    /// The real app, before Continue was ever tapped.
    func testANormalFirstLaunchOpensOnIt() {
        launch(nil, arguments: ["-localNetworkIntroduced", "NO"], screen: "intro.title")
        element("intro.continue").tap()
        waitUntilGone(element("intro.title"))
        XCTAssertEqual(label(of: "status.title"), "Waiting for a device on the hotspot")
    }

    func testOtherDemosDontShowIt() {
        launch(.waiting)
        assertNowhere(element("intro.title"))
    }

    /// The text grows with the setting and Continue stays in reach under it.
    func testLargeTextKeepsContinueInReach() {
        launch(.localNetworkIntro, arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
               screen: "intro.title")
        XCTAssertTrue(element("intro.continue").isHittable)
    }
}
