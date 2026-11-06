import Foundation
import Network

/// The DNS server a new device's config names, picked in Settings > New devices (#79). A device
/// already added keeps the one in its config: Tether can't change what a device imported. Each preset
/// has a second server, so a device still looks names up when one doesn't answer. Foundation and
/// Network only, so `swift test` covers it.
enum DNSChoice: String, CaseIterable {
    case cloudflare
    case cloudflareMalware
    case quad9
    case adGuard
    case other

    static let `default` = DNSChoice.cloudflare
    /// Where it's saved in UserDefaults, and the address typed under Other.
    static let key = "newDevices.dns"
    static let otherKey = "newDevices.dnsOther"
    /// The default's servers, for a config when nothing else is usable.
    static let defaultServers = "1.1.1.1, 1.0.0.1"

    /// In the menu, "name (address, what it does)", as signed off in #79 and put in one shape by the design review.
    var label: String {
        switch self {
        case .cloudflare: "Cloudflare (1.1.1.1, no filtering)"
        case .cloudflareMalware: "Cloudflare (1.1.1.2, blocks malware)"
        case .quad9: "Quad9 (9.9.9.9, blocks malware)"
        case .adGuard: "AdGuard (94.140.14.14, blocks ads)"
        case .other: "Other server"
        }
    }

    /// The config's DNS line for a preset. Other's comes from what was typed, see `servers(typed:)`.
    var servers: String? {
        switch self {
        case .cloudflare: Self.defaultServers
        case .cloudflareMalware: "1.1.1.2, 1.0.0.2"
        case .quad9: "9.9.9.9, 149.112.112.112"
        case .adGuard: "94.140.14.14, 94.140.15.15"
        case .other: nil
        }
    }

    static func saved(in defaults: UserDefaults) -> DNSChoice {
        defaults.string(forKey: key).flatMap(DNSChoice.init(rawValue:)) ?? .default
    }

    /// The DNS line for the next device: the saved choice, or Cloudflare's while Other has no usable
    /// address, so a config never goes out without a DNS server.
    static func servers(in defaults: UserDefaults) -> String {
        let choice = saved(in: defaults)
        let typed = choice == .other ? servers(typed: defaults.string(forKey: otherKey) ?? "") : choice.servers
        return typed ?? defaultServers
    }

    /// One or two IPv4 addresses, apart by a comma or a space, as a DNS line. Nil for anything else.
    /// IPv6 can't work: a device's tunnel address is IPv4 only, and so is the UDP the server forwards.
    /// And WireGuard reads a word on the DNS line as a search domain, leaving no DNS server at all.
    static func servers(typed: String) -> String? {
        let parts = typed.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy(isIPv4) else { return nil }
        return parts.joined(separator: ", ")
    }

    /// Four numbers with dots, each up to 255. Network's IPv4Address alone also takes "8.8.8".
    private static func isIPv4(_ text: String) -> Bool {
        text.split(separator: ".", omittingEmptySubsequences: false).count == 4 && IPv4Address(text) != nil
    }
}
