import Foundation

/// The day of the month the counts and the data limits start over (#187). Carrier plans reset on
/// the billing day, which can be any day, so with it set Tether's meter matches the carrier's.
/// Foundation only, so `swift test` covers it.
///
/// A day a month doesn't have means that month's last day, the way carriers do it: 31 resets on
/// February 28 (29 in a leap year) and April 30. So 31 is "the last day of the month".
struct ResetDay: Hashable, Codable {
    /// 1 to 31.
    let day: Int

    init?(_ day: Int) {
        guard (1...31).contains(day) else { return nil }
        self.day = day
    }

    static let first = ResetDay(1)!
    static let lastDay = ResetDay(31)!
    static let `default` = first
    /// Where the setting is saved in UserDefaults, as the day, 31 for the last day.
    static let key = "usage.resetDay"

    /// The 1st when nothing is saved (`integer` reads 0) or the number isn't a day.
    static func saved(in defaults: UserDefaults) -> ResetDay {
        ResetDay(defaults.integer(forKey: key)) ?? .default
    }

    /// Saved as the plain number, like the setting.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let day = ResetDay(try container.decode(Int.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a day of the month")
        }
        self = day
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(day)
    }

    // MARK: Its dates, as days of `MonthlyUsage`

    /// The last reset on or before `day`, where the period it's in started.
    func last(onOrBefore day: MonthlyUsage.Day, calendar: Calendar) -> MonthlyUsage.Day {
        let here = inMonth(of: day, calendar: calendar)
        return here <= day ? here : inMonth(of: day, adding: -1, calendar: calendar)
    }

    /// The last reset before `day`.
    func last(before day: MonthlyUsage.Day, calendar: Calendar) -> MonthlyUsage.Day {
        let here = inMonth(of: day, calendar: calendar)
        return here < day ? here : inMonth(of: day, adding: -1, calendar: calendar)
    }

    /// The first reset after `day`, where the period it's in ends.
    func next(after day: MonthlyUsage.Day, calendar: Calendar) -> MonthlyUsage.Day {
        let here = inMonth(of: day, calendar: calendar)
        return here > day ? here : inMonth(of: day, adding: 1, calendar: calendar)
    }

    /// This reset in the month of `day`, or `months` after it, by the calendar's month lengths.
    private func inMonth(of day: MonthlyUsage.Day, adding months: Int = 0, calendar: Calendar) -> MonthlyUsage.Day {
        guard let first = MonthlyUsage.Day(year: day.year, month: day.month, day: 1).start(in: calendar),
              let month = calendar.date(byAdding: .month, value: months, to: first),
              let length = calendar.range(of: .day, in: .month, for: month)?.count else { return day }
        let c = calendar.dateComponents([.year, .month], from: month)
        return MonthlyUsage.Day(year: c.year ?? day.year, month: c.month ?? day.month, day: min(self.day, length))
    }
}
