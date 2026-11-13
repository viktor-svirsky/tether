import XCTest
@testable import TetherCore

/// What the config page reads from a request, and the answers it sends.
final class ConfigPageTests: XCTestCase {
    private func request(_ text: String, hosts: [String] = ["172.20.10.1"]) -> ConfigPage.Request {
        ConfigPage.Request(Data(text.utf8), hosts: hosts)
    }

    private let download = "GET \(ConfigPage.downloadPath) HTTP/1.1\r\n"

    func testTheRequestLineSaysWhatIsAsked() {
        let cases: [(head: String, request: ConfigPage.Request, line: UInt)] = [
            ("GET / HTTP/1.1\r\nHost: 172.20.10.1\r\n\r\n", .page, #line),
            ("GET / HTTP/1.0\r\n\r\n", .page, #line),
            ("GET /?from=qr HTTP/1.1\r\n\r\n", .page, #line), // the query is ignored
            ("GET /Tether.conf?t=\(ConfigPage.token) HTTP/1.1\r\n\r\n", .config, #line),
            ("GET /Tether.conf?x=1&t=\(ConfigPage.token) HTTP/1.1\r\n\r\n", .config, #line),
            ("GET /favicon.ico HTTP/1.1\r\n\r\n", .notFound, #line),
            ("GET /tether.conf HTTP/1.1\r\n\r\n", .notFound, #line), // paths are case-sensitive
            ("GET /Tether.conf/ HTTP/1.1\r\n\r\n", .notFound, #line),
            ("HEAD / HTTP/1.1\r\n\r\n", .pageHead, #line),
            ("HEAD /Tether.conf?t=\(ConfigPage.token) HTTP/1.1\r\n\r\n", .configHead, #line),
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
        XCTAssertEqual(ConfigPage.Request(Data([0x47, 0x45, 0x54, 0x20, 0xFF, 0xFE, 0x0D, 0x0A]), hosts: []), .malformed, "not UTF-8")
    }

    /// A page from another site that points its name at the iPhone (DNS rebinding) sends its own name
    /// as Host, and gets a 400 instead of a config it could read (#158).
    func testOnlyTetherOwnAddressesAreAcceptedAsHost() {
        let hosts = ["172.20.10.1", "2607:fb91:88a2:e822::1"]
        let cases: [(host: String?, request: ConfigPage.Request, line: UInt)] = [
            ("172.20.10.1", .config, #line),
            ("172.20.10.1:80", .config, #line),
            ("[2607:fb91:88a2:e822::1]", .config, #line),
            ("[2607:FB91:88A2:E822:0:0:0:1]:80", .config, #line), // the same address, written another way
            (nil, .config, #line), // HTTP/1.0 may send none, and a rebinding browser always does
            ("evil.example", .malformed, #line),
            ("172.20.10.1.", .malformed, #line), // a trailing dot is a name, not the address
            ("evil.example:80", .malformed, #line),
            ("172.20.10.2", .malformed, #line),
            ("[2607:fb91:88a2:e822::2]", .malformed, #line),
            ("", .malformed, #line),
        ]
        for c in cases {
            let head = download + (c.host.map { "Host: \($0)\r\n" } ?? "") + "\r\n"
            XCTAssertEqual(request(head, hosts: hosts), c.request, c.host ?? "none", line: c.line)
        }
        XCTAssertEqual(request("GET / HTTP/1.1\r\nhOsT:  evil.example \r\n\r\n"), .malformed, "the name is case-insensitive")
    }

    /// Another site can make a browser on the hotspot fetch the download (an <img>, say), and each
    /// download claims the ready device. Without the token from the page it gets the page (#158).
    func testADownloadWithoutThePagesTokenGetsThePage() {
        XCTAssertEqual(request("GET /Tether.conf HTTP/1.1\r\n\r\n"), .configWithoutToken)
        XCTAssertEqual(request("GET /Tether.conf?t=wrong HTTP/1.1\r\n\r\n"), .configWithoutToken)
        XCTAssertEqual(request("GET /Tether.conf?t=\(ConfigPage.token)x HTTP/1.1\r\n\r\n"), .configWithoutToken)
        XCTAssertEqual(request("HEAD /Tether.conf HTTP/1.1\r\n\r\n"), .pageHead, "no config headers either")
        // Everything a download needs is there, so only the missing token keeps the ready device unclaimed.
        var setup = WireGuardSetup.new()
        setup.prepareReady()
        let handler = ConfigPageHandler()
        let inputs = ConfigPageHandler.Inputs(letIn: true, onScreen: true, ready: setup.ready, host: "172.20.10.1",
                                              config: "[Interface]\n", stale: [], hosts: ["172.20.10.1"], now: Date())
        XCTAssertEqual(handler.answer(.configWithoutToken, from: "172.20.10.3", inputs),
                       .answer(ConfigPage.page(.ready, status: .notFound)), "the page with a 404, not a download")
        XCTAssertTrue(String(decoding: ConfigPage.page(.ready).body, as: UTF8.self).contains("href=\"\(ConfigPage.downloadPath)\""))
        XCTAssertGreaterThanOrEqual(ConfigPage.token.count, 16)
    }

    /// On an IPv6-only carrier the page listens on a global address. Only the hotspot's own /64 and
    /// link-local clients are answered, not the internet (#159). IPv4 on the hotspot is NATed.
    func testOnlyClientsOnTheHotspotAreAnswered() {
        let hosts = ["172.20.10.1", "2607:fb91:88a2:e822::1"]
        XCTAssertTrue(ConfigPage.onHotspot("172.20.10.3", hosts: hosts))
        XCTAssertTrue(ConfigPage.onHotspot("2607:fb91:88a2:e822:1c2d:3e4f:5a6b:7c8d", hosts: hosts))
        XCTAssertTrue(ConfigPage.onHotspot("fe80::1c2d:3e4f:5a6b:7c8d%bridge100", hosts: hosts))
        XCTAssertFalse(ConfigPage.onHotspot("2001:db8::7", hosts: hosts))
        XCTAssertFalse(ConfigPage.onHotspot("2607:fb91:88a2:e823::5", hosts: hosts), "the next /64")
        XCTAssertFalse(ConfigPage.onHotspot("2001:db8::7", hosts: ["172.20.10.1"]), "no IPv6 here at all")
        XCTAssertFalse(ConfigPage.onHotspot("somewhere:80", hosts: hosts), "not an address: refused, not let through")
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
        XCTAssertTrue(ready.contains("href=\"\(ConfigPage.downloadPath)\""))
        XCTAssertTrue(ready.contains("Then import it in the WireGuard app."))
        // Compact: the button comes first, and the steps for each system wait behind a tap.
        let button = try XCTUnwrap(ready.range(of: "Download the config"))
        let steps = try XCTUnwrap(ready.range(of: "<details>"))
        XCTAssertLessThan(button.lowerBound, steps.lowerBound)
        XCTAssertEqual(ready.components(separatedBy: "<p>").count - 1, 2, "the button and one line")
        let open = try html(.openTether)
        XCTAssertFalse(open.contains("Tether.conf"))
        XCTAssertTrue(open.contains("Open Tether on the iPhone"))
        let closed = try html(.openAddDevice)
        XCTAssertFalse(closed.contains("Tether.conf"))
        XCTAssertTrue(closed.contains("open Add a device"))
        let none = try html(.noConfig)
        XCTAssertFalse(none.contains("Tether.conf"))
        XCTAssertTrue(none.contains("can't make a config"))
    }

    /// A config that no longer works is why the device can't connect, so the page says it first.
    func testAConfigThatNoLongerWorksIsSaidFirst() throws {
        func html(_ state: ConfigPage.State, _ stale: ConfigPage.Stale?) throws -> String {
            try XCTUnwrap(String(data: parts(ConfigPage.page(state, stale: stale)).body, encoding: .utf8))
        }
        let device = "This device's config no longer works. Delete its tunnel in WireGuard and add it again."
        let oldKeys = "A device here has an old config. If it's this one, delete its tunnel in WireGuard and add it again."
        let ready = try html(.ready, .thisDevice)
        let line = try XCTUnwrap(ready.range(of: device))
        XCTAssertLessThan(line.lowerBound, try XCTUnwrap(ready.range(of: "Download the config")).lowerBound)
        XCTAssertTrue(try html(.openTether, .oldKeys).contains(oldKeys))
        XCTAssertTrue(try html(.openTether, .oldKeys).contains("Open Tether on the iPhone"))
        for state in [ConfigPage.State.ready, .openTether, .openAddDevice, .noConfig] {
            let plain = try html(state, nil)
            XCTAssertFalse(plain.contains("no longer works") || plain.contains("old config"), "\(state)")
        }
    }

    func testTheAddressLeavesOutPort80() {
        XCTAssertEqual(ConfigPage.url(host: "172.20.10.1", port: 80), "http://172.20.10.1")
        XCTAssertEqual(ConfigPage.url(host: "172.20.10.1", port: 8080), "http://172.20.10.1:8080")
        XCTAssertEqual(ConfigPage.url(host: "2607:fb91::1", port: 80), "http://[2607:fb91::1]")
        XCTAssertEqual(ConfigPage.url(host: "2607:fb91::1", port: 8080), "http://[2607:fb91::1]:8080")
    }
}
