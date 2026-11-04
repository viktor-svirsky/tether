import Foundation

/// The WireGuard server's byte counters. They only grow, so a reader can take the difference of two.
struct TrafficTotals: Equatable {
    var bytesUp: UInt64 = 0
    var bytesDown: UInt64 = 0

    /// Both ways.
    var total: UInt64 { bytesUp.addingReportingOverflow(bytesDown).overflow ? .max : bytesUp + bytesDown }

    /// Stops at the largest count rather than trap.
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
    /// Where it last connected from, "ip:port". For the log, not the screen.
    var endpoint: String?
}

/// What the server reports at one moment: its totals, and each device by tunnel address.
struct ServerSnapshot: Equatable {
    var totals = TrafficTotals()
    var peers: [String: PeerStats] = [:]

    var connected: Set<String> { Set(peers.filter(\.value.connected).keys) }
}

/// `CarriedTotals` for each device, by tunnel address. A device that's no longer let in is dropped,
/// and so is an address given to another key, so a device given an address later starts from zero,
/// as on the server.
struct CarriedDevices {
    private var carried: [String: TrafficTotals] = [:]
    /// Each address's key at the last `keep(only:)`.
    private var keys: [String: Data] = [:]

    /// Call with a run's last stats when it stops.
    mutating func absorb(_ last: [String: PeerStats]) {
        for (address, stats) in last { carried[address, default: TrafficTotals()] += stats.traffic }
    }

    /// The devices let in now, address to public key. `WireGuardServer` calls it with every list it
    /// applies, which is only while running, so also with the list a new run starts with: a device
    /// removed while the server was stopped never left a list it got, but its address may have a new
    /// key already.
    mutating func keep(only devices: [String: Data]) {
        carried = carried.filter { address, _ in devices[address].map { $0 == keys[address] } ?? false }
        keys = devices
    }

    /// The run's stats with what earlier runs counted added. A device this run hasn't reported yet
    /// shows what it used, not connected.
    func apply(to current: [String: PeerStats]) -> [String: PeerStats] {
        var out = current
        for (address, c) in carried {
            out[address, default: PeerStats()].traffic += c
        }
        return out
    }
}
