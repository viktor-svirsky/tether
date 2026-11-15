import XCTest
@testable import TetherCore

/// Each device's data per period (#75, #187): what a read of the growing counters adds, the period
/// turning over, a clock set back, a relaunch where the counters start at zero again, and saving.
final class MonthlyUsageTests: XCTestCase {
    private let ipad = UUID(), mac = UUID()
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func t(_ up: UInt64, _ down: UInt64) -> TrafficTotals { TrafficTotals(bytesUp: up, bytesDown: down) }

    private func record(_ usage: inout MonthlyUsage, _ counts: [UUID: TrafficTotals], _ at: Date) {
        usage.record(counts, at: at, calendar: calendar)
    }

    func testEachReadAddsWhatTheCountersGrewBy() {
        var usage = MonthlyUsage()
        record(&usage, [ipad: t(10, 100)], date(2026, 11, 5))
        record(&usage, [ipad: t(15, 300), mac: t(1, 1)], date(2026, 11, 6))
        record(&usage, [ipad: t(15, 300), mac: t(1, 1)], date(2026, 11, 6, 13)) // the same read again, on screen and in the background
        XCTAssertEqual(usage.of(ipad, at: date(2026, 11, 7), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(15, 300), lastMonth: t(0, 0)))
        XCTAssertEqual(usage.of(mac, at: date(2026, 11, 7), calendar: calendar).thisMonth, t(1, 1))
        XCTAssertEqual(usage.of(UUID(), at: date(2026, 11, 7), calendar: calendar), MonthlyUsage.Usage(), "never seen")
    }

    /// Tether relaunched: the server's counters start from zero, so a read lower than the last one
    /// counts as all new.
    func testCountersThatStartOverCountInFull() {
        var usage = MonthlyUsage()
        record(&usage, [ipad: t(10, 1000)], date(2026, 11, 5))
        record(&usage, [ipad: t(2, 30)], date(2026, 11, 5, 13))
        XCTAssertEqual(usage.of(ipad, at: date(2026, 11, 5, 14), calendar: calendar).thisMonth, t(12, 1030))
    }

    /// Data on the 30th counts for November, on the 1st for December, which then shows November as
    /// last month. In New York's time, not the UTC date.
    func testTheMonthTurnsOverOnThe1st() {
        var usage = MonthlyUsage()
        record(&usage, [ipad: t(0, 500)], date(2026, 11, 30, 23))
        record(&usage, [ipad: t(0, 700)], date(2026, 12, 1, 0))
        XCTAssertEqual(usage.of(ipad, at: date(2026, 12, 1, 1), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 200), lastMonth: t(0, 500)))
    }

    /// Nothing read since: a read in the next month still shows the old month as last month, and
    /// two months later both are empty, not a stale "this month".
    func testMonthsWithNoReadRollOverWhenShown() {
        var usage = MonthlyUsage()
        record(&usage, [ipad: t(0, 500)], date(2026, 11, 20))
        XCTAssertEqual(usage.of(ipad, at: date(2026, 12, 3), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 0), lastMonth: t(0, 500)))
        XCTAssertEqual(usage.of(ipad, at: date(2027, 1, 3), calendar: calendar), MonthlyUsage.Usage())
        record(&usage, [ipad: t(0, 600)], date(2027, 1, 3))
        XCTAssertEqual(usage.of(ipad, at: date(2027, 1, 4), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 100), lastMonth: t(0, 0)))
    }

    /// The clock set back a month (or a time zone change across the 1st): it never rolls back, and a
    /// read for last month adds to last month.
    func testAClockSetBackAddsToTheMonthItSays() {
        var usage = MonthlyUsage()
        record(&usage, [ipad: t(0, 100)], date(2026, 12, 2))
        record(&usage, [ipad: t(0, 150)], date(2026, 11, 30))
        record(&usage, [ipad: t(0, 175)], date(2026, 9, 30)) // older than last month: nowhere to put it
        XCTAssertEqual(usage.of(ipad, at: date(2026, 12, 3), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 100), lastMonth: t(0, 50)))
    }

    func testARemovedDeviceIsDropped() {
        var usage = MonthlyUsage()
        record(&usage, [ipad: t(0, 100), mac: t(0, 5)], date(2026, 11, 5))
        usage.keep(only: [mac])
        XCTAssertEqual(usage.of(ipad, at: date(2026, 11, 5), calendar: calendar), MonthlyUsage.Usage())
        XCTAssertEqual(usage.of(mac, at: date(2026, 11, 5), calendar: calendar).thisMonth, t(0, 5))
    }

    /// Saved and read back after a relaunch, where the counters start over: what was counted stays,
    /// and the first read adds in full.
    func testItSurvivesARelaunch() {
        let defaults = UserDefaults(suiteName: "MonthlyUsageTests")!
        defaults.removePersistentDomain(forName: "MonthlyUsageTests")
        defer { defaults.removePersistentDomain(forName: "MonthlyUsageTests") }
        XCTAssertEqual(MonthlyUsage.load(from: defaults), MonthlyUsage(), "nothing saved")
        var usage = MonthlyUsage()
        record(&usage, [ipad: t(0, 1000)], date(2026, 11, 5))
        usage.save(to: defaults)
        var relaunched = MonthlyUsage.load(from: defaults)
        record(&relaunched, [ipad: t(0, 40)], date(2026, 11, 6))
        XCTAssertEqual(relaunched.of(ipad, at: date(2026, 11, 6), calendar: calendar).thisMonth, t(0, 1040))
        defaults.set(Data("not usage".utf8), forKey: MonthlyUsage.key)
        XCTAssertEqual(MonthlyUsage.load(from: defaults), MonthlyUsage(), "unreadable starts over")
    }

    /// When each device last connected (#73): each read's handshake replaces the last, and a read
    /// with none, such as a stopped server, keeps it.
    func testTheLastHandshakeIsKeptByDeviceUntilAReadHasOne() {
        var usage = MonthlyUsage()
        XCTAssertNil(usage.lastConnected(ipad), "never connected")
        usage.record([ipad: t(0, 1)], handshakes: [ipad: date(2026, 11, 5, 9), mac: date(2026, 11, 5, 10)], at: date(2026, 11, 5), calendar: calendar)
        usage.record([ipad: t(0, 1)], handshakes: [ipad: date(2026, 11, 5, 11)], at: date(2026, 11, 5, 11), calendar: calendar)
        usage.record([ipad: t(0, 1)], at: date(2026, 11, 5, 13), calendar: calendar) // stopped: no handshake
        XCTAssertEqual(usage.lastConnected(ipad), date(2026, 11, 5, 11))
        XCTAssertEqual(usage.lastConnected(mac), date(2026, 11, 5, 10), "kept with no data")
        usage.keep(only: [mac])
        XCTAssertNil(usage.lastConnected(ipad), "dropped with the device")
    }

    /// A paused device's handshakes don't count, nor the same one read again after Resume. A new
    /// one does.
    func testAPausedDevicesHandshakeCountsOnlyOnceANewOneComes() {
        var usage = MonthlyUsage()
        usage.record([:], handshakes: [ipad: date(2026, 11, 5, 9)], at: date(2026, 11, 5, 9), calendar: calendar)
        usage.record([:], handshakes: [ipad: date(2026, 11, 5, 10)], paused: [ipad], at: date(2026, 11, 5, 10), calendar: calendar)
        XCTAssertEqual(usage.lastConnected(ipad), date(2026, 11, 5, 9))
        usage.record([:], handshakes: [ipad: date(2026, 11, 5, 10)], at: date(2026, 11, 5, 11), calendar: calendar) // resumed
        XCTAssertEqual(usage.lastConnected(ipad), date(2026, 11, 5, 9))
        usage.record([:], handshakes: [ipad: date(2026, 11, 5, 12)], at: date(2026, 11, 5, 12), calendar: calendar)
        XCTAssertEqual(usage.lastConnected(ipad), date(2026, 11, 5, 12))
        usage.record([:], handshakes: [ipad: date(2026, 11, 5, 10)], at: date(2026, 11, 5, 13), calendar: calendar)
        XCTAssertEqual(usage.lastConnected(ipad), date(2026, 11, 5, 10), "the pause's handshake is forgotten once a new one came")
    }

    /// The clock was ahead, then set right: the next handshake shows, not the one from the clock that
    /// was ahead, which would read as a time still to come.
    func testAClockSetBackDoesntKeepAHandshakeFromTheFuture() {
        var usage = MonthlyUsage()
        usage.record([:], handshakes: [ipad: date(2026, 11, 5, 21)], at: date(2026, 11, 5, 21), calendar: calendar)
        usage.record([:], handshakes: [ipad: date(2026, 11, 5, 15)], at: date(2026, 11, 5, 15), calendar: calendar)
        XCTAssertEqual(usage.lastConnected(ipad), date(2026, 11, 5, 15))
    }

    /// Saved with the data, so it outlives a relaunch, where the server knows no handshake yet.
    func testTheLastHandshakeSurvivesARelaunch() {
        let defaults = UserDefaults(suiteName: "MonthlyUsageTests.handshakes")!
        defaults.removePersistentDomain(forName: "MonthlyUsageTests.handshakes")
        defer { defaults.removePersistentDomain(forName: "MonthlyUsageTests.handshakes") }
        var usage = MonthlyUsage()
        usage.record([:], handshakes: [ipad: date(2026, 11, 5, 9)], at: date(2026, 11, 5), calendar: calendar)
        XCTAssertNotEqual(usage, MonthlyUsage(), "a new handshake is a change to save")
        usage.save(to: defaults)
        XCTAssertEqual(MonthlyUsage.load(from: defaults).lastConnected(ipad), date(2026, 11, 5, 9))
    }

    /// Data saved before Tether kept handshakes still reads, and its devices say Never until they
    /// connect again.
    func testDataSavedBeforeHandshakesWereKeptReadsWithNone() throws {
        var usage = MonthlyUsage()
        usage.record([ipad: t(0, 100)], handshakes: [ipad: date(2026, 11, 5, 9)], at: date(2026, 11, 5), calendar: calendar)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(usage)) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "lastHandshakes"))
        let old = try JSONDecoder().decode(MonthlyUsage.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.of(ipad, at: date(2026, 11, 5), calendar: calendar).thisMonth, t(0, 100))
        XCTAssertNil(old.lastConnected(ipad))
    }

    func testTheTotalIsBothWays() {
        XCTAssertEqual(t(3, 4).total, 7)
        XCTAssertEqual(t(.max, 4).total, .max, "never wraps")
    }

    // MARK: The reset day (#187)

    private func midnight(_ year: Int, _ month: Int, _ day: Int) -> Date { date(year, month, day, 0) }

    /// Reset on the 15th: the 14th still counts for the period that started on the 15th of the month
    /// before, and the 15th starts a new one.
    func testOnTheFifteenthANewPeriodStarts() {
        var usage = MonthlyUsage(resetDay: ResetDay(15)!)
        record(&usage, [ipad: t(0, 50)], midnight(2026, 10, 15))
        record(&usage, [ipad: t(0, 150)], date(2026, 11, 14, 23))
        XCTAssertEqual(usage.of(ipad, at: date(2026, 11, 14, 23), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 150), lastMonth: t(0, 0)))
        XCTAssertEqual(usage.nextReset(at: date(2026, 11, 14, 23), calendar: calendar), midnight(2026, 11, 15))
        record(&usage, [ipad: t(0, 170)], midnight(2026, 11, 15))
        XCTAssertEqual(usage.of(ipad, at: date(2026, 11, 15, 1), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 20), lastMonth: t(0, 150)))
        XCTAssertEqual(usage.nextReset(at: midnight(2026, 11, 15), calendar: calendar), midnight(2026, 12, 15))
        XCTAssertEqual(usage.of(ipad, at: date(2026, 12, 20), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 0), lastMonth: t(0, 20)),
                       "a period with no read since turns over when shown")
    }

    /// The last day, or a day a month doesn't have, resets on that month's last day: February 28, or
    /// 29 in a leap year, and April 30.
    func testADayAMonthDoesntHaveIsItsLastDay() {
        XCTAssertEqual(ResetDay.lastDay, ResetDay(31))
        let last = MonthlyUsage(resetDay: .lastDay)
        XCTAssertEqual(last.nextReset(at: date(2027, 2, 10), calendar: calendar), midnight(2027, 2, 28))
        XCTAssertEqual(last.nextReset(at: date(2027, 2, 28), calendar: calendar), midnight(2027, 3, 31))
        XCTAssertEqual(last.nextReset(at: date(2028, 2, 10), calendar: calendar), midnight(2028, 2, 29), "a leap year")
        XCTAssertEqual(last.nextReset(at: date(2026, 4, 10), calendar: calendar), midnight(2026, 4, 30))
        XCTAssertEqual(last.nextReset(at: date(2026, 4, 30), calendar: calendar), midnight(2026, 5, 31))
        let thirtieth = MonthlyUsage(resetDay: ResetDay(30)!)
        XCTAssertEqual(thirtieth.nextReset(at: date(2027, 2, 10), calendar: calendar), midnight(2027, 2, 28))
        XCTAssertEqual(thirtieth.nextReset(at: date(2027, 3, 10), calendar: calendar), midnight(2027, 3, 30), "not the 31st")

        var usage = MonthlyUsage(resetDay: .lastDay)
        record(&usage, [ipad: t(0, 100)], date(2027, 2, 27, 23))
        record(&usage, [ipad: t(0, 130)], midnight(2027, 2, 28))
        XCTAssertEqual(usage.of(ipad, at: date(2027, 3, 30), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 30), lastMonth: t(0, 100)))
        XCTAssertEqual(usage.of(ipad, at: date(2027, 3, 31), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 0), lastMonth: t(0, 30)))
    }

    /// The day changed mid-period: the running period ends on the new day's next date, with all it
    /// counted. From the 1st to the 15th on November 20, the period from November 1 runs to December
    /// 15, so the count doesn't start over twice within one of the carrier's periods.
    func testANewResetDayEndsTheRunningPeriodOnItsNextDate() {
        var usage = MonthlyUsage()
        record(&usage, [ipad: t(0, 100)], date(2026, 11, 5))
        usage.markResumedOver(ipad, at: date(2026, 11, 6), calendar: calendar)
        usage.setResetDay(ResetDay(15)!, at: date(2026, 11, 20), calendar: calendar)
        XCTAssertEqual(usage.resetDay, ResetDay(15))
        XCTAssertEqual(usage.nextReset(at: date(2026, 11, 20), calendar: calendar), midnight(2026, 12, 15))
        XCTAssertEqual(usage.of(ipad, at: date(2026, 12, 3), calendar: calendar).thisMonth, t(0, 100), "nothing counted is lost, nor on the 1st")
        XCTAssertTrue(usage.resumedOver(ipad, at: date(2026, 12, 3), calendar: calendar), "a resume holds to the new date")
        record(&usage, [ipad: t(0, 150)], date(2026, 12, 3))
        XCTAssertEqual(usage.of(ipad, at: date(2026, 12, 3), calendar: calendar).thisMonth, t(0, 150))
        record(&usage, [ipad: t(0, 170)], midnight(2026, 12, 15))
        XCTAssertEqual(usage.of(ipad, at: date(2026, 12, 15), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 20), lastMonth: t(0, 150)))
        XCTAssertFalse(usage.resumedOver(ipad, at: date(2026, 12, 15), calendar: calendar))
        XCTAssertEqual(usage.nextReset(at: date(2026, 12, 15), calendar: calendar), midnight(2027, 1, 15), "then every 15th")
    }

    /// From the 15th to the 1st on November 20: the period from November 15 ends on December 1.
    func testAnEarlierResetDayEndsThePeriodSooner() {
        var usage = MonthlyUsage(resetDay: ResetDay(15)!)
        record(&usage, [ipad: t(0, 100)], date(2026, 11, 16))
        XCTAssertEqual(usage.nextReset(at: date(2026, 11, 16), calendar: calendar), midnight(2026, 12, 15))
        usage.setResetDay(.first, at: date(2026, 11, 20), calendar: calendar)
        XCTAssertEqual(usage.nextReset(at: date(2026, 11, 20), calendar: calendar), midnight(2026, 12, 1))
        record(&usage, [ipad: t(0, 130)], midnight(2026, 12, 1))
        XCTAssertEqual(usage.of(ipad, at: date(2026, 12, 2), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 30), lastMonth: t(0, 100)))
        XCTAssertEqual(usage.nextReset(at: date(2026, 12, 2), calendar: calendar), midnight(2027, 1, 1))
    }

    /// A reset day starts in the time zone of the read, like the 1st did (#163): 3 AM UTC on November
    /// 15 is still the 14th in New York.
    func testTheResetDayStartsInTheTimeZoneOfTheRead() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let early = utc.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 3))!
        let usage = MonthlyUsage(resetDay: ResetDay(15)!)
        XCTAssertEqual(usage.nextReset(at: early, calendar: calendar), midnight(2026, 11, 15))
        XCTAssertEqual(usage.nextReset(at: early, calendar: utc), utc.date(from: DateComponents(year: 2026, month: 12, day: 15)))
    }

    /// The day and a change of it are saved with the data. Data saved before, by calendar month,
    /// reads as periods from the 1st.
    func testTheResetDaySurvivesARelaunchAndOlderDataReadsAsThe1st() throws {
        var usage = MonthlyUsage()
        record(&usage, [ipad: t(0, 100)], date(2026, 11, 5))
        usage.setResetDay(ResetDay(15)!, at: date(2026, 11, 20), calendar: calendar)
        let back = try JSONDecoder().decode(MonthlyUsage.self, from: JSONEncoder().encode(usage))
        XCTAssertEqual(back.resetDay, ResetDay(15))
        XCTAssertEqual(back.nextReset(at: date(2026, 12, 3), calendar: calendar), midnight(2026, 12, 15))
        XCTAssertEqual(back.of(ipad, at: date(2026, 12, 3), calendar: calendar).thisMonth, t(0, 100))

        let id = ipad.uuidString
        let old = Data(#"""
        {"devices": ["\#(id)", {"month": {"year": 2026, "month": 11}, "thisMonth": {"bytesUp": 0, "bytesDown": 100}, "lastMonth": {"bytesUp": 0, "bytesDown": 7}}],
         "marks": ["\#(id)", {"nearTold": {"year": 2026, "month": 11}}]}
        """#.utf8)
        let decoded = try JSONDecoder().decode(MonthlyUsage.self, from: old)
        XCTAssertEqual(decoded.resetDay, .first)
        XCTAssertEqual(decoded.of(ipad, at: date(2026, 11, 30), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 100), lastMonth: t(0, 7)))
        XCTAssertTrue(decoded.nearTold(ipad, at: date(2026, 11, 30), calendar: calendar))
        XCTAssertEqual(decoded.of(ipad, at: date(2026, 12, 1), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 0), lastMonth: t(0, 100)))
    }

    /// A device with no read since last period still shows it as last period after a change, and
    /// after a second one.
    func testANewResetDayKeepsLastPeriod() {
        var usage = MonthlyUsage()
        record(&usage, [ipad: t(0, 500)], date(2026, 10, 20))
        usage.setResetDay(ResetDay(15)!, at: date(2026, 11, 20), calendar: calendar)
        XCTAssertEqual(usage.of(ipad, at: date(2026, 11, 20), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 0), lastMonth: t(0, 500)))
        usage.setResetDay(.first, at: date(2026, 11, 25), calendar: calendar)
        XCTAssertEqual(usage.of(ipad, at: date(2026, 11, 25), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 0), lastMonth: t(0, 500)))
        record(&usage, [ipad: t(0, 600)], date(2026, 11, 26))
        XCTAssertEqual(usage.of(ipad, at: date(2026, 11, 26), calendar: calendar), MonthlyUsage.Usage(thisMonth: t(0, 100), lastMonth: t(0, 500)))
    }
}
