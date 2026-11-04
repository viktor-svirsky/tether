import XCTest
@testable import TetherCore

/// When sharing stops after a time with no device connected (#76): only in the background, only
/// while sharing, and counted from the last connected device or from leaving the screen.
final class IdleStopTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func minutes(_ m: Double) -> Date { start.addingTimeInterval(m * 60) }

    private func round(_ stop: inout IdleStop, at m: Double, sharing: Bool = true, connected: Bool = false,
                       onScreen: Bool = false, after: IdleStop.After = .thirtyMinutes) -> Bool {
        stop.check(sharing: sharing, connected: connected, onScreen: onScreen, after: after, now: minutes(m))
    }

    func testItStopsAfterTheSetTimeWithNoDevice() {
        var stop = IdleStop()
        XCTAssertFalse(round(&stop, at: 0))
        XCTAssertFalse(round(&stop, at: 29.9))
        XCTAssertTrue(round(&stop, at: 30))
    }

    func testNeverIsTheDefaultAndNeverStops() {
        XCTAssertEqual(IdleStop.After.default, .never)
        var stop = IdleStop()
        XCTAssertFalse(round(&stop, at: 0, after: .never))
        XCTAssertFalse(round(&stop, at: 24 * 60, after: .never))
    }

    func testAConnectedDeviceStartsItOver() {
        var stop = IdleStop()
        _ = round(&stop, at: 0)
        XCTAssertFalse(round(&stop, at: 20, connected: true))
        // The next round sees nobody: the 30 minutes run from there.
        XCTAssertFalse(round(&stop, at: 20.25))
        XCTAssertFalse(round(&stop, at: 50))
        XCTAssertTrue(round(&stop, at: 50.25))
    }

    /// On screen the person sees it isn't sharing anything, and stopping there would be a surprise.
    /// The time runs from leaving the screen, like the keep-alive's 10 minutes.
    func testOnScreenNeverStopsAndLeavingStartsTheClock() {
        var stop = IdleStop()
        XCTAssertFalse(round(&stop, at: 0, onScreen: true))
        XCTAssertFalse(round(&stop, at: 60, onScreen: true))
        XCTAssertFalse(round(&stop, at: 61))
        XCTAssertFalse(round(&stop, at: 90.9))
        XCTAssertTrue(round(&stop, at: 91))
    }

    /// Without sharing (the hotspot off, WireGuard not running) there's nothing to stop, and the
    /// time without it doesn't count.
    func testNotSharingDoesntCount() {
        var stop = IdleStop()
        _ = round(&stop, at: 0)
        XCTAssertFalse(round(&stop, at: 40, sharing: false))
        XCTAssertFalse(round(&stop, at: 41))
        XCTAssertTrue(round(&stop, at: 71))
    }

    /// A setting changed to a shorter time counts the idle time so far.
    func testAShorterSettingCountsTheTimeSoFar() {
        var stop = IdleStop()
        _ = round(&stop, at: 0)
        XCTAssertFalse(round(&stop, at: 9))
        XCTAssertTrue(round(&stop, at: 10, after: .tenMinutes))
    }

    /// After a stop, iOS suspends Tether, and the next thing that runs is often opening it or Start
    /// Tether, which shares again before any round sees sharing off. It counts from there again.
    func testSharingAgainRightAfterAStopCountsAgain() {
        var stop = IdleStop()
        _ = round(&stop, at: 0)
        XCTAssertTrue(round(&stop, at: 30))
        XCTAssertFalse(round(&stop, at: 31))
        XCTAssertFalse(round(&stop, at: 60.9))
        XCTAssertTrue(round(&stop, at: 61))
    }

    func testTheChoicesAndTheirWords() {
        XCTAssertEqual(IdleStop.After.allCases, [.never, .tenMinutes, .thirtyMinutes, .oneHour])
        XCTAssertEqual(IdleStop.After.allCases.map(\.label), ["Never", "After 10 min", "After 30 min", "After 1 hour"])
        XCTAssertEqual(IdleStop.After.allCases.map(\.seconds), [nil, 600, 1800, 3600])
        XCTAssertEqual(IdleStop.After.allCases.map(\.spelledOut), ["", "10 minutes", "30 minutes", "1 hour"])
    }

    func testTheSettingIsSavedAndAnUnknownValueIsNever() {
        let defaults = UserDefaults(suiteName: "IdleStopTests")!
        defaults.removePersistentDomain(forName: "IdleStopTests")
        defer { defaults.removePersistentDomain(forName: "IdleStopTests") }
        XCTAssertEqual(IdleStop.After.saved(in: defaults), .never)
        defaults.set(IdleStop.After.oneHour.rawValue, forKey: IdleStop.After.key)
        XCTAssertEqual(IdleStop.After.saved(in: defaults), .oneHour)
        defaults.set(42, forKey: IdleStop.After.key)
        XCTAssertEqual(IdleStop.After.saved(in: defaults), .never)
    }
}
