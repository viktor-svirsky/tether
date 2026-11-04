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

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    /// Listens on the hotspot address only.
    /// `port` is for the tests, which can't count on 51820 being free.
    func start(host: String, setup: WireGuardSetup, port: UInt16 = WireGuardSetup.port) throws {
        stop()
        // Go reads exactly 32 bytes behind each key pointer.
        guard setup.serverPrivateKey.count == 32 else { throw Failure(message: "the server key isn't 32 bytes") }
        let error = setup.serverPrivateKey.withUnsafeBytes { key in
            host.withCString { h in
                TetherWGStart(UnsafeMutablePointer(mutating: h), Int32(port),
                              UnsafeMutablePointer(mutating: key.bindMemory(to: UInt8.self).baseAddress))
            }
        }
        if let message = take(error) { throw Failure(message: message) }
        running = true
        do {
            try setPeers(setup)
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
    func setPeers(_ setup: WireGuardSetup) throws {
        guard running else { return }
        let peers = setup.serverPeers
        guard peers.allSatisfy({ $0.publicKey.count == 32 }) else { throw Failure(message: "a device key isn't 32 bytes") }
        // No router mark: the server finds a router by its clients' traffic, see noticeRouter in server.go.
        let message = ConfigMessage(peers: peers.map { ConfigMessage.Peer(key: $0.publicKey, address: $0.address) })
        let json = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        let error = json.withCString { TetherWGConfigure(UnsafeMutablePointer(mutating: $0)) }
        if let message = take(error) { throw Failure(message: message) }
        carriedDevices.keep(only: Set(peers.map(\.address)).union(setup.peers.map(\.address)))
    }

    /// Gives memory Go's GC has freed back to iOS, on a memory warning.
    func freeMemory() {
        if running { TetherWGFreeMemory() }
    }

    /// Counters that only grow, across restarts, the totals and each device's. Which devices are
    /// connected, and the last config that knocked but no longer works, only while running.
    func snapshot() -> ServerSnapshot {
        let run = running ? currentRun() : ServerSnapshot()
        return ServerSnapshot(totals: carried.apply(to: run.totals), peers: carriedDevices.apply(to: run.peers), stale: run.stale)
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

        struct Peer: Encodable {
            let key: Data // base64 in the JSON
            let address: String
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
            }
        }

        struct OtherVersion: Error, CustomStringConvertible {
            let version: Int
            var description: String { "version \(version), this app reads \(WireGuardServer.messageVersion)" }
        }

        static func read(_ json: Data) throws -> ServerSnapshot {
            let version = try JSONDecoder().decode(Version.self, from: json).v
            guard version == WireGuardServer.messageVersion else { throw OtherVersion(version: version) }
            let m = try JSONDecoder().decode(Message.self, from: json)
            var peers: [String: PeerStats] = [:]
            for p in m.peers {
                peers[p.address] = PeerStats(traffic: TrafficTotals(bytesUp: p.up, bytesDown: p.down), connected: p.connected,
                                             lastHandshake: p.handshake > 0 ? Date(timeIntervalSince1970: TimeInterval(p.handshake)) : nil,
                                             endpoint: p.endpoint.isEmpty ? nil : p.endpoint)
            }
            // A kind this app doesn't know says nothing, like one that isn't there.
            let stale = m.stale.flatMap { s in
                StaleConfig.Kind(rawValue: s.kind).map { StaleConfig(kind: $0, at: Date(timeIntervalSince1970: TimeInterval(s.at))) }
            }
            return ServerSnapshot(totals: TrafficTotals(bytesUp: m.up, bytesDown: m.down), peers: peers, stale: stale)
        }
    }
}

private extension ServerSnapshot {
    /// The same counters, with no device connected or knocking: what's known when a read fails.
    var disconnected: ServerSnapshot {
        var s = self
        for address in s.peers.keys { s.peers[address]?.connected = false }
        s.stale = nil
        return s
    }
}

/// Reads and frees a string Go returned.
private func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    defer { TetherWGFree(p) }
    return String(cString: p)
}
