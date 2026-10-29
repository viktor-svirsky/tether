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
        XCTAssertFalse(server.running, "the watcher in Model retries only a server that isn't running")
    }

    /// What Model counts on when the server refuses a new list: it keeps running with the old one,
    /// so Model starts it again with the saved setup.
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
