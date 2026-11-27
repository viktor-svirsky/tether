import Foundation
import Network

/// The WireGuard server as `HotspotSession` uses it. `WireGuardServer` is the real one, the tests have a fake.
@MainActor
protocol WireGuardServing: AnyObject {
    var running: Bool { get }
    /// Listens on each of `hosts`. Applies the setup's devices as `setPeers` does, and is left
    /// stopped when they're refused.
    func start(hosts: [String], setup: WireGuardSetup, dns: DNSChoice.Upstream, blockLocal: Bool, port: UInt16) throws
    func stop()
    /// Listens on `hosts` instead, on the same port, and keeps every device's session (#219).
    func listen(on hosts: [String]) throws
    /// `blockLocal` keeps the devices out of the iPhone's local networks, see `LocalNetworks`.
    func setPeers(_ setup: WireGuardSetup, dns: DNSChoice.Upstream, blockLocal: Bool) throws
    /// Opens the config page to the devices on exactly `hosts`, see `ConfigPageServing.readyHosts`.
    /// A start opens it nowhere.
    func setPage(_ hosts: [String])
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
    /// Called when `readyHosts` changes.
    var onChange: @MainActor () -> Void { get set }
    var onFailure: @MainActor (Error) -> Void { get set }
    var onRefused: @MainActor (_ client: String) -> Void { get set }
    /// Started, and not failed or stopped since.
    var running: Bool { get }
    /// Taking connections.
    var listening: Bool { get }
    /// The addresses whose listener is taking connections.
    var readyHosts: [String] { get }
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
    /// Whether a call, Siri or an alarm holds the audio now, or did since the last time this was
    /// asked. The second part counts a call that ended between two watcher rounds.
    func takeInterruption() -> Bool
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
    let speedHistory = SpeedHistory()
    /// The devices that have connected, in the order they first did.
    private(set) var wireGuardPeers: [WireGuardSetup.Peer] = [] { willSet { willChange() } }
    /// Behind the QR code in the Add a device sheet, see `WireGuardSetup.ready`. Only ever a saved one,
    /// and let in only while the add window is open, see `addWindowOpen`.
    private(set) var wireGuardReady: WireGuardSetup.Ready? { willSet { willChange() } }
    /// Why there's no QR code while the devices that have one still connect: making the next one couldn't be saved.
    private(set) var wireGuardReadyProblem: String? { willSet { willChange() } }
    /// Why the code for the next device can't be saved, logged once for each new reason.
    private var readyReason: String?
    /// The last reason WireGuard didn't start that went to the log, see `showProblem`.
    private var loggedProblem: String?
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
    /// The HTTP proxy as saved: on or off, paused, its limit (#78). Nil until it's first turned on.
    private(set) var proxy: WireGuardSetup.Proxy? { willSet { willChange() } }
    /// What the server says about the proxy, read with the speeds, and by the watcher in the background.
    private(set) var proxyStats = ProxyStats() { willSet { willChange() } }
    /// The server's starts, for `ProxyStats.run`.
    private var serverRuns = 0
    /// Turning the proxy on or off couldn't be saved, until a turn saves.
    private(set) var proxyProblem: String? { willSet { willChange() } }
    /// The addresses on the hotspot that answer a knock and aren't on WireGuard or the proxy (#109),
    /// in address order. Only while sharing on screen, see `knockNeighbors`.
    private(set) var notUsingTether: [String] = [] { willSet { willChange() } }
    /// Who was connected at the last read, for the notifications: the sampler's on screen, the
    /// watcher's in the background. Nothing on screen shows the watcher's, so it isn't published.
    var connectedNow: Set<String> { sceneActive ? wireGuardConnected : watchedConnected }
    /// The hotspot is on and WireGuard runs. `running` alone is only the hotspot.
    var sharing: Bool { running && wireGuardProblem == nil }
    /// Only the on-screen sampler publishes connections and speeds, so it runs only while the app is on screen.
    /// False in a launch from a Shortcuts action, which happens in the background.
    var sceneActive: Bool
    /// CallKit has a call on. The keep-alive sound plays again right after a call starts, so it can't
    /// say so itself (#191).
    var callOn: () -> Bool = { false }
    /// False until Continue on the Local Network screen: a knock, or answering the iPhone's name, could
    /// make iOS ask before it.
    var localNetworkIntroduced: () -> Bool = { true }

    private let devices: WireGuardDevices
    private let server: WireGuardServing
    private let keepAlive: KeepAliveSound
    private let page: ConfigPageServing
    private let hotspotAddress: () -> String?
    private let carrierIPv6Only: () -> Bool
    /// The setting in Settings > Sharing, read each round, so a change counts at once.
    private let idleStopAfter: () -> IdleStop.After
    /// Settings > Devices: where the server sends lookups to its own address, the DNS server every
    /// config names, read for each start and change, see `dnsChanged`.
    private let dns: () -> DNSChoice.Upstream
    /// Settings: whether the devices are kept out of the iPhone's local networks, read with `dns`.
    private let blockLocal: () -> Bool
    /// Where each device's data per month is saved, see `MonthlyUsage`. Nil keeps it in memory only.
    private let usageDefaults: UserDefaults?
    /// The day the counts and the limits start over (#187), read each time they're used, so a change
    /// in Settings counts at once.
    private let resetDay: () -> ResetDay
    /// Follows a time zone change while Tether runs for days on the silent sound: `.current` is a
    /// snapshot from launch (#163).
    private let calendar: Calendar
    private var monthlyUsage: MonthlyUsage
    /// When it was last saved, and whether a read has changed it since.
    private var usageSavedAt: Date?
    private var usageUnsaved = false
    private let now: () -> Date
    /// mDNS for the iPhone's name on IPv6, see `HostName`. Nil gives the devices the address itself.
    private let hostName: HostNamePublishing?
    /// What the cellular data has, like "pdp_ip0: IPv6, data line: LTE", read for the log when the
    /// hotspot goes away (#191).
    private let cellular: @MainActor () -> String
    private let log: @MainActor (String) -> Void
    private let knocker: HotspotKnocker
    /// What the knocks found so far, see `HotspotNeighbors`.
    private var neighbors = HotspotNeighbors()
    /// Goes up with each `forgetNeighbors`, so a round that was still knocking then is dropped.
    private var knockRun = 0

    /// When the hotspot went away, or Tether was last on screen since. Nil while the hotspot is on.
    /// A launch starts long past, so only opening Tether or Start Tether (`wake`) gives it the 10
    /// minutes. "Is Tether Sharing?" launches Tether in the background too, and only reports.
    private var waitingSince: Date? = .distantPast
    private var idleStop = IdleStop()
    /// The proxy's bytes at the last idle check, see `stopWhenIdle`.
    private var idleProxyTraffic: TrafficTotals?
    private var sampler = TrafficSampler()
    /// When each device last sent anything, for the config page (#63). Not published: it changes
    /// with every keepalive, and only the page reads it (#166).
    private var activity = PeerActivity()
    /// Who was connected at the watcher's last read in the background, see `readInBackground`.
    private var watchedConnected: Set<String> = []
    /// Whose tunnel was up at the last read, the sampler's or the watcher's, paused devices too, so a
    /// resume shows at once.
    private var tunnelsUp: Set<String> = []
    /// The one address `hotspotAddress` picked when the server started. The others come from it,
    /// see `boundHosts`.
    private var boundHost: String?
    /// The last reason `listenToo` couldn't listen on a new IPv6 address, so a retry every round logs it once.
    private var listenFailure: String?
    /// The carrier gives this iPhone IPv6 only, see `deviceHost`.
    private var onIPv6OnlyCarrier: Bool { willSet { willChange() } }
    /// Why the saved setup can't be used, see `checkSetup`.
    private var setupProblem: String?
    /// Why the server didn't start on the hotspot. It goes with the hotspot.
    private var startProblem: String?
    /// What the config page answers, see `pageResponse`.
    private var pageHandler = ConfigPageHandler()
    /// Clients the page refused that are in the log already, see `pageRefused`.
    private var refusedClients: Set<String> = []
    /// When the code behind Add a device works, by the clock, see `addWindowOpen`.
    private var addWindow = AddWindow()
    /// The ready device is on the server: the add window was open at the last `followAddWindow()`.
    private var readyLetIn = false
    /// The interface the iPhone's internet goes out through when it's a VPN's, like utun5, nil when
    /// it isn't, see `Interfaces.internetVPN`. Read each round and when the network changes.
    private(set) var vpnInterface: String? { willSet { willChange() } }
    /// Settings > Only share through a VPN is on and no VPN carries the internet, so the server lets
    /// no device through, nor the proxy, see `serverSetup`. Nothing saved changes: they're let through
    /// again as they were once a VPN is on.
    private(set) var blockedWithoutVPN = false { willSet { willChange() } }
    private let internetVPN: () -> String?
    /// `checkVPN` ran once, so `vpnInterface` is a reading and not the nil it starts as.
    private var vpnRead = false
    /// Settings > Only share through a VPN, read each time, like the idle stop.
    static let onlyThroughVPNKey = "sharing.onlyThroughVPN"
    /// The switch as `checkVPN` last read it, so it knows when it was turned on. Nil before the first read.
    private var onlyThroughVPNWas: Bool?
    private let onlyThroughVPN: () -> Bool

    init(devices: WireGuardDevices, server: WireGuardServing, keepAlive: KeepAliveSound, page: ConfigPageServing,
         sceneActive: Bool, hotspotAddress: @escaping () -> String?, carrierIPv6Only: @escaping () -> Bool = { false },
         idleStopAfter: @escaping () -> IdleStop.After = { .never }, dns: @escaping () -> DNSChoice.Upstream = { DNSChoice.defaultUpstream },
         blockLocal: @escaping () -> Bool = { false },
         usageDefaults: UserDefaults? = nil, calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = Date.init,
         resetDay: @escaping () -> ResetDay = { .default }, hostName: HostNamePublishing? = nil, cellular: @escaping @MainActor () -> String = { "" },
         knocker: HotspotKnocker = NetworkKnocker(),
         internetVPN: @escaping () -> String? = { nil }, onlyThroughVPN: @escaping () -> Bool = { false },
         log: @escaping @MainActor (String) -> Void = { _ in }) {
        self.devices = devices
        self.server = server
        self.keepAlive = keepAlive
        self.page = page
        self.sceneActive = sceneActive
        self.hotspotAddress = hotspotAddress
        self.carrierIPv6Only = carrierIPv6Only
        self.blockLocal = blockLocal
        self.idleStopAfter = idleStopAfter
        self.dns = dns
        self.usageDefaults = usageDefaults
        self.calendar = calendar
        self.resetDay = resetDay
        self.internetVPN = internetVPN
        self.onlyThroughVPN = onlyThroughVPN
        monthlyUsage = usageDefaults.map { MonthlyUsage.load(from: $0, resetDay: resetDay()) } ?? MonthlyUsage(resetDay: resetDay())
        onIPv6OnlyCarrier = carrierIPv6Only()
        self.now = now
        self.hostName = hostName
        self.cellular = cellular
        self.knocker = knocker
        self.log = log
        // A device on the name says something else once mDNS fails or answers again, see `newConfig`.
        hostName?.onChange = { [weak self] in self?.willChange() }
        publishSetup()
        showSetupProblem() // from launch, before any device joins the hotspot
        page.respond = { [weak self] request, client in self?.pageResponse(request, from: client) ?? ConfigPage.notFound }
        page.onChange = { [weak self] in self?.pageChanged() }
        page.onFailure = { [weak self] error in self?.pageFailed(error) }
        page.onRefused = { [weak self] client in self?.pageRefused(client) }
    }

    /// The first few, so a Mac outside the expected /64 shows in the log (#159), and a scan from the
    /// internet doesn't fill it.
    private func pageRefused(_ client: String) {
        guard refusedClients.count < 10, refusedClients.insert(client).inserted else { return }
        log("Config page: refused \(client), not on the hotspot")
    }

    /// One round of the watcher in `Model`.
    func watch() {
        syncWithHotspot()
        // On screen the sampler does this every second.
        if !sceneActive { readInBackground() }
        // Also with the hotspot off, so a device paused at its limit connects again when the count resets.
        checkLimits()
        stopWhenIdle()
    }

    /// The hotspot interface exists only while Personal Hotspot is on. This starts WireGuard when
    /// it appears and stops it when it goes away or changes, so it never listens anywhere else.
    func syncWithHotspot() {
        defer { followHostName() }
        checkSetup()
        // Before a start, which lets in what `serverSetup` says. Off screen with the switch off nothing
        // hangs on it, and `Model` still hears of a change from NWPathMonitor, so the round skips it.
        if !vpnRead || sceneActive || onlyThroughVPN() { checkVPN() }
        followAddWindow()
        let ipv6Only = carrierIPv6Only()
        if ipv6Only != onIPv6OnlyCarrier { onIPv6OnlyCarrier = ipv6Only }
        let hotspot = hotspotAddress()
        if running, hotspot != boundHost, !listenToo(on: hotspot) {
            let cellular = cellular()
            log("hotspot address gone or changed, stopping" + (cellular.isEmpty ? "" : " (\(cellular))"))
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
        speedHistory.reset()
        downSpeed = 0
        upSpeed = 0
        running = true
    }

    /// On a carrier that gives the iPhone IPv6 only, the hotspot comes back with 172.20.10.1 before
    /// its IPv6 address. Listening there too, on the same port, keeps the devices' sessions, where a
    /// restart dropped them all a second time (#219). Says whether this handled the change. Anything
    /// else, an address gone or a new IPv6 prefix, restarts.
    private func listenToo(on hotspot: String?) -> Bool {
        guard let hotspot, hotspot.contains(":"), let boundHost, !boundHost.contains(":"), server.running else { return false }
        let hosts = Self.hosts(for: hotspot)
        do {
            try server.listen(on: hosts)
        } catch {
            // A new IPv6 address can't take a socket for a moment. A restart would fail on it too and
            // drop every device, so the server keeps 172.20.10.1 and the next round tries again.
            let failure = "WireGuard: can't listen on \(hotspot) yet, tries again: \(error)"
            if failure != listenFailure { log(failure) }
            listenFailure = failure
            return true
        }
        listenFailure = nil
        willChange() // the QR code and the page's addresses follow the new address
        self.boundHost = hotspot
        page.start(hosts: hosts, port: ConfigPage.port)
        log("WireGuard on \(hosts.joined(separator: " and ")) port \(WireGuardSetup.port), the devices keep their sessions")
        publishSetup()
        return true
    }

    private func stopSharing() {
        server.stop()
        page.stop()
        pageHandler.forget()
        // What the devices used since the last read: a stopped server still reports what it carried.
        countUsage(server.snapshot())
        saveUsage()
        running = false
        startProblem = nil // the next hotspot gets a new try
        showProblem()
        followHostName() // now, not next round: after an idle stop iOS may suspend Tether first
    }

    /// Stops sharing once no device has been connected in the background for the set time, see
    /// `IdleStop`, and lets iOS suspend Tether at once, with no 10 minutes' wait. Opening Tether or
    /// Start Tether shares again, see `wake`.
    private func stopWhenIdle() {
        let after = idleStopAfter()
        let now = self.now()
        // A device on the proxy is using Tether too, but not one a paused proxy answers with 403. Only
        // data through it since the last check counts, not a connection open now: a Mac can hold a
        // tunnel open for push with nothing through it for hours (#286).
        // Nor one the proxy refuses for want of a VPN.
        let proxyMoved = proxy?.paused == nil && !blockedWithoutVPN && (idleProxyTraffic.map { $0 != proxyStats.traffic } ?? false)
        idleProxyTraffic = proxyStats.traffic
        let connected = !connectedNow.isEmpty || proxyMoved
        guard idleStop.check(sharing: sharing, connected: connected, onScreen: sceneActive, after: after, now: now) else {
            return
        }
        log("no device connected for \(after.spelledOut), stopping until Tether is opened")
        stop(IdleStopped(at: now, after: after))
    }

    /// Plays the silent sound while the hotspot is on, and for a while after it goes, see
    /// `KeepAlivePolicy`. Once it stops, iOS suspends Tether, and it starts again when opened.
    private func keepAliveWhileSharing(hotspot: Bool) {
        let now = self.now()
        // On screen the wait keeps starting again, so the sound never stops there, and the 10 minutes
        // run from leaving the screen, to turn on Personal Hotspot in Settings, say.
        // A call can take the hotspot away for as long as it lasts, so the 10 minutes run from its
        // end too. Before, a long call left Tether suspended and its devices cut off until someone
        // opened it (#191). Not after an idle stop, which means to stop.
        let call = (keepAlive.takeInterruption() || keepAlive.playing && callOn()) && idleStopped == nil
        if hotspot { waitingSince = nil } else if sceneActive || call || waitingSince == nil { waitingSince = now }
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
        } else {
            publishReadyProblem() // a retry that failed, maybe for another reason
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
            try server.start(hosts: hosts, setup: serverSetup, dns: dns(), blockLocal: blockLocal(), port: WireGuardSetup.port)
            serverRuns += 1
            page.start(hosts: hosts, port: ConfigPage.port)
            startProblem = nil
            showProblem()
            log("WireGuard on \(hosts.joined(separator: " and ")) port \(WireGuardSetup.port), \(wireGuardPeers.count) devices")
        } catch {
            // The error goes to the log, see `showProblem`: on screen it says what to do.
            startProblem = Self.problem(starting: error)
            showProblem(because: error)
        }
    }

    /// Why WireGuard can't start, for `wireGuardProblem`. Another socket on 51820 is the one reason a
    /// person can do something about: a WireGuard tunnel on this iPhone with ListenPort 51820, say.
    static func problem(starting error: Error) -> String {
        guard "\(error)".contains("address already in use") else {
            return "It couldn't start. Tether tries again by itself. If this stays, share the log from Settings."
        }
        return "Something else on this iPhone is using port \(WireGuardSetup.port). Tether tries again by itself. "
            + "If this stays, turn off other VPN or WireGuard tunnels on this iPhone, or restart it."
    }

    /// Why the saved setup can't be used, for `wireGuardProblem`.
    private static func problem(with error: Error) -> String {
        switch error {
        case is WireGuardDevices.Unreadable: "Its saved keys can't be read. Start over with new keys to use it."
        case is WireGuardDevices.Unsaved: "Its new keys can't be saved. If this stays, share the log from Settings."
        default: "Its keys can't be read yet. Unlock this iPhone once."
        }
    }

    /// The setup's problem comes first: until it's solved, the server can't start anyway. Each reason
    /// is logged once, not on every try. By the error, not the text on screen, which is the same for
    /// different reasons.
    private func showProblem(because error: Error? = nil) {
        let problem = setupProblem ?? startProblem
        if problem == nil {
            loggedProblem = nil
        } else if let error, "\(error)" != loggedProblem {
            loggedProblem = "\(error)"
            log("WireGuard not started: \(error)")
        }
        if problem != wireGuardProblem { wireGuardProblem = problem }
        if !sharing { forgetNeighbors() } // also when sharing stops, which comes through here
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
        log("Tether on screen") // so a shared log shows whether a recovery waited for this (#231)
        // The background's last read, not the list from before the app left, until the sampler reads.
        if wireGuardConnected != watchedConnected { wireGuardConnected = watchedConnected }
        wake()
    }

    func leftScreen() {
        sceneActive = false
        log("Tether left the screen")
        addWindow.leftScreen(now: now())
        sampler.reset() // or the first speed back on screen averages the whole time away
        speedHistory.reset()
        forgetNeighbors()
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
        // A device whose first handshake came since the last read is listed before its code goes, but
        // only one from before the window ended: the next read can be 20 s later in the background (#161).
        if !open, running, server.running {
            claimReady(server.snapshot().peers, handshakeBy: addWindow.ends)
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
    /// With Only share through a VPN on and no VPN, all of them paused, and the proxy too.
    private var serverSetup: WireGuardSetup {
        var setup = devices.setup
        if !readyLetIn { setup.ready = nil }
        // The ready one stays, paused like the rest: left out, a device scanning the code now would
        // look like one whose config no longer works.
        return blockedWithoutVPN ? Self.pausingAll(setup) : setup
    }

    /// The setup with every device, the ready one and the proxy paused.
    private static func pausingAll(_ setup: WireGuardSetup) -> WireGuardSetup {
        var setup = setup
        if setup.ready?.paused == nil { setup.ready?.paused = .byYou }
        for i in setup.peers.indices where setup.peers[i].paused == nil { setup.peers[i].paused = .byYou }
        if setup.proxy?.paused == nil { setup.proxy?.paused = .byYou }
        return setup
    }

    /// Reads whether the internet goes out through a VPN, and with Only share through a VPN on, lets
    /// the devices through or not by it. Each watcher round, and when iOS says the network changed.
    func checkVPN() {
        vpnRead = true
        let vpn = internetVPN()
        if vpn != vpnInterface {
            log(vpn.map { "the internet goes out through a VPN (\($0))" } ?? "the internet goes out without a VPN")
            vpnInterface = vpn
        }
        let on = onlyThroughVPN()
        let turnedOn = on && onlyThroughVPNWas == false
        onlyThroughVPNWas = on
        let blocked = on && vpn == nil
        guard blocked != blockedWithoutVPN else {
            if turnedOn, !blocked, server.running { endConnectionsFromBeforeTheVPN() }
            return
        }
        blockedWithoutVPN = blocked
        log(blocked ? "no VPN, so no device gets through until one is on" : "a VPN is on, devices get through again")
        if server.running { wireGuardPeersChanged() }
    }

    /// The switch was turned on with a VPN already on. What the devices and the proxy have open may
    /// have opened before the VPN came up, and iOS keeps a connection where it opened, so it would go
    /// on outside the VPN. Pausing everything for a moment ends it, as a VPN that goes does.
    private func endConnectionsFromBeforeTheVPN() {
        log("only through a VPN: ending what was open before, so it opens again through the VPN")
        do {
            try server.setPeers(Self.pausingAll(serverSetup), dns: dns(), blockLocal: blockLocal())
        } catch {
            log("WireGuard devices: \(error)")
        }
        wireGuardPeersChanged()
    }

    /// For the Shortcuts actions. Off screen the sampler doesn't run, so the connected devices are read now.
    func shortcutState() -> ShortcutReply.State {
        var connected = wireGuardConnected
        var proxyStats = proxyStats
        if running, server.running {
            let snapshot = server.snapshot()
            connected = unpaused(snapshot.connected)
            proxyStats = snapshot.proxy
        }
        let proxyInUse = proxy.map { ProxyStatus($0, stats: proxyStats, hotspotOn: running).inUse } ?? false
        return ShortcutReply.State(running: running, connected: connected.count, problem: wireGuardProblem, proxyInUse: proxyInUse,
                                   idleStopped: idleStopped != nil, stoppedByYou: idleStopped?.byYou == true,
                                   keptAlive: !running || keepAlive.sounding, blockedWithoutVPN: blockedWithoutVPN)
    }

    /// On screen, or the sound sounds while the hotspot is on: without it iOS suspends Tether soon,
    /// so it isn't sharing for long (#164), and the widgets mustn't say it is.
    var staysRunning: Bool { !running || heldAwake }

    /// For the Live Activity: not stopped, whether or not the sound sounds this moment (a call takes
    /// it for a while), so it lasts from a start to a stop and through a wait for the hotspot.
    var up: Bool { idleStopped == nil && (running || heldAwake) }

    /// For the widgets: sharing, or waiting for the hotspot, and staying so: on screen, or with the
    /// sound keeping Tether running.
    var awake: Bool { idleStopped == nil && heldAwake }

    /// What keeps iOS from suspending Tether in what it does now, the rule the three above share: on
    /// screen, or the sound, sounding while the hotspot is on, or at least playing while Tether waits
    /// for it (a call can take the sound for a while then).
    private var heldAwake: Bool { sceneActive || (running ? keepAlive.sounding : keepAlive.playing) }

    /// The connected devices for the widgets, in the list's order, by the latest read.
    var connectedPeers: [WireGuardSetup.Peer] {
        let connected = connectedNow
        return wireGuardPeers.filter { connected.contains($0.address) }
    }

    /// Stop on a widget or in Control Center: stops sharing now, as the idle stop does, and stays
    /// stopped with the hotspot on until Tether is opened or started again (`wake`). The sound stops,
    /// so iOS suspends Tether. Says whether it was sharing. Not while Tether is on screen, where
    /// nothing stops it but the hotspot, like the idle stop: opening it is what starts it again.
    @discardableResult
    func stopNow() -> Bool {
        guard !sceneActive, idleStopped == nil else { return false }
        let was = running
        log("stopped from a widget, until Tether is opened or started")
        stop(IdleStopped(at: now(), after: idleStopAfter(), byYou: true))
        return was
    }

    /// Stops sharing and the sound, and stays stopped with the hotspot on until `wake`.
    private func stop(_ stopped: IdleStopped) {
        idleStopped = stopped
        if running { stopSharing() }
        // Nobody is connected to a stopped server, and no later round may get to say so: iOS suspends
        // Tether once the sound stops, and the widgets are told right after this.
        watchedConnected = []
        if !wireGuardConnected.isEmpty { wireGuardConnected = [] }
        waitingSince = .distantPast // so the next rounds don't start the sound again, see keepAliveWhileSharing
        keepAlive.stop()
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
    /// the screen showed it, still connects again when the count resets.
    /// The proxy is paused the same way, by its id.
    func pauseWireGuardDevice(_ id: WireGuardSetup.Peer.ID) {
        guard devices.setup.pause(of: id) == nil else { return }
        pause(id, .byYou, problem: "The device couldn't be paused.")
    }

    /// A device paused at its limit, resumed by hand while it's still at it, goes over it until the
    /// count resets, see `checkLimits`. One the count already let go (the reset, before a read caught
    /// up) doesn't.
    func resumeWireGuardDevice(_ id: WireGuardSetup.Peer.ID) {
        let atLimit = devices.setup.pause(of: id) == .atLimit && devices.setup.limit(of: id).map { usage(of: id).thisMonth.total >= $0 } == true
        guard pause(id, nil, problem: "The device couldn't be resumed."), atLimit else { return }
        monthlyUsage.markResumedOver(id, at: now(), calendar: calendar)
        usageUnsaved = true
    }

    /// Its data limit per month, or nil for none. It counts at once: lowered below what the device used
    /// this month, the device is paused, raised above it or removed, a device paused at it resumes. A
    /// resume or a notice for the old limit doesn't hold for the new one. False when it couldn't be
    /// saved, and the device's screen says so. The proxy's too, by its id.
    @discardableResult
    func setLimit(_ id: WireGuardSetup.Peer.ID, _ limit: UInt64?) -> Bool {
        // The same limit picked again changes nothing, so a resume over it still holds.
        if devices.setup.limit(of: id) == limit { return true }
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

    /// Turns the HTTP proxy on or off (#78). Add a device turns it on, its screen off. Go listens from
    /// the next change, which this sends, and the stats are read at once, for where it listens. False
    /// when it couldn't be saved: then nothing changes, and `proxyProblem` says so.
    @discardableResult
    func setProxy(on: Bool) -> Bool {
        let current = devices.setup.proxy
        // Already so: Add a device opens on it again, say. On again still resumes a pause by you.
        if (current?.on ?? false) == on, !(on && current?.paused == .byYou) {
            if proxyProblem != nil { proxyProblem = nil }
            return true
        }
        guard devices.proxy(on: on) else {
            log("Proxy: turning it \(on ? "on" : "off") couldn't be saved")
            proxyProblem = on ? "The proxy couldn't be turned on." : "The proxy couldn't be turned off."
            return false
        }
        if proxyProblem != nil { proxyProblem = nil }
        log("Proxy: turned \(on ? "on" : "off")")
        wireGuardPeersChanged()
        publishProxyStats(server.snapshot().proxy)
        return true
    }

    /// The server's counters for the Diagnostics screen, read when the screen asks: published, they
    /// would redraw every view that watches the model each second (#166).
    var serverDiagnostics: ServerDiagnostics { server.snapshot().diagnostics }

    private func publishProxyStats(_ stats: ProxyStats) {
        var stats = stats
        stats.run = serverRuns
        if stats != proxyStats { proxyStats = stats }
    }

    /// Resumed at its limit this period, so it's over it until the count resets.
    func overLimit(_ id: WireGuardSetup.Peer.ID) -> Bool {
        followResetDay()
        return monthlyUsage.resumedOver(id, at: now(), calendar: calendar)
    }

    /// When the counts and the limits start over, on the session's clock, see `MonthlyUsage.nextReset`.
    var nextReset: Date {
        followResetDay()
        return monthlyUsage.nextReset(at: now(), calendar: calendar)
    }

    /// The running count, from its start to `nextReset`, for the screens' "since Nov 15", see
    /// `Format.period`.
    var period: DateInterval {
        followResetDay()
        return monthlyUsage.period(at: now(), calendar: calendar)
    }

    /// The period before `period`, for the device screen's row, see `Format.lastPeriod`.
    var lastPeriod: DateInterval {
        followResetDay()
        return monthlyUsage.lastPeriod(at: now(), calendar: calendar)
    }

    /// Settings changed the reset day: followed now, so the screens show the new dates when Settings
    /// closes, not at the next read.
    func resetDayChanged() {
        followResetDay()
        willChange()
    }

    /// A new reset day counts from now, see `MonthlyUsage.setResetDay`. Saved at once, so a relaunch
    /// doesn't move the change to its own time.
    private func followResetDay() {
        let day = resetDay()
        guard day != monthlyUsage.resetDay else { return }
        monthlyUsage.setResetDay(day, at: now(), calendar: calendar)
        usageUnsaved = true
        saveUsage()
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
    /// A device kept out for want of a VPN still counts: it's there and gets through by itself once a
    /// VPN is on, so it stays in the list, holds the idle stop off, and Add a device can finish with it.
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
        if let ip = PeerStats.address(client), IPv4Address(ip) != nil, boundHosts.contains(Hotspot.host) { return Hotspot.host }
        return deviceHost
    }

    /// The iPhone's name for a client that reached the page over IPv6, while mDNS answers it with the
    /// address Tether listens on: the page then offers a Mac a config for it, which survives a new
    /// address (#65). Every other config keeps the address. An iPad's Safari says it's a Mac, so the
    /// page can't tell them apart, and whether WireGuard on an iPhone or iPad finds a .local name is
    /// still to be tried. Over IPv4, 172.20.10.1 never changes anyway.
    private func name(for client: String) -> String? {
        guard host(reachedFrom: client)?.contains(":") == true else { return nil }
        return publishedName
    }

    /// The IPv6 address Tether listens on, for the name. Nil without the hotspot or on IPv4.
    private var listeningIPv6: String? {
        guard running, server.running, let boundHost, boundHost.contains(":") else { return nil }
        return boundHost
    }

    /// The iPhone's name, from the server's key. Nil until the keys are read.
    private var name: String? { devices.loaded ? HostName.name(for: devices.setup.serverPublicKey) : nil }

    /// The name, while mDNS answers it with the address Tether listens on now.
    private var publishedName: String? {
        guard let name, let listeningIPv6, hostName?.published == HostNameRecord(name: name, address: listeningIPv6) else { return nil }
        return name
    }

    /// Each round: the name answers with the IPv6 address Tether listens on, and goes with it.
    private func followHostName() {
        guard let hostName, let name, localNetworkIntroduced() else { return }
        hostName.publish(name, at: listeningIPv6)
    }

    /// The device's config points at an address Tether doesn't listen on, so it can't connect until
    /// it's added again (#65). That happens only to the IPv6 address of a carrier that gives the
    /// iPhone IPv6 only, which comes with each cellular session, or goes when the carrier gives it
    /// IPv4 again. Tether always listens on 172.20.10.1, see `boundHosts`. While the hotspot
    /// is off, or for a device saved before Tether kept where it points, it's not known, and no. A
    /// device that is connected reaches Tether, whatever is saved, see `rememberHosts`. A config
    /// with the iPhone's name follows a new IPv6 address. It needs a new one once the carrier gives
    /// IPv4 again, since the name has IPv6 only (see `MDNSHostName`), and while mDNS can't answer the
    /// name: taken by another device, or refused. A new config from the page then has the address.
    func needsNewConfig(_ peer: WireGuardSetup.Peer) -> Bool { newConfig(peer) != nil }

    /// Why a device needs a new config, which its row and screen say, see `needsNewConfig`.
    enum NewConfig: Equatable {
        /// Its config points at an address, or a name, this iPhone doesn't have now.
        case oldAddress
        /// Its config uses this iPhone's name, which mDNS isn't answering on the hotspot.
        case nameNotAnswered
    }

    func newConfig(_ peer: WireGuardSetup.Peer) -> NewConfig? {
        guard running, let host = peer.host, !connectedNow.contains(peer.address) else { return nil }
        if HostName.isName(host) {
            guard host == name else { return .oldAddress }
            guard listeningIPv6 != nil else { return onIPv6OnlyCarrier ? nil : .nameNotAnswered }
            return hostName.map { $0.failure == nil } == true ? nil : .nameNotAnswered
        }
        return boundHosts.contains(host) ? nil : .oldAddress
    }

    /// The QR code's config. None while there's no `deviceHost`, so no config is made that can't connect.
    func wireGuardConfig(for ready: WireGuardSetup.Ready) -> String? {
        wireGuardConfig(for: ready, host: deviceHost)
    }

    private func wireGuardConfig(for ready: WireGuardSetup.Ready, host: String?) -> String? {
        host.map { devices.setup.clientConfig(for: ready, host: $0) }
    }

    /// A page that listens again logs its next failure. The devices reach the page's port only where
    /// Tether's page listens: where it failed, another app may have the port (#27). Each WireGuard
    /// start is followed by a page start, which says again once it listens.
    private func pageChanged() {
        if page.listening { pageHandler.listening() }
        server.setPage(page.readyHosts)
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
        // Read now: only the on-screen sampler keeps the knock, and the counts can be 20 s old.
        let snap = server.snapshot()
        activity.read(snap.peers, at: now)
        let live = unpaused(Set(snap.peers.keys)).filter { activity.live($0, at: now) }
        let named = name(for: client)
        let inputs = ConfigPageHandler.Inputs(letIn: readyLetIn, onScreen: sceneActive, ready: ready, host: host,
                                              config: ready.flatMap { wireGuardConfig(for: $0, host: host) },
                                              stale: snap.recentStale, hosts: boundHosts, now: now,
                                              live: live.compactMap { PeerStats.address(snap.peers[$0]?.endpoint) },
                                              name: named, nameConfig: ready.flatMap { wireGuardConfig(for: $0, host: named) })
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
            pageHandler.downloaded(response, by: client, forMac: request == .macConfig, at: now)
            return response
        }
    }

    /// On a memory warning.
    func freeMemory() {
        server.freeMemory()
    }

    private func publishSetup() {
        if devices.setup.peers != wireGuardPeers { wireGuardPeers = devices.setup.peers }
        if devices.setup.proxy != proxy { proxy = devices.setup.proxy }
        // Only from a setup that was read: a locked Keychain lists no devices, and that isn't a removal.
        if devices.loaded {
            let before = monthlyUsage
            monthlyUsage.keep(only: Set(devices.setup.peers.map(\.id) + [devices.setup.ready?.id, devices.setup.proxy?.id].compactMap { $0 }))
            if monthlyUsage != before { usageUnsaved = true }
        }
        if devices.setup.ready != wireGuardReady { wireGuardReady = devices.setup.ready }
        publishReadyProblem()
    }

    /// Why the next code can't be saved: on screen in plain words, and each new reason, a Keychain
    /// code say, once in the log. Also after a failed retry, which changes nothing else (#190).
    private func publishReadyProblem() {
        let reason = devices.readyError.map { "\($0)" }
        if reason != readyReason {
            readyReason = reason
            if let reason { log("WireGuard: the code for the next device can't be saved: \(reason)") }
        }
        let readyProblem = reason.map { _ in "The code for the next device can't be saved. Tether tries again by itself. If this stays, share the log from Settings." }
        if readyProblem != wireGuardReadyProblem { wireGuardReadyProblem = readyProblem }
    }

    /// The server lets in exactly the saved devices, and the ready one while the add window is open. If
    /// it refuses the new list, it starts again with the saved setup, and a start that fails leaves it
    /// stopped: a removed device is never let in, the problem shows, and the watcher tries again.
    private func wireGuardPeersChanged() {
        devices.prepareReady() // a removal on a full subnet makes room for the QR code
        publishSetup()
        do {
            try server.setPeers(serverSetup, dns: dns(), blockLocal: blockLocal())
        } catch {
            log("WireGuard devices: \(error), restarting")
            // Never left running with the list from before: it may let in what this one keeps out.
            guard running, let boundHost, devices.loaded else { return server.stop() }
            startWireGuard(on: boundHost)
        }
    }

    /// Settings > Devices changed. Every device whose config names Tether's own address asks the new
    /// choice from its next lookup (#121).
    func dnsChanged() {
        wireGuardPeersChanged()
    }

    /// Settings > local networks changed. Blocking them closes what the devices have open there (#230).
    func localNetworksChanged() {
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
            speedHistory.reset()
            if downSpeed != 0 { downSpeed = 0 }
            if upSpeed != 0 { upSpeed = 0 }
            tunnelsUp = []
            if !wireGuardConnected.isEmpty { wireGuardConnected = [] }
            let snap = server.snapshot() // a stopped server answers with what each device used
            if snap.peers != wireGuardPeerStats { wireGuardPeerStats = snap.peers }
            publishProxyStats(snap.proxy)
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
        publishProxyStats(snap.proxy)
        absorb(snap.peers)
        countUsage(snap)
        guard let speeds = sampler.sample(snap.totals, at: now) else { return } // nothing to compare with yet
        // Keep zero and unchanged readings too, so an idle graph still moves to the left.
        speedHistory.append(SpeedSample(at: now, up: speeds.up, down: speeds.down))
        // Only a change: every publish redraws every view that watches the model, each second (#166).
        if speeds.up != upSpeed { upSpeed = speeds.up }
        if speeds.down != downSpeed { downSpeed = speeds.down }
    }

    /// What each read of who is connected does, on screen (the sampler) or off (the watcher): a
    /// device that connected with the QR code is listed, and each connected device's config is
    /// known to point where Tether listens. Paused devices too: their tunnels reach Tether. Each
    /// device's count goes to `activity`.
    private func absorb(_ peers: [String: PeerStats]) {
        claimReady(peers)
        rememberHosts(peers)
        activity.read(peers, at: now())
    }

    /// A device that connected with the QR code is listed, and the code changes for the next one.
    /// Not saved means not claimed: the next check tries again. A code that isn't on the server can't
    /// have connected, whatever an older read says.
    private func claimReady(_ peers: [String: PeerStats], handshakeBy end: Date? = nil) {
        guard readyLetIn, let ready = wireGuardReady, let reached = peers[ready.address], reached.connected,
              // Handshake times come in whole seconds, so one in the window's last second can't be told
              // from one just after it: only an earlier second counts.
              end == nil || reached.lastHandshake.map { $0 < end!.wholeSecondsDown } ?? true,
              let host = host(reachedFrom: reached.endpoint),
              devices.claimReady(address: ready.address, host: host) else { return }
        log("WireGuard: a new device connected with the QR code")
        wireGuardPeersChanged()
    }

    /// A device that is connected reaches Tether where its handshake came to, so its config points
    /// there, or at a name that leads there. Saved for a device saved before Tether kept where it
    /// points, and for one whose config was changed by hand to the new address. Not saved means the
    /// next read tries again. A device on the iPhone's name that reached the IPv6 address keeps the
    /// name: that's where its config points.
    private func rememberHosts(_ peers: [String: PeerStats]) {
        guard running else { return }
        let onName = Set(devices.setup.peers.filter { $0.host.map(HostName.isName) == true }.map(\.address))
        var reached: [String: Set<String>] = [:]
        for (address, stats) in peers where stats.connected {
            guard let host = host(reachedFrom: stats.endpoint), !(onName.contains(address) && host.contains(":")) else { continue }
            reached[host, default: []].insert(address)
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
            publishProxyStats(ProxyStats(traffic: proxyStats.traffic))
            return
        }
        let snap = server.snapshot()
        tunnelsUp = snap.connected
        watchedConnected = unpaused(snap.connected)
        publishProxyStats(snap.proxy) // for the idle stop
        absorb(snap.peers)
        countUsage(snap)
    }

    // MARK: Devices not using Tether (#109)

    /// One round of the knock, every `HotspotNeighbors.every` while on screen, see `Model`. The knock
    /// waits up to `HotspotNeighbors.timeout` off the main actor, and a round that sharing stopping or
    /// Tether leaving the screen overtook is dropped, even if it's back on screen by then, and so is
    /// one a newer round overtook: coming on screen at launch starts the loop a second time.
    func knockNeighbors() async {
        guard sharing, sceneActive, localNetworkIntroduced() else { return forgetNeighbors() }
        knockRun += 1
        let run = knockRun
        let knocks = await knocker.knock(HotspotNeighbors.addresses, ports: HotspotNeighbors.ports,
                                         timeout: HotspotNeighbors.timeout)
        guard run == knockRun else { return }
        neighborsAnswered(knocks)
    }

    /// Adds a round of knocks and publishes who isn't using Tether, only when that changed: every
    /// round would redraw the screen otherwise (#166). The demos call it with their own knocks.
    func neighborsAnswered(_ knocks: [HotspotKnock]) {
        guard sharing, sceneActive else { return forgetNeighbors() }
        let now = self.now()
        neighbors.record(knocks, at: now)
        // Go names the proxy's devices without a time, the ones it served in the last 2 minutes
        // (servedFor in proxy.go) or that still have a connection open, so each counts as served now.
        // A device then counts as using Tether while Go lists it, and stops 2 minutes after its last
        // page and connection rather than the 3 minutes of `usingWithin`: close enough, with no
        // times of its own to keep here.
        let proxyClients = Dictionary(proxyStats.served.map { ($0, now) }, uniquingKeysWith: { a, _ in a })
        let list = neighbors.notUsingTether(wireGuard: wireGuardPeerStats, proxyClients: proxyClients, now: now)
        if list != notUsingTether { notUsingTether = list }
    }

    /// Sharing stopped or Tether left the screen: the list goes, and the next round starts from nothing.
    private func forgetNeighbors() {
        knockRun += 1
        neighbors = HotspotNeighbors()
        if !notUsingTether.isEmpty { notUsingTether = [] }
    }

    // MARK: Data per month

    /// What the device used this month and last, as of now, see `MonthlyUsage`.
    func usage(of id: WireGuardSetup.Peer.ID) -> MonthlyUsage.Usage {
        followResetDay()
        return monthlyUsage.of(id, at: now(), calendar: calendar)
    }

    /// The device's last handshake, kept through restarts and relaunches (#73). Nil for never, and for
    /// a device that hasn't connected since the version that started keeping it.
    func lastConnected(of id: WireGuardSetup.Peer.ID) -> Date? { monthlyUsage.lastConnected(id) }

    /// Where a connected device's last handshake came from, the address alone, for its screen (#73).
    /// Nil while it isn't connected, a paused one included, and while the server doesn't say.
    func connectsFrom(of id: WireGuardSetup.Peer.ID) -> String? {
        guard let peer = devices.setup.peers.first(where: { $0.id == id }), wireGuardConnected.contains(peer.address) else { return nil }
        return PeerStats.address(wireGuardPeerStats[peer.address]?.endpoint)
    }

    /// Adds what each device's counters grew by to this month, the proxy's too, and saves at most once
    /// a minute. A crash loses up to that minute, never counts anything twice.
    private func countUsage(_ snap: ServerSnapshot) {
        var ids: [String: WireGuardSetup.Peer.ID] = [:]
        for peer in devices.setup.peers { ids[peer.address] = peer.id }
        if let ready = devices.setup.ready { ids[ready.address] = ready.id }
        var counts: [WireGuardSetup.Peer.ID: TrafficTotals] = [:]
        var handshakes: [WireGuardSetup.Peer.ID: Date] = [:]
        for (address, stats) in snap.peers {
            guard let id = ids[address] else { continue }
            counts[id] = stats.traffic
            handshakes[id] = stats.lastHandshake
        }
        if let proxy = devices.setup.proxy { counts[proxy.id] = snap.proxy.traffic }
        let paused = Set(devices.setup.peers.filter { $0.paused != nil }.map(\.id))
        followResetDay()
        let before = monthlyUsage
        let now = self.now()
        monthlyUsage.record(counts, handshakes: handshakes, paused: paused, at: now, calendar: calendar)
        if monthlyUsage != before { usageUnsaved = true }
        checkLimits()
        if usageSavedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true { saveUsage() }
    }

    /// Each device's limit against what it used this month, after every read: at 90% it's told once,
    /// at its limit it's paused and told, unless it was resumed at its limit this month. A device paused
    /// at its limit connects again once it's under it: when the count resets, or with a higher limit or none. A
    /// pause or resume that can't be saved is tried again at the next read, and only a saved one is told.
    private func checkLimits() {
        guard devices.loaded else { return }
        followResetDay()
        let now = self.now()
        var changed = false
        // The proxy goes by the same rules, named "Proxy" in the notifications.
        var limited = devices.setup.peers.map { (id: $0.id, name: $0.name, paused: $0.paused, limit: $0.limit) }
        if let proxy = devices.setup.proxy { limited.append((proxy.id, ProxyStatus.name, proxy.paused, proxy.limit)) }
        for peer in limited {
            let used = monthlyUsage.of(peer.id, at: now, calendar: calendar).thisMonth.total
            switch (peer.paused, peer.limit) {
            case (.atLimit?, nil):
                changed = devices.pause(peer.id, nil) || changed
            case let (.atLimit?, limit?) where used < limit:
                changed = devices.pause(peer.id, nil) || changed
            case let (nil, limit?) where used >= limit && !monthlyUsage.resumedOver(peer.id, at: now, calendar: calendar):
                guard devices.pause(peer.id, .atLimit) else { continue }
                changed = true
                log("WireGuard: a device reached its limit and is paused until the count resets")
                alert(peer.id, peer.name, .reached, used: used, limit: limit, now: now)
            case let (nil, limit?) where used < limit && used >= limit / 10 * 9 && !monthlyUsage.nearTold(peer.id, at: now, calendar: calendar):
                monthlyUsage.markNearTold(peer.id, at: now, calendar: calendar)
                usageUnsaved = true
                alert(peer.id, peer.name, .near, used: used, limit: limit, now: now)
            default:
                break
            }
        }
        if changed {
            wireGuardPeersChanged()
            publishConnected()
        }
    }

    private func alert(_ id: WireGuardSetup.Peer.ID, _ name: String, _ kind: LimitAlert.Kind, used: UInt64, limit: UInt64, now: Date) {
        let alert = LimitAlert(device: id, name: name, kind: kind, used: used, limit: limit, period: period,
                               proxy: id == devices.setup.proxy?.id)
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

private extension Date {
    /// This time with the fraction of a second dropped.
    var wholeSecondsDown: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
