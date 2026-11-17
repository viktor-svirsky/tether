import XCTest
@testable import TetherCore

/// The iPhone's name on the hotspot (#65), see `HostName`.
final class HostNameTests: XCTestCase {
    /// The start of the server's public key, so it's the same for as long as the keys are.
    func testTheNameComesFromTheServersKey() {
        XCTAssertEqual(HostName.name(for: Data([0x2a, 0x9a, 0xff, 0x01])), "tether-2a9a.local")
        XCTAssertEqual(HostName.name(for: Data([0x00, 0x07])), "tether-0007.local")
    }

    /// A device's saved host is a name or an address.
    func testANameIsToldFromAnAddress() {
        XCTAssertTrue(HostName.isName("tether-2a9a.local"))
        XCTAssertFalse(HostName.isName("172.20.10.1"))
        XCTAssertFalse(HostName.isName("2607:fb91::1"))
    }
}
