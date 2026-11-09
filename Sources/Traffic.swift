import Foundation
import Network

/// The WireGuard server's byte counters. They only grow, so a reader can take the difference of two.
struct TrafficTotals: Equatable, Codable {
    var bytesUp: UInt64 = 0
    var bytesDown: UInt64 = 0

    /// Both ways, as a device's data per month counts it.
    var total: UInt64 { bytesUp.addingReportingOverflow(bytesDown).overflow ? .max : bytesUp + bytesDown }

    static func += (a: inout TrafficTotals, b: TrafficTotals) {
        a.bytesUp = a.bytesUp.addingReportingOverflow(b.bytesUp).overflow ? .max : a.bytesUp + b.bytesUp
        a.bytesDown = a.bytesDown.addingReportingOverflow(b.bytesDown).overflow ? .max : a.bytesDown + b.bytesDown
    }
}

/// The WireGuard server starts from zero each time the hotspot comes back, while readers expect
/// counters that only grow. This carries what earlier runs counted.
struct CarriedTotals {
    private var carried = TrafficTotals()

    /// Call with a run's last counters when it stops.
    mutating func absorb(_ last: TrafficTotals) {
        carried.bytesUp += last.bytesUp
        carried.bytesDown += last.bytesDown
    }

    func apply(to current: TrafficTotals) -> TrafficTotals {
        TrafficTotals(bytesUp: carried.bytesUp + current.bytesUp, bytesDown: carried.bytesDown + current.bytesDown)
    }
}

/// One device as the server reports it, see peerStats in boundary.go.
struct PeerStats: Equatable {
    /// Its bytes, the same ones as the totals.
    var traffic = TrafficTotals()
    /// A recent handshake: set up and working, also before it sent anything.
    var connected = false
    var lastHandshake: Date?
    /// Where it last connected from, "ip:port", or "[ip]:port" for IPv6. Its screen shows the
    /// address alone while it's connected (#73).
    var endpoint: String?

    /// The address alone, from an endpoint or a config page client's "ip", which has no port:
    /// "172.20.10.2" or "2600:380:abcd::1". Without an IPv6 zone, which names an interface of this
    /// iPhone, not the device. Nil for anything that isn't an IP address.
    static func address(_ endpoint: String?) -> String? {
        guard var host = endpoint?[...] else { return nil }
        if host.first == "[" {
            guard let close = host.firstIndex(of: "]") else { return nil }
            let port = host[host.index(after: close)...]
            guard port.isEmpty || port.first == ":" else { return nil }
            host = host[host.index(after: host.startIndex)..<close]
        } else if host.filter({ $0 == ":" }).count == 1 {
            host = host.prefix { $0 != ":" } // IPv4 with its port. More colons are IPv6 without one.
        }
        let ip = String(host.prefix { $0 != "%" })
        return IPv4Address(ip) != nil || IPv6Address(ip) != nil ? ip : nil
    }
}

/// A device knocking with a config that no longer works, see stale.go: a device key the server
/// doesn't let in (an expired code or a removed device), or a config for other server keys.
struct StaleConfig: Equatable {
    enum Kind: String { case device, server }
    let kind: Kind
    /// Its last handshake the server dropped.
    let at: Date
    /// Where that came from, "ip:port", so the config page can tell that device (#63). Nil for
    /// other server keys: wireguard-go doesn't say.
    var from: String?

    /// How long it shows after its last handshake. A device that still tries sends one every 5 s.
    static let shownFor: TimeInterval = 60

    func shown(at now: Date) -> Bool { now.timeIntervalSince(at) < Self.shownFor }
}

/// What the server reports at one moment: its totals, each device by tunnel address, the last
/// config that knocked but no longer works, and each address's from the last minute.
struct ServerSnapshot: Equatable {
    var totals = TrafficTotals()
    var peers: [String: PeerStats] = [:]
    var stale: StaleConfig?
    /// For the config page to tell each device its own (#63): two removed devices may keep trying.
    var recentStale: [StaleConfig] = []

    var connected: Set<String> { Set(peers.filter(\.value.connected).keys) }
}

/// `CarriedTotals` for each device, by tunnel address. A device that's no longer let in is dropped,
/// so one given its address later starts from zero, as on the server.
struct CarriedDevices {
    private var carried: [String: TrafficTotals] = [:]

    /// Call with a run's last stats when it stops.
    mutating func absorb(_ last: [String: PeerStats]) {
        for (address, stats) in last {
            var c = carried[address, default: TrafficTotals()]
            c.bytesUp += stats.traffic.bytesUp
            c.bytesDown += stats.traffic.bytesDown
            carried[address] = c
        }
    }

    mutating func keep(only addresses: Set<String>) {
        carried = carried.filter { addresses.contains($0.key) }
    }

    /// The run's stats with what earlier runs counted added. A device this run hasn't reported yet
    /// shows what it used, not connected.
    func apply(to current: [String: PeerStats]) -> [String: PeerStats] {
        var out = current
        for (address, c) in carried {
            var stats = out[address] ?? PeerStats()
            stats.traffic.bytesUp += c.bytesUp
            stats.traffic.bytesDown += c.bytesDown
            out[address] = stats
        }
        return out
    }
}
