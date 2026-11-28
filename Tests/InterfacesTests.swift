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

    /// A tunnel for IPv4 while IPv6 leaves over cellular, or the other way round: no VPN, but the
    /// reading says which family the tunnel carries (#334).
    func testATunnelForOneFamilyIsNoVPNButSaysWhich() {
        let lines = ["pdp_ip0: 10.180.2.3", "pdp_ip0: 2607:fb90:1234::5", "utun5: 10.2.0.2", "utun5: fd00::2"]
        let v4 = Interfaces.Route.local("10.2.0.2"), v6 = Interfaces.Route.local("fd00::2")
        let cell4 = Interfaces.Route.local("10.180.2.3"), cell6 = Interfaces.Route.local("2607:fb90:1234::5")
        XCTAssertEqual(Interfaces.onlyFamily(in: lines, routes: [v4, v4, cell6, cell6]), .ipv4)
        XCTAssertEqual(Interfaces.onlyFamily(in: lines, routes: [cell4, cell4, v6, v6]), .ipv6)
        XCTAssertNil(Interfaces.onlyFamily(in: lines, routes: [v4, cell4, cell6, cell6]), "IPv4 half in the tunnel")
        XCTAssertNil(Interfaces.onlyFamily(in: lines, routes: [cell4, cell4, cell6, cell6]), "no tunnel at all")
        XCTAssertNil(Interfaces.onlyFamily(in: lines, routes: [v4, v4, .none, .none]), "no IPv6 route: that is a VPN")
        XCTAssertNil(Interfaces.onlyFamily(in: lines, routes: [v4, v4, cell6, .unknown]), "a route nothing is known about")
        XCTAssertNil(Interfaces.onlyFamily(in: lines, routes: [v4, v4, .local("2001:db8::9"), cell6]), "an address on no interface")
    }

    /// The reading: a VPN for both families is one, with nothing more to say. One for IPv4 only isn't.
    func testTheReadingSaysWhyThereIsNoVPN() {
        let lines = ["pdp_ip0: 10.180.2.3", "pdp_ip0: 2607:fb90:1234::5", "utun5: 10.2.0.2", "utun5: fd00::2"]
        let both = { (host: String) -> Interfaces.Route in .local(host.contains(":") ? "fd00::2" : "10.2.0.2") }
        let v4Only = { (host: String) -> Interfaces.Route in .local(host.contains(":") ? "2607:fb90:1234::5" : "10.2.0.2") }
        XCTAssertEqual(Interfaces.reading(nat64: { nil }, addresses: lines, route: both), Interfaces.Reading(vpn: "utun5"))
        XCTAssertEqual(Interfaces.reading(nat64: { nil }, addresses: lines, route: v4Only), Interfaces.Reading(onlyFamily: .ipv4))
        XCTAssertNil(Interfaces.internetVPN(nat64: { nil }, addresses: lines, route: v4Only), "still no VPN: blocking stays as it was")
    }

    /// No route for a family the iPhone has, on cellular or Wi-Fi, is a route that failed for a
    /// moment, not an answer (#330): it counts against a VPN, so the devices aren't let through while
    /// that family goes around the tunnel. No route for a family it doesn't have is still an answer.
    func testNoRouteForAFamilyTheIPhoneHasIsNotAVPN() {
        let dualStack = ["pdp_ip0: 10.180.2.3", "pdp_ip0: 2607:fb90:1234::5", "pdp_ip0: fe80::1%pdp_ip0", "utun5: 10.2.0.2"]
        let v6Fails = { (host: String) -> Interfaces.Route in host.contains(":") ? .none : .local("10.2.0.2") }
        XCTAssertNil(Interfaces.internetVPN(nat64: { nil }, addresses: dualStack, route: v6Fails), "IPv6 failed for a moment")

        let ipv4Only = ["pdp_ip0: 10.180.2.3", "pdp_ip0: fe80::1%pdp_ip0", "utun5: 10.2.0.2"]
        XCTAssertEqual(Interfaces.internetVPN(nat64: { nil }, addresses: ipv4Only, route: v6Fails), "utun5",
                       "only a link-local IPv6 address: the iPhone has no IPv6 to leave by")

        let ipv6OnlyWithCLAT = ["pdp_ip0: 2607:fb90:1234::5", "pdp_ip0: 192.0.0.4", "utun5: fd00::2"]
        let v4Fails = { (host: String) -> Interfaces.Route in host.contains(":") ? .local("fd00::2") : .none }
        XCTAssertEqual(Interfaces.internetVPN(nat64: { nil }, addresses: ipv6OnlyWithCLAT, route: v4Fails), "utun5",
                       "the CLAT address isn't IPv4 of the carrier's own")

        let wifi = ["en0: 192.168.1.184", "pdp_ip0: 2607:fb90:1234::5", "utun5: fd00::2"]
        XCTAssertNil(Interfaces.internetVPN(nat64: { nil }, addresses: wifi, route: v4Fails), "IPv4 on Wi-Fi failed for a moment")

        let tunnelOnly = ["pdp_ip0: 2607:fb90:1234::5", "utun5: 10.2.0.2", "utun5: fd00::2", "bridge100: 172.20.10.1"]
        XCTAssertEqual(Interfaces.internetVPN(nat64: { nil }, addresses: tunnelOnly, route: v4Fails), "utun5",
                       "IPv4 only on the tunnel and the hotspot: the carrier gives none")

        // IPv4 on another pdp_ip counts too, and fails closed: on dual SIM the data line isn't always
        // pdp_ip0. On an IPv6-only carrier whose VoLTE has IPv4 on pdp_ip1 that keeps the devices out
        // while a route can't be read, a pause that's wrong, never a family around the tunnel.
        let dataOnPdpIP1 = ["pdp_ip0: 2607:fb90:1234::5", "pdp_ip1: 10.170.0.9", "utun5: fd00::2"]
        XCTAssertNil(Interfaces.internetVPN(nat64: { nil }, addresses: dataOnPdpIP1, route: v4Fails),
                     "IPv4 on pdp_ip1 failed for a moment")
    }

    func testWhatTheScreensSay() {
        XCTAssertEqual(VPNText.now(vpn: true, onlyFamily: nil), "Through a VPN")
        XCTAssertEqual(VPNText.now(vpn: false, onlyFamily: nil), "No VPN")
        XCTAssertEqual(VPNText.now(vpn: false, onlyFamily: .ipv4), "VPN for IPv4 only")
        XCTAssertEqual(VPNText.now(vpn: false, onlyFamily: .ipv6), "VPN for IPv6 only")
        XCTAssertEqual(VPNText.blocked(onlyFamily: nil),
                       "No VPN is on, so no device gets through until one is. Turn your VPN on, or turn off Only share through a VPN in Settings.")
        XCTAssertEqual(VPNText.blocked(onlyFamily: .ipv4),
                       "Your VPN carries only IPv4, and this iPhone's IPv6 goes around it, so no device gets through. Turn on IPv6 in your VPN, or turn off Only share through a VPN in Settings.")
    }
}
