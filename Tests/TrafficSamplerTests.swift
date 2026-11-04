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
