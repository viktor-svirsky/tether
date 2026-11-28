import Foundation

/// What a device's row on the main screen and its own screen say about it. Foundation only, so
/// `swift test` covers the words.
enum DeviceStatus: Equatable {
    case connected
    case notConnected
    case paused(WireGuardSetup.Pause)
    /// Its tunnel is up, but Only share through a VPN keeps it out while no VPN is on (H1), or while
    /// the VPN carries only this family. No live dot: nothing gets through.
    case keptOut(onlyFamily: Interfaces.Family?)

    /// Paused comes first: a paused device's tunnel can still be up, but nothing gets through. A
    /// connected one is kept out while `keptOut`, see `HotspotSession.blockedWithoutVPN`. Pass
    /// `onlyFamily` (`Model.vpnOnlyFamily`) with it, so the words say which VPN is missing.
    init(_ peer: WireGuardSetup.Peer, connected: Set<String>, keptOut: Bool, onlyFamily: Interfaces.Family? = nil) {
        if let pause = peer.paused {
            self = .paused(pause)
        } else if !connected.contains(peer.address) {
            self = .notConnected
        } else {
            self = keptOut ? .keptOut(onlyFamily: onlyFamily) : .connected
        }
    }

    /// The row's word. A timed pause says until when (#312), as of `now`. A connected device near or
    /// over its limit says so (M2), see `LimitStanding`.
    func label(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .current,
               standing: LimitStanding = .under) -> String {
        switch self {
        case .connected:
            switch standing {
            case .under: "Connected"
            case .near: "Connected, near its limit"
            case .over: "Connected, over its limit"
            }
        case .notConnected: Copy.notConnected
        case let .paused(pause): pause.title(now: now, calendar: calendar, locale: locale)
        case let .keptOut(family): VPNText.keptOutRow(onlyFamily: family)
        }
    }

    var label: String { label() }

    /// The first line on its screen: the row's word, or what paused it.
    func title(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .current) -> String {
        switch self {
        case let .paused(pause): pause.title(now: now, calendar: calendar, locale: locale)
        case .keptOut: Copy.keptOutTitle
        default: label(now: now, calendar: calendar, locale: locale)
        }
    }

    var title: String { title() }

    /// The line under the title on its screen, for a paused or kept out device only. `resets` is the
    /// day the count starts over, like "December 1", and `period` the running count, see `Format.period`.
    func detail(resets: String, period: String) -> String? {
        switch self {
        case let .paused(pause): pause.detail(resets: resets, period: period)
        case let .keptOut(family): VPNText.keptOutDetail(onlyFamily: family)
        default: nil
        }
    }
}

/// Where a device's or the proxy's use this period stands against its data limit (M2), for its row:
/// near from 90%, the rule `LimitRules` tells at, and over once it used all of it, which a device
/// does only after Resume at its limit, see `HotspotSession.overLimit`.
enum LimitStanding: Equatable {
    case under, near, over

    init(used: UInt64, limit: UInt64?) {
        guard let limit else {
            self = .under
            return
        }
        self = used >= limit ? .over : used >= limit / 10 * 9 ? .near : .under
    }
}

extension WireGuardSetup.Pause {
    /// When a timed pause ends, nil for the others.
    var until: Date? {
        if case let .until(end) = self { end } else { nil }
    }

    func title(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .current) -> String {
        switch self {
        case .byYou: "Paused"
        case .atLimit: "Paused at its limit"
        case let .until(end): "Paused until \(Format.until(end, now: now, calendar: calendar, locale: locale))"
        }
    }

    func detail(resets: String, period: String) -> String {
        switch self {
        case .byYou: "It can't connect until you resume it."
        case .atLimit: "It used its data \(period). It connects again on \(resets), or when you resume it."
        case .until: "It connects again then, or when you resume it."
        }
    }
}

/// What the proxy's row on the main screen and its own screen say about it (#78), like `DeviceStatus`
/// for a device: paused, or how many connections the devices on it have open.
struct ProxyStatus: Equatable {
    /// Its row's name, and its name in a limit notification.
    static let name = "Proxy"

    enum State: Equatable {
        case paused(WireGuardSetup.Pause)
        case open(Int)
        /// It doesn't listen yet: no device is on the hotspot, which iOS makes look like the hotspot off.
        case waiting
        /// It has an address to listen on and can't, so no device gets through.
        case cantListen
        /// Only share through a VPN keeps its devices out while no VPN is on (H1).
        case keptOut(onlyFamily: Interfaces.Family?)
    }

    let state: State

    /// Paused comes first, as for a device: its devices' connections are closed.
    /// Pass `onlyFamily` (`Model.vpnOnlyFamily`) with `keptOut`, as for a device.
    init(_ proxy: WireGuardSetup.Proxy, stats: ProxyStats, hotspotOn: Bool, keptOut: Bool, onlyFamily: Interfaces.Family? = nil) {
        if let pause = proxy.paused {
            state = .paused(pause)
        } else if !hotspotOn {
            state = .waiting
        } else if keptOut {
            state = .keptOut(onlyFamily: onlyFamily)
        } else if stats.cantListen {
            state = .cantListen
        } else {
            state = .open(stats.open)
        }
    }

    /// The row's word, short, beside the name. A timed pause says until when, as for a device.
    func label(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .current) -> String {
        switch state {
        case let .paused(pause): DeviceStatus.paused(pause).label(now: now, calendar: calendar, locale: locale)
        case let .keptOut(family): VPNText.keptOutRow(onlyFamily: family)
        case .cantListen: "Not listening"
        // Home's row says what the proxy does, not the hotspot: the status card says that.
        case .waiting: Copy.notInUse
        case .open: title(now: now, calendar: calendar, locale: locale)
        }
    }

    var label: String { label() }

    /// The first line on its screen.
    func title(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .current) -> String {
        switch state {
        case let .paused(pause): pause.title(now: now, calendar: calendar, locale: locale)
        case .open(0): Copy.notInUse
        case .open(1): "1 connection open"
        case let .open(n): "\(n) connections open"
        case .waiting: Copy.waitingForDevice
        case .cantListen: "Not listening"
        case .keptOut: Copy.keptOutTitle
        }
    }

    var title: String { title() }

    /// The icon `DeviceStatusLabel` shows: connected while a device has a connection open.
    var look: DeviceStatus {
        switch state {
        case let .paused(pause): .paused(pause)
        case let .open(n) where n > 0: .connected
        case let .keptOut(family): .keptOut(onlyFamily: family)
        default: .notConnected
        }
    }

    /// Why Add a device's proxy steps can't carry a page yet (H5), with the button that clears it.
    /// Opening the steps turns nothing on: the person does, with `button`.
    enum Blocked: Equatable {
        /// Off, or never turned on. It has no row under Devices.
        case off
        /// Paused on its screen, for a time or until resumed.
        case paused
        /// Paused at its data limit. Resume is on its screen, where its use shows.
        case atLimit

        var text: String {
            switch self {
            case .off: "The proxy has no password. While it's on, any device on the hotspot can use it."
            case .paused: "The proxy is paused."
            case .atLimit: "The proxy is paused at its data limit. To use it anyway, close this, tap Proxy under Devices and tap Resume."
            }
        }

        /// `Model.setProxy(on: true)` for both: it turns the proxy on and resumes a pause by you.
        var button: String? {
            switch self {
            case .off: Copy.turnOnProxy
            case .paused: Copy.resumeProxy
            case .atLimit: nil
            }
        }
    }

    /// Nil when the proxy can carry a page: on, and not paused. Off comes first.
    static func blocked(_ proxy: WireGuardSetup.Proxy?) -> Blocked? {
        guard let proxy, proxy.on else { return .off }
        return switch proxy.paused {
        case .byYou?, .until?: .paused
        case .atLimit?: .atLimit
        case nil: nil
        }
    }

    /// A device on it has a connection open, so it counts as using Tether, see `UsingTether`.
    var inUse: Bool { look == .connected }

    /// The line under the title on its screen, while it's paused or can't listen, see `DeviceStatus.detail`.
    func detail(resets: String, period: String) -> String? {
        switch state {
        case .paused(.byYou): "Nothing goes through it until you resume it."
        case .paused(.until): "It works again then, or when you resume it."
        case .paused(.atLimit): "It used its data \(period). It works again on \(resets), or when you resume it."
        case .cantListen: "Devices on it can't load anything. Tether tries again by itself."
        case let .keptOut(family): VPNText.keptOutDetail(onlyFamily: family)
        default: nil
        }
    }
}

/// What a device types into its proxy settings (#78): the server, without brackets, and the port.
enum ProxyAddress {
    /// proxyPort in WireGuard/proxy.go.
    static let port = "8118"

    /// Where the proxy listens, IPv4 first, from Go's "ip:port" and "[ip]:port". Before it listens,
    /// 172.20.10.1, where it will: Add a device shows it as the proxy turns on.
    static func servers(_ addresses: [String]) -> [String] {
        let servers = addresses.compactMap { PeerStats.address($0) }
        return servers.isEmpty ? [Hotspot.host] : servers
    }
}

/// The status card's line under Sharing: the WireGuard devices connected, and the proxy while a
/// connection is open on it. The proxy's devices can't be told apart, so it's named, not counted.
/// With none of them, the paused devices (M2), or whether there's any device at all.
enum UsingTether {
    /// `paused` counts the devices paused, for any reason. `added` is true once a device or the proxy is.
    static func headline(devices: Int, proxy: Bool, paused: Int, added: Bool) -> String {
        switch (devices, proxy) {
        case (0, false) where paused == 1: "1 device paused"
        case (0, false) where paused > 1: "\(paused) devices paused"
        case (0, false): added ? Copy.noDeviceConnected : Copy.noDeviceYet
        case (0, true): "The proxy is in use"
        case (1, false): "1 device connected"
        case (1, true): "1 device connected and the proxy in use"
        case let (n, false): "\(n) devices connected"
        case let (n, true): "\(n) devices connected and the proxy in use"
        }
    }
}
