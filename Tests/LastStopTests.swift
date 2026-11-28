import XCTest
@testable import TetherCore

/// The note on Home after sharing stopped by itself or from a widget (H3). In New York time and US
/// English, so the runner's time zone and region don't change it.
final class LastStopTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    private let us = Locale(identifier: "en_US")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func said(_ stop: LastStop, now: Date) -> String {
        stop.text(now: now, calendar: calendar, locale: us).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func testEachReasonHasItsSentence() {
        let now = date(2026, 10, 17, 18)
        let at = date(2026, 10, 17, 14, 5)
        XCTAssertEqual(said(LastStop(at: at, reason: .idle(.thirtyMinutes)), now: now),
                       "Sharing stopped today at 2:05 PM. No device was connected for 30 minutes.")
        XCTAssertEqual(said(LastStop(at: at, reason: .lowBattery(.twenty)), now: now),
                       "Sharing stopped today at 2:05 PM. The battery reached 20%.")
        XCTAssertEqual(said(LastStop(at: at, reason: .byYou), now: now),
                       "You stopped sharing today at 2:05 PM, from a widget or Control Center.")
    }

    /// Today, yesterday, or the date, the way a device's last connection says it.
    func testTheDayIsTodayYesterdayOrTheDate() {
        let now = date(2026, 10, 17, 18)
        let idle = { LastStop(at: $0, reason: .idle(.oneHour)) }
        XCTAssertEqual(said(idle(date(2026, 10, 16, 23, 59)), now: now),
                       "Sharing stopped yesterday at 11:59 PM. No device was connected for 1 hour.")
        XCTAssertEqual(said(idle(date(2026, 10, 3, 9, 12)), now: now),
                       "Sharing stopped on October 3 at 9:12 AM. No device was connected for 1 hour.")
        XCTAssertEqual(said(idle(date(2025, 12, 30, 9, 12)), now: now),
                       "Sharing stopped on December 30, 2025 at 9:12 AM. No device was connected for 1 hour.")
    }

    /// What the session stopped for, as `HotspotSession` records it.
    func testItTakesTheReasonTheSessionStoppedFor() {
        let at = date(2026, 10, 17, 14)
        XCTAssertEqual(LastStop(IdleStopped(at: at, after: .tenMinutes)).reason, .idle(.tenMinutes))
        XCTAssertEqual(LastStop(IdleStopped(at: at, after: .tenMinutes, lowBattery: .ten)).reason, .lowBattery(.ten))
        XCTAssertEqual(LastStop(IdleStopped(at: at, after: .never, byYou: true)).reason, .byYou)
        XCTAssertEqual(LastStop(IdleStopped(at: at, after: .never)).at, at)
    }

    /// Saved, since iOS can end Tether right after a stop. A newer one replaces it, and Got it clears it.
    func testItIsSavedReplacedAndCleared() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LastStopTests"))
        defaults.removePersistentDomain(forName: "LastStopTests")
        XCTAssertNil(LastStop.load(from: defaults))
        let first = LastStop(at: date(2026, 10, 17, 14), reason: .idle(.tenMinutes))
        first.save(to: defaults)
        XCTAssertEqual(LastStop.load(from: defaults), first)
        let second = LastStop(at: date(2026, 10, 17, 15), reason: .lowBattery(.twenty))
        second.save(to: defaults)
        XCTAssertEqual(LastStop.load(from: defaults), second)
        LastStop.clear(in: defaults)
        XCTAssertNil(LastStop.load(from: defaults))
        defaults.set(Data("not a stop".utf8), forKey: LastStop.key)
        XCTAssertNil(LastStop.load(from: defaults), "something unreadable is no note")
        defaults.removePersistentDomain(forName: "LastStopTests")
    }
}
