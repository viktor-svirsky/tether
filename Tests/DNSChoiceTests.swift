import XCTest
@testable import TetherCore

/// The DNS server new devices get (#79): the choices, what each puts on the config's DNS line, an
/// address typed under Other, and what a saved setting reads back as.
final class DNSChoiceTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "DNSChoiceTests")
        defaults.removePersistentDomain(forName: "DNSChoiceTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "DNSChoiceTests")
    }

    func testTheChoicesTheirWordsAndServers() {
        XCTAssertEqual(DNSChoice.allCases, [.cloudflare, .cloudflareMalware, .quad9, .adGuard, .other])
        XCTAssertEqual(DNSChoice.default, .cloudflare)
        XCTAssertEqual(DNSChoice.allCases.map(\.label),
                       ["Cloudflare (1.1.1.1, no filtering)", "Cloudflare (1.1.1.2, blocks malware)", "Quad9 (9.9.9.9, blocks malware)",
                        "AdGuard (94.140.14.14, blocks ads)", "Other server"], "as signed off in #79, the second one put in the same shape by the design review")
        // Each with its second server, so a device still looks names up when one doesn't answer.
        XCTAssertEqual(DNSChoice.allCases.map(\.servers),
                       ["1.1.1.1, 1.0.0.1", "1.1.1.2, 1.0.0.2", "9.9.9.9, 149.112.112.112", "94.140.14.14, 94.140.15.15", nil])
    }

    /// One or two IPv4 addresses. IPv6 can't work: a device's tunnel address is IPv4 only, and so is
    /// what the server forwards. A word would be read by WireGuard as a search domain, leaving the
    /// device without a DNS server, so anything else is refused.
    func testAnAddressTypedUnderOther() {
        let cases: [(typed: String, servers: String?, line: UInt)] = [
            ("192.168.1.1", "192.168.1.1", #line),
            ("  8.8.8.8 ", "8.8.8.8", #line),
            ("8.8.8.8, 8.8.4.4", "8.8.8.8, 8.8.4.4", #line),
            ("8.8.8.8 8.8.4.4", "8.8.8.8, 8.8.4.4", #line),
            ("8.8.8.8,8.8.4.4", "8.8.8.8, 8.8.4.4", #line),
            ("", nil, #line),
            ("dns.google", nil, #line),
            ("2001:4860:4860::8888", nil, #line),
            ("8.8.8", nil, #line),
            ("8.8.8.256", nil, #line),
            ("8.8.8.8, nonsense", nil, #line),
            ("1.1.1.1, 1.0.0.1, 8.8.8.8", nil, #line), // two at most
        ]
        for c in cases {
            XCTAssertEqual(DNSChoice.servers(typed: c.typed), c.servers, "'\(c.typed)'", line: c.line)
        }
    }

    func testTheSavedSettingAndItsServers() {
        XCTAssertEqual(DNSChoice.saved(in: defaults), .cloudflare, "nothing saved")
        XCTAssertEqual(DNSChoice.servers(in: defaults), "1.1.1.1, 1.0.0.1")
        defaults.set(DNSChoice.adGuard.rawValue, forKey: DNSChoice.key)
        XCTAssertEqual(DNSChoice.servers(in: defaults), "94.140.14.14, 94.140.15.15")
        defaults.set("from a newer version", forKey: DNSChoice.key)
        XCTAssertEqual(DNSChoice.saved(in: defaults), .cloudflare, "an unknown choice")
    }

    /// Other with nothing usable typed gives new devices Cloudflare, never a broken DNS line.
    func testOtherWithNoUsableAddressGivesCloudflare() {
        defaults.set(DNSChoice.other.rawValue, forKey: DNSChoice.key)
        XCTAssertEqual(DNSChoice.servers(in: defaults), "1.1.1.1, 1.0.0.1", "nothing typed")
        defaults.set("dns.google", forKey: DNSChoice.otherKey)
        XCTAssertEqual(DNSChoice.servers(in: defaults), "1.1.1.1, 1.0.0.1", "not an address")
        defaults.set("9.9.9.10", forKey: DNSChoice.otherKey)
        XCTAssertEqual(DNSChoice.servers(in: defaults), "9.9.9.10")
        defaults.set(DNSChoice.quad9.rawValue, forKey: DNSChoice.key)
        XCTAssertEqual(DNSChoice.servers(in: defaults), "9.9.9.9, 149.112.112.112", "Other's address is kept but not used")
    }
}
