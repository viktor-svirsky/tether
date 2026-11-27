#if DEBUG
import Foundation

// Fixed, fake app state for the UI tests (UITests/). On the simulator there is no Personal Hotspot
// and nothing to share, so a test launches the app with `-TetherDemo <scenario>` and gets one of
// these states instead.
//
// A demo runs the real HotspotSession once, against the fakes in Fakes.swift, so a screen shows only
// what the session itself publishes. Nothing runs after that: no WireGuard server, keep-alive audio,
// hotspot watcher, 1 s sampler, knock or scene observers. Model.swift has the few hooks, all inside
// `#if DEBUG`. Foundation only, and compiled out of Release builds.

enum DemoScenario: String, CaseIterable {
    /// Hotspot off.
    case waiting
    /// Like `waiting`, on the first launch: the screen before iOS asks for Local Network access.
    case localNetworkIntro
    /// Hotspot off, and the Keychain is locked: the problem shows from launch, and there's no QR code.
    case wireGuardLockedWaiting
    /// Hotspot on, no device yet: only Add a device.
    case noDevices
    /// Two devices, the iPad connected and the Windows PC not, and a speed.
    case sharing
    /// Like `sharing`, but the Keychain is locked: WireGuard isn't running and there's no QR code.
    case wireGuardLocked
    /// Like `sharing`, but the saved WireGuard keys can't be decoded, so only starting over gets past it.
    case wireGuardNeedsReset
    /// Hotspot on, a first launch whose new WireGuard keys can't be saved: no QR code, and WireGuard isn't running.
    case wireGuardUnsaved
    /// Like `sharing`, but nothing can be saved: there's no QR code for the next device, and renaming or
    /// removing a device doesn't save. The devices still connect.
    case qrCodeUnsaved
    /// Like `sharing`, with two days left before this build stops opening.
    case expiring
    /// Like `sharing`, with notifications turned off for Tether in Settings.
    case notificationsOff
    /// Like `sharing`, and it asks for permission on screen at launch, through the real notification
    /// center, if it never asked. Leaving the screen posts `notice`.
    case notifying
    /// Like `sharing`, opened on the Settings sheet with notifications allowed, for the
    /// screenshot.
    case notificationsScreen
    /// Like `sharing`, but iOS blocks Tether's replies: Local Network is off for Tether.
    case localNetworkDenied
    /// Like `sharing`, and a device keeps trying to connect with a config that no longer works.
    case staleConfig
    /// Like `noDevices`, opened on the Add a device sheet, for the screenshot.
    case addDeviceScreen
    /// Like `addDeviceScreen`, with Computer picked.
    case addDeviceComputer
    /// Like `addDeviceComputer`, on a carrier that gives the iPhone IPv6 only: Tether listens on a
    /// documentation IPv6 address, so the page's address is IPv6 and the sheet says a computer needs it.
    case addDeviceComputerIPv6
    /// Like `sharing`, opened on the Add a device sheet as if the Windows PC had just downloaded
    /// the code: its tunnel isn't on yet.
    case addDeviceWaiting
    /// Like `addDeviceWaiting`, for the iPad, which is connected.
    case addDeviceDone
    /// Like `addDeviceDone`, but nothing can be saved, so the iPad's new name doesn't save.
    case addDeviceDoneUnsaved
    /// Like `sharing`, but the Windows PC's config points at an IPv6 address this iPhone had before,
    /// the way a new cellular session moves it on an IPv6-only carrier, so it needs adding again.
    case oldAddress
    /// Like `oldAddress` on a carrier that gives the iPhone IPv6 only, but the Windows PC's config uses
    /// this iPhone's name, which the demo's mDNS never answers (#65).
    case nameNotAnswered
    /// Like `sharing`, but the iPad is paused: its tunnel is up, and nothing gets through.
    case paused
    /// Like `sharing`, and a device at 172.20.10.3 on the hotspot isn't on WireGuard or the proxy
    /// (#109). The iPad answers the knock too, from where its handshake comes, so it isn't listed.
    case notUsingTether
    /// Like `sharing`, with the proxy on (#78): two connections open, 85 MB this month.
    case proxy
    /// Like `proxy`, on a carrier that gives the iPhone IPv6 only: the proxy listens at 172.20.10.1 and
    /// at the hotspot's IPv6 address, which Apple devices need there.
    case proxyIPv6
    /// Like `sharing`, opened on Add a device's proxy path, with the proxy on and no page through it yet.
    case addDeviceProxy
    /// Like `addDeviceProxy`, with a device's page going through the proxy, so it's working.
    case addDeviceProxyWorking
    /// Like `noDevices`: a moment after Add a device lets its code in, a device that scanned it
    /// connects from the hotspot, so a test walks the sheet from the code to connected (#315).
    case addDeviceConnects

    static let argument = "-TetherDemo"

    /// Local 2026-10-17 18:00. The expiry warning is relative to this.
    static let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 18))!

    /// What `notifying` posts.
    static let notice = Notice(kind: .connected, id: "demo", title: "iPad connected", body: "It's using this iPhone's data now.")

    /// The scenario named after `-TetherDemo` in the launch arguments, nil in a normal launch.
    static var current: DemoScenario? {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: argument) else { return nil }
        guard args.indices.contains(flag + 1), let scenario = DemoScenario(rawValue: args[flag + 1]) else {
            fatalError("\(argument) needs one of: \(allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return scenario
    }
}

/// The notification center of a demo launch: the permission its scenario says, and nothing is ever asked or posted.
@MainActor
final class DemoNoticeCenter: NoticeCenter {
    private let state: NoticePermission
    init(_ state: NoticePermission) { self.state = state }
    func permission() async -> NoticePermission { state }
    func ask() async -> Bool { false }
    func add(_ notice: Notice) async {}
    func schedule(_ notice: Notice, after: TimeInterval) async {}
    func remove(_ id: String) {}
}

/// A Keychain that is locked until the first unlock after a restart: it can't be read or written.
final class LockedSecrets: SecretStore {
    struct Locked: Error {}
    func load() throws -> Data? { throw Locked() }
    func save(_ data: Data) throws { throw Locked() }
}

/// A Keychain that reads but refuses every save, the way a build without its Keychain entitlement does.
final class UnsavableSecrets: SecretStore {
    private let data: Data?
    init(_ data: Data?) { self.data = data }
    func load() -> Data? { data }
    func save(_ data: Data) throws { throw KeychainSecrets.Failure(status: -34018) }
}

struct DemoState {
    let scenario: DemoScenario
    private(set) var running = true
    private(set) var downSpeed = 0.0
    private(set) var upSpeed = 0.0
    /// How many whole seconds `addDeviceConnects` waits with the code let in, long enough for a UI test to see the code first.
    var connectsAfter = 8

    static func fromLaunchArguments() -> DemoState? {
        DemoScenario.current.map(DemoState.init)
    }

    init(_ scenario: DemoScenario) {
        self.scenario = scenario
        guard ![.waiting, .wireGuardLockedWaiting, .localNetworkIntro].contains(scenario) else {
            running = false
            return
        }
        if [.noDevices, .wireGuardUnsaved, .addDeviceScreen, .addDeviceComputer, .addDeviceComputerIPv6, .addDeviceConnects].contains(scenario) { return }
        downSpeed = 3_200_000
        upSpeed = 400_000
    }

    /// Where the WireGuard setup is "kept". Never the Keychain.
    func secrets() -> SecretStore {
        let secrets = InMemorySecrets()
        switch scenario {
        case .sharing, .wireGuardLocked, .expiring, .qrCodeUnsaved, .notificationsOff, .notifying, .notificationsScreen, .addDeviceWaiting, .addDeviceDone, .addDeviceDoneUnsaved, .localNetworkDenied, .oldAddress, .nameNotAnswered, .staleConfig, .paused, .notUsingTether,
             .proxy, .proxyIPv6, .addDeviceProxy, .addDeviceProxyWorking:
            var setup = WireGuardSetup.new()
            let ipad = setup.addPeer(name: "iPad")
            if scenario == .paused, let ipad { setup.pausePeer(ipad.id, .byYou) }
            // A 10 GB limit, so its screen shows the meter. The Windows PC has none.
            if let ipad { setup.limitPeer(ipad.id, 10_000_000_000) }
            // A documentation address. The demo listens on 172.20.10.1, so it's an old one.
            let name = scenario == .nameNotAnswered ? HostName.name(for: setup.serverPublicKey) : nil
            _ = setup.addPeer(name: "Windows PC", host: scenario == .oldAddress ? "2001:db8::1" : name)
            if Self.proxyOn.contains(scenario) { setup.turnProxy(on: true) }
            secrets.data = try? JSONEncoder().encode(setup) // no ready device yet: loading makes and saves one
        case .wireGuardNeedsReset:
            secrets.data = Data("not a WireGuard setup".utf8) // undecodable, like a setup from a newer version
        default: break
        }
        switch scenario {
        case .wireGuardLocked, .wireGuardLockedWaiting: return LockedSecrets()
        case .wireGuardUnsaved, .qrCodeUnsaved, .addDeviceDoneUnsaved: return UnsavableSecrets(secrets.data)
        default: return secrets
        }
    }

    /// The settings, the notification switches all on and no idle stop at each launch, so one test's
    /// setting doesn't leak into the next. Never the app's own.
    /// Where a demo launch keeps its settings, see `settingsDefaults`.
    static let settingsSuite = "TetherDemo"

    func settingsDefaults() -> UserDefaults {
        UserDefaults.standard.removePersistentDomain(forName: Self.settingsSuite)
        return UserDefaults(suiteName: Self.settingsSuite)!
    }

    /// The log Settings shares, in its own folder, emptied at each launch. Never the app's.
    func debugLog() -> DebugLog {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TetherDemoLog")
        try? FileManager.default.removeItem(at: directory)
        return DebugLog(directory: directory, source: { [] })
    }

    /// Nil for `notifying`, which uses the real one.
    @MainActor
    func noticeCenter() -> NoticeCenter? {
        switch scenario {
        case .notifying: nil
        case .notificationsOff: DemoNoticeCenter(.denied)
        case .notificationsScreen: DemoNoticeCenter(.allowed)
        default: DemoNoticeCenter(.notAsked)
        }
    }

    /// The iPad's tunnel is up, the Windows PC's isn't, so the list shows both states. In `paused` the
    /// session shows the iPad paused instead.
    var connected: Set<String> {
        ([.sharing, .expiring, .qrCodeUnsaved, .notificationsOff, .notifying, .notificationsScreen, .addDeviceWaiting, .addDeviceDone, .addDeviceDoneUnsaved, .oldAddress, .nameNotAnswered, .staleConfig, .paused, .notUsingTether] + Self.proxyOn).contains(scenario) ? ["10.7.0.2"] : []
    }

    /// The demos with the proxy on.
    private static let proxyOn: [DemoScenario] = [.proxy, .proxyIPv6, .addDeviceProxy, .addDeviceProxyWorking]

    /// A carrier that gives the iPhone IPv6 only: Tether listens on a documentation IPv6 address too.
    private var ipv6Only: Bool { [.addDeviceComputerIPv6, .proxyIPv6, .nameNotAnswered].contains(scenario) }

    /// When this build stops opening: two days on for `expiring`, never for the others.
    var expires: Date? { scenario == .expiring ? DemoScenario.now.addingTimeInterval(2 * 86_400) : nil }

    var localNetworkDenied: Bool { scenario == .localNetworkDenied }

    var showsLocalNetworkIntro: Bool { scenario == .localNetworkIntro }

    /// The real session, run the way the app would have by the time the screen shows: the hotspot comes
    /// up or doesn't, the iPad's tunnel is up or not, and two samples a second apart give the speed.
    @MainActor
    func makeSession(log: @escaping @MainActor (String) -> Void = { _ in }) -> HotspotSession {
        let server = FakeServer()
        let clock = DemoClock()
        // As long as a carrier's address gets, in the documentation range, so the screen is tried at full length.
        let ipv6 = "2001:db8:9e74:4eaa:459:5cd0:7ec7:f792"
        let address = running ? (ipv6Only ? ipv6 : Hotspot.host) : nil
        let session = HotspotSession(devices: WireGuardDevices(secrets: secrets()), server: server, keepAlive: FakeSound(),
                                     page: FakePage(), sceneActive: true, hotspotAddress: { address },
                                     dns: { DNSChoice.upstream(in: UserDefaults(suiteName: Self.settingsSuite)!) },
                                     blockLocal: { !LocalNetworks.allowed(in: UserDefaults(suiteName: Self.settingsSuite)!) },
                                     now: { clock.now }, resetDay: { ResetDay.saved(in: UserDefaults(suiteName: Self.settingsSuite)!) },
                                     // A demo never has a VPN, so the switch in Settings keeps its devices out.
                                     onlyThroughVPN: { UserDefaults(suiteName: Self.settingsSuite)!.bool(forKey: HotspotSession.onlyThroughVPNKey) },
                                     log: log)
        session.syncWithHotspot()
        server.connected = connected
        // What the iPad used this month, for its screen. The Windows PC used nothing.
        if connected.contains("10.7.0.2") { server.peerTraffic = ["10.7.0.2": TrafficTotals(bytesUp: 120_000_000, bytesDown: 3_000_000_000)] }
        // Where the iPad's handshake comes from, an address on the hotspot, for its screen (#73).
        if connected.contains("10.7.0.2") { server.endpoints = ["10.7.0.2": "172.20.10.2:52345"] }
        // The Windows PC last connected two hours ago, so its screen says when.
        server.handshakes = ["10.7.0.3": clock.now.addingTimeInterval(-2 * 3600)]
        if connected.contains("10.7.0.2") { server.handshakes["10.7.0.2"] = clock.now.addingTimeInterval(-30) }
        if scenario == .staleConfig { server.stale = StaleConfig(kind: .device, at: clock.now) }
        // The Diagnostics screen's counters: the iPad's traffic, and one connection the iPhone couldn't make.
        if connected.contains("10.7.0.2") {
            server.diagnostics = ServerDiagnostics(udpIn: 1_250, udpFrom: "172.20.10.2:52345",
                                                   packetsIn: 1_180, tcpTried: 42, tcpFailed: 1,
                                                   lastError: "TCP to 203.0.113.9:443: connect: connection refused")
        }
        // The proxy's devices: two pages open and 85 MB this month on its screen, or one page loading.
        if [.proxy, .proxyIPv6].contains(scenario) {
            server.proxyOpen = 2
            server.proxyTraffic = TrafficTotals(bytesUp: 5_000_000, bytesDown: 80_000_000)
        }
        if scenario == .addDeviceProxyWorking { server.proxyOpen = 1 }
        if scenario == .proxyIPv6 { server.proxyAddresses = ["\(Hotspot.host):8118", "[\(ipv6)]:8118"] }
        // A full graph in screenshots, ending at the same clock and current speeds as before.
        clock.now = clock.now.addingTimeInterval(-29)
        session.sampleTraffic()
        for second in 1...30 {
            clock.now = clock.now.addingTimeInterval(1)
            let downFactor = second == 30 ? 1 : 0.25 + 0.75 * pow(sin(Double(second) * .pi / 10), 2)
            let upFactor = second == 30 ? 1 : 0.2 + 0.8 * pow(cos(Double(second) * .pi / 8), 2)
            server.totals += TrafficTotals(bytesUp: UInt64(upSpeed * upFactor / 8), bytesDown: UInt64(downSpeed * downFactor / 8))
            session.sampleTraffic()
        }
        if scenario == .addDeviceProxyWorking { loadAPage(through: server, session) }
        if scenario == .addDeviceConnects { connectTheNextDevice(through: server, session) }
        if scenario == .notUsingTether {
            session.neighborsAnswered([HotspotKnock(address: "172.20.10.2", answer: .open),
                                       HotspotKnock(address: "172.20.10.3", answer: .refused)])
        }
        return session
    }

    /// The `addDeviceProxyWorking` demo's page: each second a device the proxy hadn't served gets
    /// bytes back, as the sampler would read them, so one is new to Add a device whenever it opened.
    /// A demo has no sampler, so this reads them. It stops once the session is gone, as in a unit test.
    @MainActor
    private func loadAPage(through server: FakeServer, _ session: HotspotSession) {
        Task { [weak session] in
            for i in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard let session else { return }
                server.proxyServed.insert("172.20.10.\(10 + i)")
                server.proxyTraffic += TrafficTotals(bytesUp: 1_000, bytesDown: 30_000)
                session.sampleTraffic()
            }
        }
    }
}

/// The `addDeviceConnects` demo's device: once Add a device has let its code in for `connectsAfter` whole
/// seconds, a device that scanned the code connects from an address on the hotspot, as its first
/// handshake would show, and the sampler a demo doesn't have reads it. The wait counts while the
/// code is let in, which goes on for 10 minutes after the sheet closes (see `AddWindow`), so closing
/// the sheet doesn't start it over, as a real device could still use the code then. It stops once a
/// device connects or the session is gone.
extension DemoState {
    @MainActor
    fileprivate func connectTheNextDevice(through server: FakeServer, _ session: HotspotSession) {
        Task { [weak session] in
            var openFor = 0
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard let session else { return }
                guard session.addWindowOpen, let ready = session.wireGuardReady else {
                    openFor = 0
                    continue
                }
                openFor += 1
                guard openFor >= connectsAfter else { continue }
                server.connected.insert(ready.address)
                server.endpoints[ready.address] = "172.20.10.4:51234"
                session.sampleTraffic()
                return
            }
        }
    }
}

/// The demo session's clock, which `makeSession` moves through the graph's recent history.
private final class DemoClock {
    var now = DemoScenario.now
}
#endif
