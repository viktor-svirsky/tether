import Foundation

/// What a device's row on the main screen and its own screen say about it. Foundation only, so
/// `swift test` covers the words.
enum DeviceStatus: Equatable {
    case connected
    case notConnected
    case paused(WireGuardSetup.Pause)

    /// Paused comes first: a paused device's tunnel can still be up, but nothing gets through.
    init(_ peer: WireGuardSetup.Peer, connected: Set<String>) {
        if let pause = peer.paused {
            self = .paused(pause)
        } else {
            self = connected.contains(peer.address) ? .connected : .notConnected
        }
    }

    /// The row's word. A timed pause says until when (#312), as of `now`.
    func label(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .current) -> String {
        switch self {
        case .connected: "Connected"
        case .notConnected: "Not connected"
        case let .paused(pause): pause.until.map { "Paused until \(Format.until($0, now: now, calendar: calendar, locale: locale))" } ?? "Paused"
        }
    }

    var label: String { label() }

    /// The first line on its screen: the row's word, or what paused it.
    func title(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .current) -> String {
        switch self {
        case let .paused(pause): pause.title(now: now, calendar: calendar, locale: locale)
        default: label(now: now, calendar: calendar, locale: locale)
        }
    }

    var title: String { title() }

    /// The line under the title on its screen, for a paused device only. `resets` is the day the
    /// count starts over, like "December 1", and `period` the running count, see `Format.period`.
    func detail(resets: String, period: String) -> String? {
        switch self {
        case let .paused(pause): pause.detail(resets: resets, period: period)
        default: nil
        }
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
    }

    let state: State

    /// Paused comes first, as for a device: its devices' connections are closed.
    init(_ proxy: WireGuardSetup.Proxy, stats: ProxyStats, hotspotOn: Bool) {
        if let pause = proxy.paused {
            state = .paused(pause)
        } else if !hotspotOn {
            state = .waiting
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
        case let .open(n) where n > 0: "\(n) open"
        case .cantListen: "Not listening"
        default: "Idle"
        }
    }

    var label: String { label() }

    /// The first line on its screen.
    func title(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .current) -> String {
        switch state {
        case let .paused(pause): pause.title(now: now, calendar: calendar, locale: locale)
        case .open(0): "No connections open"
        case .open(1): "1 connection open"
        case let .open(n): "\(n) connections open"
        case .waiting: "Waiting for a device to join Personal Hotspot"
        case .cantListen: "Not listening"
        }
    }

    var title: String { title() }

    /// The icon `DeviceStatusLabel` shows: connected while a device has a connection open.
    var look: DeviceStatus {
        switch state {
        case let .paused(pause): .paused(pause)
        case let .open(n) where n > 0: .connected
        default: .notConnected
        }
    }

    /// Add a device's last step when the proxy can't carry a page, or nil when it can. Opening the
    /// steps turns it on and resumes a pause by you, but either can fail to be saved. Off, it has no
    /// row under Devices, so that comes first.
    static func blocked(_ proxy: WireGuardSetup.Proxy?) -> String? {
        guard let proxy, proxy.on else { return "The proxy is off. Close this and pick No, use the proxy again to turn it on." }
        return switch proxy.paused {
        case .byYou?, .until?: "The proxy is paused. To resume it, close this, tap Proxy under Devices and turn off Pause."
        case .atLimit?: "The proxy is paused at its data limit. To use it anyway, close this, tap Proxy under Devices and turn off Pause."
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
enum UsingTether {
    static func headline(devices: Int, proxy: Bool) -> String {
        switch (devices, proxy) {
        case (0, false): "No device is using Tether yet"
        case (0, true): "The proxy is in use"
        case (1, false): "1 device connected"
        case (1, true): "1 device connected and the proxy in use"
        case let (n, false): "\(n) devices connected"
        case let (n, true): "\(n) devices connected and the proxy in use"
        }
    }
}
