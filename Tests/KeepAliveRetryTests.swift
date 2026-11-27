import XCTest
@testable import TetherCore

final class KeepAliveRetryTests: XCTestCase {
    /// A sound that starts playing at a given try, and a clock that runs the waiting work by hand.
    private final class Fake {
        var startsUntilSound: Int
        var starts = 0
        var waits: [(TimeInterval, () -> Void)] = []
        var lines: [String] = []
        var done = 0
        init(soundsAtTry: Int) { startsUntilSound = soundsAtTry }

        lazy var retry = KeepAliveRetry(
            start: { [unowned self] in starts += 1 },
            sounding: { [unowned self] in starts >= startsUntilSound },
            after: { [unowned self] seconds, work in waits.append((seconds, work)) },
            log: { [unowned self] in lines.append($0) },
            done: { [unowned self] in done += 1 })

        /// Runs the next waiting work, as a second passing would.
        func tick() {
            guard !waits.isEmpty else { return XCTFail("nothing waits") }
            waits.removeFirst().1()
        }
    }

    func testASoundThatPlaysAtOnceEndsTheHoldWithNoWait() {
        let fake = Fake(soundsAtTry: 1)
        fake.retry.run(after: .interruptionBegan) { true }
        XCTAssertEqual(fake.starts, 1)
        XCTAssertEqual(fake.done, 1)
        XCTAssertTrue(fake.waits.isEmpty)
        XCTAssertEqual(fake.lines, ["keep-alive sound back after the interruption began, 1 try"])
    }

    func testASilentSoundIsTriedAgainEverySecondUntilItPlays() {
        let fake = Fake(soundsAtTry: 3)
        fake.retry.run(after: .interruptionEnded) { true }
        XCTAssertEqual(fake.starts, 1)
        XCTAssertEqual(fake.waits.map(\.0), [1])
        fake.tick()
        XCTAssertEqual(fake.starts, 2)
        XCTAssertEqual(fake.done, 0, "still silent: the hold goes on")
        fake.tick()
        XCTAssertEqual(fake.starts, 3)
        XCTAssertEqual(fake.done, 1)
        XCTAssertTrue(fake.waits.isEmpty, "playing: no more tries")
        XCTAssertEqual(fake.lines, ["keep-alive sound back after the interruption, 3 tries"])
    }

    func testATryFromAHoldThatEndedDoesNothing() {
        let fake = Fake(soundsAtTry: 5)
        var holding = true
        fake.retry.run(after: .mediaServicesLost) { holding }
        holding = false // the background time ran out, or a newer hold took over
        fake.tick()
        XCTAssertEqual(fake.starts, 1, "no start after the hold ended")
        XCTAssertTrue(fake.waits.isEmpty)
        XCTAssertEqual(fake.done, 0)
        XCTAssertTrue(fake.lines.isEmpty)
    }

    func testAHoldThatAlreadyEndedNeverStarts() {
        let fake = Fake(soundsAtTry: 1)
        fake.retry.run(after: .interruptionBegan) { false }
        XCTAssertEqual(fake.starts, 0)
        XCTAssertEqual(fake.done, 0)
    }

    func testTheLogSaysWhatLeftTheSoundSilent() {
        XCTAssertEqual(KeepAliveRetry.back(after: .mediaServicesLost, tries: 2),
                       "keep-alive sound back after the media services were lost, 2 tries")
        XCTAssertEqual(KeepAliveRetry.back(after: .interruptionBegan, tries: 1),
                       "keep-alive sound back after the interruption began, 1 try")
        XCTAssertEqual(KeepAliveRetry.back(after: .interruptionEnded, tries: 4),
                       "keep-alive sound back after the interruption, 4 tries")
    }
}
