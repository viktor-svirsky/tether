import Foundation

/// When sharing stops after a time with no device connected (#76). The silent sound that keeps
/// Tether running costs battery even with nobody on the hotspot, so after the chosen time Tether
/// stops sharing and lets iOS suspend it, until it's opened again. Only in the background: on
/// screen the person sees nothing is shared, and the time runs from leaving the screen, like the
/// keep-alive's 10 minutes. Foundation only, with the clock passed in, so `swift test` covers it.
struct IdleStop {
    /// The setting in Settings > Sharing.
    enum After: Int, CaseIterable {
        case never = 0
        case tenMinutes = 600
        case thirtyMinutes = 1800
        case oneHour = 3600

        static let `default` = After.never
        /// Where it's saved in UserDefaults, as seconds, 0 for never.
        static let key = "sharing.idleStopAfter"

        static func saved(in defaults: UserDefaults) -> After {
            After(rawValue: defaults.integer(forKey: key)) ?? .default
        }

        var seconds: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) }

        /// In the menu.
        var label: String {
            switch self {
            case .never: "Never"
            case .tenMinutes: "After 10 min"
            case .thirtyMinutes: "After 30 min"
            case .oneHour: "After 1 hour"
            }
        }

        /// In the notification: "No device was connected for 30 minutes."
        var spelledOut: String {
            switch self {
            case .never: ""
            case .tenMinutes: "10 minutes"
            case .thirtyMinutes: "30 minutes"
            case .oneHour: "1 hour"
            }
        }
    }

    /// Since when nothing was connected in the background while sharing. Nil while a device is
    /// connected, on screen, or without sharing.
    private var idleSince: Date?

    /// One watcher round. True when sharing should stop now. The session stops it in the same
    /// round, so the next round isn't sharing. If Tether shares again before that round (opened, or
    /// Start Tether, while iOS had it suspended), it counts from there.
    mutating func check(sharing: Bool, connected: Bool, onScreen: Bool, after: After, now: Date) -> Bool {
        guard sharing, !connected, !onScreen else {
            idleSince = nil
            return false
        }
        let since = idleSince ?? now
        idleSince = since
        guard let seconds = after.seconds, now.timeIntervalSince(since) >= seconds else { return false }
        idleSince = nil
        return true
    }
}

/// Sharing stopped after `after` with no device connected, see `IdleStop`, until Tether is opened
/// or Start Tether runs.
struct IdleStopped: Equatable {
    let at: Date
    let after: IdleStop.After
}
