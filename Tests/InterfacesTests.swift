import Darwin
@testable import TetherCore
import XCTest

/// How a failed socket or connect reads in the VPN check (#332): only an answer that says there's no
/// route is "none". Anything else is "unknown", which counts against a VPN, so a failure can't let
/// devices through.
final class InterfacesTests: XCTestCase {
    func testASocketForAFamilyTheIPhoneLacksIsNoRoute() {
        XCTAssertEqual(Interfaces.Route(socketFailed: EAFNOSUPPORT), Interfaces.Route.none)
        XCTAssertEqual(Interfaces.Route(socketFailed: EPROTONOSUPPORT), Interfaces.Route.none)
    }

    func testAnyOtherSocketFailureIsUnknown() {
        XCTAssertEqual(Interfaces.Route(socketFailed: EMFILE), .unknown, "no socket left says nothing about routes")
        XCTAssertEqual(Interfaces.Route(socketFailed: ENOBUFS), .unknown)
    }

    func testAConnectWithNoRouteIsNoRoute() {
        for code in [ENETUNREACH, EHOSTUNREACH, ENETDOWN, EADDRNOTAVAIL] {
            XCTAssertEqual(Interfaces.Route(connectFailed: code), Interfaces.Route.none, "errno \(code)")
        }
    }

    func testAnyOtherConnectFailureIsUnknown() {
        for code in [EACCES, EPERM, EINVAL, ENOBUFS] {
            XCTAssertEqual(Interfaces.Route(connectFailed: code), .unknown, "errno \(code)")
        }
    }

    /// An unknown route keeps the VPN check from finding one, whatever the other routes say.
    func testAnUnknownRouteMeansNoVPN() {
        let interfaces = ["utun5: 10.0.0.2"]
        XCTAssertEqual(Interfaces.vpn(in: interfaces, routes: [.local("10.0.0.2")]), "utun5")
        XCTAssertNil(Interfaces.vpn(in: interfaces, routes: [.local("10.0.0.2"), .unknown]))
    }
}
