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
        XCTAssertEqual(Format.bytes(0), "0 bytes", "a number, not \"Zero KB\"")
        XCTAssertEqual(Format.bytes(UInt64.max), Format.bytes(UInt64(Int64.max)), "a huge count doesn't trap")
    }
}
