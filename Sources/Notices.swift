import Foundation

/// What Tether can tell in a notification. Each has its own switch, all on until turned off.
enum NoticeKind: String, CaseIterable {
    case connected, disconnected, sharingStopped, closed, expiring

    /// The switch's label in Settings.
    var label: String {
        switch self {
        case .connected: "A device connects"
        case .disconnected: "A device disconnects"
        case .sharingStopped: "Sharing stops with a problem"
        case .closed: "iOS stops Tether in the background"
        case .expiring: "Tether stops opening soon"
        }
    }

    /// Where its switch is saved in UserDefaults.
    var key: String { "notify.\(rawValue)" }

    func isOn(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// One notification. A later one with the same `id` takes its place in Notification Center, so a
/// device that connects and then leaves shows only the last of the two.
struct Notice: Equatable {
    let kind: NoticeKind
    let id: String
    let title: String
    let body: String
}

/// Decides what to tell, round by round: a device that connects or leaves, sharing that stops while
/// devices were connected, and the build about to stop opening, once a day. `Model` gives it every
/// watcher round. On screen it tells nothing, since the screen shows the same, but it keeps up, so
/// leaving the screen doesn't tell what was seen there, and it says when it would have told
/// something, the moment to ask for permission. Foundation only, with the clock passed in, so
/// `swift test` covers it.
struct Notifier {
    /// A device that leaves is told once it has been gone this long. It's a second wait on top of the
    /// server's: connected already means a handshake in the last 3 minutes, so it's told 3 to 6
    /// minutes after it went, and one that comes back meanwhile isn't told at all.
    static let goneFor: TimeInterval = 3 * 60
    /// One device is told about at most once in this long. A change in between waits, and is told
    /// only if it still holds then, so a device that comes and goes posts once.
    static let quietFor: TimeInterval = 5 * 60
    /// WireGuard that stops and starts again within this long isn't told. A hotspot that goes waits
    /// `goneFor` instead: its network also goes when the last device leaves it, which is one device
    /// leaving.
    static let stoppedFor: TimeInterval = 60
    /// The last day the expiry was told or shown on screen, saved so a relaunch doesn't tell it again.
    static let expiryKey = "notify.expiryDay"

    /// What one round sees.
    struct Round {
        var now: Date
        var onScreen: Bool
        /// Personal Hotspot is on. With `sharing` false, WireGuard isn't running.
        var hotspot: Bool
        var sharing: Bool
        var devices: [WireGuardSetup.Peer]
        /// The tunnel addresses with a recent handshake.
        var connected: Set<String>
        var expires: Date? = nil
    }

    private struct Device {
        /// Connected, as last told, or as the screen showed it.
        var told: Bool
        /// When it left the connected list. Nil while it's on it.
        var goneSince: Date?
        var lastPost: Date?
    }

    private let defaults: UserDefaults
    private let calendar: Calendar
    private var devices: [WireGuardSetup.Peer.ID: Device] = [:]
    /// The first round only learns how things are: a device connected at launch isn't news.
    private var seen = false
    /// When sharing stopped. Nil while sharing.
    private var stoppedSince: Date?
    /// The last round was on screen and saw something it would have told in the background. iOS
    /// shows the permission question only while Tether is on screen, so `Model` asks then.
    private(set) var wouldTell = false

    init(defaults: UserDefaults, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    /// What to post now. Empty on screen.
    mutating func check(_ round: Round) -> [Notice] {
        wouldTell = false
        var notices: [Notice] = []
        if round.sharing {
            stoppedSince = nil
            notices += checkDevices(round)
        } else {
            notices += checkStopped(round)
        }
        notices += checkExpiry(round)
        seen = true
        return notices
    }

    /// How long since `since`. A time in the future, left by a clock set back, counts as long ago, so
    /// no wait gets stuck on it.
    private static func elapsed(since: Date, now: Date) -> TimeInterval {
        let d = now.timeIntervalSince(since)
        return d < 0 ? .infinity : d
    }

    /// The device's last notification was `quietFor` ago or more.
    private static func quiet(_ device: Device, now: Date) -> Bool {
        device.lastPost.map { elapsed(since: $0, now: now) >= quietFor } ?? true
    }

    /// Each device's state goes to the screen's at once, and to a notification only once it holds:
    /// gone for `goneFor`, and `quietFor` after that device's last notification.
    private mutating func checkDevices(_ round: Round) -> [Notice] {
        devices = devices.filter { id, _ in round.devices.contains { $0.id == id } } // removed devices
        var notices: [Notice] = []
        for peer in round.devices {
            let connected = round.connected.contains(peer.address)
            // New to the owner, wherever it's first seen: a device added on screen is listed already
            // connected. At launch it's simply how things are.
            var device = devices[peer.id] ?? Device(told: seen ? false : connected)
            if connected { device.goneSince = nil } else if device.goneSince == nil { device.goneSince = round.now }
            defer { devices[peer.id] = device }
            if round.onScreen {
                // The moment to ask: a change the background would tell, now or, for a device gone, in 3 minutes.
                if connected != device.told, (connected ? NoticeKind.connected : .disconnected).isOn(in: defaults) { wouldTell = true }
                device.told = connected
                continue
            }
            let held = device.told && device.goneSince.map { Self.elapsed(since: $0, now: round.now) < Self.goneFor } ?? false
            let now = connected || held
            guard now != device.told, Self.quiet(device, now: round.now) else { continue }
            device.told = now
            let kind: NoticeKind = now ? .connected : .disconnected
            guard kind.isOn(in: defaults) else { continue }
            device.lastPost = round.now
            notices.append(Notice(kind: kind, id: "device.\(peer.id.uuidString)",
                                  title: "\(peer.name) \(now ? "connected" : "disconnected")",
                                  body: now ? "It's using this iPhone's data now." : "It left a few minutes ago."))
        }
        return notices
    }

    /// Once sharing has been off for `stoppedFor`, or `goneFor` when the hotspot went, the devices
    /// still counted as connected are told. When the hotspot went, each is told as disconnected:
    /// its network also goes when the last device leaves it, so Tether can't tell the hotspot turned
    /// off from a device that left, and disconnected is true either way. When WireGuard stopped,
    /// they're told in one notification. After that, or as soon as the screen shows it, nobody
    /// counts as connected, so each device that comes back is told.
    private mutating func checkStopped(_ round: Round) -> [Notice] {
        let since = stoppedSince ?? round.now
        stoppedSince = since
        let wait = round.hotspot ? Self.stoppedFor : Self.goneFor
        guard round.onScreen || Self.elapsed(since: since, now: round.now) >= wait else { return [] }
        let gone = round.devices.filter { devices[$0.id]?.told == true }
        let kind: NoticeKind = round.hotspot ? .sharingStopped : .disconnected
        let on = kind.isOn(in: defaults)
        if !round.onScreen, !round.hotspot {
            // Each device in its own notice, once its own quiet time is over. Until then it stays
            // counted as connected, and a later round tells it.
            var notices: [Notice] = []
            for peer in gone {
                guard var device = devices[peer.id], Self.quiet(device, now: round.now) else { continue }
                device.told = false
                device.goneSince = nil
                if on {
                    device.lastPost = round.now
                    notices.append(Notice(kind: .disconnected, id: "device.\(peer.id.uuidString)",
                                          title: "\(peer.name) disconnected", body: "It left a few minutes ago."))
                }
                devices[peer.id] = device
            }
            return notices
        }
        for id in devices.keys {
            devices[id]?.told = false
            devices[id]?.goneSince = nil
        }
        if round.onScreen, !gone.isEmpty, on { wouldTell = true }
        guard !round.onScreen, !gone.isEmpty, on else { return [] }
        let names = gone.map(\.name)
        let who = names.count == 1 ? "\(names[0]) was" : names.count == 2 ? "\(names[0]) and \(names[1]) were" : "\(names.count) devices were"
        return [Notice(kind: .sharingStopped, id: "sharing", title: "Sharing stopped",
                       body: "WireGuard stopped while \(who) connected. Open Tether to see why.")]
    }

    /// Once a day within `AppExpiry.warnBefore`. A day the main screen showed the warning counts as told.
    private func checkExpiry(_ round: Round) -> [Notice] {
        guard let expires = round.expires, let when = AppExpiry.when(expires: expires, now: round.now, calendar: calendar) else { return [] }
        let today = calendar.startOfDay(for: round.now)
        guard defaults.object(forKey: Self.expiryKey) as? Date != today else { return [] }
        if round.onScreen {
            defaults.set(today, forKey: Self.expiryKey)
            return []
        }
        guard NoticeKind.expiring.isOn(in: defaults) else { return [] }
        defaults.set(today, forKey: Self.expiryKey)
        return [Notice(kind: .expiring, id: "expiry", title: "Tether stops opening \(when)",
                       body: "Refresh or reinstall it before then.")]
    }
}

/// A notification that waits while Tether shares and shows if Tether stops. iOS doesn't tell an app
/// it's ending it in the background, and it can stop running it for good after a call or with too
/// little memory, so Tether keeps one set `delay` ahead and pushes it back every `pushBackEvery`.
/// Once Tether is gone nothing pushes it back, and it shows. Sharing that stops, or its switch
/// turned off, takes it away, and so does the first round after a launch, for one left behind.
struct ClosedAlarm {
    /// More than `pushBackEvery` plus a background round (15 s, see `KeepAlivePolicy`) and its
    /// tolerance, so a late round never lets it show.
    static let delay: TimeInterval = 3 * 60
    static let pushBackEvery: TimeInterval = 60
    static let notice = Notice(kind: .closed, id: "closed", title: "Tether stopped sharing",
                               body: "Devices on the hotspot have no data until Tether runs again.")

    enum Action: Equatable {
        /// Show it after this long, in place of any waiting one, and take away one that showed.
        case set(after: TimeInterval)
        /// Take it away, waiting or shown.
        case clear
        case none
    }

    /// When it was last set. Nil while it isn't.
    private var setAt: Date?
    private var checked = false

    mutating func check(now: Date, sharing: Bool, on: Bool) -> Action {
        defer { checked = true }
        guard sharing, on else {
            let waiting = setAt != nil || !checked
            setAt = nil
            return waiting ? .clear : .none
        }
        if let setAt {
            let since = now.timeIntervalSince(setAt)
            if since >= 0, since < Self.pushBackEvery { return .none } // a clock set back pushes it back too
        }
        setAt = now
        return .set(after: Self.delay)
    }
}

/// Notification permission, as `NoticePoster` needs it.
enum NoticePermission {
    case notAsked, allowed, denied
}

/// The system's notification center as `NoticePoster` uses it. The app passes the real one
/// (SettingsView.swift), the tests a fake.
@MainActor
protocol NoticeCenter: AnyObject {
    func permission() async -> NoticePermission
    /// Shows the system's question. True when allowed.
    func ask() async -> Bool
    func add(_ notice: Notice) async
    /// Shows it after this long, in place of one with its id that waits or showed.
    func schedule(_ notice: Notice, after: TimeInterval) async
    /// Takes away the notice with this id, waiting or shown.
    func remove(_ id: String)
}

/// Posts what `Notifier` decided, and asks for permission the first time something happens that it
/// would tell, not at launch. Notices post in the background, but iOS shows the question only while
/// Tether is on screen, so it's asked there, when `Notifier.wouldTell` says so: a device connecting
/// while it's added, say. Until then, and after a no, nothing posts. iOS never asks twice.
@MainActor
final class NoticePoster {
    private let center: NoticeCenter
    /// The question while it's up, so a round that comes meanwhile doesn't ask again.
    private var asking: Task<Void, Never>?
    /// The last alarm action queued, see `queue`.
    private var alarm: Task<Void, Never>?

    init(center: NoticeCenter) {
        self.center = center
    }

    func post(_ notices: [Notice]) async {
        guard !notices.isEmpty, await center.permission() == .allowed else { return }
        for notice in notices { await center.add(notice) }
    }

    /// Does what `ClosedAlarm` decided, after what it decided before: a set still asking for the
    /// permission mustn't come after the clear of a later round, and leave one waiting.
    func queue(_ action: ClosedAlarm.Action) {
        let before = alarm
        alarm = Task { await before?.value; await apply(action) }
    }

    /// The queued alarm actions are done.
    func alarmDone() async { await alarm?.value }

    /// Without permission nothing waits, and nothing is asked: the alarm alone is no moment to ask.
    private func apply(_ action: ClosedAlarm.Action) async {
        switch action {
        case let .set(after):
            guard await center.permission() == .allowed else { return }
            await center.schedule(ClosedAlarm.notice, after: after)
        case .clear:
            center.remove(ClosedAlarm.notice.id)
        case .none:
            break
        }
    }

    func askIfNotAsked() async {
        if let asking { return await asking.value }
        guard await center.permission() == .notAsked else { return }
        if let asking { return await asking.value } // asked while this one checked
        let question = Task { _ = await center.ask() }
        asking = question
        await question.value
        asking = nil
    }
}
