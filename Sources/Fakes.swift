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
    /// Where a connected device's last handshake came from, ip:port, by tunnel address.
    var endpoints: [String: String] = [:]
    /// Each device's last handshake, by tunnel address. Reported only while running, as the real
    /// server forgets them when it stops.
    var handshakes: [String: Date] = [:]
    /// Reported only while running, as the real server's knocks go with it.
    var stale: StaleConfig?
    /// Other addresses' configs that knocked before `stale`, which the config page reads with it.
    var earlierStale: [StaleConfig] = []
    /// The proxy's counters, always reported, like a device's.
    var proxyTraffic = TrafficTotals()
    /// Its open connections and where it listens, reported only while running with the proxy on, as
    /// Go does. Nil listens where Go does on a usual hotspot.
    var proxyOpen = 0
    var proxyAddresses: [String]?
    /// The addresses of each start, comma-separated.
    private(set) var starts: [String] = []
    private(set) var lastSetup: WireGuardSetup?
    /// Where the last start or change sent lookups to Tether's own address.
    private(set) var lastDNS: DNSChoice.Upstream?
    /// Whether the last start or change kept the devices out of the local networks.
    private(set) var lastBlockLocal: Bool?
    /// Where the config page is open to the devices, see `setPage`. A run starts with it nowhere, as
    /// the real one does.
    private(set) var page: [String] = []

    func start(hosts: [String], setup: WireGuardSetup, dns: DNSChoice.Upstream, blockLocal: Bool, port: UInt16) throws {
        stop()
        starts.append(hosts.joined(separator: ","))
        if let startError { throw startError }
        running = true
        page = []
        do {
            try setPeers(setup, dns: dns, blockLocal: blockLocal)
        } catch {
            running = false
            throw error
        }
    }

    func stop() {
        running = false
        page = []
    }

    func setPage(_ hosts: [String]) {
        guard running else { return }
        page = hosts
    }

    /// The addresses of each listen, comma-separated, see `listen(on:)`.
    private(set) var listens: [String] = []
    /// Thrown by every listen while set.
    var listenError: Error?

    func listen(on hosts: [String]) throws {
        guard running else { return }
        listens.append(hosts.joined(separator: ","))
        if let listenError { throw listenError }
    }

    func setPeers(_ setup: WireGuardSetup, dns: DNSChoice.Upstream, blockLocal: Bool) throws {
        guard running else { return }
        if let refusedAddress, setup.serverPeers.contains(where: { $0.address == refusedAddress }) { throw Refused() }
        lastSetup = setup
        lastDNS = dns
        lastBlockLocal = blockLocal
    }

    func snapshot() -> ServerSnapshot {
        var peers: [String: PeerStats] = [:]
        for (address, traffic) in peerTraffic { peers[address] = PeerStats(traffic: traffic) }
        if running {
            for address in connected {
                peers[address, default: PeerStats()].connected = true
                peers[address]?.endpoint = endpoints[address]
            }
            for (address, handshake) in handshakes { peers[address, default: PeerStats()].lastHandshake = handshake }
        }
        var proxy = ProxyStats(traffic: proxyTraffic)
        if running, let on = lastSetup?.proxy, on.on {
            proxy.addresses = proxyAddresses ?? ["\(Hotspot.host):8118"]
            proxy.paused = on.paused != nil
            proxy.open = proxyOpen
        }
        return ServerSnapshot(totals: totals, peers: peers, proxy: proxy, stale: running ? stale : nil,
                              recentStale: running ? earlierStale + [stale].compactMap(\.self) : [])
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
    var onRefused: @MainActor (_ client: String) -> Void = { _ in }
    private(set) var running = false
    private(set) var readyHosts: [String] = []
    var listening: Bool { !readyHosts.isEmpty }
    /// "hosts:port" for each start, the hosts comma-separated.
    private(set) var starts: [String] = []
    private var hosts: [String] = []

    func start(hosts: [String], port: UInt16) {
        stop()
        starts.append("\(hosts.joined(separator: ",")):\(port)")
        self.hosts = hosts
        running = true
    }

    func stop() {
        running = false
        setReady([])
    }

    /// The listeners on `hosts` are ready for connections, by default all of the last start's.
    func becomeReady(_ hosts: [String]? = nil) { setReady(hosts ?? self.hosts) }

    /// The listener failed after it started, the way the real one stops itself.
    func fail() {
        stop()
        onFailure(Failure())
    }

    /// A request from a device on the hotspot.
    func ask(_ request: ConfigPage.Request, from client: String = "172.20.10.2") -> ConfigPage.Response {
        respond(request, client)
    }

    private func setReady(_ hosts: [String]) {
        guard hosts != readyHosts else { return }
        readyHosts = hosts
        onChange()
    }
}

/// mDNS for `<name>.local`, see `HostNamePublishing`. It confirms each name at once, unless
/// `confirms` is off (still checking) or `refuses` says why not (taken by another device, say).
@MainActor
final class FakeHostName: HostNamePublishing {
    var confirms = true { didSet { onChange?() } }
    var refuses: String? { didSet { onChange?() } }
    var onChange: (@MainActor () -> Void)?
    private var asked: HostNameRecord?
    var published: HostNameRecord? { confirms && refuses == nil ? asked : nil }
    var failure: String? { asked == nil ? nil : refuses }
    /// Each change, "name address" or "name -" for taken down.
    private(set) var changes: [String] = []

    func publish(_ name: String, at address: String?) {
        let change = "\(name) \(address ?? "-")"
        // Nothing to take down before the first name.
        guard change != changes.last ?? "\(name) -" else { return }
        changes.append(change)
        asked = address.map { HostNameRecord(name: name, address: $0) }
    }
}

final class FakeSound: KeepAliveSound {
    private(set) var playing = false
    /// Started, but iOS gives it no sound.
    var silent = false
    var sounding: Bool { playing && !silent }
    /// A call holds the audio now.
    var interrupted = false
    /// A call came and went since the last round asked.
    var interruptedSinceTaken = false
    func takeInterruption() -> Bool {
        defer { interruptedSinceTaken = false }
        return interrupted || interruptedSinceTaken
    }
    func start() { playing = true }
    func stop() { playing = false }
}
#endif
