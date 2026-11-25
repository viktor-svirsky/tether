import XCTest
@testable import TetherCore

final class WidgetStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let sharing = WidgetState(sharing: true, awake: true, connected: [WidgetState.Device(id: UUID(), name: "iPad")], vpn: true)

    /// The app stood by its state within the last rounds: the widget shows it.
    func testAStateTheAppStillStandsByIsShown() {
        XCTAssertEqual(sharing.fresh(alive: now.addingTimeInterval(-20), now: now), sharing)
        XCTAssertEqual(sharing.fresh(alive: now.addingTimeInterval(-119), now: now), sharing)
    }

    /// iOS closed Tether without a last word: the widget mustn't say Sharing for hours, and its
    /// button has to offer Start, not Stop.
    func testAStateTheAppLeftBehindReadsAsStopped() {
        for alive in [now.addingTimeInterval(-120), now.addingTimeInterval(-3600), nil] {
            let shown = sharing.fresh(alive: alive, now: now)
            XCTAssertFalse(shown.sharing)
            XCTAssertFalse(shown.awake)
            XCTAssertEqual(shown.connected, [])
            XCTAssertEqual(shown.title, "Stopped")
        }
    }

    /// A clock set back leaves a time in the future, which doesn't count as fresh for ever.
    func testATimeFarInTheFutureIsNotFresh() {
        XCTAssertFalse(sharing.fresh(alive: now.addingTimeInterval(3600), now: now).sharing)
    }

    /// Stopped is the app's own last word, so it needs no standing by.
    func testAStoppedStateStaysAsItIs() {
        let stopped = WidgetState(problem: "Its keys can't be read yet. Unlock this iPhone once.")
        XCTAssertEqual(stopped.fresh(alive: nil, now: now), stopped)
        XCTAssertEqual(stopped.title, "Not running")
    }

    func testTheTitleSaysWhereTetherStands() {
        XCTAssertEqual(WidgetState().title, "Stopped")
        XCTAssertEqual(WidgetState(awake: true).title, "Waiting")
        XCTAssertEqual(WidgetState(sharing: true, awake: true).title, "Sharing")
        XCTAssertEqual(sharing.title, "Sharing with 1")
        XCTAssertEqual(WidgetState(sharing: true, awake: true, blockedWithoutVPN: true).title, "No VPN")
    }
}
