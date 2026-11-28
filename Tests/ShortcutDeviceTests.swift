import XCTest
@testable import TetherCore

/// List, Pause and Resume Tether Device in Shortcuts (#310): what each says back, and that Pause and
/// Resume change the device as its screen does, also for one removed since the shortcut picked it.
@MainActor
final class ShortcutDeviceTests: XCTestCase {
    private let hotspot = "172.20.10.1"
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private var now = Date()
    private var server: FakeServer!
    private var secrets: FlakySecrets!
    private var devices: WireGuardDevices!
    private var session: HotspotSession!
    private let usageDefaults: UserDefaults = {
        let d = UserDefaults(suiteName: "ShortcutDeviceTests")!
        d.removePersistentDomain(forName: "ShortcutDeviceTests")
        return d
    }()

    private func at(_ hour: Int, _ minute: Int, day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    /// A session with one listed device, connected, at 3:15 PM on 10 November.
    private func iPad() throws -> WireGuardSetup.Peer {
        now = at(15, 15)
        secrets = FlakySecrets()
        usageDefaults.removePersistentDomain(forName: "ShortcutDeviceTests")
        server = FakeServer()
        devices = WireGuardDevices(secrets: secrets)
        session = HotspotSession(devices: devices, server: server, keepAlive: FakeSound(), page: FakePage(),
                                 sceneActive: false, hotspotAddress: { [unowned self] in hotspot },
                                 usageDefaults: usageDefaults, calendar: calendar, now: { [unowned self] in now })
        session.syncWithHotspot()
        let peer = try XCTUnwrap(devices.connectReady())
        server.connected = [peer.address]
        session.syncWithHotspot()
        return peer
    }

    /// The narrow space some versions put before PM, as a plain one, see FormatTests.
    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    private func pause(of peer: WireGuardSetup.Peer) -> WireGuardSetup.Pause? {
        session.wireGuardPeers.first { $0.id == peer.id }?.paused
    }

    // MARK: Replies

    func testTheListSaysEachDeviceAsItsRowDoes() {
        let devices = [ShortcutReply.Device(id: UUID(), name: "iPad", status: "Connected"),
                       ShortcutReply.Device(id: UUID(), name: "Kids iPad", status: "Paused until 9:00 PM")]
        XCTAssertEqual(ShortcutReply.devices(devices), "iPad: Connected\nKids iPad: Paused until 9:00 PM")
        XCTAssertEqual(ShortcutReply.devices([]), "Tether has no devices yet. Add one in Tether.")
    }

    func testPauseSaysUntilWhen() {
        XCTAssertEqual(ShortcutReply.paused("Kids iPad", until: "9:00 PM", wasPaused: false), "Kids iPad is paused until 9:00 PM.")
        XCTAssertEqual(ShortcutReply.paused("Kids iPad", until: nil, wasPaused: false), "Kids iPad is paused until you resume it.")
        XCTAssertEqual(ShortcutReply.paused("Kids iPad", until: "9:00 PM", wasPaused: true),
                       "Kids iPad was already paused. It's now paused until 9:00 PM.")
        XCTAssertEqual(ShortcutReply.paused("Kids iPad", until: nil, wasPaused: true),
                       "Kids iPad was already paused. It's now paused until you resume it.")
    }

    func testResumeAndTheMisses() {
        XCTAssertEqual(ShortcutReply.resumed("Kids iPad"), "Kids iPad can connect again.")
        XCTAssertEqual(ShortcutReply.notPaused("Kids iPad"), "Kids iPad isn't paused.")
        XCTAssertEqual(ShortcutReply.gone("Kids iPad"), "Tether has no device called Kids iPad any more.")
        XCTAssertEqual(ShortcutReply.notSaved, "Tether couldn't save the change. Try again on the device's screen in Tether.")
    }

    // MARK: The session

    /// In the background, as a launch for the action is: connected by the server's read.
    func testTheListReadsWhoIsConnectedFromTheServer() throws {
        let peer = try iPad()
        let listed = session.shortcutDevices()
        XCTAssertEqual(listed.map(\.id), [peer.id])
        XCTAssertEqual(listed.first?.status, "Connected")
        server.connected = []
        XCTAssertEqual(session.shortcutDevices().first?.status, "Not connected")
    }

    func testPauseForAnHourPausesItAndSaysUntilWhen() throws {
        let peer = try iPad()
        let reply = session.shortcutPause(peer.id, named: peer.name, for: .hour)
        XCTAssertEqual(pause(of: peer), .until(at(16, 15)))
        XCTAssertEqual(plain(reply), "\(peer.name) is paused until 4:15 PM.")
        XCTAssertEqual(plain(session.shortcutDevices().first?.status ?? ""), "Paused until 4:15 PM")
    }

    func testPauseUntilResumedSaysSo() throws {
        let peer = try iPad()
        XCTAssertEqual(session.shortcutPause(peer.id, named: peer.name, for: .untilResumed), "\(peer.name) is paused until you resume it.")
        XCTAssertEqual(pause(of: peer), .byYou)
    }

    /// The new length replaces the old one: a shortcut that pauses for the night after a pause by hand.
    func testPausingAPausedDeviceTakesTheNewLength() throws {
        let peer = try iPad()
        session.pauseWireGuardDevice(peer.id)
        let reply = session.shortcutPause(peer.id, named: peer.name, for: .halfHour)
        XCTAssertEqual(pause(of: peer), .until(at(15, 45)))
        XCTAssertEqual(plain(reply), "\(peer.name) was already paused. It's now paused until 3:45 PM.")
    }

    func testResumeLetsItConnectAgain() throws {
        let peer = try iPad()
        session.pauseWireGuardDevice(peer.id, for: .hour)
        XCTAssertEqual(session.shortcutResume(peer.id, named: peer.name), "\(peer.name) can connect again.")
        XCTAssertNil(pause(of: peer))
        XCTAssertEqual(session.shortcutResume(peer.id, named: peer.name), "\(peer.name) isn't paused.")
    }

    /// Removed since the shortcut picked it: said, and nothing else changes.
    func testARemovedDeviceIsSaidByTheNameTheShortcutHas() throws {
        let peer = try iPad()
        XCTAssertTrue(session.removeWireGuardDevice(peer.id))
        XCTAssertEqual(session.shortcutPause(peer.id, named: "Kids iPad", for: .hour), "Tether has no device called Kids iPad any more.")
        XCTAssertEqual(session.shortcutResume(peer.id, named: "Kids iPad"), "Tether has no device called Kids iPad any more.")
    }

    /// A pause that couldn't be saved changes nothing, and the action says so instead of that it did.
    func testAPauseThatCantBeSavedSaysSo() throws {
        let peer = try iPad()
        secrets.savesFail = true
        XCTAssertEqual(session.shortcutPause(peer.id, named: peer.name, for: .hour), ShortcutReply.notSaved)
        XCTAssertNil(pause(of: peer))
    }
}
