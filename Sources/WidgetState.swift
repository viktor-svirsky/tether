import Foundation

// Compiled into both the app and the widget extension (Widgets/): what the widgets, the Control
// Center button and the Live Activity show. Foundation only, so `swift test` covers it.

/// Where Tether stands, as the app last wrote it into the app group for the widget extension.
struct WidgetState: Codable, Equatable {
    /// The hotspot is on and WireGuard runs.
    var sharing = false
    /// Awake: sharing, or waiting for the hotspot with the sound playing. Off after Stop, the idle
    /// stop, or once iOS may suspend it. The Control Center button shows this.
    var awake = false
    var problem: String?
    /// The connected devices, in the list's order.
    var connected: [Device] = []
    var vpn = false
    var blockedWithoutVPN = false

    /// By its id, since two devices can have the same name.
    struct Device: Codable, Equatable, Identifiable {
        var id: UUID
        var name: String
    }

    /// The names a Live Activity carries, of all the connected devices' names, in their order: as
    /// many as fit in `budget` bytes of JSON, each cut to `nameLength` characters. ActivityKit takes
    /// 4 KB of state and drops an update over that, so with many devices or long names the Live
    /// Activity would stop following. It shows a line of names, and the count of the rest.
    static func activityNames(_ names: [String], budget: Int = activityNameBytes) -> [String] {
        var kept: [String] = []
        var left = budget
        for name in names {
            let short = String(name.prefix(activityNameLength))
            // As JSON it's quoted, escaped, and followed by a comma.
            guard let size = (try? JSONEncoder().encode([short]))?.count, size - 1 <= left else { break }
            left -= size - 1
            kept.append(short)
        }
        return kept
    }

    static let activityNameBytes = 1024
    static let activityNameLength = 40

    static let key = "widget.state"
    static let aliveKey = "widget.alive"
    /// The app marks itself alive each watcher round while awake, every 15 seconds in the background.
    /// Eight rounds missed, and iOS has killed or suspended Tether without a last word (#164).
    static let staleAfter: TimeInterval = 120
    /// How often a widget looks again while Tether is awake, to notice that. Never while it's stopped.
    static let lookAgainAfter: TimeInterval = 15 * 60

    /// What the app last wrote. An awake state the app hasn't stood by for `staleAfter` reads as
    /// stopped, so a widget doesn't say Sharing for hours after iOS closed Tether, and its button
    /// offers Start.
    static func load(now: Date = Date()) -> WidgetState {
        guard SharedGroup.available else { return WidgetState(problem: noGroup) }
        let defaults = SharedGroup.defaults
        let saved = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(WidgetState.self, from: $0) } ?? WidgetState()
        return saved.fresh(alive: defaults?.object(forKey: aliveKey) as? Date, now: now)
    }

    func fresh(alive: Date?, now: Date) -> WidgetState {
        guard awake || sharing else { return self }
        if let alive, Self.gap(since: alive, now: now) < Self.staleAfter { return self }
        return WidgetState() // not the VPN either: nobody has looked since
    }

    /// The time since `alive`, either way: a clock set back leaves `alive` in the future, and that
    /// counts as time gone by too, or the app would wait for the clock to catch up while widgets
    /// read its state as left behind.
    static func gap(since alive: Date, now: Date) -> TimeInterval {
        abs(now.timeIntervalSince(alive))
    }

    /// The Live Activity's headline. Waiting only while Tether waits for a device on the hotspot,
    /// not when WireGuard couldn't start.
    static func activityHeadline(sharing: Bool, count: Int, blockedWithoutVPN: Bool, problem: String?) -> String {
        if !sharing, problem != nil { return "Not running" }
        guard sharing else { return Copy.waitingForDevice }
        if blockedWithoutVPN { return "No VPN, devices kept out" }
        switch count {
        case 0: return "Sharing, no device yet"
        case 1: return "Sharing with 1 device"
        case let n: return "Sharing with \(n) devices"
        }
    }

    /// The line under it: the problem, or the names that fit (`activityNames`) and the count of the rest.
    static func activityLine(sharing: Bool, count: Int, names: [String], problem: String?) -> String {
        if let problem { return problem }
        guard count > 0 else { return sharing ? "No device connected" : "" }
        let more = count - names.count
        guard more > 0 else { return names.joined(separator: ", ") }
        return (names + ["\(more) more"]).joined(separator: ", ")
    }

    /// What a widget says when the install has no app group to read Tether's state through, see
    /// `SharedGroup.available`.
    static let noGroup = "This install was signed without Tether's app group, so widgets can't see it."

    static func markAlive(_ now: Date = Date()) {
        SharedGroup.defaults?.set(now, forKey: aliveKey)
    }

    func save() {
        SharedGroup.defaults?.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    /// "Sharing with 2 devices", "Waiting for the hotspot", "Stopped".
    var title: String {
        if sharing, blockedWithoutVPN { return "No VPN" }
        if sharing { return connected.isEmpty ? "Sharing" : "Sharing with \(connected.count)" }
        if problem == Self.noGroup { return "No data" }
        if problem != nil { return "Not running" }
        return awake ? "Waiting" : "Stopped"
    }

    /// The line under the title: why it isn't running, that devices are kept out, or the VPN. The
    /// VPN only while Tether is awake to have looked.
    var detail: String {
        if let problem, !sharing { return problem }
        if sharing, blockedWithoutVPN { return "Devices kept out" }
        guard awake else { return "" }
        if vpn { return "Through a VPN" }
        return sharing ? "No VPN" : ""
    }
}

enum SharedGroup {
    /// The group the build asks for, group.<the app's bundle ID>, from TetherAppGroup in Info.plist
    /// (project.yml), so a build under another team's bundle ID has its own.
    static var original: String {
        Bundle.main.object(forInfoDictionaryKey: "TetherAppGroup") as? String ?? "group.com.vsvirskyi.phoneshare"
    }

    /// SideStore and AltStore give an app group a name of the signer's own, and list the new names
    /// under ALTAppGroups in the app's Info.plist. The extension looks in its app's too.
    /// Read once: it can't change while the process runs.
    static let id: String = {
        let app = Bundle.main.bundleURL.pathExtension == "appex"
            ? Bundle(url: Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()) : Bundle.main
        for bundle in [Bundle.main, app].compactMap({ $0 }) {
            if let groups = bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String], let first = groups.first { return first }
        }
        return original
    }()

    /// UserDefaults is thread-safe (Apple documents it so), but the SDK doesn't mark it Sendable.
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: id)

    /// The signature really carries the group. Without it `UserDefaults(suiteName:)` still gives a
    /// store, but each process its own, so the widgets would say Stopped for ever: a signer that
    /// drops the entitlement (some do, with their own profile) is told apart by the container.
    static let available = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil
}
