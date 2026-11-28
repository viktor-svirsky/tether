import XCTest
@testable import TetherCore

/// Diagnostics > Copy all (L5): one text for a bug report, with the log's first line on top.
final class DiagnosticsCopyAllTests: XCTestCase {
    func testCopyAllHasTheHeaderThenEachSectionsRows() {
        let d = ServerDiagnostics(listening: ["172.20.10.1:51820"], udpIn: 12, tcpFailed: 1, lastError: "TCP to 1.1.1.1:443: connection refused")
        let text = Diagnostics.all(Diagnostics.sections(d, sharing: true), header: "Tether 1.14.0 (700), iOS 26.5.0, iPhone18,1")
        XCTAssertEqual(text, """
            Tether 1.14.0 (700), iOS 26.5.0, iPhone18,1

            WireGuard port
            Listening on: 172.20.10.1:51820
            UDP in: 12
            Last UDP from: None yet
            Rejected messages: 0
            Replies not sent: 0
            Last send error: None

            Tunnel
            Packets in: 0
            Dropped for their source address: 0

            Out to the internet
            TCP connections tried: 0
            TCP connections failed: 1
            UDP sends failed: 0
            NAT64 prefix: Not needed yet
            Last connection error: TCP to 1.1.1.1:443: connection refused
            """)
    }

    /// The footers explain the screen, so they stay out of the copy, sharing or not.
    func testCopyAllLeavesTheFootersOut() {
        for sharing in [true, false] {
            let sections = Diagnostics.sections(ServerDiagnostics(), sharing: sharing)
            let text = Diagnostics.all(sections, header: "Tether")
            for footer in sections.map(\.footer) where !footer.isEmpty {
                XCTAssertFalse(text.contains(footer), footer)
            }
        }
    }
}
