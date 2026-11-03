import Foundation
import TetherWG

/// Runs the WireGuard server from WireGuard/ (Go, linked as TetherWG.xcframework). Only the main actor calls it. The Go side is thread-safe and quick, so nothing here waits.
@MainActor
final class WireGuardServer {
    private(set) var running = false
    private var carried = CarriedTotals()
    /// The run's counters at the last read Swift could decode.
    private var lastRun = TrafficTotals()
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
        carried.absorb(currentRun())
        lastRun = TrafficTotals() // the next run counts from zero
        TetherWGStop()
        running = false
        connectedAddresses = []
    }

    /// Lets in exactly the devices in `setup`. A removed device's open connections finish on their own.
    func setPeers(_ setup: WireGuardSetup) throws {
        guard running else { return }
        let peers = setup.serverPeers
        guard peers.allSatisfy({ $0.publicKey.count == 32 }) else { throw Failure(message: "a device key isn't 32 bytes") }
        // No router mark: the server finds a router by its clients' traffic, see noticeRouter in server.go.
        let message = ConfigMessage(peers: peers.map { ConfigMessage.Peer(key: $0.publicKey, address: $0.address) })
        let json = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        let error = json.withCString { TetherWGConfigure(UnsafeMutablePointer(mutating: $0)) }
        if let message = take(error) { throw Failure(message: message) }
    }

    /// Gives memory Go's GC has freed back to iOS, on a memory warning.
    func freeMemory() {
        if running { TetherWGFreeMemory() }
    }

    /// Counters that only grow, across restarts.
    func snapshot() -> TrafficTotals {
        carried.apply(to: running ? currentRun() : TrafficTotals())
    }

    /// The tunnel addresses of the devices with a recent handshake: set up and working, also
    /// before they sent anything. From the last `snapshot()`, so both describe the same moment.
    private(set) var connectedAddresses: Set<String> = []

    /// This run's counters. Stats it can't read leave the last ones it read, so a stop still carries
    /// what the run counted, and the failure is logged once, not every second.
    private func currentRun() -> TrafficTotals {
        guard let json = take(TetherWGStats()) else {
            connectedAddresses = []
            return lastRun
        }
        do {
            let stats = try Stats(json: Data(json.utf8))
            lastRun = stats.totals
            connectedAddresses = stats.connected
            statsProblem = nil
        } catch {
            let problem = "WireGuard stats can't be read: \(error)"
            if problem != statsProblem { log(problem) }
            statsProblem = problem
        }
        return lastRun
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// The message version both sides read, see boundary.go. A key added later doesn't change it.
    static let messageVersion = 1

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
    struct Stats {
        let totals: TrafficTotals
        /// The devices with a recent handshake: set up and working, also before they sent anything.
        let connected: Set<String>

        private struct Message: Decodable {
            let v: Int
            let up: UInt64
            let down: UInt64
            let peers: [Peer]

            struct Peer: Decodable {
                let address: String
                let connected: Bool
            }
        }

        struct OtherVersion: Error, CustomStringConvertible {
            let version: Int
            var description: String { "version \(version), this app reads \(WireGuardServer.messageVersion)" }
        }

        init(json: Data) throws {
            let m = try JSONDecoder().decode(Message.self, from: json)
            guard m.v == WireGuardServer.messageVersion else { throw OtherVersion(version: m.v) }
            totals = TrafficTotals(bytesUp: m.up, bytesDown: m.down)
            connected = Set(m.peers.filter(\.connected).map(\.address))
        }
    }
}

/// Reads and frees a string Go returned.
private func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    defer { TetherWGFree(p) }
    return String(cString: p)
}
