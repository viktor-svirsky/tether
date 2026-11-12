import Foundation

/// The page on the hotspot that gives the next device its config, for a device that can't scan the
/// QR code: a laptop opens http://172.20.10.1, or the iPhone's IPv6 address on an IPv6-only hotspot
/// (see `Interfaces.hotspotAddress`), and downloads it. ConfigPageServer.swift listens,
/// HotspotSession decides what it hands out. Foundation only, so `swift test` covers it.
enum ConfigPage {
    /// 80, so the address is only the IP. The rule against listening below 1024 is macOS's, iOS
    /// never had it.
    static let port: UInt16 = 80
    static let configPath = "/Tether.conf"
    /// In the page's download link, and a download without it gets the page: each download claims
    /// the ready device, and another site can make a browser on the hotspot fetch a URL it knows, but
    /// can't read the page for this (#158). New with each launch, like the page's code window.
    static let token = (0..<16).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
    static var downloadPath: String { "\(configPath)?t=\(token)" }

    /// The address to type, without the port when it's 80.
    static func url(host: String, port: UInt16 = port) -> String {
        let host = host.contains(":") ? "[\(host)]" : host
        return port == 80 ? "http://\(host)" : "http://\(host):\(port)"
    }

    /// A request's head ends with an empty line.
    static func headComplete(_ head: Data) -> Bool {
        head.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    /// What a browser asks for, from the request line. Of the headers only Host counts: one that isn't
    /// an address of Tether's is a page on another site that pointed its own name at the iPhone (DNS
    /// rebinding), and gets a 400, so its script can't read a config (#158). A HEAD asks for the same
    /// as a GET, without the body. Download managers send one first.
    enum Request: Equatable {
        case page, config, pageHead, configHead, notFound, notGet, malformed

        /// `hosts`: where the page listens, see `HotspotSession.boundHosts`.
        init(_ head: Data, hosts: [String]) {
            guard let text = String(data: head, encoding: .utf8), let end = text.range(of: "\r\n") else {
                self = .malformed
                return
            }
            let parts = text[..<end.lowerBound].split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[1].hasPrefix("/"), parts[2].hasPrefix("HTTP/1.") else {
                self = .malformed
                return
            }
            guard parts[0] == "GET" || parts[0] == "HEAD" else {
                self = .notGet
                return
            }
            let lines = text[end.upperBound...].components(separatedBy: "\r\n")
            let host = lines.first { $0.lowercased().hasPrefix("host:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            if let host, !hosts.contains(where: { ConfigPage.sameAddress(ConfigPage.address(inHost: host), $0) }) {
                self = .malformed
                return
            }
            let head = parts[0] == "HEAD"
            let target = parts[1]
            switch target.prefix(while: { $0 != "?" && $0 != "#" }) {
            case "/": self = head ? .pageHead : .page
            case Substring(ConfigPage.configPath):
                let query = target.drop { $0 != "?" }.dropFirst().prefix { $0 != "#" }
                let tokened = query.split(separator: "&").contains { $0 == "t=\(ConfigPage.token)" }
                self = head ? .configHead : tokened ? .config : .page
            default: self = .notFound
            }
        }
    }

    /// The address in a Host header: without the port, and an IPv6 one without its brackets.
    static func address(inHost host: String) -> String {
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            return String(host[host.index(after: host.startIndex)..<close])
        }
        return host.split(separator: ":", omittingEmptySubsequences: false).count == 2
            ? String(host.prefix { $0 != ":" }) : host
    }

    /// The same IP address, however it's written.
    static func sameAddress(_ a: String, _ b: String) -> Bool {
        if let a = ipv6(a), let b = ipv6(b) { return a == b }
        return !a.isEmpty && a == b
    }

    /// Whether a client is on the hotspot. On an IPv6-only carrier the page listens on the iPhone's
    /// global address, which the internet may reach if the carrier lets it in, so an IPv6 client must
    /// be link-local or in that address's /64, the hotspot's (#159). An IPv4 one is on the hotspot or
    /// behind its NAT, which nobody outside gets through.
    static func onHotspot(_ client: String, hosts: [String]) -> Bool {
        guard let address = ipv6(client) else { return true }
        if address[0] == 0xfe && address[1] & 0xc0 == 0x80 { return true } // fe80::/10
        return hosts.compactMap(ipv6).contains { $0.prefix(8) == address.prefix(8) }
    }

    /// The 16 bytes of an IPv6 address, without a zone (%bridge100). Nil for anything else.
    private static func ipv6(_ text: String) -> [UInt8]? {
        let plain = text.prefix { $0 != "%" }
        var address = in6_addr()
        guard plain.contains(":"), inet_pton(AF_INET6, String(plain), &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    enum Status: Equatable {
        case ok, badRequest, notFound, notGet, unavailable

        var line: String {
            switch self {
            case .ok: "200 OK"
            case .badRequest: "400 Bad Request"
            case .notFound: "404 Not Found"
            case .notGet: "405 Method Not Allowed"
            case .unavailable: "503 Service Unavailable"
            }
        }
    }

    struct Response: Equatable {
        var status: Status
        var contentType: String
        var extraHeaders: [String] = []
        var body: Data
        /// The answer to a HEAD: the GET's headers, Content-Length included, and no body.
        var headOnly = false

        /// Every answer closes the connection, is never cached (the config holds a private key),
        /// is never sniffed into another type, and runs no scripts.
        var bytes: Data {
            let head = ["HTTP/1.1 \(status.line)",
                        "Content-Type: \(contentType)",
                        "Content-Length: \(body.count)",
                        "Cache-Control: no-store",
                        "X-Content-Type-Options: nosniff",
                        "Referrer-Policy: no-referrer",
                        "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
                        "Connection: close"] + extraHeaders
            return Data((head.joined(separator: "\r\n") + "\r\n\r\n").utf8) + (headOnly ? Data() : body)
        }

        /// This answer without its body, for a HEAD.
        var forHead: Response {
            var head = self
            head.headOnly = true
            return head
        }
    }

    static let notFound = text(.notFound, "Not found.")
    static let notGet = Response(status: .notGet, contentType: "text/plain; charset=utf-8", extraHeaders: ["Allow: GET, HEAD"],
                                 body: Data("Only GET and HEAD.\n".utf8))
    static let malformed = text(.badRequest, "Bad request.")

    private static func text(_ status: Status, _ text: String) -> Response {
        Response(status: status, contentType: "text/plain; charset=utf-8", body: Data((text + "\n").utf8))
    }

    /// The config as a file to save, not a page to show. Nothing is registered for WireGuard's
    /// .conf, so a browser saves it and the device's WireGuard imports it from there.
    static func config(_ text: String, fileName: String) -> Response {
        Response(status: .ok, contentType: "application/octet-stream",
                 extraHeaders: ["Content-Disposition: attachment; filename=\"\(fileName)\""], body: Data(text.utf8))
    }

    /// What the page says.
    enum State {
        /// It links the config.
        case ready
        /// Tether isn't on screen, so it hands nothing out.
        case openTether
        /// Add a device isn't open on the iPhone, and didn't close in the last 10 minutes, see
        /// `AddWindow`.
        case openAddDevice
        /// On screen, but there's no config for a new device: Tether's screen says why.
        case noConfig
    }

    /// A config that no longer works knocked in the last minute (#63), said before the rest: it's
    /// why the device can't connect. Only these two can be told. Whether a tunnel works can't: a
    /// request through one comes from the iPhone, whichever device sent it.
    enum Stale: Equatable {
        /// A device key the server doesn't let in, from the address that asks.
        case thisDevice
        /// A config for other server keys, from somewhere: wireguard-go doesn't say where.
        case oldKeys

        var line: String {
            switch self {
            case .thisDevice: "This device's config no longer works. Delete its tunnel in WireGuard and add it again."
            case .oldKeys: "A device here has an old config. If it's this one, delete its tunnel in WireGuard and add it again."
            }
        }
    }

    static func page(_ state: State, stale: Stale? = nil, status: Status = .ok) -> Response {
        Response(status: status, contentType: "text/html; charset=utf-8", body: Data(html(state, stale).utf8))
    }

    private static func html(_ state: State, _ stale: Stale?) -> String {
        let content = switch state {
        case .ready:
            """
            <p><a class="button" href="\(downloadPath)">Download the config</a></p>
            <p>Then import it in the WireGuard app.</p>
            <details>
            <summary>How, on Mac, Windows, Linux or a phone</summary>
            <ul>
            <li>Mac: get WireGuard from the App Store, then Import Tunnel(s) from File.</li>
            <li>Windows: get WireGuard from wireguard.com/install, then Import tunnel(s) from file.</li>
            <li>iPhone, iPad or Android: in the WireGuard app, tap + and import the file.</li>
            <li>Linux: <code>sudo wg-quick up</code> and the file's path.</li>
            <li>Each config is for one device. For another device, open this page on it.</li>
            </ul>
            </details>
            """
        case .openTether:
            """
            <p>Open Tether on the iPhone and keep it on screen, then reload this page.</p>
            """
        case .openAddDevice:
            """
            <p>In Tether on the iPhone, open Add a device, then reload this page.</p>
            """
        case .noConfig:
            """
            <p>Tether can't make a config for a new device right now. Tether's screen on the iPhone says why.</p>
            """
        }
        let notice = stale.map { "<p class=\"stale\">\($0.line)</p>\n" } ?? ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Tether</title>
        <style>
        :root { color-scheme: light dark; --bg: #f2f2f7; --card: #fff; --text: #1c1c1e; --muted: #6c6c70; --accent: #0073c7; --on-accent: #fff; }
        @media (prefers-color-scheme: dark) { :root { --bg: #000; --card: #1c1c1e; --text: #f2f2f7; --muted: #98989f; --accent: #4db3ff; --on-accent: #0b1a26; } }
        body { margin: 0; background: var(--bg); color: var(--text); font: 17px/1.45 -apple-system, "Segoe UI", Roboto, sans-serif; }
        main { max-width: 520px; margin: 0 auto; padding: 24px 16px; }
        h1 { font-size: 28px; margin: 0 0 16px; }
        p, li, summary { color: var(--muted); }
        summary { cursor: pointer; }
        ul { padding-left: 20px; margin: 8px 0 0; }
        code { font: 15px ui-monospace, Menlo, Consolas, monospace; }
        .stale { color: var(--text); font-weight: 600; }
        .button { display: block; text-align: center; text-decoration: none; font-weight: 600; padding: 14px; border-radius: 12px; background: var(--accent); color: var(--on-accent); }
        </style>
        </head>
        <body>
        <main>
        <h1>Connect to Tether</h1>
        \(notice)\(content)
        </main>
        </body>
        </html>

        """
    }
}
