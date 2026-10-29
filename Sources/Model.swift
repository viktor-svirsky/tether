// File map (all in Sources/):
//   TetherApp.swift     the @main App only
//   Model.swift         Model, Interfaces
//   Traffic.swift       the server's byte counters, Foundation only
//   Format.swift        bytes and speeds as text
//   MainView.swift      MainView (the main screen), StatusCard, and the speeds
//   DevicesView.swift   the QR code for the next device, and a device's own screen
//   AppExpiry.swift     when a sideloaded build stops opening, and the warning before it
//   DemoMode.swift      fake app state for the UI tests, Debug builds only
//   Shortcuts.swift     the Shortcuts actions; ShortcutReply.swift has what they say, Foundation only
//   WireGuardSetup.swift  the hotspot address, WireGuard keys, devices and client configs, Foundation only
//   WireGuardServer.swift  runs the WireGuard server (WireGuard/, Go)
//   KeepAlive.swift, KeepAlivePolicy.swift  the silent sound that keeps Tether running

import OSLog
import SwiftUI
import UIKit

@MainActor
final class Model: ObservableObject {
    /// The screen and the Shortcuts actions share it. An action can launch Tether in the
    /// background, with no screen, and this is all that runs then.
    static let shared = Model()

    @Published var running = false
    /// Download and upload speed now, in bits per second. Zero until there are two samples to compare.
    @Published var downSpeed = 0.0
    @Published var upSpeed = 0.0
    /// When this build stops opening, from its provisioning profile. Nil without one.
    var expires: Date? = AppExpiry.installed { didSet { refreshExpiryWarning() } }
    /// "Tether stops opening in 2 days ...", in the last three days before `expires`. Refreshed by
    /// the 1 s sampler, so it appears on time even on a screen where nothing else changes.
    @Published private(set) var expiryWarning: String?
    /// The devices that have connected, in the order they first did. Their keys are in the Keychain.
    @Published private(set) var wireGuardPeers: [WireGuardSetup.Peer] = []
    /// Behind the QR code on the main screen, see `WireGuardSetup.ready`. Only ever a saved one.
    @Published private(set) var wireGuardReady: WireGuardSetup.Peer?
    /// Why there's no QR code while the devices that have one still connect: making the next one couldn't be saved.
    @Published private(set) var wireGuardReadyProblem: String?
    /// Why WireGuard isn't running, shown on the main screen: the saved setup's problem from launch on,
    /// hotspot or not, or why the server didn't start on the hotspot.
    @Published private(set) var wireGuardProblem: String?
    /// The hotspot is on and WireGuard runs. `running` alone is only the hotspot.
    var sharing: Bool { running && wireGuardProblem == nil }
    /// The tunnel addresses of the WireGuard devices that are connected. Read with every sample
    /// while the app is on screen.
    @Published var wireGuardConnected: Set<String> = []

    private let wireGuard = WireGuardServer()
    private let wireGuardDevices: WireGuardDevices
    private let keepAlive = KeepAlive()
    private static let logger = Logger(subsystem: "com.vsvirskyi.phoneshare", category: "tether")
    /// Only the on-screen sampler publishes connections and speeds, so it runs only while the app is on screen.
    /// False in a launch from a Shortcuts action, which happens in the background.
    private var sceneActive = UIApplication.shared.applicationState != .background

    #if DEBUG
    /// Set in a demo launch (`-TetherDemo`, see DemoMode.swift). Nothing real runs then.
    private var demo: DemoState?
    #endif

    init() {
        #if DEBUG
        let demo = DemoState.fromLaunchArguments()
        let secrets: SecretStore = demo?.secrets() ?? KeychainSecrets()
        #else
        let secrets: SecretStore = KeychainSecrets()
        #endif
        self.wireGuardDevices = WireGuardDevices(secrets: secrets)
        publishSetup()
        showSetupProblem() // from launch, before any device joins the hotspot
        #if DEBUG
        if let demo {
            self.demo = demo
            demo.apply(to: self)
            return // no server, keep-alive audio, watcher, sampler or scene observers
        }
        #endif
        refreshExpiryWarning()
        observeScene()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                self?.syncWithHotspot()
                // On screen the sampler does this every second.
                if self?.sceneActive == false { self?.claimReadyInBackground() }
                // The slack lets iOS wake the app for this together with other timers.
                let interval = KeepAlivePolicy.watchInterval(sceneActive: self?.sceneActive ?? false)
                try? await Task.sleep(for: interval.every, tolerance: interval.tolerance)
            }
        }
        if sceneActive { startSampler() }
    }

    /// Every second while the app is on screen. In the background nothing on screen needs it, so it stops.
    private func startSampler() {
        sampler?.cancel()
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleTraffic()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Publishes only when the text changes, so the sampler doesn't redraw the screen every second.
    func refreshExpiryWarning(now: Date = Date()) {
        var now = now
        #if DEBUG
        if demo != nil { now = DemoScenario.now }
        #endif
        let warning = expires.flatMap { AppExpiry.warning(expires: $0, now: now) }
        if warning != expiryWarning { expiryWarning = warning }
    }

    private var watcher: Task<Void, Never>?
    /// When the hotspot went away, or Tether was last on screen since. Nil while the hotspot is on.
    /// A launch starts long past, so only opening Tether or Start Tether (`wake`) gives it the 10
    /// minutes. "Is Tether Sharing?" launches Tether in the background too, and only reports.
    private var waitingSince: Date? = .distantPast
    private var sampler: Task<Void, Never>?
    private var lastSample: (up: UInt64, down: UInt64, at: Date)?
    private var boundHost: String?
    /// Why the saved setup can't be used, see `checkSetup`.
    private var setupProblem: String?
    /// Why the server didn't start on the hotspot. It goes with the hotspot.
    private var startProblem: String?

    /// The hotspot interface exists only while Personal Hotspot is on. This starts WireGuard when
    /// it appears and stops it when it goes away or changes, so it never listens anywhere else.
    func syncWithHotspot() {
        checkSetup()
        let hotspot = Interfaces.hotspotAddress()
        if running, hotspot != boundHost {
            append("hotspot address gone or changed, stopping")
            wireGuard.stop()
            running = false
            startProblem = nil // the next hotspot gets a new try
            showProblem()
        }
        // A WireGuard start that failed (keys locked after a restart, say) is tried again here.
        if running, !wireGuard.running, let boundHost { startWireGuard(on: boundHost) }
        keepAliveWhileSharing(hotspot: hotspot != nil)
        guard !running, let hotspot else { return }
        append("binding to \(hotspot)")
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
    private func keepAliveWhileSharing(hotspot: Bool, now: Date = Date()) {
        // On screen the wait keeps starting again, so the sound never stops there, and the 10 minutes
        // run from leaving the screen, to turn on Personal Hotspot in Settings, say.
        if hotspot { waitingSince = nil } else if sceneActive || waitingSince == nil { waitingSince = now }
        let plays = KeepAlivePolicy.plays(waitingSince: waitingSince, now: now)
        if plays { keepAlive.start() } else if keepAlive.playing {
            append("no hotspot for 10 minutes, letting iOS suspend Tether until it's opened")
            keepAlive.stop()
        }
    }

    /// Reads the saved setup until it can, and says why it can't. On every watcher round, hotspot
    /// or not: without the setup there's no QR code to add a device with either.
    private func checkSetup() {
        if !wireGuardDevices.loaded, !wireGuardDevices.needsReset {
            wireGuardDevices.load() // the Keychain can be locked until the first unlock after a restart
            if wireGuardDevices.loaded { publishSetup() } // not every round while it's locked, which redraws the screen
        } else if wireGuardDevices.prepareReady() { // a QR code that couldn't be saved before
            wireGuardPeersChanged()
        }
        showSetupProblem()
    }

    private func showSetupProblem() {
        setupProblem = wireGuardDevices.loadError.map(Self.problem(with:))
        showProblem(because: wireGuardDevices.loadError)
    }

    /// If WireGuard can't start, the problem shows on the main screen. The watcher tries again on
    /// its next round.
    private func startWireGuard(on hotspot: String) {
        guard wireGuardDevices.loaded else { return } // the setup's problem shows already
        do {
            try wireGuard.start(host: hotspot, setup: wireGuardDevices.setup)
            startProblem = nil
            showProblem()
            append("WireGuard on \(hotspot):\(WireGuardSetup.port), \(wireGuardPeers.count) devices")
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
        if problem != nil, let error { append("WireGuard not started: \(error)") }
    }

    /// The same as opening Tether, for Start Tether in Shortcuts: the 10 minutes' wait for the hotspot
    /// starts again, and sharing starts now if the hotspot is on. True when the silent sound plays,
    /// so iOS keeps Tether running after the action ends.
    @discardableResult
    func wake() -> Bool {
        #if DEBUG
        if demo != nil { return true }
        #endif
        if waitingSince != nil { waitingSince = Date() }
        syncWithHotspot()
        return keepAlive.sounding
    }

    /// For the Shortcuts actions. Off screen the sampler doesn't run, so the connected devices are read now.
    func shortcutState() -> ShortcutReply.State {
        var connected = wireGuardConnected
        if running, wireGuard.running {
            _ = wireGuard.snapshot() // refreshes connectedAddresses
            connected = wireGuard.connectedAddresses
        }
        return ShortcutReply.State(running: running, connected: connected.count, problem: wireGuardProblem)
    }

    var wireGuardNeedsReset: Bool { wireGuardDevices.needsReset }

    /// Gives up on saved keys this version can't read: a new server key and no devices.
    func resetWireGuard() {
        wireGuardDevices.reset()
        publishSetup()
        showSetupProblem()
        guard wireGuardDevices.loaded else { return }
        append("WireGuard keys started over")
        if running, let boundHost { startWireGuard(on: boundHost) }
    }

    /// Only the name Tether shows changes. The tunnel already imported keeps its own name.
    func renameWireGuardDevice(_ id: WireGuardSetup.Peer.ID, to name: String) {
        if !wireGuardDevices.rename(id, to: name) { append("WireGuard: the new name couldn't be saved") }
        publishSetup()
    }

    func removeWireGuardDevice(_ id: WireGuardSetup.Peer.ID) {
        if !wireGuardDevices.remove(id) { append("WireGuard: the removal couldn't be saved, the device stays") }
        wireGuardPeersChanged()
    }

    func wireGuardConfig(for peer: WireGuardSetup.Peer) -> String {
        wireGuardDevices.setup.clientConfig(for: peer)
    }

    private func publishSetup() {
        wireGuardPeers = wireGuardDevices.setup.peers
        wireGuardReady = wireGuardDevices.setup.ready
        let readyProblem = wireGuardDevices.readyError.map { "The code for the next device can't be saved: \($0)." }
        if readyProblem != wireGuardReadyProblem {
            wireGuardReadyProblem = readyProblem
            if let readyProblem { append("WireGuard: \(readyProblem)") }
        }
    }

    /// The server lets in exactly the saved devices. If it refuses the new list, it starts again with
    /// the saved setup, and a start that fails leaves it stopped: a removed device is never let in, the
    /// problem shows, and the watcher tries again.
    private func wireGuardPeersChanged() {
        wireGuardDevices.prepareReady() // a removal on a full subnet makes room for the QR code
        publishSetup()
        do {
            try wireGuard.setPeers(wireGuardDevices.setup)
        } catch {
            append("WireGuard devices: \(error), restarting")
            if running, let boundHost { startWireGuard(on: boundHost) }
        }
    }

    /// Reads the server's counters, see `startSampler`: which devices are connected, and the speeds
    /// from how far the counters moved since the last sample. A device that connected with the QR
    /// code is listed here, and the code changes for the next one.
    /// `snapshot()` reads a small JSON from Go, which is fine to do on the main actor.
    func sampleTraffic() {
        let now = Date()
        refreshExpiryWarning(now: now)
        guard running else {
            // A new session starts with zero speeds and nobody connected.
            lastSample = nil
            if downSpeed != 0 { downSpeed = 0 }
            if upSpeed != 0 { upSpeed = 0 }
            if !wireGuardConnected.isEmpty { wireGuardConnected = [] }
            return
        }
        let snap = wireGuard.snapshot()
        defer { lastSample = (snap.bytesUp, snap.bytesDown, now) }
        let connected = wireGuard.connectedAddresses // from the snapshot above
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
              wireGuardDevices.claimReady(address: ready.address) else { return }
        append("WireGuard: a new device connected with the QR code")
        wireGuardPeersChanged()
    }

    /// The watcher's check in the background, where the sampler doesn't run, so a device that
    /// connects then is listed too and the next one gets a new code.
    private func claimReadyInBackground() {
        guard running else { return }
        _ = wireGuard.snapshot() // refreshes connectedAddresses
        claimReady(connected: wireGuard.connectedAddresses)
    }

    /// The server's counters never go backwards. The guard is only a safety net.
    private static func bps(_ new: UInt64, _ old: UInt64, _ seconds: TimeInterval) -> Double {
        new >= old ? Double(new - old) * 8 / seconds : 0
    }

    private func observeScene() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor (Model) -> Void) {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
        }
        observe(UIApplication.didBecomeActiveNotification) { model in
            model.sceneActive = true
            // Opening Tether starts the wait again, so there's time to turn on Personal Hotspot in Settings.
            model.wake()
            model.startSampler() // samples at once, then every second again
        }
        observe(UIApplication.willResignActiveNotification) { model in
            model.sceneActive = false
            model.sampler?.cancel()
            model.lastSample = nil // or the first speed back on screen averages the whole time away
        }
        observe(UIApplication.didReceiveMemoryWarningNotification) { $0.wireGuard.freeMemory() }
    }

    /// Internal log, read in Console.app. Nothing in the app shows it.
    private func append(_ s: String) {
        Self.logger.info("\(s, privacy: .public)")
    }
}

enum Interfaces {
    /// iOS Personal Hotspot always gives the phone 172.20.10.1 on a bridge interface.
    /// Matching the subnet, not only the name, keeps other bridges out.
    static func hotspotAddress() -> String? {
        ipv4().lazy
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
