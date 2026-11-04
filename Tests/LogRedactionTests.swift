import XCTest
@testable import TetherCore

/// What leaves Tether in a shared log: no WireGuard keys and no full addresses, checked on the
/// lines Tether really writes (HotspotSession's, Model's and the Go server's).
final class LogRedactionTests: XCTestCase {
    private func redact(_ line: String) -> String { LogRedaction.redact(line) }

    // A real-looking key pair, as WireGuard prints them: 32 bytes, 44 base64 characters.
    private let privateKey = "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
    private let publicKey = "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg="

    func testWireGuardKeysAreLeftOut() {
        XCTAssertEqual(redact("PrivateKey = \(privateKey)"), "PrivateKey = [key]")
        XCTAssertEqual(redact("PublicKey=\(publicKey), Endpoint = 172.20.10.1:51820"), "PublicKey=[key], Endpoint = 172.20.10.1:51820")
        XCTAssertEqual(redact("two: \(privateKey) \(publicKey)"), "two: [key] [key]")
        XCTAssertEqual(redact("in a URL ?k=\(publicKey)&x=1"), "in a URL ?k=[key]&x=1")
    }

    /// The UAPI wireguard-go reads takes keys in hex.
    func testHexKeysAreLeftOut() {
        let hex = "c8a9f3e5317e959589b5ed78b638b7ce530dabe85ddab6142202418019df066e"
        XCTAssertEqual(redact("private_key=\(hex)\nlisten_port=51820"), "private_key=[key] listen_port=51820")
        XCTAssertEqual(redact("public_key=\(hex.uppercased())"), "public_key=[key]")
    }

    func testFullIPv6AddressesKeepOnlyTheirStart() {
        // HotspotSession: the hotspot address on a carrier that gives the iPhone IPv6 only.
        XCTAssertEqual(redact("binding to 2607:fb91:8a1c:3e40:1d2b:9f3e:44a1:7c02"), "binding to 2607:fb91:…")
        // The same, with the port after it and no brackets.
        XCTAssertEqual(redact("WireGuard on 2607:fb91:8a1c:3e40::1:51820, 2 devices"), "WireGuard on 2607:fb91:…:51820, 2 devices")
        XCTAssertEqual(redact("WireGuard on 2607:fb91:8a1c:3e40:1d2b:9f3e:44a1:7c02:51820, 1 devices"), "WireGuard on 2607:fb91:…:51820, 1 devices")
        // The Go server: where a device's handshake came from, in brackets.
        XCTAssertEqual(redact("go: Received invalid initiation message from [2607:fb91:8a1c:3e40:a1b2:c3d4:e5f6:1234]:51820"),
                       "go: Received invalid initiation message from [2607:fb91:…]:51820")
        XCTAssertEqual(redact("WireGuard: 2607:FB91:8A1C:3E40::99 downloaded the config from the page"),
                       "WireGuard: 2607:fb91:… downloaded the config from the page")
        XCTAssertEqual(redact("WireGuard not started: listen udp6 [2607:fb91:8a1c::1]:51820: bind: can't assign requested address"),
                       "WireGuard not started: listen udp6 [2607:fb91:…]:51820: bind: can't assign requested address")
        // NAT64, link-local with its interface, and two in one line.
        XCTAssertEqual(redact("dial tcp [64:ff9b::5db8:d822]:443: i/o timeout"), "dial tcp [64:ff9b:…]:443: i/o timeout")
        XCTAssertEqual(redact("fe80::1c2d:3e4f:5a6b:7c8d%en2"), "fe80:0:…%en2")
        XCTAssertEqual(redact("2001:db8::1 then 2607:fb91::2."), "2001:db8:… then 2607:fb91:….")
    }

    /// An address glued to a word, or cut short, still doesn't get through whole.
    func testAnAddressNextToOtherTextIsStillFound() {
        XCTAssertFalse(redact("address:2607:fb91:8a1c:3e40::1").contains("3e40"))
        XCTAssertFalse(redact("abc2607:fb91:8a1c:3e40::1").contains("3e40"))
        XCTAssertFalse(redact("::ffff:93.184.216.34").contains("216.34"))
    }

    func testWhatIsntSecretStays() {
        for line in [
            "binding to 172.20.10.1",
            "WireGuard on 172.20.10.1:51820, 2 devices",
            "WireGuard: 172.20.10.3 downloaded the config from the page",
            "go: device 10.7.0.2 - Received handshake initiation",
            "go: Received invalid initiation message from 172.20.10.3:58211",
            "notice: iPad connected",
            "Local Network access: denied",
            "WireGuard: Keychain error -25308",
            "Tether 1.6.0 (123) launched",
            "at 10:12:33 and 23:59:59.120",
            "a4:83:e7:12:34:56", // not an address
            "loopback ::1 and ::",
            "CGNAT 100.72.13.5, home 192.168.1.20, docs 198.51.100.7, any 0.0.0.0, local 127.0.0.1, link 169.254.3.4",
            "a short base64 aGVsbG8=", // not 32 bytes
        ] {
            XCTAssertEqual(redact(line), line)
        }
    }

    /// The iPhone's or a website's public IPv4 address shows only its first half.
    func testPublicIPv4AddressesKeepOnlyTheirStart() {
        XCTAssertEqual(redact("dial tcp 93.184.216.34:443: i/o timeout"), "dial tcp 93.184.…:443: i/o timeout")
        XCTAssertEqual(redact("from 8.8.8.8"), "from 8.8.…")
        XCTAssertEqual(redact("172.32.0.1 is public, 172.31.0.1 isn't"), "172.32.… is public, 172.31.0.1 isn't")
        XCTAssertEqual(redact("not an address 300.1.2.3"), "not an address 300.1.2.3")
    }

    func testALineStaysOneLine() {
        XCTAssertEqual(redact("config page: failed\nsecond line\r\nthird"), "config page: failed second line third")
    }

    /// A long line is cut after the redaction, so a cut never leaves half a key that no longer looks like one.
    func testALongLineIsCutAfterTheKeysAreOut() {
        let line = String(repeating: "x", count: LogRedaction.lineLimit - 10) + " " + privateKey + " " + String(repeating: "y", count: 50)
        let redacted = redact(line)
        XCTAssertEqual(redacted.count, LogRedaction.lineLimit)
        XCTAssertTrue(redacted.hasSuffix("…"))
        XCTAssertFalse(redacted.contains(String(privateKey.prefix(10))), redacted)
        XCTAssertEqual(redact(String(repeating: "y", count: LogRedaction.lineLimit)).count, LogRedaction.lineLimit, "a line at the limit stays whole")
    }
}
