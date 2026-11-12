import Network
import XCTest
@testable import TetherCore

/// The real listener on loopback, on a free port below the system's own range (see `freeTCPPort`),
/// and a raw TCP client so the tests send exactly the bytes they mean to.
@MainActor
final class ConfigPageServerTests: XCTestCase {
    private var server: ConfigPageServer!
    private var asked: [(ConfigPage.Request, String)] = []

    override func tearDown() async throws {
        server?.stop()
        server = nil
    }

    /// Listening on 127.0.0.1, answering every request with the page and noting who asked for what.
    private func listen(on hosts: [String] = ["127.0.0.1"], port: UInt16? = nil, timeout: TimeInterval = 5) async throws -> UInt16 {
        let port = try port ?? freeTCPPort()
        server = ConfigPageServer(timeout: timeout)
        server.respond = { [unowned self] request, client in
            asked.append((request, client))
            return switch request {
            case .page: ConfigPage.page(.ready)
            case .config: ConfigPage.config("[Interface]\n", fileName: "Tether-Device.conf")
            case .pageHead: ConfigPage.page(.ready).forHead
            case .configHead: ConfigPage.config("[Interface]\n", fileName: "Tether-Device.conf").forHead
            case .notFound: ConfigPage.notFound
            case .notGet: ConfigPage.notGet
            case .malformed: ConfigPage.malformed
            case .configWithoutToken: ConfigPage.page(.ready, status: .notFound)
            }
        }
        let ready = expectation(description: "listening")
        ready.assertForOverFulfill = false // once for each address that gets ready
        server.onChange = { [unowned self] in if server.listening { ready.fulfill() } }
        server.start(hosts: hosts, port: port)
        XCTAssertTrue(server.running, "running from the start, before it's ready")
        await fulfillment(of: [ready], timeout: 5)
        return try XCTUnwrap(server.port)
    }

    /// What the server sent before it closed (nil when the connection failed), and how it ended, so a
    /// failed assertion says why nothing came (#131).
    private struct Reply {
        var data: Data?
        var why: String
    }

    /// Sends `bytes` and reads until the server closes.
    private nonisolated func exchange(_ bytes: Data, port: UInt16, host: NWEndpoint.Host = "127.0.0.1") async -> Reply {
        await withCheckedContinuation { done in
            let connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let queue = DispatchQueue(label: "test.client")
            var received = Data()
            var finished = false
            func finish(_ result: Data?, _ why: String) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                done.resume(returning: Reply(data: result, why: why))
            }
            func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let data { received.append(data) }
                    if isComplete {
                        finish(received, "closed by the server")
                    } else if let error {
                        finish(received.isEmpty ? nil : received, "receive failed: \(error)")
                    } else {
                        read()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !bytes.isEmpty { connection.send(content: bytes, completion: .contentProcessed { _ in }) }
                    read()
                case .failed, .waiting: finish(nil, "connection \(state)")
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// The answer as text, or why there is none.
    private func text(_ reply: Reply) -> String {
        guard let data = reply.data, !data.isEmpty else { return "no answer, \(reply.why)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether connections to `host` fail within 2 seconds. A stopped listener closes its socket
    /// asynchronously (#102), so one tried at once can still be accepted and closed.
    private func refusedSoon(port: UInt16, host: NWEndpoint.Host = "127.0.0.1") async throws -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await exchange(Data("GET / HTTP/1.1\r\n\r\n".utf8), port: port, host: host).data == nil { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    func testItAnswersOneRequestAndCloses() async throws {
        let port = try await listen()
        let page = text(await exchange(Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8), port: port))
        XCTAssertTrue(page.hasPrefix("HTTP/1.1 200 OK\r\n"), page)
        XCTAssertTrue(page.hasSuffix("</html>\n"), "the whole body arrives before the close")
        let config = text(await exchange(Data("GET \(ConfigPage.downloadPath) HTTP/1.1\r\n\r\n".utf8), port: port))
        XCTAssertTrue(config.hasSuffix("\r\n\r\n[Interface]\n"), config)
        XCTAssertEqual(asked.map(\.0), [.page, .config])
        XCTAssertEqual(asked.map(\.1), ["127.0.0.1", "127.0.0.1"], "who asked, for the log")
    }

    /// A page that pointed its own name at this address sends that name as Host, and gets a 400 (#158).
    func testAForeignHostGetsA400OverTheWire() async throws {
        let port = try await listen()
        let reply = text(await exchange(Data("GET \(ConfigPage.downloadPath) HTTP/1.1\r\nHost: evil.example\r\n\r\n".utf8), port: port))
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 400 Bad Request"), reply)
    }

    func testARequestInPiecesIsAnsweredOnceWhole() async throws {
        let port = try await listen()
        // One send, but the head is only complete at the end: the server must wait for all of it.
        let head = "GET \(ConfigPage.downloadPath) HTTP/1.1\r\n" + String(repeating: "X-Pad: 1234567890\r\n", count: 200) + "\r\n"
        let reply = text(await exchange(Data(head.utf8), port: port))
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK"), reply)
        XCTAssertEqual(asked.map(\.0), [.config])
    }

    func testAHeadOver8KBIsRefused() async throws {
        let port = try await listen()
        let head = "GET / HTTP/1.1\r\n" + String(repeating: "X-Pad: 1234567890\r\n", count: 6_000) // no end, ~114 KB: most of it unread at the answer
        let reply = text(await exchange(Data(head.utf8), port: port))
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 400 Bad Request"), reply)
        XCTAssertEqual(asked.map(\.0), [.malformed])
    }

    func testAConnectionThatSendsNothingIsClosed() async throws {
        let port = try await listen(timeout: 0.3)
        let started = Date()
        let reply = await exchange(Data(), port: port)
        XCTAssertEqual(reply.data ?? Data(), Data(), "closed with no answer")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertTrue(asked.isEmpty)
    }

    func testAfterStopNothingListens() async throws {
        let port = try await listen()
        server.stop()
        XCTAssertFalse(server.running)
        XCTAssertFalse(server.listening)
        XCTAssertEqual(server.readyHosts, [])
        XCTAssertNil(server.port)
        let refused = try await refusedSoon(port: port)
        XCTAssertTrue(refused, "connection refused")
    }

    /// Connections past 8 are closed at once, and a connection that closes frees its place.
    func testANinthConnectionIsClosedUntilOneEnds() async throws {
        let port = try await listen(timeout: 1)
        let idle = (0..<8).map { _ in
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection.start(queue: .main)
            return connection
        }
        defer { idle.forEach { $0.cancel() } }
        try await Task.sleep(for: .milliseconds(300)) // all eight accepted
        let ninth = await exchange(Data("GET / HTTP/1.1\r\n\r\n".utf8), port: port)
        XCTAssertEqual(ninth.data ?? Data(), Data(), "closed with no answer")
        XCTAssertTrue(asked.isEmpty)
        try await Task.sleep(for: .milliseconds(1_500)) // the eight time out
        let later = text(await exchange(Data("GET / HTTP/1.1\r\n\r\n".utf8), port: port))
        XCTAssertTrue(later.hasPrefix("HTTP/1.1 200 OK"), later)
    }

    /// The hotspot off and on again: the same address and port in the same turn, as a hotspot address
    /// change does (#102). The old listener's socket isn't closed yet, and the last answers'
    /// connections are still closing (TIME_WAIT, since the server closes first).
    func testItStartsAgainOnTheSamePortRightAfterServing() async throws {
        let port = try await listen()
        _ = await exchange(Data("GET / HTTP/1.1\r\n\r\n".utf8), port: port)
        server.stop()
        let ready = expectation(description: "listening again")
        server.onChange = { [unowned self] in if server.listening { ready.fulfill() } }
        server.onFailure = { XCTFail("\($0)") }
        server.start(hosts: ["127.0.0.1"], port: port)
        await fulfillment(of: [ready], timeout: 5)
        let reply = text(await exchange(Data("GET / HTTP/1.1\r\n\r\n".utf8), port: port))
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK"), reply)
    }

    /// A start waits until the listeners it replaces say they closed. One that failed must say so
    /// too, or the page never starts again.
    func testItStartsAgainAfterAFailure() async throws {
        server = ConfigPageServer()
        let failed = expectation(description: "failed")
        server.onFailure = { _ in failed.fulfill() }
        server.start(hosts: ["192.0.2.1"], port: 0) // an address this Mac doesn't have
        await fulfillment(of: [failed], timeout: 5)
        let ready = expectation(description: "listening")
        server.onChange = { [unowned self] in if server.listening { ready.fulfill() } }
        server.onFailure = { XCTFail("\($0)") }
        server.start(hosts: ["127.0.0.1"], port: 0)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertNotNil(server.port, "the port the system picked")
    }

    /// Another listener already has the port: this one fails, says so, and HotspotSession starts it again later.
    func testAPortInUseStopsIt() async throws {
        let port = try await listen()
        let second = ConfigPageServer()
        let failed = expectation(description: "failed")
        second.onFailure = { error in
            XCTAssertEqual((error as? NWError).map { "\($0)" }, "\(NWError.posix(.EADDRINUSE))")
            failed.fulfill()
        }
        second.start(hosts: ["127.0.0.1"], port: port)
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertFalse(second.running)
        XCTAssertFalse(second.listening)
        XCTAssertEqual(second.readyHosts, [], "WireGuard mustn't open the port to the devices: it's another listener's (#27)")
        second.stop()
    }

    /// On a carrier that gives the iPhone IPv6 only, the page is on 172.20.10.1 and the IPv6 address
    /// (#98): one port, each address answering, and each client named by its own address.
    func testItListensOnEachAddress() async throws {
        let port = try await listen(on: ["127.0.0.1", "::1"])
        for host: NWEndpoint.Host in ["127.0.0.1", "::1"] {
            let reply = text(await exchange(Data("GET / HTTP/1.1\r\n\r\n".utf8), port: port, host: host))
            XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK"), "\(host): \(reply)")
        }
        XCTAssertEqual(asked.map(\.1), ["127.0.0.1", "::1"])
        XCTAssertEqual(Set(server.readyHosts), ["127.0.0.1", "::1"])
        server.stop()
        let refused = try await refusedSoon(port: port, host: "::1")
        XCTAssertTrue(refused, "both stopped")
    }

    /// An address that can't be listened on stops them all, so HotspotSession starts them again later,
    /// that one too.
    func testOneAddressThatFailsStopsThemAll() async throws {
        let port = try freeTCPPort()
        let taken = ConfigPageServer()
        let up = expectation(description: "taken")
        taken.onChange = { if taken.listening { up.fulfill() } }
        taken.start(hosts: ["::1"], port: port)
        await fulfillment(of: [up], timeout: 5)
        defer { taken.stop() }

        server = ConfigPageServer()
        server.respond = { _, _ in ConfigPage.page(.ready) }
        let failed = expectation(description: "the IPv6 one failed")
        server.onFailure = { _ in failed.fulfill() }
        server.start(hosts: ["127.0.0.1", "::1"], port: port)
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertFalse(server.running)
        XCTAssertFalse(server.listening)
        XCTAssertEqual(server.readyHosts, [], "the IPv4 one may have been ready before")
        let reply = await exchange(Data("GET / HTTP/1.1\r\n\r\n".utf8), port: port)
        XCTAssertNil(reply.data, "the IPv4 one stopped too: \(reply.why)")
    }

    /// A port free on 127.0.0.1 and ::1, below the range the system hands out for port 0 and for
    /// clients (#131). In that range a listener can get a port a client of an earlier test just used,
    /// and a client the port an earlier listener had. That connection's TIME_WAIT then holds the same
    /// address pair, and the client fails with "address in use" before it sends anything. On the CI
    /// runner, which picks listener ports at random, that was 39 restarts in 2570.
    private func freeTCPPort() throws -> UInt16 {
        var first: Int32 = 49_152
        var size = MemoryLayout<Int32>.size
        sysctlbyname("net.inet.ip.portrange.first", &first, &size, nil, 0)
        for _ in 0..<50 {
            let port = UInt16.random(in: 20_000..<UInt16(clamping: first))
            if bindable(port, family: AF_INET), bindable(port, family: AF_INET6) { return port }
        }
        throw XCTSkip("no free port")
    }

    private func bindable(_ port: UInt16, family: Int32) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        defer { close(fd) }
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
        }
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 } }
    }
}
