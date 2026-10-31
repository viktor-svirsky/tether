// File map (all in Sources/):
//   TetherApp.swift     the @main App only
//   Model.swift         Model: what the screen and the Shortcuts actions see, and the timers
//   HotspotSession.swift  the hotspot lifecycle Model runs, and Interfaces, Foundation only
//   Traffic.swift       the server's byte counters, Foundation only
//   Format.swift        bytes and speeds as text
//   MainView.swift      MainView (the main screen), StatusCard, and the speeds
//   DevicesView.swift   the QR code for the next device, and a device's own screen
//   ConfigPage.swift    the page on the hotspot that hands out the next device's config, Foundation only
//   ConfigPageServer.swift  serves that page on the hotspot address
//   AppExpiry.swift     when a sideloaded build stops opening, and the warning before it
//   DemoMode.swift      fake app state for the UI tests, Debug builds only
//   Shortcuts.swift     the Shortcuts actions; ShortcutReply.swift has what they say, Foundation only
//   WireGuardSetup.swift  the hotspot address, WireGuard keys, devices and client configs, Foundation only
//   WireGuardServer.swift  runs the WireGuard server (WireGuard/, Go)
//   KeepAlive.swift, KeepAlivePolicy.swift  the silent sound that keeps Tether running

import OSLog
import SwiftUI
import UIKit

extension KeepAlive: KeepAliveSound {}

/// What SwiftUI observes. The decisions are in `HotspotSession`. This runs it on the watcher and the
/// sampler, tells it when the app comes on screen or leaves, and shows what it has.
@MainActor
final class Model: ObservableObject {
    /// The screen and the Shortcuts actions share it. An action can launch Tether in the
    /// background, with no screen, and this is all that runs then.
    static let shared = Model()

    // These forward to the session, which announces each change through `objectWillChange`.
    var running: Bool {
        get { session.running }
        set { session.running = newValue }
    }
    var downSpeed: Double {
        get { session.downSpeed }
        set { session.downSpeed = newValue }
    }
    var upSpeed: Double {
        get { session.upSpeed }
        set { session.upSpeed = newValue }
    }
    var wireGuardConnected: Set<String> {
        get { session.wireGuardConnected }
        set { session.wireGuardConnected = newValue }
    }
    var configPageURL: String? {
        get { session.configPageURL }
        set { session.configPageURL = newValue }
    }
    var wireGuardPeers: [WireGuardSetup.Peer] { session.wireGuardPeers }
    var wireGuardReady: WireGuardSetup.Ready? { session.wireGuardReady }
    var wireGuardReadyProblem: String? { session.wireGuardReadyProblem }
    var wireGuardDeviceProblem: HotspotSession.DeviceProblem? { session.wireGuardDeviceProblem }
    var wireGuardProblem: String? { session.wireGuardProblem }
    var sharing: Bool { session.sharing }
    var wireGuardNeedsReset: Bool { session.wireGuardNeedsReset }

    /// When this build stops opening, from its provisioning profile. Nil without one.
    var expires: Date? = AppExpiry.installed { didSet { refreshExpiryWarning() } }
    /// "Tether stops opening in 2 days ...", in the last three days before `expires`. Refreshed by
    /// the 1 s sampler, so it appears on time even on a screen where nothing else changes.
    @Published private(set) var expiryWarning: String?

    private let session: HotspotSession
    private static let logger = Logger(subsystem: "com.vsvirskyi.phoneshare", category: "tether")

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
        session = HotspotSession(devices: WireGuardDevices(secrets: secrets), server: WireGuardServer(),
                                 keepAlive: KeepAlive(log: Self.append), page: ConfigPageServer(),
                                 sceneActive: UIApplication.shared.applicationState != .background,
                                 hotspotAddress: Interfaces.hotspotAddress, log: Self.append)
        session.willChange = { [weak self] in self?.objectWillChange.send() }
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
                self?.session.watch()
                // The slack lets iOS wake the app for this together with other timers.
                let interval = KeepAlivePolicy.watchInterval(sceneActive: self?.session.sceneActive ?? false)
                try? await Task.sleep(for: interval.every, tolerance: interval.tolerance)
            }
        }
        if session.sceneActive { startSampler() }
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
    private var sampler: Task<Void, Never>?

    /// See `HotspotSession.syncWithHotspot`.
    func syncWithHotspot() {
        session.syncWithHotspot()
    }

    /// See `HotspotSession.wake`.
    @discardableResult
    func wake() -> Bool {
        #if DEBUG
        if demo != nil { return true }
        #endif
        return session.wake()
    }

    func shortcutState() -> ShortcutReply.State {
        session.shortcutState()
    }

    func resetWireGuard() {
        session.resetWireGuard()
    }

    func renameWireGuardDevice(_ id: WireGuardSetup.Peer.ID, to name: String) {
        session.renameWireGuardDevice(id, to: name)
    }

    /// See `HotspotSession.removeWireGuardDevice`.
    @discardableResult
    func removeWireGuardDevice(_ id: WireGuardSetup.Peer.ID) -> Bool {
        session.removeWireGuardDevice(id)
    }

    func wireGuardConfig(for ready: WireGuardSetup.Ready) -> String {
        session.wireGuardConfig(for: ready)
    }

    /// The expiry warning and the session's sample, see `HotspotSession.sampleTraffic`.
    func sampleTraffic() {
        refreshExpiryWarning()
        session.sampleTraffic()
    }

    private func observeScene() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor (Model) -> Void) {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
        }
        observe(UIApplication.didBecomeActiveNotification) { model in
            model.session.cameOnScreen()
            model.startSampler() // samples at once, then every second again
        }
        observe(UIApplication.willResignActiveNotification) { model in
            model.session.leftScreen()
            model.sampler?.cancel()
        }
        observe(UIApplication.didReceiveMemoryWarningNotification) { $0.session.freeMemory() }
    }

    /// Internal log, read in Console.app. Nothing in the app shows it.
    private static func append(_ s: String) {
        logger.info("\(s, privacy: .public)")
    }
}
