import Foundation
import TetherWG

/// Runs the WireGuard server from WireGuard/ (Go, linked as TetherWG.xcframework). Only the main actor calls it. The Go side is thread-safe and quick, so nothing here waits.
@MainActor
final class WireGuardServer {
    private(set) var running = false
    private var carried = CarriedTotals()
    private var carriedDevices = CarriedDevices()
    /// The run's stats at the last read Swift could decode.
    private var lastRun = ServerSnapshot()
    /// The last time stats couldn't be read, so it's logged once.
    private var statsProblem: String?
    private let log: (String) -> Void

    /// `carriedDevices` is for the tests, which can't make traffic through the real server.
    init(log: @escaping (String) -> Void = { _ in }, carriedDevices: CarriedDevices = CarriedDevices()) {
        self.log = log
        self.carriedDevices = carriedDevices
    }

    /// Listens on the hotspot's addresses only. Go leaves out one it can't listen on, unless none works.
    /// `port` is for the tests, which can't count on 51820 being free.
    func start(hosts: [String], setup: WireGuardSetup, dns: DNSChoice.Upstream = DNSChoice.defaultUpstream,
               port: UInt16 = WireGuardSetup.port) throws {
        stop()
        // Go reads exactly 32 bytes behind each key pointer.
        guard setup.serverPrivateKey.count == 32 else { throw Failure(message: "the server key isn't 32 bytes") }
        let error = setup.serverPrivateKey.withUnsafeBytes { key in
            hosts.joined(separator: ",").withCString { h in
                TetherWGStart(UnsafeMutablePointer(mutating: h), Int32(port),
                              UnsafeMutablePointer(mutating: key.bindMemory(to: UInt8.self).baseAddress))
            }
        }
        if let message = take(error) { throw Failure(message: message) }
        running = true
        do {
            try setPeers(setup, dns: dns)
        } catch {
            // Not left half started: HotspotSession's watcher round retries a server that isn't running.
            TetherWGStop()
            running = false
            throw error
        }
    }

    func stop() {
        guard running else { return }
        let last = currentRun()
        carried.absorb(last.totals)
        carriedDevices.absorb(last.peers)
        lastRun = ServerSnapshot() // the next run counts from zero
        TetherWGStop()
        running = false
    }

    /// Lets in exactly the devices in `setup`. A removed device's open connections finish on their own,
    /// and what it used is dropped, as on the server. A saved device the server doesn't let in now keeps it.
    /// A paused device stays, and keeps what it used: the server closes its connections and lets nothing through.
    /// `dns` is where lookups to Tether's own address go, see `DNSChoice`. It goes in the same message, so
    /// the two never disagree.
    func setPeers(_ setup: WireGuardSetup, dns: DNSChoice.Upstream = DNSChoice.defaultUpstream) throws {
        // Also while stopped: a device removed then mustn't hand what it used to the next device
        // that gets its address.
        carriedDevices.keep(only: Set(setup.serverPeers.map(\.address)).union(setup.peers.map(\.address)))
        guard running else { return }
        let peers = setup.serverPeers
        guard peers.allSatisfy({ $0.publicKey.count == 32 }) else { throw Failure(message: "a device key isn't 32 bytes") }
        // No router mark: the server finds a router by its clients' traffic, see noticeRouter in server.go.
        let message = ConfigMessage(peers, dns: dns)
        let json = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        let error = json.withCString { TetherWGConfigure(UnsafeMutablePointer(mutating: $0)) }
        if let message = take(error) { throw Failure(message: message) }
    }

    /// Opens the config page to the devices on exactly `hosts`, where its listener is ready now (#27).
    /// Stopped, there's nothing to tell: a start opens it nowhere. Go refuses only an address that
    /// isn't one, which is logged, and then opens it nowhere.
    func setPage(_ hosts: [String]) {
        guard running else { return }
        let error = hosts.joined(separator: ",").withCString { TetherWGSetPage(UnsafeMutablePointer(mutating: $0)) }
        if let message = take(error) { log("WireGuard: the config page can't be opened to the devices: \(message)") }
    }

    /// Gives memory Go's GC has freed back to iOS, on a memory warning.
    func freeMemory() {
        if running { TetherWGFreeMemory() }
    }

    /// Counters that only grow, across restarts, the totals and each device's. Which devices are
    /// connected, the last config that knocked but no longer works, and each address's from the last
    /// minute for the config page (#63), only while running.
    func snapshot() -> ServerSnapshot {
        let run = running ? currentRun() : ServerSnapshot()
        return ServerSnapshot(totals: carried.apply(to: run.totals), peers: carriedDevices.apply(to: run.peers), stale: run.stale,
                              recentStale: run.recentStale)
    }

    /// This run's stats. Stats it can't read leave the last counters it read, so a stop still carries
    /// what the run counted, with no device shown as connected, and the failure is logged once, not
    /// every second.
    private func currentRun() -> ServerSnapshot {
        guard let json = take(TetherWGStats()) else { return lastRun.disconnected }
        do {
            lastRun = try Stats.read(Data(json.utf8))
            statsProblem = nil
            return lastRun
        } catch {
            let problem = "WireGuard stats can't be read: \(error)"
            if problem != statsProblem { log(problem) }
            statsProblem = problem
            return lastRun.disconnected
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// The message version both sides read, see boundary.go. A key added later doesn't change it.
    nonisolated static let messageVersion = 1

    /// The devices for TetherWGConfigure, see configMessage in boundary.go.
    struct ConfigMessage: Encodable {
        var v = WireGuardServer.messageVersion
        let peers: [Peer]
        /// Added later, so the version stays. Without it Go keeps lookups to 10.7.0.1 inside.
        var dns: DNS?

        struct Peer: Encodable {
            let key: Data // base64 in the JSON
            let address: String
            var paused = false // added later, so the version stays
        }

        /// A DoH URL or plain servers, never both: configDNS in WireGuard/dns.go.
        struct DNS: Encodable {
            var doh: String?
            var udp: [String]?
        }
    }

    /// What TetherWGStats returns, see statsMessage in boundary.go. WireGuard/testdata/stats.json is an
    /// example Go's tests check against the real thing.
    enum Stats {
        /// Only the version, read first: another version may lack keys this one needs.
        private struct Version: Decodable {
            let v: Int
        }

        private struct Message: Decodable {
            let up: UInt64
            let down: UInt64
            let peers: [Peer]
            let stale: Stale?
            let recent: [Stale]?

            struct Peer: Decodable {
                let address: String
                let connected: Bool
                let up: UInt64
                let down: UInt64
                let handshake: Int64 // Unix seconds, 0 for never
                let endpoint: String // "" for never
            }

            struct Stale: Decodable {
                let kind: String // "" for none yet
                let at: Int64 // Unix seconds
                let from: String? // "" for nowhere
            }
        }

        /// Refuses a message of a version this app doesn't read, before anything else is read from it.
        static func checkVersion(_ json: Data) throws {
            let version = try JSONDecoder().decode(Version.self, from: json).v
            guard version == WireGuardServer.messageVersion else { throw OtherVersion(version: version) }
        }

        struct OtherVersion: Error, CustomStringConvertible {
            let version: Int
            var description: String { "version \(version), this app reads \(WireGuardServer.messageVersion)" }
        }

        static func read(_ json: Data) throws -> ServerSnapshot {
            try checkVersion(json)
            let m = try JSONDecoder().decode(Message.self, from: json)
            var peers: [String: PeerStats] = [:]
            for p in m.peers {
                peers[p.address] = PeerStats(traffic: TrafficTotals(bytesUp: p.up, bytesDown: p.down), connected: p.connected,
                                             lastHandshake: p.handshake > 0 ? Date(timeIntervalSince1970: TimeInterval(p.handshake)) : nil,
                                             endpoint: p.endpoint.isEmpty ? nil : p.endpoint)
            }
            // A kind this app doesn't know says nothing, like one that isn't there.
            func stale(_ s: Message.Stale) -> StaleConfig? {
                StaleConfig.Kind(rawValue: s.kind).map {
                    StaleConfig(kind: $0, at: Date(timeIntervalSince1970: TimeInterval(s.at)), from: s.from.flatMap { $0.isEmpty ? nil : $0 })
                }
            }
            return ServerSnapshot(totals: TrafficTotals(bytesUp: m.up, bytesDown: m.down), peers: peers, stale: m.stale.flatMap(stale),
                                  recentStale: (m.recent ?? []).compactMap(stale))
        }
    }
}

extension WireGuardServer {
    /// The Go server's lines since the last call, for the shared log, see golog.go. It works with no
    /// server running, so a server that stopped leaves its last lines. A message this app can't read
    /// becomes a line that says so.
    nonisolated static func takeLog() -> [DebugLog.Line] {
        guard let json = take(TetherWGLog()) else { return [] }
        do {
            return try ServerLog.read(Data(json.utf8))
        } catch {
            return [DebugLog.Line(at: Date(), text: "go: the server's log can't be read: \(error)")]
        }
    }

    /// What TetherWGLog returns, see logMessage in golog.go. WireGuard/testdata/log.json is an example
    /// Go's tests check against the real thing.
    enum ServerLog {
        private struct Message: Decodable {
            let lines: [Line]
            let dropped: Int

            struct Line: Decodable {
                let at: Int64 // Unix milliseconds
                let text: String
            }
        }

        /// Each line marked as the server's with "go:", after a line for any it lost.
        static func read(_ json: Data) throws -> [DebugLog.Line] {
            try Stats.checkVersion(json)
            let m = try JSONDecoder().decode(Message.self, from: json)
            var lines = m.lines.map { DebugLog.Line(at: Date(timeIntervalSince1970: TimeInterval($0.at) / 1000), text: "go: \($0.text)") }
            if m.dropped > 0 {
                lines.insert(DebugLog.Line(at: lines.first?.at ?? Date(), text: "go: \(m.dropped) earlier lines were lost"), at: 0)
            }
            return lines
        }
    }
}

private extension ServerSnapshot {
    /// The same counters, with no device connected or knocking: what's known when a read fails.
    var disconnected: ServerSnapshot {
        var s = self
        for address in s.peers.keys { s.peers[address]?.connected = false }
        s.stale = nil
        s.recentStale = []
        return s
    }
}

/// Reads and frees a string Go returned.
private func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    defer { TetherWGFree(p) }
    return String(cString: p)
}

extension WireGuardServer.ConfigMessage {
    /// The devices the server lets in, paused or not, and where lookups to Tether's own address go.
    init(_ peers: [WireGuardSetup.Peer], dns: DNSChoice.Upstream? = nil) {
        let message: DNS? = switch dns {
        case let .doh(url): DNS(doh: url.absoluteString)
        case let .servers(servers): DNS(udp: servers)
        case nil: nil
        }
        self.init(peers: peers.map { Peer(key: $0.publicKey, address: $0.address, paused: $0.paused != nil) }, dns: message)
    }
}
