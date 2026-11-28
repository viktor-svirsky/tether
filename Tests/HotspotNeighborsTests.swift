import Network
import XCTest
@testable import TetherCore

/// Devices on the hotspot that don't use Tether (#109): what the TCP knock finds, held through a few
/// missed rounds, minus the devices on WireGuard or the proxy.
final class HotspotNeighborsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func seconds(_ s: Double) -> Date { start.addingTimeInterval(s) }

    private func knock(_ answers: [String: HotspotKnock.Answer]) -> [HotspotKnock] {
        answers.map { HotspotKnock(address: $0.key, answer: $0.value) }
    }

    private func listed(_ n: HotspotNeighbors, at s: Double, wireGuard: [String: PeerStats] = [:],
                        proxy: [String: Date] = [:]) -> [String] {
        n.notUsingTether(wireGuard: wireGuard, proxyClients: proxy, now: seconds(s))
    }

    private func peer(from endpoint: String, handshakeAt s: Double) -> PeerStats {
        PeerStats(connected: true, lastHandshake: seconds(s), endpoint: endpoint)
    }

    func testAnOpenPortOrARefusalBothMeanSomeoneIsThere() {
        var n = HotspotNeighbors()
        n.record(knock(["172.20.10.2": .open, "172.20.10.3": .refused, "172.20.10.4": .nobody]), at: seconds(0))
        XCTAssertEqual(listed(n, at: 0), ["172.20.10.2", "172.20.10.3"])
    }

    /// Two ports per address: one answer is enough.
    func testAnyPortAnsweringCounts() {
        var n = HotspotNeighbors()
        n.record([HotspotKnock(address: "172.20.10.5", answer: .nobody),
                  HotspotKnock(address: "172.20.10.5", answer: .refused)], at: seconds(0))
        XCTAssertEqual(listed(n, at: 0), ["172.20.10.5"])
    }

    func testTheIPhoneItselfIsNeverListed() {
        var n = HotspotNeighbors()
        n.record(knock([Hotspot.host: .open]), at: seconds(0))
        XCTAssertEqual(listed(n, at: 0), [])
    }

    /// The travel router in #109 went 11 rounds of 10 s without answering.
    func testADeviceThatMissesElevenRoundsStaysListed() {
        var n = HotspotNeighbors()
        n.record(knock(["172.20.10.3": .refused]), at: seconds(0))
        for round in 1...11 {
            n.record(knock(["172.20.10.3": .nobody]), at: seconds(Double(round) * 10))
        }
        XCTAssertEqual(listed(n, at: 111.5), ["172.20.10.3"])
    }

    func testADeviceSilentPastTheHoldLeaves() {
        var n = HotspotNeighbors()
        n.record(knock(["172.20.10.2": .open]), at: seconds(0))
        XCTAssertEqual(listed(n, at: HotspotNeighbors.holdFor - 1), ["172.20.10.2"])
        n.record(knock(["172.20.10.2": .nobody]), at: seconds(HotspotNeighbors.holdFor))
        XCTAssertEqual(listed(n, at: HotspotNeighbors.holdFor), [])
    }

    func testADeviceThatComesBackIsListedAgain() {
        var n = HotspotNeighbors()
        n.record(knock(["172.20.10.2": .open]), at: seconds(0))
        n.record(knock(["172.20.10.2": .open]), at: seconds(400))
        XCTAssertEqual(listed(n, at: 400), ["172.20.10.2"])
    }

    func testAWireGuardDeviceWithARecentHandshakeIsntListed() {
        var n = HotspotNeighbors()
        n.record(knock(["172.20.10.2": .open, "172.20.10.3": .refused]), at: seconds(100))
        let peers = ["10.7.0.2": peer(from: "172.20.10.3:51820", handshakeAt: 0)]
        XCTAssertEqual(listed(n, at: 100, wireGuard: peers), ["172.20.10.2"])
    }

    /// The same 3 minutes Go counts a device online for (onlineWithin in server.go). After that its
    /// tunnel is off, and if it still answers the knock it's on the hotspot without Tether.
    func testAnOldHandshakeDoesntCount() {
        var n = HotspotNeighbors()
        n.record(knock(["172.20.10.3": .refused]), at: seconds(170))
        let peers = ["10.7.0.2": peer(from: "172.20.10.3:51820", handshakeAt: 0)]
        XCTAssertEqual(listed(n, at: 179, wireGuard: peers), [])
        XCTAssertEqual(listed(n, at: 180, wireGuard: peers), ["172.20.10.3"])
    }

    func testAPeerWithoutAnEndpointOrHandshakeMatchesNothing() {
        var n = HotspotNeighbors()
        n.record(knock(["172.20.10.2": .open]), at: seconds(0))
        let peers = ["10.7.0.2": PeerStats(), "10.7.0.3": PeerStats(lastHandshake: seconds(0))]
        XCTAssertEqual(listed(n, at: 0, wireGuard: peers), ["172.20.10.2"])
    }

    func testAProxyClientIsntListedWhileItsRecent() {
        var n = HotspotNeighbors()
        n.record(knock(["172.20.10.4": .open]), at: seconds(170))
        XCTAssertEqual(listed(n, at: 179, proxy: ["172.20.10.4": seconds(0)]), [])
        XCTAssertEqual(listed(n, at: 180, proxy: ["172.20.10.4": seconds(0)]), ["172.20.10.4"])
    }

    /// On a carrier that gives the iPhone IPv6 only, a device can reach WireGuard or the proxy over
    /// IPv6 (#324). Nothing ties that address to the 172.20.10.x one the knock found, so the list
    /// can't tell who it is and says nothing rather than list a device that is using Tether.
    func testAnIPv6WireGuardDeviceEmptiesTheList() {
        var n = HotspotNeighbors()
        n.record(knock(["172.20.10.2": .open, "172.20.10.3": .refused]), at: seconds(0))
        let peers = ["10.7.0.2": peer(from: "[2607:fb91:88a2:e822::5]:51820", handshakeAt: 0)]
        XCTAssertEqual(listed(n, at: 0, wireGuard: peers), [])
    }

    func testAnIPv6ProxyClientEmptiesTheList() {
        var n = HotspotNeighbors()
        n.record(knock(["172.20.10.2": .open]), at: seconds(0))
        XCTAssertEqual(listed(n, at: 0, proxy: ["2607:fb91:88a2:e822::5": seconds(0)]), [])
    }

    /// Once the IPv6 device's handshake is old, it no longer counts, and the list comes back.
    func testAnOldIPv6HandshakeLeavesTheListAlone() {
        var n = HotspotNeighbors()
        n.record(knock(["172.20.10.2": .open]), at: seconds(170))
        let peers = ["10.7.0.2": peer(from: "[2607:fb91:88a2:e822::5]:51820", handshakeAt: 0)]
        XCTAssertEqual(listed(n, at: 180, wireGuard: peers), ["172.20.10.2"])
    }

    /// An IPv4 device written as an IPv4-mapped IPv6 address is the same device. Go unmaps them before
    /// Swift sees them (bind.go, proxy.go), so this pins the Swift side in case that ever changes: the
    /// device still matches, and the list isn't emptied as if a device used Tether over IPv6.
    func testAnIPv4MappedEndpointCountsAsItsIPv4Address() {
        var n = HotspotNeighbors()
        n.record(knock(["172.20.10.2": .open, "172.20.10.3": .refused]), at: seconds(0))
        let peers = ["10.7.0.2": peer(from: "[::ffff:172.20.10.2]:51820", handshakeAt: 0)]
        XCTAssertEqual(listed(n, at: 0, wireGuard: peers), ["172.20.10.3"])
        XCTAssertEqual(listed(n, at: 0, proxy: ["::ffff:172.20.10.3": seconds(0)]), ["172.20.10.2"])
        // The other ways the same address can be written: upper case, the hex form, and with a zone.
        for endpoint in ["[::FFFF:172.20.10.2]:51820", "[::ffff:ac14:a02]:51820", "[::ffff:172.20.10.2%bridge100]:51820"] {
            let peers = ["10.7.0.2": peer(from: endpoint, handshakeAt: 0)]
            XCTAssertEqual(listed(n, at: 0, wireGuard: peers), ["172.20.10.3"], endpoint)
        }
        XCTAssertEqual(listed(n, at: 0, proxy: ["::ffff:172.20.10.3%bridge100": seconds(0)]), ["172.20.10.2"])
    }

    /// A mix: an IPv4 device on WireGuard, one on IPv6, and an address not on Tether. The IPv6 one could
    /// be the unmatched address, so the list says nothing rather than list it.
    func testAnIPv6DeviceAmongIPv4OnesStillEmptiesTheList() {
        var n = HotspotNeighbors()
        n.record(knock(["172.20.10.2": .open, "172.20.10.3": .refused]), at: seconds(0))
        let peers = ["10.7.0.2": peer(from: "172.20.10.2:51820", handshakeAt: 0),
                     "10.7.0.3": peer(from: "[2607:fb91:88a2:e822::5]:51820", handshakeAt: 0)]
        XCTAssertEqual(listed(n, at: 0, wireGuard: peers), [])
    }

    /// Sorted by the address as a number, so .10 comes after .9.
    func testTheListIsInAddressOrder() {
        var n = HotspotNeighbors()
        n.record(knock(["172.20.10.10": .open, "172.20.10.9": .open, "172.20.10.2": .refused]), at: seconds(0))
        XCTAssertEqual(listed(n, at: 0), ["172.20.10.2", "172.20.10.9", "172.20.10.10"])
    }

    /// What the prober knocks: every client address of the hotspot's /28 but the iPhone's own.
    func testTheRangeIsTheHotspotsClients() {
        XCTAssertEqual(HotspotNeighbors.addresses.first, "172.20.10.2")
        XCTAssertEqual(HotspotNeighbors.addresses.last, "172.20.10.14")
        XCTAssertEqual(HotspotNeighbors.addresses.count, 13)
        XCTAssertFalse(HotspotNeighbors.addresses.contains(Hotspot.host))
    }

    /// The prober is used through its protocol, so a fake one drives a whole round without sockets.
    func testARoundThroughAFakeKnocker() async {
        struct Fake: HotspotKnocker {
            func knock(_ addresses: [String], ports: [UInt16], timeout: TimeInterval) async -> [HotspotKnock] {
                addresses.map { HotspotKnock(address: $0, answer: $0 == "172.20.10.7" ? .refused : .nobody) }
            }
        }
        let knocks = await Fake().knock(HotspotNeighbors.addresses, ports: HotspotNeighbors.ports, timeout: HotspotNeighbors.timeout)
        var n = HotspotNeighbors()
        n.record(knocks, at: seconds(0))
        XCTAssertEqual(listed(n, at: 0), ["172.20.10.7"])
    }

    /// NWConnection waits rather than fails on a refusal, and that reset is what most devices answer.
    func testTheKnockerReadsAResetAsSomeoneThere() {
        XCTAssertEqual(NetworkKnocker.answer(.ready), .open)
        XCTAssertEqual(NetworkKnocker.answer(.waiting(.posix(.ECONNREFUSED))), .refused)
        XCTAssertEqual(NetworkKnocker.answer(.failed(.posix(.ECONNREFUSED))), .refused)
        XCTAssertEqual(NetworkKnocker.answer(.waiting(.posix(.EHOSTDOWN))), .nobody)
        XCTAssertEqual(NetworkKnocker.answer(.failed(.posix(.EHOSTUNREACH))), .nobody)
        XCTAssertNil(NetworkKnocker.answer(.preparing))
    }
}
