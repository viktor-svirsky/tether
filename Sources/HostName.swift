import dnssd
import Foundation

/// A name for this iPhone on the hotspot, `tether-xxxx.local`, for a config to point at in place of
/// the iPhone's IPv6 address (#65). On a carrier that gives the iPhone IPv6 only, that address comes
/// with each cellular session, so a config with it stops working when it changes. The name follows
/// the address, see `HotspotSession.configHost`.
///
/// The 4 hex digits are the start of the server's public key, so the name stays the same across
/// launches and a reinstall, as long as the keys do: the keys are in the Keychain. New keys mean every
/// device is added again anyway. The app can't use the iPhone's own name: iOS gives apps "iPhone".
/// Two iPhones with Tether each have their own hotspot, so their names never meet on one network.
/// After matthewdyso's fork (f8b78b5, 2398531).
enum HostName {
    static func name(for serverPublicKey: Data) -> String {
        "tether-" + serverPublicKey.prefix(2).map { String(format: "%02x", $0) }.joined() + ".local"
    }

    /// Whether a device's saved host is a name, not an address.
    static func isName(_ host: String) -> Bool { host.hasSuffix(".local") }
}

/// Answers a name with mDNS, so `HotspotSession` can be tested without it.
@MainActor
protocol HostNamePublishing: AnyObject {
    /// Answers `name` with `address` on the interface that has it, or takes it down for nil. The same
    /// again changes nothing.
    func publish(_ name: String, at address: String?)
    /// What mDNS confirmed it answers: nil until it does, and after a conflict or an error.
    var published: HostNameRecord? { get }
}

struct HostNameRecord: Equatable {
    let name: String
    let address: String
}

/// The real one, with Bonjour (DNSServiceRegisterRecord). Only an AAAA record, on the hotspot's
/// bridge: the name is only given to devices that reached Tether over IPv6, and WireGuard for iPhone,
/// iPad and Mac takes an IPv4 address over an IPv6 one whenever a name has both, with no fallback. An
/// A record for 172.20.10.1 would send a Mac on an IPv6-only hotspot, which can't reach it, there.
/// After ktg3769's fork (fe2ec29).
@MainActor
final class MDNSHostName: HostNamePublishing {
    private(set) var published: HostNameRecord?
    private var asked: HostNameRecord?
    private var connection: DNSServiceRef?
    private let log: @MainActor (String) -> Void

    init(log: @escaping @MainActor (String) -> Void) {
        self.log = log
    }

    func publish(_ name: String, at address: String?) {
        let record = address.map { HostNameRecord(name: name, address: $0) }
        guard record != asked else { return }
        withdraw()
        guard let record else {
            log("mDNS: \(name) withdrawn")
            return
        }
        asked = record
        var bytes = in6_addr()
        guard inet_pton(AF_INET6, record.address, &bytes) == 1 else {
            log("mDNS: \(record.address) isn't an IPv6 address")
            return
        }
        // Only on the hotspot's interface, so the name means nothing on Wi-Fi or cellular.
        let interface = Interfaces.addresses().first { $0.hasSuffix(": \(record.address)") }.map { String($0.prefix { $0 != ":" }) }
        let index = interface.map { if_nametoindex($0) } ?? 0
        guard index != 0 else {
            log("mDNS: no interface has \(record.address)")
            return
        }
        var ref: DNSServiceRef?
        var error = DNSServiceCreateConnection(&ref)
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            log("mDNS: no connection to mDNSResponder: \(error)")
            return
        }
        DNSServiceSetDispatchQueue(ref, .main)
        connection = ref
        var recordRef: DNSRecordRef?
        error = withUnsafeBytes(of: &bytes) { raw in
            DNSServiceRegisterRecord(ref, &recordRef, DNSServiceFlags(kDNSServiceFlagsUnique), index, record.name + ".",
                                     UInt16(kDNSServiceType_AAAA), UInt16(kDNSServiceClass_IN), UInt16(raw.count),
                                     raw.baseAddress, 120, { _, _, _, error, context in
                guard let context else { return }
                let me = Unmanaged<MDNSHostName>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { me.registered(error) }
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            log("mDNS: \(record.name) refused: \(error)")
            withdraw()
            asked = record // not again each round
            return
        }
    }

    /// mDNSResponder's answer once it has probed the name on the hotspot.
    private func registered(_ error: DNSServiceErrorType) {
        guard let asked else { return }
        if error == DNSServiceErrorType(kDNSServiceErr_NoError) {
            published = asked
            log("mDNS: \(asked.name) is \(asked.address)")
        } else if error == DNSServiceErrorType(kDNSServiceErr_NameConflict) {
            published = nil
            log("mDNS: \(asked.name) is taken by another device on the hotspot")
        } else {
            published = nil
            log("mDNS: \(asked.name) failed: \(error)")
            self.asked = nil // the next round registers it again, mDNSResponder restarted say
        }
    }

    private func withdraw() {
        if let connection { DNSServiceRefDeallocate(connection) } // takes its record with it
        connection = nil
        published = nil
        asked = nil
    }
}
