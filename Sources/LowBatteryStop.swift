import Foundation

/// When sharing stops at a low battery (#311). Sharing keeps the cellular radio and the silent sound
/// busy, so a phone left sharing away from its owner can run flat. At or below the chosen level, and only
/// while it isn't charging, Tether stops sharing in the background, like the idle stop (`IdleStop`),
/// and lets iOS suspend it until it's opened again. Foundation only, so `swift test` covers it.
enum LowBatteryStop {
    /// The setting in Settings > When to stop.
    enum Level: Int, CaseIterable {
        case never = 0
        case ten = 10
        case twenty = 20
        case thirty = 30

        static let `default` = Level.never
        /// Where it's saved in UserDefaults, as a percent, 0 for never.
        static let key = "sharing.lowBatteryStop"

        static func saved(in defaults: UserDefaults) -> Level {
            Level(rawValue: defaults.integer(forKey: key)) ?? .default
        }

        var percent: Int? { self == .never ? nil : rawValue }

        /// In the menu.
        var label: String { self == .never ? "Never" : "At \(rawValue)%" }
    }

    /// What iOS says about the battery.
    struct Battery: Equatable {
        /// 0 to 100. Nil when iOS can't say: monitoring off, or the simulator.
        var percent: Int?
        /// Charging, or full on the charger.
        var charging: Bool

        static let unknown = Battery(percent: nil, charging: false)
    }

    /// At or below the level and not charging, so sharing should stop. An unknown reading never
    /// stops it, and comparing at-or-below works whatever steps iOS reports the level in.
    static func low(_ battery: Battery, at level: Level) -> Bool {
        guard let limit = level.percent, let percent = battery.percent, !battery.charging else { return false }
        return percent <= limit
    }
}

/// The battery is at or below the stop level and not charging, see `LowBatteryStop`. On screen,
/// the main screen says sharing stops when Tether leaves it.
struct BelowBatteryStop: Equatable {
    let percent: Int
    let level: LowBatteryStop.Level

    /// The main screen's line while Tether is open.
    var text: String {
        "Battery is at \(percent)%, at or below your \(level.rawValue)% stop level. Sharing stops when you leave Tether."
    }
}
