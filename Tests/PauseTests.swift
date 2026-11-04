import XCTest
@testable import TetherCore

/// Pausing a device (#74): saved with the setup, sent to Go with the devices, and never counted as
/// connected, while the device stays on the server so its tunnel stays up.
@MainActor
final class PauseTests: XCTestCase {
    private let hotspot = "172.20.10.1"
    private var server: FakeServer!
    private var secrets: FlakySecrets!
    private var devices: WireGuardDevices!
    private var session: HotspotSession!

    private func makeSession(sceneActive: Bool = true, saved: WireGuardSetup? = nil) {
        server = FakeServer()
        secrets = FlakySecrets()
        secrets.data = saved.flatMap { try? JSONEncoder().encode($0) }
        devices = WireGuardDevices(secrets: secrets)
        session = HotspotSession(devices: devices, server: server, keepAlive: FakeSound(), page: FakePage(),
                                 sceneActive: sceneActive, hotspotAddress: { [unowned self] in hotspot })
        session.syncWithHotspot()
    }

    /// A session with one listed device whose tunnel is up.
    private func connectedDevice(sceneActive: Bool = true) throws -> WireGuardSetup.Peer {
        makeSession(sceneActive: sceneActive)
        let peer = try XCTUnwrap(devices.connectReady())
        server.connected = [peer.address]
        if sceneActive { session.sampleTraffic() } else { session.watch() }
        XCTAssertEqual(session.connectedNow, [peer.address])
        return peer
    }

    private func serverPeer(_ peer: WireGuardSetup.Peer) -> WireGuardSetup.Peer? {
        server.lastSetup?.serverPeers.first { $0.id == peer.id }
    }

    // MARK: Saved with the setup

    func testAPauseIsSavedAndSoIsAResume() throws {
        let secrets = InMemorySecrets()
        let devices = WireGuardDevices(secrets: secrets)
        let peer = try XCTUnwrap(devices.connectReady())
        let other = try XCTUnwrap(devices.connectReady())
        XCTAssertTrue(devices.pause(peer.id, .byYou))
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.peers.map(\.paused), [.byYou, nil], "only that device, after a relaunch too")
        XCTAssertTrue(devices.pause(peer.id, nil))
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.peers.map(\.paused), [nil, nil])
        XCTAssertEqual(devices.setup.peers.map(\.id), [peer.id, other.id])
    }

    func testPausingADeviceThatIsntListedChangesNothing() throws {
        var setup = WireGuardSetup.new()
        _ = setup.addPeer(name: "iPad")
        let before = setup
        setup.pausePeer(UUID(), .byYou)
        XCTAssertEqual(setup, before)
    }

    func testAPauseThatCantBeSavedChangesNothing() throws {
        let secrets = FlakySecrets()
        let devices = WireGuardDevices(secrets: secrets)
        let peer = try XCTUnwrap(devices.connectReady())
        secrets.savesFail = true
        XCTAssertFalse(devices.pause(peer.id, .byYou))
        XCTAssertNil(devices.setup.peers[0].paused, "not paused, since it wouldn't be after a relaunch")
    }

    /// A paused device is saved with its reason, so a second reason can be added later (#75).
    func testAPauseIsSavedWithItsReason() throws {
        var setup = WireGuardSetup.new()
        let peer = try XCTUnwrap(setup.addPeer(name: "iPad"))
        _ = setup.addPeer(name: "Windows PC")
        setup.pausePeer(peer.id, .byYou)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(setup)) as? [String: Any])
        let peers = try XCTUnwrap(json["peers"] as? [[String: Any]])
        XCTAssertEqual(peers[0]["paused"] as? [String: String], ["why": "you"])
        XCTAssertNil(peers[1]["paused"], "a device that isn't paused saves nothing for it")
        XCTAssertEqual(try JSONDecoder().decode(WireGuardSetup.self, from: JSONEncoder().encode(setup)), setup)
    }

    func testASetupSavedBeforePauseStillLoads() throws {
        let json: [String: Any] = [
            "serverPrivateKey": WireGuardSetup.new().serverPrivateKey.base64EncodedString(),
            "peers": [["id": UUID().uuidString, "name": "iPad", "privateKey": "", "publicKey": Data(repeating: 1, count: 32).base64EncodedString(),
                       "address": "10.7.0.2", "host": hotspot]],
        ]
        let setup = try JSONDecoder().decode(WireGuardSetup.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(setup.peers.map(\.name), ["iPad"])
        XCTAssertEqual(setup.peers.map(\.paused), [nil])
    }

    /// A newer version may pause for a reason this one doesn't know, and an older release can be
    /// installed over it. The device stays paused rather than connecting, and this one says it's paused.
    func testAReasonThisVersionDoesntKnowStillPauses() throws {
        var setup = WireGuardSetup.new()
        _ = setup.addPeer(name: "iPad")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(setup)) as? [String: Any])
        var peers = try XCTUnwrap(json["peers"] as? [[String: Any]])
        peers[0]["paused"] = ["why": "limit", "until": 1_800_000_000]
        json["peers"] = peers
        let read = try JSONDecoder().decode(WireGuardSetup.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(read.peers.map(\.paused), [.byYou])
    }

    // MARK: Sent to Go

    func testAPausedDeviceGoesToGoPaused() throws {
        var setup = WireGuardSetup.new()
        let ipad = try XCTUnwrap(setup.addPeer(name: "iPad"))
        _ = setup.addPeer(name: "Windows PC")
        setup.pausePeer(ipad.id, .byYou)
        let message = WireGuardServer.ConfigMessage(setup.serverPeers)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        let peers = try XCTUnwrap(json["peers"] as? [[String: Any]])
        XCTAssertEqual(peers.map { $0["paused"] as? Bool }, [true, false])
        XCTAssertEqual(json["v"] as? Int, 1, "an added key, so the same version")
    }

    /// Go reads the key: the real server starts with a paused device, and takes a resume.
    func testTheRealServerTakesAPausedDevice() throws {
        let real = WireGuardServer()
        defer { real.stop() }
        var setup = WireGuardSetup.new()
        let ipad = try XCTUnwrap(setup.addPeer(name: "iPad"))
        setup.pausePeer(ipad.id, .byYou)
        try real.start(host: "127.0.0.1", setup: setup, port: 0)
        XCTAssertEqual(real.snapshot().peers.keys.sorted(), [ipad.address], "it stays on the server")
        setup.pausePeer(ipad.id, nil)
        XCTAssertNoThrow(try real.setPeers(setup))
    }

    // MARK: The session

    func testAPausedDeviceIsntConnectedButStaysOnTheServer() throws {
        let peer = try connectedDevice()
        session.pauseWireGuardDevice(peer.id)
        XCTAssertEqual(session.wireGuardPeers.map(\.paused), [.byYou])
        XCTAssertEqual(serverPeer(peer)?.paused, .byYou, "kept on the server, paused")
        XCTAssertEqual(session.wireGuardConnected, [], "at once, not at the next sample")
        session.sampleTraffic()
        XCTAssertEqual(session.wireGuardConnected, [], "its tunnel is up, but nothing gets through")
        XCTAssertEqual(session.connectedNow, [])
        XCTAssertEqual(session.shortcutState().connected, 0)
        XCTAssertNil(session.wireGuardDeviceProblem)
        session.resumeWireGuardDevice(peer.id)
        XCTAssertEqual(session.wireGuardPeers.map(\.paused), [nil])
        XCTAssertNil(serverPeer(peer)?.paused)
        XCTAssertEqual(session.wireGuardConnected, [peer.address], "its tunnel stayed up, so it's connected at once")
        XCTAssertEqual(session.shortcutState().connected, 1)
    }

    func testInTheBackgroundAPausedDeviceIsntConnected() throws {
        let peer = try connectedDevice()
        session.pauseWireGuardDevice(peer.id)
        session.leftScreen()
        session.watch()
        XCTAssertEqual(session.connectedNow, [])
        session.cameOnScreen()
        XCTAssertEqual(session.wireGuardConnected, [])
    }

    /// Back on screen, the background's read stands in until the sampler's first. A Resume tapped
    /// before that shows the device connected at once too.
    func testAResumeRightAfterComingOnScreenShowsItConnected() throws {
        let peer = try connectedDevice()
        session.pauseWireGuardDevice(peer.id)
        session.leftScreen()
        session.watch()
        session.cameOnScreen()
        session.resumeWireGuardDevice(peer.id)
        XCTAssertEqual(session.wireGuardConnected, [peer.address])
    }

    func testAPauseOrResumeThatCantBeSavedSaysSo() throws {
        let peer = try connectedDevice()
        secrets.savesFail = true
        session.pauseWireGuardDevice(peer.id)
        XCTAssertEqual(session.wireGuardDeviceProblem, HotspotSession.DeviceProblem(device: peer.id, text: "The device couldn't be paused."))
        XCTAssertEqual(session.wireGuardPeers.map(\.paused), [nil])
        XCTAssertEqual(session.wireGuardConnected, [peer.address], "still connected")
        XCTAssertNil(serverPeer(peer)?.paused)
        secrets.savesFail = false
        session.pauseWireGuardDevice(peer.id)
        XCTAssertNil(session.wireGuardDeviceProblem)
        secrets.savesFail = true
        session.resumeWireGuardDevice(peer.id)
        XCTAssertEqual(session.wireGuardDeviceProblem, HotspotSession.DeviceProblem(device: peer.id, text: "The device couldn't be resumed."))
        XCTAssertEqual(session.wireGuardPeers.map(\.paused), [.byYou])
        XCTAssertEqual(serverPeer(peer)?.paused, .byYou)
    }

    func testAPausedDeviceIsStillPausedAfterARelaunch() throws {
        var setup = WireGuardSetup.new()
        let ipad = try XCTUnwrap(setup.addPeer(name: "iPad"))
        setup.pausePeer(ipad.id, .byYou)
        makeSession(saved: setup)
        XCTAssertEqual(session.wireGuardPeers.map(\.paused), [.byYou])
        XCTAssertEqual(serverPeer(ipad)?.paused, .byYou, "the server starts with it paused")
        server.connected = [ipad.address]
        session.sampleTraffic()
        XCTAssertEqual(session.wireGuardConnected, [])
    }

    /// Pause and Resume are tapped on screen, where the notifications only keep up. A paused device
    /// is left out of them, so pausing one is no device disconnecting, then or later.
    func testPausingADeviceTellsNothing() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PauseTests"))
        defaults.removePersistentDomain(forName: "PauseTests")
        var notifier = Notifier(defaults: defaults)
        let peer = try connectedDevice()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func round(_ minutes: Double, onScreen: Bool) -> [Notice] {
            notifier.check(Notifier.Round(now: start.addingTimeInterval(minutes * 60), onScreen: onScreen, hotspot: true, sharing: true,
                                          devices: session.notifiedPeers, connected: session.connectedNow))
        }
        _ = round(0, onScreen: true)
        session.pauseWireGuardDevice(peer.id)
        XCTAssertTrue(round(0.1, onScreen: true).isEmpty)
        XCTAssertFalse(notifier.wouldTell, "a tap on Pause doesn't ask for permission to notify")
        session.leftScreen()
        for m in stride(from: 1.0, through: 20, by: 1) {
            session.watch()
            XCTAssertTrue(round(m, onScreen: false).isEmpty, "minute \(m)")
        }
    }

    // MARK: What it says

    func testWhatADeviceSays() {
        let peer = WireGuardSetup.Peer(name: "iPad", publicKey: Data(), address: "10.7.0.2")
        var paused = peer
        paused.paused = .byYou
        let cases: [(status: DeviceStatus, label: String, title: String, detail: String?, line: UInt)] = [
            (DeviceStatus(peer, connected: ["10.7.0.2"]), "Connected", "Connected", nil, #line),
            (DeviceStatus(peer, connected: []), "Not connected", "Not connected", nil, #line),
            (DeviceStatus(paused, connected: []), "Paused", "Paused", "It can't connect until you resume it.", #line),
            (DeviceStatus(paused, connected: ["10.7.0.2"]), "Paused", "Paused", "It can't connect until you resume it.", #line),
        ]
        for c in cases {
            XCTAssertEqual(c.status.label, c.label, line: c.line)
            XCTAssertEqual(c.status.title, c.title, line: c.line)
            XCTAssertEqual(c.status.detail, c.detail, line: c.line)
        }
    }

    // MARK: The demo

    func testThePausedDemoHasTheIPadPausedWithItsTunnelUp() throws {
        let session = DemoState(.paused).makeSession()
        let ipad = try XCTUnwrap(session.wireGuardPeers.first { $0.name == "iPad" })
        XCTAssertEqual(ipad.paused, .byYou)
        XCTAssertEqual(session.wireGuardPeers.first { $0.name == "Windows PC" }?.paused, nil)
        XCTAssertEqual(session.wireGuardConnected, [])
        session.resumeWireGuardDevice(ipad.id)
        XCTAssertEqual(session.wireGuardConnected, [ipad.address], "Resume shows it connected, though the demo samples no more")
    }
}
