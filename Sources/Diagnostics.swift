import Foundation

/// The Diagnostics screen in Settings (#256): the server's counters, in the order a device's traffic
/// meets them, so the first one that stays at 0 says where it stops. A tap on a row copies its value,
/// and Copy all copies every row for a bug report (L5). Foundation only, so `swift test` covers it. `DiagnosticsView` draws it.
enum Diagnostics {
    struct Row: Equatable, Identifiable {
        /// Its accessibility identifier is "diagnostics.<id>".
        let id: String
        let title: String
        /// What the row shows, and what a tap copies.
        let value: String
        /// A text that can be long goes under its title, not beside it.
        var wide = false
    }

    struct Section: Equatable, Identifiable {
        let id: String
        let title: String
        /// "" for none.
        let footer: String
        let rows: [Row]
    }

    /// Not `sharing`, there's nothing to count: the first footer says so, and the others, which
    /// explain a 0, are left out. The rows stay, so the screen shows what it will count.
    static func sections(_ d: ServerDiagnostics, sharing: Bool) -> [Section] {
        let port = sharing ? "UDP in stays at 0 when nothing from a device reaches this iPhone. Rejected messages often mean a config that no longer works. The counts start again each time sharing starts. Tap a row to copy its value, or Copy all for a bug report."
            : "Tether isn't sharing, so there's nothing to count. Start sharing, then come back."
        let tunnel = sharing ? "Packets in stays at 0 when a device's tunnel sends nothing to Tether. Dropped packets come from an address the device's config doesn't give it, like a router's clients before Tether finds the router." : ""
        let out = sharing ? "The connections this iPhone makes for your devices." : ""
        return [
            Section(id: "port", title: "WireGuard port", footer: port, rows: [
                Row(id: "listening", title: "Listening on", value: d.listening.isEmpty ? "Not listening" : d.listening.joined(separator: ", "), wide: true),
                Row(id: "udpIn", title: "UDP in", value: count(d.udpIn)),
                Row(id: "udpFrom", title: "Last UDP from", value: text(d.udpFrom, none: "None yet"), wide: true),
                Row(id: "rejected", title: "Rejected messages", value: count(d.rejected)),
                Row(id: "replyFailed", title: "Replies not sent", value: count(d.replyFailed)),
                Row(id: "replyError", title: "Last send error", value: text(d.replyError, none: "None"), wide: true),
            ]),
            Section(id: "tunnel", title: "Tunnel", footer: tunnel, rows: [
                Row(id: "packetsIn", title: "Packets in", value: count(d.packetsIn)),
                Row(id: "disallowed", title: "Dropped for their source address", value: count(d.disallowed)),
            ]),
            Section(id: "out", title: "Out to the internet", footer: out, rows: [
                Row(id: "tcpTried", title: "TCP connections tried", value: count(d.tcpTried)),
                Row(id: "tcpFailed", title: "TCP connections failed", value: count(d.tcpFailed)),
                Row(id: "udpFailed", title: "UDP sends failed", value: count(d.udpFailed)),
                Row(id: "nat64", title: "NAT64 prefix", value: text(d.nat64, none: "Not needed yet"), wide: true),
                Row(id: "lastError", title: "Last connection error", value: text(d.lastError, none: "None"), wide: true),
            ]),
        ]
    }

    /// What Copy all copies: `header`, the log's first line (Tether's version, iOS and the iPhone), then
    /// each section's title and its rows as "Title: value". Footers are left out: they explain the
    /// screen, not this iPhone.
    static func all(_ sections: [Section], header: String) -> String {
        ([header] + sections.map { section in
            ([section.title] + section.rows.map { "\($0.title): \($0.value)" }).joined(separator: "\n")
        }).joined(separator: "\n\n")
    }

    private static func count(_ n: UInt64) -> String { n.formatted() }

    private static func text(_ s: String, none: String) -> String { s.isEmpty ? none : s }
}
