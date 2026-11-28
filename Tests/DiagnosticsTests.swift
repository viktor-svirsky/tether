import XCTest
@testable import TetherCore

/// The Diagnostics screen in Settings (#256): what each row says from the server's counters, and the
/// counters reaching it through the session. The counters themselves are Go's, see
/// WireGuard/diagnostics_test.go, and their trip through the C API is in WireGuardServerTests.
@MainActor
final class DiagnosticsTests: XCTestCase {
    private func values(_ d: ServerDiagnostics, sharing: Bool = true) -> [String: String] {
        var out: [String: String] = [:]
        for row in Diagnostics.sections(d, sharing: sharing).flatMap(\.rows) { out[row.id] = row.value }
        return out
    }

    /// Before anything came in, each row says so in words, and a count says 0.
    func testAServerThatCountedNothing() {
        XCTAssertEqual(values(ServerDiagnostics()), [
            "listening": "Not listening", "udpIn": "0", "udpFrom": "None yet", "rejected": "0", "replyFailed": "0",
            "replyError": "None", "packetsIn": "0", "disallowed": "0", "tcpTried": "0", "tcpFailed": "0", "udpFailed": "0",
            "nat64": "Not needed yet", "lastError": "None",
        ])
    }

    /// Not sharing, there's nothing to count, and the first footer says so instead of blaming a
    /// device. The rows stay, so the screen shows what it will count. The other footers explain a 0,
    /// which says nothing then, so they go.
    func testNotSharingSaysSoInsteadOfBlamingADevice() {
        let sections = Diagnostics.sections(ServerDiagnostics(), sharing: false)
        XCTAssertEqual(sections[0].footer, "Tether isn't sharing, so there's nothing to count. Start sharing, then come back.")
        XCTAssertEqual(sections.dropFirst().map(\.footer), ["", ""])
        XCTAssertEqual(sections.flatMap(\.rows).count, 13)
    }

    func testEachCounterHasItsRow() {
        let d = ServerDiagnostics(listening: ["172.20.10.1:51820", "[2001:db8::1]:51820"], udpIn: 12, udpFrom: "172.20.10.2:52345",
                                  rejected: 3, replyFailed: 4, replyError: "to 172.20.10.2:52345: sendto: no route to host",
                                  packetsIn: 1_250, disallowed: 5, tcpTried: 6, tcpFailed: 7, udpFailed: 8, nat64: "64:ff9b::/96",
                                  lastError: "TCP to 1.1.1.1:443: connection refused")
        XCTAssertEqual(values(d), [
            "listening": "172.20.10.1:51820, [2001:db8::1]:51820", "udpIn": "12", "udpFrom": "172.20.10.2:52345", "rejected": "3",
            "replyFailed": "4", "replyError": "to 172.20.10.2:52345: sendto: no route to host", "packetsIn": UInt64(1_250).formatted(),
            "disallowed": "5", "tcpTried": "6", "tcpFailed": "7", "udpFailed": "8", "nat64": "64:ff9b::/96",
            "lastError": "TCP to 1.1.1.1:443: connection refused",
        ])
    }

    /// In the order a device's traffic meets them: the port, the tunnel, then the iPhone's way out.
    /// Texts that can be long go under their titles.
    func testTheRowsFollowTheTraffic() {
        let sections = Diagnostics.sections(ServerDiagnostics(), sharing: true)
        XCTAssertEqual(sections.map(\.title), ["WireGuard port", "Tunnel", "Out to the internet"])
        XCTAssertEqual(sections.flatMap(\.rows).map(\.id), ["listening", "udpIn", "udpFrom", "rejected", "replyFailed", "replyError",
                                                            "packetsIn", "disallowed",
                                                            "tcpTried", "tcpFailed", "udpFailed", "nat64", "lastError"])
        XCTAssertEqual(sections.flatMap(\.rows).filter(\.wide).map(\.id), ["listening", "udpFrom", "replyError", "nat64", "lastError"])
        let titles = Dictionary(uniqueKeysWithValues: sections.flatMap(\.rows).map { ($0.id, $0.title) })
        XCTAssertEqual(titles["tcpTried"], "TCP connections tried", "it counts the failed ones too")
        XCTAssertEqual(titles["lastError"], "Last connection error")
        // What a reset and a tap do is said once, up top.
        XCTAssertTrue(sections[0].footer.hasSuffix("The counts start again each time sharing starts. Tap a row to copy its value, or Copy all for a bug report."), sections[0].footer)
        XCTAssertFalse(sections[2].footer.contains("start again"))
    }

    /// The session reads the running server's counters, and a stopped server has none.
    func testTheSessionReadsTheServersCounters() {
        let sharing = DemoState(.sharing).makeSession()
        XCTAssertEqual(sharing.serverDiagnostics.listening, ["172.20.10.1:51820"])
        XCTAssertEqual(sharing.serverDiagnostics.tcpFailed, 1)
        XCTAssertEqual(DemoState(.waiting).makeSession().serverDiagnostics, ServerDiagnostics())
        // Sharing with no device yet: listening, and nothing counted.
        XCTAssertEqual(DemoState(.noDevices).makeSession().serverDiagnostics, ServerDiagnostics(listening: ["172.20.10.1:51820"]))
    }
}
