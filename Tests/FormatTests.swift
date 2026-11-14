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

    func testThisMonthSaysNotUsedRatherThanZero() {
        XCTAssertEqual(Format.thisMonth(0), "Not used this month")
        XCTAssertEqual(Format.thisMonth(3_120_000_000), "3.12 GB this month")
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
