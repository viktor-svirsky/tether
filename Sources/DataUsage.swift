import Foundation

/// What a device's screen and its row show: its data this calendar month and last, and when it was
/// last seen connected. Nil for a device that never connected since Tether began counting.
struct DeviceUsage: Equatable {
    var thisMonth = TrafficTotals()
    var lastMonth = TrafficTotals()
    var lastConnected: Date?
}

/// A month in the user's calendar, where a device's data is counted.
struct Month: Hashable, Comparable {
    let year: Int
    let month: Int

    init(_ date: Date, in calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month], from: date)
        year = c.year ?? 0
        month = c.month ?? 0
    }

    static func before(_ date: Date, in calendar: Calendar) -> Month {
        Month(calendar.date(byAdding: .month, value: -1, to: date) ?? date, in: calendar)
    }

    static func < (a: Month, b: Month) -> Bool { (a.year, a.month) < (b.year, b.month) }
}

/// Each device's data by month, kept across launches, from the server's counters. Those start at
/// zero with each launch and only grow within it (`CarriedDevices` covers the hotspot going off and
/// on), so a device first read in this launch counts from zero, and each read adds how far its
/// counters moved since the last one. Foundation only, so `swift test` covers it.
struct UsageLedger {
    private struct Device: Equatable {
        var months: [Month: TrafficTotals] = [:]
        var lastConnected: Date?
    }

    private var devices: [WireGuardSetup.Peer.ID: Device] = [:]
    /// Each device's counters at the last read in this launch. Not saved.
    private var lastCounter: [WireGuardSetup.Peer.ID: TrafficTotals] = [:]

    init() {}

    /// Adds what moved since the last read to `now`'s month, for the devices in `peers`, and forgets
    /// any other: a removed one, or all of them after starting over with new keys. A device isn't
    /// counted before it's listed, so the ready one behind the QR code counts once it's claimed.
    /// Drops months before last month, and none after it, so a clock that was set back loses nothing.
    /// True when anything changed, so there's something to save.
    @discardableResult
    mutating func record(_ snapshot: ServerSnapshot, peers: [WireGuardSetup.Peer], now: Date, calendar: Calendar) -> Bool {
        let listed = Set(peers.map(\.id))
        let before = devices
        devices = devices.filter { listed.contains($0.key) }
        lastCounter = lastCounter.filter { listed.contains($0.key) }
        let month = Month(now, in: calendar)
        let oldest = Month.before(now, in: calendar)
        for peer in peers {
            guard let stats = snapshot.peers[peer.address] else { continue }
            var device = devices[peer.id] ?? Device()
            let last = lastCounter[peer.id] ?? TrafficTotals()
            lastCounter[peer.id] = stats.traffic
            // The counters never go backwards. If they did, this counts on from there.
            if stats.traffic.bytesUp >= last.bytesUp, stats.traffic.bytesDown >= last.bytesDown {
                let moved = TrafficTotals(bytesUp: stats.traffic.bytesUp - last.bytesUp, bytesDown: stats.traffic.bytesDown - last.bytesDown)
                if moved.total > 0 { device.months[month, default: TrafficTotals()] += moved }
            }
            // A handshake comes every two minutes or so, so while it's connected the read's own time is
            // closer. To the minute, which is all the screen shows, so a connected device that sends
            // nothing doesn't change on every read.
            let thisMinute = calendar.dateInterval(of: .minute, for: now)?.start ?? now
            if let seen = stats.connected ? thisMinute : stats.lastHandshake, seen > device.lastConnected ?? .distantPast {
                device.lastConnected = seen
            }
            device.months = device.months.filter { $0.key >= oldest }
            devices[peer.id] = device
        }
        return devices != before
    }

    func usage(of id: WireGuardSetup.Peer.ID, now: Date, calendar: Calendar) -> DeviceUsage {
        guard let device = devices[id] else { return DeviceUsage() }
        return DeviceUsage(thisMonth: device.months[Month(now, in: calendar)] ?? TrafficTotals(),
                           lastMonth: device.months[Month.before(now, in: calendar)] ?? TrafficTotals(),
                           lastConnected: device.lastConnected)
    }

    // MARK: Saved

    /// The version of what's saved. Another one starts from zero rather than misread it.
    static let version = 1

    struct OtherVersion: Error, CustomStringConvertible {
        let version: Int
        var description: String { "version \(version), this app reads \(UsageLedger.version)" }
    }

    private struct Saved: Codable {
        var v = UsageLedger.version
        var devices: [String: SavedDevice] // by Peer.ID

        struct SavedDevice: Codable {
            var months: [SavedMonth]
            var lastConnected: Date?
        }

        struct SavedMonth: Codable {
            let year: Int
            let month: Int
            let up: UInt64
            let down: UInt64
        }
    }

    /// Only the version, read first: another version may lack keys this one needs.
    private struct Version: Decodable {
        let v: Int
    }

    init(saved data: Data) throws {
        let version = try JSONDecoder().decode(Version.self, from: data).v
        guard version == Self.version else { throw OtherVersion(version: version) }
        for (id, saved) in try JSONDecoder().decode(Saved.self, from: data).devices {
            guard let id = UUID(uuidString: id) else { continue }
            var device = Device(lastConnected: saved.lastConnected)
            for m in saved.months {
                device.months[Month(year: m.year, month: m.month)] = TrafficTotals(bytesUp: m.up, bytesDown: m.down)
            }
            devices[id] = device
        }
    }

    func saved() -> Data {
        let saved = Saved(devices: Dictionary(uniqueKeysWithValues: devices.map { id, device in
            (id.uuidString, Saved.SavedDevice(months: device.months.map { month, used in
                Saved.SavedMonth(year: month.year, month: month.month, up: used.bytesUp, down: used.bytesDown)
            }, lastConnected: device.lastConnected))
        }))
        // Plain values only, so encoding can't fail.
        return (try? JSONEncoder().encode(saved)) ?? Data()
    }
}

private extension Month {
    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }
}
