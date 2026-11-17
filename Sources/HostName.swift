import dnssd
import Foundation

/// A name for this iPhone on the hotspot, `tether-xxxx.local`, for a config to point at in place of
/// the iPhone's IPv6 address (#65). On a carrier that gives the iPhone IPv6 only, that address comes
/// with each cellular session, so a config with it stops working when it changes. The name follows
/// the address. The config page offers it to a Mac, see `HotspotSession.name(for:)`.
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
    /// again changes nothing, but tries again a name that failed, once it's time to.
    func publish(_ name: String, at address: String?)
    /// What mDNS confirmed it answers: nil until it does, and after a conflict or an error.
    var published: HostNameRecord? { get }
    /// Why the name asked for isn't answered: taken by another device, or refused. Nil while it is,
    /// and while mDNS is still checking it.
    var failure: String? { get }
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
///
/// A name that fails is tried again after 10 seconds, then twice as long each time, up to 10
/// minutes, and each reason is logged once. Model keeps it for the app's life. Its record goes with
/// it: mDNSResponder drops a record when its connection closes.
@MainActor
final class MDNSHostName: HostNamePublishing {
    static let firstRetry: TimeInterval = 10
    static let lastRetry: TimeInterval = 600

    private(set) var published: HostNameRecord?
    /// Kept through a new address until it's confirmed, so a device on the name stays told meanwhile.
    private(set) var failure: String?
    /// The last failure in the log, so each is said once for each address.
    private var said: String?
    private var asked: HostNameRecord?
    private var retryAt: Date?
    private var wait: TimeInterval = 0
    /// Closed in deinit, which isn't on the main actor.
    nonisolated(unsafe) private var connection: DNSServiceRef?
    private let interfaces: () -> [String]
    private let now: () -> Date
    private let log: @MainActor (String) -> Void

    /// `interfaces` are lines like "bridge100: 2607:fb91::1", the tests' own in place of the iPhone's.
    init(interfaces: @escaping () -> [String] = Interfaces.addresses, now: @escaping () -> Date = Date.init,
         log: @escaping @MainActor (String) -> Void) {
        self.interfaces = interfaces
        self.now = now
        self.log = log
    }

    deinit {
        if let connection { DNSServiceRefDeallocate(connection) }
    }

    func publish(_ name: String, at address: String?) {
        let record = address.map { HostNameRecord(name: name, address: $0) }
        if record == asked {
            // Answered or still being checked, or failed and not time yet.
            guard let retryAt, now() >= retryAt else { return }
        } else {
            if asked != nil, record == nil { log("mDNS: \(name) withdrawn") }
            if record == nil { failure = nil }
            said = nil
            wait = 0
        }
        close()
        asked = record
        retryAt = nil
        if let record { register(record) }
    }

    private func register(_ record: HostNameRecord) {
        var bytes = in6_addr()
        guard inet_pton(AF_INET6, record.address, &bytes) == 1 else { return fail("\(record.address) isn't an IPv6 address") }
        // Only on the hotspot's interface, so the name means nothing on Wi-Fi or cellular.
        let interface = interfaces().first { $0.hasSuffix(": \(record.address)") }.map { String($0.prefix { $0 != ":" }) }
        let index = interface.map { if_nametoindex($0) } ?? 0
        guard index != 0 else { return fail("no interface has \(record.address)") }
        var ref: DNSServiceRef?
        var error = DNSServiceCreateConnection(&ref)
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else { return fail("no connection to mDNSResponder (\(error))") }
        connection = ref
        error = DNSServiceSetDispatchQueue(ref, .main)
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            close()
            return fail("no queue for mDNS (\(error))")
        }
        var recordRef: DNSRecordRef?
        error = withUnsafeBytes(of: &bytes) { raw in
            DNSServiceRegisterRecord(ref, &recordRef, DNSServiceFlags(kDNSServiceFlagsUnique), index, record.name + ".",
                                     UInt16(kDNSServiceType_AAAA), UInt16(kDNSServiceClass_IN), UInt16(raw.count),
                                     raw.baseAddress, 120, { _, _, _, error, context in
                guard let context else { return }
                // Unretained: the connection, and with it this callback, goes before self does, see deinit.
                let me = Unmanaged<MDNSHostName>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { me.registered(error) }
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            close()
            return fail("refused (\(error))")
        }
    }

    /// mDNSResponder's answer once it has probed the name on the hotspot. The connection stays open
    /// after a failure: closing it in its own callback isn't allowed, so the retry closes it.
    private func registered(_ error: DNSServiceErrorType) {
        guard let asked else { return }
        if error == DNSServiceErrorType(kDNSServiceErr_NoError) {
            published = asked
            failure = nil
            said = nil
            wait = 0
            log("mDNS: \(asked.name) is \(asked.address)")
        } else if error == DNSServiceErrorType(kDNSServiceErr_NameConflict) {
            fail("taken by another device on the hotspot")
        } else {
            fail("failed (\(error))")
        }
    }

    /// Not answered: said once for each reason, and tried again later, a little later each time.
    private func fail(_ why: String) {
        published = nil
        if why != said, let asked { log("mDNS: \(asked.name): \(why), tries again later") }
        said = why
        failure = why
        wait = min(max(wait * 2, Self.firstRetry), Self.lastRetry)
        retryAt = now().addingTimeInterval(wait)
    }

    private func close() {
        if let connection { DNSServiceRefDeallocate(connection) } // takes its record with it
        connection = nil
        published = nil
    }
}
