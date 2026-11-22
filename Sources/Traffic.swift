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
    /// Every byte the server took from it, keepalives too, see `PeerActivity`.
    var received: UInt64 = 0

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

/// When each device last sent anything (#63). Its WireGuard sends a keepalive at least every 25 s
/// while its tunnel is on (PersistentKeepalive in the config), so a device whose count didn't go up
/// for `liveFor` has its tunnel off, or is gone. A count read once says nothing of when it went up.
/// Go reads the counts with the handshakes, every 10 s. The session reads them every second on
/// screen, on each watcher round in the background (up to 20 s apart), and when the page is asked.
/// A rise is seen up to 30 s late, so with a keepalive every 25 s a live tunnel stays within
/// `liveFor`. A tunnel turned off still counts as live for up to a minute.
struct PeerActivity {
    static let liveFor: TimeInterval = 60

    private var seen: [String: (received: UInt64, rose: Date?)] = [:]

    /// The server's devices now, by tunnel address. One it no longer has is forgotten. A count that
    /// went down is a server that started again, not the device sending.
    mutating func read(_ peers: [String: PeerStats], at now: Date) {
        var next: [String: (received: UInt64, rose: Date?)] = [:]
        for (address, stats) in peers {
            let old = seen[address]
            next[address] = (stats.received, old.map { stats.received > $0.received ? now : $0.rose } ?? nil)
        }
        seen = next
    }

    func live(_ address: String, at now: Date) -> Bool {
        seen[address]?.rose.map { now.timeIntervalSince($0) < Self.liveFor } ?? false
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

/// The HTTP proxy as the server reports it, see proxyStats in WireGuard/proxy.go (#78).
struct ProxyStats: Equatable {
    /// Where it listens, "ip:port": 172.20.10.1 first, then "[ip]:port" on a hotspot that gives Apple
    /// devices IPv6 only. Empty while it doesn't listen: off, or not listening yet. Paused, it listens.
    var addresses: [String] = []
    /// It has an address to listen on and can't, its port taken say. It tries again by itself.
    var cantListen = false
    var paused = false
    /// The client connections it has open, from every device on it.
    var open = 0
    /// The devices, by address, the far end answered through it in the last 2 minutes, so Add a
    /// device can tell a new one from one already on the proxy (#285). Empty when a read failed.
    var served: Set<String> = []
    /// Its bytes, the same ones as the totals. They only grow, across restarts, like a device's.
    var traffic = TrafficTotals()
    /// Which start of the server these come from, counted by HotspotSession. A new one's `served`
    /// starts empty, also after a restart no read saw stop, so Add a device can tell (#285).
    var run = 0
}

/// The server's counters for the Diagnostics screen in Settings (#256), see diagStats in
/// WireGuard/diagnostics.go. They count from the server's start, so a stopped server has none. A
/// text is "" for none yet.
struct ServerDiagnostics: Equatable, Decodable {
    /// Where the WireGuard port listens, "ip:port" or "[ip]:port", IPv4 first.
    var listening: [String] = []
    /// UDP that reached the WireGuard port, and where the last of it came from.
    var udpIn: UInt64 = 0
    var udpFrom = ""
    /// WireGuard messages turned away: a config that no longer works, for one.
    var rejected: UInt64 = 0
    /// Replies to the devices that couldn't be sent, and why the last one couldn't.
    var replyFailed: UInt64 = 0
    var replyError = ""
    /// Packets the devices sent into the tunnel, and the ones dropped for a source address their
    /// config doesn't give them.
    var packetsIn: UInt64 = 0
    var disallowed: UInt64 = 0
    /// The iPhone's side: TCP connections it tried for the devices and the ones that failed, UDP it
    /// couldn't send on, the NAT64 prefix once one was needed, and the last of those errors.
    var tcpTried: UInt64 = 0
    var tcpFailed: UInt64 = 0
    var udpFailed: UInt64 = 0
    var nat64 = ""
    var lastError = ""
}

extension ServerDiagnostics {
    private enum CodingKeys: String, CodingKey {
        case listening, udpIn, udpFrom, rejected, replyFailed, replyError, packetsIn, disallowed, tcpTried, tcpFailed, udpFailed, nat64, lastError
    }

    /// A key missing reads as nothing counted, so the two sides drifting never fails the whole stats read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        listening = try c.decodeIfPresent([String].self, forKey: .listening) ?? []
        udpIn = try c.decodeIfPresent(UInt64.self, forKey: .udpIn) ?? 0
        udpFrom = try c.decodeIfPresent(String.self, forKey: .udpFrom) ?? ""
        rejected = try c.decodeIfPresent(UInt64.self, forKey: .rejected) ?? 0
        replyFailed = try c.decodeIfPresent(UInt64.self, forKey: .replyFailed) ?? 0
        replyError = try c.decodeIfPresent(String.self, forKey: .replyError) ?? ""
        packetsIn = try c.decodeIfPresent(UInt64.self, forKey: .packetsIn) ?? 0
        disallowed = try c.decodeIfPresent(UInt64.self, forKey: .disallowed) ?? 0
        tcpTried = try c.decodeIfPresent(UInt64.self, forKey: .tcpTried) ?? 0
        tcpFailed = try c.decodeIfPresent(UInt64.self, forKey: .tcpFailed) ?? 0
        udpFailed = try c.decodeIfPresent(UInt64.self, forKey: .udpFailed) ?? 0
        nat64 = try c.decodeIfPresent(String.self, forKey: .nat64) ?? ""
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError) ?? ""
    }
}

/// What the server reports at one moment: its totals, each device by tunnel address, the proxy, the
/// last config that knocked but no longer works, and each address's from the last minute.
struct ServerSnapshot: Equatable {
    var totals = TrafficTotals()
    var peers: [String: PeerStats] = [:]
    var proxy = ProxyStats()
    var stale: StaleConfig?
    /// For the config page to tell each device its own (#63): two removed devices may keep trying.
    var recentStale: [StaleConfig] = []
    /// For the Diagnostics screen in Settings (#256).
    var diagnostics = ServerDiagnostics()

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
