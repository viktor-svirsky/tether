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
        let defaults = SharedGroup.defaults
        let saved = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(WidgetState.self, from: $0) } ?? WidgetState()
        return saved.fresh(alive: defaults?.object(forKey: aliveKey) as? Date, now: now)
    }

    func fresh(alive: Date?, now: Date) -> WidgetState {
        guard awake || sharing else { return self }
        if let alive, abs(now.timeIntervalSince(alive)) < Self.staleAfter { return self }
        return WidgetState(vpn: vpn)
    }

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
        if problem != nil { return "Not running" }
        return awake ? "Waiting" : "Stopped"
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
    static var id: String {
        let app = Bundle.main.bundleURL.pathExtension == "appex"
            ? Bundle(url: Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()) : Bundle.main
        for bundle in [Bundle.main, app].compactMap({ $0 }) {
            if let groups = bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String], let first = groups.first { return first }
        }
        return original
    }

    static var defaults: UserDefaults? { UserDefaults(suiteName: id) }
}
