import Foundation

/// What a line of the shared log leaves out, so the file can go into a public bug report: WireGuard
/// keys (base64, and hex as wireguard-go's UAPI takes them) become "[key]", an IPv6 address keeps only
/// its first two groups, like 2607:fb91:…, and a public IPv4 address only its first two numbers. The
/// iPhone's hotspot, tunnel and other private addresses stay, since they say nothing about who it is.
/// Foundation only.
enum LogRedaction {
    /// The longest line kept, in characters. A longer one is cut after the redaction, so a cut never
    /// leaves half a key that no longer looks like one.
    static let lineLimit = 500

    static func redact(_ line: String) -> String {
        var s = line.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        s = replace(base64Key, in: s) { _ in "[key]" }
        s = replace(hexKey, in: s) { _ in "[key]" }
        s = replace(ipv6Run, in: s, with: shortenIPv6)
        s = replace(ipv4, in: s, with: shortenIPv4)
        if s.count > lineLimit { s = String(s.prefix(lineLimit - 1)) + "…" }
        return s
    }

    // 32 bytes in base64 are 43 characters and a "=".
    private static let base64Key = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/=])")
    private static let hexKey = try! NSRegularExpression(pattern: "(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])")
    /// Hex digits, colons and dots, with two colons at least: where an IPv6 address may be.
    private static let ipv6Run = try! NSRegularExpression(pattern: "[0-9A-Fa-f:.]*:[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*")
    private static let ipv4 = try! NSRegularExpression(pattern: "(?<![0-9.])(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})(?![0-9])")

    private static func replace(_ regex: NSRegularExpression, in s: String, with change: (String) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var at = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: match.range.location - at))
            out += change(ns.substring(with: match.range))
            at = match.range.location + match.range.length
        }
        return out + ns.substring(from: at)
    }

    /// The longest IPv6 address in the run keeps its first two groups. Trying each start and end finds one with a port after it ("2607:fb91::1:51820") or a word
    /// before it. A port of up to four digits can't be told from the address's last group, and is cut
    /// with it: that hides more, never less. Loopback and the unspecified address stay.
    private static func shortenIPv6(_ run: String) -> String {
        let chars = Array(run)
        // An address starts or ends at a colon (both sides, for "::"), or at a dot, like a sentence's.
        let colons = chars.indices.filter { chars[$0] == ":" }
        let dots = chars.indices.filter { chars[$0] == "." }
        let starts = [0] + colons.flatMap { [$0, $0 + 1] } + dots.map { $0 + 1 }
        let ends = [chars.count] + colons.flatMap { [$0, $0 + 1] } + dots
        var best: (start: Int, end: Int, groups: [UInt16])?
        for start in Set(starts) where start < chars.count {
            for end in Set(ends) where end > start {
                if let best, best.end - best.start >= end - start { continue }
                if let groups = ipv6(String(chars[start..<end])) { best = (start, end, groups) }
            }
        }
        guard let best else { return run }
        let address = String(chars[best.start..<best.end])
        if address == "::1" || address == "::" { return run }
        let short = "\(String(best.groups[0], radix: 16)):\(String(best.groups[1], radix: 16)):…"
        return String(chars[..<best.start]) + short + String(chars[best.end...])
    }

    /// The eight groups of an IPv6 address, nil for anything else.
    private static func ipv6(_ text: String) -> [UInt16]? {
        guard text.filter({ $0 == ":" }).count >= 2 else { return nil }
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { bytes in
            stride(from: 0, to: 16, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
        }
    }

    private static func shortenIPv4(_ text: String) -> String {
        let n = text.split(separator: ".").compactMap { Int($0) }
        guard n.count == 4, n.allSatisfy({ $0 <= 255 }), isPublic(n) else { return text }
        return "\(n[0]).\(n[1]).…"
    }

    /// Not private (10/8, 172.16/12, 192.168/16), the carrier's shared range (100.64/10), loopback,
    /// link-local, "this network" (0/8), multicast and above, or a documentation range.
    private static func isPublic(_ n: [Int]) -> Bool {
        switch (n[0], n[1], n[2]) {
        case (0, _, _), (10, _, _), (127, _, _), (224..., _, _): false
        case (100, 64...127, _), (169, 254, _), (172, 16...31, _), (192, 168, _): false
        case (192, 0, 2), (198, 51, 100), (203, 0, 113): false
        default: true
        }
    }
}
