import ActivityKit
import AppIntents
import Foundation

// Compiled into both the app and the widget extension (Widgets/): what the widgets, the Control
// Center button and the Live Activity show, and the intent their buttons run.

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

    static func load() -> WidgetState {
        SharedGroup.defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(WidgetState.self, from: $0) } ?? WidgetState()
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

/// The Live Activity while Tether shares.
struct TetherActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var connected: [String]
        var vpn: Bool
        var blockedWithoutVPN: Bool
    }
}

/// The widgets' and the Control Center button's Start and Stop. A LiveActivityIntent runs in the
/// app's process, launched in the background if it isn't running, so Start does what Start Tether
/// in Shortcuts does, and Stop stops sharing until Tether is opened or started again. The widget
/// extension compiles it too, for its buttons, but never runs it.
struct SetSharingIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn Tether On or Off"
    static let isDiscoverable = false

    @Parameter(title: "On") var value: Bool
    /// Run from a widget's button, not the Control Center button, see `Model.publishWidgets(after:)`.
    @Parameter(title: "From a Widget", default: false) var fromWidget: Bool

    init() {}

    init(_ on: Bool, fromWidget: Bool = false) {
        value = on
        self.fromWidget = fromWidget
    }

    func perform() async throws -> some IntentResult {
        #if TETHER_APP
        await MainActor.run {
            if value { Model.shared.wake() } else { Model.shared.stopNow() }
        }
        await Model.shared.publishWidgets(after: fromWidget ? .widget : .control)
        #endif
        return .result()
    }
}
