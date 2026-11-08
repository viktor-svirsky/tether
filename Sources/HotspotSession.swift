import Foundation
import Network

/// The WireGuard server as `HotspotSession` uses it. `WireGuardServer` is the real one, the tests have a fake.
@MainActor
protocol WireGuardServing: AnyObject {
    var running: Bool { get }
    /// Listens on each of `hosts`. Applies the setup's devices as `setPeers` does, and is left
    /// stopped when they're refused.
    func start(hosts: [String], setup: WireGuardSetup, dns: DNSChoice.Upstream, port: UInt16) throws
    func stop()
    func setPeers(_ setup: WireGuardSetup, dns: DNSChoice.Upstream) throws
    /// The counters, the totals and each device's, only grow, across restarts. Which devices are
    /// connected, only while running.
    func snapshot() -> ServerSnapshot
    func freeMemory()
}

extension WireGuardServer: WireGuardServing {}

/// The config page as `HotspotSession` uses it. `ConfigPageServer` is the real one, the tests have a fake.
@MainActor
protocol ConfigPageServing: AnyObject {
    var respond: @MainActor (ConfigPage.Request, _ client: String) -> ConfigPage.Response { get set }
    var onChange: @MainActor () -> Void { get set }
    var onFailure: @MainActor (Error) -> Void { get set }
    /// Started, and not failed or stopped since.
    var running: Bool { get }
    /// Taking connections.
    var listening: Bool { get }
    func start(hosts: [String], port: UInt16)
    func stop()
}

extension ConfigPageServer: ConfigPageServing {}

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
/// and the config page when the hotspot appears, stop them when it goes, try again after a failure,
/// say why it isn't running, keep the sound playing for a while, and count the speeds. `Model` runs it on a timer
/// and shows it. Foundation only, with everything it talks to passed in, so `swift test` covers it.
@MainActor
final class HotspotSession {
    /// Called before anything below that the screen shows changes, as `@Published` does.
    var willChange: () -> Void = {}

    private(set) var running = false { willSet { willChange() } }
    /// Download and upload speed now, in bits per second. Zero until there are two samples to compare.
    private(set) var downSpeed = 0.0 { willSet { willChange() } }
    private(set) var upSpeed = 0.0 { willSet { willChange() } }
    /// The devices that have connected, in the order they first did.
    private(set) var wireGuardPeers: [WireGuardSetup.Peer] = [] { willSet { willChange() } }
    /// Behind the QR code in the Add a device sheet, see `WireGuardSetup.ready`. Only ever a saved one,
    /// and let in only while the add window is open, see `addWindowOpen`.
    private(set) var wireGuardReady: WireGuardSetup.Ready? { willSet { willChange() } }
    /// Why there's no QR code while the devices that have one still connect: making the next one couldn't be saved.
    private(set) var wireGuardReadyProblem: String? { willSet { willChange() } }
    /// A rename, removal, pause or resume that couldn't be saved, shown on that device's screen until a change saves.
    private(set) var wireGuardDeviceProblem: DeviceProblem? { willSet { willChange() } }
    /// Why WireGuard isn't running, shown on the main screen: the saved setup's problem from launch on,
    /// hotspot or not, or why the server didn't start on the hotspot.
    private(set) var wireGuardProblem: String? { willSet { willChange() } }
    /// The tunnel addresses of the WireGuard devices that are connected. Read with every sample
    /// while the app is on screen. A paused device isn't, even with its tunnel up, see `unpaused`.
    private(set) var wireGuardConnected: Set<String> = [] { willSet { willChange() } }
    /// Each device's numbers by tunnel address, read with the speeds. With the hotspot off, what they used.
    private(set) var wireGuardPeerStats: [String: PeerStats] = [:] { willSet { willChange() } }
    /// The last config that knocked but no longer works, read with every sample, see `showsStaleConfig`.
    private(set) var staleConfig: StaleConfig? { willSet { willChange() } }
    /// Sharing stopped after a time with no device connected, until Tether is opened or Start Tether runs.
    private(set) var idleStopped: IdleStopped? { willSet { willChange() } }
    /// Devices that came near or reached their data limit, for the notifications, the latest last.
    private(set) var limitAlerts: [LimitAlert] = [] { willSet { willChange() } }
    /// Who was connected at the last read, for the notifications: the sampler's on screen, the
    /// watcher's in the background. Nothing on screen shows the watcher's, so it isn't published.
    var connectedNow: Set<String> { sceneActive ? wireGuardConnected : watchedConnected }
    /// The hotspot is on and WireGuard runs. `running` alone is only the hotspot.
    var sharing: Bool { running && wireGuardProblem == nil }
    /// Only the on-screen sampler publishes connections and speeds, so it runs only while the app is on screen.
    /// False in a launch from a Shortcuts action, which happens in the background.
    var sceneActive: Bool

    private let devices: WireGuardDevices
    private let server: WireGuardServing
    private let keepAlive: KeepAliveSound
    private let page: ConfigPageServing
    private let hotspotAddress: () -> String?
    private let carrierIPv6Only: () -> Bool
    /// The setting in Settings > Sharing, read each round, so a change counts at once.
    private let idleStopAfter: () -> IdleStop.After
    /// Settings > New devices: the DNS line for the next device, read for each config made, and where
    /// the server sends lookups to its own address, read for each start and change, see `dnsChanged`.
    private let dns: () -> DNSChoice.Setting
    /// Where each device's data per month is saved, see `MonthlyUsage`. Nil keeps it in memory only.
    private let usageDefaults: UserDefaults?
    private let calendar: Calendar
    private var monthlyUsage: MonthlyUsage
    /// When it was last saved, and whether a read has changed it since.
    private var usageSavedAt: Date?
    private var usageUnsaved = false
    private let now: () -> Date
    private let log: @MainActor (String) -> Void

    /// When the hotspot went away, or Tether was last on screen since. Nil while the hotspot is on.
    /// A launch starts long past, so only opening Tether or Start Tether (`wake`) gives it the 10
    /// minutes. "Is Tether Sharing?" launches Tether in the background too, and only reports.
    private var waitingSince: Date? = .distantPast
    private var idleStop = IdleStop()
    private var sampler = TrafficSampler()
    /// Who was connected at the watcher's last read in the background, see `readInBackground`.
    private var watchedConnected: Set<String> = []
    /// Whose tunnel was up at the last read, the sampler's or the watcher's, paused devices too, so a
    /// resume shows at once.
    private var tunnelsUp: Set<String> = []
    /// The one address `hotspotAddress` picked when the server started. The others come from it,
    /// see `boundHosts`.
    private var boundHost: String?
    /// The carrier gives this iPhone IPv6 only, see `deviceHost`.
    private var onIPv6OnlyCarrier: Bool { willSet { willChange() } }
    /// Why the saved setup can't be used, see `checkSetup`.
    private var setupProblem: String?
    /// Why the server didn't start on the hotspot. It goes with the hotspot.
    private var startProblem: String?
    /// What the config page answers, see `pageResponse`.
    private var pageHandler = ConfigPageHandler()
    /// When the code behind Add a device works, by the clock, see `addWindowOpen`.
    private var addWindow = AddWindow()
    /// The ready device is on the server: the add window was open at the last `followAddWindow()`.
    private var readyLetIn = false

    init(devices: WireGuardDevices, server: WireGuardServing, keepAlive: KeepAliveSound, page: ConfigPageServing,
         sceneActive: Bool, hotspotAddress: @escaping () -> String?, carrierIPv6Only: @escaping () -> Bool = { false },
         idleStopAfter: @escaping () -> IdleStop.After = { .never }, dns: @escaping () -> DNSChoice.Setting = { .default },
         usageDefaults: UserDefaults? = nil, calendar: Calendar = .current, now: @escaping () -> Date = Date.init,
         log: @escaping @MainActor (String) -> Void = { _ in }) {
        self.devices = devices
        self.server = server
        self.keepAlive = keepAlive
        self.page = page
        self.sceneActive = sceneActive
        self.hotspotAddress = hotspotAddress
        self.carrierIPv6Only = carrierIPv6Only
        self.idleStopAfter = idleStopAfter
        self.dns = dns
        self.usageDefaults = usageDefaults
        self.calendar = calendar
        monthlyUsage = usageDefaults.map(MonthlyUsage.load(from:)) ?? MonthlyUsage()
        onIPv6OnlyCarrier = carrierIPv6Only()
        self.now = now
        self.log = log
        publishSetup()
        showSetupProblem() // from launch, before any device joins the hotspot
        page.respond = { [weak self] request, client in self?.pageResponse(request, from: client) ?? ConfigPage.notFound }
        page.onChange = { [weak self] in self?.pageChanged() }
        page.onFailure = { [weak self] error in self?.pageFailed(error) }
    }

    /// One round of the watcher in `Model`.
    func watch() {
        syncWithHotspot()
        // On screen the sampler does this every second.
        if !sceneActive { readInBackground() }
        // Also with the hotspot off, so a device paused at its limit connects again on the 1st.
        checkLimits()
        stopWhenIdle()
    }

    /// The hotspot interface exists only while Personal Hotspot is on. This starts WireGuard when
    /// it appears and stops it when it goes away or changes, so it never listens anywhere else.
    func syncWithHotspot() {
        checkSetup()
        followAddWindow()
        let ipv6Only = carrierIPv6Only()
        if ipv6Only != onIPv6OnlyCarrier { onIPv6OnlyCarrier = ipv6Only }
        let hotspot = hotspotAddress()
        if running, hotspot != boundHost {
            log("hotspot address gone or changed, stopping")
            stopSharing()
        }
        // A WireGuard start that failed (keys locked after a restart, say) is tried again here.
        if running, !server.running, let boundHost { startWireGuard(on: boundHost) }
        // And a page that failed: the address may not have been ready for it yet.
        if running, server.running, !page.running { page.start(hosts: boundHosts, port: ConfigPage.port) }
        // Stopped while idle, it waits to be opened, hotspot or not.
        keepAliveWhileSharing(hotspot: hotspot != nil && idleStopped == nil)
        guard !running, idleStopped == nil, let hotspot else { return }
        log("binding to \(hotspot)")
        boundHost = hotspot
        startWireGuard(on: hotspot)
        // A restart (hotspot address change) never passes through running == false in the
        // sampler, so start the session's counters afresh here.
        sampler.reset()
        downSpeed = 0
        upSpeed = 0
        running = true
    }

    private func stopSharing() {
        server.stop()
        page.stop()
        pageHandler.forget()
        // What the devices used since the last read: a stopped server still reports what it carried.
        countUsage(server.snapshot().peers)
        saveUsage()
        running = false
        startProblem = nil // the next hotspot gets a new try
        showProblem()
    }

    /// Stops sharing once no device has been connected in the background for the set time, see
    /// `IdleStop`, and lets iOS suspend Tether at once, with no 10 minutes' wait. Opening Tether or
    /// Start Tether shares again, see `wake`.
    private func stopWhenIdle() {
        let after = idleStopAfter()
        let now = self.now()
        guard idleStop.check(sharing: sharing, connected: !connectedNow.isEmpty, onScreen: sceneActive, after: after, now: now) else {
            return
        }
        log("no device connected for \(after.spelledOut), stopping until Tether is opened")
        idleStopped = IdleStopped(at: now, after: after)
        stopSharing()
        waitingSince = .distantPast // so the next rounds don't start the sound again, see keepAliveWhileSharing
        keepAlive.stop()
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
            if devices.loaded {
                readyLetIn = false // a code read from the store is replaced before it's let in, see followAddWindow
                publishSetup() // not every round while it's locked, which redraws the screen
            }
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
        let hosts = Self.hosts(for: hotspot)
        do {
            try server.start(hosts: hosts, setup: serverSetup, dns: dns().upstream, port: WireGuardSetup.port)
            page.start(hosts: hosts, port: ConfigPage.port)
            startProblem = nil
            showProblem()
            log("WireGuard on \(hosts.joined(separator: " and ")) port \(WireGuardSetup.port), \(wireGuardPeers.count) devices")
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
    /// starts again, sharing stopped while idle starts again, and sharing starts now if the hotspot
    /// is on. True when the silent sound plays, so iOS keeps Tether running after the action ends.
    @discardableResult
    func wake() -> Bool {
        if waitingSince != nil { waitingSince = now() }
        if idleStopped != nil { idleStopped = nil }
        syncWithHotspot()
        return keepAlive.sounding
    }

    /// Opening Tether starts the wait again, so there's time to turn on Personal Hotspot in Settings.
    func cameOnScreen() {
        sceneActive = true
        // The background's last read, not the list from before the app left, until the sampler reads.
        if wireGuardConnected != watchedConnected { wireGuardConnected = watchedConnected }
        wake()
    }

    func leftScreen() {
        sceneActive = false
        addWindow.leftScreen(now: now())
        sampler.reset() // or the first speed back on screen averages the whole time away
        watchedConnected = wireGuardConnected // not a list from an earlier time away, until the next round reads
    }

    /// The Add a device sheet came on screen. Its code works from now on, see `addWindowOpen`.
    func openAddWindow() {
        addWindow.sheetOpened()
        followAddWindow()
    }

    /// The Add a device sheet went away. Its code works 10 more minutes, see `addWindowOpen`.
    func closeAddWindow() {
        addWindow.sheetClosed(now: now(), sceneActive: sceneActive)
        followAddWindow()
    }

    /// When the code behind Add a device works, see `AddWindow`.
    var addWindowOpen: Bool { addWindow.isOpen(now: now(), sceneActive: sceneActive) }

    /// Puts the ready device on the server when the add window opens and takes it off when it closes.
    /// A window that opens from closed gets a new code first, so a code from an earlier window never
    /// works again, after a relaunch too, where the window starts closed. If the new code can't be
    /// saved there's none until the watcher saves one, never the old one. Checked on every watcher
    /// round, sample and page request, and when the sheet comes or goes.
    private func followAddWindow() {
        let open = addWindowOpen
        // A setup that isn't read yet would bring back the saved code, so the new one waits for it.
        guard open != readyLetIn, !open || devices.loaded else { return }
        // A device whose first handshake came since the last read is listed before its code goes.
        if !open, running, server.running {
            claimReady(server.snapshot().peers)
        }
        readyLetIn = open
        if open {
            log("WireGuard: Add a device opened, a new code for the next device")
            devices.replaceReady()
        } else {
            log("WireGuard: Add a device closed 10 minutes ago, its code no longer works")
        }
        wireGuardPeersChanged()
    }

    /// What the server lets in: the saved devices, and the ready one only while the add window is open.
    private var serverSetup: WireGuardSetup {
        var setup = devices.setup
        if !readyLetIn { setup.ready = nil }
        return setup
    }

    /// For the Shortcuts actions. Off screen the sampler doesn't run, so the connected devices are read now.
    func shortcutState() -> ShortcutReply.State {
        var connected = wireGuardConnected
        if running, server.running {
            connected = unpaused(server.snapshot().connected)
        }
        return ShortcutReply.State(running: running, connected: connected.count, problem: wireGuardProblem,
                                   idleStopped: idleStopped != nil)
    }

    var wireGuardNeedsReset: Bool { devices.needsReset }

    /// Gives up on saved keys this version can't read: a new server key and no devices.
    func resetWireGuard() {
        pageHandler.forget()
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
        if removed { pageHandler.forget() } // its config mustn't be handed out again
        if !removed { log("WireGuard: the removal couldn't be saved, the device stays") }
        showDeviceProblem(removed ? nil : DeviceProblem(device: id, text: "The device couldn't be removed."))
        wireGuardPeersChanged()
        return removed
    }

    /// Paused, a device stays on the server, so its tunnel stays up, but nothing gets through until
    /// it's resumed. A pause that couldn't be saved changes nothing, and its screen says so.
    /// A device already paused stays paused for its reason: one paused at its limit just now, before
    /// the screen showed it, still connects again on the 1st.
    func pauseWireGuardDevice(_ id: WireGuardSetup.Peer.ID) {
        guard devices.setup.peers.first(where: { $0.id == id })?.paused == nil else { return }
        pause(id, .byYou, problem: "The device couldn't be paused.")
    }

    /// A device paused at its limit, resumed by hand while it's still at it, goes over it until the
    /// 1st, see `checkLimits`. One the count already let go (the 1st, before a read caught up) doesn't.
    func resumeWireGuardDevice(_ id: WireGuardSetup.Peer.ID) {
        let peer = devices.setup.peers.first { $0.id == id }
        let atLimit = peer?.paused == .atLimit && peer?.limit.map { usage(of: id).thisMonth.total >= $0 } == true
        guard pause(id, nil, problem: "The device couldn't be resumed."), atLimit else { return }
        monthlyUsage.markResumedOver(id, at: now(), calendar: calendar)
        usageUnsaved = true
    }

    /// Its data limit per month, or nil for none. It counts at once: lowered below what the device used
    /// this month, the device is paused, raised above it or removed, a device paused at it resumes. A
    /// resume or a notice for the old limit doesn't hold for the new one. False when it couldn't be
    /// saved, and the device's screen says so.
    @discardableResult
    func setLimit(_ id: WireGuardSetup.Peer.ID, _ limit: UInt64?) -> Bool {
        // The same limit picked again changes nothing, so a resume over it still holds.
        if devices.setup.peers.first(where: { $0.id == id })?.limit == limit { return true }
        guard devices.limit(id, limit) else {
            log("WireGuard: the new limit couldn't be saved")
            showDeviceProblem(DeviceProblem(device: id, text: "The new limit couldn't be saved."))
            publishSetup()
            return false
        }
        showDeviceProblem(nil)
        monthlyUsage.clearMarks(id)
        usageUnsaved = true
        publishSetup()
        checkLimits()
        return true
    }

    /// Resumed at its limit this month, so it's over it until the 1st.
    func overLimit(_ id: WireGuardSetup.Peer.ID) -> Bool {
        monthlyUsage.resumedOver(id, at: now(), calendar: calendar)
    }

    /// The 1st of next month, when the counts and the limits start over, on the session's clock.
    var nextReset: Date {
        calendar.dateInterval(of: .month, for: now())?.end ?? now()
    }

    @discardableResult
    private func pause(_ id: WireGuardSetup.Peer.ID, _ pause: WireGuardSetup.Pause?, problem: String) -> Bool {
        let saved = devices.pause(id, pause)
        if !saved { log("WireGuard: the \(pause == nil ? "resume" : "pause") couldn't be saved, nothing changed") }
        showDeviceProblem(saved ? nil : DeviceProblem(device: id, text: problem))
        wireGuardPeersChanged()
        publishConnected()
        return saved
    }

    /// The devices the notifications follow, see `Notifier`. A paused one neither connects nor
    /// disconnects, so pausing one tells nothing, and doesn't ask for permission to.
    var notifiedPeers: [WireGuardSetup.Peer] { wireGuardPeers.filter { $0.paused == nil } }

    /// Who is connected, from who has a tunnel up: a paused device's tunnel can be up, but nothing gets through.
    private func unpaused(_ connected: Set<String>) -> Set<String> {
        connected.subtracting(devices.setup.peers.filter { $0.paused != nil }.map(\.address))
    }

    private func publishConnected() {
        let connected = unpaused(tunnelsUp)
        if connected != wireGuardConnected { wireGuardConnected = connected }
    }

    /// It names its device, so another device's screen doesn't show it.
    struct DeviceProblem: Equatable {
        let device: WireGuardSetup.Peer.ID
        let text: String
    }

    /// The last change to a device decides: one that saves clears it, one that doesn't names itself.
    private func showDeviceProblem(_ problem: DeviceProblem?) {
        if problem != wireGuardDeviceProblem { wireGuardDeviceProblem = problem }
    }

    /// Where devices reach Tether: the hotspot address it listens on, or the usual one while it
    /// doesn't, for a QR code scanned before the hotspot is on. None on a carrier that gives the
    /// iPhone IPv6 only, until a device joins the hotspot: 172.20.10.1 can't be reached there, and
    /// the iPhone's IPv6 address on the hotspot only comes with the hotspot's first device.
    var deviceHost: String? {
        if running { return boundHost ?? Hotspot.host }
        return onIPv6OnlyCarrier ? nil : Hotspot.host
    }

    /// Where Tether listens while the hotspot is on. On a carrier that gives the iPhone IPv6 only,
    /// its IPv6 address and 172.20.10.1 too: the hotspot gives a Windows PC IPv4 there, and only a
    /// Mac, an iPhone or an iPad takes none (#98). Elsewhere only 172.20.10.1.
    var boundHosts: [String] { boundHost.map(Self.hosts(for:)) ?? [] }

    /// 172.20.10.1 first: it never changes, and a computer with IPv4 on the hotspot reaches it.
    private static func hosts(for hotspot: String) -> [String] {
        hotspot.contains(":") ? [Hotspot.host, hotspot] : [hotspot]
    }

    /// The addresses Add a device > Computer shows for the config page, see `boundHosts`.
    var pageHosts: [String] {
        running ? boundHosts : deviceHost.map { [$0] } ?? []
    }

    /// Where a device reaches Tether, by where its handshake ("ip:port", "[ip]:port") or page
    /// request ("ip") came from: 172.20.10.1 from IPv4 while Tether listens there, else
    /// `deviceHost`. A device whose last handshake isn't known goes by `deviceHost` too.
    private func host(reachedFrom client: String?) -> String? {
        if let client, IPv4Address(Hotspot.address(of: client)) != nil, boundHosts.contains(Hotspot.host) { return Hotspot.host }
        return deviceHost
    }

    /// The device's config points at an address Tether doesn't listen on, so it can't connect until
    /// it's added again (#65). That happens only to the IPv6 address of a carrier that gives the
    /// iPhone IPv6 only, which comes with each cellular session, or goes when the carrier gives it
    /// IPv4 again. Tether always listens on 172.20.10.1, see `boundHosts`. While the hotspot
    /// is off, or for a device saved before Tether kept where it points, it's not known, and no. A
    /// device that is connected reaches Tether, whatever is saved, see `rememberHosts`.
    func needsNewConfig(_ peer: WireGuardSetup.Peer) -> Bool {
        guard running, let host = peer.host, !connectedNow.contains(peer.address) else { return false }
        return !boundHosts.contains(host)
    }

    /// The QR code's config. None while there's no `deviceHost`, so no config is made that can't connect.
    func wireGuardConfig(for ready: WireGuardSetup.Ready) -> String? {
        wireGuardConfig(for: ready, host: deviceHost)
    }

    private func wireGuardConfig(for ready: WireGuardSetup.Ready, host: String?) -> String? {
        host.map { devices.setup.clientConfig(for: ready, host: $0, dns: dns().line) }
    }

    /// A page that listens again logs its next failure.
    private func pageChanged() {
        if page.listening { pageHandler.listening() }
    }

    private func pageFailed(_ error: Error) {
        if let line = pageHandler.failed("\(error)") { log(line) }
    }

    /// The config page's answer, see `ConfigPageHandler`. A download adds the device: it's listed,
    /// and the next device gets a new key, so two devices that download never share one. A device
    /// that never connects shows as Not connected, and can be removed like any other.
    func pageResponse(_ request: ConfigPage.Request, from client: String) -> ConfigPage.Response {
        followAddWindow() // by the clock, not only at the watcher's last round
        let ready = wireGuardReady
        let now = self.now()
        let host = host(reachedFrom: client)
        let inputs = ConfigPageHandler.Inputs(letIn: readyLetIn, onScreen: sceneActive, ready: ready, host: host,
                                              config: ready.flatMap { wireGuardConfig(for: $0, host: host) },
                                              // Read now: only the on-screen sampler keeps the knock.
                                              stale: server.snapshot().recentStale, hosts: boundHosts, now: now)
        switch pageHandler.answer(request, from: client, inputs) {
        case let .answer(response):
            return response
        case let .download(ready, host, config):
            guard devices.claimReady(address: ready.address, host: host) else {
                log("WireGuard: \(client) asked for the config, but the new device couldn't be saved")
                return ConfigPage.page(.noConfig, status: .unavailable)
            }
            log("WireGuard: \(client) downloaded the config from the page")
            wireGuardPeersChanged()
            let name = devices.setup.peers.first { $0.id == ready.id }?.name ?? ""
            let response = ConfigPage.config(config, fileName: WireGuardSetup.fileName(for: name))
            pageHandler.downloaded(response, by: client, at: now)
            return response
        }
    }

    /// On a memory warning.
    func freeMemory() {
        server.freeMemory()
    }

    private func publishSetup() {
        wireGuardPeers = devices.setup.peers
        // Only from a setup that was read: a locked Keychain lists no devices, and that isn't a removal.
        if devices.loaded {
            let before = monthlyUsage
            monthlyUsage.keep(only: Set(devices.setup.peers.map(\.id) + [devices.setup.ready?.id].compactMap { $0 }))
            if monthlyUsage != before { usageUnsaved = true }
        }
        wireGuardReady = devices.setup.ready
        let readyProblem = devices.readyError.map { "The code for the next device can't be saved: \($0)." }
        if readyProblem != wireGuardReadyProblem {
            wireGuardReadyProblem = readyProblem
            if let readyProblem { log("WireGuard: \(readyProblem)") }
        }
    }

    /// The server lets in exactly the saved devices, and the ready one while the add window is open. If
    /// it refuses the new list, it starts again with the saved setup, and a start that fails leaves it
    /// stopped: a removed device is never let in, the problem shows, and the watcher tries again.
    private func wireGuardPeersChanged() {
        devices.prepareReady() // a removal on a full subnet makes room for the QR code
        publishSetup()
        do {
            try server.setPeers(serverSetup, dns: dns().upstream)
        } catch {
            log("WireGuard devices: \(error), restarting")
            if running, let boundHost { startWireGuard(on: boundHost) }
        }
    }

    /// Settings > New devices changed. A device whose config names Tether's own address asks the new
    /// choice from its next lookup. The next device's config is made when it's shown, so it follows too.
    func dnsChanged() {
        wireGuardPeersChanged()
    }

    /// A device is trying to connect with a config that no longer works (#89), by this session's clock.
    var showsStaleConfig: Bool { staleConfig?.shown(at: now()) ?? false }

    /// Reads the server's counters, every second on screen: which devices are connected, and the
    /// speeds from how far the counters moved since the last sample. A device that connected with
    /// the QR code is listed here, and the code changes for the next one.
    /// `snapshot()` reads a small JSON from Go, which is fine to do on the main actor.
    func sampleTraffic() {
        followAddWindow()
        let now = self.now()
        guard running else {
            // A new session starts with zero speeds and nobody connected.
            sampler.reset()
            if downSpeed != 0 { downSpeed = 0 }
            if upSpeed != 0 { upSpeed = 0 }
            tunnelsUp = []
            if !wireGuardConnected.isEmpty { wireGuardConnected = [] }
            let peers = server.snapshot().peers // a stopped server answers with what each device used
            if peers != wireGuardPeerStats { wireGuardPeerStats = peers }
            if staleConfig != nil { staleConfig = nil }
            checkLimits()
            return
        }
        let snap = server.snapshot()
        let connected = snap.connected
        tunnelsUp = connected
        publishConnected()
        if snap.peers != wireGuardPeerStats { wireGuardPeerStats = snap.peers }
        if snap.stale != staleConfig { staleConfig = snap.stale }
        absorb(snap.peers)
        countUsage(snap.peers)
        guard let speeds = sampler.sample(snap.totals, at: now) else { return } // nothing to compare with yet
        upSpeed = speeds.up
        downSpeed = speeds.down
    }

    /// What each read of who is connected does, on screen (the sampler) or off (the watcher): a
    /// device that connected with the QR code is listed, and each connected device's config is
    /// known to point where Tether listens. Paused devices too: their tunnels reach Tether.
    private func absorb(_ peers: [String: PeerStats]) {
        claimReady(peers)
        rememberHosts(peers)
    }

    /// A device that connected with the QR code is listed, and the code changes for the next one.
    /// Not saved means not claimed: the next check tries again. A code that isn't on the server can't
    /// have connected, whatever an older read says.
    private func claimReady(_ peers: [String: PeerStats]) {
        guard readyLetIn, let ready = wireGuardReady, let reached = peers[ready.address], reached.connected,
              let host = host(reachedFrom: reached.endpoint),
              devices.claimReady(address: ready.address, host: host) else { return }
        log("WireGuard: a new device connected with the QR code")
        wireGuardPeersChanged()
    }

    /// A device that is connected reaches Tether where its handshake came to, so its config points
    /// there, or at a name that leads there. Saved for a device saved before Tether kept where it
    /// points, and for one whose config was changed by hand to the new address. Not saved means the
    /// next read tries again.
    private func rememberHosts(_ peers: [String: PeerStats]) {
        guard running else { return }
        var reached: [String: Set<String>] = [:]
        for (address, stats) in peers where stats.connected {
            if let host = host(reachedFrom: stats.endpoint) { reached[host, default: []].insert(address) }
        }
        var changed = false
        for (host, addresses) in reached where devices.point(addresses, at: host) { changed = true }
        if changed { publishSetup() }
    }

    /// The watcher's read in the background, where the sampler doesn't run: who is connected, for
    /// the notifications, and a device that connects then is listed too and the next one gets a new
    /// code. One small JSON from Go each round, which reads the handshakes every 10 seconds anyway.
    private func readInBackground() {
        guard running else {
            watchedConnected = []
            tunnelsUp = []
            return
        }
        let snap = server.snapshot()
        tunnelsUp = snap.connected
        watchedConnected = unpaused(snap.connected)
        absorb(snap.peers)
        countUsage(snap.peers)
    }

    // MARK: Data per month

    /// What the device used this month and last, as of now, see `MonthlyUsage`.
    func usage(of id: WireGuardSetup.Peer.ID) -> MonthlyUsage.Usage {
        monthlyUsage.of(id, at: now(), calendar: calendar)
    }

    /// The device's last handshake, kept through restarts and relaunches (#73). Nil for never, and for
    /// a device that hasn't connected since the version that started keeping it.
    func lastConnected(of id: WireGuardSetup.Peer.ID) -> Date? { monthlyUsage.lastConnected(id) }

    /// Adds what each device's counters grew by to this month, and saves at most once a minute. A
    /// crash loses up to that minute, never counts anything twice.
    private func countUsage(_ peers: [String: PeerStats]) {
        var ids: [String: WireGuardSetup.Peer.ID] = [:]
        for peer in devices.setup.peers { ids[peer.address] = peer.id }
        if let ready = devices.setup.ready { ids[ready.address] = ready.id }
        var counts: [WireGuardSetup.Peer.ID: TrafficTotals] = [:]
        var handshakes: [WireGuardSetup.Peer.ID: Date] = [:]
        for (address, stats) in peers {
            guard let id = ids[address] else { continue }
            counts[id] = stats.traffic
            handshakes[id] = stats.lastHandshake
        }
        let paused = Set(devices.setup.peers.filter { $0.paused != nil }.map(\.id))
        let before = monthlyUsage
        let now = self.now()
        monthlyUsage.record(counts, handshakes: handshakes, paused: paused, at: now, calendar: calendar)
        if monthlyUsage != before { usageUnsaved = true }
        checkLimits()
        if usageSavedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true { saveUsage() }
    }

    /// Each device's limit against what it used this month, after every read: at 90% it's told once,
    /// at its limit it's paused and told, unless it was resumed at its limit this month. A device paused
    /// at its limit connects again once it's under it: on the 1st, or with a higher limit or none. A
    /// pause or resume that can't be saved is tried again at the next read, and only a saved one is told.
    private func checkLimits() {
        guard devices.loaded else { return }
        let now = self.now()
        var changed = false
        for peer in devices.setup.peers {
            let used = monthlyUsage.of(peer.id, at: now, calendar: calendar).thisMonth.total
            switch (peer.paused, peer.limit) {
            case (.atLimit?, nil):
                changed = devices.pause(peer.id, nil) || changed
            case let (.atLimit?, limit?) where used < limit:
                changed = devices.pause(peer.id, nil) || changed
            case let (nil, limit?) where used >= limit && !monthlyUsage.resumedOver(peer.id, at: now, calendar: calendar):
                guard devices.pause(peer.id, .atLimit) else { continue }
                changed = true
                log("WireGuard: a device reached its limit and is paused until the 1st")
                alert(peer, .reached, used: used, limit: limit, now: now)
            case let (nil, limit?) where used < limit && used >= limit / 10 * 9 && !monthlyUsage.nearTold(peer.id, at: now, calendar: calendar):
                monthlyUsage.markNearTold(peer.id, at: now, calendar: calendar)
                usageUnsaved = true
                alert(peer, .near, used: used, limit: limit, now: now)
            default:
                break
            }
        }
        if changed {
            wireGuardPeersChanged()
            publishConnected()
        }
    }

    private func alert(_ peer: WireGuardSetup.Peer, _ kind: LimitAlert.Kind, used: UInt64, limit: UInt64, now: Date) {
        let alert = LimitAlert(device: peer.id, name: peer.name, kind: kind, used: used, limit: limit, resets: nextReset)
        limitAlerts = Array((limitAlerts + [alert]).suffix(20))
    }

    /// Also when sharing stops and when Tether leaves the screen, see `Model`.
    func saveUsage() {
        guard usageUnsaved, let usageDefaults else { return }
        monthlyUsage.save(to: usageDefaults)
        usageSavedAt = now()
        usageUnsaved = false
    }
}

/// Where Tether listens on the hotspot, as `Interfaces.hotspotAddress(in:keeping:)` picks it, with the
/// IPv6 address it last used kept in `defaults`: a device's config points at the address it was given,
/// so Tether keeps it through the hotspot going off and on and a relaunch, while the bridge has it.
/// Only IPv6 is kept, since 172.20.10.1 is always the same.
final class HotspotAddressKeeper {
    static let key = "hotspot.ipv6Address"
    private let defaults: UserDefaults
    private let interfaces: () -> [String]

    /// `interfaces` are lines like "bridge100: 172.20.10.1", the tests' own in place of the iPhone's.
    init(defaults: UserDefaults, interfaces: @escaping () -> [String] = Interfaces.addresses) {
        self.defaults = defaults
        self.interfaces = interfaces
    }

    func address() -> String? {
        let kept = defaults.string(forKey: Self.key)
        let address = Interfaces.hotspotAddress(in: interfaces(), keeping: kept)
        if let address, address.contains(":"), address != kept { defaults.set(address, forKey: Self.key) }
        return address
    }
}

enum Interfaces {
    /// Where devices on the hotspot reach the iPhone. iOS Personal Hotspot gives the phone
    /// 172.20.10.1 on a bridge interface, and matching the subnet, not only the name, keeps other
    /// bridges out. But when the carrier gives the iPhone IPv6 only (T-Mobile US among others), a Mac
    /// on the hotspot takes no IPv4 (it asks for IPv6 only and makes up 192.0.0.2 for itself) and
    /// can't reach 172.20.10.1. Then it's the iPhone's IPv6 address on the same bridge, and the session
    /// listens on 172.20.10.1 too, for a Windows PC, which does take IPv4 (#98). A CLAT's address in
    /// 192.0.0.0/29 is no IPv4 from the carrier, and nor is IPv4 on another cellular interface than
    /// pdp_ip0, the internet's: VoLTE often has its own, with IPv4 on an IPv6-only carrier.
    /// The bridge may have more than one IPv6 address, some of them temporary ones that come and go.
    /// `current` is kept while the bridge has it, since a new address restarts the server and makes
    /// the devices' configs point at the wrong place. `HotspotAddressKeeper` keeps it across launches.
    /// `interfaces` are lines like "bridge100: 172.20.10.1", from `addresses()`.
    static func hotspotAddress(in interfaces: [String], keeping current: String? = nil) -> String? {
        let lines = parse(interfaces)
        guard let bridge = lines.first(where: { $0.name.hasPrefix("bridge") && $0.address.hasPrefix("172.20.10.") }) else {
            return nil
        }
        if carrierIPv4(lines) { return bridge.address }
        // A link-local address comes with its interface after a %, which only the iPhone knows.
        let ipv6 = lines.filter { $0.name == bridge.name && $0.address.contains(":") && !$0.address.contains("%") }.map(\.address)
        if let current, ipv6.contains(current) { return current }
        return ipv6.first ?? bridge.address
    }

    @MainActor static func carrierIPv6Only() -> Bool {
        carrierIPv6Only(in: addresses())
    }

    /// The carrier gives this iPhone IPv6 and no IPv4, so a Mac, an iPhone or an iPad on the hotspot
    /// will take no IPv4 either. Unlike `hotspotAddress`, this is known before a device joins and the
    /// bridge appears.
    /// It takes pdp_ip0 with IPv6 to say so: no cellular at all, or Wi-Fi only, isn't IPv6 only.
    static func carrierIPv6Only(in interfaces: [String]) -> Bool {
        let lines = parse(interfaces)
        let ipv6 = lines.contains { $0.name == "pdp_ip0" && $0.address.contains(":") && !$0.address.contains("%") }
        return ipv6 && !carrierIPv4(lines)
    }

    private static func parse(_ interfaces: [String]) -> [(name: String, address: String)] {
        interfaces.compactMap { line in
            let parts = line.components(separatedBy: ": ")
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    private static func carrierIPv4(_ lines: [(name: String, address: String)]) -> Bool {
        lines.contains { $0.name == "pdp_ip0" && !$0.address.contains(":") && !isCLAT($0.address) }
    }

    private static func isCLAT(_ address: String) -> Bool {
        guard address.hasPrefix("192.0.0."), let last = Int(address.dropFirst("192.0.0.".count)) else { return false }
        return last < 8
    }

    /// Every address but loopback's, IPv4 and IPv6, as "name: address".
    static func addresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let name = String(cString: p.pointee.ifa_name)
            let addr = String(cString: host)
            if name != "lo0" { out.append("\(name): \(addr)") }
        }
        return out
    }
}
