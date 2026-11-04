import XCTest
@testable import TetherCore

final class ShortcutReplyTests: XCTestCase {
    private typealias State = ShortcutReply.State

    func testStatusCountsTheConnectedDevices() {
        XCTAssertEqual(ShortcutReply.status(State(running: false, connected: 0)), "Tether is waiting for a device to join Personal Hotspot.")
        XCTAssertEqual(ShortcutReply.status(State(running: true, connected: 0)), "Tether is sharing. No device is using it yet.")
        XCTAssertEqual(ShortcutReply.status(State(running: true, connected: 1)), "Tether is sharing with 1 device.")
        XCTAssertEqual(ShortcutReply.status(State(running: true, connected: 3)), "Tether is sharing with 3 devices.")
    }

    func testStatusPassesOnWhyWireGuardIsNotRunning() {
        let state = State(running: true, connected: 0, problem: "Its keys can't be read yet. Unlock this iPhone once.")
        XCTAssertEqual(ShortcutReply.status(state),
                       "Personal Hotspot is on, but WireGuard isn't running. Its keys can't be read yet. Unlock this iPhone once.")
    }

    /// Stopped while idle, a device may be on the hotspot, but Tether waits to be opened (#76).
    func testStatusSaysSharingStoppedWhileIdle() {
        XCTAssertEqual(ShortcutReply.status(State(running: false, connected: 0, idleStopped: true)),
                       "Tether stopped sharing while idle. Open it, or run Start Tether, to share again.")
    }

    func testSharingNeedsWireGuardRunning() {
        XCTAssertTrue(State(running: true, connected: 0).sharing)
        XCTAssertFalse(State(running: true, connected: 0, problem: "Its keys can't be read yet.").sharing)
        XCTAssertFalse(State(running: false, connected: 0).sharing)
    }

    func testStartWithoutTheHotspotSaysHowLongItWaits() {
        XCTAssertEqual(ShortcutReply.start(State(running: false, connected: 0), keptAlive: true),
                       "Tether is ready. It starts sharing when a device joins Personal Hotspot in the next 10 minutes.")
    }

    func testStartWithTheHotspotOnSaysItShares() {
        XCTAssertEqual(ShortcutReply.start(State(running: true, connected: 2), keptAlive: true), "Tether is sharing with 2 devices.")
    }

    func testStartThatCannotStayAliveAsksToOpenTether() {
        XCTAssertEqual(ShortcutReply.start(State(running: true, connected: 0), keptAlive: false),
                       "Tether couldn't keep running in the background. Open it once.")
    }
}
