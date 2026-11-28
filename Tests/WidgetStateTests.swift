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
            XCTAssertFalse(shown.vpn, "nobody has looked at the VPN since either")
            XCTAssertEqual(shown.detail, "")
        }
    }

    /// The line under the title never repeats it, and names the VPN only while Tether is awake, and
    /// only while one is on: most people run none, so "No VPN" told nearly everyone something wrong (M10).
    func testTheDetailSaysWhatTheTitleDoesNot() {
        XCTAssertEqual(sharing.detail, "Through a VPN")
        XCTAssertEqual(WidgetState(sharing: true, awake: true).detail, "")
        XCTAssertEqual(WidgetState(sharing: true, awake: true, blockedWithoutVPN: true).detail, "Devices kept out")
        XCTAssertEqual(WidgetState(awake: true, vpn: true).detail, "Through a VPN")
        XCTAssertEqual(WidgetState(awake: true).detail, "")
        XCTAssertEqual(WidgetState(vpn: true).detail, "", "stopped: the VPN was last looked at who knows when")
        XCTAssertEqual(WidgetState(problem: WireGuardProblem.keysLocked.title).detail, "Tether can't read its keys yet")
    }

    /// Signed without the app group, a widget says so, not Stopped.
    func testAnInstallWithoutTheAppGroupSaysSo() {
        let state = WidgetState(problem: WidgetState.noGroup)
        XCTAssertEqual(state.title, "No data")
        XCTAssertEqual(state.detail, WidgetState.noGroup)
    }

    /// ActivityKit drops an update whose state is over 4 KB, so the Live Activity carries the names
    /// that fit and the count of all of them.
    func testTheLiveActivityCarriesTheNamesThatFit() throws {
        XCTAssertEqual(WidgetState.activityNames(["iPad", "Pixel 9"]), ["iPad", "Pixel 9"])
        XCTAssertEqual(WidgetState.activityNames([]), [])

        let many = (1...250).map { "Device number \($0) of a very long list" }
        let kept = WidgetState.activityNames(many)
        XCTAssertEqual(kept, Array(many.prefix(kept.count)), "the first ones, in their order")
        XCTAssertGreaterThan(kept.count, 3)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(kept).count, WidgetState.activityNameBytes + 2)

        // The worst a name can be: long, and every character many bytes as JSON.
        let worst = [String](repeating: String(repeating: "\u{1}👨‍👩‍👧‍👦", count: 500), count: 250)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(WidgetState.activityNames(worst)).count, WidgetState.activityNameBytes + 2)
        XCTAssertEqual(WidgetState.activityNames([String(repeating: "a", count: 100)]), [String(repeating: "a", count: 40)])
        XCTAssertEqual(WidgetState.activityNames(["iPad", "Pixel"], budget: 8), ["iPad"], "\"iPad\", is 7 bytes")
    }

    /// A clock set back leaves a time in the future, which doesn't count as fresh for ever.
    func testATimeFarInTheFutureIsNotFresh() {
        XCTAssertFalse(sharing.fresh(alive: now.addingTimeInterval(3600), now: now).sharing)
    }

    /// A clock set back counts as time gone by, the way `fresh` reads it, so the app stands by its
    /// state again instead of waiting for the clock to catch up while widgets say Stopped.
    func testAClockSetBackCountsAsTimeGoneBy() {
        XCTAssertEqual(WidgetState.gap(since: now.addingTimeInterval(300), now: now), 300)
        XCTAssertEqual(WidgetState.gap(since: now.addingTimeInterval(-30), now: now), 30)
        XCTAssertGreaterThanOrEqual(WidgetState.gap(since: now.addingTimeInterval(WidgetState.staleAfter), now: now), WidgetState.staleAfter)
    }

    /// The Live Activity says waiting only while Tether really waits for a device on the hotspot.
    func testTheLiveActivitySaysWhereTetherStands() {
        XCTAssertEqual(WidgetState.activityHeadline(sharing: false, count: 0, blockedWithoutVPN: false, problem: nil), "Waiting for a device on the hotspot")
        XCTAssertEqual(WidgetState.activityHeadline(sharing: true, count: 0, blockedWithoutVPN: false, problem: nil), "Sharing, no device connected")
        XCTAssertEqual(WidgetState.activityHeadline(sharing: true, count: 1, blockedWithoutVPN: false, problem: nil), "Sharing with 1 device")
        XCTAssertEqual(WidgetState.activityHeadline(sharing: true, count: 3, blockedWithoutVPN: false, problem: nil), "Sharing with 3 devices")
        XCTAssertEqual(WidgetState.activityHeadline(sharing: true, count: 2, blockedWithoutVPN: true, problem: nil), "No VPN, devices kept out")
        // WireGuard couldn't start: not a wait.
        XCTAssertEqual(WidgetState.activityHeadline(sharing: false, count: 0, blockedWithoutVPN: false, problem: "Port 51820 is taken."), "Not running")
    }

    /// The line under it: the problem when there is one, else the names and the count of the rest.
    func testTheLiveActivityLineSaysTheProblemFirst() {
        XCTAssertEqual(WidgetState.activityLine(sharing: false, count: 0, names: [], problem: "Port 51820 is taken."), "Port 51820 is taken.")
        let cantStay = "Tether couldn't keep running in the background. Open it once."
        XCTAssertEqual(WidgetState.activityLine(sharing: true, count: 2, names: ["iPad", "Pixel"], problem: cantStay), cantStay)
        XCTAssertEqual(WidgetState.activityLine(sharing: true, count: 2, names: ["iPad", "Pixel"], problem: nil), "iPad, Pixel")
        XCTAssertEqual(WidgetState.activityLine(sharing: true, count: 3, names: ["iPad"], problem: nil), "iPad, 2 more")
        XCTAssertEqual(WidgetState.activityLine(sharing: true, count: 0, names: [], problem: nil), "No device connected")
        XCTAssertEqual(WidgetState.activityLine(sharing: false, count: 0, names: [], problem: nil), "")
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
