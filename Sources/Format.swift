import Foundation

/// Byte counts, speeds and a device's data use as text.
enum Format {
    /// "0 bytes", not ByteCountFormatter's "Zero KB".
    static func bytes(_ n: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(clamping: n))
    }

    /// Bits per second in the unit a person expects on a speed test.
    static func speed(_ bps: Double) -> String {
        switch bps {
        case 1e6...: return String(format: "%.1f Mbit/s", bps / 1e6)
        case 1e3...: return String(format: "%.0f kbit/s", bps / 1e3)
        default: return String(format: "%.0f bit/s", bps)
        }
    }

    // MARK: Data use

    /// Both ways together: "3.12 GB this month", or "Not used this month".
    static func thisMonth(_ used: TrafficTotals) -> String {
        used.total == 0 ? "Not used this month" : "\(bytes(used.total)) this month"
    }

    static func lastMonth(_ used: TrafficTotals) -> String {
        used.total == 0 ? "Not used" : bytes(used.total)
    }

    /// "↓ 2.7 GB  ↑ 420 MB" for VoiceOver, which reads the arrows as words that mean nothing here.
    static func downAndUpSpoken(_ used: TrafficTotals) -> String {
        "\(bytes(used.bytesDown)) down, \(bytes(used.bytesUp)) up"
    }

    /// The first of next month, when "this month" starts again: "Resets on 1 December".
    static func resetsOn(now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let next = calendar.dateInterval(of: .month, for: now)?.end ?? now
        return "Resets on \(date(next, template: "dMMMM", calendar: calendar, locale: locale))"
    }

    /// "Today, 09:12", "Yesterday, 18:02", "2 November, 18:02", with the year when it isn't this one,
    /// or "Never". Worked out here, not by DateFormatter's relative dates, which read the real clock.
    static func lastConnected(_ last: Date?, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        guard let last else { return "Never" }
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.timeStyle = .short
        let day: String
        if calendar.isDate(last, inSameDayAs: now) {
            day = "Today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(last, inSameDayAs: yesterday) {
            day = "Yesterday"
        } else {
            let sameYear = calendar.component(.year, from: last) == calendar.component(.year, from: now)
            day = date(last, template: sameYear ? "dMMMM" : "dMMMMy", calendar: calendar, locale: locale)
        }
        return "\(day), \(time.string(from: last))"
    }

    private static func date(_ date: Date, template: String, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }
}
