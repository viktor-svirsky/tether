import XCTest
@testable import TetherCore

final class FormatTests: XCTestCase {
    func testSpeedUsesTheUnitOfASpeedTest() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(Format.speed(0, locale: us), "0 bit/s")
        XCTAssertEqual(Format.speed(999, locale: us), "999 bit/s")
        XCTAssertEqual(Format.speed(400_000, locale: us), "400 kbit/s")
        XCTAssertEqual(Format.speed(3_200_000, locale: us), "3.2 Mbit/s")
    }

    /// The region decides the decimal separator, as it does for sizes, so "3,12 GB" and "3.2 Mbit/s"
    /// don't sit on one screen (#177).
    func testSpeedUsesTheRegionsNumberFormat() {
        let germany = Locale(identifier: "de_DE")
        XCTAssertEqual(Format.speed(3_200_000, locale: germany), "3,2 Mbit/s")
        XCTAssertEqual(Format.speed(400_000, locale: germany), "400 kbit/s")
    }

    func testBytesAreReadable() {
        XCTAssertEqual(Format.bytes(2_000_000), "2 MB")
        XCTAssertEqual(Format.bytes(0), "0 bytes", "a number, not \"Zero KB\"")
        XCTAssertEqual(Format.bytes(UInt64.max), Format.bytes(UInt64(Int64.max)), "a huge count doesn't trap")
    }

    func testUsedSaysNotUsedRatherThanZero() {
        XCTAssertEqual(Format.used(0, "this month"), "Not used this month")
        XCTAssertEqual(Format.used(3_120_000_000, "this month"), "3.12 GB this month")
        XCTAssertEqual(Format.used(0, "since Nov 15"), "Nothing used since Nov 15")
        XCTAssertEqual(Format.used(3_120_000_000, "since Nov 15"), "3.12 GB since Nov 15")
    }

    /// How the screens and notices name the running count (#187): "this month" when it runs from
    /// the 1st to the 1st, else since the day it started, short, as the region writes it. In New
    /// York time, so the runner's time zone doesn't change it.
    func testTheCountIsThisMonthOnlyFromThe1st() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let us = Locale(identifier: "en_US")
        func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        func said(_ day: ResetDay, at date: Date, locale: Locale = us) -> String {
            let usage = MonthlyUsage(resetDay: day)
            return Format.period(usage.period(at: date, calendar: calendar), calendar: calendar, locale: locale)
        }
        XCTAssertEqual(said(.first, at: day(2026, 11, 20)), "this month")
        XCTAssertEqual(said(.first, at: day(2026, 11, 1)), "this month", "on the day itself")
        XCTAssertEqual(said(.first, at: day(2027, 2, 10)), "this month", "a short month")
        XCTAssertEqual(said(ResetDay(15)!, at: day(2026, 11, 20)), "since Nov 15")
        XCTAssertEqual(said(ResetDay(15)!, at: day(2026, 11, 14)), "since Oct 15", "the period before the day")
        XCTAssertEqual(said(ResetDay(15)!, at: day(2026, 11, 15)), "since Nov 15", "on the day itself")
        XCTAssertEqual(said(ResetDay(15)!, at: day(2027, 1, 3)), "since Dec 15", "across the year")
        XCTAssertEqual(said(.lastDay, at: day(2026, 11, 10)), "since Oct 31")
        XCTAssertEqual(said(.lastDay, at: day(2027, 3, 10)), "since Feb 28", "a month shorter than the day")
        XCTAssertEqual(said(.lastDay, at: day(2026, 12, 31)), "since Dec 31")
        XCTAssertEqual(said(ResetDay(15)!, at: day(2026, 11, 20), locale: Locale(identifier: "en_GB")), "since 15 Nov", "as the region writes it")
        XCTAssertEqual(said(.first, at: day(2026, 11, 20), locale: Locale(identifier: "en_GB")), "this month")
    }

    /// The device screen's row for the period before (#187): "Last month" when it ran from a 1st to
    /// the next, else its first and last days, short, as the region writes them.
    func testThePeriodBeforeIsLastMonthOnlyFromThe1st() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let us = Locale(identifier: "en_US")
        func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        func said(_ usage: MonthlyUsage, at date: Date, locale: Locale = us) -> String {
            Format.lastPeriod(usage.lastPeriod(at: date, calendar: calendar), calendar: calendar, locale: locale)
        }
        XCTAssertEqual(said(MonthlyUsage(resetDay: .first), at: day(2026, 11, 20)), "Last month")
        XCTAssertEqual(said(MonthlyUsage(resetDay: .first), at: day(2026, 3, 10)), "Last month", "after a short month")
        XCTAssertEqual(said(MonthlyUsage(resetDay: ResetDay(15)!), at: day(2026, 11, 20)), "Oct 15 to Nov 14")
        XCTAssertEqual(said(MonthlyUsage(resetDay: ResetDay(15)!), at: day(2026, 11, 14)), "Sep 15 to Oct 14")
        XCTAssertEqual(said(MonthlyUsage(resetDay: ResetDay(15)!), at: day(2027, 1, 20)), "Dec 15 to Jan 14", "across the year")
        XCTAssertEqual(said(MonthlyUsage(resetDay: .lastDay), at: day(2027, 3, 10)), "Jan 31 to Feb 27", "a month shorter than the day")
        XCTAssertEqual(said(MonthlyUsage(resetDay: ResetDay(15)!), at: day(2026, 11, 20), locale: Locale(identifier: "en_GB")),
                       "15 Oct to 14 Nov", "as the region writes it")
        var changed = MonthlyUsage(resetDay: .first)
        changed.setResetDay(ResetDay(15)!, at: day(2026, 11, 20), calendar: calendar)
        XCTAssertEqual(said(changed, at: day(2026, 11, 20)), "Last month", "October, before the change")
        XCTAssertEqual(said(changed, at: day(2026, 12, 20)), "Nov 1 to Dec 14", "the changed period")
    }

    /// A day changed mid-period runs the period to the new day's next date, so it isn't a month any
    /// more, even when the new day is the 1st.
    func testAChangedPeriodSaysSinceItsStart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let us = Locale(identifier: "en_US")
        let nov20 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        var toThe15th = MonthlyUsage(resetDay: .first)
        toThe15th.setResetDay(ResetDay(15)!, at: nov20, calendar: calendar)
        XCTAssertEqual(Format.period(toThe15th.period(at: nov20, calendar: calendar), calendar: calendar, locale: us), "since Nov 1",
                       "November 1 to December 15")
        var toThe1st = MonthlyUsage(resetDay: ResetDay(15)!)
        toThe1st.setResetDay(.first, at: nov20, calendar: calendar)
        XCTAssertEqual(Format.period(toThe1st.period(at: nov20, calendar: calendar), calendar: calendar, locale: us), "since Nov 15",
                       "November 15 to December 1")
        let dec2 = calendar.date(from: DateComponents(year: 2026, month: 12, day: 2))!
        XCTAssertEqual(Format.period(toThe1st.period(at: dec2, calendar: calendar), calendar: calendar, locale: us), "this month",
                       "then a month from each 1st")
    }

    /// When a device last connected, on its screen (#73): the day in words when it is today or
    /// yesterday, then the day and month, with the year only when it is another year. In New York
    /// time and US English, so the runner's time zone and region don't change it.
    func testLastConnectedSaysNeverTodayYesterdayOrTheDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let us = Locale(identifier: "en_US")
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        let now = date(2026, 10, 17, 18)
        func said(_ date: Date?, locale: Locale = us) -> String {
            Format.lastConnected(date, now: now, calendar: calendar, locale: locale)
                .replacingOccurrences(of: "\u{202F}", with: " ") // the narrow space some versions put before PM
        }
        XCTAssertEqual(said(nil), "Never")
        XCTAssertEqual(said(date(2026, 10, 17, 16)), "Today at 4:00 PM")
        XCTAssertEqual(said(date(2026, 10, 17, 0, 5)), "Today at 12:05 AM")
        XCTAssertEqual(said(date(2026, 10, 16, 23, 59)), "Yesterday at 11:59 PM")
        XCTAssertEqual(said(date(2026, 10, 3, 9, 12)), "October 3 at 9:12 AM")
        XCTAssertEqual(said(date(2025, 12, 30, 9, 12)), "December 30, 2025 at 9:12 AM")
        XCTAssertEqual(said(date(2026, 10, 17, 16), locale: Locale(identifier: "en_GB")), "Today at 16:00", "the clock the region uses")
    }
}
