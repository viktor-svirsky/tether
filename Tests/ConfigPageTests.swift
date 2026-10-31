import XCTest
@testable import TetherCore

/// What the config page reads from a request, and the answers it sends.
final class ConfigPageTests: XCTestCase {
    private func request(_ text: String) -> ConfigPage.Request {
        ConfigPage.Request(Data(text.utf8))
    }

    func testOnlyTheRequestLineCounts() {
        let cases: [(head: String, request: ConfigPage.Request, line: UInt)] = [
            ("GET / HTTP/1.1\r\nHost: 172.20.10.1\r\n\r\n", .page, #line),
            ("GET / HTTP/1.0\r\n\r\n", .page, #line),
            ("GET /?from=qr HTTP/1.1\r\n\r\n", .page, #line), // the query is ignored
            ("GET /Tether.conf HTTP/1.1\r\n\r\n", .config, #line),
            ("GET /Tether.conf?x=1 HTTP/1.1\r\n\r\n", .config, #line),
            ("GET /favicon.ico HTTP/1.1\r\n\r\n", .notFound, #line),
            ("GET /tether.conf HTTP/1.1\r\n\r\n", .notFound, #line), // paths are case-sensitive
            ("GET /Tether.conf/ HTTP/1.1\r\n\r\n", .notFound, #line),
            ("HEAD / HTTP/1.1\r\n\r\n", .pageHead, #line),
            ("HEAD /Tether.conf HTTP/1.1\r\n\r\n", .configHead, #line),
            ("HEAD /favicon.ico HTTP/1.1\r\n\r\n", .notFound, #line),
            ("OPTIONS / HTTP/1.1\r\n\r\n", .notGet, #line),
            ("POST /Tether.conf HTTP/1.1\r\n\r\n", .notGet, #line),
            ("get / HTTP/1.1\r\n\r\n", .notGet, #line), // methods are case-sensitive
            ("", .malformed, #line),
            ("GET / HTTP/1.1", .malformed, #line), // no line end
            ("GET /\r\n\r\n", .malformed, #line), // HTTP/0.9
            ("GET / SPDY/3\r\n\r\n", .malformed, #line),
            ("GET  / HTTP/1.1\r\n\r\n", .malformed, #line), // two spaces
            ("GET http://172.20.10.1/ HTTP/1.1\r\n\r\n", .malformed, #line), // only the path form
            ("GET / HTTP/1.1 extra\r\n\r\n", .malformed, #line),
        ]
        for c in cases {
            XCTAssertEqual(request(c.head), c.request, line: c.line)
        }
        XCTAssertEqual(ConfigPage.Request(Data([0x47, 0x45, 0x54, 0x20, 0xFF, 0xFE, 0x0D, 0x0A])), .malformed, "not UTF-8")
    }

    func testAHeadIsCompleteAtTheEmptyLine() {
        XCTAssertFalse(ConfigPage.headComplete(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)))
        XCTAssertTrue(ConfigPage.headComplete(Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
    }

    /// The parts of a response, split the way a client reads it.
    private func parts(_ response: ConfigPage.Response) throws -> (status: String, headers: [String: String], body: Data) {
        let bytes = response.bytes
        let end = try XCTUnwrap(bytes.range(of: Data("\r\n\r\n".utf8)))
        let head = try XCTUnwrap(String(data: bytes[..<end.lowerBound], encoding: .utf8))
        var lines = head.components(separatedBy: "\r\n")
        let status = lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(pair.count, 2, line)
            XCTAssertNil(headers[pair[0]], "\(pair[0]) twice")
            headers[pair[0]] = pair[1]
        }
        return (status, headers, Data(bytes[end.upperBound...]))
    }

    /// The config holds a private key: it's never cached, never shown as text, and the page runs no scripts.
    func testEveryAnswerIsClosedUncachedAndScriptFree() throws {
        let all: [(ConfigPage.Response, String)] = [
            (ConfigPage.page(.ready), "HTTP/1.1 200 OK"),
            (ConfigPage.page(.openTether), "HTTP/1.1 200 OK"),
            (ConfigPage.page(.openTether, status: .notFound), "HTTP/1.1 404 Not Found"),
            (ConfigPage.page(.noConfig, status: .unavailable), "HTTP/1.1 503 Service Unavailable"),
            (ConfigPage.config("[Interface]\n", fileName: "Tether-Device.conf"), "HTTP/1.1 200 OK"),
            (ConfigPage.notFound, "HTTP/1.1 404 Not Found"),
            (ConfigPage.notGet, "HTTP/1.1 405 Method Not Allowed"),
            (ConfigPage.malformed, "HTTP/1.1 400 Bad Request"),
        ]
        for (response, status) in all {
            let p = try parts(response)
            XCTAssertEqual(p.status, status)
            XCTAssertEqual(p.headers["Content-Length"], String(response.body.count), status)
            XCTAssertEqual(p.body, response.body, status)
            XCTAssertEqual(p.headers["Cache-Control"], "no-store", status)
            XCTAssertEqual(p.headers["X-Content-Type-Options"], "nosniff", status)
            XCTAssertEqual(p.headers["Referrer-Policy"], "no-referrer", status)
            XCTAssertEqual(p.headers["Connection"], "close", status)
            XCTAssertTrue(p.headers["Content-Security-Policy"]?.hasPrefix("default-src 'none'") ?? false, status)
        }
        XCTAssertEqual(try parts(ConfigPage.notGet).headers["Allow"], "GET, HEAD")
    }

    func testAHeadAnswerHasTheGetsLengthAndNoBody() throws {
        let get = ConfigPage.config("[Interface]\n", fileName: "Tether-Device.conf")
        let head = try parts(get.forHead)
        XCTAssertEqual(head.headers["Content-Length"], String(get.body.count))
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertEqual(head.headers["Content-Disposition"], "attachment; filename=\"Tether-Device.conf\"")
    }

    func testTheConfigDownloadsAsAFileNamedForTheDevice() throws {
        let text = "[Interface]\nPrivateKey = abc\n"
        let p = try parts(ConfigPage.config(text, fileName: "Tether-Device-2.conf"))
        XCTAssertEqual(p.headers["Content-Type"], "application/octet-stream")
        XCTAssertEqual(p.headers["Content-Disposition"], "attachment; filename=\"Tether-Device-2.conf\"")
        XCTAssertEqual(String(data: p.body, encoding: .utf8), text)
    }

    func testOnlyAReadyPageLinksTheConfig() throws {
        func html(_ state: ConfigPage.State) throws -> String {
            let p = try parts(ConfigPage.page(state))
            XCTAssertEqual(p.headers["Content-Type"], "text/html; charset=utf-8")
            return try XCTUnwrap(String(data: p.body, encoding: .utf8))
        }
        let ready = try html(.ready)
        XCTAssertTrue(ready.contains("href=\"/Tether.conf\""))
        XCTAssertTrue(ready.contains("WireGuard"))
        let open = try html(.openTether)
        XCTAssertFalse(open.contains("Tether.conf"))
        XCTAssertTrue(open.contains("Open Tether on the iPhone"))
        let none = try html(.noConfig)
        XCTAssertFalse(none.contains("Tether.conf"))
        XCTAssertTrue(none.contains("can't make a config"))
    }

    func testTheAddressLeavesOutPort80() {
        XCTAssertEqual(ConfigPage.url(host: "172.20.10.1", port: 80), "http://172.20.10.1")
        XCTAssertEqual(ConfigPage.url(host: "172.20.10.1", port: 8080), "http://172.20.10.1:8080")
    }
}
