// File map (all in Sources/):
//   TetherApp.swift     the @main App only
//   Model.swift         Model: what the screen and the Shortcuts actions see, and the timers
//   HotspotSession.swift  the hotspot lifecycle Model runs, and Interfaces, Foundation only
//   Traffic.swift       the server's byte counters, Foundation only
//   Format.swift        bytes and speeds as text
//   MainView.swift      MainView (the main screen), StatusCard, and the speeds
//   DevicesView.swift   Add a device on the main screen, and a device's own screen
//   AddDeviceSheet.swift the steps to add a device, with the QR code for it
//   AddDeviceProgress.swift  how far adding a device has got, for the sheet, Foundation only
//   ConfigPage.swift    the page on the hotspot that hands out the next device's config, Foundation only
//   ConfigPageServer.swift  serves that page on the hotspot address
//   AppExpiry.swift     when a sideloaded build stops opening, and the warning before it
//   LocalNetwork.swift  whether iOS lets Tether answer the devices (Local Network access)
//   Notices.swift       what to tell in a notification and when, and asking for permission, Foundation only
//   SettingsView.swift  the Settings sheet behind the gear, and the system's notification center
//   DemoMode.swift      fake app state for the UI tests, Debug builds only
//   Fakes.swift         the stand-in server, page and sound the tests and demos share, Debug builds only
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
    var wireGuardPeers: [WireGuardSetup.Peer] { session.wireGuardPeers }
    var wireGuardPeerStats: [String: PeerStats] { session.wireGuardPeerStats }
    var wireGuardReady: WireGuardSetup.Ready? { session.wireGuardReady }
    var wireGuardReadyProblem: String? { session.wireGuardReadyProblem }
    var wireGuardDeviceProblem: HotspotSession.DeviceProblem? { session.wireGuardDeviceProblem }
    var wireGuardProblem: String? { session.wireGuardProblem }
    var sharing: Bool { session.sharing }
    var wireGuardNeedsReset: Bool { session.wireGuardNeedsReset }

    /// iOS blocks Tether's replies to the devices, see `LocalNetworkCheck`. Checked while on screen.
    @Published var localNetworkDenied = false
    private let localNetwork = LocalNetworkCheck()
    /// The hotspot was up at the watcher's last round, so the check runs again when it comes up.
    private var hotspotWasUp = false

    /// When this build stops opening, from its provisioning profile. Nil without one.
    var expires: Date? = AppExpiry.installed { didSet { refreshExpiryWarning() } }
    /// "Tether stops opening in 2 days ...", in the last three days before `expires`. Refreshed by
    /// the 1 s sampler, so it appears on time even on a screen where nothing else changes.
    @Published private(set) var expiryWarning: String?

    /// For the Settings sheet, which refreshes it, see `refreshNoticePermission`.
    @Published private(set) var noticePermission: NoticePermission = .notAsked
    /// Where the notification switches are saved. A demo launch has its own, emptied at launch.
    let noticeDefaults: UserDefaults
    private var notifier: Notifier
    private var closedAlarm = ClosedAlarm()
    private let noticeCenter: NoticeCenter
    private let poster: NoticePoster

    private let session: HotspotSession
    private static let logger = Logger(subsystem: "com.vsvirskyi.phoneshare", category: "tether")

    #if DEBUG
    /// Set in a demo launch (`-TetherDemo`, see DemoMode.swift). Nothing real runs then.
    private var demo: DemoState?
    /// The `notificationsScreen` demo opens on the Settings sheet.
    var opensSettings: Bool { demo?.scenario == .notificationsScreen }
    /// Some demos open on the Add a device sheet.
    var opensAddDevice: Bool { [.addDeviceScreen, .addDeviceComputer, .addDeviceWaiting, .addDeviceDone].contains(demo?.scenario) }
    /// The `addDeviceComputer` demo opens the sheet with Computer picked.
    var addDeviceStartsOnComputer: Bool { demo?.scenario == .addDeviceComputer }
    /// In the `addDeviceWaiting` and `addDeviceDone` demos, the sheet follows a listed device, as if
    /// it had just claimed the code: the Windows PC isn't connected, the iPad is.
    var addDeviceFollows: WireGuardSetup.Peer.ID? {
        let name = switch demo?.scenario {
        case .addDeviceWaiting: "Windows PC"
        case .addDeviceDone: "iPad"
        default: ""
        }
        return wireGuardPeers.first { $0.name == name }?.id
    }
    #else
    var opensSettings: Bool { false }
    var opensAddDevice: Bool { false }
    var addDeviceFollows: WireGuardSetup.Peer.ID? { nil }
    var addDeviceStartsOnComputer: Bool { false }
    #endif

    init() {
        #if DEBUG
        let demo = DemoState.fromLaunchArguments()
        let secrets: SecretStore = demo?.secrets() ?? KeychainSecrets()
        noticeDefaults = demo?.noticeDefaults() ?? .standard
        noticeCenter = demo?.noticeCenter() ?? SystemNoticeCenter(log: Self.append)
        #else
        let secrets: SecretStore = KeychainSecrets()
        noticeDefaults = .standard
        noticeCenter = SystemNoticeCenter(log: Self.append)
        #endif
        notifier = Notifier(defaults: noticeDefaults)
        poster = NoticePoster(center: noticeCenter)
        #if DEBUG
        session = demo?.makeSession(log: Self.append) ?? Self.session(secrets: secrets)
        #else
        session = Self.session(secrets: secrets)
        #endif
        session.willChange = { [weak self] in self?.objectWillChange.send() }
        #if DEBUG
        if let demo {
            self.demo = demo
            expires = demo.expires
            refreshExpiryWarning() // didSet doesn't run for a property set in its own class's init
            localNetworkDenied = demo.localNetworkDenied
            if demo.scenario == .notifying { postDemoNoticeInBackground() }
            return // no watcher, sampler or scene observers
        }
        #endif
        refreshExpiryWarning()
        observeScene()
        localNetwork.onChange = { [weak self] denied in
            self?.localNetworkDenied = denied
            Self.append("Local Network access: \(denied ? "denied" : "allowed")")
        }
        if session.sceneActive { localNetwork.start() }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                self?.session.watch()
                self?.checkLocalNetworkWhenTheHotspotComesUp()
                self?.notify()
                // The slack lets iOS wake the app for this together with other timers.
                let interval = KeepAlivePolicy.watchInterval(sceneActive: self?.session.sceneActive ?? false)
                try? await Task.sleep(for: interval.every, tolerance: interval.tolerance)
            }
        }
        if session.sceneActive { startSampler() }
    }

    /// The session with the real server, sound, page and hotspot.
    private static func session(secrets: SecretStore) -> HotspotSession {
        HotspotSession(devices: WireGuardDevices(secrets: secrets), server: WireGuardServer(log: Self.append),
                       keepAlive: KeepAlive(log: Self.append), page: ConfigPageServer(),
                       sceneActive: UIApplication.shared.applicationState != .background,
                       hotspotAddress: HotspotAddressKeeper(defaults: .standard).address,
                       carrierIPv6Only: Interfaces.carrierIPv6Only,
                       log: Self.append)
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

    /// After each watcher round: what to tell, see `Notifier`. In the background the round has just
    /// read who is connected, so this costs no more reads of the server. On screen, the first thing it
    /// would have told asks for permission.
    private func notify() {
        let notices = notifier.check(Notifier.Round(now: Date(), onScreen: session.sceneActive, hotspot: session.running,
                                                    sharing: session.sharing, devices: session.wireGuardPeers,
                                                    connected: session.connectedNow, expires: expires))
        if notifier.wouldTell { askForNotices() }
        let alarm = closedAlarm.check(now: Date(), sharing: session.sharing, on: NoticeKind.closed.isOn(in: noticeDefaults))
        if alarm != .none { poster.queue(alarm) }
        guard !notices.isEmpty else { return }
        for notice in notices { Self.append("notice: \(notice.title)") }
        Task { await poster.post(notices) }
    }

    /// Shows the system's question if it was never answered, see `NoticePoster`.
    func askForNotices() {
        Task {
            await poster.askIfNotAsked()
            await refreshNoticePermission()
        }
    }

    func refreshNoticePermission() async {
        let permission = await noticeCenter.permission()
        if permission != noticePermission { noticePermission = permission }
    }

    #if DEBUG
    /// The `notifying` demo: it asks for permission on screen at launch, the way a device connecting
    /// there does, and leaving the screen posts one notice through the real notification center. A
    /// demo has no silent sound, so a background task keeps it running for that.
    private func postDemoNoticeInBackground() {
        askForNotices()
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let task = UIApplication.shared.beginBackgroundTask()
                Task {
                    await self.poster.post([DemoScenario.notice])
                    UIApplication.shared.endBackgroundTask(task)
                }
            }
        }
    }
    #endif

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

    /// See `HotspotSession.openAddWindow`.
    func openAddWindow() {
        session.openAddWindow()
    }

    /// See `HotspotSession.closeAddWindow`.
    func closeAddWindow() {
        session.closeAddWindow()
    }

    var deviceHost: String? { session.deviceHost }

    /// See `HotspotSession.needsNewConfig`.
    func needsNewConfig(_ peer: WireGuardSetup.Peer) -> Bool {
        session.needsNewConfig(peer)
    }

    func wireGuardConfig(for ready: WireGuardSetup.Ready) -> String? {
        session.wireGuardConfig(for: ready)
    }

    /// The hotspot is a local network iOS may ask about, so a check on screen runs again when it appears.
    private func checkLocalNetworkWhenTheHotspotComesUp() {
        let up = session.running
        defer { hotspotWasUp = up }
        if up, !hotspotWasUp, session.sceneActive { localNetwork.start() }
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
            model.localNetwork.start() // afresh, for a change made in Settings
            model.startSampler() // samples at once, then every second again
        }
        observe(UIApplication.willResignActiveNotification) { model in
            model.session.leftScreen()
            model.localNetwork.stop()
            model.sampler?.cancel()
        }
        observe(UIApplication.didReceiveMemoryWarningNotification) { $0.session.freeMemory() }
    }

    /// Internal log, read in Console.app. Nothing in the app shows it.
    private static func append(_ s: String) {
        logger.info("\(s, privacy: .public)")
    }
}
