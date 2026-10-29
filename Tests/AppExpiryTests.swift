import XCTest
@testable import TetherCore

final class AppExpiryTests: XCTestCase {
    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private func at(_ day: Int, _ hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    /// A provisioning profile is a signed blob with the plist in clear text inside it.
    private func profile(expiring date: String) -> Data {
        Data([0x30, 0x82, 0x0F, 0x00, 0x06, 0x09]) + Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Name</key><string>Tether</string>
        <key>ExpirationDate</key><date>\(date)</date></dict></plist>
        """.utf8) + Data([0xA0, 0x82, 0x03, 0x00])
    }

    func testTheExpiryDateIsReadFromTheProfile() {
        XCTAssertEqual(AppExpiry.date(fromProfile: profile(expiring: "2026-10-26T12:00:00Z")), at(26))
    }

    func testDataWithoutAPlistHasNoDate() {
        XCTAssertNil(AppExpiry.date(fromProfile: Data()))
        XCTAssertNil(AppExpiry.date(fromProfile: Data("<?xml no end".utf8)))
        XCTAssertNil(AppExpiry.date(fromProfile: Data("<?xml version=\"1.0\"?><plist><dict></dict></plist>".utf8)))
    }

    func testNoWarningWhileMoreThanThreeDaysAreLeft() {
        XCTAssertNil(AppExpiry.warning(expires: at(26), now: at(19), calendar: utc))
        XCTAssertNil(AppExpiry.warning(expires: at(26, 12), now: at(23, 11), calendar: utc))
    }

    func testTheWarningSaysWhenInDays() {
        XCTAssertEqual(AppExpiry.warning(expires: at(26), now: at(23, 12), calendar: utc),
                       "Tether stops opening in 3 days. Refresh or reinstall it before then.")
        XCTAssertEqual(AppExpiry.warning(expires: at(26, 9), now: at(24, 20), calendar: utc),
                       "Tether stops opening in 2 days. Refresh or reinstall it before then.", "counted in calendar days")
        XCTAssertEqual(AppExpiry.warning(expires: at(26, 9), now: at(25, 22), calendar: utc),
                       "Tether stops opening tomorrow. Refresh or reinstall it before then.")
        XCTAssertEqual(AppExpiry.warning(expires: at(26, 20), now: at(26, 8), calendar: utc),
                       "Tether stops opening today. Refresh or reinstall it before then.")
    }

    /// Still running after the moment it expired: it won't open again once closed.
    func testPastTheDateItSaysToday() {
        XCTAssertEqual(AppExpiry.warning(expires: at(26, 8), now: at(26, 9), calendar: utc),
                       "Tether stops opening today. Refresh or reinstall it before then.")
    }
}
