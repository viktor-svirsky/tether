import Foundation

/// The WireGuard server's byte counters. They only grow, so a reader can take the difference of two.
struct TrafficTotals: Equatable {
    var bytesUp: UInt64 = 0
    var bytesDown: UInt64 = 0
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
    /// Where it last connected from, "ip:port". For the log, not the screen.
    var endpoint: String?
}

/// A device knocking with a config that no longer works, see stale.go: a device key the server
/// doesn't let in (an expired code or a removed device), or a config for other server keys.
struct StaleConfig: Equatable {
    enum Kind: String { case device, server }
    let kind: Kind
    /// Its last handshake the server dropped.
    let at: Date

    /// How long it shows after its last handshake. A device that still tries sends one every 5 s.
    static let shownFor: TimeInterval = 60

    func shown(at now: Date) -> Bool { now.timeIntervalSince(at) < Self.shownFor }
}

/// What the server reports at one moment: its totals, each device by tunnel address, and the last
/// config that knocked but no longer works.
struct ServerSnapshot: Equatable {
    var totals = TrafficTotals()
    var peers: [String: PeerStats] = [:]
    var stale: StaleConfig?

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
