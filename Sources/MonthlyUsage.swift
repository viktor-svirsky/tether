import Foundation

/// Each device's data through Tether per calendar month, this month and last (#75). Counted from
/// the server's per-device counters, the same bytes as the main screen's total, by device id, since
/// a tunnel address goes to the next device after a removal. Foundation only, so `swift test` covers it.
///
/// The counters only grow while Tether runs (`CarriedDevices` carries them across server restarts),
/// so each read adds what they grew by since the last read, and reading the same value twice adds
/// nothing. They start from zero when Tether launches again, so a value lower than the last one
/// counts as all new. Those last values aren't saved: after a relaunch the first read counts in full.
///
/// It also keeps when each device last connected (#73), saved the same way, since the server
/// forgets its handshakes when it stops.
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

    /// What a device's limit has done this month, see `HotspotSession.checkLimits`. Each is the month
    /// it holds for, so a new month forgets it.
    private struct Marks: Codable, Equatable {
        /// Resumed by hand at its limit: it goes over until the 1st.
        var resumedOver: Month?
        /// Told it's near its limit.
        var nearTold: Month?
    }

    static let key = "usage.monthly"

    private var devices: [UUID: Device] = [:]
    private var marks: [UUID: Marks] = [:]
    /// Each device's last handshake (#73). Kept here, since the server forgets it when it stops.
    private var lastHandshakes: [UUID: Date] = [:]
    /// Each device's counters at the last read, in this launch only.
    private var seen: [UUID: TrafficTotals] = [:]
    /// The last handshake read while each device was paused, in this launch only: the server forgets
    /// it when it stops.
    private var pausedHandshakes: [UUID: Date] = [:]

    private enum CodingKeys: String, CodingKey { case devices, marks, lastHandshakes }

    init() {}

    /// Usage saved before there were marks or handshakes has none.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devices = try container.decode([UUID: Device].self, forKey: .devices)
        marks = try container.decodeIfPresent([UUID: Marks].self, forKey: .marks) ?? [:]
        lastHandshakes = try container.decodeIfPresent([UUID: Date].self, forKey: .lastHandshakes) ?? [:]
    }

    /// Adds what each device's counters grew by since the last read to the month of `date`, and
    /// keeps each device's last handshake. A device with none in this read, as from a stopped
    /// server, keeps the one it had. One in the read always replaces it, even an earlier one: the
    /// server's only moves forward, so an earlier one means the clock was set back, and keeping the
    /// later one would show a time that hasn't come yet until the clock catches up.
    ///
    /// A paused device keeps handshaking with nothing getting through, which isn't connecting. Its
    /// handshakes don't count, nor the last of them, which the server goes on reporting after Resume
    /// until the device handshakes again. Its data counts either way.
    mutating func record(_ counts: [UUID: TrafficTotals], handshakes: [UUID: Date] = [:], paused: Set<UUID> = [],
                         at date: Date, calendar: Calendar) {
        for (id, handshake) in handshakes {
            if paused.contains(id) {
                pausedHandshakes[id] = handshake
            } else if pausedHandshakes[id] != handshake {
                pausedHandshakes[id] = nil
                lastHandshakes[id] = handshake
            }
        }
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

    /// When the device last connected, nil for never.
    func lastConnected(_ id: UUID) -> Date? { lastHandshakes[id] }

    /// Drops removed devices.
    mutating func keep(only ids: Set<UUID>) {
        devices = devices.filter { ids.contains($0.key) }
        marks = marks.filter { ids.contains($0.key) }
        lastHandshakes = lastHandshakes.filter { ids.contains($0.key) }
        pausedHandshakes = pausedHandshakes.filter { ids.contains($0.key) }
        seen = seen.filter { ids.contains($0.key) }
    }

    // MARK: The limit's marks

    func resumedOver(_ id: UUID, at date: Date, calendar: Calendar) -> Bool {
        marks[id]?.resumedOver == Month(date, calendar: calendar)
    }

    mutating func markResumedOver(_ id: UUID, at date: Date, calendar: Calendar) {
        marks[id, default: Marks()].resumedOver = Month(date, calendar: calendar)
    }

    func nearTold(_ id: UUID, at date: Date, calendar: Calendar) -> Bool {
        marks[id]?.nearTold == Month(date, calendar: calendar)
    }

    mutating func markNearTold(_ id: UUID, at date: Date, calendar: Calendar) {
        marks[id, default: Marks()].nearTold = Month(date, calendar: calendar)
    }

    /// A new limit starts over: a resume or a notice for the old one doesn't hold for it.
    mutating func clearMarks(_ id: UUID) {
        marks[id] = nil
    }

    static func load(from defaults: UserDefaults) -> MonthlyUsage {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(MonthlyUsage.self, from: $0) } ?? MonthlyUsage()
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    static func == (a: MonthlyUsage, b: MonthlyUsage) -> Bool {
        a.devices == b.devices && a.marks == b.marks && a.lastHandshakes == b.lastHandshakes
    }
}
