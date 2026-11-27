import XCTest
@testable import TetherCore

/// Pausing a device for a set time (#312): saved with its end, said on its row and screen, and
/// resumed by the first round at or after the end, never before. The proxy goes by the same rules.
@MainActor
final class TimedPauseTests: XCTestCase {
    private let hotspot = "172.20.10.1"
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private var now = Date()
    private var server: FakeServer!
    private var secrets: InMemorySecrets!
    private var devices: WireGuardDevices!
    private var session: HotspotSession!
    private let usageDefaults: UserDefaults = {
        let d = UserDefaults(suiteName: "TimedPauseTests")!
        d.removePersistentDomain(forName: "TimedPauseTests")
        return d
    }()

    private func at(_ hour: Int, _ minute: Int, day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func makeSession() {
        usageDefaults.removePersistentDomain(forName: "TimedPauseTests")
        server = FakeServer()
        devices = WireGuardDevices(secrets: secrets)
        session = HotspotSession(devices: devices, server: server, keepAlive: FakeSound(), page: FakePage(),
                                 sceneActive: true, hotspotAddress: { [unowned self] in hotspot },
                                 usageDefaults: usageDefaults, calendar: calendar, now: { [unowned self] in now })
        session.syncWithHotspot()
    }

    /// A session with one listed device, connected, at 3:15 PM on 10 November.
    private func iPad() throws -> WireGuardSetup.Peer {
        now = at(15, 15)
        secrets = InMemorySecrets()
        makeSession()
        let peer = try XCTUnwrap(devices.connectReady())
        server.connected = [peer.address]
        session.sampleTraffic()
        return peer
    }

    /// The narrow space some versions put before PM, as a plain one, see FormatTests.
    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    private func pause(of peer: WireGuardSetup.Peer) -> WireGuardSetup.Pause? {
        session.wireGuardPeers.first { $0.id == peer.id }?.paused
    }

    // MARK: Saved

    func testATimedPauseIsSavedWithItsEnd() throws {
        var setup = WireGuardSetup.new()
        let peer = try XCTUnwrap(setup.addPeer(name: "iPad"))
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        setup.pausePeer(peer.id, .until(end))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(setup)) as? [String: Any])
        let peers = try XCTUnwrap(json["peers"] as? [[String: Any]])
        let saved = try XCTUnwrap(peers[0]["paused"] as? [String: Any])
        XCTAssertEqual(saved["why"] as? String, "until")
        XCTAssertEqual(saved["at"] as? Double, 1_800_000_000)
        XCTAssertEqual(try JSONDecoder().decode(WireGuardSetup.self, from: JSONEncoder().encode(setup)), setup)
    }

    /// An older release reads any reason it doesn't know as paused by you, so installed over this one,
    /// a timed pause stays paused there and can be resumed by hand. A timed pause saved without its
    /// end reads the same way here.
    func testAnOlderReleaseAndAMissingEndReadItAsPausedByYou() throws {
        var setup = WireGuardSetup.new()
        let peer = try XCTUnwrap(setup.addPeer(name: "iPad"))
        setup.pausePeer(peer.id, .until(Date(timeIntervalSince1970: 1_800_000_000)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(setup)) as? [String: Any])
        let why = try XCTUnwrap(((json["peers"] as? [[String: Any]])?[0]["paused"] as? [String: Any])?["why"] as? String)
        XCTAssertFalse(["you", "limit"].contains(why), "a reason older releases don't know, so they read paused by you")
        let noEnd = try JSONDecoder().decode(WireGuardSetup.Pause.self, from: Data(#"{"why": "until"}"#.utf8))
        XCTAssertEqual(noEnd, .byYou)
    }

    // MARK: The lengths

    func testTheLengthsEndWhenTheirNamesSay() {
        let start = at(15, 15)
        XCTAssertEqual(WireGuardSetup.PauseLength.allCases.map(\.title), ["For 30 minutes", "For 1 hour", "Until tomorrow", "Until I resume it"])
        XCTAssertEqual(WireGuardSetup.PauseLength.halfHour.pause(from: start, calendar: calendar), .until(at(15, 45)))
        XCTAssertEqual(WireGuardSetup.PauseLength.hour.pause(from: start, calendar: calendar), .until(at(16, 15)))
        XCTAssertEqual(WireGuardSetup.PauseLength.untilTomorrow.pause(from: start, calendar: calendar), .until(at(6, 0, day: 11)))
        XCTAssertEqual(WireGuardSetup.PauseLength.untilTomorrow.pause(from: at(1, 30), calendar: calendar), .until(at(6, 0, day: 11)),
                       "the next morning, even after midnight")
        XCTAssertEqual(WireGuardSetup.PauseLength.untilResumed.pause(from: start, calendar: calendar), .byYou)
    }

    // MARK: What it says

    func testItsRowAndScreenSayUntilWhen() throws {
        var peer = WireGuardSetup.Peer(name: "iPad", publicKey: Data(), address: "10.7.0.2")
        peer.paused = .until(at(15, 45))
        let status = DeviceStatus(peer, connected: [])
        XCTAssertEqual(plain(status.label(now: at(15, 15), calendar: calendar, locale: locale)), "Paused until 3:45 PM")
        XCTAssertEqual(plain(status.title(now: at(15, 15), calendar: calendar, locale: locale)), "Paused until 3:45 PM")
        XCTAssertEqual(status.detail(resets: "December 1", period: "this month"), "It connects again then, or when you resume it.")
        peer.paused = .until(at(6, 0, day: 11))
        XCTAssertEqual(plain(DeviceStatus(peer, connected: []).label(now: at(15, 15), calendar: calendar, locale: locale)),
                       "Paused until tomorrow, 6:00 AM")
        peer.paused = .byYou
        XCTAssertEqual(plain(DeviceStatus(peer, connected: []).label(now: at(15, 15), calendar: calendar, locale: locale)), "Paused",
                       "a pause until resumed says what it always did")
    }

    // MARK: Resumed on time

    func testItResumesAtTheFirstRoundAtItsEndNeverBefore() throws {
        let ipad = try iPad()
        session.pauseWireGuardDevice(ipad.id, for: .halfHour)
        XCTAssertEqual(pause(of: ipad), .until(at(15, 45)))
        XCTAssertEqual(server.lastSetup?.serverPeers.first { $0.id == ipad.id }?.paused, .until(at(15, 45)), "sent to Go paused")
        now = at(15, 44, day: 10).addingTimeInterval(59)
        session.sampleTraffic()
        XCTAssertEqual(pause(of: ipad), .until(at(15, 45)), "a second before, still paused")
        now = at(15, 45)
        session.sampleTraffic()
        XCTAssertNil(pause(of: ipad), "at its end")
        XCTAssertNil(server.lastSetup?.serverPeers.first { $0.id == ipad.id }?.paused, "and sent to Go resumed")
        XCTAssertNil(WireGuardDevices(secrets: secrets).setup.peers.first { $0.id == ipad.id }?.paused, "saved")
    }

    func testARoundLateResumesIt() throws {
        let ipad = try iPad()
        session.pauseWireGuardDevice(ipad.id, for: .hour)
        now = at(20, 0) // iOS had Tether suspended
        session.sampleTraffic()
        XCTAssertNil(pause(of: ipad))
    }

    func testAPauseAlreadyThereKeepsItsReason() throws {
        let ipad = try iPad()
        session.pauseWireGuardDevice(ipad.id)
        session.pauseWireGuardDevice(ipad.id, for: .halfHour)
        XCTAssertEqual(pause(of: ipad), .byYou)
    }

    /// Over its data limit when the time is up: the same round pauses it at its limit.
    func testOverItsLimitItIsPausedAtTheLimitWhenTheTimeIsUp() throws {
        let ipad = try iPad()
        XCTAssertTrue(session.setLimit(ipad.id, 1_000))
        session.pauseWireGuardDevice(ipad.id, for: .halfHour)
        server.peerTraffic = [ipad.address: TrafficTotals(bytesUp: 0, bytesDown: 2_000)]
        session.sampleTraffic()
        XCTAssertEqual(pause(of: ipad), .until(at(15, 45)), "a pause by you keeps its reason over the limit")
        now = at(15, 45)
        session.sampleTraffic()
        XCTAssertEqual(pause(of: ipad), .atLimit)
    }

    func testAfterARelaunchItStillResumesOnTime() throws {
        let ipad = try iPad()
        session.pauseWireGuardDevice(ipad.id, for: .halfHour)
        makeSession() // the same saved setup, as after a relaunch
        server.connected = [ipad.address]
        session.sampleTraffic()
        XCTAssertEqual(pause(of: ipad), .until(at(15, 45)))
        now = at(15, 46)
        session.sampleTraffic()
        XCTAssertNil(pause(of: ipad))
    }

    // MARK: The proxy

    func testTheProxyPausesForATimeAndResumes() throws {
        _ = try iPad()
        XCTAssertTrue(session.setProxy(on: true))
        let id = try XCTUnwrap(devices.setup.proxy?.id)
        session.pauseWireGuardDevice(id, for: .hour)
        XCTAssertEqual(devices.setup.proxy?.paused, .until(at(16, 15)))
        let status = ProxyStatus(try XCTUnwrap(devices.setup.proxy), stats: ProxyStats(), hotspotOn: true)
        XCTAssertEqual(plain(status.label(now: at(15, 15), calendar: calendar, locale: locale)), "Paused until 4:15 PM")
        XCTAssertEqual(plain(status.title(now: at(15, 15), calendar: calendar, locale: locale)), "Paused until 4:15 PM")
        now = at(16, 15)
        session.sampleTraffic()
        XCTAssertNil(devices.setup.proxy?.paused)
    }

    /// Opening Add a device's proxy steps resumes a pause by you, and a timed one is one too.
    func testTurningTheProxyOnAgainResumesATimedPause() throws {
        _ = try iPad()
        XCTAssertTrue(session.setProxy(on: true))
        let id = try XCTUnwrap(devices.setup.proxy?.id)
        session.pauseWireGuardDevice(id, for: .hour)
        XCTAssertTrue(session.setProxy(on: true))
        XCTAssertNil(devices.setup.proxy?.paused)
    }
}
