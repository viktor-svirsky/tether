import XCTest
@testable import TetherCore

/// The day the counts and the limits start over (#187), as Settings saves it.
final class ResetDayTests: XCTestCase {
    func testTheSavedDayIsThe1stUnlessADayIsSet() {
        let defaults = UserDefaults(suiteName: "ResetDayTests")!
        defaults.removePersistentDomain(forName: "ResetDayTests")
        defer { defaults.removePersistentDomain(forName: "ResetDayTests") }
        XCTAssertEqual(ResetDay.saved(in: defaults), .first, "nothing saved")
        defaults.set(15, forKey: ResetDay.key)
        XCTAssertEqual(ResetDay.saved(in: defaults).day, 15)
        defaults.set(31, forKey: ResetDay.key)
        XCTAssertEqual(ResetDay.saved(in: defaults), .lastDay)
        for wrong in [0, 32, -1] {
            defaults.set(wrong, forKey: ResetDay.key)
            XCTAssertEqual(ResetDay.saved(in: defaults), .first, "\(wrong) isn't a day")
        }
    }

    func testOnlyDaysOfAMonth() {
        XCTAssertNil(ResetDay(0))
        XCTAssertNil(ResetDay(32))
        XCTAssertEqual(ResetDay(28)?.day, 28)
        XCTAssertEqual(ResetDay.default, .first)
    }
}
