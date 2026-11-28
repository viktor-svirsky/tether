import XCTest
@testable import TetherCore

/// What the status card at the top of Home says (H1, M9), the waiting hint (H2), and the warnings
/// and notes under it (M13).
final class HomeStatusTests: XCTestCase {
    private func status(localNetworkDenied: Bool = false, problem: WireGuardProblem? = nil, sharing: Bool = false,
                        blocked: Bool = false, onlyFamily: Interfaces.Family? = nil) -> HomeStatus {
        HomeStatus(localNetworkDenied: localNetworkDenied, problem: problem, sharing: sharing, blockedWithoutVPN: blocked, onlyFamily: onlyFamily)
    }

    /// Local Network first, then WireGuard's problem, hotspot or not, then the VPN rule, sharing, waiting.
    func testOneStateInOrder() {
        XCTAssertEqual(status(localNetworkDenied: true, problem: .keysLocked, sharing: true, blocked: true), .localNetworkOff)
        XCTAssertEqual(status(problem: .keysLocked), .problem(.keysLocked), "with the hotspot off too")
        XCTAssertEqual(status(sharing: true, blocked: true, onlyFamily: .ipv4), .keptOut(onlyFamily: .ipv4))
        XCTAssertEqual(status(sharing: true), .sharing)
        XCTAssertEqual(status(blocked: true), .waiting, "the VPN rule keeps nobody out without the hotspot")
        XCTAssertEqual(status(), .waiting)
    }

    func testWhatEachStateSays() {
        let cases: [(HomeStatus, String, String?, String?, Bool, UInt)] = [
            (.localNetworkOff, "Devices can't connect", "Local Network is off for Tether", nil, false, #line),
            (.problem(.portTaken), "Port 51820 is taken", WireGuardProblem.portTaken.line, nil, false, #line),
            (.keptOut(onlyFamily: nil), "Devices kept out", "No VPN is on",
             "No device gets through until a VPN is on. Turn your VPN on, or turn off Only share through a VPN in Settings.", false, #line),
            (.keptOut(onlyFamily: .ipv4), "Devices kept out", "Your VPN carries only IPv4",
             "This iPhone's IPv6 goes around it, so no device gets through. Turn on IPv6 in your VPN, or turn off Only share through a VPN in Settings.", false, #line),
            (.sharing, "Sharing", nil, nil, true, #line),
            (.waiting, "Waiting for a device on the hotspot", nil, nil, false, #line),
        ]
        for (state, title, line, body, live, at) in cases {
            XCTAssertEqual(state.title, title, line: at)
            XCTAssertEqual(state.line, line, line: at)
            XCTAssertEqual(state.body, body, line: at)
            XCTAssertEqual(state.live, live, line: at)
        }
    }

    /// The number is the keep-alive's wait, as Start Tether's reply says it (H2).
    func testTheSleepHintFollowsTheKeepAlivesWait() {
        XCTAssertEqual(KeepAlivePolicy.grace, 600)
        XCTAssertEqual(WakeHelp.minutes, Int(KeepAlivePolicy.grace / 60))
        XCTAssertEqual(HomeStatus.sleepHint,
                       "Open Tether before you turn the hotspot on. It waits 10 minutes after you leave it, then sleeps. To wake it without opening it, see Settings > Help.")
        XCTAssertEqual(WakeHelp.title, "Start without opening Tether")
        XCTAssertEqual(WakeHelp.lines.last, "Each one wakes Tether for 10 minutes, the same as opening it.")
        XCTAssertEqual(WakeHelp.lines.count, 4)
    }

    // MARK: Warnings and notes (M13)

    private let stop = LastStop(at: Date(timeIntervalSince1970: 1_800_000_000), reason: .byYou)

    /// Battery, stale config, expiry, then the notes, whatever order they come in.
    func testWarningsComeInOneOrder() {
        let all: [HomeNote] = [.offerNotifications, .stopIgnored, .lastStop(stop), .expiry("x"), .staleConfig, .lowBattery("b")]
        XCTAssertEqual(HomeNote.fold(all, expanded: true).shown,
                       [.lowBattery("b"), .staleConfig, .expiry("x"), .lastStop(stop), .stopIgnored, .offerNotifications])
        XCTAssertEqual(all.filter(\.isNote), [.offerNotifications, .stopIgnored, .lastStop(stop)])
    }

    /// One or two all show. Three or more fold behind "2 more" until it's tapped.
    func testThreeOrMoreFold() {
        XCTAssertEqual(HomeNote.fold([], expanded: false).shown, [])
        XCTAssertNil(HomeNote.fold([.staleConfig], expanded: false).more)
        let two = HomeNote.fold([.expiry("x"), .lowBattery("b")], expanded: false)
        XCTAssertEqual(two.shown, [.lowBattery("b"), .expiry("x")])
        XCTAssertNil(two.more)
        let three = HomeNote.fold([.expiry("x"), .stopIgnored, .lowBattery("b")], expanded: false)
        XCTAssertEqual(three.shown, [.lowBattery("b")])
        XCTAssertEqual(three.more, "2 more")
        XCTAssertEqual(HomeNote.fold([.expiry("x"), .stopIgnored, .lowBattery("b"), .staleConfig], expanded: false).more, "3 more")
        let open = HomeNote.fold([.expiry("x"), .stopIgnored, .lowBattery("b")], expanded: true)
        XCTAssertEqual(open.shown.count, 3)
        XCTAssertNil(open.more)
    }

    func testWhatEachNoteSays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = stop.at.addingTimeInterval(60)
        func text(_ note: HomeNote) -> String { note.text(now: now, calendar: calendar, locale: Locale(identifier: "en_US")) }
        XCTAssertEqual(text(.lowBattery("Battery at 18%.")), "Battery at 18%.")
        XCTAssertEqual(text(.expiry("Tether stops opening today.")), "Tether stops opening today.")
        XCTAssertEqual(text(.staleConfig),
                       "A device is trying to connect with a config that no longer works. Delete its tunnel in WireGuard, then add the device again.")
        XCTAssertEqual(text(.lastStop(stop)), stop.text(now: now, calendar: calendar, locale: Locale(identifier: "en_US")))
        XCTAssertEqual(text(.stopIgnored), "Stop does nothing while Tether is open. To stop, turn off Personal Hotspot.")
        XCTAssertEqual(text(.offerNotifications), "Tether can tell you when a device connects or sharing stops.")
    }

    /// The warnings keep the identifiers the UI tests know them by.
    func testTheWarningsKeepTheirIdentifiers() {
        XCTAssertEqual(HomeNote.lowBattery("").id, "battery.low")
        XCTAssertEqual(HomeNote.staleConfig.id, "stale.warning")
        XCTAssertEqual(HomeNote.expiry("").id, "app.expiry")
        XCTAssertEqual(HomeNote.lastStop(stop).id, "note.lastStop")
        XCTAssertEqual(HomeNote.stopIgnored.id, "note.stopIgnored")
        XCTAssertEqual(HomeNote.offerNotifications.id, "note.notifications")
    }
}
