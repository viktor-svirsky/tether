import Foundation

/// The page on the hotspot that gives the next device its config, for a device that can't scan the
/// QR code: a laptop opens http://172.20.10.1 and downloads it. ConfigPageServer.swift listens,
/// HotspotSession decides what it hands out. Foundation only, so `swift test` covers it.
enum ConfigPage {
    /// 80, so the address is only the IP. The rule against listening below 1024 is macOS's, iOS
    /// never had it.
    static let port: UInt16 = 80
    static let configPath = "/Tether.conf"

    /// The address to type, without the port when it's 80.
    static func url(host: String, port: UInt16 = port) -> String {
        port == 80 ? "http://\(host)" : "http://\(host):\(port)"
    }

    /// A request's head ends with an empty line.
    static func headComplete(_ head: Data) -> Bool {
        head.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    /// What a browser asks for. Only the request line counts: the headers are read and ignored.
    /// A HEAD asks for the same as a GET, without the body. Download managers send one first.
    enum Request: Equatable {
        case page, config, pageHead, configHead, notFound, notGet, malformed

        init(_ head: Data) {
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
            let head = parts[0] == "HEAD"
            switch parts[1].prefix(while: { $0 != "?" && $0 != "#" }) {
            case "/": self = head ? .pageHead : .page
            case Substring(ConfigPage.configPath): self = head ? .configHead : .config
            default: self = .notFound
            }
        }
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
        /// On screen, but there's no config for a new device: Tether's screen says why.
        case noConfig
    }

    static func page(_ state: State, status: Status = .ok) -> Response {
        Response(status: status, contentType: "text/html; charset=utf-8", body: Data(html(state).utf8))
    }

    private static func html(_ state: State) -> String {
        let content = switch state {
        case .ready:
            """
            <p><a class="button" href="\(configPath)">Download the config</a></p>
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
        case .noConfig:
            """
            <p>Tether can't make a config for a new device right now. Tether's screen on the iPhone says why.</p>
            """
        }
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
        .button { display: block; text-align: center; text-decoration: none; font-weight: 600; padding: 14px; border-radius: 12px; background: var(--accent); color: var(--on-accent); }
        </style>
        </head>
        <body>
        <main>
        <h1>Connect to Tether</h1>
        \(content)
        </main>
        </body>
        </html>

        """
    }
}
