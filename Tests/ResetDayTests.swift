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

    /// Settings' menu: the 1st to the 28th, then Last day, saved as 31.
    func testTheMenuIsTheFirstTo28thThenLastDay() {
        XCTAssertEqual(ResetDay.choices.count, 29)
        XCTAssertEqual(ResetDay.choices.first, .first)
        XCTAssertEqual(ResetDay.choices.dropLast().last?.day, 28)
        XCTAssertEqual(ResetDay.choices.last, .lastDay)
        XCTAssertEqual(ResetDay.lastDay.day, 31)
        XCTAssertEqual(ResetDay.choices.map(\.label).prefix(4), ["1st", "2nd", "3rd", "4th"])
        XCTAssertEqual([11, 12, 13, 21, 22, 23, 28].compactMap(ResetDay.init).map(\.label),
                       ["11th", "12th", "13th", "21st", "22nd", "23rd", "28th"])
        XCTAssertEqual(ResetDay.lastDay.label, "Last day")
    }

    func testOnlyDaysOfAMonth() {
        XCTAssertNil(ResetDay(0))
        XCTAssertNil(ResetDay(32))
        XCTAssertEqual(ResetDay(28)?.day, 28)
        XCTAssertEqual(ResetDay.default, .first)
    }
}
