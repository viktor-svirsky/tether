import Network
import XCTest
@testable import TetherCore

/// What a Bonjour browse's state says about Tether's Local Network access (TN3179).
final class LocalNetworkTests: XCTestCase {
    private let policyDenied = NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))

    func testAPolicyDeniedBrowseMeansNoAccess() {
        XCTAssertEqual(LocalNetworkCheck.denied(.waiting(policyDenied)), true)
        XCTAssertEqual(LocalNetworkCheck.denied(.failed(policyDenied)), true)
    }

    func testARunningBrowseMeansAccess() {
        XCTAssertEqual(LocalNetworkCheck.denied(.ready), false)
    }

    /// A browse that fails for another reason is no reason for a warning, so an old one goes.
    func testABrowseThatFailsOtherwiseClearsTheWarning() {
        XCTAssertEqual(LocalNetworkCheck.denied(.failed(.posix(.ENETDOWN))), false)
    }

    /// While it's still working it out, the last answer stays.
    func testOtherStatesSayNothing() {
        XCTAssertNil(LocalNetworkCheck.denied(.setup))
        XCTAssertNil(LocalNetworkCheck.denied(.cancelled))
        XCTAssertNil(LocalNetworkCheck.denied(.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_NoSuchRecord)))))
        XCTAssertNil(LocalNetworkCheck.denied(.waiting(.posix(.ENETDOWN))))
    }
}
