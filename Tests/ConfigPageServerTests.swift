import Network
import XCTest
@testable import TetherCore

/// The real listener on loopback, with a port the system picks, and a raw TCP client so the tests
/// send exactly the bytes they mean to.
@MainActor
final class ConfigPageServerTests: XCTestCase {
    private var server: ConfigPageServer!
    private var asked: [(ConfigPage.Request, String)] = []

    override func tearDown() async throws {
        server?.stop()
        server = nil
    }

    /// Listening on 127.0.0.1, answering every request with the page and noting who asked for what.
    private func listen(timeout: TimeInterval = 5) async throws -> UInt16 {
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
            }
        }
        let ready = expectation(description: "listening")
        server.onChange = { [unowned self] in if server.listening { ready.fulfill() } }
        server.start(host: "127.0.0.1", port: 0)
        XCTAssertTrue(server.running, "running from the start, before it's ready")
        await fulfillment(of: [ready], timeout: 5)
        return try XCTUnwrap(server.port)
    }

    /// Sends `bytes` and reads until the server closes. Nil when the connection fails.
    private nonisolated func exchange(_ bytes: Data, port: UInt16) async -> Data? {
        await withCheckedContinuation { done in
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let queue = DispatchQueue(label: "test.client")
            var received = Data()
            var finished = false
            func finish(_ result: Data?) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                done.resume(returning: result)
            }
            func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let data { received.append(data) }
                    if isComplete { finish(received) } else if error != nil { finish(received.isEmpty ? nil : received) } else { read() }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !bytes.isEmpty { connection.send(content: bytes, completion: .contentProcessed { _ in }) }
                    read()
                case .failed, .waiting: finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func text(_ data: Data?) -> String { data.flatMap { String(data: $0, encoding: .utf8) } ?? "" }

    func testItAnswersOneRequestAndCloses() async throws {
        let port = try await listen()
        let page = text(await exchange(Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8), port: port))
        XCTAssertTrue(page.hasPrefix("HTTP/1.1 200 OK\r\n"), page)
        XCTAssertTrue(page.hasSuffix("</html>\n"), "the whole body arrives before the close")
        let config = text(await exchange(Data("GET /Tether.conf HTTP/1.1\r\n\r\n".utf8), port: port))
        XCTAssertTrue(config.hasSuffix("\r\n\r\n[Interface]\n"), config)
        XCTAssertEqual(asked.map(\.0), [.page, .config])
        XCTAssertEqual(asked.map(\.1), ["127.0.0.1", "127.0.0.1"], "who asked, for the log")
    }

    func testARequestInPiecesIsAnsweredOnceWhole() async throws {
        let port = try await listen()
        // One send, but the head is only complete at the end: the server must wait for all of it.
        let head = "GET /Tether.conf HTTP/1.1\r\n" + String(repeating: "X-Pad: 1234567890\r\n", count: 200) + "\r\n"
        let reply = text(await exchange(Data(head.utf8), port: port))
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK"), reply)
        XCTAssertEqual(asked.map(\.0), [.config])
    }

    func testAHeadOver8KBIsRefused() async throws {
        let port = try await listen()
        let head = "GET / HTTP/1.1\r\n" + String(repeating: "X-Pad: 1234567890\r\n", count: 600) // no end, ~11 KB
        let reply = text(await exchange(Data(head.utf8), port: port))
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 400 Bad Request"), reply)
        XCTAssertEqual(asked.map(\.0), [.malformed])
    }

    func testAConnectionThatSendsNothingIsClosed() async throws {
        let port = try await listen(timeout: 0.3)
        let started = Date()
        let reply = await exchange(Data(), port: port)
        XCTAssertEqual(reply ?? Data(), Data(), "closed with no answer")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertTrue(asked.isEmpty)
    }

    func testAfterStopNothingListens() async throws {
        let port = try await listen()
        server.stop()
        XCTAssertFalse(server.running)
        XCTAssertFalse(server.listening)
        XCTAssertNil(server.port)
        let reply = await exchange(Data("GET / HTTP/1.1\r\n\r\n".utf8), port: port)
        XCTAssertNil(reply, "connection refused")
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
        XCTAssertEqual(ninth ?? Data(), Data(), "closed with no answer")
        XCTAssertTrue(asked.isEmpty)
        try await Task.sleep(for: .milliseconds(1_500)) // the eight time out
        let later = text(await exchange(Data("GET / HTTP/1.1\r\n\r\n".utf8), port: port))
        XCTAssertTrue(later.hasPrefix("HTTP/1.1 200 OK"), later)
    }

    /// The hotspot off and on again: the same address and port, with the last answers' connections
    /// still closing (TIME_WAIT, since the server closes first).
    func testItStartsAgainOnTheSamePortRightAfterServing() async throws {
        let port = try await listen()
        _ = await exchange(Data("GET / HTTP/1.1\r\n\r\n".utf8), port: port)
        server.stop()
        let ready = expectation(description: "listening again")
        server.onChange = { [unowned self] in if server.listening { ready.fulfill() } }
        server.onFailure = { XCTFail("\($0)") }
        server.start(host: "127.0.0.1", port: port)
        await fulfillment(of: [ready], timeout: 5)
        let reply = text(await exchange(Data("GET / HTTP/1.1\r\n\r\n".utf8), port: port))
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK"), reply)
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
        second.start(host: "127.0.0.1", port: port)
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertFalse(second.running)
        XCTAssertFalse(second.listening)
        second.stop()
    }
}
