import Foundation
import XCTest
@testable import TetherCore

/// WireGuardServer.swift through the C API into the real Go server (WireGuard/, linked as
/// TetherWG.xcframework's macOS slice). Traffic through the tunnel is tested in Go, where a real
/// WireGuard client exists. These cover the Swift side and the boundary: keys and strings going
/// in, errors and stats coming back.
@MainActor
final class WireGuardServerTests: XCTestCase {
    private var server: WireGuardServer!

    override func setUp() async throws {
        server = WireGuardServer()
    }

    override func tearDown() async throws {
        server.stop()
    }

    /// A UDP port nothing is using right now.
    private func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { Darwin.close(fd) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, len)
            return getsockname(fd, $0, &len)
        } }
        return UInt16(bigEndian: a.sin_port)
    }

    private func start(_ setup: WireGuardSetup = .new()) throws -> UInt16 {
        let port = freePort()
        try server.start(host: "127.0.0.1", setup: setup, port: port)
        return port
    }

    func testItStartsAndStops() throws {
        try start()
        XCTAssertTrue(server.running)
        let s = server.snapshot()
        XCTAssertEqual(s.bytesUp, 0)
        XCTAssertEqual(s.bytesDown, 0)
        XCTAssertTrue(server.connectedAddresses.isEmpty)
        server.stop()
        XCTAssertFalse(server.running)
        XCTAssertEqual(server.snapshot().bytesDown, 0, "a stopped server still answers with its carried counters")
    }

    func testStartingAgainReplacesTheServer() throws {
        try start()
        try start()
        XCTAssertTrue(server.running)
    }

    func testAnAddressThatIsntOneIsAnError() {
        XCTAssertThrowsError(try server.start(host: "not an address", setup: .new(), port: freePort())) { error in
            XCTAssertTrue("\(error)".contains("ParseAddr"), "\(error)")
        }
        XCTAssertFalse(server.running)
    }

    /// Go reads 32 bytes behind the pointer, so a short key must never get that far.
    func testAShortServerKeyIsRefusedBeforeGo() {
        var setup = WireGuardSetup.new()
        setup.serverPrivateKey = Data(count: 16)
        XCTAssertThrowsError(try server.start(host: "127.0.0.1", setup: setup, port: freePort())) { error in
            XCTAssertTrue("\(error)".contains("32 bytes"))
        }
        XCTAssertFalse(server.running)
    }

    func testAPortInUseIsAnError() throws {
        let port = freePort()
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { Darwin.close(fd) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        XCTAssertThrowsError(try server.start(host: "127.0.0.1", setup: .new(), port: port)) { error in
            XCTAssertTrue("\(error)".contains("address already in use"), "\(error)")
        }
        XCTAssertFalse(server.running, "not left half started")
    }

    func testDevicesAreLetIn() throws {
        var setup = WireGuardSetup.new()
        _ = setup.addPeer(name: "iPad")
        _ = setup.addPeer(name: "Mac")
        try start(setup)
        _ = setup.addPeer(name: "Phone")
        XCTAssertNoThrow(try server.setPeers(setup))
        setup.removePeer(setup.peers[0].id)
        XCTAssertNoThrow(try server.setPeers(setup))
        XCTAssertNoThrow(try server.setPeers(WireGuardSetup.new()), "no devices at all is fine")
    }

    func testTheReadyDeviceIsLetInToo() throws {
        var setup = WireGuardSetup.new()
        _ = setup.addPeer(name: "iPad")
        setup.prepareReady()
        try start(setup)
        XCTAssertNoThrow(try server.setPeers(setup))
        setup.ready?.publicKey = Data(count: 16) // only checked if it's sent
        XCTAssertThrowsError(try server.setPeers(setup)) { error in
            XCTAssertTrue("\(error)".contains("32 bytes"), "\(error)")
        }
    }

    func testNoDeviceIsConnectedBeforeAHandshake() throws {
        var setup = WireGuardSetup.new()
        _ = setup.addPeer(name: "iPad")
        XCTAssertTrue(server.connectedAddresses.isEmpty, "stopped")
        try start(setup)
        _ = server.snapshot()
        XCTAssertTrue(server.connectedAddresses.isEmpty, "the connected list comes back from Go, empty until a handshake")
    }

    func testASetupGoRefusesComesBackAsAnError() throws {
        var setup = WireGuardSetup.new()
        let a = setup.addPeer(name: "iPad")!
        var b = setup.addPeer(name: "Mac")!
        setup.removePeer(b.id)
        b.address = a.address // two devices on one tunnel address
        setup.peers.append(b)
        try start()
        XCTAssertThrowsError(try server.setPeers(setup)) { error in
            XCTAssertTrue("\(error)".contains("repeats a key or address"), "\(error)")
        }
    }

    func testAStartWhosePeersFailIsUndone() {
        var setup = WireGuardSetup.new()
        let a = setup.addPeer(name: "iPad")!
        var b = setup.addPeer(name: "Mac")!
        setup.removePeer(b.id)
        b.address = a.address
        setup.peers.append(b)
        XCTAssertThrowsError(try server.start(host: "127.0.0.1", setup: setup, port: freePort()))
        XCTAssertFalse(server.running, "HotspotSession's watcher retries only a server that isn't running")
    }

    /// A refused list leaves the server running with the old one, which may still let in a removed
    /// device. So HotspotSession starts it again with the saved setup: a list it accepts runs, and one
    /// it refuses leaves it stopped (see `testAStartWhosePeersFailIsUndone`).
    func testARefusedListKeepsTheServerRunningAndAStartWithTheSavedSetupWorks() throws {
        var saved = WireGuardSetup.new()
        _ = saved.addPeer(name: "iPad")
        try start(saved)
        var refused = saved
        refused.peers[0].publicKey = Data(count: 5)
        XCTAssertThrowsError(try server.setPeers(refused))
        XCTAssertTrue(server.running, "still running with the list it had")
        try start(saved)
        XCTAssertTrue(server.running)
    }

    func testAShortDeviceKeyIsRefusedBeforeGo() throws {
        var setup = WireGuardSetup.new()
        var peer = setup.addPeer(name: "iPad")!
        setup.removePeer(peer.id)
        peer.publicKey = Data(count: 5)
        setup.peers.append(peer)
        try start()
        XCTAssertThrowsError(try server.setPeers(setup)) { error in
            XCTAssertTrue("\(error)".contains("32 bytes"))
        }
    }

    /// WireGuard/testdata/stats.json is the shape Go sends, with traffic and one of two devices
    /// connected: TestStatsMatchTheFixtureSwiftReads checks it against a live server.
    func testTheStatsGoSendsAreRead() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WireGuard/testdata/stats.json")
        let stats = try WireGuardServer.Stats(json: Data(contentsOf: fixture))
        XCTAssertEqual(stats.totals, TrafficTotals(bytesUp: 1840, bytesDown: 5262))
        XCTAssertEqual(stats.connected, ["10.7.0.2"])
    }

    func testStatsOfAnotherShapeAreRefused() {
        XCTAssertThrowsError(try WireGuardServer.Stats(json: Data(#"{"v":2,"up":1,"down":1,"peers":[]}"#.utf8))) { error in
            XCTAssertEqual("\(error)", "version 2, this app reads 1")
        }
        XCTAssertThrowsError(try WireGuardServer.Stats(json: Data(#"{"up":1,"down":1,"connected":[]}"#.utf8)),
                             "the shape from before versions")
    }

    func testAStatsKeyAddedLaterIsSkipped() throws {
        let json = #"{"v":1,"up":1,"down":2,"peers":[{"address":"10.7.0.2","connected":true,"handshake":5}],"paused":[]}"#
        XCTAssertEqual(try WireGuardServer.Stats(json: Data(json.utf8)).connected, ["10.7.0.2"])
    }

    func testTheDeviceListIsTheMessageGoReads() throws {
        let message = WireGuardServer.ConfigMessage(peers: [.init(key: Data(repeating: 7, count: 32), address: "10.7.0.2")])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        XCTAssertEqual(json?["v"] as? Int, 1)
        let peer = (json?["peers"] as? [[String: Any]])?.first
        XCTAssertEqual(peer?["key"] as? String, Data(repeating: 7, count: 32).base64EncodedString())
        XCTAssertEqual(peer?["address"] as? String, "10.7.0.2")
    }

    func testSetPeersBeforeStartDoesNothing() {
        var setup = WireGuardSetup.new()
        _ = setup.addPeer(name: "iPad")
        XCTAssertNoThrow(try server.setPeers(setup))
        XCTAssertFalse(server.running)
    }

    func testFreeingMemoryIsSafeStoppedOrRunning() throws {
        server.freeMemory()
        try start()
        server.freeMemory()
        XCTAssertTrue(server.running)
    }
}
