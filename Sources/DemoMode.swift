#if DEBUG
import Foundation

// Fixed, fake app state for the UI tests (UITests/). On the simulator there is no Personal Hotspot
// and nothing to share, so a test launches the app with `-TetherDemo <scenario>` and gets one of
// these states instead.
//
// A demo runs the real HotspotSession once, against the fakes in Fakes.swift, so a screen shows only
// what the session itself publishes. Nothing runs after that: no WireGuard server, keep-alive audio,
// hotspot watcher, 1 s sampler or scene observers. Model.swift has the few hooks, all inside
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
    /// Like `sharing`, but the Windows PC's config points at an IPv6 address this iPhone had before,
    /// the way a new cellular session moves it on an IPv6-only carrier, so it needs adding again.
    case oldAddress
    /// Like `sharing`, but the iPad is paused: its tunnel is up, and nothing gets through.
    case paused

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

    static func fromLaunchArguments() -> DemoState? {
        DemoScenario.current.map(DemoState.init)
    }

    init(_ scenario: DemoScenario) {
        self.scenario = scenario
        guard ![.waiting, .wireGuardLockedWaiting, .localNetworkIntro].contains(scenario) else {
            running = false
            return
        }
        if [.noDevices, .wireGuardUnsaved, .addDeviceScreen, .addDeviceComputer, .addDeviceComputerIPv6].contains(scenario) { return }
        downSpeed = 3_200_000
        upSpeed = 400_000
    }

    /// Where the WireGuard setup is "kept". Never the Keychain.
    func secrets() -> SecretStore {
        let secrets = InMemorySecrets()
        switch scenario {
        case .sharing, .wireGuardLocked, .expiring, .qrCodeUnsaved, .notificationsOff, .notifying, .notificationsScreen, .addDeviceWaiting, .addDeviceDone, .localNetworkDenied, .oldAddress, .staleConfig, .paused:
            var setup = WireGuardSetup.new()
            let ipad = setup.addPeer(name: "iPad")
            if scenario == .paused, let ipad { setup.pausePeer(ipad.id, .byYou) }
            // A 10 GB limit, so its screen shows the meter. The Windows PC has none.
            if let ipad { setup.limitPeer(ipad.id, 10_000_000_000) }
            // A documentation address. The demo listens on 172.20.10.1, so it's an old one.
            _ = setup.addPeer(name: "Windows PC", host: scenario == .oldAddress ? "2001:db8::1" : nil)
            secrets.data = try? JSONEncoder().encode(setup) // no ready device yet: loading makes and saves one
        case .wireGuardNeedsReset:
            secrets.data = Data("not a WireGuard setup".utf8) // undecodable, like a setup from a newer version
        default: break
        }
        switch scenario {
        case .wireGuardLocked, .wireGuardLockedWaiting: return LockedSecrets()
        case .wireGuardUnsaved, .qrCodeUnsaved: return UnsavableSecrets(secrets.data)
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
        [.sharing, .expiring, .qrCodeUnsaved, .notificationsOff, .notifying, .notificationsScreen, .addDeviceWaiting, .addDeviceDone, .oldAddress, .staleConfig, .paused].contains(scenario) ? ["10.7.0.2"] : []
    }

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
        let address = running ? (scenario == .addDeviceComputerIPv6 ? "2001:db8::1" : Hotspot.host) : nil
        let session = HotspotSession(devices: WireGuardDevices(secrets: secrets()), server: server, keepAlive: FakeSound(),
                                     page: FakePage(), sceneActive: true, hotspotAddress: { address },
                                     dns: { DNSChoice.servers(in: UserDefaults(suiteName: Self.settingsSuite)!) },
                                     now: { clock.now }, log: log)
        session.syncWithHotspot()
        server.connected = connected
        // What the iPad used this month, for its screen. The Windows PC used nothing.
        if connected.contains("10.7.0.2") { server.peerTraffic = ["10.7.0.2": TrafficTotals(bytesUp: 120_000_000, bytesDown: 3_000_000_000)] }
        if scenario == .staleConfig { server.stale = StaleConfig(kind: .device, at: clock.now) }
        session.sampleTraffic()
        clock.now = clock.now.addingTimeInterval(1)
        server.totals = TrafficTotals(bytesUp: UInt64(upSpeed / 8), bytesDown: UInt64(downSpeed / 8))
        session.sampleTraffic()
        return session
    }
}

/// The demo session's clock, which `makeSession` moves on one second between its two samples.
private final class DemoClock {
    var now = DemoScenario.now
}
#endif
