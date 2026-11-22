import Foundation

/// Byte counts, speeds and times as text.
enum Format {
    /// The Devices section's line for the devices on the hotspot not using Tether (#109): their
    /// addresses, or how many once there are more than two, so it stays short.
    static func notUsingTether(_ addresses: [String]) -> String {
        let who = addresses.count > 2 ? "\(addresses.count) devices" : addresses.joined(separator: ", ")
        return "On your hotspot, not using Tether: \(who)"
    }

    /// "0 bytes" for nothing, not "Zero KB", so a column of numbers stays numbers.
    static func bytes(_ n: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(clamping: n))
    }

    /// Bits per second in the unit a person expects on a speed test. With the region's decimal
    /// separator, like `bytes`, since `String(format:)` always prints a dot (#177).
    static func speed(_ bps: Double, locale: Locale = .current) -> String {
        func number(_ value: Double, digits: Int) -> String {
            value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
        }
        switch bps {
        case 1e6...: return "\(number(bps / 1e6, digits: 1)) Mbit/s"
        case 1e3...: return "\(number(bps / 1e3, digits: 0)) kbit/s"
        default: return "\(number(bps, digits: 0)) bit/s"
        }
    }

    /// How every screen and notice names the running count of a device's data (#187): "this month"
    /// when it runs from a 1st to the next, else "since Nov 15", the day it started, short, as the
    /// region writes it. A period after a changed reset day isn't a month, even on the 1st.
    static func period(_ period: DateInterval, calendar: Calendar, locale: Locale = .current) -> String {
        isMonth(period, calendar: calendar) ? thisMonth : "since \(short(period.start, calendar: calendar, locale: locale))"
    }

    /// The device screen's row for the period before the running one (#187): "Last month", or its
    /// first and last days, like "Oct 15 to Nov 14".
    static func lastPeriod(_ period: DateInterval, calendar: Calendar, locale: Locale = .current) -> String {
        if isMonth(period, calendar: calendar) { return "Last month" }
        let lastDay = calendar.date(byAdding: .day, value: -1, to: period.end) ?? period.end
        return "\(short(period.start, calendar: calendar, locale: locale)) to \(short(lastDay, calendar: calendar, locale: locale))"
    }

    /// What `period` says for a calendar month.
    static let thisMonth = "this month"

    /// A device's row and its screen (#73): "3.12 GB this month", or "Not used this month" rather
    /// than "0 bytes this month", and "Nothing used since Nov 15". `period` is from `period(_:calendar:locale:)`.
    static func used(_ used: UInt64, _ period: String) -> String {
        if used > 0 { return "\(bytes(used)) \(period)" }
        return period == thisMonth ? "Not used this month" : "Nothing used \(period)"
    }

    /// From a 1st to the next. By days, not times: where a clock change skips midnight, the 1st
    /// starts at 1 AM.
    private static func isMonth(_ period: DateInterval, calendar: Calendar) -> Bool {
        let from = calendar.dateComponents([.year, .month, .day], from: period.start)
        let to = calendar.dateComponents([.year, .month, .day], from: period.end)
        guard from.day == 1, to.day == 1, let next = calendar.date(byAdding: .month, value: 1, to: period.start) else { return false }
        return calendar.dateComponents([.year, .month], from: next) == calendar.dateComponents([.year, .month], from: period.end)
    }

    /// "Nov 15" in the US, "15 Nov" in the UK.
    private static func short(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day())
    }

    /// When a device last connected (#73): "Today at 4:00 PM", "Yesterday at ...", "October 3 at
    /// ...", with the year only for another year. A time, not "2 hours ago", so the screen doesn't
    /// have to tick to stay right.
    static func lastConnected(_ date: Date?, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        guard let date else { return "Never" }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            day = "Yesterday"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            day = LimitAlert.day(date, calendar: calendar, locale: locale)
        } else {
            day = date.formatted(style.day().month(.wide).year())
        }
        return "\(day) at \(date.formatted(style.hour().minute()))"
    }
}
