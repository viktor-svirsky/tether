// File map (all in Sources/):
//   TetherApp.swift     the @main App only
//   Model.swift         Model: what the screen and the Shortcuts actions see, and the timers
//   HotspotSession.swift  the hotspot lifecycle Model runs, and Interfaces, Foundation only
//   AddWindow.swift     when the code behind Add a device works, by the clock, Foundation only
//   TrafficSampler.swift  the speeds from two reads of the counters, Foundation only
//   Traffic.swift       the server's byte counters, Foundation only
//   Format.swift        bytes and speeds as text
//   MainView.swift      MainView (the main screen), StatusCard, and the speeds
//   DevicesView.swift   Add a device on the main screen, and a device's own screen
//   ProxyView.swift     the HTTP proxy's own screen (#78)
//   AddDeviceSheet.swift the steps to add a device, with the QR code for it
//   AddDeviceProgress.swift  how far adding a device has got, for the sheet, Foundation only
//   DeviceStatus.swift  what a device's row and screen say: connected, not, or paused, Foundation only
//   ConfigPage.swift    the page on the hotspot that hands out the next device's config, Foundation only
//   ConfigPageHandler.swift  what the page answers to each request, Foundation only
//   ConfigPageServer.swift  serves that page on the hotspot address
//   AppExpiry.swift     when a sideloaded build stops opening, and the warning before it
//   LocalNetwork.swift  whether iOS lets Tether answer the devices (Local Network access)
//   LocalNetworkWarning.swift  why no device can connect while it's off, on the card and in Add a device
//   LocalNetworkIntro.swift  no check before the first launch's screen about it, Foundation only;
//     LocalNetworkIntroView.swift is that screen
//   Notices.swift       what to tell in a notification and when, and asking for permission, Foundation only
//   SettingsView.swift  the Settings sheet behind the gear, and the system's notification center
//   DebugLog.swift      the log Settings shares, kept in a file, Foundation only
//   LogRedaction.swift  what each line of that log leaves out, Foundation only
//   DemoMode.swift      fake app state for the UI tests, Debug builds only
//   Fakes.swift         the stand-in server, page and sound the tests and demos share, Debug builds only
//   Shortcuts.swift     the Shortcuts actions; ShortcutReply.swift has what they say, Foundation only
//   WireGuardSetup.swift  the hotspot address, WireGuard keys, devices and client configs, Foundation only
//   WireGuardServer.swift  runs the WireGuard server (WireGuard/, Go)
//   KeepAlive.swift, KeepAlivePolicy.swift  the silent sound that keeps Tether running
//   WidgetState.swift   what the widgets show, Foundation only; TetherShared.swift has the Live
//     Activity's contents and the intent their buttons run. Both are also compiled into the widget
//     extension (Widgets/)

import ActivityKit
import Network
import OSLog
import SwiftUI
import UIKit
import WidgetKit

extension KeepAlive: KeepAliveSound {}

/// What SwiftUI observes. The decisions are in `HotspotSession`. This runs it on the watcher and the
/// sampler, tells it when the app comes on screen or leaves, and shows what it has.
@MainActor
final class Model: ObservableObject {
    /// The screen and the Shortcuts actions share it. An action can launch Tether in the
    /// background, with no screen, and this is all that runs then.
    static let shared = Model()

    // These forward to the session, which announces each change through `objectWillChange`.
    var running: Bool { session.running }
    var downSpeed: Double { session.downSpeed }
    var upSpeed: Double { session.upSpeed }
    var wireGuardConnected: Set<String> { session.wireGuardConnected }
    var wireGuardPeers: [WireGuardSetup.Peer] { session.wireGuardPeers }
    var wireGuardPeerStats: [String: PeerStats] { session.wireGuardPeerStats }
    var wireGuardReady: WireGuardSetup.Ready? { session.wireGuardReady }
    var wireGuardReadyProblem: String? { session.wireGuardReadyProblem }
    var wireGuardDeviceProblem: HotspotSession.DeviceProblem? { session.wireGuardDeviceProblem }
    var wireGuardProblem: String? { session.wireGuardProblem }
    var sharing: Bool { session.sharing }
    var wireGuardNeedsReset: Bool { session.wireGuardNeedsReset }
    /// The HTTP proxy (#78), see `HotspotSession.proxy`. Paused, limited and counted by its id, like a device.
    var proxy: WireGuardSetup.Proxy? { session.proxy }
    var proxyStats: ProxyStats { session.proxyStats }
    var proxyProblem: String? { session.proxyProblem }
    /// For the Diagnostics screen in Settings (#256).
    var serverDiagnostics: ServerDiagnostics { session.serverDiagnostics }
    /// On, so it has a row under Devices.
    var proxyOn: Bool { proxy?.on == true }
    /// The devices on the hotspot that aren't using Tether (#109), see `HotspotSession.notUsingTether`.
    var notUsingTether: [String] { session.notUsingTether }
    var vpnInterface: String? { session.vpnInterface }
    var blockedWithoutVPN: Bool { session.blockedWithoutVPN }

    /// iOS blocks Tether's replies to the devices, see `LocalNetworkCheck`. Checked while on screen.
    @Published private(set) var localNetworkDenied = false
    /// A device is trying to connect with a config that no longer works, see `HotspotSession.showsStaleConfig`.
    /// Its own, since it goes by the clock, a minute after the last knock, when nothing else changes.
    @Published private(set) var staleConfigShown = false
    private let localNetwork = LocalNetworkCheck()
    /// The screen before iOS asks for Local Network access. Every check goes through it, see `LocalNetworkIntro`.
    @Published private(set) var showsLocalNetworkIntro = false
    private lazy var localNetworkIntro = LocalNetworkIntro(defaults: .standard) { [weak self] in self?.localNetwork.start() }
    /// The hotspot was up at the watcher's last round, so the check runs again when it comes up.
    private var hotspotWasUp = false

    /// When this build stops opening, from its provisioning profile. Nil without one.
    private(set) var expires: Date? = AppExpiry.installed { didSet { refreshExpiryWarning() } }
    /// "Tether stops opening in 2 days ...", in the last three days before `expires`. Refreshed by
    /// the 1 s sampler, so it appears on time even on a screen where nothing else changes.
    @Published private(set) var expiryWarning: String?

    /// For the Settings sheet. Refreshed each time Tether comes on screen and when Settings opens, see `refreshNoticePermission`.
    @Published private(set) var noticePermission: NoticePermission = .notAsked
    /// Where Settings saves the notification switches and the idle stop. A demo launch has its own, emptied at launch.
    let settingsDefaults: UserDefaults
    private var notifier: Notifier
    private var closedAlarm = ClosedAlarm()
    private let noticeCenter: NoticeCenter
    private let poster: NoticePoster

    private let session: HotspotSession
    private static let logger = Logger(subsystem: "com.vsvirskyi.phoneshare", category: "tether")
    /// The log Settings shares, with the Go server's lines. A demo launch has its own, emptied at launch.
    nonisolated static let debugLog: DebugLog = {
        #if DEBUG
        if let demo = DemoState.fromLaunchArguments() { return demo.debugLog() }
        #endif
        return DebugLog(directory: DebugLog.defaultDirectory, source: WireGuardServer.takeLog)
    }()

    /// "1.1.0 (66)": the version people see, and the build number from the commit count.
    nonisolated static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// The log to share, as a file: what this build, iOS and iPhone are, then the lines.
    nonisolated static func writeLog() throws -> URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let header = "Tether \(version), iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(model)"
        return try debugLog.writeExport(header: header, to: FileManager.default.temporaryDirectory)
    }

    #if DEBUG
    /// Set in a demo launch (`-TetherDemo`, see DemoMode.swift). Nothing real runs then.
    private var demo: DemoState?
    /// The `notificationsScreen` demo opens on the Settings sheet.
    var opensSettings: Bool { demo?.scenario == .notificationsScreen }
    /// Some demos open on the Add a device sheet, past its first question.
    var opensAddDevice: Bool { addDeviceOpensOn != nil }
    var addDeviceOpensOn: AddDeviceWay? {
        switch demo?.scenario {
        case .addDeviceScreen, .addDeviceComputer, .addDeviceComputerIPv6, .addDeviceWaiting, .addDeviceDone, .addDeviceDoneUnsaved: .wireGuard
        case .addDeviceProxy, .addDeviceProxyWorking: .proxy
        default: nil
        }
    }
    /// The `addDeviceComputer` demos open the sheet with Computer picked.
    var addDeviceStartsOnComputer: Bool { [.addDeviceComputer, .addDeviceComputerIPv6].contains(demo?.scenario) }
    /// In the `addDeviceWaiting` and `addDeviceDone` demos (and `addDeviceDoneUnsaved`), the sheet
    /// follows a listed device, as if it had just claimed the code: the Windows PC isn't connected,
    /// the iPad is.
    var addDeviceFollows: WireGuardSetup.Peer.ID? {
        let name = switch demo?.scenario {
        case .addDeviceWaiting: "Windows PC"
        case .addDeviceDone, .addDeviceDoneUnsaved: "iPad"
        default: ""
        }
        return wireGuardPeers.first { $0.name == name }?.id
    }
    #else
    var opensSettings: Bool { false }
    var opensAddDevice: Bool { false }
    var addDeviceOpensOn: AddDeviceWay? { nil }
    var addDeviceFollows: WireGuardSetup.Peer.ID? { nil }
    var addDeviceStartsOnComputer: Bool { false }
    #endif

    init() {
        Self.append("Tether \(Self.version) launched")
        #if DEBUG
        let demo = DemoState.fromLaunchArguments()
        let secrets: SecretStore = demo?.secrets() ?? KeychainSecrets()
        settingsDefaults = demo?.settingsDefaults() ?? .standard
        noticeCenter = demo?.noticeCenter() ?? SystemNoticeCenter(log: Self.append)
        #else
        let secrets: SecretStore = KeychainSecrets()
        settingsDefaults = .standard
        noticeCenter = SystemNoticeCenter(log: Self.append)
        #endif
        notifier = Notifier(defaults: settingsDefaults)
        Self.settleLocalNetworks(settingsDefaults, secrets: secrets) // before the session reads it (#230)
        poster = NoticePoster(center: noticeCenter)
        #if DEBUG
        session = demo?.makeSession(log: Self.append) ?? Self.session(secrets: secrets, settings: settingsDefaults)
        #else
        session = Self.session(secrets: secrets, settings: settingsDefaults)
        #endif
        session.willChange = { [weak self] in self?.objectWillChange.send() }
        #if DEBUG
        if let demo {
            self.demo = demo
            expires = demo.expires
            refreshExpiryWarning() // didSet doesn't run for a property set in its own class's init
            localNetworkDenied = demo.localNetworkDenied
            showsLocalNetworkIntro = demo.showsLocalNetworkIntro
            staleConfigShown = session.showsStaleConfig
            if demo.scenario == .notifying { postDemoNoticeInBackground() }
            return // no watcher, sampler or scene observers
        }
        #endif
        refreshExpiryWarning()
        let calls = SystemCalls()
        callWatch = CallWatch(calls: calls, cellular: Self.cellular, log: Self.append)
        session.callOn = { calls.calls.contains { !$0.ended } }
        session.localNetworkIntroduced = { [weak self] in !(self?.localNetworkIntro.shown ?? true) }
        observeScene()
        localNetwork.onChange = { [weak self] denied in
            self?.localNetworkDenied = denied
            Self.append("Local Network access: \(denied ? "denied" : "allowed")")
        }
        showsLocalNetworkIntro = localNetworkIntro.shown
        if session.sceneActive { localNetworkIntro.check() }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                self?.session.checkVPN()
                // And once more: iOS can say the network changed before a VPN has all its routes in,
                // IPv4 a moment before IPv6, and may not say it again.
                try? await Task.sleep(for: .seconds(2))
                self?.session.checkVPN()
            }
        }
        pathMonitor.start(queue: .main)
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                self?.session.watch()
                Self.debugLog.takeSource() // the Go server's lines, also when Tether has nothing to say
                self?.checkLocalNetworkWhenTheHotspotComesUp()
                self?.publishWidgets()
                self?.notify()
                // The slack lets iOS wake the app for this together with other timers.
                let interval = KeepAlivePolicy.watchInterval(sceneActive: self?.session.sceneActive ?? false)
                try? await Task.sleep(for: interval.every, tolerance: interval.tolerance)
            }
        }
        if session.sceneActive {
            startSampler()
            startKnocking()
        }
    }

    /// See `LocalNetworks.settle`. It does nothing once the setting is saved.
    private static func settleLocalNetworks(_ settings: UserDefaults, secrets: SecretStore) {
        LocalNetworks.settle(in: settings, introduced: UserDefaults.standard.bool(forKey: LocalNetworkIntro.key),
                             savedSetup: { try secrets.load() })
    }

    /// The session with the real server, sound, page and hotspot.
    private static func session(secrets: SecretStore, settings: UserDefaults) -> HotspotSession {
        HotspotSession(devices: WireGuardDevices(secrets: secrets), server: WireGuardServer(log: Self.append),
                       keepAlive: KeepAlive(log: Self.append), page: ConfigPageServer(),
                       sceneActive: UIApplication.shared.applicationState != .background,
                       hotspotAddress: HotspotAddressKeeper(defaults: .standard).address,
                       carrierIPv6Only: Interfaces.carrierIPv6Only,
                       idleStopAfter: { IdleStop.After.saved(in: settings) },
                       dns: { DNSChoice.upstream(in: settings) },
                       blockLocal: {
                           settleLocalNetworks(settings, secrets: secrets) // once the Keychain can be read
                           return !LocalNetworks.allowed(in: settings)
                       }, usageDefaults: settings,
                       resetDay: { ResetDay.saved(in: settings) },
                       cellular: { "\(Interfaces.pdpIp0(in: Interfaces.addresses())), \(cellular.dataLine())" },
                       internetVPN: { Interfaces.internetVPN(nat64: WireGuardServer.nat64Prefix) },
                       onlyThroughVPN: { settings.bool(forKey: HotspotSession.onlyThroughVPNKey) },
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

    /// Every 10 s while the app is on screen: who on the hotspot isn't using Tether, see
    /// `HotspotSession.knockNeighbors`. Only the Devices section shows it, and each round is 26 TCP
    /// connects that wake Tether and the hotspot's Wi-Fi, so like the sampler it stops off screen,
    /// where nobody sees the result, to save battery.
    private func startKnocking() {
        knocking?.cancel()
        knocking = Task { [weak self] in
            while !Task.isCancelled {
                await self?.session.knockNeighbors()
                try? await Task.sleep(for: .seconds(HotspotNeighbors.every))
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
    /// What the widgets were last given, so they're reloaded only on a change.
    private var widgetState: WidgetState?
    /// The Live Activity while sharing, see `followLiveActivity`.
    private var activity: Activity<TetherActivityAttributes>?
    private var activityFailure: String?
    /// The person swiped the Live Activity away, so it isn't started again until a stop and a start.
    private var activityDismissed = false
    /// One left by an earlier launch was looked for.
    private var activityAdopted = false
    /// When a start was last tried.
    private var activityTried: Date?
    /// When the widgets' state was last stood by, see `WidgetState.markAlive`.
    private var widgetAlive: Date?
    /// When the Live Activity was last looked at.
    private var activityChecked: Date?
    private var toldNoGroup = false
    /// Logs the calls, see `CallWatch`.
    private var callWatch: CallWatch?
    /// Shared, so the call lines and the hotspot line number the lines the same way.
    private static let cellular = Cellular(radio: SystemRadio())
    /// Tells the session at once when the network changes, so Only share through a VPN pauses the
    /// devices as the VPN goes, not at the next round.
    private let pathMonitor = NWPathMonitor()
    private var sampler: Task<Void, Never>?
    private var knocking: Task<Void, Never>?

    /// After each watcher round: what to tell, see `Notifier`. In the background the round has just
    /// read who is connected, so this costs no more reads of the server. On screen, the first thing it
    /// would have told asks for permission.
    /// Gives the task that posts, nil when there's nothing to post.
    @discardableResult
    private func notify() -> Task<Void, Never>? {
        let notices = notifier.check(Notifier.Round(now: Date(), onScreen: session.sceneActive, hotspot: session.running,
                                                    sharing: session.sharing, devices: session.notifiedPeers,
                                                    connected: session.connectedNow, expires: expires,
                                                    idleStopped: session.idleStopped, limitAlerts: session.limitAlerts,
                                                    keptOut: session.blockedWithoutVPN))
        if notifier.wouldTell { askForNotices() }
        let alarm = closedAlarm.check(now: Date(), sharing: session.sharing, on: NoticeKind.closed.isOn(in: settingsDefaults))
        if alarm != .none { poster.queue(alarm) }
        for notice in notices { Self.append(notice.logLine) }
        guard alarm != .none || !notices.isEmpty else { return nil }
        // An idle stop has just stopped the sound, and iOS suspends Tether soon after. Background time
        // lets the notice and the alarm's change get out first: a "Tether stopped sharing" left waiting
        // would show 3 minutes later.
        let background = BackgroundTime()
        return Task {
            await poster.post(notices)
            await poster.alarmDone()
            background.end()
        }
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

    /// See `HotspotSession.stopNow`. Only from the background: with Control Center over the open app
    /// Tether is inactive, not gone, and closing Control Center would start it again.
    @discardableResult
    func stopNow() -> Bool {
        #if DEBUG
        if demo != nil { return false }
        #endif
        guard UIApplication.shared.applicationState == .background else { return false }
        return session.stopNow()
    }

    /// Which button ran the widgets' own Start or Stop. iOS redraws that one itself once the intent
    /// returns, so asking for it too redrew it twice, and a widget's Stop spun twice before it showed
    /// Stopped.
    enum WidgetButton { case widget, control }

    /// Gives the widgets, the Control Center button and the Live Activity where Tether stands, through
    /// the app group, and asks iOS to redraw them only when it changed, for the battery. Each watcher
    /// round.
    func publishWidgets() {
        guard let state = widgetStateNow() else { return }
        // A round that stopped sharing has stopped the sound too, and iOS suspends Tether soon after.
        // Background time lets the Live Activity's end get out first, as in `notify`.
        if let change = followLiveActivity(state, mayStart: session.sceneActive) {
            let background = BackgroundTime()
            Task {
                await change.value
                background.end()
            }
        }
        reloadWidgets(state, redrawnByIOS: nil)
    }

    /// The same after the widgets' own Start and Stop, see `WidgetButton`. Everything is done before
    /// this returns: after Stop iOS suspends Tether, and what's left to a task would wait. That's the
    /// Live Activity's end, and the alarm for iOS closing Tether, which a Stop mustn't leave to ring.
    func publishWidgets(after button: WidgetButton) async {
        guard let state = widgetStateNow() else { return }
        activityTried = nil // the person asked, so it's tried now
        await followLiveActivity(state, mayStart: true)?.value
        await notify()?.value
        // Read again: a Start or a watcher round may have published a newer one while this waited.
        guard let latest = widgetStateNow() else { return }
        reloadWidgets(latest, redrawnByIOS: button)
    }

    private func widgetStateNow() -> WidgetState? {
        #if DEBUG
        if demo != nil { return nil }
        #endif
        // Running, but not for long: what Start Tether says in Shortcuts then (#164), so a Start on a
        // widget that couldn't keep Tether running says why it shows Stopped again.
        let cantStay = session.running && !session.staysRunning ? "Tether couldn't keep running in the background. Open it once." : nil
        return WidgetState(sharing: session.sharing && session.staysRunning, awake: session.awake, problem: session.wireGuardProblem ?? cantStay,
                           connected: session.connectedPeers.map { WidgetState.Device(id: $0.id, name: $0.name) },
                           vpn: session.vpnInterface != nil, blockedWithoutVPN: session.blockedWithoutVPN)
    }

    private func reloadWidgets(_ state: WidgetState, redrawnByIOS button: WidgetButton?) {
        // The Live Activity needs no app group, the widgets do: without it there's nothing to write.
        guard SharedGroup.available else {
            if !toldNoGroup { Self.append("widgets: this install's signature has no app group (\(SharedGroup.id)), so they can't read Tether's state") }
            toldNoGroup = true
            return
        }
        let now = Date()
        // The state wasn't stood by for `WidgetState.staleAfter`: iOS had Tether suspended, and a
        // widget may have taken it for left behind and drawn Stopped. The same state is news again.
        if let alive = widgetAlive, now.timeIntervalSince(alive) >= WidgetState.staleAfter { widgetState = nil }
        let changed = state != widgetState
        // Stood by once a minute while awake, with no redraw, see `WidgetState.load`.
        if state.awake, changed || widgetAlive.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            WidgetState.markAlive(now)
            widgetAlive = now
        }
        guard changed else { return }
        state.save()
        // iOS redraws the widget whose button ran, but perhaps not Tether's other widgets. Left
        // unremembered, the next round's state counts as a change and redraws them all. After Stop
        // there's no next round, and they catch up at their timeline's next reload.
        widgetState = button == .widget ? nil : state
        if button != .widget { WidgetCenter.shared.reloadAllTimelines() }
        if button != .control, #available(iOS 18, *) { ControlCenter.shared.reloadAllControls() }
    }

    /// How long a Live Activity's contents count without a word from Tether. iOS marks it stale
    /// after that, and it says to open Tether: iOS can close Tether with no warning, and the
    /// activity would say Sharing for hours. Renewed with `activityRenewWithin` left, so about three
    /// times an hour, and with every change.
    private static let activityFreshFor: TimeInterval = 30 * 60
    private static let activityRenewWithin: TimeInterval = 10 * 60

    /// A Live Activity from a start to a stop: while Tether shares or waits for the hotspot, see
    /// `HotspotSession.up`. Updated when sharing, the devices or the VPN change. iOS starts one only
    /// while Tether is on screen or runs an action (`mayStart`), so a round in the background doesn't
    /// ask, and on screen it's tried once a minute at most. One left from before a relaunch is taken
    /// over, not doubled. One iOS ended after its 8 hours is started again, and one swiped away
    /// stays away until Tether is stopped and started. Gives the task that ends or updates it, nil
    /// when there's none.
    @discardableResult
    private func followLiveActivity(_ state: WidgetState, mayStart: Bool) -> Task<Void, Never>? {
        let now = Date()
        if let current = activity, current.activityState != .active, current.activityState != .stale {
            // Swiped away by the person if it was there a round ago. After a long suspension it's as
            // likely iOS, which removes one it ended itself, and that one is started again.
            let justNow = activityChecked.map { now.timeIntervalSince($0) < WidgetState.staleAfter } ?? false
            if current.activityState == .dismissed, justNow { activityDismissed = true }
            activity = nil
        }
        activityChecked = now
        if !activityAdopted {
            activityAdopted = true
            activity = Activity<TetherActivityAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
        }
        guard session.up else {
            activityDismissed = false
            let ending = activity
            activity = nil
            return ending.map { ending in Task { await ending.end(nil, dismissalPolicy: .immediate) } }
        }
        let content = TetherActivityAttributes.ContentState(sharing: state.sharing, count: state.connected.count,
                                                            connected: WidgetState.activityNames(state.connected.map(\.name)),
                                                            vpn: state.vpn, blockedWithoutVPN: state.blockedWithoutVPN)
        let fresh = ActivityContent(state: content, staleDate: now.addingTimeInterval(Self.activityFreshFor))
        if let activity {
            let renew = activity.content.staleDate.map { $0.timeIntervalSince(now) < Self.activityRenewWithin } ?? true
            guard activity.content.state != content || renew else { return nil }
            return Task { await activity.update(fresh) }
        }
        guard mayStart, !activityDismissed, activityTried.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return nil }
        activityTried = now
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        do {
            activity = try Activity.request(attributes: TetherActivityAttributes(), content: fresh)
            activityFailure = nil
        } catch {
            let failure = "Live Activity: \(error)"
            if failure != activityFailure { Self.append(failure) }
            activityFailure = failure
        }
        return nil
    }

    func resetWireGuard() {
        session.resetWireGuard()
    }

    func renameWireGuardDevice(_ id: WireGuardSetup.Peer.ID, to name: String) {
        session.renameWireGuardDevice(id, to: name)
    }

    /// See `HotspotSession.pauseWireGuardDevice`.
    func pauseWireGuardDevice(_ id: WireGuardSetup.Peer.ID) {
        session.pauseWireGuardDevice(id)
    }

    func resumeWireGuardDevice(_ id: WireGuardSetup.Peer.ID) {
        session.resumeWireGuardDevice(id)
    }

    /// See `HotspotSession.removeWireGuardDevice`.
    @discardableResult
    func removeWireGuardDevice(_ id: WireGuardSetup.Peer.ID) -> Bool {
        session.removeWireGuardDevice(id)
    }

    /// See `HotspotSession.setProxy`.
    func setProxy(on: Bool) { session.setProxy(on: on) }

    /// See `HotspotSession.openAddWindow`.
    func openAddWindow() {
        session.openAddWindow()
    }

    /// See `HotspotSession.closeAddWindow`.
    func closeAddWindow() {
        session.closeAddWindow()
    }

    var deviceHost: String? { session.deviceHost }
    var pageHosts: [String] { session.pageHosts }

    /// See `HotspotSession.usage(of:)`.
    func usage(of id: WireGuardSetup.Peer.ID) -> MonthlyUsage.Usage { session.usage(of: id) }

    /// "Today at 4:00 PM", or "Never": see `HotspotSession.lastConnected(of:)`. A demo goes by its own
    /// clock, like the expiry warning.
    func lastConnected(of id: WireGuardSetup.Peer.ID) -> String {
        var now = Date()
        #if DEBUG
        if demo != nil { now = DemoScenario.now }
        #endif
        return Format.lastConnected(session.lastConnected(of: id), now: now, calendar: .current)
    }

    /// See `HotspotSession.connectsFrom(of:)`.
    func connectsFrom(of id: WireGuardSetup.Peer.ID) -> String? { session.connectsFrom(of: id) }

    /// See `HotspotSession.setLimit`.
    func setLimit(_ id: WireGuardSetup.Peer.ID, _ limit: UInt64?) { session.setLimit(id, limit) }

    /// Settings > Devices changed, see `HotspotSession.dnsChanged`.
    func dnsChanged() { session.dnsChanged() }
    /// Settings > local networks changed, see `HotspotSession.localNetworksChanged`.
    func localNetworksChanged() { session.localNetworksChanged() }

    /// Settings > Only share through a VPN changed: it counts at once.
    func checkVPN() { session.checkVPN() }

    /// See `HotspotSession.overLimit`.
    func overLimit(_ id: WireGuardSetup.Peer.ID) -> Bool { session.overLimit(id) }

    /// "1 December": see `HotspotSession.nextReset`.
    var nextResetDay: String { LimitAlert.day(session.nextReset, calendar: .current) }

    /// "this month", or "since Nov 15" with another reset day: see `Format.period`.
    var usagePeriod: String { Format.period(session.period, calendar: .current) }

    /// "Last month", or "Oct 15 to Nov 14" with another reset day: see `Format.lastPeriod`.
    var lastPeriodLabel: String { Format.lastPeriod(session.lastPeriod, calendar: .current) }

    /// Settings > Sharing changed the reset day, see `HotspotSession.resetDayChanged`.
    func resetDayChanged() { session.resetDayChanged() }

    /// See `HotspotSession.needsNewConfig`.
    func needsNewConfig(_ peer: WireGuardSetup.Peer) -> Bool {
        session.needsNewConfig(peer)
    }

    func wireGuardConfig(for ready: WireGuardSetup.Ready) -> String? {
        session.wireGuardConfig(for: ready)
    }

    /// Continue on the screen before iOS asks: the check that makes it ask runs now.
    func finishLocalNetworkIntro() {
        showsLocalNetworkIntro = false
        #if DEBUG
        if demo != nil { return } // nothing real runs in a demo
        #endif
        localNetworkIntro.finish()
    }

    /// The hotspot is a local network iOS may ask about, so a check on screen runs again when it appears.
    private func checkLocalNetworkWhenTheHotspotComesUp() {
        let up = session.running
        defer { hotspotWasUp = up }
        if up, !hotspotWasUp, session.sceneActive { localNetworkIntro.check() }
    }

    /// The expiry warning and the session's sample, see `HotspotSession.sampleTraffic`.
    func sampleTraffic() {
        refreshExpiryWarning()
        session.sampleTraffic()
        refreshStaleConfig()
    }

    /// Logged once each time it shows, not at every knock.
    private func refreshStaleConfig() {
        let shown = session.showsStaleConfig
        guard shown != staleConfigShown else { return }
        staleConfigShown = shown
        if shown, let stale = session.staleConfig {
            Self.append("WireGuard: a device is trying to connect with a config that no longer works (\(stale.kind == .device ? "a device key Tether doesn't let in" : "made for other server keys"))")
        }
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
            model.localNetworkIntro.check() // afresh, for a change made in Settings
            model.startSampler() // samples at once, then every second again
            model.startKnocking()
            // Before Settings opens, or it shows "Allow notifications" for a moment (#184).
            Task { await model.refreshNoticePermission() }
        }
        observe(UIApplication.willResignActiveNotification) { model in
            model.session.leftScreen()
            model.session.saveUsage() // iOS may end Tether in the background with no warning
            model.localNetwork.stop()
            model.sampler?.cancel()
            model.knocking?.cancel()
        }
        observe(UIApplication.didReceiveMemoryWarningNotification) { $0.session.freeMemory() }
    }

    /// Time iOS gives Tether to finish something before it suspends it. Ended once: when the work is
    /// done, or when iOS says the time is up, since a task left running then gets the app killed.
    @MainActor private final class BackgroundTime {
        private var task: UIBackgroundTaskIdentifier = .invalid

        init() {
            // iOS calls this on the main thread.
            task = UIApplication.shared.beginBackgroundTask { [weak self] in MainActor.assumeIsolated { self?.end() } }
        }

        func end() {
            guard task != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
    }

    /// Internal log, read in Console.app, and the log Settings shares. The system log gets the
    /// redacted line too, or full addresses would end up in a sysdiagnose (#162).
    private static func append(_ s: String) {
        logger.info("\(LogRedaction.redact(s), privacy: .public)")
        debugLog.append(s)
    }
}
