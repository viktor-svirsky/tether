import Foundation
import Network

/// One address's answer to one TCP knock, see `HotspotKnocker` (#109).
struct HotspotKnock: Equatable, Sendable {
    enum Answer: Equatable, Sendable {
        /// The port took the connection.
        case open
        /// A reset: the port is closed, but a device is there to send it.
        case refused
        /// A timeout, EHOSTDOWN or any other error: nobody there, or a device that drops the knock.
        case nobody
    }

    let address: String
    let answer: Answer
}

/// The devices on the hotspot that don't use Tether (#109). iOS hides the ARP table from apps, so
/// what's there comes from a TCP knock on each client address every `every` seconds. Each address that
/// answers is listed, unless a device with a recent WireGuard handshake or a recent proxy request
/// comes from it. No sockets here, so `swift test` covers it.
struct HotspotNeighbors {
    /// The hotspot's clients: 172.20.10.2 to .14 of its /28, without the iPhone's own 172.20.10.1.
    static let addresses = (2...14).map { "172.20.10.\($0)" }
    /// 62078 is open on every iPhone and iPad (lockdownd). 9 (discard) is closed almost everywhere,
    /// so most other devices answer it with a reset.
    static let ports: [UInt16] = [62078, 9]
    /// The knock in #109 used these: the travel router refused after 1 to 1.5 s.
    static let timeout: TimeInterval = 1.5
    static let every: TimeInterval = 10
    /// How long an address stays listed after its last answer. In #109 an iPad answered every round,
    /// but a travel router answered only 7 rounds in 10 and once went 11 rounds (110 s) without
    /// answering while it was still there. 150 s covers those 11 missed rounds with a round's slack
    /// for late or slow rounds, so a device like it doesn't flicker off the list, and one that left
    /// is gone within 2.5 minutes.
    static let holdFor: TimeInterval = 150
    /// How recent a WireGuard handshake or a proxy request must be for its device to count as using
    /// Tether: the same 3 minutes Go counts a device online for (onlineWithin in server.go).
    static let usingWithin: TimeInterval = 180

    /// When each address last answered.
    private(set) var lastAnswer: [String: Date] = [:]

    /// Adds a round of knocks, one or more per address. An address answers when any of its ports
    /// does. A round that doesn't answer changes nothing, so the address stays for `holdFor`.
    mutating func record(_ knocks: [HotspotKnock], at now: Date) {
        for knock in knocks where knock.answer != .nobody && knock.address != Hotspot.host {
            lastAnswer[knock.address] = now
        }
        lastAnswer = lastAnswer.filter { now.timeIntervalSince($0.value) < Self.holdFor }
    }

    /// The addresses on the hotspot that aren't using Tether, in address order. `wireGuard` is the
    /// server's peers as `HotspotSession` has them, and `proxyClients` the address of each device the
    /// proxy served with when it last served it. Empty while a device uses Tether over IPv6 (#324): the
    /// knock finds 172.20.10.x addresses, and nothing says which of them that device is.
    func notUsingTether(wireGuard: [String: PeerStats], proxyClients: [String: Date], now: Date) -> [String] {
        func recent(_ at: Date?) -> Bool { at.map { now.timeIntervalSince($0) < Self.usingWithin } ?? false }
        var using = Set(proxyClients.filter { recent($0.value) }.keys)
        for stats in wireGuard.values where recent(stats.lastHandshake) {
            if let address = PeerStats.address(stats.endpoint) { using.insert(address) }
        }
        if using.contains(where: { IPv6Address($0) != nil }) { return [] }
        return lastAnswer
            .filter { now.timeIntervalSince($0.value) < Self.holdFor && !using.contains($0.key) }
            .keys
            .sorted { Self.order($0).lexicographicallyPrecedes(Self.order($1)) }
    }

    /// An IPv4 address's four numbers, to sort .10 after .9.
    private static func order(_ address: String) -> [Int] {
        address.split(separator: ".").map { Int($0) ?? 0 }
    }
}

/// Knocks each address on each port at once and says who answered, see `HotspotKnock`. A protocol so
/// `HotspotNeighbors` is tested without sockets. `NetworkKnocker` is the real one.
protocol HotspotKnocker: Sendable {
    /// Every knock, one per address and port, once each has answered or `timeout` passed.
    func knock(_ addresses: [String], ports: [UInt16], timeout: TimeInterval) async -> [HotspotKnock]
}
