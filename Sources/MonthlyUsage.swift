import Foundation

/// Each device's data through Tether per period, this one and the last (#75). A period runs from one
/// reset day to the next, the 1st unless the plan's billing day is set (#187), see `ResetDay`. Counted from
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
    /// A day on the calendar, in the time zone of the read. A period starts at the start of one and
    /// is known by it.
    struct Day: Codable, Hashable, Comparable {
        let year: Int
        let month: Int
        let day: Int

        init(_ date: Date, calendar: Calendar) {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            year = c.year ?? 0
            month = c.month ?? 0
            day = c.day ?? 0
        }

        init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        /// Saved before #187 it was a calendar month, with no day: that period started on the 1st.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            year = try container.decode(Int.self, forKey: .year)
            month = try container.decode(Int.self, forKey: .month)
            day = try container.decodeIfPresent(Int.self, forKey: .day) ?? 1
        }

        /// When it starts, nil for a day the calendar doesn't have.
        func start(in calendar: Calendar) -> Date? {
            calendar.date(from: DateComponents(year: year, month: month, day: day))
        }

        static func < (a: Day, b: Day) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
    }

    /// From the start of one day to the start of another.
    struct Period: Codable, Equatable {
        let start: Day
        let end: Day
    }

    /// What a device used this period and the last, as a screen shows it.
    struct Usage: Equatable {
        var thisMonth = TrafficTotals()
        var lastMonth = TrafficTotals()
    }

    private struct Device: Codable, Equatable {
        /// The start of the period `thisMonth` is for, the latest any read was in. Saved as `month`,
        /// from when it was the calendar month.
        var period: Day
        var thisMonth: TrafficTotals
        var lastMonth: TrafficTotals

        private enum CodingKeys: String, CodingKey { case period = "month", thisMonth, lastMonth }
    }

    /// What a device's limit has done this period, see `HotspotSession.checkLimits`. Each is the start
    /// of the period it holds for, so a new period forgets it.
    private struct Marks: Codable, Equatable {
        /// Resumed by hand at its limit: it goes over until the count resets.
        var resumedOver: Day?
        /// Told it's near its limit.
        var nearTold: Day?
    }

    static let key = "usage.monthly"

    /// The day the periods start on, as last followed, see `setResetDay`.
    private(set) var resetDay: ResetDay
    /// The period that was running when the reset day last changed, which ends on the new day's next
    /// date, see `setResetDay`. Nil before any change.
    private var changed: Period?
    /// The start of the period before `changed`, found with the day it followed, which is gone now.
    private var beforeChanged: Day?
    private var devices: [UUID: Device] = [:]
    private var marks: [UUID: Marks] = [:]
    /// Each device's last handshake while it wasn't paused (#73), see `record`. Kept here, since the
    /// server forgets it when it stops.
    private var lastHandshakes: [UUID: Date] = [:]
    /// Each device's counters at the last read, in this launch only.
    private var seen: [UUID: TrafficTotals] = [:]
    /// The last handshake read while each device was paused, in this launch only: the server forgets
    /// it when it stops.
    private var pausedHandshakes: [UUID: Date] = [:]

    private enum CodingKeys: String, CodingKey { case resetDay, changed, beforeChanged, devices, marks, lastHandshakes }

    init(resetDay: ResetDay = .default) {
        self.resetDay = resetDay
    }

    /// Usage saved before there were marks, handshakes or a reset day has none, so its periods start
    /// on the 1st.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resetDay = try container.decodeIfPresent(ResetDay.self, forKey: .resetDay) ?? .default
        changed = try container.decodeIfPresent(Period.self, forKey: .changed)
        beforeChanged = try container.decodeIfPresent(Day.self, forKey: .beforeChanged)
        devices = try container.decode([UUID: Device].self, forKey: .devices)
        marks = try container.decodeIfPresent([UUID: Marks].self, forKey: .marks) ?? [:]
        lastHandshakes = try container.decodeIfPresent([UUID: Date].self, forKey: .lastHandshakes) ?? [:]
    }

    /// Adds what each device's counters grew by since the last read to the period of `date`, and
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
        let current = period(of: date, calendar: calendar).start
        for (id, now) in counts {
            let before = seen[id] ?? TrafficTotals()
            seen[id] = now
            let startedOver = now.bytesUp < before.bytesUp || now.bytesDown < before.bytesDown
            let added = startedOver ? now : TrafficTotals(bytesUp: now.bytesUp - before.bytesUp, bytesDown: now.bytesDown - before.bytesDown)
            guard added != TrafficTotals() else { continue }
            var device = devices[id] ?? Device(period: current, thisMonth: TrafficTotals(), lastMonth: TrafficTotals())
            if current == device.period {
                device.thisMonth += added
            } else if current > device.period {
                device.lastMonth = device.period >= start(before: current, calendar: calendar) ? device.thisMonth : TrafficTotals()
                device.thisMonth = added
                device.period = current
            } else if current >= start(before: device.period, calendar: calendar) {
                device.lastMonth += added // the clock went back across a reset: never roll back
            }
            devices[id] = device
        }
    }

    /// The device's counters start again from zero elsewhere: a new config gave it a new key and
    /// address (M1). Its next read counts in full, whether it's bigger than the old counter or not.
    mutating func newCounters(_ id: UUID) {
        seen[id] = nil
    }

    /// This period and the last as of `date`, so a period that ended with no read since shows right.
    func of(_ id: UUID, at date: Date, calendar: Calendar) -> Usage {
        guard let device = devices[id] else { return Usage() }
        let current = period(of: date, calendar: calendar).start
        if current <= device.period { return Usage(thisMonth: device.thisMonth, lastMonth: device.lastMonth) }
        let last = device.period >= start(before: current, calendar: calendar)
        return Usage(thisMonth: TrafficTotals(), lastMonth: last ? device.thisMonth : TrafficTotals())
    }

    // MARK: Periods

    /// When the period `date` is in ends, and the counts and the limits start over.
    func nextReset(at date: Date, calendar: Calendar) -> Date {
        period(at: date, calendar: calendar).end
    }

    /// From when to when the period `date` is in runs, for the screens' "since Nov 15", see
    /// `Format.period`.
    func period(at date: Date, calendar: Calendar) -> DateInterval {
        let period = period(of: date, calendar: calendar)
        let end = period.end.start(in: calendar) ?? date
        return DateInterval(start: min(period.start.start(in: calendar) ?? end, end), end: end)
    }

    /// The period before the one `date` is in, for the device screen's "Oct 15 to Nov 14", see
    /// `Format.lastPeriod`.
    func lastPeriod(at date: Date, calendar: Calendar) -> DateInterval {
        let current = period(of: date, calendar: calendar).start
        let end = current.start(in: calendar) ?? date
        let start = start(before: current, calendar: calendar).start(in: calendar) ?? end
        return DateInterval(start: min(start, end), end: end)
    }

    /// The reset day changed in Settings at `date`. The running period ends on the new day's next
    /// date, with all it counted: from the 1st to the 15th on November 20, the period from November
    /// 1 runs to December 15, and a device paused at its limit stays paused until then. Ending it on
    /// the old date instead would start the count over twice within one of the carrier's periods,
    /// and let a device use its limit twice.
    mutating func setResetDay(_ day: ResetDay, at date: Date, calendar: Calendar) {
        guard day != resetDay else { return }
        let running = period(of: date, calendar: calendar)
        beforeChanged = start(before: running.start, calendar: calendar)
        resetDay = day
        changed = Period(start: running.start, end: day.next(after: Day(date, calendar: calendar), calendar: calendar))
    }

    /// The period `date` is in: the changed one, or one from a reset day to the next. Before the
    /// change, as with a clock set back, there's only the new day to go by.
    private func period(of date: Date, calendar: Calendar) -> Period {
        let today = Day(date, calendar: calendar)
        if let changed, changed.start <= today, today < changed.end { return changed }
        var end = resetDay.next(after: today, calendar: calendar)
        if let changed, today < changed.start { end = min(end, changed.start) }
        return Period(start: resetDay.last(onOrBefore: today, calendar: calendar), end: end)
    }

    /// The start of the period before the one that starts on `start`.
    private func start(before start: Day, calendar: Calendar) -> Day {
        if let changed, start == changed.end { return changed.start }
        if let changed, start == changed.start, let beforeChanged { return beforeChanged }
        return resetDay.last(before: start, calendar: calendar)
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
        marks[id]?.resumedOver == period(of: date, calendar: calendar).start
    }

    mutating func markResumedOver(_ id: UUID, at date: Date, calendar: Calendar) {
        marks[id, default: Marks()].resumedOver = period(of: date, calendar: calendar).start
    }

    func nearTold(_ id: UUID, at date: Date, calendar: Calendar) -> Bool {
        marks[id]?.nearTold == period(of: date, calendar: calendar).start
    }

    mutating func markNearTold(_ id: UUID, at date: Date, calendar: Calendar) {
        marks[id, default: Marks()].nearTold = period(of: date, calendar: calendar).start
    }

    /// A new limit starts over: a resume or a notice for the old one doesn't hold for it.
    mutating func clearMarks(_ id: UUID) {
        marks[id] = nil
    }

    /// Nothing saved, or nothing readable, starts over on `resetDay`: there's no period to change.
    static func load(from defaults: UserDefaults, resetDay: ResetDay = .default) -> MonthlyUsage {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(MonthlyUsage.self, from: $0) } ?? MonthlyUsage(resetDay: resetDay)
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    static func == (a: MonthlyUsage, b: MonthlyUsage) -> Bool {
        a.resetDay == b.resetDay && a.changed == b.changed && a.beforeChanged == b.beforeChanged
            && a.devices == b.devices && a.marks == b.marks
            && a.lastHandshakes == b.lastHandshakes
    }
}
