import Foundation

/// Which button ran the widgets' own Start or Stop. iOS redraws that one itself once the intent
/// returns, so asking for it too redrew it twice, and a widget's Stop spun twice before it showed
/// Stopped.
enum WidgetButton { case widget, control }

/// What the Live Activity shows, as Tether decides it. `Model` turns it into the activity's
/// `TetherActivityAttributes.ContentState`, which only the app and the widget extension can build.
struct LiveActivityFacts: Equatable {
    /// The hotspot is on and WireGuard runs. Not, and Tether waits for a device on the hotspot, or
    /// WireGuard couldn't start (`problem`).
    var sharing: Bool
    var count: Int
    /// As many names as `WidgetState.activityNames` lets through: ActivityKit takes 4 KB.
    var connected: [String]
    var vpn: Bool
    var blockedWithoutVPN: Bool
    var problem: String?

    /// Sharing as the session has it, not as the widgets do: a call can stop the sound for a while,
    /// and the devices are still there. Why not, from `problem`, so only a real wait reads as one.
    init(state: WidgetState, sessionSharing: Bool) {
        sharing = sessionSharing
        count = state.connected.count
        connected = WidgetState.activityNames(state.connected.map(\.name))
        vpn = state.vpn
        blockedWithoutVPN = state.blockedWithoutVPN
        problem = state.problem
    }

    init(sharing: Bool, count: Int, connected: [String], vpn: Bool, blockedWithoutVPN: Bool, problem: String?) {
        self.sharing = sharing
        self.count = count
        self.connected = connected
        self.vpn = vpn
        self.blockedWithoutVPN = blockedWithoutVPN
        self.problem = problem
    }
}

/// When the widgets, the Control Center button and the Live Activity hear from Tether. `Model` carries
/// out what it decides with WidgetKit and ActivityKit, like `Notifier` for notices, so each decision
/// can be tested with any clock. Each round, and after the widgets' own Start and Stop.
struct WidgetPublisher {
    /// What the widgets were last given, so they're reloaded only on a change.
    private var widgetState: WidgetState?
    /// When the widgets' state was last stood by, see `WidgetState.markAlive`.
    private var widgetAlive: Date?
    /// The person swiped the Live Activity away, so it isn't started again until a stop and a start.
    private var activityDismissed = false
    /// When a start was last tried.
    private var activityTried: Date?
    /// When the Live Activity was last looked at.
    private var activityChecked: Date?

    /// How long a Live Activity's contents count without a word from Tether. iOS marks it stale
    /// after that, and it says to open Tether: iOS can close Tether with no warning, and the
    /// activity would say Sharing for hours. Renewed with `activityRenewWithin` left, so about three
    /// times an hour, and with every change.
    static let activityFreshFor: TimeInterval = 30 * 60
    static let activityRenewWithin: TimeInterval = 10 * 60
    /// On screen, a start is tried once a minute at most.
    static let activityTryEvery: TimeInterval = 60

    // MARK: Widgets

    /// What to do with the widgets this round.
    struct WidgetPlan: Equatable {
        /// Stand by the state, see `WidgetState.markAlive`.
        var markAlive = false
        /// Write the state for the widgets to read.
        var save = false
        var reloadWidgets = false
        /// The Control Center button, from iOS 18.
        var reloadControls = false
    }

    /// The state changed, or wasn't stood by for a while: write it and redraw. `button` ran the
    /// widgets' own Start or Stop, see `WidgetButton`.
    mutating func widgets(_ state: WidgetState, now: Date, redrawnByIOS button: WidgetButton? = nil) -> WidgetPlan {
        var plan = WidgetPlan()
        // The state wasn't stood by for `WidgetState.staleAfter`: iOS had Tether suspended, and a
        // widget may have taken it for left behind and drawn Stopped. The same state is news again.
        if let alive = widgetAlive, WidgetState.gap(since: alive, now: now) >= WidgetState.staleAfter { widgetState = nil }
        let changed = state != widgetState
        // Stood by once a minute while awake, with no redraw, see `WidgetState.load`.
        if state.awake, changed || widgetAlive.map({ WidgetState.gap(since: $0, now: now) >= 60 }) ?? true {
            plan.markAlive = true
            widgetAlive = now
        }
        guard changed else { return plan }
        plan.save = true
        // iOS redraws the widget whose button ran, but perhaps not Tether's other widgets. Left
        // unremembered, the next round's state counts as a change and redraws them all. After Stop
        // there's no next round, and they catch up at their timeline's next reload.
        widgetState = button == .widget ? nil : state
        plan.reloadWidgets = button != .widget
        plan.reloadControls = button != .control
        return plan
    }

    // MARK: Live Activity

    /// What iOS says of the Live Activity Tether holds, see ActivityKit's `ActivityState`.
    enum ActivityState { case active, stale, ended, dismissed }

    /// The one Tether holds, as iOS has it.
    struct Shown {
        var state: ActivityState
        var facts: LiveActivityFacts
        var staleDate: Date?
    }

    enum ActivityAction: Equatable {
        case none
        /// Start one with these, stale after `staleDate`.
        case start(LiveActivityFacts, staleDate: Date)
        case update(LiveActivityFacts, staleDate: Date)
        case end
    }

    struct ActivityPlan: Equatable {
        /// iOS ended the one Tether held, or the person swiped it away: let go of it before `action`.
        var forget = false
        var action = ActivityAction.none
    }

    /// The person asked for a Start or a Stop, so a start is tried now.
    mutating func activityAsked() { activityTried = nil }

    /// A Live Activity from a start to a stop: while Tether shares or waits for the hotspot (`up`,
    /// see `HotspotSession.up`). Updated when sharing, the devices or the VPN change. iOS starts one
    /// only while Tether is on screen or runs an action (`mayStart`), so a round in the background
    /// doesn't ask, and on screen it's tried once a minute at most. One iOS ended after its 8 hours is
    /// started again, and one swiped away stays away until Tether is stopped and started.
    mutating func activity(_ shown: Shown?, up: Bool, facts: LiveActivityFacts, mayStart: Bool, now: Date) -> ActivityPlan {
        var plan = ActivityPlan()
        var live = shown
        if let shown, shown.state != .active, shown.state != .stale {
            // Swiped away by the person if it was there a round ago. After a long suspension it's as
            // likely iOS, which removes one it ended itself, and that one is started again.
            // Both times are taken either way, so a clock set back reads as time gone by, see `WidgetState.gap`.
            let justNow = activityChecked.map { WidgetState.gap(since: $0, now: now) < WidgetState.staleAfter } ?? false
            if shown.state == .dismissed, justNow { activityDismissed = true }
            plan.forget = true
            live = nil
        }
        activityChecked = now
        guard up else {
            activityDismissed = false
            if live != nil { plan.action = .end }
            return plan
        }
        let staleDate = now.addingTimeInterval(Self.activityFreshFor)
        if let live {
            let renew = live.staleDate.map { $0.timeIntervalSince(now) < Self.activityRenewWithin } ?? true
            if live.facts != facts || renew { plan.action = .update(facts, staleDate: staleDate) }
            return plan
        }
        guard mayStart, !activityDismissed, activityTried.map({ WidgetState.gap(since: $0, now: now) >= Self.activityTryEvery }) ?? true else { return plan }
        activityTried = now
        plan.action = .start(facts, staleDate: staleDate)
        return plan
    }
}
