import Foundation

enum Interfaces {
    /// Where devices on the hotspot reach the iPhone. iOS Personal Hotspot gives the phone
    /// 172.20.10.1 on a bridge interface, and matching the subnet, not only the name, keeps other
    /// bridges out. But when the carrier gives the iPhone IPv6 only (T-Mobile US among others), a Mac
    /// on the hotspot takes no IPv4 (it asks for IPv6 only and makes up 192.0.0.2 for itself) and
    /// can't reach 172.20.10.1. Then it's the iPhone's IPv6 address on the same bridge, and the session
    /// listens on 172.20.10.1 too, for a Windows PC, which does take IPv4 (#98). A CLAT's address in
    /// 192.0.0.0/29 is no IPv4 from the carrier, and nor is IPv4 on another cellular interface than
    /// pdp_ip0, the internet's: VoLTE often has its own, with IPv4 on an IPv6-only carrier.
    /// The bridge may have more than one IPv6 address, some of them temporary ones that come and go.
    /// `current` is kept while the bridge has it, since a new address restarts the server and makes
    /// the devices' configs point at the wrong place. `HotspotAddressKeeper` keeps it across launches.
    /// `interfaces` are lines like "bridge100: 172.20.10.1", from `addresses()`.
    static func hotspotAddress(in interfaces: [String], keeping current: String? = nil) -> String? {
        let lines = parse(interfaces)
        guard let bridge = lines.first(where: { $0.name.hasPrefix("bridge") && $0.address.hasPrefix("172.20.10.") }) else {
            return nil
        }
        if carrierIPv4(lines) { return bridge.address }
        // A link-local address comes with its interface after a %, which only the iPhone knows.
        let ipv6 = lines.filter { $0.name == bridge.name && $0.address.contains(":") && !$0.address.contains("%") }.map(\.address)
        if let current, ipv6.contains(current) { return current }
        return ipv6.first ?? bridge.address
    }

    @MainActor static func carrierIPv6Only() -> Bool {
        carrierIPv6Only(in: addresses())
    }

    /// The carrier gives this iPhone IPv6 and no IPv4, so a Mac, an iPhone or an iPad on the hotspot
    /// will take no IPv4 either. Unlike `hotspotAddress`, this is known before a device joins and the
    /// bridge appears.
    /// It takes pdp_ip0 with IPv6 to say so: no cellular at all, or Wi-Fi only, isn't IPv6 only.
    static func carrierIPv6Only(in interfaces: [String]) -> Bool {
        let lines = parse(interfaces)
        let ipv6 = lines.contains { $0.name == "pdp_ip0" && $0.address.contains(":") && !$0.address.contains("%") }
        return ipv6 && !carrierIPv4(lines)
    }

    private static func parse(_ interfaces: [String]) -> [(name: String, address: String)] {
        interfaces.compactMap { line in
            let parts = line.components(separatedBy: ": ")
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    private static func carrierIPv4(_ lines: [(name: String, address: String)]) -> Bool {
        lines.contains { $0.name == "pdp_ip0" && !$0.address.contains(":") && !isCLAT($0.address) }
    }

    /// What pdp_ip0, the cellular data's interface, has, for the log: "pdp_ip0: IPv6", say, or
    /// "pdp_ip0: no address". Never the address itself.
    static func pdpIp0(in interfaces: [String]) -> String {
        let lines = parse(interfaces).filter { $0.name == "pdp_ip0" && !$0.address.contains("%") }
        let has = [carrierIPv4(lines) ? "IPv4" : nil, lines.contains { $0.address.contains(":") } ? "IPv6" : nil].compactMap { $0 }
        return "pdp_ip0: " + (has.isEmpty ? "no address" : has.joined(separator: " and "))
    }

    private static func isCLAT(_ address: String) -> Bool {
        guard address.hasPrefix("192.0.0."), let last = Int(address.dropFirst("192.0.0.".count)) else { return false }
        return last < 8
    }

    /// The interface the internet goes out through when it's a VPN's (utun or ipsec), nil when it's
    /// cellular, Wi-Fi or nothing: the one holding the local address iOS picks for each of
    /// `internetProbes`. All of them have to go through a tunnel. IPv4 and IPv6 both, when the iPhone
    /// has both, since a device's traffic leaves over IPv4 and the proxy's over either: a VPN that
    /// carries only one of them isn't one here. A tunnel that carries no default route, like
    /// Tailscale without an exit node, isn't one either. No packet is sent.
    ///
    /// `nat64` is the NAT64 prefix the server uses, see `WireGuardServer.nat64Prefix`, asked only on
    /// an iPhone with no IPv4 route.
    static func internetVPN(nat64: () -> String?, addresses: [String], route: (String) -> Route) -> String? {
        reading(nat64: nat64, addresses: addresses, route: route).vpn
    }

    /// The VPN as `internetVPN` finds it and, when there's none, the one family a tunnel carries while
    /// the other goes around it, so the screen can say why it doesn't count (#334).
    struct Reading: Equatable {
        var vpn: String?
        /// Only when `vpn` is nil, on an iPhone with routes for both families.
        var onlyFamily: Family?
    }

    enum Family: String {
        case ipv4 = "IPv4", ipv6 = "IPv6"

        var other: Family { self == .ipv4 ? .ipv6 : .ipv4 }
    }

    static func reading(nat64: () -> String?) -> Reading {
        reading(nat64: nat64, addresses: addresses(), route: route(toward:))
    }

    static func reading(nat64: () -> String?, addresses: [String], route: (String) -> Route) -> Reading {
        // No route for a family the iPhone has, on cellular or Wi-Fi, is a route that failed for a
        // moment, not an answer, so it's unknown and counts against a VPN (#330). Left as "none", the
        // other family would decide, and the devices would get through while this one goes around
        // the tunnel until the next check.
        let probe = { (host: String) -> Route in
            let found = route(host)
            return found == .none && hasOwn(ipv6: host.contains(":"), in: addresses) ? .unknown : found
        }
        var routes = internetProbes.map(probe)
        // With no IPv4 route, a device's IPv4 traffic leaves through the carrier's NAT64 (nat64.go),
        // at the carrier's own prefix when it has one. A VPN that carries only 2000::/3 carries a
        // prefix inside it and leaves the well-known one out, so the probe is in the prefix the
        // server uses. While the server still looks it up, nothing is known.
        if !routes.contains(where: { $0.isIPv4 }) {
            routes.append(nat64Probe(prefix: nat64()).map(probe) ?? .unknown)
        }
        if let vpn = vpn(in: addresses, routes: routes) { return Reading(vpn: vpn) }
        return Reading(onlyFamily: onlyFamily(in: addresses, routes: routes))
    }

    /// The iPhone has an address of that family to reach the internet by, on cellular (pdp_ip) or
    /// Wi-Fi (en): IPv6 in 2000::/3, IPv4 that isn't link-local or the CLAT's (192.0.0.0/29, which
    /// an IPv6-only carrier gives for its own translation). Tunnels and the hotspot don't count.
    static func hasOwn(ipv6: Bool, in interfaces: [String]) -> Bool {
        parse(interfaces).contains { line in
            guard line.name.hasPrefix("pdp_ip") || line.name.hasPrefix("en") else { return false }
            let address = line.address
            if ipv6 {
                return address.contains(":") && !address.contains("%") && (address.hasPrefix("2") || address.hasPrefix("3"))
            }
            return !address.contains(":") && !address.hasPrefix("169.254.") && !isCLAT(address)
        }
    }

    /// A tunnel carries every probe of one family, and every probe of the other leaves on an address
    /// that's on no tunnel. Only with routes for both families and every route known. It only says why
    /// there's no VPN, it never makes one.
    static func onlyFamily(in interfaces: [String], routes: [Route]) -> Family? {
        let local = routes.compactMap { if case .local(let address) = $0 { address } else { nil } }
        guard local.count == routes.count else { return nil }
        let ipv4 = local.filter { !$0.contains(":") }, ipv6 = local.filter { $0.contains(":") }
        guard !ipv4.isEmpty, !ipv6.isEmpty else { return nil }
        let lines = parse(interfaces)
        let outside = { (address: String) -> Bool in
            let names = lines.filter { $0.address == address }.map(\.name)
            return !names.isEmpty && !names.contains { $0.hasPrefix("utun") || $0.hasPrefix("ipsec") }
        }
        switch (vpn(in: interfaces, local: ipv4) != nil, vpn(in: interfaces, local: ipv6) != nil) {
        case (true, false) where ipv6.allSatisfy(outside): return .ipv4
        case (false, true) where ipv4.allSatisfy(outside): return .ipv6
        default: return nil
        }
    }

    /// Two addresses per family, far apart. A DNS app's tunnel can carry only its resolver's address
    /// (1.1.1.1, say) and nothing else, so the second of each is one no such tunnel is for: a CDN's
    /// (Fastly), routed like any website. Not one from the ranges kept for documentation: VPN apps
    /// leave the special-purpose ranges out of their tunnel by default (Shadowrocket leaves out
    /// 198.51.100.0/24), so a full tunnel would read as none (#277). No packet is sent to them.
    static let internetProbes = ["1.1.1.1", "151.101.0.1", "2606:4700:4700::1111", "2a04:4e42::1"]
    /// The prefix most NAT64s use (RFC 6052), which the server uses when the carrier has none of its own.
    static let wellKnownNAT64 = "64:ff9b::/96"

    /// 1.1.1.1 behind a NAT64 prefix like "2607:7700:0:1d::/96": the address in its last 32 bits, as
    /// nat64.go puts it. With no server running, nil, it's the well-known prefix, where a server
    /// starts from. Nil for a prefix still looked up, "", or one that can't be read.
    static func nat64Probe(prefix: String?) -> String? {
        let parts = (prefix ?? wellKnownNAT64).split(separator: "/")
        var address = in6_addr()
        guard parts.count == 2, parts[1] == "96", inet_pton(AF_INET6, String(parts[0]), &address) == 1 else { return nil }
        withUnsafeMutableBytes(of: &address) { $0[12..<16].copyBytes(from: [1, 1, 1, 1]) }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil else { return nil }
        return String(cString: text)
    }

    /// Where iOS would send from toward one address.
    enum Route: Equatable {
        /// From this local address.
        case local(String)
        /// Nowhere: the iPhone has no route there, like IPv4 on an IPv6-only carrier without CLAT. For
        /// a family the iPhone has, `reading` counts it as unknown.
        case none
        /// The question itself failed (no socket left, say), so nothing is known.
        case unknown

        /// After `socket` failed with `code`: no route when the iPhone has no such family at all.
        init(socketFailed code: Int32) {
            self = [EAFNOSUPPORT, EPROTONOSUPPORT].contains(code) ? .none : .unknown
        }

        /// After `connect` failed with `code`: no route when iOS has none toward the address, anything
        /// else is unknown, which counts against a VPN.
        init(connectFailed code: Int32) {
            self = [ENETUNREACH, EHOSTUNREACH, ENETDOWN, EADDRNOTAVAIL].contains(code) ? .none : .unknown
        }

        var isIPv4: Bool {
            if case .local(let address) = self { return !address.contains(":") }
            return false
        }
    }

    /// A route nothing is known about counts against a VPN: guessing would let devices through.
    static func vpn(in interfaces: [String], routes: [Route]) -> String? {
        guard !routes.contains(.unknown) else { return nil }
        return vpn(in: interfaces, local: routes.compactMap { if case .local(let address) = $0 { address } else { nil } })
    }

    static func vpn(in interfaces: [String], local: [String]) -> String? {
        let lines = parse(interfaces)
        var tunnel: String?
        for address in local {
            // Every interface that holds it: a VPN's inner address can be the carrier's too.
            let names = lines.filter { $0.address == address }.map(\.name)
            guard let name = names.first, names.allSatisfy({ $0.hasPrefix("utun") || $0.hasPrefix("ipsec") }) else { return nil }
            tunnel = tunnel ?? name
        }
        return tunnel
    }

    /// The local address a UDP socket connected toward `host` gets, port 53. Connecting a UDP socket
    /// only picks the route.
    private static func route(toward host: String) -> Route {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: SOCK_DGRAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "53", &hints, &info) == 0, let info else { return .unknown }
        defer { freeaddrinfo(info) }
        let fd = socket(info.pointee.ai_family, SOCK_DGRAM, 0)
        guard fd >= 0 else { return Route(socketFailed: errno) }
        defer { close(fd) }
        guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            return Route(connectFailed: errno)
        }
        var local = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return .unknown }
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let found = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return found == 0 ? .local(String(cString: name)) : .unknown
    }

    /// Every address but loopback's, IPv4 and IPv6, as "name: address".
    static func addresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let name = String(cString: p.pointee.ifa_name)
            let addr = String(cString: host)
            if name != "lo0" { out.append("\(name): \(addr)") }
        }
        return out
    }
}

/// Where Tether listens on the hotspot, as `Interfaces.hotspotAddress(in:keeping:)` picks it, with the
/// IPv6 address it last used kept in `defaults`: a device's config points at the address it was given,
/// so Tether keeps it through the hotspot going off and on and a relaunch, while the bridge has it.
/// Only IPv6 is kept, since 172.20.10.1 is always the same.
final class HotspotAddressKeeper {
    static let key = "hotspot.ipv6Address"
    private let defaults: UserDefaults
    private let interfaces: () -> [String]

    /// `interfaces` are lines like "bridge100: 172.20.10.1", the tests' own in place of the iPhone's.
    init(defaults: UserDefaults, interfaces: @escaping () -> [String] = Interfaces.addresses) {
        self.defaults = defaults
        self.interfaces = interfaces
    }

    func address() -> String? {
        let kept = defaults.string(forKey: Self.key)
        let address = Interfaces.hotspotAddress(in: interfaces(), keeping: kept)
        if let address, address.contains(":"), address != kept { defaults.set(address, forKey: Self.key) }
        return address
    }
}
