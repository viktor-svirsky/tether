import XCTest
@testable import TetherCore

/// A limit picked on a device's or the proxy's screen that pauses it at once asks first (L1).
final class LimitPausesNowTests: XCTestCase {
    private let gb: UInt64 = 1_000_000_000

    func testALimitUnderWhatItUsedPausesNow() {
        XCTAssertTrue(LimitRules.pausesNow(1 * gb, current: nil, used: 3_120_000_000, paused: nil))
        XCTAssertTrue(LimitRules.pausesNow(5 * gb, current: 10 * gb, used: 9 * gb, paused: nil), "lowered under it")
    }

    func testALimitAtWhatItUsedPausesNow() {
        XCTAssertTrue(LimitRules.pausesNow(5 * gb, current: nil, used: 5 * gb, paused: nil))
    }

    func testALimitOverWhatItUsedDoesnt() {
        XCTAssertFalse(LimitRules.pausesNow(10 * gb, current: nil, used: 3 * gb, paused: nil))
    }

    func testNoLimitDoesnt() {
        XCTAssertFalse(LimitRules.pausesNow(nil, current: 1 * gb, used: 3 * gb, paused: nil))
    }

    /// Paused already: by the person, for a time or at its limit. Nothing changes at once.
    func testAPausedDeviceDoesnt() {
        for pause in [WireGuardSetup.Pause.byYou, .atLimit, .until(Date())] {
            XCTAssertFalse(LimitRules.pausesNow(1 * gb, current: nil, used: 3 * gb, paused: pause), "\(pause)")
        }
    }

    /// The same limit picked again changes nothing, so a device resumed over it stays on.
    func testTheSameLimitAgainDoesnt() {
        XCTAssertFalse(LimitRules.pausesNow(1 * gb, current: 1 * gb, used: 3 * gb, paused: nil))
    }

    func testTheQuestionSaysWhatItUsedAndUntilWhen() {
        let question = LimitRules.PausesNowQuestion(name: "iPad", used: 3_120_000_000, limit: 1 * gb, resets: "December 1")
        XCTAssertEqual(question.title, "iPad already used 3.12 GB")
        XCTAssertEqual(question.message, "With a 1 GB limit it pauses now, until the count resets on December 1.")
        XCTAssertEqual(LimitRules.PausesNowQuestion.confirm, "Set the limit and pause it")
    }
}
