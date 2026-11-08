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
        try server.start(hosts: ["127.0.0.1"], setup: setup, port: port)
        return port
    }

    func testItStartsAndStops() throws {
        try start()
        XCTAssertTrue(server.running)
        let s = server.snapshot()
        XCTAssertEqual(s.totals, TrafficTotals())
        XCTAssertTrue(s.connected.isEmpty)
        server.stop()
        XCTAssertFalse(server.running)
        XCTAssertEqual(server.snapshot().totals, TrafficTotals(), "a stopped server still answers with its carried counters")
    }

    /// On a carrier that gives the iPhone IPv6 only it listens on 172.20.10.1 and the IPv6 address (#98).
    func testItListensOnTwoAddresses() throws {
        try server.start(hosts: ["127.0.0.1", "::1"], setup: .new(), port: freePort())
        XCTAssertTrue(server.running)
    }

    func testStartingAgainReplacesTheServer() throws {
        try start()
        try start()
        XCTAssertTrue(server.running)
    }

    func testAnAddressThatIsntOneIsAnError() {
        XCTAssertThrowsError(try server.start(hosts: ["not an address"], setup: .new(), port: freePort())) { error in
            XCTAssertTrue("\(error)".contains("ParseAddr"), "\(error)")
        }
        XCTAssertFalse(server.running)
    }

    /// Go reads 32 bytes behind the pointer, so a short key must never get that far.
    func testAShortServerKeyIsRefusedBeforeGo() {
        var setup = WireGuardSetup.new()
        setup.serverPrivateKey = Data(count: 16)
        XCTAssertThrowsError(try server.start(hosts: ["127.0.0.1"], setup: setup, port: freePort())) { error in
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
        XCTAssertThrowsError(try server.start(hosts: ["127.0.0.1"], setup: .new(), port: port)) { error in
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
        XCTAssertTrue(server.snapshot().connected.isEmpty, "stopped")
        try start(setup)
        let snap = server.snapshot()
        XCTAssertTrue(snap.connected.isEmpty, "the connected list comes back from Go, empty until a handshake")
        XCTAssertEqual(snap.peers[setup.peers[0].address], PeerStats(), "listed from Go, with nothing yet")
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
        XCTAssertThrowsError(try server.start(hosts: ["127.0.0.1"], setup: setup, port: freePort()))
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
        let stats = try WireGuardServer.Stats.read(Data(contentsOf: fixture))
        XCTAssertEqual(stats.totals, TrafficTotals(bytesUp: 1840, bytesDown: 5262))
        XCTAssertEqual(stats.connected, ["10.7.0.2"])
        XCTAssertEqual(stats.peers["10.7.0.2"], PeerStats(traffic: TrafficTotals(bytesUp: 1840, bytesDown: 5262), connected: true,
                                                          lastHandshake: Date(timeIntervalSince1970: 1_793_718_000),
                                                          endpoint: "172.20.10.3:51820"))
        XCTAssertEqual(stats.peers["10.7.0.3"], PeerStats(), "never connected: no handshake, no endpoint")
        XCTAssertEqual(stats.stale, StaleConfig(kind: .device, at: Date(timeIntervalSince1970: 1_793_718_030)))
    }

    /// Go sends an empty kind until a config that no longer works knocks, see stale.go.
    func testNoStaleConfigUntilOneKnocks() throws {
        func stale(_ json: String) throws -> StaleConfig? {
            try WireGuardServer.Stats.read(Data(#"{"v":1,"up":0,"down":0,"peers":[],\#(json)}"#.utf8)).stale
        }
        XCTAssertNil(try stale(#""stale":{"kind":"","at":0}"#))
        XCTAssertEqual(try stale(#""stale":{"kind":"server","at":7}"#), StaleConfig(kind: .server, at: Date(timeIntervalSince1970: 7)))
        XCTAssertNil(try stale(#""stale":{"kind":"router","at":7}"#), "a kind this app doesn't know says nothing")
    }

    /// A config made for other server keys knocks with handshakes that fail wireguard-go's mac1 check,
    /// and so do junk handshakes. Two of them reach the snapshot, and they go with the server.
    func testAKnockReachesTheSnapshotAndGoesWithTheServer() async throws {
        let port = try start()
        XCTAssertNil(server.snapshot().stale)
        knock(port, times: 2)
        // wireguard-go reads handshakes on its own goroutines.
        var stale: StaleConfig?
        for _ in 0..<100 where stale == nil {
            try await Task.sleep(for: .milliseconds(20))
            stale = server.snapshot().stale
        }
        XCTAssertEqual(stale?.kind, .server)
        server.stop()
        XCTAssertNil(server.snapshot().stale, "a stopped server knows of no knock")
    }

    /// Junk handshakes, as a config made for other server keys sends: a handshake initiation is type 1
    /// and 148 bytes long, and zeroes for the rest fail wireguard-go's mac1 check.
    private func knock(_ port: UInt16, times: Int) {
        var initiation = [UInt8](repeating: 0, count: 148)
        initiation[0] = 1
        send(initiation, to: port, times: times)
    }

    private func send(_ packet: [UInt8], to port: UInt16, times: Int) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { Darwin.close(fd) }
        var to = sockaddr_in()
        to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); to.sin_family = sa_family_t(AF_INET)
        to.sin_port = port.bigEndian
        to.sin_addr.s_addr = inet_addr("127.0.0.1")
        for _ in 0..<times {
            let sent = withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            XCTAssertEqual(sent, packet.count)
        }
    }

    /// The server's own lines come back through the C API for the shared log, with their times, and
    /// they're taken once. See golog.go. A packet of a type WireGuard doesn't have is a line no other
    /// test makes: one that came in the last minute would be counted, not kept.
    func testTheServersLinesComeBackThroughTheCAPI() async throws {
        let port = try start()
        _ = WireGuardServer.takeLog()
        let before = Date()
        var packet = [UInt8](repeating: 0, count: 32)
        packet[0] = 9
        send(packet, to: port, times: 1)
        let unknown = "go: Received message with unknown type"
        var lines: [DebugLog.Line] = []
        for _ in 0..<100 where !lines.contains(where: { $0.text == unknown }) {
            try await Task.sleep(for: .milliseconds(20))
            lines += WireGuardServer.takeLog()
        }
        let knocked = try XCTUnwrap(lines.first { $0.text == unknown }, "\(lines)")
        XCTAssertGreaterThanOrEqual(knocked.at.timeIntervalSince(before), -0.01)
        XCTAssertLessThanOrEqual(knocked.at.timeIntervalSinceNow, 0.01)
        XCTAssertFalse(lines.contains { $0.text.contains("Routine:") }, "the goroutines' noise is left out")
        XCTAssertFalse(WireGuardServer.takeLog().contains(knocked), "taken once")
    }

    /// WireGuard/testdata/log.json is the shape Go sends: TestLogMatchesTheFixtureSwiftReads checks it
    /// against the live log.
    func testTheLogGoSendsIsRead() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WireGuard/testdata/log.json")
        XCTAssertEqual(try WireGuardServer.ServerLog.read(Data(contentsOf: fixture)), [
            DebugLog.Line(at: Date(timeIntervalSince1970: 1_793_786_553.12), text: "go: 3 earlier lines were lost"),
            DebugLog.Line(at: Date(timeIntervalSince1970: 1_793_786_553.12), text: "go: Interface state was Down, requested Up, now Up"),
            DebugLog.Line(at: Date(timeIntervalSince1970: 1_793_786_554), text: "go: device 10.7.0.2 - Received handshake initiation"),
        ])
    }

    func testALogOfAnotherShapeIsRefused() {
        XCTAssertThrowsError(try WireGuardServer.ServerLog.read(Data(#"{"v":2,"lines":[]}"#.utf8))) { error in
            XCTAssertEqual("\(error)", "version 2, this app reads 1")
        }
        XCTAssertThrowsError(try WireGuardServer.ServerLog.read(Data(#"{"v":1,"text":"x"}"#.utf8)))
    }

    func testStatsOfAnotherShapeAreRefused() {
        XCTAssertThrowsError(try WireGuardServer.Stats.read(Data(#"{"v":2,"up":1,"down":1,"peers":[]}"#.utf8))) { error in
            XCTAssertEqual("\(error)", "version 2, this app reads 1")
        }
        XCTAssertThrowsError(try WireGuardServer.Stats.read(Data(#"{"v":2,"bytes":1}"#.utf8))) { error in
            XCTAssertEqual("\(error)", "version 2, this app reads 1", "the version is read first, whatever else changed")
        }
        XCTAssertThrowsError(try WireGuardServer.Stats.read(Data(#"{"up":1,"down":1,"connected":[]}"#.utf8)),
                             "the shape from before versions")
    }

    func testAStatsKeyAddedLaterIsSkipped() throws {
        let json = #"{"v":1,"up":1,"down":2,"peers":[{"address":"10.7.0.2","connected":true,"up":1,"down":2,"handshake":5,"endpoint":"","paused":true}],"new":0}"#
        XCTAssertEqual(try WireGuardServer.Stats.read(Data(json.utf8)).connected, ["10.7.0.2"])
        XCTAssertNil(try WireGuardServer.Stats.read(Data(json.utf8)).stale, "no stale key, no stale config")
    }

    func testTheDeviceListIsTheMessageGoReads() throws {
        let message = WireGuardServer.ConfigMessage(peers: [.init(key: Data(repeating: 7, count: 32), address: "10.7.0.2")])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        XCTAssertEqual(json?["v"] as? Int, 1)
        let peer = (json?["peers"] as? [[String: Any]])?.first
        XCTAssertEqual(peer?["key"] as? String, Data(repeating: 7, count: 32).base64EncodedString())
        XCTAssertEqual(peer?["address"] as? String, "10.7.0.2")
        XCTAssertNil(json?["dns"], "none given, none sent")
    }

    /// Where lookups to 10.7.0.1 go (#100), a DoH URL or plain servers, never both.
    func testTheDeviceListCarriesTheDNS() throws {
        func dns(_ upstream: DNSChoice.Upstream) throws -> [String: Any]? {
            let message = WireGuardServer.ConfigMessage([], dns: upstream)
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
            return json?["dns"] as? [String: Any]
        }
        let doh = try dns(.doh(URL(string: "https://dns.controld.com/abcd1234")!))
        XCTAssertEqual(doh?["doh"] as? String, "https://dns.controld.com/abcd1234")
        XCTAssertNil(doh?["udp"])
        let plain = try dns(.servers(["1.1.1.1", "1.0.0.1"]))
        XCTAssertEqual(plain?["udp"] as? [String], ["1.1.1.1", "1.0.0.1"])
        XCTAssertNil(plain?["doh"])
    }

    /// Go reads both kinds, at start and in a change.
    func testTheServerTakesEachKindOfDNS() throws {
        let server = WireGuardServer()
        defer { server.stop() }
        let setup = WireGuardSetup.new()
        XCTAssertNoThrow(try server.start(hosts: ["127.0.0.1"], setup: setup, dns: .doh(URL(string: "https://dns.controld.com/abcd1234")!),
                                          port: freePort()))
        XCTAssertNoThrow(try server.setPeers(setup, dns: .servers(["9.9.9.9", "149.112.112.112"])))
        XCTAssertThrowsError(try server.setPeers(setup, dns: .servers(["10.7.0.1"])), "a server lookups can't reach")
    }

    /// A device removed while the hotspot is off drops what it used then, so the next device given its
    /// address starts from zero (#75 counts each device's data by these numbers).
    func testADeviceRemovedWhileStoppedDropsWhatItUsed() throws {
        var carried = CarriedDevices()
        carried.absorb(["10.7.0.2": PeerStats(traffic: TrafficTotals(bytesUp: 10, bytesDown: 100))])
        let server = WireGuardServer(carriedDevices: carried)
        var setup = WireGuardSetup.new()
        let ipad = try XCTUnwrap(setup.addPeer(name: "iPad"))
        XCTAssertEqual(ipad.address, "10.7.0.2")
        try server.setPeers(setup)
        XCTAssertEqual(server.snapshot().peers["10.7.0.2"]?.traffic, TrafficTotals(bytesUp: 10, bytesDown: 100), "kept while it's there")
        setup.removePeer(ipad.id)
        try server.setPeers(setup)
        XCTAssertNil(server.snapshot().peers["10.7.0.2"])
    }

    func testSetPeersBeforeStartDoesNothing() {
        var setup = WireGuardSetup.new()
        _ = setup.addPeer(name: "iPad")
        XCTAssertNoThrow(try server.setPeers(setup))
        XCTAssertFalse(server.running)
    }

    /// Where the config page listens goes to Go, which opens it to the devices there (#27). Go's
    /// tests cover the traffic. An address Go can't read is logged.
    func testThePagesAddressesReachGo() throws {
        var logged: [String] = []
        server = WireGuardServer(log: { logged.append($0) })
        server.setPage(["127.0.0.1"]) // stopped: nothing to tell
        try start()
        server.setPage(["127.0.0.1", "::1"])
        server.setPage([])
        XCTAssertEqual(logged, [])
        server.setPage(["not an address"])
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged.first?.contains("page address") == true, "\(logged)")
    }

    func testFreeingMemoryIsSafeStoppedOrRunning() throws {
        server.freeMemory()
        try start()
        server.freeMemory()
        XCTAssertTrue(server.running)
    }
}
