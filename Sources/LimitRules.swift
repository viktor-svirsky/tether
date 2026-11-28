import Foundation

/// What each device's timed pause and data limit call for, from a snapshot of the devices and their
/// counts, like `AddWindow` and `IdleStop`: the session carries it out, saving the pauses and telling
/// the person. The proxy goes by the same rules, as one more device.
enum LimitRules {
    /// One device, or the proxy, as the rules read it.
    struct Device: Equatable {
        var id: WireGuardSetup.Peer.ID
        var name: String
        var paused: WireGuardSetup.Pause?
        var limit: UInt64?
        /// What it used since the count last started over.
        var used: UInt64 = 0
        /// Resumed by hand at its limit this period, so it goes over it until the count resets.
        var resumedOver = false
        /// Already told it nears its limit this period.
        var nearTold = false
    }

    /// The devices whose timed pause is over at the first round at or after its end (#312). In that
    /// round `action` reads each as not paused: one over its limit goes straight to paused at it, the
    /// others connect again.
    static func timedPausesOver(_ devices: [Device], at now: Date) -> [WireGuardSetup.Peer.ID] {
        devices.compactMap { device in
            guard case .until(let end)? = device.paused, now >= end else { return nil }
            return device.id
        }
    }

    enum Action: Equatable {
        /// Paused at its limit and now under it (the count reset, or a higher limit or none): resume.
        case resume
        /// At its limit: pause it until the count resets, and tell the person once that's saved.
        case pauseAtLimit
        /// At 90% of its limit, not told yet this period: tell the person.
        case near
    }

    /// What one device's limit calls for now, nil for nothing. A device resumed at its limit this period
    /// stays on until the count resets, and one paused by the person or for a time keeps its pause.
    static func action(for device: Device) -> Action? {
        switch (device.paused, device.limit) {
        case (.atLimit?, nil):
            return .resume
        case let (.atLimit?, limit?) where device.used < limit:
            return .resume
        case let (nil, limit?) where device.used >= limit && !device.resumedOver:
            return .pauseAtLimit
        case let (nil, limit?) where device.used < limit && device.used >= limit / 10 * 9 && !device.nearTold:
            return .near
        default:
            return nil
        }
    }

    /// A limit picked on a device's or the proxy's screen pauses it at once (L1): it isn't paused, the
    /// limit is a new one, and it already used that much this period. Its screen asks first then.
    /// The same limit again changes nothing, see `HotspotSession.setLimit`, and a paused one stays as it is.
    static func pausesNow(_ limit: UInt64?, current: UInt64?, used: UInt64, paused: WireGuardSetup.Pause?) -> Bool {
        guard let limit, limit != current, paused == nil else { return false }
        return used >= limit
    }

    /// What the screen asks before such a limit (L1).
    struct PausesNowQuestion: Equatable {
        static let confirm = "Set the limit and pause it"
        let title: String
        let message: String

        /// `resets` is the day the count starts over, like "December 1".
        init(name: String, used: UInt64, limit: UInt64, resets: String) {
            title = "\(name) already used \(Format.bytes(used))"
            message = "With a \(Format.bytes(limit)) limit it pauses now, until the count resets on \(resets)."
        }
    }
}
