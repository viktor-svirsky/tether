import Foundation

/// The WireGuard server as `HotspotSession` uses it. `WireGuardServer` is the real one, the tests have a fake.
@MainActor
protocol WireGuardServing: AnyObject {
    var running: Bool { get }
    /// From the last `snapshot()`.
    var connectedAddresses: Set<String> { get }
    func start(host: String, setup: WireGuardSetup, port: UInt16) throws
    func stop()
    func setPeers(_ setup: WireGuardSetup) throws
    func snapshot() -> TrafficTotals
    func freeMemory()
}

extension WireGuardServer: WireGuardServing {}

/// The silent sound that keeps Tether running, see `KeepAlive` and `KeepAlivePolicy`.
@MainActor
protocol KeepAliveSound: AnyObject {
    /// Started and not stopped.
    var playing: Bool { get }
    /// Making its sound right now.
    var sounding: Bool { get }
    func start()
    func stop()
}

/// What Tether does with the hotspot, its saved devices and the WireGuard server: start the server
/// when the hotspot appears, stop it when it goes, try again after a failure, say why it isn't
/// running, keep the sound playing for a while, and count the speeds. `Model` runs it on a timer
/// and shows it. Foundation only, with everything it talks to passed in, so `swift test` covers it.
@MainActor
final class HotspotSession {
    /// Called before anything below that the screen shows changes, as `@Published` does.
    var willChange: () -> Void = {}

    var running = false { willSet { willChange() } }
    /// Download and upload speed now, in bits per second. Zero until there are two samples to compare.
    var downSpeed = 0.0 { willSet { willChange() } }
    var upSpeed = 0.0 { willSet { willChange() } }
    /// The devices that have connected, in the order they first did.
    private(set) var wireGuardPeers: [WireGuardSetup.Peer] = [] { willSet { willChange() } }
    /// Behind the QR code on the main screen, see `WireGuardSetup.ready`. Only ever a saved one.
    private(set) var wireGuardReady: WireGuardSetup.Ready? { willSet { willChange() } }
    /// Why there's no QR code while the devices that have one still connect: making the next one couldn't be saved.
    private(set) var wireGuardReadyProblem: String? { willSet { willChange() } }
    /// A rename or removal that couldn't be saved, shown on that device's screen until a change saves.
    private(set) var wireGuardDeviceProblem: DeviceProblem? { willSet { willChange() } }
    /// Why WireGuard isn't running, shown on the main screen: the saved setup's problem from launch on,
    /// hotspot or not, or why the server didn't start on the hotspot.
    private(set) var wireGuardProblem: String? { willSet { willChange() } }
    /// The tunnel addresses of the WireGuard devices that are connected. Read with every sample
    /// while the app is on screen.
    var wireGuardConnected: Set<String> = [] { willSet { willChange() } }
    /// The hotspot is on and WireGuard runs. `running` alone is only the hotspot.
    var sharing: Bool { running && wireGuardProblem == nil }
    /// Only the on-screen sampler publishes connections and speeds, so it runs only while the app is on screen.
    /// False in a launch from a Shortcuts action, which happens in the background.
    var sceneActive: Bool

    private let devices: WireGuardDevices
    private let server: WireGuardServing
    private let keepAlive: KeepAliveSound
    private let hotspotAddress: () -> String?
    private let now: () -> Date
    private let log: @MainActor (String) -> Void

    /// When the hotspot went away, or Tether was last on screen since. Nil while the hotspot is on.
    /// A launch starts long past, so only opening Tether or Start Tether (`wake`) gives it the 10
    /// minutes. "Is Tether Sharing?" launches Tether in the background too, and only reports.
    private var waitingSince: Date? = .distantPast
    private var lastSample: (up: UInt64, down: UInt64, at: Date)?
    private var boundHost: String?
    /// Why the saved setup can't be used, see `checkSetup`.
    private var setupProblem: String?
    /// Why the server didn't start on the hotspot. It goes with the hotspot.
    private var startProblem: String?

    init(devices: WireGuardDevices, server: WireGuardServing, keepAlive: KeepAliveSound, sceneActive: Bool,
         hotspotAddress: @escaping () -> String?, now: @escaping () -> Date = Date.init,
         log: @escaping @MainActor (String) -> Void = { _ in }) {
        self.devices = devices
        self.server = server
        self.keepAlive = keepAlive
        self.sceneActive = sceneActive
        self.hotspotAddress = hotspotAddress
        self.now = now
        self.log = log
        publishSetup()
        showSetupProblem() // from launch, before any device joins the hotspot
    }

    /// One round of the watcher in `Model`.
    func watch() {
        syncWithHotspot()
        // On screen the sampler does this every second.
        if !sceneActive { claimReadyInBackground() }
    }

    /// The hotspot interface exists only while Personal Hotspot is on. This starts WireGuard when
    /// it appears and stops it when it goes away or changes, so it never listens anywhere else.
    func syncWithHotspot() {
        checkSetup()
        let hotspot = hotspotAddress()
        if running, hotspot != boundHost {
            log("hotspot address gone or changed, stopping")
            server.stop()
            running = false
            startProblem = nil // the next hotspot gets a new try
            showProblem()
        }
        // A WireGuard start that failed (keys locked after a restart, say) is tried again here.
        if running, !server.running, let boundHost { startWireGuard(on: boundHost) }
        keepAliveWhileSharing(hotspot: hotspot != nil)
        guard !running, let hotspot else { return }
        log("binding to \(hotspot)")
        boundHost = hotspot
        startWireGuard(on: hotspot)
        // A restart (hotspot address change) never passes through running == false in the
        // sampler, so start the session's counters afresh here.
        lastSample = nil
        downSpeed = 0
        upSpeed = 0
        running = true
    }

    /// Plays the silent sound while the hotspot is on, and for a while after it goes, see
    /// `KeepAlivePolicy`. Once it stops, iOS suspends Tether, and it starts again when opened.
    private func keepAliveWhileSharing(hotspot: Bool) {
        let now = self.now()
        // On screen the wait keeps starting again, so the sound never stops there, and the 10 minutes
        // run from leaving the screen, to turn on Personal Hotspot in Settings, say.
        if hotspot { waitingSince = nil } else if sceneActive || waitingSince == nil { waitingSince = now }
        let plays = KeepAlivePolicy.plays(waitingSince: waitingSince, now: now)
        if plays { keepAlive.start() } else if keepAlive.playing {
            log("no hotspot for 10 minutes, letting iOS suspend Tether until it's opened")
            keepAlive.stop()
        }
    }

    /// Reads the saved setup until it can, and says why it can't. On every watcher round, hotspot
    /// or not: without the setup there's no QR code to add a device with either.
    private func checkSetup() {
        if !devices.loaded, !devices.needsReset {
            devices.load() // the Keychain can be locked until the first unlock after a restart
            if devices.loaded { publishSetup() } // not every round while it's locked, which redraws the screen
        } else if devices.prepareReady() { // a QR code that couldn't be saved before
            wireGuardPeersChanged()
        }
        showSetupProblem()
    }

    private func showSetupProblem() {
        setupProblem = devices.loadError.map(Self.problem(with:))
        showProblem(because: devices.loadError)
    }

    /// If WireGuard can't start, the problem shows on the main screen. The watcher tries again on
    /// its next round.
    private func startWireGuard(on hotspot: String) {
        guard devices.loaded else { return } // the setup's problem shows already
        do {
            try server.start(host: hotspot, setup: devices.setup, port: WireGuardSetup.port)
            startProblem = nil
            showProblem()
            log("WireGuard on \(hotspot):\(WireGuardSetup.port), \(wireGuardPeers.count) devices")
        } catch {
            startProblem = "It couldn't start: \(error)"
            showProblem(because: error)
        }
    }

    /// Why the saved setup can't be used, for `wireGuardProblem`.
    private static func problem(with error: Error) -> String {
        switch error {
        case is WireGuardDevices.Unreadable: "Its saved keys can't be read. Start over with new keys to use it."
        case let unsaved as WireGuardDevices.Unsaved: "Its new keys can't be saved: \(unsaved.reason)."
        default: "Its keys can't be read yet. Unlock this iPhone once."
        }
    }

    /// The setup's problem comes first: until it's solved, the server can't start anyway. A problem
    /// is logged once, not on every try.
    private func showProblem(because error: Error? = nil) {
        let problem = setupProblem ?? startProblem
        guard problem != wireGuardProblem else { return }
        wireGuardProblem = problem
        if problem != nil, let error { log("WireGuard not started: \(error)") }
    }

    /// The same as opening Tether, for Start Tether in Shortcuts: the 10 minutes' wait for the hotspot
    /// starts again, and sharing starts now if the hotspot is on. True when the silent sound plays,
    /// so iOS keeps Tether running after the action ends.
    @discardableResult
    func wake() -> Bool {
        if waitingSince != nil { waitingSince = now() }
        syncWithHotspot()
        return keepAlive.sounding
    }

    /// Opening Tether starts the wait again, so there's time to turn on Personal Hotspot in Settings.
    func cameOnScreen() {
        sceneActive = true
        wake()
    }

    func leftScreen() {
        sceneActive = false
        lastSample = nil // or the first speed back on screen averages the whole time away
    }

    /// For the Shortcuts actions. Off screen the sampler doesn't run, so the connected devices are read now.
    func shortcutState() -> ShortcutReply.State {
        var connected = wireGuardConnected
        if running, server.running {
            _ = server.snapshot() // refreshes connectedAddresses
            connected = server.connectedAddresses
        }
        return ShortcutReply.State(running: running, connected: connected.count, problem: wireGuardProblem)
    }

    var wireGuardNeedsReset: Bool { devices.needsReset }

    /// Gives up on saved keys this version can't read: a new server key and no devices.
    func resetWireGuard() {
        devices.reset()
        publishSetup()
        showSetupProblem()
        guard devices.loaded else { return }
        log("WireGuard keys started over")
        if running, let boundHost { startWireGuard(on: boundHost) }
    }

    /// Only the name Tether shows changes. The tunnel already imported keeps its own name.
    func renameWireGuardDevice(_ id: WireGuardSetup.Peer.ID, to name: String) {
        let renamed = devices.rename(id, to: name)
        if !renamed { log("WireGuard: the new name couldn't be saved") }
        showDeviceProblem(renamed ? nil : DeviceProblem(device: id, text: "The new name couldn't be saved."))
        publishSetup()
    }

    /// False when the removal couldn't be saved, and the device stays.
    @discardableResult
    func removeWireGuardDevice(_ id: WireGuardSetup.Peer.ID) -> Bool {
        let removed = devices.remove(id)
        if !removed { log("WireGuard: the removal couldn't be saved, the device stays") }
        showDeviceProblem(removed ? nil : DeviceProblem(device: id, text: "The device couldn't be removed."))
        wireGuardPeersChanged()
        return removed
    }

    /// It names its device, so another device's screen doesn't show it.
    struct DeviceProblem: Equatable {
        let device: WireGuardSetup.Peer.ID
        let text: String
    }

    /// The last rename or removal decides: one that saves clears it, one that doesn't names itself.
    private func showDeviceProblem(_ problem: DeviceProblem?) {
        if problem != wireGuardDeviceProblem { wireGuardDeviceProblem = problem }
    }

    func wireGuardConfig(for ready: WireGuardSetup.Ready) -> String {
        devices.setup.clientConfig(for: ready)
    }

    /// On a memory warning.
    func freeMemory() {
        server.freeMemory()
    }

    private func publishSetup() {
        wireGuardPeers = devices.setup.peers
        wireGuardReady = devices.setup.ready
        let readyProblem = devices.readyError.map { "The code for the next device can't be saved: \($0)." }
        if readyProblem != wireGuardReadyProblem {
            wireGuardReadyProblem = readyProblem
            if let readyProblem { log("WireGuard: \(readyProblem)") }
        }
    }

    /// The server lets in exactly the saved devices. If it refuses the new list, it starts again with
    /// the saved setup, and a start that fails leaves it stopped: a removed device is never let in, the
    /// problem shows, and the watcher tries again.
    private func wireGuardPeersChanged() {
        devices.prepareReady() // a removal on a full subnet makes room for the QR code
        publishSetup()
        do {
            try server.setPeers(devices.setup)
        } catch {
            log("WireGuard devices: \(error), restarting")
            if running, let boundHost { startWireGuard(on: boundHost) }
        }
    }

    /// Reads the server's counters, every second on screen: which devices are connected, and the
    /// speeds from how far the counters moved since the last sample. A device that connected with
    /// the QR code is listed here, and the code changes for the next one.
    /// `snapshot()` reads a small JSON from Go, which is fine to do on the main actor.
    func sampleTraffic() {
        let now = self.now()
        guard running else {
            // A new session starts with zero speeds and nobody connected.
            lastSample = nil
            if downSpeed != 0 { downSpeed = 0 }
            if upSpeed != 0 { upSpeed = 0 }
            if !wireGuardConnected.isEmpty { wireGuardConnected = [] }
            return
        }
        let snap = server.snapshot()
        defer { lastSample = (snap.bytesUp, snap.bytesDown, now) }
        let connected = server.connectedAddresses // from the snapshot above
        if connected != wireGuardConnected { wireGuardConnected = connected }
        claimReady(connected: connected)
        guard let last = lastSample else { return } // the first sample has nothing to compare with
        let seconds = now.timeIntervalSince(last.at)
        guard seconds > 0 else { return }
        upSpeed = Self.bps(snap.bytesUp, last.up, seconds)
        downSpeed = Self.bps(snap.bytesDown, last.down, seconds)
    }

    /// A device that connected with the QR code is listed, and the code changes for the next one.
    /// Not saved means not claimed: the next check tries again.
    private func claimReady(connected: Set<String>) {
        guard let ready = wireGuardReady, connected.contains(ready.address),
              devices.claimReady(address: ready.address) else { return }
        log("WireGuard: a new device connected with the QR code")
        wireGuardPeersChanged()
    }

    /// The watcher's check in the background, where the sampler doesn't run, so a device that
    /// connects then is listed too and the next one gets a new code.
    private func claimReadyInBackground() {
        guard running else { return }
        _ = server.snapshot() // refreshes connectedAddresses
        claimReady(connected: server.connectedAddresses)
    }

    /// The server's counters never go backwards. The guard is only a safety net.
    private static func bps(_ new: UInt64, _ old: UInt64, _ seconds: TimeInterval) -> Double {
        new >= old ? Double(new - old) * 8 / seconds : 0
    }
}

enum Interfaces {
    static func hotspotAddress() -> String? {
        hotspotAddress(in: ipv4())
    }

    /// iOS Personal Hotspot always gives the phone 172.20.10.1 on a bridge interface.
    /// Matching the subnet, not only the name, keeps other bridges out.
    /// `interfaces` are lines like "bridge100: 172.20.10.1", from `ipv4()`.
    static func hotspotAddress(in interfaces: [String]) -> String? {
        interfaces.lazy
            .filter { $0.hasPrefix("bridge") }
            .compactMap { $0.components(separatedBy: ": ").last }
            .first { $0.hasPrefix("172.20.10.") }
    }

    static func ipv4() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let name = String(cString: p.pointee.ifa_name)
            let addr = String(cString: host)
            if name != "lo0" { out.append("\(name): \(addr)") }
        }
        return out
    }
}
