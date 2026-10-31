import XCTest
@testable import TetherCore

/// HotspotSession with a fake server, keep-alive sound, hotspot and clock: what Model does each
/// watcher round and sample, without UIKit, Go or a real hotspot.
@MainActor
final class HotspotSessionTests: XCTestCase {
    private let hotspot = "172.20.10.1"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let locked = "Its keys can't be read yet. Unlock this iPhone once."
    private let couldntStart = "It couldn't start: port in use"

    private var server: FakeServer!
    private var sound: FakeSound!
    private var page: FakePage!
    private var secrets: FlakySecrets!
    private var devices: WireGuardDevices!
    private var address: String?
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var session: HotspotSession!

    private func makeSession(sceneActive: Bool = true, locked: Bool = false, log: @escaping @MainActor (String) -> Void = { _ in }) {
        server = FakeServer()
        sound = FakeSound()
        page = FakePage()
        secrets = FlakySecrets()
        secrets.failing = locked
        devices = WireGuardDevices(secrets: secrets)
        session = HotspotSession(devices: devices, server: server, keepAlive: sound, page: page,
                                 sceneActive: sceneActive, hotspotAddress: { [unowned self] in address }, now: { [unowned self] in now }, log: log)
    }

    private func minutes(_ m: Double) -> Date { start.addingTimeInterval(m * 60) }

    // MARK: The hotspot

    func testTheServerFollowsTheHotspot() {
        makeSession()
        // Each row is one watcher round: the hotspot address it sees, then where the server listens.
        let rounds: [(address: String?, running: Bool, starts: [String], line: UInt)] = [
            (nil, false, [], #line),
            (hotspot, true, [hotspot], #line),
            (hotspot, true, [hotspot], #line), // no restart while it stays
            ("172.20.10.3", true, [hotspot, "172.20.10.3"], #line), // a new address, a new server
            (nil, false, [hotspot, "172.20.10.3"], #line),
            (hotspot, true, [hotspot, "172.20.10.3", hotspot], #line),
        ]
        for round in rounds {
            address = round.address
            session.syncWithHotspot()
            XCTAssertEqual(session.running, round.running, line: round.line)
            XCTAssertEqual(session.sharing, round.running, line: round.line)
            XCTAssertEqual(server.running, round.running, line: round.line)
            XCTAssertEqual(server.starts, round.starts, line: round.line)
        }
    }

    func testTheHotspotAddressIsOnABridgeInTheHotspotSubnet() {
        let cases: [(interfaces: [String], hotspot: String?, line: UInt)] = [
            ([], nil, #line),
            (["en0: 192.168.1.5"], nil, #line),
            (["bridge100: 172.20.10.1"], "172.20.10.1", #line),
            (["bridge100: 192.168.2.1"], nil, #line), // another bridge, a Mac's Internet Sharing say
            (["en2: 172.20.10.4"], nil, #line), // this iPhone on someone else's hotspot
            (["en0: 10.0.0.2", "bridge101: 192.168.64.1", "bridge100: 172.20.10.1"], "172.20.10.1", #line),
        ]
        for c in cases {
            XCTAssertEqual(Interfaces.hotspotAddress(in: c.interfaces), c.hotspot, line: c.line)
        }
    }

    // MARK: Problems

    /// One watcher round: the hotspot, the Keychain and the server as they are, then what shows.
    private struct Round {
        var address: String?
        var locked = false
        var startFails = false
        var problem: String?
        var serverRunning: Bool
        var line: UInt = #line
    }

    private func run(_ rounds: [Round]) {
        makeSession(locked: rounds.first?.locked ?? false)
        for round in rounds {
            address = round.address
            secrets.failing = round.locked
            server.startError = round.startFails ? FakeServer.Failure() : nil
            session.syncWithHotspot()
            XCTAssertEqual(session.wireGuardProblem, round.problem, line: round.line)
            XCTAssertEqual(server.running, round.serverRunning, line: round.line)
            XCTAssertEqual(session.sharing, round.address != nil && round.problem == nil, line: round.line)
        }
    }

    func testLockedKeysThenUnlocked() {
        run([
            Round(address: nil, locked: true, problem: locked, serverRunning: false), // from launch, hotspot or not
            Round(address: hotspot, locked: true, problem: locked, serverRunning: false),
            Round(address: hotspot, problem: nil, serverRunning: true),
        ])
        XCTAssertEqual(server.starts, [hotspot], "nothing is tried while the keys are locked")
        XCTAssertNotNil(session.wireGuardReady, "the QR code appears once the keys load")
    }

    func testAStartThatFailsIsTriedAgainEachRound() {
        run([
            Round(address: hotspot, startFails: true, problem: couldntStart, serverRunning: false),
            Round(address: hotspot, startFails: true, problem: couldntStart, serverRunning: false),
            Round(address: hotspot, problem: nil, serverRunning: true),
        ])
        XCTAssertEqual(server.starts, [hotspot, hotspot, hotspot])
    }

    func testAStartErrorGoesWithTheHotspot() {
        run([
            Round(address: hotspot, startFails: true, problem: couldntStart, serverRunning: false),
            Round(address: nil, startFails: true, problem: nil, serverRunning: false),
            Round(address: hotspot, problem: nil, serverRunning: true),
        ])
    }

    func testTheSetupProblemComesBeforeTheStartProblem() {
        run([
            Round(address: hotspot, locked: true, startFails: true, problem: locked, serverRunning: false),
            Round(address: hotspot, startFails: true, problem: couldntStart, serverRunning: false),
            Round(address: hotspot, problem: nil, serverRunning: true),
        ])
    }

    func testAProblemIsLoggedOnceNotEveryRound() {
        var logged: [String] = []
        makeSession(log: { logged.append($0) })
        address = hotspot
        server.startError = FakeServer.Failure()
        for _ in 0..<3 { session.syncWithHotspot() }
        XCTAssertEqual(logged.filter { $0.hasPrefix("WireGuard not started") }, ["WireGuard not started: port in use"])
    }

    // MARK: Devices

    func testADeviceListTheServerRefusesRestartsIt() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        let peer = try XCTUnwrap(devices.connectReady())
        server.setPeersError = FakeServer.Failure()
        session.removeWireGuardDevice(peer.id)
        XCTAssertEqual(server.starts, [hotspot, hotspot], "started again with the saved devices")
        XCTAssertFalse(server.lastSetup?.serverPeers.contains(peer) ?? true, "the removed device isn't let in")
        XCTAssertTrue(server.running)
        XCTAssertNil(session.wireGuardProblem)
    }

    func testARestartThatFailsLeavesTheServerStoppedUntilTheNextRound() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        let peer = try XCTUnwrap(devices.connectReady())
        server.setPeersError = FakeServer.Failure()
        server.startError = FakeServer.Failure()
        session.removeWireGuardDevice(peer.id)
        XCTAssertFalse(server.running, "a removed device is never let in")
        XCTAssertEqual(session.wireGuardProblem, couldntStart)
        server.startError = nil
        session.syncWithHotspot()
        XCTAssertTrue(server.running)
        XCTAssertNil(session.wireGuardProblem)
    }

    func testARenameThatCantBeSavedSaysSoUntilAChangeSaves() throws {
        makeSession()
        let peer = try XCTUnwrap(devices.connectReady())
        let other = try XCTUnwrap(devices.connectReady())
        secrets.savesFail = true
        session.renameWireGuardDevice(peer.id, to: "Kitchen iPad")
        XCTAssertEqual(session.wireGuardPeers.first?.name, peer.name, "the old name stays")
        XCTAssertEqual(session.wireGuardDeviceProblem,
                       HotspotSession.DeviceProblem(device: peer.id, text: "The new name couldn't be saved."))
        secrets.savesFail = false
        XCTAssertTrue(session.removeWireGuardDevice(other.id))
        XCTAssertNil(session.wireGuardDeviceProblem, "any change that saves clears it")
    }

    func testARemovalThatCantBeSavedSaysSoUntilAChangeSaves() throws {
        makeSession()
        let peer = try XCTUnwrap(devices.connectReady())
        secrets.savesFail = true
        XCTAssertFalse(session.removeWireGuardDevice(peer.id))
        XCTAssertEqual(session.wireGuardPeers.map(\.id), [peer.id], "the device stays")
        XCTAssertEqual(session.wireGuardDeviceProblem,
                       HotspotSession.DeviceProblem(device: peer.id, text: "The device couldn't be removed."))
        secrets.savesFail = false
        session.renameWireGuardDevice(peer.id, to: "Kitchen iPad")
        XCTAssertNil(session.wireGuardDeviceProblem)
        XCTAssertEqual(session.wireGuardPeers.first?.name, "Kitchen iPad")
    }

    func testABackgroundRoundClaimsTheReadyDevice() throws {
        makeSession(sceneActive: false)
        address = hotspot
        session.watch()
        let ready = try XCTUnwrap(session.wireGuardReady)
        server.connected = [ready.address]
        session.watch()
        XCTAssertEqual(session.wireGuardPeers.map(\.address), [ready.address])
        XCTAssertNotNil(session.wireGuardReady)
        XCTAssertNotEqual(session.wireGuardReady?.address, ready.address, "a new code for the next device")
        XCTAssertEqual(server.lastSetup?.serverPeers.count, 2, "the server lets in the device and the new code")
    }

    func testOnScreenTheSamplerClaimsAndTheWatcherDoesnt() throws {
        makeSession(sceneActive: true)
        address = hotspot
        session.watch()
        let ready = try XCTUnwrap(session.wireGuardReady)
        server.connected = [ready.address]
        session.watch()
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
        session.sampleTraffic()
        XCTAssertEqual(session.wireGuardPeers.map(\.address), [ready.address])
        XCTAssertEqual(session.wireGuardConnected, [ready.address])
    }

    func testTheShortcutReadsWhoIsConnectedNow() {
        makeSession(sceneActive: false)
        address = hotspot
        session.syncWithHotspot()
        server.connected = ["10.7.0.2", "10.7.0.3"]
        XCTAssertEqual(session.shortcutState(), ShortcutReply.State(running: true, connected: 2, problem: nil))
    }

    // MARK: The config page

    func testThePageListensWhereTheServerDoes() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        XCTAssertEqual(page.starts, ["\(hotspot):80"])
        session.syncWithHotspot()
        XCTAssertEqual(page.starts.count, 1, "no restart while it runs")
        address = "172.20.10.3"
        session.syncWithHotspot()
        XCTAssertEqual(page.starts, ["\(hotspot):80", "172.20.10.3:80"], "a new address, a new page")
        address = nil
        session.syncWithHotspot()
        XCTAssertFalse(page.running)
    }

    /// Each failure is logged once, until the page listens again.
    func testAPageThatListensAgainLogsItsNextFailure() {
        var logged: [String] = []
        makeSession(log: { logged.append($0) })
        address = hotspot
        session.syncWithHotspot()
        page.fail()
        session.syncWithHotspot()
        page.fail()
        XCTAssertEqual(logged.filter { $0 == "config page: address in use" }.count, 1, "the same failure again")
        session.syncWithHotspot()
        page.becomeReady()
        page.fail()
        XCTAssertEqual(logged.filter { $0 == "config page: address in use" }.count, 2, "\(logged)")
    }

    func testAPageThatFailsIsStartedAgainNextRound() {
        var logged: [String] = []
        makeSession(log: { logged.append($0) })
        address = hotspot
        session.syncWithHotspot()
        page.becomeReady()
        page.fail()
        XCTAssertTrue(logged.contains("config page: address in use"), "\(logged)")
        XCTAssertTrue(server.running, "WireGuard goes on without it")
        XCTAssertNil(session.wireGuardProblem)
        session.syncWithHotspot()
        XCTAssertEqual(page.starts.count, 2)
    }

    func testNoPageWithoutTheServer() {
        makeSession(locked: true)
        address = hotspot
        session.syncWithHotspot()
        XCTAssertTrue(page.starts.isEmpty, "the keys are locked")
        secrets.failing = false
        server.startError = FakeServer.Failure()
        session.syncWithHotspot()
        XCTAssertTrue(page.starts.isEmpty, "the server didn't start")
        server.startError = nil
        session.syncWithHotspot()
        XCTAssertEqual(page.starts, ["\(hotspot):80"])
    }

    private func body(_ response: ConfigPage.Response) -> String { String(decoding: response.body, as: UTF8.self) }

    /// A download is a device added: it's listed, and the next one gets a new key, so two devices never share one.
    func testOnScreenADownloadAddsTheDevice() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        XCTAssertTrue(body(page.ask(.page)).contains("href=\"/Tether.conf\""))
        let ready = try XCTUnwrap(session.wireGuardReady)
        let first = page.ask(.config)
        XCTAssertEqual(first.status, .ok)
        XCTAssertEqual(body(first), session.wireGuardConfig(for: ready))
        XCTAssertTrue(first.extraHeaders.contains("Content-Disposition: attachment; filename=\"Tether-Device.conf\""))
        XCTAssertEqual(session.wireGuardPeers.map(\.address), [ready.address])
        XCTAssertEqual(session.wireGuardPeers.map(\.name), ["Device"])
        let next = try XCTUnwrap(session.wireGuardReady)
        XCTAssertNotEqual(next.address, ready.address, "a new key for the next device")
        XCTAssertEqual(server.lastSetup?.serverPeers.map(\.address), [ready.address, next.address], "both let in")
        let second = page.ask(.config, from: "172.20.10.3")
        XCTAssertEqual(body(second), session.wireGuardConfig(for: next))
        XCTAssertNotEqual(body(second), body(first))
        XCTAssertTrue(second.extraHeaders.contains("Content-Disposition: attachment; filename=\"Tether-Device-2.conf\""))
    }

    func testTheDownloadedDeviceConnectingAddsNothingMore() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        let ready = try XCTUnwrap(session.wireGuardReady)
        _ = page.ask(.config)
        let next = session.wireGuardReady
        server.connected = [ready.address]
        session.sampleTraffic()
        XCTAssertEqual(session.wireGuardPeers.count, 1)
        XCTAssertEqual(session.wireGuardReady, next)
        XCTAssertEqual(session.wireGuardConnected, [ready.address])
    }

    /// The same as the QR code, which can only be seen while Tether is on screen.
    func testOffScreenThePageGivesNothing() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.leftScreen()
        let ready = session.wireGuardReady
        XCTAssertTrue(body(page.ask(.page)).contains("Open Tether on the iPhone"))
        let config = page.ask(.config)
        XCTAssertEqual(config.status, .notFound)
        XCTAssertFalse(body(config).contains("PrivateKey"))
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
        XCTAssertEqual(session.wireGuardReady, ready)
        session.cameOnScreen()
        XCTAssertEqual(page.ask(.config).status, .ok)
    }

    func testADownloadThatCantBeSavedGivesNothing() {
        var logged: [String] = []
        makeSession(log: { logged.append($0) })
        address = hotspot
        session.syncWithHotspot()
        let ready = session.wireGuardReady
        secrets.savesFail = true
        let config = page.ask(.config)
        XCTAssertEqual(config.status, .unavailable)
        XCTAssertFalse(body(config).contains("PrivateKey"), "a key that isn't saved could never connect")
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
        XCTAssertEqual(session.wireGuardReady, ready)
        XCTAssertTrue(logged.contains("WireGuard: 172.20.10.2 asked for the config, but the new device couldn't be saved"), "\(logged)")
    }

    /// A browser or download manager that fetches twice gets the same config, and only one device is listed.
    func testTheSameDeviceAskingAgainSoonGetsTheSameConfig() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        let first = page.ask(.config, from: "172.20.10.2")
        now = now.addingTimeInterval(59)
        XCTAssertEqual(page.ask(.configHead, from: "172.20.10.2"), first.forHead)
        XCTAssertEqual(page.ask(.config, from: "172.20.10.2"), first)
        XCTAssertEqual(session.wireGuardPeers.count, 1)
        let other = page.ask(.config, from: "172.20.10.3")
        XCTAssertNotEqual(other.body, first.body, "another device gets its own")
        now = now.addingTimeInterval(61)
        XCTAssertNotEqual(page.ask(.config, from: "172.20.10.3").body, other.body, "a minute later it's a new device")
        XCTAssertEqual(session.wireGuardPeers.count, 3)
    }

    func testARemovedDevicesConfigIsntHandedOutAgain() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        let first = page.ask(.config)
        session.removeWireGuardDevice(try XCTUnwrap(session.wireGuardPeers.first).id)
        XCTAssertNotEqual(page.ask(.config).body, first.body)
    }

    func testAHeadAddsNoDevice() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        let ready = session.wireGuardReady
        let head = page.ask(.configHead)
        XCTAssertEqual(head.status, .ok)
        XCTAssertTrue(head.headOnly)
        XCTAssertEqual(page.ask(.pageHead), ConfigPage.page(.ready).forHead)
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
        XCTAssertEqual(session.wireGuardReady, ready)
        session.leftScreen()
        XCTAssertEqual(page.ask(.configHead).status, .notFound)
    }

    func testAPageThatFailsEveryRoundIsLoggedOnce() {
        var logged: [String] = []
        makeSession(log: { logged.append($0) })
        address = hotspot
        session.syncWithHotspot()
        for _ in 0..<3 {
            page.fail()
            session.syncWithHotspot()
        }
        XCTAssertEqual(logged.filter { $0.hasPrefix("config page:") }, ["config page: address in use"])
        XCTAssertEqual(page.starts.count, 4, "still tried each round")
    }

    func testOtherRequestsGetTheirErrors() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        XCTAssertEqual(page.ask(.notFound), ConfigPage.notFound)
        XCTAssertEqual(page.ask(.notGet), ConfigPage.notGet)
        XCTAssertEqual(page.ask(.malformed), ConfigPage.malformed)
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
    }

    // MARK: The keep-alive sound

    /// One watcher round at `minute`: on screen or not, the hotspot, and whether the sound plays after it.
    private struct SoundRound {
        var minute: Double
        var onScreen: Bool
        var hotspot = false
        var wake = false
        var plays: Bool
        var line: UInt = #line
    }

    private func run(_ rounds: [SoundRound]) {
        makeSession(sceneActive: rounds.first?.onScreen ?? true)
        for round in rounds {
            now = minutes(round.minute)
            address = round.hotspot ? hotspot : nil
            session.sceneActive = round.onScreen
            if round.wake { session.wake() } else { session.syncWithHotspot() }
            XCTAssertEqual(sound.playing, round.plays, line: round.line)
        }
    }

    func testOnScreenTheSoundNeverStops() {
        run([
            SoundRound(minute: 0, onScreen: true, plays: true),
            SoundRound(minute: 30, onScreen: true, plays: true),
            // The 10 minutes run from the last round on screen.
            SoundRound(minute: 35, onScreen: false, plays: true),
            SoundRound(minute: 39.9, onScreen: false, plays: true),
            SoundRound(minute: 40, onScreen: false, plays: false),
        ])
    }

    func testABackgroundLaunchDoesntPlayUntilWoken() {
        run([
            SoundRound(minute: 0, onScreen: false, plays: false), // "Is Tether Sharing?" only reports
            SoundRound(minute: 1, onScreen: false, wake: true, plays: true), // Start Tether
            SoundRound(minute: 10.9, onScreen: false, plays: true),
            SoundRound(minute: 11, onScreen: false, plays: false),
            SoundRound(minute: 12, onScreen: false, wake: true, plays: true), // a stopped wait starts again
        ])
    }

    func testTheSoundPlaysTenMinutesAfterTheHotspotGoes() {
        run([
            SoundRound(minute: 0, onScreen: false, hotspot: true, plays: true), // a launch with the hotspot on
            SoundRound(minute: 60, onScreen: false, hotspot: true, plays: true),
            SoundRound(minute: 61, onScreen: false, plays: true),
            SoundRound(minute: 70.9, onScreen: false, plays: true),
            SoundRound(minute: 71, onScreen: false, plays: false),
            SoundRound(minute: 80, onScreen: false, hotspot: true, plays: true), // the hotspot back, a device joined
        ])
    }

    func testOpeningTetherStartsTheWaitAgain() {
        makeSession(sceneActive: false)
        session.syncWithHotspot()
        XCTAssertFalse(sound.playing, "a background launch only reports")
        now = minutes(1)
        session.cameOnScreen()
        XCTAssertTrue(sound.playing)
        now = minutes(2)
        session.leftScreen()
        session.syncWithHotspot()
        now = minutes(10.9)
        session.syncWithHotspot()
        XCTAssertTrue(sound.playing)
        now = minutes(11)
        session.syncWithHotspot()
        XCTAssertFalse(sound.playing, "10 minutes from the last round on screen")
    }

    func testWakeSaysWhetherTheSoundIsMade() {
        makeSession(sceneActive: false)
        XCTAssertTrue(session.wake())
        sound.silent = true // iOS refused the audio session, in the background say
        XCTAssertFalse(session.wake())
    }

    // MARK: What the screen sees

    /// Model relies on this to redraw, as `@Published` would: each change is announced while the old value is still there.
    func testEveryChangeIsAnnouncedBeforeItHappens() throws {
        makeSession(locked: true)
        var announced: [String] = []
        session.willChange = { [unowned self] in
            announced.append("\(session.running) \(session.wireGuardProblem ?? "-") \(session.wireGuardPeers.count)")
        }
        address = hotspot
        session.syncWithHotspot()
        XCTAssertEqual(announced.last, "false \(locked) 0", "running")
        secrets.failing = false
        announced = []
        session.syncWithHotspot()
        XCTAssertTrue(announced.contains("true \(locked) 0"), "the problem going")
        server.connected = [try XCTUnwrap(session.wireGuardReady).address]
        session.sampleTraffic() // claims it
        let peer = try XCTUnwrap(session.wireGuardPeers.first)
        announced = []
        session.removeWireGuardDevice(peer.id)
        XCTAssertTrue(announced.contains("true - 1"), "the devices")
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
        let changes: [(String, () -> Void)] = [
            ("downSpeed", { self.session.downSpeed = 1 }),
            ("upSpeed", { self.session.upSpeed = 1 }),
            ("wireGuardConnected", { self.session.wireGuardConnected = ["10.7.0.2"] }),
        ]
        for (name, change) in changes {
            announced = []
            change()
            XCTAssertEqual(announced.count, 1, name)
        }
    }

    // MARK: Speeds

    func testSpeedsAreBitsPerSecondBetweenTwoSamples() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        server.totals = TrafficTotals(bytesUp: 1000, bytesDown: 5000)
        session.sampleTraffic()
        XCTAssertEqual(session.upSpeed, 0, "the first sample has nothing to compare with")
        XCTAssertEqual(session.downSpeed, 0)
        now = now.addingTimeInterval(2)
        server.totals = TrafficTotals(bytesUp: 2000, bytesDown: 9000)
        session.sampleTraffic()
        XCTAssertEqual(session.upSpeed, 4000)
        XCTAssertEqual(session.downSpeed, 16000)
        // Off screen and back: the time away isn't averaged in.
        session.leftScreen()
        now = now.addingTimeInterval(600)
        server.totals = TrafficTotals(bytesUp: 3000, bytesDown: 10000)
        session.sampleTraffic()
        now = now.addingTimeInterval(1)
        server.totals = TrafficTotals(bytesUp: 3250, bytesDown: 10000)
        session.sampleTraffic()
        XCTAssertEqual(session.upSpeed, 2000)
        XCTAssertEqual(session.downSpeed, 0)
    }

    func testANewHotspotStartsFromZero() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        server.connected = ["10.7.0.2"]
        session.sampleTraffic()
        now = now.addingTimeInterval(1)
        server.totals = TrafficTotals(bytesUp: 100, bytesDown: 100)
        session.sampleTraffic()
        XCTAssertEqual(session.downSpeed, 800)
        address = "172.20.10.3"
        session.syncWithHotspot()
        XCTAssertEqual(session.downSpeed, 0, "a new address restarts without passing through off")
        XCTAssertEqual(session.upSpeed, 0)
        XCTAssertEqual(session.wireGuardConnected, ["10.7.0.2"], "until the next sample")
        address = nil
        session.syncWithHotspot()
        session.sampleTraffic()
        XCTAssertTrue(session.wireGuardConnected.isEmpty)
    }

    func testACounterGoingBackwardsIsNoSpeed() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        server.totals = TrafficTotals(bytesUp: 1000, bytesDown: 1000)
        session.sampleTraffic()
        now = now.addingTimeInterval(1)
        server.totals = TrafficTotals(bytesUp: 10, bytesDown: 10)
        session.sampleTraffic()
        XCTAssertEqual(session.upSpeed, 0)
        XCTAssertEqual(session.downSpeed, 0)
    }
}

/// The WireGuard server, with errors to order and the counters and handshakes a test sets.
@MainActor
final class FakeServer: WireGuardServing {
    struct Failure: Error, CustomStringConvertible {
        var description: String { "port in use" }
    }

    private(set) var running = false
    private(set) var connectedAddresses: Set<String> = []
    /// Thrown by every start while set.
    var startError: Error?
    var setPeersError: Error?
    /// What the next snapshot reports, while running.
    var connected: Set<String> = []
    var totals = TrafficTotals()
    private(set) var starts: [String] = []
    private(set) var lastSetup: WireGuardSetup?

    func start(host: String, setup: WireGuardSetup, port: UInt16) throws {
        stop()
        starts.append(host)
        if let startError { throw startError }
        running = true
        lastSetup = setup
    }

    func stop() {
        running = false
        connectedAddresses = []
    }

    func setPeers(_ setup: WireGuardSetup) throws {
        guard running else { return }
        if let setPeersError { throw setPeersError }
        lastSetup = setup
    }

    func snapshot() -> TrafficTotals {
        connectedAddresses = running ? connected : []
        return totals
    }

    func freeMemory() {}
}

@MainActor
final class FakePage: ConfigPageServing {
    struct Failure: Error, CustomStringConvertible {
        var description: String { "address in use" }
    }

    var respond: @MainActor (ConfigPage.Request, String) -> ConfigPage.Response = { _, _ in ConfigPage.notFound }
    var onChange: @MainActor () -> Void = {}
    var onFailure: @MainActor (Error) -> Void = { _ in }
    private(set) var running = false
    private(set) var listening = false
    /// "host:port" for each start.
    private(set) var starts: [String] = []

    func start(host: String, port: UInt16) {
        stop()
        starts.append("\(host):\(port)")
        running = true
    }

    func stop() {
        running = false
        setListening(false)
    }

    /// The listener is ready for connections.
    func becomeReady() { setListening(true) }

    /// The listener failed after it started, the way the real one stops itself.
    func fail() {
        stop()
        onFailure(Failure())
    }

    /// A request from a device on the hotspot.
    func ask(_ request: ConfigPage.Request, from client: String = "172.20.10.2") -> ConfigPage.Response {
        respond(request, client)
    }

    private func setListening(_ value: Bool) {
        guard value != listening else { return }
        listening = value
        onChange()
    }
}

final class FakeSound: KeepAliveSound {
    private(set) var playing = false
    /// Started, but iOS gives it no sound.
    var silent = false
    var sounding: Bool { playing && !silent }
    func start() { playing = true }
    func stop() { playing = false }
}
