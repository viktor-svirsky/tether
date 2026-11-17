import dnssd
import XCTest
@testable import TetherCore

/// The iPhone's name on the hotspot (#65), see `HostName`.
final class HostNameTests: XCTestCase {
    /// The start of the server's public key, so it's the same for as long as the keys are.
    func testTheNameComesFromTheServersKey() {
        XCTAssertEqual(HostName.name(for: Data([0x2a, 0x9a, 0xff, 0x01])), "tether-2a9a.local")
        XCTAssertEqual(HostName.name(for: Data([0x00, 0x07])), "tether-0007.local")
    }

    /// A device's saved host is a name or an address.
    func testANameIsToldFromAnAddress() {
        XCTAssertTrue(HostName.isName("tether-2a9a.local"))
        XCTAssertFalse(HostName.isName("172.20.10.1"))
        XCTAssertFalse(HostName.isName("2607:fb91::1"))
    }

    // MARK: MDNSHostName

    /// A name that can't be answered is said once, and tried again after 10 seconds, then twice as
    /// long each time, up to 10 minutes. A new address tries at once.
    @MainActor
    func testAFailureIsLoggedOnceAndTriedAgainLessAndLessOften() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var tries = 0
        var lines: [String] = []
        let mdns = MDNSHostName(interfaces: { tries += 1; return [] }, now: { now }, log: { lines.append($0) })
        let a = "2001:db8::1"
        mdns.publish("tether-2a9a.local", at: a)
        XCTAssertEqual(tries, 1)
        XCTAssertEqual(mdns.failure, "no interface has \(a)")
        XCTAssertNil(mdns.published)
        var waits: [TimeInterval] = []
        var since = now
        for _ in 0..<100 {
            now += 5
            mdns.publish("tether-2a9a.local", at: a)
            if tries > waits.count + 1 { waits.append(now.timeIntervalSince(since)); since = now }
        }
        XCTAssertEqual(waits, [10, 20, 40, 80, 160], "500 seconds")
        XCTAssertEqual(lines, ["mDNS: tether-2a9a.local: no interface has \(a), tries again later"])
        mdns.publish("tether-2a9a.local", at: "2001:db8::2")
        XCTAssertEqual(tries, waits.count + 2, "a new address at once")
        mdns.publish("tether-2a9a.local", at: nil)
        XCTAssertNil(mdns.failure)
        XCTAssertEqual(lines.last, "mDNS: tether-2a9a.local withdrawn")
        XCTAssertEqual(MDNSHostName.lastRetry, 600)
    }

    /// The real thing, on this Mac's loopback: mDNSResponder confirms the name, and a lookup gets the
    /// AAAA record and no A record.
    @MainActor
    func testTheNameIsAnsweredWithIPv6Only() throws {
        let name = "tether-test-\(UUID().uuidString.prefix(8).lowercased()).local"
        var lines: [String] = []
        let mdns = MDNSHostName(interfaces: { ["lo0: ::1"] }, log: { lines.append($0) })
        mdns.publish(name, at: "2001:db8::1") // on no interface here
        XCTAssertNotNil(mdns.failure)
        mdns.publish(name, at: "::1")
        XCTAssertNotNil(mdns.failure, "kept until the new address is confirmed, so a device on the name stays told")
        let deadline = Date().addingTimeInterval(10)
        while mdns.published == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(mdns.published, HostNameRecord(name: name, address: "::1"), "\(lines)")
        XCTAssertNil(mdns.failure)
        XCTAssertEqual(lookUp(name, type: kDNSServiceType_AAAA), [Data(repeating: 0, count: 15) + [1]])
        XCTAssertEqual(lookUp(name, type: kDNSServiceType_A), [])
        mdns.publish(name, at: nil)
        XCTAssertNil(mdns.published)
    }

    /// The answers' data for `name` on loopback, for 2 seconds.
    @MainActor
    private func lookUp(_ name: String, type: Int) -> [Data] {
        final class Box { var answers: [Data] = [] }
        let box = Box()
        var ref: DNSServiceRef?
        let error = DNSServiceQueryRecord(&ref, 0, if_nametoindex("lo0"), name + ".", UInt16(type), UInt16(kDNSServiceClass_IN),
                                          { _, _, _, error, _, _, _, length, data, _, context in
            guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let data, let context else { return }
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().answers.append(Data(bytes: data, count: Int(length)))
        }, Unmanaged.passUnretained(box).toOpaque())
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else { return [] }
        defer { DNSServiceRefDeallocate(ref) }
        DNSServiceSetDispatchQueue(ref, .main)
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        return box.answers
    }
}
