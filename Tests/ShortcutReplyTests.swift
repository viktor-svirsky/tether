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

    /// A device on the proxy uses Tether too. The proxy can't tell its devices apart, so it's named, not counted.
    func testStatusCountsTheProxyWhileAConnectionIsOpenOnIt() {
        XCTAssertEqual(ShortcutReply.status(State(running: true, connected: 0, proxyInUse: true)), "Tether is sharing. The proxy is in use.")
        XCTAssertEqual(ShortcutReply.status(State(running: true, connected: 1, proxyInUse: true)), "Tether is sharing with 1 device and the proxy.")
        XCTAssertEqual(ShortcutReply.status(State(running: true, connected: 2, proxyInUse: true)), "Tether is sharing with 2 devices and the proxy.")
    }

    /// Only share through a VPN is on and no VPN is: sharing, but nothing gets through (#277).
    func testStatusSaysWhenNoVPNKeepsTheDevicesOut() {
        XCTAssertEqual(ShortcutReply.status(State(running: true, connected: 0, blockedWithoutVPN: true)),
                       "Tether is sharing, but no VPN is on, so no device gets through until one is.")
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

    /// The sound didn't start on a cold launch: iOS suspends Tether after the action, so a shortcut
    /// mustn't be told it's sharing (#164).
    func testStatusSaysWhenTetherCantKeepRunning() {
        let state = State(running: true, connected: 0, keptAlive: false)
        XCTAssertFalse(state.sharing)
        XCTAssertEqual(ShortcutReply.status(state), "Tether couldn't keep running in the background. Open it once.")
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
