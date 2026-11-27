import XCTest
@testable import TetherCore

final class WidgetPublisherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let sharing = WidgetState(sharing: true, awake: true, connected: [WidgetState.Device(id: UUID(), name: "iPad")], vpn: true)
    private var facts: LiveActivityFacts { LiveActivityFacts(state: sharing, sessionSharing: true) }

    // MARK: Widgets

    /// A new state is written and every widget and the Control Center button redrawn.
    func testANewStateIsWrittenAndRedrawn() {
        var publisher = WidgetPublisher()
        XCTAssertEqual(publisher.widgets(sharing, now: now),
                       .init(markAlive: true, save: true, reloadWidgets: true, reloadControls: true))
    }

    /// The same state a moment later redraws nothing, for the battery, and is stood by once a minute.
    func testTheSameStateRedrawsNothingAndIsStoodByOnceAMinute() {
        var publisher = WidgetPublisher()
        _ = publisher.widgets(sharing, now: now)
        XCTAssertEqual(publisher.widgets(sharing, now: now.addingTimeInterval(30)), .init())
        XCTAssertEqual(publisher.widgets(sharing, now: now.addingTimeInterval(60)), .init(markAlive: true))
    }

    /// Asleep, a stopped state isn't stood by: a widget reads it as it is, see `WidgetState.load`.
    func testAStoppedStateIsNotStoodBy() {
        var publisher = WidgetPublisher()
        XCTAssertFalse(publisher.widgets(WidgetState(), now: now).markAlive)
    }

    /// Suspended past `WidgetState.staleAfter`, a widget may have drawn Stopped: the same state is news again.
    func testAfterASuspensionTheSameStateIsNewsAgain() {
        var publisher = WidgetPublisher()
        _ = publisher.widgets(sharing, now: now)
        XCTAssertTrue(publisher.widgets(sharing, now: now.addingTimeInterval(WidgetState.staleAfter)).save)
    }

    /// The clock set back by hours: the widgets would read the state as left behind (`fresh` takes
    /// the gap either way), so the app stands by it again and writes it, not waits for the clock.
    func testAClockSetBackMakesTheAppStandByItsStateAgain() {
        var publisher = WidgetPublisher()
        _ = publisher.widgets(sharing, now: now)
        let plan = publisher.widgets(sharing, now: now.addingTimeInterval(-3 * 3600))
        XCTAssertTrue(plan.markAlive)
        XCTAssertTrue(plan.save)
        XCTAssertEqual(publisher.widgets(sharing, now: now.addingTimeInterval(-3 * 3600 + 30)), .init(), "and then settles")
    }

    /// iOS redraws the widget whose button ran: it isn't asked again, and the others catch up next round.
    func testAWidgetsOwnButtonIsNotRedrawnTwice() {
        var publisher = WidgetPublisher()
        let plan = publisher.widgets(sharing, now: now, redrawnByIOS: .widget)
        XCTAssertTrue(plan.save)
        XCTAssertFalse(plan.reloadWidgets)
        XCTAssertTrue(plan.reloadControls)
        XCTAssertTrue(publisher.widgets(sharing, now: now.addingTimeInterval(1)).reloadWidgets, "the other widgets catch up")
    }

    func testTheControlCenterButtonIsNotRedrawnTwice() {
        var publisher = WidgetPublisher()
        let plan = publisher.widgets(sharing, now: now, redrawnByIOS: .control)
        XCTAssertTrue(plan.reloadWidgets)
        XCTAssertFalse(plan.reloadControls)
    }

    // MARK: Live Activity

    private func shown(_ state: WidgetPublisher.ActivityState, facts: LiveActivityFacts? = nil, staleIn: TimeInterval = WidgetPublisher.activityFreshFor) -> WidgetPublisher.Shown {
        WidgetPublisher.Shown(state: state, facts: facts ?? self.facts, staleDate: now.addingTimeInterval(staleIn))
    }

    /// The Live Activity says sharing as the session has it, not as the widgets do: a call stops
    /// the sound, the widgets read Stopped, and the devices are still there.
    func testTheLiveActivityTakesSharingFromTheSession() {
        let duringACall = WidgetState(sharing: false, awake: true, connected: sharing.connected)
        let facts = LiveActivityFacts(state: duringACall, sessionSharing: true)
        XCTAssertTrue(facts.sharing)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.connected, ["iPad"])
        XCTAssertFalse(LiveActivityFacts(state: sharing, sessionSharing: false).sharing)
    }

    func testOneIsStartedOnScreenWhileTetherIsUp() {
        var publisher = WidgetPublisher()
        XCTAssertEqual(publisher.activity(nil, up: true, facts: facts, mayStart: true, now: now),
                       .init(action: .start(facts, staleDate: now.addingTimeInterval(WidgetPublisher.activityFreshFor))))
    }

    /// iOS starts one only on screen or in an action, so a round in the background doesn't ask.
    func testNoneIsStartedFromTheBackground() {
        var publisher = WidgetPublisher()
        XCTAssertEqual(publisher.activity(nil, up: true, facts: facts, mayStart: false, now: now), .init())
    }

    /// On screen a start is tried once a minute at most, and at once when the person asks.
    func testAStartIsTriedOnceAMinute() {
        var publisher = WidgetPublisher()
        _ = publisher.activity(nil, up: true, facts: facts, mayStart: true, now: now)
        XCTAssertEqual(publisher.activity(nil, up: true, facts: facts, mayStart: true, now: now.addingTimeInterval(59)).action, .none)
        XCTAssertNotEqual(publisher.activity(nil, up: true, facts: facts, mayStart: true, now: now.addingTimeInterval(60)).action, .none)
        publisher.activityAsked()
        XCTAssertNotEqual(publisher.activity(nil, up: true, facts: facts, mayStart: true, now: now.addingTimeInterval(61)).action, .none)
    }

    /// The same contents with plenty of time left aren't sent again; a change or a near stale date is.
    func testItIsUpdatedOnAChangeOrToStayFresh() {
        var publisher = WidgetPublisher()
        XCTAssertEqual(publisher.activity(shown(.active), up: true, facts: facts, mayStart: true, now: now), .init())
        var two = facts
        two.count = 2
        XCTAssertEqual(publisher.activity(shown(.active), up: true, facts: two, mayStart: true, now: now).action,
                       .update(two, staleDate: now.addingTimeInterval(WidgetPublisher.activityFreshFor)))
        XCTAssertNotEqual(publisher.activity(shown(.stale, staleIn: WidgetPublisher.activityRenewWithin - 1), up: true, facts: facts, mayStart: false, now: now).action, .none)
    }

    /// Stopped, the activity ends, and only if there's one.
    func testItEndsWhenTetherStops() {
        var publisher = WidgetPublisher()
        XCTAssertEqual(publisher.activity(shown(.active), up: false, facts: facts, mayStart: true, now: now), .init(action: .end))
        XCTAssertEqual(publisher.activity(nil, up: false, facts: facts, mayStart: true, now: now), .init())
    }

    /// Swiped away while it was there a round ago: it stays away until a stop and a start.
    func testOneSwipedAwayStaysAwayUntilAStopAndAStart() {
        var publisher = WidgetPublisher()
        _ = publisher.activity(shown(.active), up: true, facts: facts, mayStart: true, now: now)
        XCTAssertEqual(publisher.activity(shown(.dismissed), up: true, facts: facts, mayStart: true, now: now.addingTimeInterval(10)), .init(forget: true))
        XCTAssertEqual(publisher.activity(nil, up: true, facts: facts, mayStart: true, now: now.addingTimeInterval(200)).action, .none)
        _ = publisher.activity(nil, up: false, facts: facts, mayStart: true, now: now.addingTimeInterval(300))
        XCTAssertNotEqual(publisher.activity(nil, up: true, facts: facts, mayStart: true, now: now.addingTimeInterval(400)).action, .none)
    }

    /// One iOS ended itself, after its 8 hours or a long suspension, is let go of and started again.
    func testOneIOSEndedIsStartedAgain() {
        var publisher = WidgetPublisher()
        _ = publisher.activity(shown(.active), up: true, facts: facts, mayStart: true, now: now)
        let later = now.addingTimeInterval(8 * 3600)
        let plan = publisher.activity(shown(.dismissed), up: true, facts: facts, mayStart: true, now: later)
        XCTAssertTrue(plan.forget)
        XCTAssertEqual(plan.action, .start(facts, staleDate: later.addingTimeInterval(WidgetPublisher.activityFreshFor)))
        let ended = publisher.activity(shown(.ended), up: true, facts: facts, mayStart: true, now: later.addingTimeInterval(61))
        XCTAssertTrue(ended.forget)
        XCTAssertNotEqual(ended.action, .none)
    }
}
