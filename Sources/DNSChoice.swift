import Foundation
import Network

/// Where Tether sends a device's lookups, picked in Settings > Devices (#79). Every config names
/// Tether's own address, 10.7.0.1, as its DNS server, and Tether asks the server picked at that moment
/// (WireGuard/dns.go), so a change reaches every device at once (#121). A device added before keeps the
/// server its config names: Tether can't change what a device imported. Each preset has a second
/// server, so a lookup the first drops is asked of the second. Foundation and Network only, so
/// `swift test` covers it.
///
/// Control D (#100) is the user's own profile, where they pick the country sites see. Its plain servers
/// answer only addresses the user authorized, and the iPhone's carrier address changes and is shared,
/// so Tether asks the profile over HTTPS.
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
    /// Tether's own address in the tunnel, the DNS server every config names: dnsAddr in WireGuard/dns.go.
    static let tetherServer = "10.7.0.1"
    /// The default's servers, for when nothing else is usable.
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

    /// A preset's servers. Other's come from what was typed, see `servers(typed:)`, and Control D asks
    /// over HTTPS, see `upstream(in:)`.
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

    /// Where Tether sends lookups to its own address: the profile's DoH URL, or servers.
    enum Upstream: Equatable {
        case doh(URL)
        case servers([String])
    }

    /// Where lookups go now: Control D's profile when one was typed, otherwise the servers of the saved
    /// choice, or Cloudflare's while Other or Control D has nothing usable typed, so lookups never go
    /// nowhere.
    static func upstream(in defaults: UserDefaults) -> Upstream {
        let choice = saved(in: defaults)
        if choice == .controlD, let profile = controlD(typed: defaults.string(forKey: controlDKey) ?? "") {
            return .doh(profile)
        }
        let typed = choice == .other ? servers(typed: defaults.string(forKey: otherKey) ?? "") : choice.servers
        return .servers((typed ?? defaultServers).components(separatedBy: ", "))
    }

    /// One or two IPv4 addresses, apart by a comma or a space, as "a, b". Nil for anything else. IPv6
    /// can't work: the UDP the server forwards to them is IPv4 only. An address the server never
    /// forwards to is refused too (forwardable in WireGuard/server.go), or the server wouldn't start.
    static func servers(typed: String) -> String? {
        let parts = typed.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy({ isIPv4($0) && isForwardable($0) }) else { return nil }
        return parts.joined(separator: ", ")
    }

    /// Not the iPhone itself (127/8, 0.0.0.0), the tunnel (10.7.0.0/24), link-local (169.254/16),
    /// multicast (224/4) or broadcast.
    private static func isForwardable(_ text: String) -> Bool {
        guard let bytes = IPv4Address(text)?.rawValue, bytes.count == 4 else { return false }
        let b = [UInt8](bytes)
        return b[0] != 127 && b != [0, 0, 0, 0] && !(b[0] == 10 && b[1] == 7 && b[2] == 0)
            && !(b[0] == 169 && b[1] == 254) && b[0] < 224
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
