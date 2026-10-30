import Foundation
import TetherWG

/// Runs the WireGuard server from WireGuard/ (Go, linked as TetherWG.xcframework). Only the main actor calls it. The Go side is thread-safe and quick, so nothing here waits.
@MainActor
final class WireGuardServer {
    private(set) var running = false
    private var carried = CarriedTotals()

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
        TetherWGStop()
        running = false
        connectedAddresses = []
    }

    /// Lets in exactly the devices in `setup`. A removed device's open connections finish on their own.
    func setPeers(_ setup: WireGuardSetup) throws {
        guard running else { return }
        let peers = setup.serverPeers
        guard peers.allSatisfy({ $0.publicKey.count == 32 }) else { throw Failure(message: "a device key isn't 32 bytes") }
        var keys = Data()
        for p in peers { keys.append(p.publicKey) }
        // No router mark: the server finds a router by its clients' traffic, see noticeRouter in server.go.
        let addresses = peers.map(\.address).joined(separator: "\n")
        let error = keys.withUnsafeBytes { k in
            addresses.withCString { a in
                TetherWGSetPeers(UnsafeMutablePointer(mutating: k.bindMemory(to: UInt8.self).baseAddress),
                                 UnsafeMutablePointer(mutating: a), Int32(peers.count))
            }
        }
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

    private func currentRun() -> TrafficTotals {
        guard let json = take(TetherWGStats()), let data = json.data(using: .utf8),
              let stats = try? JSONDecoder().decode(GoStats.self, from: data) else {
            connectedAddresses = []
            return TrafficTotals()
        }
        connectedAddresses = Set(stats.connected)
        return TrafficTotals(bytesUp: stats.up, bytesDown: stats.down)
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// The parts of TetherWGStats' JSON the app uses, see Stats in server.go.
    private struct GoStats: Decodable {
        let up: UInt64
        let down: UInt64
        let connected: [String]
    }
}

/// Reads and frees a string Go returned.
private func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    defer { TetherWGFree(p) }
    return String(cString: p)
}
