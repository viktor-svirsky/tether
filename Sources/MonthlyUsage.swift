import Foundation

/// Each device's data through Tether per calendar month, this month and last (#75). Counted from
/// the server's per-device counters, the same bytes as the main screen's total, by device id, since
/// a tunnel address goes to the next device after a removal. Foundation only, so `swift test` covers it.
///
/// The counters only grow while Tether runs (`CarriedDevices` carries them across server restarts),
/// so each read adds what they grew by since the last read, and reading the same value twice adds
/// nothing. They start from zero when Tether launches again, so a value lower than the last one
/// counts as all new. Those last values aren't saved: after a relaunch the first read counts in full.
struct MonthlyUsage: Codable, Equatable {
    /// A calendar month, in the time zone of the read.
    struct Month: Codable, Hashable, Comparable {
        let year: Int
        let month: Int

        init(_ date: Date, calendar: Calendar) {
            let c = calendar.dateComponents([.year, .month], from: date)
            year = c.year ?? 0
            month = c.month ?? 0
        }

        private init(year: Int, month: Int) {
            self.year = year
            self.month = month
        }

        var previous: Month { month == 1 ? Month(year: year - 1, month: 12) : Month(year: year, month: month - 1) }

        static func < (a: Month, b: Month) -> Bool { (a.year, a.month) < (b.year, b.month) }
    }

    /// What a device used, as a screen shows it.
    struct Usage: Equatable {
        var thisMonth = TrafficTotals()
        var lastMonth = TrafficTotals()
    }

    private struct Device: Codable, Equatable {
        /// The month `thisMonth` is for, the latest any read was in.
        var month: Month
        var thisMonth: TrafficTotals
        var lastMonth: TrafficTotals
    }

    static let key = "usage.monthly"

    private var devices: [UUID: Device] = [:]
    /// Each device's counters at the last read, in this launch only.
    private var seen: [UUID: TrafficTotals] = [:]

    private enum CodingKeys: String, CodingKey { case devices }

    /// Adds what each device's counters grew by since the last read to the month of `date`.
    mutating func record(_ counts: [UUID: TrafficTotals], at date: Date, calendar: Calendar) {
        let month = Month(date, calendar: calendar)
        for (id, now) in counts {
            let before = seen[id] ?? TrafficTotals()
            seen[id] = now
            let startedOver = now.bytesUp < before.bytesUp || now.bytesDown < before.bytesDown
            let added = startedOver ? now : TrafficTotals(bytesUp: now.bytesUp - before.bytesUp, bytesDown: now.bytesDown - before.bytesDown)
            guard added != TrafficTotals() else { continue }
            var device = devices[id] ?? Device(month: month, thisMonth: TrafficTotals(), lastMonth: TrafficTotals())
            if month == device.month {
                device.thisMonth += added
            } else if month > device.month {
                device.lastMonth = month.previous == device.month ? device.thisMonth : TrafficTotals()
                device.thisMonth = added
                device.month = month
            } else if month == device.month.previous {
                device.lastMonth += added // the clock went back across the 1st: never roll back
            }
            devices[id] = device
        }
    }

    /// This month and last as of `date`, so a month that turned over with no read since shows right.
    func of(_ id: UUID, at date: Date, calendar: Calendar) -> Usage {
        guard let device = devices[id] else { return Usage() }
        let month = Month(date, calendar: calendar)
        if month <= device.month { return Usage(thisMonth: device.thisMonth, lastMonth: device.lastMonth) }
        return Usage(thisMonth: TrafficTotals(), lastMonth: month.previous == device.month ? device.thisMonth : TrafficTotals())
    }

    /// Drops removed devices.
    mutating func keep(only ids: Set<UUID>) {
        devices = devices.filter { ids.contains($0.key) }
        seen = seen.filter { ids.contains($0.key) }
    }

    static func load(from defaults: UserDefaults) -> MonthlyUsage {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(MonthlyUsage.self, from: $0) } ?? MonthlyUsage()
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    static func == (a: MonthlyUsage, b: MonthlyUsage) -> Bool { a.devices == b.devices }
}
