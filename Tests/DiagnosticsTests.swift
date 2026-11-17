import XCTest
@testable import TetherCore

/// The Diagnostics screen in Settings (#256): what each row says from the server's counters, and the
/// counters reaching it through the session. The counters themselves are Go's, see
/// WireGuard/diagnostics_test.go, and their trip through the C API is in WireGuardServerTests.
@MainActor
final class DiagnosticsTests: XCTestCase {
    private func values(_ d: ServerDiagnostics) -> [String: String] {
        var out: [String: String] = [:]
        for row in Diagnostics.sections(d).flatMap(\.rows) { out[row.id] = row.value }
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
        let sections = Diagnostics.sections(ServerDiagnostics())
        XCTAssertEqual(sections.map(\.title), ["WireGuard port", "Tunnel", "Out to the internet"])
        XCTAssertEqual(sections.flatMap(\.rows).map(\.id), ["listening", "udpIn", "udpFrom", "rejected", "replyFailed", "replyError",
                                                            "packetsIn", "disallowed",
                                                            "tcpTried", "tcpFailed", "udpFailed", "nat64", "lastError"])
        XCTAssertEqual(sections.flatMap(\.rows).filter(\.wide).map(\.id), ["listening", "udpFrom", "replyError", "lastError"])
        XCTAssertTrue(sections[0].footer.contains("Tap a row to copy it."))
    }

    /// The session reads the running server's counters, and a stopped server has none.
    func testTheSessionReadsTheServersCounters() {
        let sharing = DemoState(.sharing).makeSession()
        XCTAssertEqual(sharing.serverDiagnostics.listening, ["172.20.10.1:51820"])
        XCTAssertEqual(sharing.serverDiagnostics.tcpFailed, 1)
        XCTAssertEqual(DemoState(.waiting).makeSession().serverDiagnostics, ServerDiagnostics())
    }
}
