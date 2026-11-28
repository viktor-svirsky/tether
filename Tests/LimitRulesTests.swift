import XCTest
@testable import TetherCore

final class LimitRulesTests: XCTestCase {
    private let id = WireGuardSetup.Peer.ID()
    private let gb: UInt64 = 1_000_000_000

    private func device(paused: WireGuardSetup.Pause? = nil, limit: UInt64? = nil, used: UInt64 = 0,
                        resumedOver: Bool = false, nearTold: Bool = false) -> LimitRules.Device {
        LimitRules.Device(id: id, name: "iPad", paused: paused, limit: limit, used: used,
                          resumedOver: resumedOver, nearTold: nearTold)
    }

    func testNoLimitAsksForNothing() {
        XCTAssertNil(LimitRules.action(for: device(used: 50 * gb)))
    }

    func testUnderNinetyPercentAsksForNothing() {
        XCTAssertNil(LimitRules.action(for: device(limit: 10 * gb, used: 8 * gb)))
    }

    func testAtNinetyPercentTellsOnce() {
        XCTAssertEqual(LimitRules.action(for: device(limit: 10 * gb, used: 9 * gb)), .near)
        XCTAssertNil(LimitRules.action(for: device(limit: 10 * gb, used: 9 * gb, nearTold: true)))
    }

    func testAtTheLimitPauses() {
        XCTAssertEqual(LimitRules.action(for: device(limit: 10 * gb, used: 10 * gb)), .pauseAtLimit)
        XCTAssertEqual(LimitRules.action(for: device(limit: 10 * gb, used: 12 * gb, nearTold: true)), .pauseAtLimit)
    }

    func testResumedOverItsLimitStaysOn() {
        XCTAssertNil(LimitRules.action(for: device(limit: 10 * gb, used: 12 * gb, resumedOver: true)))
    }

    func testPausedAtItsLimitResumesUnderIt() {
        XCTAssertEqual(LimitRules.action(for: device(paused: .atLimit, limit: 10 * gb, used: 0)), .resume)
        XCTAssertNil(LimitRules.action(for: device(paused: .atLimit, limit: 10 * gb, used: 10 * gb)))
    }

    func testPausedAtItsLimitResumesWhenTheLimitGoes() {
        XCTAssertEqual(LimitRules.action(for: device(paused: .atLimit, used: 12 * gb)), .resume)
    }

    func testAPauseByThePersonOrForATimeKeepsItsPause() {
        XCTAssertNil(LimitRules.action(for: device(paused: .byYou, limit: 10 * gb, used: 12 * gb)))
        let until = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(LimitRules.action(for: device(paused: .until(until), limit: 10 * gb, used: 0)))
    }

    func testATimedPauseIsOverAtItsEndNotBefore() {
        let end = Date(timeIntervalSince1970: 1_000)
        let timed = device(paused: .until(end))
        XCTAssertEqual(LimitRules.timedPausesOver([timed], at: end.addingTimeInterval(-1)), [])
        XCTAssertEqual(LimitRules.timedPausesOver([timed], at: end), [id])
        XCTAssertEqual(LimitRules.timedPausesOver([timed], at: end.addingTimeInterval(3_600)), [id])
    }

    /// Read as not paused once its time is up, a device over its limit is paused at it, one under it
    /// isn't, and until then its timed pause stands.
    func testATimedPauseThatEndedOverTheLimitPausesAtIt() {
        XCTAssertNil(LimitRules.action(for: device(paused: .until(Date(timeIntervalSince1970: 1_000)), limit: 10 * gb, used: 12 * gb)))
        XCTAssertEqual(LimitRules.action(for: device(limit: 10 * gb, used: 12 * gb)), .pauseAtLimit)
        XCTAssertNil(LimitRules.action(for: device(limit: 10 * gb, used: 1 * gb)))
    }

    func testOnlyTimedPausesEnd() {
        let at = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(LimitRules.timedPausesOver([device(paused: .byYou), device(paused: .atLimit), device()], at: at), [])
    }
}
