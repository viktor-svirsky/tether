import Foundation

/// The last time sharing stopped by itself or from a widget (H3), for a note on Home until "Got it".
/// Saved when it stops, since iOS can end Tether soon after, and opening Tether starts sharing again
/// at once, so the stop itself is gone by the time anyone looks. A newer stop takes its place.
/// Foundation only, so `swift test` covers the sentence.
struct LastStop: Codable, Equatable {
    enum Reason: Codable, Equatable {
        /// No device was connected for this long, see `IdleStop`.
        case idle(IdleStop.After)
        /// The battery reached this level, not charging, see `LowBatteryStop`.
        case lowBattery(LowBatteryStop.Level)
        /// Stop on a widget or in Control Center.
        case byYou
    }

    let at: Date
    let reason: Reason

    /// What `HotspotSession` stopped for.
    init(_ stopped: IdleStopped) {
        at = stopped.at
        reason = stopped.byYou ? .byYou : stopped.lowBattery.map(Reason.lowBattery) ?? .idle(stopped.after)
    }

    init(at: Date, reason: Reason) {
        self.at = at
        self.reason = reason
    }

    /// "Sharing stopped today at 2:05 PM. The battery reached 20%."
    func text(now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let when = Self.when(at, now: now, calendar: calendar, locale: locale)
        return switch reason {
        case let .idle(after): "Sharing stopped \(when). No device was connected for \(after.spelledOut)."
        case let .lowBattery(level): "Sharing stopped \(when). The battery reached \(level.rawValue)%."
        case .byYou: "You stopped sharing \(when), from a widget or Control Center."
        }
    }

    /// "today at 2:05 PM", "yesterday at ...", "on October 3 at ...", with the year only for another
    /// year: `Format.lastConnected`'s days, inside a sentence.
    static func when(_ date: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let said = Format.lastConnected(date, now: now, calendar: calendar, locale: locale)
        if said.hasPrefix("Today ") { return "today" + said.dropFirst("Today".count) }
        if said.hasPrefix("Yesterday ") { return "yesterday" + said.dropFirst("Yesterday".count) }
        return "on \(said)"
    }

    static let key = "home.lastStop"

    static func load(from defaults: UserDefaults) -> LastStop? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(LastStop.self, from: $0) }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    static func clear(in defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
    }
}

extension IdleStop.After: Codable {}
extension LowBatteryStop.Level: Codable {}
