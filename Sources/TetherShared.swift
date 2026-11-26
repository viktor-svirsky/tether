import ActivityKit
import AppIntents
import Foundation

// Compiled into both the app and the widget extension (Widgets/), with WidgetState.swift: the Live
// Activity's contents and the intent the widgets' buttons run.

/// The Live Activity while Tether shares.
struct TetherActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The hotspot is on and WireGuard runs. Not, and Tether waits for a device on the hotspot.
        var sharing: Bool
        /// How many devices are connected.
        var count: Int
        /// Their names, as many as `WidgetState.activityNames` lets through: ActivityKit takes 4 KB.
        var connected: [String]
        var vpn: Bool
        var blockedWithoutVPN: Bool

        init(sharing: Bool, count: Int, connected: [String], vpn: Bool, blockedWithoutVPN: Bool) {
            self.sharing = sharing
            self.count = count
            self.connected = connected
            self.vpn = vpn
            self.blockedWithoutVPN = blockedWithoutVPN
        }

        /// A Live Activity left by a build from before `count` has every name.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sharing = try c.decode(Bool.self, forKey: .sharing)
            connected = try c.decode([String].self, forKey: .connected)
            count = try c.decodeIfPresent(Int.self, forKey: .count) ?? connected.count
            vpn = try c.decode(Bool.self, forKey: .vpn)
            blockedWithoutVPN = try c.decode(Bool.self, forKey: .blockedWithoutVPN)
        }
    }
}

/// The widgets' and the Control Center button's Start and Stop. A LiveActivityIntent runs in the
/// app's process, launched in the background if it isn't running, so Start does what Start Tether
/// in Shortcuts does, and Stop stops sharing until Tether is opened or started again. The widget
/// extension compiles it too, for its buttons, but never runs it.
///
/// The widgets' buttons work from iOS 17. The Control Center button is iOS 18's, and so is
/// SetValueIntent, which its toggle asks for: see the extension below.
struct SetSharingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn Tether On or Off"
    static let isDiscoverable = false
    /// Not from a locked iPhone: whoever holds it could start sharing again after a Stop.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

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
            _ = value ? Model.shared.wake() : Model.shared.stopNow()
        }
        await Model.shared.publishWidgets(after: fromWidget ? .widget : .control)
        #endif
        return .result()
    }
}

@available(iOS 18, *)
extension SetSharingIntent: SetValueIntent {}
