import XCTest
@testable import TetherCore

/// The speeds from two samples of the server's totals.
final class TrafficSamplerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheFirstSampleHasNothingToCompareWith() {
        var sampler = TrafficSampler()
        XCTAssertNil(sampler.sample(TrafficTotals(bytesUp: 1000, bytesDown: 5000), at: start))
    }

    func testSpeedsAreBitsPerSecondBetweenTwoSamples() {
        var sampler = TrafficSampler()
        _ = sampler.sample(TrafficTotals(bytesUp: 1000, bytesDown: 5000), at: start)
        let speeds = sampler.sample(TrafficTotals(bytesUp: 2000, bytesDown: 9000), at: start.addingTimeInterval(2))
        XCTAssertEqual(speeds?.up, 4000)
        XCTAssertEqual(speeds?.down, 16000)
    }

    /// Two reads in the same instant would divide by zero: no speed, and the later one counts from there.
    func testNoTimeBetweenSamplesIsNoSpeed() {
        var sampler = TrafficSampler()
        _ = sampler.sample(TrafficTotals(bytesUp: 1000, bytesDown: 1000), at: start)
        XCTAssertNil(sampler.sample(TrafficTotals(bytesUp: 2000, bytesDown: 2000), at: start))
        let speeds = sampler.sample(TrafficTotals(bytesUp: 2000, bytesDown: 3000), at: start.addingTimeInterval(1))
        XCTAssertEqual(speeds?.up, 0)
        XCTAssertEqual(speeds?.down, 8000)
    }

    /// The server's counters never go backwards. If they do, it's no speed rather than a huge one.
    func testACounterGoingBackwardsIsNoSpeed() {
        var sampler = TrafficSampler()
        _ = sampler.sample(TrafficTotals(bytesUp: 5000, bytesDown: 5000), at: start)
        let speeds = sampler.sample(TrafficTotals(bytesUp: 1000, bytesDown: 6000), at: start.addingTimeInterval(1))
        XCTAssertEqual(speeds?.up, 0)
        XCTAssertEqual(speeds?.down, 8000)
    }

    /// After a reset (off screen, a new hotspot) the time away isn't averaged in.
    func testAResetStartsOver() {
        var sampler = TrafficSampler()
        _ = sampler.sample(TrafficTotals(bytesUp: 1000, bytesDown: 1000), at: start)
        sampler.reset()
        XCTAssertNil(sampler.sample(TrafficTotals(bytesUp: 9000, bytesDown: 9000), at: start.addingTimeInterval(600)))
    }
}

/// When each device last sent anything, keepalives too (#63).
final class PeerActivityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func peers(_ received: UInt64) -> [String: PeerStats] {
        ["10.7.0.2": PeerStats(received: received)]
    }

    func testADeviceIsLiveForAMinuteAfterItsCountWentUp() {
        var activity = PeerActivity()
        activity.read(peers(100), at: start)
        XCTAssertFalse(activity.live("10.7.0.2", at: start), "read once: when it went up isn't known")
        activity.read(peers(132), at: start.addingTimeInterval(10))
        activity.read(peers(132), at: start.addingTimeInterval(20))
        XCTAssertTrue(activity.live("10.7.0.2", at: start.addingTimeInterval(10 + PeerActivity.liveFor - 1)))
        XCTAssertFalse(activity.live("10.7.0.2", at: start.addingTimeInterval(10 + PeerActivity.liveFor)))
        XCTAssertFalse(activity.live("10.7.0.3", at: start), "a device it never read")
    }

    /// A server that started again counts from zero: that isn't the device sending.
    func testACountThatStartsOverIsntActivity() {
        var activity = PeerActivity()
        activity.read(peers(100), at: start)
        activity.read(peers(0), at: start.addingTimeInterval(1))
        XCTAssertFalse(activity.live("10.7.0.2", at: start.addingTimeInterval(1)))
        activity.read(peers(32), at: start.addingTimeInterval(2))
        XCTAssertTrue(activity.live("10.7.0.2", at: start.addingTimeInterval(2)))
    }

    func testARemovedDeviceIsForgotten() {
        var activity = PeerActivity()
        activity.read(peers(100), at: start)
        activity.read(peers(132), at: start.addingTimeInterval(1))
        activity.read([:], at: start.addingTimeInterval(2))
        activity.read(peers(132), at: start.addingTimeInterval(3))
        XCTAssertFalse(activity.live("10.7.0.2", at: start.addingTimeInterval(3)))
    }
}
