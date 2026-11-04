#if DEBUG
import Foundation

// Stand-ins for the WireGuard server, the config page and the keep-alive sound, with what a test or
// a demo sets. The unit tests (Tests/) and the demos (DemoMode.swift) share them, so a demo can only
// show what the real session publishes. Foundation only, and compiled out of Release builds.

/// The WireGuard server, with errors to order and the counters and handshakes a test sets. It keeps
/// the real one's contract (see `WireGuardServing`): `start` applies the devices too, and is left
/// stopped when they're refused.
@MainActor
final class FakeServer: WireGuardServing {
    struct Failure: Error, CustomStringConvertible {
        var description: String { "port in use" }
    }

    /// Like what the real server says about a list it refuses.
    struct Refused: Error, CustomStringConvertible {
        var description: String { "the device list repeats a key or address" }
    }

    private(set) var running = false
    /// Thrown by every start while set, before the devices are applied.
    var startError: Error?
    /// Every list with a device on this tunnel address is refused, by `setPeers` and so by `start`:
    /// the real server refuses a list by what's in it, so trying the same list again doesn't help.
    var refusedAddress: String?
    /// What the next snapshot reports. Connected only while running, and the counters always, as
    /// the real server carries them across restarts.
    var connected: Set<String> = []
    var totals = TrafficTotals()
    var peerTraffic: [String: TrafficTotals] = [:]
    /// Reported only while running, as the real server's knocks go with it.
    var stale: StaleConfig?
    private(set) var starts: [String] = []
    private(set) var lastSetup: WireGuardSetup?

    func start(host: String, setup: WireGuardSetup, port: UInt16) throws {
        stop()
        starts.append(host)
        if let startError { throw startError }
        running = true
        do {
            try setPeers(setup)
        } catch {
            running = false
            throw error
        }
    }

    func stop() {
        running = false
    }

    func setPeers(_ setup: WireGuardSetup) throws {
        guard running else { return }
        if let refusedAddress, setup.serverPeers.contains(where: { $0.address == refusedAddress }) { throw Refused() }
        lastSetup = setup
    }

    func snapshot() -> ServerSnapshot {
        var peers: [String: PeerStats] = [:]
        for (address, traffic) in peerTraffic { peers[address] = PeerStats(traffic: traffic) }
        if running {
            for address in connected { peers[address, default: PeerStats()].connected = true }
        }
        return ServerSnapshot(totals: totals, peers: peers, stale: running ? stale : nil)
    }

    func freeMemory() {}
}

@MainActor
final class FakePage: ConfigPageServing {
    struct Failure: Error, CustomStringConvertible {
        var description: String { "address in use" }
    }

    var respond: @MainActor (ConfigPage.Request, String) -> ConfigPage.Response = { _, _ in ConfigPage.notFound }
    var onChange: @MainActor () -> Void = {}
    var onFailure: @MainActor (Error) -> Void = { _ in }
    private(set) var running = false
    private(set) var listening = false
    /// "host:port" for each start.
    private(set) var starts: [String] = []

    func start(host: String, port: UInt16) {
        stop()
        starts.append("\(host):\(port)")
        running = true
    }

    func stop() {
        running = false
        setListening(false)
    }

    /// The listener is ready for connections.
    func becomeReady() { setListening(true) }

    /// The listener failed after it started, the way the real one stops itself.
    func fail() {
        stop()
        onFailure(Failure())
    }

    /// A request from a device on the hotspot.
    func ask(_ request: ConfigPage.Request, from client: String = "172.20.10.2") -> ConfigPage.Response {
        respond(request, client)
    }

    private func setListening(_ value: Bool) {
        guard value != listening else { return }
        listening = value
        onChange()
    }
}

final class FakeSound: KeepAliveSound {
    private(set) var playing = false
    /// Started, but iOS gives it no sound.
    var silent = false
    var sounding: Bool { playing && !silent }
    func start() { playing = true }
    func stop() { playing = false }
}
#endif
