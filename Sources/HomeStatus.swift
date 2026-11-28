import Foundation

/// What the status card at the top of Home says (H1, M9): one state, with its title, the line under
/// it and the text under that. Foundation only, so `swift test` covers the words.
enum HomeStatus: Equatable {
    /// iOS blocks Tether's replies to the devices: nothing works until Local Network is on.
    case localNetworkOff
    /// WireGuard isn't running, see `WireGuardProblem`. The saved keys' problems show with the
    /// hotspot off too: until they're solved nothing can start.
    case problem(WireGuardProblem)
    /// Sharing, but Only share through a VPN keeps every device out while no VPN is on.
    case keptOut(onlyFamily: Interfaces.Family?)
    case sharing
    /// No device on the hotspot, which iOS makes look the same as the hotspot off.
    case waiting

    /// Local Network off comes first, hotspot or not, then a reason WireGuard isn't running.
    init(localNetworkDenied: Bool, problem: WireGuardProblem?, sharing: Bool, blockedWithoutVPN: Bool, onlyFamily: Interfaces.Family?) {
        if localNetworkDenied {
            self = .localNetworkOff
        } else if let problem {
            self = .problem(problem)
        } else if sharing {
            self = blockedWithoutVPN ? .keptOut(onlyFamily: onlyFamily) : .sharing
        } else {
            self = .waiting
        }
    }

    var title: String {
        switch self {
        case .localNetworkOff: "Devices can't connect"
        case let .problem(problem): problem.title
        case .keptOut: Copy.keptOut
        case .sharing: "Sharing"
        case .waiting: Copy.waitingForDevice
        }
    }

    /// The line under the title. Nil while sharing, where `UsingTether.headline` says who uses it,
    /// and while waiting, where the hint says what to do.
    var line: String? {
        switch self {
        case .localNetworkOff: "Local Network is off for Tether"
        case let .problem(problem): problem.line
        case let .keptOut(family): VPNText.keptOutLine(onlyFamily: family)
        case .sharing, .waiting: nil
        }
    }

    /// The text under the line, only while the devices are kept out: what to do, before the link to
    /// Settings (`Copy.openTetherSettings`).
    var body: String? {
        if case let .keptOut(family) = self { return VPNText.blocked(onlyFamily: family) }
        return nil
    }

    /// The live dot and the speeds: only while something can get through.
    var live: Bool { self == .sharing }

    /// The waiting hint on Home (H2), after the way to turn on the hotspot: Tether sleeps once it's
    /// left for `KeepAlivePolicy.grace` with no device, which nothing said.
    static var sleepHint: String {
        "Open Tether before you turn the hotspot on. It waits \(WakeHelp.minutes) minutes after you leave it, then sleeps. "
            + "To wake it without opening it, see Settings > Help."
    }
}

/// Settings > Help > Start without opening Tether (H2): the ways to wake Tether from outside it.
enum WakeHelp {
    /// How long each way keeps Tether awake for the hotspot, `KeepAlivePolicy.grace`.
    static var minutes: Int { Int(KeepAlivePolicy.grace / 60) }

    static let title = "Start without opening Tether"

    static var lines: [String] {
        [
            "Shortcuts: put Start Tether after Set Personal Hotspot, and run that shortcut.",
            "Widget: add the Tether widget and tap Start.",
            "Control Center: add the Tether button and turn it on.",
            "Each one wakes Tether for \(minutes) minutes, the same as opening it.",
        ]
    }
}

/// A warning or a note on Home between the status card and Devices (M13), in one order, folded once
/// there are three or more. The notes stay until "Got it" (H3, M7, M11). The status card says the
/// rest: Local Network, WireGuard's problems and the VPN rule.
enum HomeNote: Equatable, Identifiable {
    /// The battery is at the stop level, see `BelowBatteryStop.text`.
    case lowBattery(String)
    /// A device knocks with a config that no longer works, see `HotspotSession.showsStaleConfig`.
    case staleConfig
    /// This build stops opening soon, see `AppExpiry.warning`.
    case expiry(String)
    case lastStop(LastStop)
    case stopIgnored
    /// Notifications were never asked about, and Tether has something to tell (M7).
    case offerNotifications

    /// Its accessibility identifier: the old warnings keep theirs.
    var id: String {
        switch self {
        case .lowBattery: "battery.low"
        case .staleConfig: "stale.warning"
        case .expiry: "app.expiry"
        case .lastStop: "note.lastStop"
        case .stopIgnored: "note.stopIgnored"
        case .offerNotifications: "note.notifications"
        }
    }

    /// Warnings first, then the notes, in this order.
    private var rank: Int {
        switch self {
        case .lowBattery: 0
        case .staleConfig: 1
        case .expiry: 2
        case .lastStop: 3
        case .stopIgnored: 4
        case .offerNotifications: 5
        }
    }

    /// A note has "Got it", or for notifications "Allow notifications" and "Not now". A warning goes
    /// by itself once it's no longer true.
    var isNote: Bool { rank >= 3 }

    func text(now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        switch self {
        case let .lowBattery(text), let .expiry(text): text
        case .staleConfig:
            "A device is trying to connect with a config that no longer works. Delete its tunnel in WireGuard, then add the device again."
        case let .lastStop(stop): stop.text(now: now, calendar: calendar, locale: locale)
        case .stopIgnored: Copy.stopIgnored
        case .offerNotifications: Copy.offerNotifications
        }
    }

    /// The ones to show, in order, and the link for the rest: one or two all show, three or more
    /// show the first and "2 more", until the link is tapped (`expanded`).
    static func fold(_ notes: [HomeNote], expanded: Bool) -> (shown: [HomeNote], more: String?) {
        let sorted = notes.sorted { $0.rank < $1.rank }
        guard sorted.count >= 3, !expanded else { return (sorted, nil) }
        return (Array(sorted.prefix(1)), "\(sorted.count - 1) more")
    }
}
