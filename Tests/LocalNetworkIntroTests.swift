import XCTest
@testable import TetherCore

/// The screen before iOS asks for Local Network access: no check runs before Continue, since a check
/// is what makes iOS ask, and the screen shows once.
@MainActor
final class LocalNetworkIntroTests: XCTestCase {
    private var defaults: UserDefaults!
    private var checks = 0

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: "LocalNetworkIntroTests")
        defaults = UserDefaults(suiteName: "LocalNetworkIntroTests")
        checks = 0
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: "LocalNetworkIntroTests")
        super.tearDown()
    }

    private func intro() -> LocalNetworkIntro {
        LocalNetworkIntro(defaults: defaults) { [weak self] in self?.checks += 1 }
    }

    func testUntilContinueNoCheckRuns() {
        let intro = intro()
        XCTAssertTrue(intro.shown)
        intro.check()
        intro.check()
        XCTAssertEqual(checks, 0, "a check would make iOS ask before the screen says why")
    }

    func testContinueChecksAtOnceAndEveryCheckRunsAfterThat() {
        let intro = intro()
        intro.finish()
        XCTAssertFalse(intro.shown)
        XCTAssertEqual(checks, 1, "Continue is what makes iOS ask")
        intro.check()
        XCTAssertEqual(checks, 2)
    }

    func testItShowsOnceAcrossLaunches() {
        intro().finish()
        let next = intro()
        XCTAssertFalse(next.shown)
        next.check()
        XCTAssertEqual(checks, 2)
    }
}
