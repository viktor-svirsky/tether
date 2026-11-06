import Foundation
import Network

/// The DNS server a new device's config names, picked in Settings > New devices (#79). A device
/// already added keeps the one in its config: Tether can't change what a device imported. Each preset
/// has a second server, so a device still looks names up when one doesn't answer. Foundation and
/// Network only, so `swift test` covers it.
///
/// Control D (#100) is the user's own profile, where they pick the country sites see. Its plain
/// servers answer only addresses the user authorized, and the iPhone's carrier address changes and
/// is shared, so the config names Tether's own address instead, and Tether asks the profile over
/// HTTPS (WireGuard/dns.go). Once a device names Tether, the setting decides where its lookups go,
/// so it follows a change of the setting at once.
enum DNSChoice: String, CaseIterable {
    case cloudflare
    case cloudflareMalware
    case quad9
    case adGuard
    case controlD
    case other

    static let `default` = DNSChoice.cloudflare
    /// Where it's saved in UserDefaults, and the address typed under Other.
    static let key = "newDevices.dns"
    static let otherKey = "newDevices.dnsOther"
    /// The Control D profile typed, see `controlD(typed:)`.
    static let controlDKey = "newDevices.dnsControlD"
    /// Tether's own address in the tunnel, where it answers lookups: dnsAddr in WireGuard/dns.go.
    static let tetherServer = "10.7.0.1"
    /// The default's servers, for a config when nothing else is usable.
    static let defaultServers = "1.1.1.1, 1.0.0.1"
    /// Where lookups to Tether's own address go when nothing else is given.
    static let defaultUpstream = Upstream.servers(defaultServers.components(separatedBy: ", "))

    /// In the menu, "name (address, what it does)", as signed off in #79 and put in one shape by the design review.
    var label: String {
        switch self {
        case .cloudflare: "Cloudflare (1.1.1.1, no filtering)"
        case .cloudflareMalware: "Cloudflare (1.1.1.2, blocks malware)"
        case .quad9: "Quad9 (9.9.9.9, blocks malware)"
        case .adGuard: "AdGuard (94.140.14.14, blocks ads)"
        case .controlD: "Control D (your profile, over HTTPS)"
        case .other: "Other server"
        }
    }

    /// The config's DNS line for a preset. Other's comes from what was typed, see `servers(typed:)`, and
    /// Control D's is Tether's own address, see `setting(in:)`.
    var servers: String? {
        switch self {
        case .cloudflare: Self.defaultServers
        case .cloudflareMalware: "1.1.1.2, 1.0.0.2"
        case .quad9: "9.9.9.9, 149.112.112.112"
        case .adGuard: "94.140.14.14, 94.140.15.15"
        case .controlD, .other: nil
        }
    }

    static func saved(in defaults: UserDefaults) -> DNSChoice {
        defaults.string(forKey: key).flatMap(DNSChoice.init(rawValue:)) ?? .default
    }

    /// What a new config names and where Tether sends lookups to its own address.
    struct Setting: Equatable {
        /// The config's DNS line.
        let line: String
        let upstream: Upstream

        static let `default` = Setting(line: defaultServers, upstream: defaultUpstream)
    }

    /// Where lookups to Tether's own address go: the profile's DoH URL, or the servers on the line, so
    /// a device set up with Control D keeps resolving once another choice is picked.
    enum Upstream: Equatable {
        case doh(URL)
        case servers([String])
    }

    /// The setting for the next device and the server: Control D's profile when one was typed,
    /// otherwise the servers of `servers(in:)`.
    static func setting(in defaults: UserDefaults) -> Setting {
        if saved(in: defaults) == .controlD, let profile = controlD(typed: defaults.string(forKey: controlDKey) ?? "") {
            return Setting(line: tetherServer, upstream: .doh(profile))
        }
        let line = servers(in: defaults)
        return Setting(line: line, upstream: .servers(line.components(separatedBy: ", ")))
    }

    /// The DNS line for the next device: the saved choice, or Cloudflare's while Other or Control D has
    /// nothing usable typed, so a config never goes out without a DNS server.
    private static func servers(in defaults: UserDefaults) -> String {
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

    /// The profile's DoH URL from the link in Control D's dashboard, `https://dns.controld.com/<id>`,
    /// maybe with a device name after the ID, or from the ID alone. Nil for anything else. The ID's
    /// format isn't published, so letters, digits, `-` and `_` are taken.
    static func controlD(typed: String) -> URL? {
        var path = Substring(typed.trimmingCharacters(in: .whitespaces))
        for prefix in ["https://", "dns.controld.com/"] where path.hasPrefix(prefix) {
            path = path.dropFirst(prefix.count)
        }
        if path.hasSuffix("/") { path = path.dropLast() }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) } })
        else { return nil }
        return URL(string: "https://dns.controld.com/" + parts.joined(separator: "/"))
    }

    /// Four numbers with dots, each up to 255. Network's IPv4Address alone also takes "8.8.8".
    private static func isIPv4(_ text: String) -> Bool {
        text.split(separator: ".", omittingEmptySubsequences: false).count == 4 && IPv4Address(text) != nil
    }
}
