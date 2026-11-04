import XCTest
@testable import TetherCore

final class FormatTests: XCTestCase {
    func testSpeedUsesTheUnitOfASpeedTest() {
        XCTAssertEqual(Format.speed(0), "0 bit/s")
        XCTAssertEqual(Format.speed(999), "999 bit/s")
        XCTAssertEqual(Format.speed(400_000), "400 kbit/s")
        XCTAssertEqual(Format.speed(3_200_000), "3.2 Mbit/s")
    }

    func testBytesAreReadable() {
        XCTAssertEqual(Format.bytes(2_000_000), "2 MB")
        XCTAssertEqual(Format.bytes(UInt64.max), Format.bytes(UInt64(Int64.max)), "a huge count doesn't trap")
        XCTAssertEqual(Format.bytes(0), "0 bytes", "not \"Zero KB\"")
    }

    // MARK: Data use (#73)

    private let gb = Locale(identifier: "en_GB")
    private let us = Locale(identifier: "en_US")
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testThisMonthSaysNotUsedForNothing() {
        XCTAssertEqual(Format.thisMonth(TrafficTotals(bytesUp: 420_000_000, bytesDown: 2_700_000_000)), "3.12 GB this month")
        XCTAssertEqual(Format.thisMonth(TrafficTotals()), "Not used this month")
        XCTAssertEqual(Format.lastMonth(TrafficTotals(bytesDown: 11_400_000_000)), "11.4 GB")
        XCTAssertEqual(Format.lastMonth(TrafficTotals()), "Not used")
    }

    func testDownAndUpReadInWords() {
        let used = TrafficTotals(bytesUp: 420_000_000, bytesDown: 2_700_000_000)
        XCTAssertEqual(Format.downAndUpSpoken(used), "2.7 GB down, 420 MB up")
    }

    func testTheCountResetsOnTheFirstOfNextMonth() {
        let now = date(2026, 11, 3, 12, 0)
        XCTAssertEqual(Format.resetsOn(now: now, calendar: calendar, locale: gb), "Resets on 1 December")
        XCTAssertEqual(Format.resetsOn(now: now, calendar: calendar, locale: us), "Resets on December 1")
        XCTAssertEqual(Format.resetsOn(now: date(2026, 12, 31, 23, 59), calendar: calendar, locale: gb), "Resets on 1 January")
    }

    func testLastConnectedSaysTodayYesterdayOrTheDate() {
        let now = date(2026, 11, 24, 20, 0)
        func text(_ d: Date?, _ locale: Locale = Locale(identifier: "en_GB")) -> String {
            Format.lastConnected(d, now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(text(nil), "Never")
        XCTAssertEqual(text(date(2026, 11, 24, 9, 12)), "Today, 09:12")
        XCTAssertEqual(text(date(2026, 11, 23, 18, 2)), "Yesterday, 18:02")
        XCTAssertEqual(text(date(2026, 11, 2, 18, 2)), "2 November, 18:02")
        XCTAssertEqual(text(date(2025, 11, 2, 18, 2)), "2 November 2025, 18:02", "another year says which")
        // US times have a narrow no-break space before AM, the way the system shows them.
        XCTAssertEqual(text(date(2026, 11, 24, 9, 12), us), "Today, 9:12\u{202F}AM")
        XCTAssertEqual(text(date(2026, 11, 2, 18, 2), us), "November 2, 6:02\u{202F}PM")
    }
}
