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
        XCTAssertEqual(DNSChoice.allCases, [.cloudflare, .cloudflareMalware, .quad9, .adGuard, .controlD, .other])
        XCTAssertEqual(DNSChoice.default, .cloudflare)
        XCTAssertEqual(DNSChoice.allCases.map(\.label),
                       ["Cloudflare (1.1.1.1, no filtering)", "Cloudflare (1.1.1.2, blocks malware)", "Quad9 (9.9.9.9, blocks malware)",
                        "AdGuard (94.140.14.14, blocks ads)", "Control D (your profile, over HTTPS)", "Other server"],
                       "as signed off in #79, the second one put in the same shape by the design review, Control D from #100")
        // Each with its second server, so a device still looks names up when one doesn't answer.
        XCTAssertEqual(DNSChoice.allCases.map(\.servers),
                       ["1.1.1.1, 1.0.0.1", "1.1.1.2, 1.0.0.2", "9.9.9.9, 149.112.112.112", "94.140.14.14, 94.140.15.15", nil, nil])
    }

    /// One or two IPv4 addresses Tether can send lookups to. IPv6 can't work: what the server forwards
    /// is IPv4 only. An address the server never forwards to (the iPhone itself, the tunnel, link-local,
    /// multicast, broadcast) is refused too: the server wouldn't start with it, and every device would
    /// lose its connection, not only its lookups (#121).
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
            ("127.0.0.1", nil, #line),
            ("0.0.0.0", nil, #line),
            ("10.7.0.1", nil, #line), // Tether itself, asking itself
            ("10.7.0.200", nil, #line),
            ("169.254.1.1", nil, #line),
            ("224.0.0.251", nil, #line),
            ("255.255.255.255", nil, #line),
            ("8.8.8.8, 127.0.0.1", nil, #line),
            ("10.7.1.1", "10.7.1.1", #line), // outside the tunnel's 10.7.0.0/24
        ]
        for c in cases {
            XCTAssertEqual(DNSChoice.servers(typed: c.typed), c.servers, "'\(c.typed)'", line: c.line)
        }
    }

    func testTheSavedSettingAndItsServers() {
        XCTAssertEqual(DNSChoice.saved(in: defaults), .cloudflare, "nothing saved")
        XCTAssertEqual(DNSChoice.upstream(in: defaults), .servers(["1.1.1.1", "1.0.0.1"]))
        defaults.set(DNSChoice.adGuard.rawValue, forKey: DNSChoice.key)
        XCTAssertEqual(DNSChoice.upstream(in: defaults), .servers(["94.140.14.14", "94.140.15.15"]))
        defaults.set("from a newer version", forKey: DNSChoice.key)
        XCTAssertEqual(DNSChoice.saved(in: defaults), .cloudflare, "an unknown choice")
    }

    /// Other with nothing usable typed sends lookups to Cloudflare, never nowhere.
    func testOtherWithNoUsableAddressGivesCloudflare() {
        defaults.set(DNSChoice.other.rawValue, forKey: DNSChoice.key)
        XCTAssertEqual(DNSChoice.upstream(in: defaults), .servers(["1.1.1.1", "1.0.0.1"]), "nothing typed")
        defaults.set("dns.google", forKey: DNSChoice.otherKey)
        XCTAssertEqual(DNSChoice.upstream(in: defaults), .servers(["1.1.1.1", "1.0.0.1"]), "not an address")
        defaults.set("9.9.9.10", forKey: DNSChoice.otherKey)
        XCTAssertEqual(DNSChoice.upstream(in: defaults), .servers(["9.9.9.10"]))
        defaults.set(DNSChoice.quad9.rawValue, forKey: DNSChoice.key)
        XCTAssertEqual(DNSChoice.upstream(in: defaults), .servers(["9.9.9.9", "149.112.112.112"]), "Other's address is kept but not used")
    }

    /// Control D (#100) takes the DoH link from its dashboard, with a device name after it or not,
    /// or the resolver ID alone. Anything else is refused: the lookups would go nowhere.
    func testAControlDProfileTyped() {
        let profile = "https://dns.controld.com/abcd1234"
        let cases: [(typed: String, url: String?, line: UInt)] = [
            ("abcd1234", profile, #line),
            ("  abcd1234 ", profile, #line),
            ("https://dns.controld.com/abcd1234", profile, #line),
            ("https://dns.controld.com/abcd1234/", profile, #line),
            ("dns.controld.com/abcd1234", profile, #line),
            ("https://dns.controld.com/abcd1234/my-laptop", profile + "/my-laptop", #line),
            ("", nil, #line),
            ("https://dns.controld.com/", nil, #line),
            ("http://dns.controld.com/abcd1234", nil, #line),
            ("https://dns.google/dns-query", nil, #line),
            ("https://dns.controld.com.evil.example/abcd1234", nil, #line),
            ("76.76.2.22", nil, #line),
            ("abcd 1234", nil, #line),
            ("a/b/c", nil, #line),
            ("abcd1234?x=1", nil, #line),
        ]
        for c in cases {
            XCTAssertEqual(DNSChoice.controlD(typed: c.typed)?.absoluteString, c.url, "'\(c.typed)'", line: c.line)
        }
    }

    /// Where Tether sends lookups to 10.7.0.1, the one DNS server every config names (#121): Control D's
    /// profile over HTTPS, or the servers of the choice.
    func testWhereLookupsGoForEachChoice() {
        XCTAssertEqual(DNSChoice.upstream(in: defaults), .servers(["1.1.1.1", "1.0.0.1"]), "nothing saved")
        defaults.set(DNSChoice.controlD.rawValue, forKey: DNSChoice.key)
        XCTAssertEqual(DNSChoice.upstream(in: defaults), .servers(["1.1.1.1", "1.0.0.1"]),
                       "Control D with nothing typed sends lookups to Cloudflare, never nowhere")
        defaults.set("abcd1234", forKey: DNSChoice.controlDKey)
        XCTAssertEqual(DNSChoice.upstream(in: defaults), .doh(URL(string: "https://dns.controld.com/abcd1234")!))
        defaults.set(DNSChoice.other.rawValue, forKey: DNSChoice.key)
        defaults.set("9.9.9.10", forKey: DNSChoice.otherKey)
        XCTAssertEqual(DNSChoice.upstream(in: defaults), .servers(["9.9.9.10"]), "Control D's profile is kept but not used")
    }
}
