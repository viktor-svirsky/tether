import Foundation

/// Byte counts, speeds and times as text.
enum Format {
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
        // By days, not times: where a clock change skips midnight, the 1st starts at 1 AM.
        let start = period.start
        let from = calendar.dateComponents([.year, .month, .day], from: start)
        let to = calendar.dateComponents([.year, .month, .day], from: period.end)
        if from.day == 1, to.day == 1, let next = calendar.date(byAdding: .month, value: 1, to: start),
           calendar.dateComponents([.year, .month], from: next) == calendar.dateComponents([.year, .month], from: period.end) {
            return "this month"
        }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        return "since \(start.formatted(style.month(.abbreviated).day()))"
    }

    /// A device's row and its screen (#73): "3.12 GB this month", or "Not used this month" rather
    /// than "0 bytes this month". `period` is from `period(_:calendar:locale:)`.
    static func used(_ used: UInt64, _ period: String) -> String {
        used == 0 ? "Not used \(period)" : "\(bytes(used)) \(period)"
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
