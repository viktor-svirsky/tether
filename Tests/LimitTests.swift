import XCTest
@testable import TetherCore

/// A device's data limit per month (#75): saved with the device, paused at the limit and told, near
/// it told at 90%, resumed by hand to go over until the 1st, and back on the 1st by itself.
@MainActor
final class LimitTests: XCTestCase {
    private let hotspot = "172.20.10.1"
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private var now = Date()
    private var hotspotOff = false
    private var server: FakeServer!
    private var secrets: FlakySecrets!
    private var devices: WireGuardDevices!
    private var session: HotspotSession!
    private let usageDefaults: UserDefaults = {
        let d = UserDefaults(suiteName: "LimitTests")!
        d.removePersistentDomain(forName: "LimitTests")
        return d
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// A session with one listed device, iPad, connected, on 10 November.
    private func iPad() throws -> WireGuardSetup.Peer {
        now = date(2026, 11, 10)
        server = FakeServer()
        secrets = FlakySecrets()
        devices = WireGuardDevices(secrets: secrets)
        session = HotspotSession(devices: devices, server: server, keepAlive: FakeSound(), page: FakePage(),
                                 sceneActive: true, hotspotAddress: { [unowned self] in hotspotOff ? nil : hotspot },
                                 usageDefaults: usageDefaults, calendar: calendar, now: { [unowned self] in now })
        session.syncWithHotspot()
        var peer = try XCTUnwrap(devices.connectReady())
        XCTAssertTrue(devices.rename(peer.id, to: "iPad"))
        peer.name = "iPad"
        server.connected = [peer.address]
        return peer
    }

    /// The iPad has used `bytes` in all, read now.
    private func used(_ peer: WireGuardSetup.Peer, _ bytes: UInt64) {
        server.peerTraffic = [peer.address: TrafficTotals(bytesUp: 0, bytesDown: bytes)]
        session.sampleTraffic()
    }

    private func current(_ peer: WireGuardSetup.Peer) -> WireGuardSetup.Peer? {
        session.wireGuardPeers.first { $0.id == peer.id }
    }

    // MARK: Saved

    func testALimitIsSavedWithTheDeviceAndAnOlderSetupHasNone() throws {
        var setup = WireGuardSetup.new()
        let ipad = try XCTUnwrap(setup.addPeer(name: "iPad"))
        _ = setup.addPeer(name: "Windows PC")
        setup.limitPeer(ipad.id, 10_000_000_000)
        setup.pausePeer(ipad.id, .atLimit)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(setup)) as? [String: Any])
        let peers = try XCTUnwrap(json["peers"] as? [[String: Any]])
        XCTAssertEqual(peers[0]["limit"] as? UInt64, 10_000_000_000)
        XCTAssertEqual(peers[0]["paused"] as? [String: String], ["why": "limit"])
        XCTAssertNil(peers[1]["limit"], "no limit saves nothing")
        let read = try JSONDecoder().decode(WireGuardSetup.self, from: JSONEncoder().encode(setup))
        XCTAssertEqual(read, setup)
        XCTAssertEqual(read.peers.map(\.limit), [10_000_000_000, nil])
        XCTAssertEqual(read.peers.map(\.paused), [.atLimit, nil])
    }

    func testWhatADevicePausedAtItsLimitSays() {
        var peer = WireGuardSetup.Peer(name: "iPad", publicKey: Data(), address: "10.7.0.2")
        peer.paused = .atLimit
        let status = DeviceStatus(peer, connected: ["10.7.0.2"])
        XCTAssertEqual(status.label, "Paused")
        XCTAssertEqual(status.title, "Paused at its limit")
        XCTAssertEqual(status.detail(resets: "December 1"), "It used its data for this month. It connects again on December 1, or when you resume it.")
    }

    func testTheLimitChoices() {
        XCTAssertEqual(DataLimit.choices, [nil, 5_000_000_000, 10_000_000_000, 20_000_000_000, 50_000_000_000])
        XCTAssertEqual(DataLimit.label(nil), "None")
        XCTAssertEqual(DataLimit.label(10_000_000_000), "10 GB")
        XCTAssertEqual(DataLimit.bytes(typedGB: "7.5"), 7_500_000_000)
        XCTAssertEqual(DataLimit.bytes(typedGB: " 3 "), 3_000_000_000)
        XCTAssertEqual(DataLimit.bytes(typedGB: "7,5"), 7_500_000_000)
        XCTAssertEqual(DataLimit.bytes(typedGB: "0.001"), 1_000_000, "1 MB, the smallest")
        // Hex and exponents aren't GB anyone types, and an amount that rounds to almost nothing would
        // pause the device at once (#165).
        for bad in ["", "0", "-1", "ten", "100001", "0.0000000001", "0.0009", "0x10", "1e3", "7.5.1", ".", "+5", "inf", "nan"] {
            XCTAssertNil(DataLimit.bytes(typedGB: bad), bad)
        }
    }

    // MARK: Pause at the limit

    func testAtItsLimitADeviceIsPausedAndToldOnce() throws {
        let ipad = try iPad()
        XCTAssertTrue(session.setLimit(ipad.id, 1_000))
        used(ipad, 800)
        XCTAssertNil(current(ipad)?.paused)
        XCTAssertEqual(session.limitAlerts, [], "under 90%")
        used(ipad, 900)
        XCTAssertEqual(session.limitAlerts.map(\.kind), [.near])
        XCTAssertNil(current(ipad)?.paused)
        used(ipad, 1_000)
        XCTAssertEqual(current(ipad)?.paused, .atLimit)
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.peers.first?.paused, .atLimit, "saved")
        XCTAssertEqual(session.limitAlerts.map(\.kind), [.near, .reached])
        used(ipad, 1_200) // its tunnel is up, the server lets nothing through, but a read counts what came
        XCTAssertEqual(session.limitAlerts.count, 2, "each once")
    }

    func testAPauseThatCantBeSavedIsntToldAndIsTriedAgain() throws {
        let ipad = try iPad()
        XCTAssertTrue(session.setLimit(ipad.id, 1_000))
        secrets.savesFail = true
        used(ipad, 1_000)
        XCTAssertNil(current(ipad)?.paused)
        XCTAssertFalse(session.limitAlerts.map(\.kind).contains(.reached))
        secrets.savesFail = false
        session.sampleTraffic()
        XCTAssertEqual(current(ipad)?.paused, .atLimit)
        XCTAssertTrue(session.limitAlerts.map(\.kind).contains(.reached))
    }

    func testAPauseByYouIsLeftAlone() throws {
        let ipad = try iPad()
        XCTAssertTrue(session.setLimit(ipad.id, 1_000))
        session.pauseWireGuardDevice(ipad.id)
        used(ipad, 2_000)
        XCTAssertEqual(current(ipad)?.paused, .byYou)
        now = date(2026, 12, 1)
        session.sampleTraffic()
        XCTAssertEqual(current(ipad)?.paused, .byYou, "the 1st resumes only a pause at the limit")
    }

    // MARK: Resume and the 1st

    /// Resumed by hand, it goes over its limit until the count starts over on the 1st, then the limit
    /// counts again.
    func testResumedAtItsLimitItGoesOverUntilThe1st() throws {
        let ipad = try iPad()
        XCTAssertTrue(session.setLimit(ipad.id, 1_000))
        used(ipad, 1_000)
        session.resumeWireGuardDevice(ipad.id)
        used(ipad, 5_000)
        XCTAssertNil(current(ipad)?.paused)
        XCTAssertTrue(session.overLimit(ipad.id))
        now = date(2026, 12, 2)
        used(ipad, 5_500)
        XCTAssertFalse(session.overLimit(ipad.id))
        used(ipad, 6_000)
        XCTAssertEqual(current(ipad)?.paused, .atLimit, "a new month, a new limit")
    }

    func testOnThe1stADevicePausedAtItsLimitConnectsAgain() throws {
        let ipad = try iPad()
        XCTAssertTrue(session.setLimit(ipad.id, 1_000))
        used(ipad, 1_000)
        XCTAssertEqual(current(ipad)?.paused, .atLimit)
        now = date(2026, 12, 1)
        session.leftScreen()
        session.watch() // in the background too
        XCTAssertNil(current(ipad)?.paused)
    }

    /// With the hotspot off nothing is read, but the 1st still lets it connect.
    func testOnThe1stWithTheHotspotOffItConnectsAgain() throws {
        let ipad = try iPad()
        XCTAssertTrue(session.setLimit(ipad.id, 1_000))
        used(ipad, 1_000)
        XCTAssertEqual(current(ipad)?.paused, .atLimit)
        hotspotOff = true
        session.syncWithHotspot()
        XCTAssertFalse(session.running)
        now = date(2026, 12, 1)
        session.watch()
        XCTAssertNil(current(ipad)?.paused)
    }

    /// Resumed on the 1st before a read caught up, it isn't at its limit any more, so it isn't over it.
    func testAResumeOnThe1stIsNoResumeOverTheLimit() throws {
        let ipad = try iPad()
        XCTAssertTrue(session.setLimit(ipad.id, 1_000))
        used(ipad, 1_000)
        now = date(2026, 12, 1)
        session.resumeWireGuardDevice(ipad.id)
        XCTAssertNil(current(ipad)?.paused)
        XCTAssertFalse(session.overLimit(ipad.id))
    }

    func testAResumeThatCantBeSavedIsntOverTheLimit() throws {
        let ipad = try iPad()
        XCTAssertTrue(session.setLimit(ipad.id, 1_000))
        used(ipad, 1_000)
        secrets.savesFail = true
        session.resumeWireGuardDevice(ipad.id)
        XCTAssertEqual(current(ipad)?.paused, .atLimit)
        XCTAssertFalse(session.overLimit(ipad.id))
    }

    /// Pause tapped on a screen that hadn't shown the pause at the limit yet keeps it, so the device
    /// still connects again on the 1st.
    func testPauseOnADevicePausedAtItsLimitKeepsTheReason() throws {
        let ipad = try iPad()
        XCTAssertTrue(session.setLimit(ipad.id, 1_000))
        used(ipad, 1_000)
        session.pauseWireGuardDevice(ipad.id)
        XCTAssertEqual(current(ipad)?.paused, .atLimit)
    }

    /// The same limit picked again after a resume changes nothing: it stays over it.
    func testTheSameLimitAgainKeepsAResume() throws {
        let ipad = try iPad()
        XCTAssertTrue(session.setLimit(ipad.id, 1_000))
        used(ipad, 1_000)
        session.resumeWireGuardDevice(ipad.id)
        XCTAssertTrue(session.setLimit(ipad.id, 1_000))
        used(ipad, 1_100)
        XCTAssertNil(current(ipad)?.paused)
        XCTAssertTrue(session.overLimit(ipad.id))
        XCTAssertEqual(session.limitAlerts.map(\.kind), [.reached])
    }

    // MARK: Changing the limit

    func testChangingTheLimitCountsAtOnce() throws {
        let ipad = try iPad()
        XCTAssertTrue(session.setLimit(ipad.id, 1_000))
        used(ipad, 1_000)
        XCTAssertEqual(current(ipad)?.paused, .atLimit)
        XCTAssertTrue(session.setLimit(ipad.id, 5_000))
        XCTAssertNil(current(ipad)?.paused, "raised above what it used")
        XCTAssertTrue(session.setLimit(ipad.id, 500))
        XCTAssertEqual(current(ipad)?.paused, .atLimit, "lowered below it")
        XCTAssertTrue(session.setLimit(ipad.id, nil))
        XCTAssertNil(current(ipad)?.paused, "no limit")
    }

    /// A new limit starts over what was told and what was resumed: raised after a resume, it pauses
    /// again at the new limit.
    func testANewLimitForgetsAResumeAndWhatWasTold() throws {
        let ipad = try iPad()
        XCTAssertTrue(session.setLimit(ipad.id, 1_000))
        used(ipad, 1_000)
        session.resumeWireGuardDevice(ipad.id)
        XCTAssertTrue(session.setLimit(ipad.id, 2_000))
        XCTAssertFalse(session.overLimit(ipad.id))
        used(ipad, 1_850)
        XCTAssertEqual(session.limitAlerts.map(\.kind), [.reached, .near])
        used(ipad, 2_000)
        XCTAssertEqual(current(ipad)?.paused, .atLimit)
    }

    func testALimitThatCantBeSavedSaysSo() throws {
        let ipad = try iPad()
        secrets.savesFail = true
        XCTAssertFalse(session.setLimit(ipad.id, 1_000))
        XCTAssertNil(current(ipad)?.limit)
        XCTAssertEqual(session.wireGuardDeviceProblem?.text, "The new limit couldn't be saved.")
    }

    // MARK: Told

    /// Near and at the limit are told in the background, each once, and on screen nothing is posted
    /// but it's the moment to ask for permission.
    func testTheNotifierTellsEachLimitAlertOnce() throws {
        let defaults = UserDefaults(suiteName: "LimitTests.notifier")!
        defaults.removePersistentDomain(forName: "LimitTests.notifier")
        var notifier = Notifier(defaults: defaults, calendar: calendar)
        let id = UUID()
        let near = LimitAlert(device: id, name: "iPad", kind: .near, used: 9_100_000_000, limit: 10_000_000_000, resets: date(2026, 12, 1))
        let reached = LimitAlert(device: id, name: "Travel router", kind: .reached, used: 10_000_000_000, limit: 10_000_000_000, resets: date(2026, 12, 1))
        func round(_ alerts: [LimitAlert], onScreen: Bool = false) -> Notifier.Round {
            Notifier.Round(now: now, onScreen: onScreen, hotspot: true, sharing: true, devices: [], connected: [], limitAlerts: alerts)
        }
        XCTAssertEqual(notifier.check(round([])), [])
        XCTAssertEqual(notifier.check(round([near])).map(\.title), ["iPad is near its limit"])
        XCTAssertEqual(notifier.check(round([near])), [], "once")
        let posted = notifier.check(round([near, reached]))
        XCTAssertEqual(posted.map(\.title), ["Travel router paused at its limit"])
        XCTAssertTrue(posted.first?.body.hasPrefix("It used 10 GB this month. It connects again on ") == true)
        XCTAssertEqual(posted.first?.kind, .limit)

        var onScreen = Notifier(defaults: defaults, calendar: calendar)
        _ = onScreen.check(round([], onScreen: true))
        XCTAssertEqual(onScreen.check(round([near], onScreen: true)), [])
        XCTAssertTrue(onScreen.wouldTell)

        defaults.set(false, forKey: NoticeKind.limit.key)
        var off = Notifier(defaults: defaults, calendar: calendar)
        _ = off.check(round([]))
        XCTAssertEqual(off.check(round([near])), [], "its switch off")
        XCTAssertEqual(NoticeKind.limit.label, "A device nears or reaches its limit")
    }

    /// The day the count resets, the way the iPhone's region writes dates.
    func testTheResetDayFollowsTheRegion() {
        let first = date(2026, 12, 1)
        XCTAssertEqual(LimitAlert.day(first, calendar: calendar, locale: Locale(identifier: "en_US")), "December 1")
        XCTAssertEqual(LimitAlert.day(first, calendar: calendar, locale: Locale(identifier: "en_GB")), "1 December")
        let reached = LimitAlert(device: UUID(), name: "iPad", kind: .reached, used: 1, limit: 10_000_000_000, resets: first)
        XCTAssertEqual(reached.notice(calendar: calendar, locale: Locale(identifier: "en_US")).body,
                       "It used 10 GB this month. It connects again on December 1, or when you resume it.")
    }

    func testTheNearNoticeSaysHowMuch() {
        let near = LimitAlert(device: UUID(), name: "iPad", kind: .near, used: 9_100_000_000, limit: 10_000_000_000, resets: date(2026, 12, 1))
        XCTAssertEqual(near.notice(calendar: calendar).body, "It used 9.1 GB of its 10 GB this month.")
    }
}
