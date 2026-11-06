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

    /// Bits per second in the unit a person expects on a speed test.
    static func speed(_ bps: Double) -> String {
        switch bps {
        case 1e6...: return String(format: "%.1f Mbit/s", bps / 1e6)
        case 1e3...: return String(format: "%.0f kbit/s", bps / 1e3)
        default: return String(format: "%.0f bit/s", bps)
        }
    }

    /// A device's row on the main screen (#73): "3.12 GB this month", or "Not used this month"
    /// rather than "0 bytes this month".
    static func thisMonth(_ used: UInt64) -> String {
        used == 0 ? "Not used this month" : "\(bytes(used)) this month"
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
