import Foundation

/// When this build stops opening. Signed with a free Apple ID, its provisioning profile lasts
/// 7 days, and nothing warns before the app just fails to launch.
enum AppExpiry {
    /// How long before the date the main screen starts saying so.
    static let warnBefore: TimeInterval = 3 * 86_400

    /// The installed profile's expiry. Nil on the simulator and in a test run, which have no profile.
    static var installed: Date? {
        Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap(date(fromProfile:))
    }

    /// The profile is a signed blob with its plist in clear text inside.
    static func date(fromProfile data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil)
        else { return nil }
        return (plist as? [String: Any])?["ExpirationDate"] as? Date
    }

    /// What to tell the user, nil while more than `warnBefore` is left. Counted in calendar days,
    /// so 9 am the day after tomorrow is "in 2 days" at any hour today.
    static func warning(expires: Date, now: Date, calendar: Calendar = .current) -> String? {
        guard expires.timeIntervalSince(now) <= warnBefore else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expires)).day ?? 0
        let when = days <= 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days"
        return "Tether stops opening \(when). Refresh or reinstall it before then."
    }
}
