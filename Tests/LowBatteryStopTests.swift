import XCTest
@testable import TetherCore

/// When the battery stops sharing (#311). Sharing stopping, the notice and Start Tether are in
/// HotspotSessionTests, NotifierTests and ShortcutReplyTests.
final class LowBatteryStopTests: XCTestCase {
    private typealias Battery = LowBatteryStop.Battery

    func testTheMenuHasNeverAndThreeLevels() {
        XCTAssertEqual(LowBatteryStop.Level.default, .never)
        XCTAssertEqual(LowBatteryStop.Level.allCases.map(\.label), ["Never", "At 10%", "At 20%", "At 30%"])
        XCTAssertEqual(LowBatteryStop.Level.allCases.map(\.percent), [nil, 10, 20, 30])
    }

    func testTheLevelIsSaved() {
        let defaults = UserDefaults(suiteName: "LowBatteryStopTests")!
        defaults.removePersistentDomain(forName: "LowBatteryStopTests")
        XCTAssertEqual(LowBatteryStop.Level.saved(in: defaults), .never, "nothing saved")
        defaults.set(20, forKey: LowBatteryStop.Level.key)
        XCTAssertEqual(LowBatteryStop.Level.saved(in: defaults), .twenty)
        defaults.set(15, forKey: LowBatteryStop.Level.key)
        XCTAssertEqual(LowBatteryStop.Level.saved(in: defaults), .never, "a value no menu has")
    }

    func testLowAtOrBelowTheLevel() {
        XCTAssertFalse(LowBatteryStop.low(Battery(percent: 21, charging: false), at: .twenty))
        XCTAssertTrue(LowBatteryStop.low(Battery(percent: 20, charging: false), at: .twenty), "at it, whatever steps iOS reports in")
        XCTAssertTrue(LowBatteryStop.low(Battery(percent: 5, charging: false), at: .twenty))
    }

    func testNeverLowWhileChargingUnknownOrOff() {
        XCTAssertFalse(LowBatteryStop.low(Battery(percent: 5, charging: true), at: .twenty), "charging or full")
        XCTAssertFalse(LowBatteryStop.low(.unknown, at: .thirty), "iOS can't say")
        XCTAssertFalse(LowBatteryStop.low(Battery(percent: 1, charging: false), at: .never))
    }

    func testTheMainScreenLine() {
        XCTAssertEqual(BelowBatteryStop(percent: 15, level: .twenty).text,
                       "Battery is at 15%, at or below your 20% stop level. Sharing stops when you leave Tether.")
    }
}
