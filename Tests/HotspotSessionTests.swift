import XCTest
@testable import TetherCore

/// HotspotSession with a fake server, keep-alive sound, hotspot and clock: what Model does each
/// watcher round and sample, without UIKit, Go or a real hotspot.
@MainActor
final class HotspotSessionTests: XCTestCase {
    private let hotspot = "172.20.10.1"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let locked = "Its keys can't be read yet. Unlock this iPhone once."
    private let couldntStart = "It couldn't start. Tether tries again by itself. If this stays, share the log from Settings."

    private var server: FakeServer!
    private var sound: FakeSound!
    private var page: FakePage!
    private var secrets: FlakySecrets!
    private var devices: WireGuardDevices!
    private var address: String?
    private var ipv6Only = false
    private var idleAfter = IdleStop.After.never
    private var dns = DNSChoice.Upstream.servers(["1.1.1.1", "1.0.0.1"])
    private var blockLocal = true
    private var vpn: String?
    private var onlyFamily: Interfaces.Family?
    private var onlyThroughVPN = false
    /// mDNS for the iPhone's name, nil for none, see `HostName`.
    private var names: FakeHostName?
    /// Continue on the screen before iOS asks for Local Network access, see `LocalNetworkIntro`.
    private var introduced = true
    private let usageDefaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: "HotspotSessionTests.usage")!
        defaults.removePersistentDomain(forName: "HotspotSessionTests.usage")
        return defaults
    }()
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var session: HotspotSession!
    private var knocker: FakeKnocker!

    /// `saved` is a setup already in the Keychain at launch.
    private func makeSession(sceneActive: Bool = true, locked: Bool = false, saved: WireGuardSetup? = nil,
                             cellular: @escaping () -> String = { "" }, log: @escaping @MainActor (String) -> Void = { _ in }) {
        server = FakeServer()
        sound = FakeSound()
        page = FakePage()
        secrets = FlakySecrets()
        secrets.failing = locked
        secrets.data = saved.flatMap { try? JSONEncoder().encode($0) }
        devices = WireGuardDevices(secrets: secrets)
        knocker = FakeKnocker()
        session = HotspotSession(devices: devices, server: server, keepAlive: sound, page: page,
                                 sceneActive: sceneActive, hotspotAddress: { [unowned self] in address },
                                 carrierIPv6Only: { [unowned self] in ipv6Only }, idleStopAfter: { [unowned self] in idleAfter },
                                 dns: { [unowned self] in dns }, blockLocal: { [unowned self] in blockLocal }, usageDefaults: usageDefaults,
                                 now: { [unowned self] in now }, hostName: names, cellular: cellular, knocker: knocker,
                                 internetVPN: { [unowned self] in Interfaces.Reading(vpn: vpn, onlyFamily: onlyFamily) }, onlyThroughVPN: { [unowned self] in onlyThroughVPN }, log: log)
        session.localNetworkIntroduced = { [unowned self] in introduced }
    }

    private func minutes(_ m: Double) -> Date { start.addingTimeInterval(m * 60) }

    // MARK: The hotspot

    func testTheServerFollowsTheHotspot() {
        makeSession()
        // Each row is one watcher round: the hotspot address it sees, then where the server listens.
        let rounds: [(address: String?, running: Bool, starts: [String], line: UInt)] = [
            (nil, false, [], #line),
            (hotspot, true, [hotspot], #line),
            (hotspot, true, [hotspot], #line), // no restart while it stays
            ("172.20.10.3", true, [hotspot, "172.20.10.3"], #line), // a new address, a new server
            (nil, false, [hotspot, "172.20.10.3"], #line),
            (hotspot, true, [hotspot, "172.20.10.3", hotspot], #line),
        ]
        for round in rounds {
            address = round.address
            session.syncWithHotspot()
            XCTAssertEqual(session.running, round.running, line: round.line)
            XCTAssertEqual(session.sharing, round.running, line: round.line)
            XCTAssertEqual(server.running, round.running, line: round.line)
            XCTAssertEqual(server.starts, round.starts, line: round.line)
        }
    }

    /// A new hotspot address restarts the server in one round, so no read sees it stop. The proxy's
    /// stats say it's a new run, whose served list starts empty, see ProxyProgress (#285).
    func testARestartGivesTheProxyStatsANewRun() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.sampleTraffic()
        let first = session.proxyStats.run
        address = "172.20.10.3"
        session.syncWithHotspot()
        session.sampleTraffic()
        XCTAssertNotEqual(session.proxyStats.run, first)
    }

    func testTheHotspotAddressIsOnABridgeInTheHotspotSubnet() {
        let cases: [(interfaces: [String], hotspot: String?, line: UInt)] = [
            ([], nil, #line),
            (["en0: 192.168.1.5"], nil, #line),
            (["bridge100: 172.20.10.1"], "172.20.10.1", #line),
            (["bridge100: 192.168.2.1"], nil, #line), // another bridge, a Mac's Internet Sharing say
            (["en2: 172.20.10.4"], nil, #line), // this iPhone on someone else's hotspot
            (["en0: 10.0.0.2", "bridge101: 192.168.64.1", "bridge100: 172.20.10.1"], "172.20.10.1", #line),
        ]
        for c in cases {
            XCTAssertEqual(Interfaces.hotspotAddress(in: c.interfaces), c.hotspot, line: c.line)
        }
    }

    /// A carrier that gives the iPhone IPv6 only gives the hotspot's devices no IPv4 either, so they
    /// reach the iPhone at its IPv6 address on the same bridge (#58). Everyone else keeps 172.20.10.1.
    func testOnAnIPv6OnlyCarrierTheHotspotAddressIsIPv6() {
        let v6 = "2607:fb91:88a2:e822:2c2a:d4de:6d26:71e2"
        let bridge = ["bridge100: 172.20.10.1", "bridge100: fe80::c416:8fff:feae:9664%bridge100", "bridge100: \(v6)"]
        let cases: [(interfaces: [String], hotspot: String?, line: UInt)] = [
            (bridge + ["pdp_ip0: 2607:fb90:1::2"], v6, #line), // no IPv4 from the carrier
            (bridge, v6, #line),
            (bridge + ["pdp_ip0: 192.0.0.4"], v6, #line), // a CLAT's address isn't IPv4 from the carrier
            (bridge + ["pdp_ip0: 10.20.30.40"], "172.20.10.1", #line), // dual stack, as before
            (bridge + ["pdp_ip1: 10.170.0.9"], v6, #line), // VoLTE's own IPv4 isn't for the internet
            (bridge + ["pdp_ip0: 192.0.0.8"], "172.20.10.1", #line), // just past the CLAT's range
            (["bridge100: 172.20.10.1", "bridge100: fe80::1%bridge100"], "172.20.10.1", #line), // no IPv6 to give
            (["bridge100: 172.20.10.1", "bridge101: \(v6)"], "172.20.10.1", #line), // another bridge's
            (["bridge101: \(v6)"], nil, #line), // no hotspot
        ]
        for c in cases {
            XCTAssertEqual(Interfaces.hotspotAddress(in: c.interfaces), c.hotspot, line: c.line)
        }
    }

    /// A new IPv6 address on the bridge, a temporary one say, doesn't move Tether while the one it
    /// listens on is still there.
    func testTheIPv6AddressInUseIsKeptWhileTheBridgeHasIt() {
        let a = "2607:fb91:88a2:e822::a", b = "2607:fb91:88a2:e822::b", c = "2607:fb91:88a2:e822::c"
        let both = ["bridge100: 172.20.10.1", "bridge100: \(a)", "bridge100: \(b)"]
        XCTAssertEqual(Interfaces.hotspotAddress(in: both), a)
        XCTAssertEqual(Interfaces.hotspotAddress(in: both, keeping: b), b)
        XCTAssertEqual(Interfaces.hotspotAddress(in: ["bridge100: 172.20.10.1", "bridge100: \(c)"], keeping: b), c, "gone, so a new one")
        XCTAssertEqual(Interfaces.hotspotAddress(in: both + ["pdp_ip0: 10.20.30.40"], keeping: b), "172.20.10.1", "IPv4 is back")
    }

    /// The IPv6 address in use is kept through the hotspot going off and on and a relaunch, while the
    /// bridge has it, since the devices set up there point at it (#65). 172.20.10.1 never changes, so
    /// it isn't kept.
    func testTheIPv6AddressInUseIsKeptAcrossARelaunch() {
        let defaults = UserDefaults(suiteName: "HotspotSessionTests")!
        defaults.removePersistentDomain(forName: "HotspotSessionTests")
        let a = "2607:fb91:88a2:e822::a", b = "2607:fb91:88a2:e822::b"
        var interfaces = ["bridge100: 172.20.10.1", "bridge100: \(a)", "pdp_ip0: 10.20.30.40"]
        let keeper = HotspotAddressKeeper(defaults: defaults) { interfaces }
        XCTAssertEqual(keeper.address(), "172.20.10.1")
        XCTAssertNil(defaults.string(forKey: HotspotAddressKeeper.key), "nothing kept on a usual carrier")
        interfaces = ["bridge100: 172.20.10.1", "bridge100: \(a)"]
        XCTAssertEqual(keeper.address(), a)
        interfaces = []
        XCTAssertNil(keeper.address(), "the hotspot went")
        interfaces = ["bridge100: 172.20.10.1", "bridge100: \(b)", "bridge100: \(a)"]
        XCTAssertEqual(keeper.address(), a, "back, with another address listed first")
        let relaunched = HotspotAddressKeeper(defaults: defaults) { interfaces }
        XCTAssertEqual(relaunched.address(), a, "and after a relaunch")
        interfaces = ["bridge100: 172.20.10.1", "bridge100: \(b)"]
        XCTAssertEqual(relaunched.address(), b, "gone, so a new one")
        interfaces += ["pdp_ip0: 10.20.30.40"]
        XCTAssertEqual(relaunched.address(), "172.20.10.1", "IPv4 is back")
        XCTAssertEqual(defaults.string(forKey: HotspotAddressKeeper.key), b, "only IPv6 is kept")
        defaults.removePersistentDomain(forName: "HotspotSessionTests")
    }

    /// On an IPv6-only hotspot everything a device is given points at the iPhone's IPv6 address: the
    /// server, the page, the QR code's config and the downloaded one.
    func testOnAnIPv6HotspotEverythingPointsAtTheIPv6Address() throws {
        makeSession()
        let v6 = "2607:fb91:88a2:e822:2c2a:d4de:6d26:71e2"
        XCTAssertEqual(session.deviceHost, hotspot)
        address = v6
        session.syncWithHotspot()
        XCTAssertEqual(server.starts, ["\(hotspot),\(v6)"])
        XCTAssertEqual(page.starts, ["\(hotspot),\(v6):80"])
        XCTAssertEqual(session.deviceHost, v6)
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        XCTAssertTrue(try XCTUnwrap(session.wireGuardConfig(for: ready)).contains("Endpoint = [\(v6)]:51820\n"))
        XCTAssertTrue(body(page.ask(.config, from: "2607:fb91:88a2:e822:1868:49e0:74e1:bee3")).contains("Endpoint = [\(v6)]:51820\n"))
        address = nil
        session.syncWithHotspot()
        XCTAssertEqual(session.deviceHost, hotspot, "the usual address while there's no hotspot")
    }

    /// A Mac takes no IPv4 on an IPv6-only hotspot, but a Windows PC does, and reaches 172.20.10.1
    /// (#98). So Tether listens there too, and a computer that downloads over IPv4 gets a config for
    /// 172.20.10.1, which never changes. The page shows that address first.
    func testOnAnIPv6HotspotAComputerWithIPv4Gets172_20_10_1() throws {
        makeSession()
        let v6 = "2607:fb91:88a2:e822::a"
        XCTAssertEqual(session.pageHosts, [hotspot], "before the hotspot, the usual address")
        address = v6
        session.syncWithHotspot()
        XCTAssertEqual(session.pageHosts, [hotspot, v6])
        XCTAssertEqual(session.deviceHost, v6, "the QR code: iPhones and iPads take no IPv4 there either")
        session.openAddWindow()
        XCTAssertTrue(body(page.ask(.config, from: "172.20.10.2")).contains("Endpoint = 172.20.10.1:51820\n"))
        XCTAssertTrue(body(page.ask(.config, from: "2607:fb91:88a2:e822::99")).contains("Endpoint = [\(v6)]:51820\n"))
        XCTAssertEqual(session.wireGuardPeers.map(\.host), [hotspot, v6])

        address = hotspot // IPv4 from the carrier again: only 172.20.10.1
        session.syncWithHotspot()
        XCTAssertEqual(session.pageHosts, [hotspot])
        XCTAssertEqual(server.starts, ["\(hotspot),\(v6)", hotspot])
    }

    /// On an IPv6-only carrier the hotspot comes back with 172.20.10.1 before its IPv6 address. Tether
    /// listens on the IPv6 address too once it shows up, with no restart, so the devices keep their
    /// sessions (#219). Everything a device is given then points at the IPv6 address.
    func testAnIPv6AddressThatShowsUpLaterIsListenedOnWithoutARestart() {
        makeSession()
        let v6 = "2607:fb91:88a2:e822::a"
        address = hotspot
        session.syncWithHotspot()
        var changes = 0
        session.willChange = { changes += 1 }
        address = v6
        session.syncWithHotspot()
        XCTAssertGreaterThan(changes, 0, "the screen shows the new addresses")
        XCTAssertEqual(server.starts, [hotspot], "no restart")
        XCTAssertEqual(server.listens, ["\(hotspot),\(v6)"])
        XCTAssertTrue(server.running)
        XCTAssertEqual(page.starts.last, "\(hotspot),\(v6):80")
        XCTAssertEqual(session.pageHosts, [hotspot, v6])
        XCTAssertEqual(session.deviceHost, v6)
        session.syncWithHotspot()
        XCTAssertEqual(server.listens.count, 1, "once")
    }

    /// An IPv6 address the server can't listen on yet doesn't restart it, which would fail on that
    /// address too and drop every device. It keeps 172.20.10.1 and tries again each round.
    func testAnIPv6AddressThatCantBeListenedOnYetIsTriedAgainWithoutARestart() {
        makeSession()
        let v6 = "2607:fb91:88a2:e822::a"
        address = hotspot
        session.syncWithHotspot()
        server.listenError = FakeServer.Failure()
        address = v6
        session.syncWithHotspot()
        session.syncWithHotspot()
        XCTAssertEqual(server.starts, [hotspot], "no restart")
        XCTAssertEqual(server.listens.count, 2, "tried each round")
        XCTAssertEqual(session.pageHosts, [hotspot])
        server.listenError = nil
        session.syncWithHotspot()
        XCTAssertEqual(server.starts, [hotspot])
        XCTAssertEqual(session.pageHosts, [hotspot, v6])
    }

    /// A config for 172.20.10.1 keeps working through a new IPv6 address, and back on a usual carrier.
    /// One for the old IPv6 address doesn't.
    func testAConfigFor172_20_10_1NeverNeedsANewOne() throws {
        makeSession()
        let a = "2607:fb91:88a2:e822::a", b = "2607:fb91:88a3:1234::b"
        address = a
        session.syncWithHotspot()
        session.openAddWindow()
        _ = page.ask(.config, from: "172.20.10.2")
        _ = page.ask(.config, from: "2607:fb91:88a2:e822::99")
        let (overV4, overV6) = (session.wireGuardPeers[0], session.wireGuardPeers[1])
        let rounds: [(address: String?, v4: Bool, v6: Bool, line: UInt)] = [
            (a, false, false, #line),
            (b, false, true, #line),
            (hotspot, false, true, #line),
            (a, false, false, #line),
        ]
        for round in rounds {
            address = round.address
            session.syncWithHotspot()
            XCTAssertEqual(session.needsNewConfig(overV4), round.v4, line: round.line)
            XCTAssertEqual(session.needsNewConfig(overV6), round.v6, line: round.line)
        }
    }

    /// The server tells where each device's last handshake came from, so a connected device points
    /// at the address it reached, whichever it was given, the QR code's device too.
    func testAConnectedDevicePointsAtTheAddressItReached() throws {
        makeSession()
        let v6 = "2607:fb91:88a2:e822::a"
        address = v6
        session.syncWithHotspot()
        session.openAddWindow()
        let scanned = try XCTUnwrap(session.wireGuardReady)
        server.connected = [scanned.address]
        server.endpoints = [scanned.address: "172.20.10.3:51820"]
        session.sampleTraffic()
        XCTAssertEqual(session.wireGuardPeers.map(\.host), [hotspot])
        server.endpoints = [scanned.address: "[2607:fb91:88a2:e822::99]:51820"]
        session.leftScreen()
        session.watch() // the background read
        XCTAssertEqual(session.wireGuardPeers.map(\.host), [v6])
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.peers.map(\.host), [v6], "saved")
    }

    /// A connected device's screen shows where its handshake comes from, the address alone (#73).
    /// None while the server doesn't say, and none while it's paused or gone, though a paused
    /// device's tunnel is up and the server still says.
    func testAConnectedDeviceConnectsFromItsHandshakesAddress() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let scanned = try XCTUnwrap(session.wireGuardReady)
        XCTAssertNil(session.connectsFrom(of: scanned.id), "never connected")
        server.connected = [scanned.address]
        session.sampleTraffic()
        XCTAssertNil(session.connectsFrom(of: scanned.id), "connected, but the server doesn't say from where")
        server.endpoints = [scanned.address: "172.20.10.2:52345"]
        session.sampleTraffic()
        XCTAssertEqual(session.connectsFrom(of: scanned.id), "172.20.10.2")
        server.endpoints = [scanned.address: "[2600:380:abcd::1]:52345"]
        session.sampleTraffic()
        XCTAssertEqual(session.connectsFrom(of: scanned.id), "2600:380:abcd::1")
        session.pauseWireGuardDevice(scanned.id)
        session.sampleTraffic()
        XCTAssertNil(session.connectsFrom(of: scanned.id), "paused, with its tunnel up")
        session.resumeWireGuardDevice(scanned.id)
        session.sampleTraffic()
        XCTAssertEqual(session.connectsFrom(of: scanned.id), "2600:380:abcd::1")
        server.connected = []
        session.sampleTraffic()
        XCTAssertNil(session.connectsFrom(of: scanned.id), "gone")
    }

    /// Before a device joins, the hotspot has no bridge, so there's no IPv6 address to give yet. The
    /// carrier's own interface, pdp_ip0, already says whether there will be IPv4 (#64).
    func testTheCarrierIsIPv6OnlyWhenTheInternetHasNoIPv4() {
        let v6 = "2607:fb90:1::2"
        let cases: [(interfaces: [String], ipv6Only: Bool, line: UInt)] = [
            ([], false, #line), // no cellular, the simulator say
            (["en0: 192.168.1.5", "en0: 2001:db8::5"], false, #line), // Wi-Fi only
            (["pdp_ip0: \(v6)"], true, #line),
            (["pdp_ip0: \(v6)", "pdp_ip0: 192.0.0.4"], true, #line), // a CLAT's address isn't IPv4 from the carrier
            (["pdp_ip0: \(v6)", "pdp_ip1: 10.170.0.9"], true, #line), // nor is VoLTE's
            (["pdp_ip0: \(v6)", "pdp_ip0: 10.20.30.40"], false, #line), // dual stack
            (["pdp_ip0: 10.20.30.40"], false, #line),
            (["pdp_ip0: fe80::1%pdp_ip0"], false, #line), // link-local only, not online yet
            (["pdp_ip1: \(v6)"], false, #line), // not the internet's
        ]
        for c in cases {
            XCTAssertEqual(Interfaces.carrierIPv6Only(in: c.interfaces), c.ipv6Only, line: c.line)
        }
    }

    /// On an IPv6-only carrier nothing is handed out before a device joins the hotspot: 172.20.10.1
    /// can't be reached there, and the IPv6 address comes with the hotspot (#64).
    func testOnAnIPv6OnlyCarrierThereIsNoConfigBeforeTheHotspot() throws {
        ipv6Only = true
        makeSession()
        let ready = try XCTUnwrap(session.wireGuardReady)
        XCTAssertNil(session.deviceHost, "known from the start")
        XCTAssertNil(session.wireGuardConfig(for: ready))
        let v6 = "2607:fb91:88a2:e822:2c2a:d4de:6d26:71e2"
        address = v6
        session.syncWithHotspot()
        XCTAssertEqual(session.deviceHost, v6)
        XCTAssertTrue(try XCTUnwrap(session.wireGuardConfig(for: ready)).contains("Endpoint = [\(v6)]:51820\n"))
        address = nil
        session.syncWithHotspot()
        XCTAssertNil(session.deviceHost, "the hotspot went")
        var changes = 0
        session.willChange = { changes += 1 }
        ipv6Only = false // IPv4 is back
        session.syncWithHotspot()
        XCTAssertEqual(session.deviceHost, hotspot)
        XCTAssertEqual(changes, 1, "the screen hears of it")
        session.syncWithHotspot()
        XCTAssertEqual(changes, 1, "and only when it changes")
    }

    /// Sharing with nothing moving, a sample and a watcher round change nothing on screen, so nothing
    /// redraws every second (#166).
    func testNothingIsPublishedWhenNothingChanged() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let scanned = try XCTUnwrap(session.wireGuardReady)
        server.connected = [scanned.address]
        session.sampleTraffic()
        session.sampleTraffic()
        var changes = 0
        session.willChange = { changes += 1 }
        now = now.addingTimeInterval(1)
        session.sampleTraffic()
        session.syncWithHotspot()
        session.dnsChanged() // publishes the setup, the same as before
        XCTAssertEqual(changes, 0)
    }

    /// Flown to another time zone mid-run, the month ends at the new zone's midnight, not the launch
    /// zone's (#163).
    func testTheMonthFollowsATimeZoneChange() throws {
        let before = NSTimeZone.default
        defer { NSTimeZone.default = before }
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        makeSession()
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        var london = Calendar(identifier: .gregorian)
        london.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        now = try XCTUnwrap(london.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 23, minute: 30)))
        XCTAssertEqual(session.nextReset, london.date(from: DateComponents(year: 2026, month: 12, day: 1)))
    }

    // MARK: Where a device's config points (#65)

    /// A device keeps the address Tether listened on when it connected with the QR code or downloaded its config.
    func testADeviceKeepsTheAddressItsConfigPointsAt() throws {
        makeSession()
        let v6 = "2607:fb91:88a2:e822::a"
        address = v6
        session.syncWithHotspot()
        session.openAddWindow()
        let scanned = try XCTUnwrap(session.wireGuardReady)
        server.connected = [scanned.address]
        session.sampleTraffic()
        XCTAssertEqual(page.ask(.config, from: "2607:fb91:88a2:e822::99").status, .ok)
        XCTAssertEqual(session.wireGuardPeers.map(\.host), [v6, v6])
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.peers.map(\.host), [v6, v6], "saved")
        XCTAssertFalse(session.wireGuardPeers.contains { session.needsNewConfig($0) })
    }

    /// A new IPv6 address, from a new cellular session say, leaves a config pointing at the old one.
    /// It says so while Tether listens somewhere else, and not while the hotspot is off, where it isn't known.
    func testADeviceWhoseConfigPointsAtAnOldAddressNeedsANewOne() throws {
        makeSession()
        let a = "2607:fb91:88a2:e822::a", b = "2607:fb91:88a3:1234::b"
        address = a
        session.syncWithHotspot()
        session.openAddWindow()
        _ = page.ask(.config, from: "2607:fb91:88a2:e822::99")
        let peer = try XCTUnwrap(session.wireGuardPeers.first)
        let rounds: [(address: String?, needsNewConfig: Bool, line: UInt)] = [
            (a, false, #line),
            (nil, false, #line),
            (b, true, #line),
            (hotspot, true, #line), // IPv4 is back, and the config still points at a
            (a, false, #line),
        ]
        for round in rounds {
            address = round.address
            session.syncWithHotspot()
            XCTAssertEqual(session.needsNewConfig(peer), round.needsNewConfig, line: round.line)
        }
    }

    /// On a usual carrier the address is always 172.20.10.1, so no device ever needs a new config.
    /// Every config names Tether's own address as its DNS server, whatever is picked in Settings: the QR
    /// code's and a download from the page. Tether asks the server picked at that moment, so a change
    /// reaches every device at once (#121).
    func testEveryNewConfigAsksTetherForDNS() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        XCTAssertTrue(try XCTUnwrap(session.wireGuardConfig(for: ready)).contains("\nDNS = 10.7.0.1\n"))
        dns = .servers(["94.140.14.14", "94.140.15.15"])
        XCTAssertTrue(try XCTUnwrap(session.wireGuardConfig(for: ready)).contains("\nDNS = 10.7.0.1\n"))
        XCTAssertTrue(body(page.ask(.config)).contains("\nDNS = 10.7.0.1\n"))
    }

    /// Where Tether sends lookups to 10.7.0.1 goes with each start and each change of the setting.
    func testTheServerFollowsTheDNSSetting() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        XCTAssertEqual(server.lastDNS, .servers(["1.1.1.1", "1.0.0.1"]), "at start")
        let controlD = DNSChoice.Upstream.doh(URL(string: "https://dns.controld.com/abcd1234")!)
        dns = controlD
        session.dnsChanged()
        XCTAssertEqual(server.lastDNS, controlD)
        dns = .servers(["9.9.9.9", "149.112.112.112"])
        session.dnsChanged()
        XCTAssertEqual(server.lastDNS, .servers(["9.9.9.9", "149.112.112.112"]))
    }

    /// Whether the devices reach the iPhone's local networks goes with each start and each change (#230).
    func testTheServerFollowsTheLocalNetworksSetting() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        XCTAssertEqual(server.lastBlockLocal, true, "at start")
        blockLocal = false
        session.localNetworksChanged()
        XCTAssertEqual(server.lastBlockLocal, false)
        blockLocal = true
        session.localNetworksChanged()
        XCTAssertEqual(server.lastBlockLocal, true)
    }

    /// Each device's data this month comes from its counters, on screen and in the background, and
    /// is saved at most once a minute, so it's there after a relaunch (#75).
    func testEachDevicesDataThisMonthIsCountedAndSaved() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let scanned = try XCTUnwrap(session.wireGuardReady)
        server.connected = [scanned.address]
        server.peerTraffic = [scanned.address: TrafficTotals(bytesUp: 10, bytesDown: 1000)]
        session.sampleTraffic()
        XCTAssertEqual(session.usage(of: scanned.id).thisMonth, TrafficTotals(bytesUp: 10, bytesDown: 1000))
        server.peerTraffic = [scanned.address: TrafficTotals(bytesUp: 20, bytesDown: 3000)]
        session.leftScreen()
        session.watch() // the background read
        XCTAssertEqual(session.usage(of: scanned.id).thisMonth, TrafficTotals(bytesUp: 20, bytesDown: 3000))
        XCTAssertEqual(MonthlyUsage.load(from: usageDefaults).of(scanned.id, at: now, calendar: .current).thisMonth,
                       TrafficTotals(bytesUp: 10, bytesDown: 1000), "saved at the first read, not again within the minute")
        now = now.addingTimeInterval(61)
        session.watch()
        XCTAssertEqual(MonthlyUsage.load(from: usageDefaults).of(scanned.id, at: now, calendar: .current).thisMonth,
                       TrafficTotals(bytesUp: 20, bytesDown: 3000))
    }

    /// While the Keychain is locked the setup lists no devices, which mustn't drop what they used.
    func testALockedSetupKeepsEachDevicesData() throws {
        var saved = WireGuardSetup.new()
        let ipad = try XCTUnwrap(saved.addPeer(name: "iPad"))
        var usage = MonthlyUsage()
        usage.record([ipad.id: TrafficTotals(bytesUp: 1, bytesDown: 2)], at: now, calendar: .current)
        usage.save(to: usageDefaults)
        makeSession(locked: true, saved: saved)
        session.saveUsage()
        XCTAssertEqual(MonthlyUsage.load(from: usageDefaults), usage)
        secrets.failing = false
        session.syncWithHotspot() // unlocked: the setup is read
        XCTAssertEqual(session.usage(of: ipad.id).thisMonth, TrafficTotals(bytesUp: 1, bytesDown: 2))
    }

    /// What a device used after the last read still counts when the hotspot goes.
    func testDataUsedJustBeforeTheHotspotGoesIsCounted() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let scanned = try XCTUnwrap(session.wireGuardReady)
        server.connected = [scanned.address]
        server.peerTraffic = [scanned.address: TrafficTotals(bytesUp: 10, bytesDown: 1000)]
        session.sampleTraffic()
        server.peerTraffic = [scanned.address: TrafficTotals(bytesUp: 30, bytesDown: 5000)] // after that read
        address = nil
        session.syncWithHotspot()
        XCTAssertEqual(MonthlyUsage.load(from: usageDefaults).of(scanned.id, at: now, calendar: .current).thisMonth,
                       TrafficTotals(bytesUp: 30, bytesDown: 5000))
    }

    /// When a device last connected outlives the hotspot going (#73). Sharing stops the server before
    /// its last read, and a stopped server knows no handshake, so the date kept is the last read's.
    func testTheLastConnectedTimeOutlivesTheHotspotGoing() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let scanned = try XCTUnwrap(session.wireGuardReady)
        XCTAssertNil(session.lastConnected(of: scanned.id), "never connected")
        server.connected = [scanned.address]
        server.handshakes = [scanned.address: minutes(-1)]
        session.sampleTraffic()
        XCTAssertEqual(session.lastConnected(of: scanned.id), minutes(-1))
        server.handshakes = [scanned.address: minutes(0)] // after that read, gone with the server
        address = nil
        session.syncWithHotspot()
        XCTAssertEqual(session.lastConnected(of: scanned.id), minutes(-1))
        XCTAssertEqual(MonthlyUsage.load(from: usageDefaults).lastConnected(scanned.id), minutes(-1), "saved, for a relaunch")
    }

    /// A removed device's data goes with it.
    func testARemovedDevicesDataIsDropped() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let scanned = try XCTUnwrap(session.wireGuardReady)
        server.connected = [scanned.address]
        server.peerTraffic = [scanned.address: TrafficTotals(bytesUp: 10, bytesDown: 1000)]
        session.sampleTraffic()
        XCTAssertTrue(session.removeWireGuardDevice(scanned.id))
        XCTAssertEqual(session.usage(of: scanned.id), MonthlyUsage.Usage())
    }

    func testOnAUsualCarrierNoDeviceNeedsANewConfig() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let scanned = try XCTUnwrap(session.wireGuardReady)
        server.connected = [scanned.address]
        session.sampleTraffic()
        _ = page.ask(.config)
        XCTAssertEqual(session.wireGuardPeers.map(\.host), [hotspot, hotspot])
        for address in [nil, hotspot] {
            self.address = address
            session.syncWithHotspot()
            XCTAssertFalse(session.wireGuardPeers.contains { session.needsNewConfig($0) })
        }
    }

    /// A device saved before Tether kept where its config points isn't told to add itself again: that
    /// isn't known. Once it connects, it points where Tether listens, after a relaunch too.
    func testADeviceSavedWithoutAnAddressLearnsItWhenItConnects() throws {
        var saved = WireGuardSetup.new()
        let old = try XCTUnwrap(saved.addPeer(name: "iPad"))
        makeSession(saved: saved)
        let a = "2607:fb91:88a2:e822::a", b = "2607:fb91:88a3:1234::b"
        address = a
        session.syncWithHotspot()
        XCTAssertFalse(session.needsNewConfig(try XCTUnwrap(session.wireGuardPeers.first)), "not known is fine")
        server.connected = [old.address]
        session.sampleTraffic()
        XCTAssertEqual(session.wireGuardPeers.map(\.host), [a])
        server.connected = [] // its config can't reach b
        address = b
        session.syncWithHotspot()
        session.sampleTraffic()
        XCTAssertTrue(session.needsNewConfig(try XCTUnwrap(session.wireGuardPeers.first)))

        let again = HotspotSession(devices: WireGuardDevices(secrets: secrets), server: FakeServer(), keepAlive: FakeSound(),
                                   page: FakePage(), sceneActive: true, hotspotAddress: { [unowned self] in address },
                                   now: { [unowned self] in now })
        again.syncWithHotspot()
        XCTAssertTrue(again.needsNewConfig(try XCTUnwrap(again.wireGuardPeers.first)), "after a relaunch too")
    }

    /// The server listens on one address only, so a device that connects points there, its config
    /// changed by hand say, and isn't told to add itself again.
    func testADeviceThatConnectsPointsWhereTetherListens() throws {
        makeSession()
        let a = "2607:fb91:88a2:e822::a", b = "2607:fb91:88a3:1234::b"
        address = a
        session.syncWithHotspot()
        session.openAddWindow()
        _ = page.ask(.config, from: "2607:fb91:88a2:e822::99")
        let peer = try XCTUnwrap(session.wireGuardPeers.first)
        address = b
        session.syncWithHotspot()
        XCTAssertTrue(session.needsNewConfig(peer))
        server.connected = [peer.address]
        session.leftScreen()
        session.watch() // the background read
        XCTAssertEqual(session.wireGuardPeers.map(\.host), [b])
        XCTAssertFalse(session.needsNewConfig(try XCTUnwrap(session.wireGuardPeers.first)))
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.peers.map(\.host), [b], "saved")
    }

    /// A device that is connected reaches Tether, so it isn't told otherwise, even when where it
    /// points now can't be saved.
    func testAConnectedDeviceNeverNeedsANewConfig() throws {
        makeSession()
        let a = "2607:fb91:88a2:e822::a", b = "2607:fb91:88a3:1234::b"
        address = a
        session.syncWithHotspot()
        session.openAddWindow()
        _ = page.ask(.config, from: "2607:fb91:88a2:e822::99")
        let peer = try XCTUnwrap(session.wireGuardPeers.first)
        address = b
        session.syncWithHotspot()
        secrets.savesFail = true
        server.connected = [peer.address]
        session.sampleTraffic()
        XCTAssertEqual(session.wireGuardPeers.map(\.host), [a], "not saved")
        XCTAssertFalse(session.needsNewConfig(peer))
    }

    // MARK: The iPhone's name on IPv6 (#65)

    private func name() -> String { HostName.name(for: devices.setup.serverPublicKey) }
    private func offersMac(_ response: ConfigPage.Response) -> Bool { body(response).contains(ConfigPage.macDownloadPath) }

    /// Over IPv6 the page's usual download keeps the address: an iPad's Safari says it's a Mac, and
    /// whether WireGuard on an iPhone or iPad finds a .local name is still to be tried. A second link,
    /// for a Mac, gives a config for the iPhone's name, which mDNS keeps pointing at the IPv6 address
    /// through a new cellular session. The QR code keeps the address too.
    func testOnAnIPv6HotspotTheMacLinkGivesTheNameThatFollowsTheAddress() throws {
        names = FakeHostName()
        makeSession()
        let a = "2607:fb91:88a2:e822::a", b = "2607:fb91:88a3:1234::b"
        address = a
        session.syncWithHotspot()
        let name = name()
        XCTAssertEqual(names?.changes, ["\(name) \(a)"], "the name answers with the address Tether listens on")
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        XCTAssertTrue(try XCTUnwrap(session.wireGuardConfig(for: ready)).contains("Endpoint = [\(a)]:51820\n"), "the QR code")
        let v6Client = "2607:fb91:88a2:e822::99"
        let page6 = page.ask(.page, from: v6Client)
        XCTAssertTrue(offersMac(page6))
        XCTAssertTrue(body(page6).contains("For a Mac: a config that follows the iPhone when its address changes"))
        XCTAssertTrue(body(page6).contains(name))
        XCTAssertTrue(body(page.ask(.config, from: v6Client)).contains("Endpoint = [\(a)]:51820\n"), "an iPad in Safari")
        XCTAssertTrue(body(page.ask(.macConfig, from: "2607:fb91:88a2:e822::98")).contains("Endpoint = \(name):51820\n"))
        XCTAssertEqual(session.wireGuardPeers.map(\.host), [a, name])
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.peers.map(\.host), [a, name], "saved")

        address = b // a new cellular session
        session.syncWithHotspot()
        XCTAssertEqual(names?.changes.last, "\(name) \(b)")
        XCTAssertEqual(session.wireGuardPeers.map { session.needsNewConfig($0) }, [true, false])
        address = nil
        session.syncWithHotspot()
        XCTAssertEqual(names?.changes.last, "\(name) -", "taken down with the hotspot")
    }

    /// Answering the name with mDNS can make iOS ask for Local Network access, so it waits for
    /// Continue on the screen before that question. WireGuard starts on the hotspot all the same.
    func testTheNameWaitsForTheLocalNetworkScreen() {
        names = FakeHostName()
        introduced = false
        makeSession()
        let a = "2607:fb91:88a2:e822::a"
        address = a
        session.syncWithHotspot()
        XCTAssertTrue(server.running, "WireGuard is not held back")
        XCTAssertEqual(names?.changes, [], "no mDNS before Continue")

        introduced = true
        session.syncWithHotspot()
        XCTAssertEqual(names?.changes, ["\(name()) \(a)"], "the next round answers the name")
    }

    /// Over IPv4 nothing changes: no name, no Mac link, and every config points at 172.20.10.1. On an
    /// IPv6-only hotspot a computer with IPv4 (a Windows PC) gets no Mac link either: 172.20.10.1 stays.
    func testOverIPv4ThereIsNoMacLinkAndConfigsKeep172_20_10_1() throws {
        names = FakeHostName()
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        XCTAssertTrue(try XCTUnwrap(session.wireGuardConfig(for: ready)).contains("Endpoint = 172.20.10.1:51820\n"))
        XCTAssertFalse(offersMac(page.ask(.page, from: "172.20.10.2")))
        XCTAssertEqual(page.ask(.macConfig, from: "172.20.10.2").status, .notFound)
        XCTAssertTrue(body(page.ask(.config, from: "172.20.10.2")).contains("Endpoint = 172.20.10.1:51820\n"))
        XCTAssertEqual(names?.changes, [])

        address = "2607:fb91:88a2:e822::a"
        session.syncWithHotspot()
        XCTAssertFalse(offersMac(page.ask(.page, from: "172.20.10.3")))
        XCTAssertEqual(page.ask(.macConfig, from: "172.20.10.3").status, .notFound)
    }

    /// The name comes from the server's key, which is in the Keychain, so a relaunch, or a reinstall
    /// that drops the app's other data, keeps it, and with it every config made for it.
    func testTheNameStaysTheSameAcrossLaunches() throws {
        names = FakeHostName()
        makeSession()
        let a = "2607:fb91:88a2:e822::a"
        address = a
        session.syncWithHotspot()
        let first = try XCTUnwrap(names?.published)
        XCTAssertNotNil(first.name.range(of: #"^tether-[0-9a-f]{4}\.local$"#, options: .regularExpression), first.name)

        let relaunched = FakeHostName()
        let again = HotspotSession(devices: WireGuardDevices(secrets: secrets), server: FakeServer(), keepAlive: FakeSound(),
                                   page: FakePage(), sceneActive: true, hotspotAddress: { [unowned self] in address },
                                   carrierIPv6Only: { true }, hostName: relaunched)
        again.syncWithHotspot()
        XCTAssertEqual(relaunched.published, first)
    }

    /// A name mDNS hasn't confirmed, still being checked or taken by another device, is never offered.
    func testAnUnconfirmedNameIsNotOffered() throws {
        for refused in [false, true] {
            names = FakeHostName()
            names?.confirms = refused
            names?.refuses = refused ? "taken by another device on the hotspot" : nil
            makeSession()
            address = "2607:fb91:88a2:e822::a"
            session.syncWithHotspot()
            session.openAddWindow()
            XCTAssertFalse(offersMac(page.ask(.page, from: "2607:fb91:88a2:e822::99")))
            XCTAssertEqual(page.ask(.macConfig, from: "2607:fb91:88a2:e822::99").status, .notFound)
            XCTAssertTrue(session.wireGuardPeers.isEmpty)
        }
    }

    /// A device on the address, from the QR code or the usual download, is still told to be added
    /// again once the address changes. One on the name isn't, until Tether listens on IPv4 only, where
    /// the name leads nowhere: the carrier gives IPv4 again. While an IPv6-only carrier's hotspot is
    /// back on 172.20.10.1 before its IPv6 address, it waits.
    func testADeviceOnTheAddressIsToldToAddItAgainAndOneOnTheNameOnlyOffIPv6() throws {
        names = FakeHostName()
        ipv6Only = true
        makeSession()
        let a = "2607:fb91:88a2:e822::a", b = "2607:fb91:88a3:1234::b"
        address = a
        session.syncWithHotspot()
        session.openAddWindow()
        let scanned = try XCTUnwrap(session.wireGuardReady)
        server.connected = [scanned.address]
        server.endpoints = [scanned.address: "[2607:fb91:88a2:e822::98]:51820"]
        session.sampleTraffic()
        _ = page.ask(.macConfig, from: "2607:fb91:88a2:e822::99")
        server.connected = []
        session.sampleTraffic()
        XCTAssertEqual(session.wireGuardPeers.map(\.host), [a, name()])
        let (onAddress, onName) = (session.wireGuardPeers[0], session.wireGuardPeers[1])
        let rounds: [(address: String?, ipv6Only: Bool, onAddress: Bool, onName: Bool, line: UInt)] = [
            (a, true, false, false, #line),
            (b, true, true, false, #line),
            (hotspot, true, true, false, #line), // the IPv6 address isn't there yet
            (hotspot, false, true, true, #line), // IPv4 from the carrier again
            (b, true, true, false, #line),
        ]
        for round in rounds {
            address = round.address
            ipv6Only = round.ipv6Only
            session.syncWithHotspot()
            XCTAssertEqual(session.newConfig(onAddress), round.onAddress ? .oldAddress : nil, line: round.line)
            XCTAssertEqual(session.newConfig(onName), round.onName ? .nameNotAnswered : nil, line: round.line)
        }
    }

    /// A device on the name can't connect while mDNS can't answer it: taken by another device, or
    /// refused (Local Network off, say). It says so, and a new config from the page has the address.
    /// Still being checked, it waits.
    func testADeviceOnANameThatIsntAnsweredIsToldToAddItAgain() throws {
        names = FakeHostName()
        makeSession()
        address = "2607:fb91:88a2:e822::a"
        session.syncWithHotspot()
        session.openAddWindow()
        _ = page.ask(.macConfig, from: "2607:fb91:88a2:e822::99")
        let peer = try XCTUnwrap(session.wireGuardPeers.first)
        XCTAssertNil(session.newConfig(peer))
        names?.confirms = false
        XCTAssertNil(session.newConfig(peer), "still being checked")
        names?.refuses = "taken by another device on the hotspot"
        XCTAssertEqual(session.newConfig(peer), .nameNotAnswered, "its own words, not an old address")
        XCTAssertTrue(session.needsNewConfig(peer))
        XCTAssertFalse(offersMac(page.ask(.page, from: "2607:fb91:88a2:e822::99")))
        names?.refuses = nil
        names?.confirms = true
        XCTAssertFalse(session.needsNewConfig(peer), "answered again")
    }

    /// mDNS failing or answering again changes what a device on the name says, with no other change on
    /// the screen, so the screen is told then too.
    func testTheScreenFollowsTheNameFailingAndAnsweringAgain() throws {
        names = FakeHostName()
        makeSession()
        address = "2607:fb91:88a2:e822::a"
        session.syncWithHotspot()
        var changes = 0
        session.willChange = { changes += 1 }
        names?.refuses = "taken by another device on the hotspot"
        XCTAssertEqual(changes, 1, "failed")
        names?.refuses = nil
        XCTAssertEqual(changes, 2, "answered again")
    }

    /// The usual download and then the Mac link from one Mac within seconds are two configs, two
    /// devices: the second isn't a repeat of the first.
    func testTheMacLinkRightAfterTheUsualDownloadGivesTheName() throws {
        names = FakeHostName()
        makeSession()
        let a = "2607:fb91:88a2:e822::a"
        address = a
        session.syncWithHotspot()
        session.openAddWindow()
        let mac = "2607:fb91:88a2:e822::99"
        XCTAssertTrue(body(page.ask(.config, from: mac)).contains("Endpoint = [\(a)]:51820\n"))
        XCTAssertTrue(body(page.ask(.macConfig, from: mac)).contains("Endpoint = \(name()):51820\n"))
        XCTAssertEqual(session.wireGuardPeers.map(\.host), [a, name()])
    }

    /// A device on the name that connects over IPv6 keeps the name: its config has it, not the address
    /// the handshake came to. Overwritten, it would be told to add itself again at the next address.
    func testAConnectedDeviceOnTheNameKeepsIt() throws {
        names = FakeHostName()
        makeSession()
        let a = "2607:fb91:88a2:e822::a", b = "2607:fb91:88a3:1234::b"
        address = a
        session.syncWithHotspot()
        session.openAddWindow()
        _ = page.ask(.macConfig, from: "2607:fb91:88a2:e822::99")
        let peer = try XCTUnwrap(session.wireGuardPeers.first)
        server.connected = [peer.address]
        server.endpoints = [peer.address: "[2607:fb91:88a2:e822::99]:51820"]
        session.sampleTraffic()
        session.leftScreen()
        session.watch()
        XCTAssertEqual(session.wireGuardPeers.map(\.host), [name()])
        server.connected = []
        address = b
        session.syncWithHotspot()
        XCTAssertFalse(session.needsNewConfig(try XCTUnwrap(session.wireGuardPeers.first)))
    }

    // MARK: Problems

    /// One watcher round: the hotspot, the Keychain and the server as they are, then what shows.
    private struct Round {
        var address: String?
        var locked = false
        var startFails = false
        var problem: String?
        var serverRunning: Bool
        var line: UInt = #line
    }

    private func run(_ rounds: [Round]) {
        makeSession(locked: rounds.first?.locked ?? false)
        for round in rounds {
            address = round.address
            secrets.failing = round.locked
            server.startError = round.startFails ? FakeServer.Failure() : nil
            session.syncWithHotspot()
            XCTAssertEqual(session.wireGuardProblem, round.problem, line: round.line)
            XCTAssertEqual(server.running, round.serverRunning, line: round.line)
            XCTAssertEqual(session.sharing, round.address != nil && round.problem == nil, line: round.line)
        }
    }

    func testLockedKeysThenUnlocked() {
        run([
            Round(address: nil, locked: true, problem: locked, serverRunning: false), // from launch, hotspot or not
            Round(address: hotspot, locked: true, problem: locked, serverRunning: false),
            Round(address: hotspot, problem: nil, serverRunning: true),
        ])
        XCTAssertEqual(server.starts, [hotspot], "nothing is tried while the keys are locked")
        XCTAssertNotNil(session.wireGuardReady, "the QR code appears once the keys load")
    }

    func testAStartThatFailsIsTriedAgainEachRound() {
        run([
            Round(address: hotspot, startFails: true, problem: couldntStart, serverRunning: false),
            Round(address: hotspot, startFails: true, problem: couldntStart, serverRunning: false),
            Round(address: hotspot, problem: nil, serverRunning: true),
        ])
        XCTAssertEqual(server.starts, [hotspot, hotspot, hotspot])
    }

    func testAStartErrorGoesWithTheHotspot() {
        run([
            Round(address: hotspot, startFails: true, problem: couldntStart, serverRunning: false),
            Round(address: nil, startFails: true, problem: nil, serverRunning: false),
            Round(address: hotspot, problem: nil, serverRunning: true),
        ])
    }

    /// Another socket on the port is something the person can act on, so it's said (the issue in the shared log).
    func testAPortInUseSaysSo() {
        struct InUse: Error, CustomStringConvertible {
            var description: String { "listen udp 172.20.10.1:51820: bind: address already in use" }
        }
        makeSession()
        address = hotspot
        server.startError = InUse()
        session.syncWithHotspot()
        XCTAssertEqual(session.wireGuardProblem, HotspotSession.problem(starting: InUse()))
        XCTAssertTrue(session.wireGuardProblem?.hasPrefix("Something else on this iPhone is using port 51820.") ?? false)
        server.startError = nil
        session.syncWithHotspot()
        XCTAssertNil(session.wireGuardProblem, "gone once it starts")
    }

    func testTheSetupProblemComesBeforeTheStartProblem() {
        run([
            Round(address: hotspot, locked: true, startFails: true, problem: locked, serverRunning: false),
            Round(address: hotspot, startFails: true, problem: couldntStart, serverRunning: false),
            Round(address: hotspot, problem: nil, serverRunning: true),
        ])
    }

    /// A shared log shows whether a recovery happened in the background or after Tether was opened (#231).
    func testComingOnScreenAndLeavingItAreLogged() {
        var logged: [String] = []
        makeSession(log: { logged.append($0) })
        session.leftScreen()
        session.cameOnScreen()
        XCTAssertEqual(logged.filter { $0.hasPrefix("Tether ") }, ["Tether left the screen", "Tether on screen"])
    }

    /// Whether the cellular data went with the hotspot, read only in the round it goes (#191).
    func testTheHotspotGoingAwaySaysWhatTheCellularDataHas() {
        var logged: [String] = []
        var reads = 0
        makeSession(cellular: { reads += 1; return "pdp_ip0: no address, data line: LTE" }, log: { logged.append($0) })
        address = hotspot
        session.syncWithHotspot()
        address = nil
        for _ in 0..<3 { session.syncWithHotspot() }
        XCTAssertEqual(logged.filter { $0.hasPrefix("hotspot address gone") },
                       ["hotspot address gone or changed, stopping (pdp_ip0: no address, data line: LTE)"])
        XCTAssertEqual(reads, 1)
    }

    /// With nothing to say about the cellular data, as in a demo, the line has no empty brackets.
    func testTheHotspotGoingAwayWithNoCellularText() {
        var logged: [String] = []
        makeSession(log: { logged.append($0) })
        address = hotspot
        session.syncWithHotspot()
        address = nil
        session.syncWithHotspot()
        XCTAssertEqual(logged.filter { $0.hasPrefix("hotspot address gone") }, ["hotspot address gone or changed, stopping"])
    }

    func testAProblemIsLoggedOnceNotEveryRound() {
        var logged: [String] = []
        makeSession(log: { logged.append($0) })
        address = hotspot
        server.startError = FakeServer.Failure()
        for _ in 0..<3 { session.syncWithHotspot() }
        XCTAssertEqual(logged.filter { $0.hasPrefix("WireGuard not started") }, ["WireGuard not started: port in use"])
    }

    /// The screen says the same for every reason, so a new reason is still logged (#190).
    func testADifferentReasonIsLoggedToo() {
        var logged: [String] = []
        makeSession(log: { logged.append($0) })
        address = hotspot
        server.startError = FakeServer.Failure()
        session.syncWithHotspot()
        server.startError = FakeServer.Refused()
        session.syncWithHotspot()
        session.syncWithHotspot()
        XCTAssertEqual(logged.filter { $0.hasPrefix("WireGuard not started") },
                       ["WireGuard not started: port in use", "WireGuard not started: the device list repeats a key or address"])
    }

    // MARK: Devices

    /// The server refuses a list by what's in it, so starting it again with the same list is refused
    /// too: it stays stopped and says why, rather than running without the change.
    func testADeviceListTheServerRefusesLeavesItStoppedUntilTheNextRound() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        let peer = try XCTUnwrap(devices.connectReady())
        let other = try XCTUnwrap(devices.connectReady())
        server.refusedAddress = other.address
        session.removeWireGuardDevice(peer.id)
        XCTAssertEqual(server.starts, [hotspot, hotspot], "tried again with the saved devices")
        XCTAssertFalse(server.running, "a removed device is never let in")
        XCTAssertEqual(session.wireGuardProblem, couldntStart)
        server.refusedAddress = nil
        session.syncWithHotspot()
        XCTAssertTrue(server.running)
        XCTAssertFalse(server.lastSetup?.serverPeers.contains(peer) ?? true, "the removed device isn't let in")
        XCTAssertNil(session.wireGuardProblem)
    }

    /// A list the server refuses while the saved devices can't be read stops it: starting it again
    /// would need that setup, and leaving it running with the old list could let in what the new one
    /// keeps out (#333).
    func testARefusedListWithTheDevicesUnreadableStopsTheServer() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        let peer = try XCTUnwrap(devices.connectReady())
        XCTAssertTrue(server.running)
        secrets.savesFail = true
        devices.reset()
        XCTAssertFalse(devices.loaded, "a reset that can't be saved leaves the devices unread")
        server.refusedAddress = peer.address
        session.dnsChanged()
        XCTAssertFalse(server.running, "stopped, not left with the list from before")
        XCTAssertEqual(server.starts, [hotspot], "not started again without the saved devices")
    }

    /// A retry of the next code that fails for another reason puts that reason in the log too (#190).
    func testEachReasonTheNextCodeCantBeSavedIsLogged() {
        var logged: [String] = []
        makeSession(log: { logged.append($0) })
        address = hotspot
        session.syncWithHotspot()
        secrets.savesFail = true
        session.openAddWindow()
        secrets.saveError = FlakySecrets.Full()
        session.syncWithHotspot()
        session.syncWithHotspot()
        XCTAssertEqual(logged.filter { $0.hasPrefix("WireGuard: the code for the next device can't be saved") },
                       ["WireGuard: the code for the next device can't be saved: Locked()",
                        "WireGuard: the code for the next device can't be saved: Full()"])
    }

    func testARenameThatCantBeSavedSaysSoUntilAChangeSaves() throws {
        makeSession()
        let peer = try XCTUnwrap(devices.connectReady())
        let other = try XCTUnwrap(devices.connectReady())
        secrets.savesFail = true
        session.renameWireGuardDevice(peer.id, to: "Kitchen iPad")
        XCTAssertEqual(session.wireGuardPeers.first?.name, peer.name, "the old name stays")
        XCTAssertEqual(session.wireGuardDeviceProblem,
                       HotspotSession.DeviceProblem(device: peer.id, text: "The new name couldn't be saved."))
        secrets.savesFail = false
        XCTAssertTrue(session.removeWireGuardDevice(other.id))
        XCTAssertNil(session.wireGuardDeviceProblem, "any change that saves clears it")
    }

    func testARemovalThatCantBeSavedSaysSoUntilAChangeSaves() throws {
        makeSession()
        let peer = try XCTUnwrap(devices.connectReady())
        secrets.savesFail = true
        XCTAssertFalse(session.removeWireGuardDevice(peer.id))
        XCTAssertEqual(session.wireGuardPeers.map(\.id), [peer.id], "the device stays")
        XCTAssertEqual(session.wireGuardDeviceProblem,
                       HotspotSession.DeviceProblem(device: peer.id, text: "The device couldn't be removed."))
        secrets.savesFail = false
        session.renameWireGuardDevice(peer.id, to: "Kitchen iPad")
        XCTAssertNil(session.wireGuardDeviceProblem)
        XCTAssertEqual(session.wireGuardPeers.first?.name, "Kitchen iPad")
    }

    func testABackgroundRoundClaimsTheReadyDevice() throws {
        makeSession()
        address = hotspot
        session.openAddWindow()
        session.leftScreen() // the sheet still open, the 10 minutes run from here
        session.watch()
        let ready = try XCTUnwrap(session.wireGuardReady)
        server.connected = [ready.address]
        session.watch()
        XCTAssertEqual(session.wireGuardPeers.map(\.address), [ready.address])
        XCTAssertNotNil(session.wireGuardReady)
        XCTAssertNotEqual(session.wireGuardReady?.address, ready.address, "a new code for the next device")
        XCTAssertEqual(server.lastSetup?.serverPeers.count, 2, "the server lets in the device and the new code")
    }

    func testOnScreenTheSamplerClaimsAndTheWatcherDoesnt() throws {
        makeSession(sceneActive: true)
        address = hotspot
        session.watch()
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        server.connected = [ready.address]
        session.watch()
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
        session.sampleTraffic()
        XCTAssertEqual(session.wireGuardPeers.map(\.address), [ready.address])
        XCTAssertEqual(session.wireGuardConnected, [ready.address])
    }

    func testTheShortcutReadsWhoIsConnectedNow() {
        makeSession(sceneActive: false)
        address = hotspot
        session.syncWithHotspot()
        server.connected = ["10.7.0.2", "10.7.0.3"]
        XCTAssertEqual(session.shortcutState(), ShortcutReply.State(running: true, connected: 2, problem: nil))
        sound.silent = true // iOS gave the keep-alive no sound
        XCTAssertFalse(session.shortcutState().sharing)
    }

    /// The notifications need who is connected in the background too, where the sampler doesn't run.
    func testABackgroundRoundReadsWhoIsConnected() {
        makeSession(sceneActive: false)
        address = hotspot
        session.watch()
        server.connected = ["10.7.0.2"]
        XCTAssertEqual(session.connectedNow, [], "the last round's read, not a new one")
        session.watch()
        XCTAssertEqual(session.connectedNow, ["10.7.0.2"])
        XCTAssertEqual(session.wireGuardConnected, [], "the screen's list waits for the sampler")
        address = nil
        session.watch()
        XCTAssertEqual(session.connectedNow, [], "nobody once the hotspot goes")
    }

    func testOnScreenWhoIsConnectedIsTheSamplers() {
        makeSession(sceneActive: true)
        address = hotspot
        session.watch()
        server.connected = ["10.7.0.2"]
        session.watch()
        XCTAssertEqual(session.connectedNow, [])
        session.sampleTraffic()
        XCTAssertEqual(session.connectedNow, ["10.7.0.2"])
    }

    /// Back on screen, the list starts from the last background read, not from before the app left,
    /// until the sampler's next read.
    func testComingBackOnScreenStartsFromTheLastBackgroundRead() {
        makeSession(sceneActive: false)
        address = hotspot
        server.connected = ["10.7.0.2"]
        session.watch()
        session.cameOnScreen()
        XCTAssertEqual(session.wireGuardConnected, ["10.7.0.2"])
        XCTAssertEqual(session.connectedNow, ["10.7.0.2"])
    }

    /// Until the first background round reads again, the screen's last list stands, not one from an earlier time away.
    func testLeavingTheScreenKeepsTheSamplersList() {
        makeSession(sceneActive: false)
        address = hotspot
        server.connected = ["10.7.0.3"]
        session.watch()
        session.cameOnScreen()
        server.connected = ["10.7.0.2"]
        session.sampleTraffic()
        session.leftScreen()
        XCTAssertEqual(session.connectedNow, ["10.7.0.2"])
    }

    // MARK: The config page

    func testThePageListensWhereTheServerDoes() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        XCTAssertEqual(page.starts, ["\(hotspot):80"])
        session.syncWithHotspot()
        XCTAssertEqual(page.starts.count, 1, "no restart while it runs")
        address = "172.20.10.3"
        session.syncWithHotspot()
        XCTAssertEqual(page.starts, ["\(hotspot):80", "172.20.10.3:80"], "a new address, a new page")
        address = nil
        session.syncWithHotspot()
        XCTAssertFalse(page.running)
    }

    /// Each failure is logged once, until the page listens again.
    func testAPageThatListensAgainLogsItsNextFailure() {
        var logged: [String] = []
        makeSession(log: { logged.append($0) })
        address = hotspot
        session.syncWithHotspot()
        page.fail()
        session.syncWithHotspot()
        page.fail()
        XCTAssertEqual(logged.filter { $0 == "config page: address in use" }.count, 1, "the same failure again")
        session.syncWithHotspot()
        page.becomeReady()
        page.fail()
        XCTAssertEqual(logged.filter { $0 == "config page: address in use" }.count, 2, "\(logged)")
    }

    func testAPageThatFailsIsStartedAgainNextRound() {
        var logged: [String] = []
        makeSession(log: { logged.append($0) })
        address = hotspot
        session.syncWithHotspot()
        page.becomeReady()
        page.fail()
        XCTAssertTrue(logged.contains("config page: address in use"), "\(logged)")
        XCTAssertTrue(server.running, "WireGuard goes on without it")
        XCTAssertNil(session.wireGuardProblem)
        session.syncWithHotspot()
        XCTAssertEqual(page.starts.count, 2)
    }

    func testNoPageWithoutTheServer() {
        makeSession(locked: true)
        address = hotspot
        session.syncWithHotspot()
        XCTAssertTrue(page.starts.isEmpty, "the keys are locked")
        secrets.failing = false
        server.startError = FakeServer.Failure()
        session.syncWithHotspot()
        XCTAssertTrue(page.starts.isEmpty, "the server didn't start")
        server.startError = nil
        session.syncWithHotspot()
        XCTAssertEqual(page.starts, ["\(hotspot):80"])
    }

    // MARK: The page through the tunnel (#27)

    /// The devices reach the iPhone's own addresses only for the config page, and only where its
    /// listener is ready: each address as it gets ready, not all once one is.
    func testThePageOpensThroughTheTunnelWhereItListens() {
        makeSession()
        let v6 = "2607:fb91:88a2:e822::a"
        address = v6
        session.syncWithHotspot()
        XCTAssertEqual(server.page, [], "not before a listener is ready")
        page.becomeReady([hotspot])
        XCTAssertEqual(server.page, [hotspot])
        page.becomeReady([hotspot, v6])
        XCTAssertEqual(server.page, [hotspot, v6])
    }

    /// Another app has port 80: Tether's page fails, WireGuard goes on, and the devices must not
    /// reach that app through the tunnel. Not on the next round's try either.
    func testAPageThatFailsStaysClosedThroughTheTunnel() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        page.fail()
        XCTAssertTrue(server.running)
        XCTAssertEqual(server.page, [])
        session.syncWithHotspot()
        page.fail()
        XCTAssertEqual(page.starts.count, 2)
        XCTAssertEqual(server.page, [])
        session.syncWithHotspot()
        page.becomeReady()
        page.fail()
        XCTAssertEqual(server.page, [], "it listened, then failed")
    }

    func testAPageThatStopsClosesThroughTheTunnel() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        page.becomeReady()
        XCTAssertEqual(server.page, [hotspot])
        page.stop()
        XCTAssertTrue(server.running)
        XCTAssertEqual(server.page, [])
    }

    /// A new WireGuard server opens the page nowhere, so it's opened again once the page listens again.
    func testARestartedServerOpensThePageAgain() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        page.becomeReady()
        server.stop() // as if it went away. The next round starts it again
        session.syncWithHotspot()
        XCTAssertEqual(server.starts.count, 2)
        XCTAssertEqual(server.page, [], "not before the page listens again")
        page.becomeReady()
        XCTAssertEqual(server.page, [hotspot])
    }

    private func body(_ response: ConfigPage.Response) -> String { String(decoding: response.body, as: UTF8.self) }

    /// A download is a device added: it's listed, and the next one gets a new key, so two devices never share one.
    func testOnScreenADownloadAddsTheDevice() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        XCTAssertTrue(body(page.ask(.page)).contains("href=\"\(ConfigPage.downloadPath)\""))
        let ready = try XCTUnwrap(session.wireGuardReady)
        let first = page.ask(.config)
        XCTAssertEqual(first.status, .ok)
        XCTAssertEqual(body(first), session.wireGuardConfig(for: ready))
        XCTAssertTrue(first.extraHeaders.contains("Content-Disposition: attachment; filename=\"Tether-Device.conf\""))
        XCTAssertEqual(session.wireGuardPeers.map(\.address), [ready.address])
        XCTAssertEqual(session.wireGuardPeers.map(\.name), ["Device"])
        let next = try XCTUnwrap(session.wireGuardReady)
        XCTAssertNotEqual(next.address, ready.address, "a new key for the next device")
        XCTAssertEqual(server.lastSetup?.serverPeers.map(\.address), [ready.address, next.address], "both let in")
        let second = page.ask(.config, from: "172.20.10.3")
        XCTAssertEqual(body(second), session.wireGuardConfig(for: next))
        XCTAssertNotEqual(body(second), body(first))
        XCTAssertTrue(second.extraHeaders.contains("Content-Disposition: attachment; filename=\"Tether-Device-2.conf\""))
    }

    func testTheDownloadedDeviceConnectingAddsNothingMore() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        _ = page.ask(.config)
        let next = session.wireGuardReady
        server.connected = [ready.address]
        session.sampleTraffic()
        XCTAssertEqual(session.wireGuardPeers.count, 1)
        XCTAssertEqual(session.wireGuardReady, next)
        XCTAssertEqual(session.wireGuardConnected, [ready.address])
    }

    /// The same as the QR code, which can only be seen while Tether is on screen.
    func testOffScreenThePageGivesNothing() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        session.leftScreen()
        let ready = session.wireGuardReady
        XCTAssertTrue(body(page.ask(.page)).contains("Open Tether on the iPhone"))
        let config = page.ask(.config)
        XCTAssertEqual(config.status, .notFound)
        XCTAssertFalse(body(config).contains("PrivateKey"))
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
        XCTAssertEqual(session.wireGuardReady, ready)
        session.cameOnScreen()
        XCTAssertEqual(page.ask(.config).status, .ok)
    }

    func testADownloadThatCantBeSavedGivesNothing() {
        var logged: [String] = []
        makeSession(log: { logged.append($0) })
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let ready = session.wireGuardReady
        secrets.savesFail = true
        let config = page.ask(.config)
        XCTAssertEqual(config.status, .unavailable)
        XCTAssertFalse(body(config).contains("PrivateKey"), "a key that isn't saved could never connect")
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
        XCTAssertEqual(session.wireGuardReady, ready)
        XCTAssertTrue(logged.contains("WireGuard: 172.20.10.2 asked for the config, but the new device couldn't be saved"), "\(logged)")
    }

    /// A browser or download manager that fetches twice gets the same config, and only one device is listed.
    func testTheSameDeviceAskingAgainSoonGetsTheSameConfig() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let first = page.ask(.config, from: "172.20.10.2")
        now = now.addingTimeInterval(ConfigPageHandler.repeatWithin - 1)
        XCTAssertEqual(page.ask(.configHead, from: "172.20.10.2"), first.forHead)
        XCTAssertEqual(page.ask(.config, from: "172.20.10.2"), first)
        XCTAssertEqual(session.wireGuardPeers.count, 1)
        let other = page.ask(.config, from: "172.20.10.3")
        XCTAssertNotEqual(other.body, first.body, "another device gets its own")
        now = now.addingTimeInterval(ConfigPageHandler.repeatWithin + 1)
        XCTAssertNotEqual(page.ask(.config, from: "172.20.10.3").body, other.body, "a few seconds later it's a new device")
        XCTAssertEqual(session.wireGuardPeers.count, 3)
    }

    func testARemovedDevicesConfigIsntHandedOutAgain() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let first = page.ask(.config)
        session.removeWireGuardDevice(try XCTUnwrap(session.wireGuardPeers.first).id)
        XCTAssertNotEqual(page.ask(.config).body, first.body)
    }

    func testAHeadAddsNoDevice() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let ready = session.wireGuardReady
        let head = page.ask(.configHead)
        XCTAssertEqual(head.status, .ok)
        XCTAssertTrue(head.headOnly)
        XCTAssertEqual(page.ask(.pageHead), ConfigPage.page(.ready, tunnel: .notConnected).forHead)
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
        XCTAssertEqual(session.wireGuardReady, ready)
        session.leftScreen()
        XCTAssertEqual(page.ask(.configHead).status, .notFound)
    }

    func testAPageThatFailsEveryRoundIsLoggedOnce() {
        var logged: [String] = []
        makeSession(log: { logged.append($0) })
        address = hotspot
        session.syncWithHotspot()
        for _ in 0..<3 {
            page.fail()
            session.syncWithHotspot()
        }
        XCTAssertEqual(logged.filter { $0.hasPrefix("config page:") }, ["config page: address in use"])
        XCTAssertEqual(page.starts.count, 4, "still tried each round")
    }

    func testOtherRequestsGetTheirErrors() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        XCTAssertEqual(page.ask(.notFound), ConfigPage.notFound)
        XCTAssertEqual(page.ask(.notGet), ConfigPage.notGet)
        XCTAssertEqual(page.ask(.malformed), ConfigPage.malformed)
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
    }

    // MARK: The add window

    /// The keys the server lets in now.
    private var letIn: [Data] { server.lastSetup?.serverPeers.map(\.publicKey) ?? [] }

    /// A photo of the QR code, or a .conf from days ago, connects only while Add a device is open (#29).
    func testAtLaunchTheCodeIsntLetIn() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        let ready = try XCTUnwrap(session.wireGuardReady)
        XCTAssertEqual(server.lastSetup?.serverPeers, [], "the devices only, and there are none yet")
        server.connected = [ready.address] // an old read, say: it can't have connected
        session.sampleTraffic()
        XCTAssertTrue(session.wireGuardPeers.isEmpty, "not listed")
        XCTAssertEqual(session.wireGuardReady, ready)
    }

    /// Each time Add a device opens after the window closed there's a new code, so a code from an
    /// earlier time never works again, after a relaunch too. It's saved before it's let in.
    func testOpeningAddADeviceLetsInANewCode() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        let before = try XCTUnwrap(session.wireGuardReady)
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        XCTAssertNotEqual(ready.publicKey, before.publicKey)
        XCTAssertEqual(server.lastSetup?.serverPeers, [ready.peer])
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.ready, ready, "saved")
    }

    func testTheCodeWorksTenMinutesAfterTheSheetClosesThenGoes() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        now = minutes(5)
        session.closeAddWindow()
        now = minutes(14.9)
        session.syncWithHotspot()
        XCTAssertEqual(letIn, [ready.publicKey])
        now = minutes(15)
        session.syncWithHotspot()
        XCTAssertEqual(letIn, [], "off the server")
        session.openAddWindow()
        let next = try XCTUnwrap(session.wireGuardReady)
        XCTAssertNotEqual(next.publicKey, ready.publicKey, "a new code replaces it")
        XCTAssertEqual(letIn, [next.publicKey])
    }

    /// The sampler checks too, every second on screen.
    func testOnScreenTheSamplerClosesTheWindow() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        session.closeAddWindow()
        now = minutes(10)
        session.sampleTraffic()
        XCTAssertEqual(letIn, [])
    }

    /// A device that scanned the code and isn't connected yet still can when the sheet opens again.
    func testReopeningWithinTheTenMinutesKeepsTheCode() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        session.closeAddWindow()
        now = minutes(9)
        session.openAddWindow()
        XCTAssertEqual(session.wireGuardReady, ready)
        XCTAssertEqual(letIn, [ready.publicKey])
    }

    /// A sheet left open in the background isn't on screen: the 10 minutes run from leaving it.
    func testLeavingTheScreenWithTheSheetOpenStartsTheTenMinutes() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        now = minutes(1)
        session.leftScreen()
        now = minutes(10.9)
        session.watch()
        XCTAssertEqual(letIn, [ready.publicKey])
        now = minutes(11)
        session.watch()
        XCTAssertEqual(letIn, [], "off the server")
        session.cameOnScreen() // the sheet still open
        let next = try XCTUnwrap(session.wireGuardReady)
        XCTAssertNotEqual(next.publicKey, ready.publicKey)
        XCTAssertEqual(letIn, [next.publicKey])
    }

    func testThePageHandsOutTheConfigOnlyWhileTheWindowIsOpen() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        XCTAssertEqual(page.ask(.page), ConfigPage.page(.openAddDevice, tunnel: .notConnected))
        let closed = page.ask(.config)
        XCTAssertEqual(closed.status, .notFound)
        XCTAssertFalse(body(closed).contains("PrivateKey"))
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
        session.openAddWindow()
        XCTAssertEqual(page.ask(.page), ConfigPage.page(.ready, tunnel: .notConnected))
        session.closeAddWindow()
        now = minutes(9.9)
        XCTAssertEqual(page.ask(.config, from: "172.20.10.3").status, .ok)
        now = minutes(10)
        let late = page.ask(.config, from: "172.20.10.4")
        XCTAssertEqual(late.status, .notFound, "by the clock, before the watcher's next round")
        XCTAssertFalse(body(late).contains("PrivateKey"))
        XCTAssertEqual(session.wireGuardPeers.count, 1)
    }

    func testAClaimedDeviceKeepsWorkingAfterTheWindowCloses() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        server.connected = [ready.address]
        session.sampleTraffic()
        XCTAssertEqual(session.wireGuardPeers.map(\.id), [ready.id])
        session.closeAddWindow()
        now = minutes(10)
        session.syncWithHotspot()
        XCTAssertEqual(letIn, [ready.publicKey], "the device, not the next code")
    }

    /// A device whose first handshake came after the last read, in the background where reads are
    /// 15 seconds apart, is listed as the window closes, not locked out.
    func testADeviceThatConnectedJustBeforeTheWindowClosesIsListed() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        session.leftScreen()
        session.watch()
        now = minutes(9.9)
        server.connected = [ready.address]
        server.handshakes = [ready.address: minutes(9.9)]
        now = minutes(10)
        session.watch()
        XCTAssertEqual(session.wireGuardPeers.map(\.id), [ready.id])
        XCTAssertEqual(letIn, [ready.publicKey], "the device, not the next code")
    }

    /// A handshake after the window ended, seen by the next round up to 20 s later, adds nothing: the
    /// code no longer works (#161).
    func testAHandshakeAfterTheWindowEndedIsntListed() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        session.leftScreen()
        session.watch()
        now = minutes(10.2)
        server.connected = [ready.address]
        server.handshakes = [ready.address: minutes(10.1)]
        session.watch()
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
        XCTAssertFalse(letIn.contains(ready.publicKey), "its code no longer works")
    }

    /// Handshake times are whole seconds. A window that ends at .25 s and a handshake at .75 s of the
    /// same second read as the same time, and the device isn't added (#161).
    func testAHandshakeInTheWindowsLastSecondIsntListed() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        now = minutes(0).addingTimeInterval(0.25)
        session.leftScreen()
        session.watch()
        now = minutes(10.2)
        server.connected = [ready.address]
        server.handshakes = [ready.address: minutes(10)] // 0.75 s after the end, cut to the second
        session.watch()
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
    }

    /// A new code that can't be saved leaves no code rather than the old one, and the old one stays
    /// off the server after a relaunch too, where the Keychain still has it.
    func testACodeThatCantBeReplacedIsntLetIn() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        let old = try XCTUnwrap(session.wireGuardReady)
        secrets.savesFail = true
        session.openAddWindow()
        XCTAssertNil(session.wireGuardReady)
        XCTAssertNotNil(session.wireGuardReadyProblem)
        XCTAssertEqual(letIn, [])
        session.syncWithHotspot() // tries again
        XCTAssertEqual(letIn, [])
        XCTAssertEqual(page.ask(.config).status, .notFound)

        let relaunched = FakeServer()
        let again = HotspotSession(devices: WireGuardDevices(secrets: secrets), server: relaunched, keepAlive: FakeSound(),
                                   page: FakePage(), sceneActive: true, hotspotAddress: { [unowned self] in address },
                                   now: { [unowned self] in now })
        again.syncWithHotspot()
        XCTAssertEqual(again.wireGuardReady, old, "still the saved one")
        XCTAssertEqual(relaunched.lastSetup?.serverPeers, [])
        again.openAddWindow()
        XCTAssertEqual(relaunched.lastSetup?.serverPeers, [])
        secrets.savesFail = false
        again.syncWithHotspot()
        let next = try XCTUnwrap(again.wireGuardReady)
        XCTAssertNotEqual(next.publicKey, old.publicKey)
        XCTAssertEqual(relaunched.lastSetup?.serverPeers, [next.peer], "a new one, once it's saved")
    }

    // MARK: The keep-alive sound

    /// One watcher round at `minute`: on screen or not, the hotspot, and whether the sound plays after it.
    private struct SoundRound {
        var minute: Double
        var onScreen: Bool
        var hotspot = false
        var wake = false
        /// A call, Siri or an alarm holds the audio.
        var call = false
        /// One came and went since the last round, with no round in between.
        var callEnded = false
        /// CallKit has a call on, while the sound plays again.
        var callOn = false
        var plays: Bool
        var line: UInt = #line
    }

    private func run(_ rounds: [SoundRound]) {
        makeSession(sceneActive: rounds.first?.onScreen ?? true)
        for round in rounds {
            now = minutes(round.minute)
            address = round.hotspot ? hotspot : nil
            session.sceneActive = round.onScreen
            sound.interrupted = round.call
            sound.interruptedSinceTaken = round.callEnded
            session.callOn = { round.callOn }
            if round.wake { session.wake() } else { session.syncWithHotspot() }
            XCTAssertEqual(sound.playing, round.plays, line: round.line)
        }
    }

    func testOnScreenTheSoundNeverStops() {
        run([
            SoundRound(minute: 0, onScreen: true, plays: true),
            SoundRound(minute: 30, onScreen: true, plays: true),
            // The 10 minutes run from the last round on screen.
            SoundRound(minute: 35, onScreen: false, plays: true),
            SoundRound(minute: 39.9, onScreen: false, plays: true),
            SoundRound(minute: 40, onScreen: false, plays: false),
        ])
    }

    func testABackgroundLaunchDoesntPlayUntilWoken() {
        run([
            SoundRound(minute: 0, onScreen: false, plays: false), // "Is Tether Sharing?" only reports
            SoundRound(minute: 1, onScreen: false, wake: true, plays: true), // Start Tether
            SoundRound(minute: 10.9, onScreen: false, plays: true),
            SoundRound(minute: 11, onScreen: false, plays: false),
            SoundRound(minute: 12, onScreen: false, wake: true, plays: true), // a stopped wait starts again
        ])
    }

    func testTheSoundPlaysTenMinutesAfterTheHotspotGoes() {
        run([
            SoundRound(minute: 0, onScreen: false, hotspot: true, plays: true), // a launch with the hotspot on
            SoundRound(minute: 60, onScreen: false, hotspot: true, plays: true),
            SoundRound(minute: 61, onScreen: false, plays: true),
            SoundRound(minute: 70.9, onScreen: false, plays: true),
            SoundRound(minute: 71, onScreen: false, plays: false),
            SoundRound(minute: 80, onScreen: false, hotspot: true, plays: true), // the hotspot back, a device joined
        ])
    }

    /// A call can take the hotspot away for as long as it lasts. The 10 minutes run from the call's
    /// end, so a long call doesn't leave Tether suspended, with its devices cut off until someone
    /// opens it (#191).
    func testTheTenMinutesRunFromTheEndOfACall() {
        run([
            SoundRound(minute: 0, onScreen: false, hotspot: true, plays: true),
            SoundRound(minute: 1, onScreen: false, call: true, plays: true), // the call takes the hotspot
            SoundRound(minute: 20, onScreen: false, call: true, plays: true),
            SoundRound(minute: 21, onScreen: false, plays: true), // the call is over, no device back yet
            SoundRound(minute: 29.9, onScreen: false, plays: true), // 10 minutes from the last round in the call
            SoundRound(minute: 30, onScreen: false, plays: false),
        ])
    }

    /// The sound plays again right after a call starts, so it no longer says a call is on. CallKit
    /// still does, and the 10 minutes run from the call's end all the same (#191).
    func testTheTenMinutesRunFromTheEndOfACallWithTheSoundBack() {
        run([
            SoundRound(minute: 0, onScreen: false, hotspot: true, plays: true),
            SoundRound(minute: 1, onScreen: false, callOn: true, plays: true), // the call takes the hotspot
            SoundRound(minute: 20, onScreen: false, callOn: true, plays: true),
            SoundRound(minute: 21, onScreen: false, plays: true), // the call is over, no device back yet
            SoundRound(minute: 29.9, onScreen: false, plays: true), // 10 minutes from the last round in the call
            SoundRound(minute: 30, onScreen: false, plays: false),
        ])
    }

    /// "Is Tether Sharing?" during a call only reports. The call keeps a sound that plays going, it
    /// doesn't start one.
    func testACallDoesntStartTheSoundOnABackgroundLaunch() {
        run([
            SoundRound(minute: 0, onScreen: false, callOn: true, plays: false),
            SoundRound(minute: 1, onScreen: false, callOn: true, plays: false),
        ])
    }

    /// A call that started and ended with no watcher round in between, while iOS held Tether back
    /// say, still counts: the 10 minutes run from the first round after it.
    func testACallBetweenTwoRoundsStillCounts() {
        run([
            SoundRound(minute: 0, onScreen: false, hotspot: true, plays: true),
            SoundRound(minute: 1, onScreen: false, plays: true), // the hotspot goes
            SoundRound(minute: 30, onScreen: false, callEnded: true, plays: true),
            SoundRound(minute: 39.9, onScreen: false, plays: true),
            SoundRound(minute: 40, onScreen: false, plays: false),
        ])
    }

    func testOpeningTetherStartsTheWaitAgain() {
        makeSession(sceneActive: false)
        session.syncWithHotspot()
        XCTAssertFalse(sound.playing, "a background launch only reports")
        now = minutes(1)
        session.cameOnScreen()
        XCTAssertTrue(sound.playing)
        now = minutes(2)
        session.leftScreen()
        session.syncWithHotspot()
        now = minutes(10.9)
        session.syncWithHotspot()
        XCTAssertTrue(sound.playing)
        now = minutes(11)
        session.syncWithHotspot()
        XCTAssertFalse(sound.playing, "10 minutes from the last round on screen")
    }

    func testWakeSaysWhetherTheSoundIsMade() {
        makeSession(sceneActive: false)
        XCTAssertTrue(session.wake())
        sound.silent = true // iOS refused the audio session, in the background say
        XCTAssertFalse(session.wake())
    }

    // MARK: Stopping when idle (#76)

    /// Start Tether in the background, with the hotspot on, then a watcher round.
    private func shareInTheBackground() {
        makeSession(sceneActive: false)
        address = hotspot
        session.wake()
        session.watch()
    }

    /// An idle stop takes the name down in the same round: iOS may suspend Tether before the next.
    func testAnIdleStopTakesTheNameDown() {
        names = FakeHostName()
        idleAfter = .tenMinutes
        makeSession(sceneActive: false)
        let a = "2607:fb91:88a2:e822::a"
        address = a
        session.wake()
        session.watch()
        XCTAssertEqual(names?.changes, ["\(name()) \(a)"])
        now = minutes(10)
        session.watch()
        XCTAssertFalse(server.running)
        XCTAssertEqual(names?.changes.last, "\(name()) -", "withdrawn with WireGuard")
    }

    func testSharingStopsAfterTheIdleTimeInTheBackground() {
        idleAfter = .tenMinutes
        shareInTheBackground()
        now = minutes(9.9)
        session.watch()
        XCTAssertTrue(session.sharing)
        now = minutes(10)
        session.watch()
        XCTAssertFalse(session.sharing)
        XCTAssertFalse(server.running)
        XCTAssertFalse(page.running)
        XCTAssertFalse(sound.playing, "so iOS suspends Tether and the battery is spared")
        XCTAssertEqual(session.idleStopped, IdleStopped(at: minutes(10), after: .tenMinutes))
        XCTAssertFalse(session.shortcutState().running, "Is Tether Sharing? says no")
        XCTAssertTrue(session.shortcutState().idleStopped, "and why")
        // The hotspot is still on, but it stays stopped.
        now = minutes(20)
        session.watch()
        XCTAssertFalse(server.running)
        XCTAssertFalse(sound.playing)
    }

    func testOpeningTetherSharesAgain() {
        idleAfter = .tenMinutes
        shareInTheBackground()
        now = minutes(10)
        session.watch()
        session.cameOnScreen()
        XCTAssertNil(session.idleStopped)
        XCTAssertTrue(session.sharing)
        XCTAssertTrue(server.running)
        XCTAssertTrue(sound.playing)
    }

    // MARK: Only share through a VPN

    /// With the switch on, no device gets through while no VPN carries the internet, and all do again
    /// as they were once one does. Nothing saved changes.
    func testOnlyThroughAVPNLetsNoDeviceThroughWithoutOne() throws {
        var saved = WireGuardSetup.new()
        let ipad = try XCTUnwrap(saved.addPeer(name: "iPad"))
        makeSession(saved: saved)
        address = hotspot
        session.syncWithHotspot()
        XCTAssertEqual(server.lastSetup?.serverPeers.first { $0.id == ipad.id }?.paused, nil, "off: let through")

        onlyThroughVPN = true
        session.checkVPN()
        XCTAssertTrue(session.blockedWithoutVPN)
        XCTAssertNotNil(server.lastSetup?.serverPeers.first { $0.id == ipad.id }?.paused, "no VPN: kept out")
        XCTAssertNil(devices.setup.peers.first { $0.id == ipad.id }?.paused, "the saved device isn't paused")
        XCTAssertTrue(session.shortcutState().blockedWithoutVPN)
        server.connected = [ipad.address]
        session.sampleTraffic()
        XCTAssertEqual(session.connectedNow, [ipad.address], "kept out, but there, and through by itself once a VPN is on")

        vpn = "utun5"
        session.checkVPN()
        XCTAssertFalse(session.blockedWithoutVPN)
        XCTAssertEqual(session.vpnInterface, "utun5")
        XCTAssertNil(server.lastSetup?.serverPeers.first { $0.id == ipad.id }?.paused, "a VPN: let through again")
        session.sampleTraffic()
        XCTAssertEqual(session.connectedNow, [ipad.address])
    }

    /// Turning the switch on while a VPN is already on ends what the devices and the proxy have open:
    /// it may have opened before the VPN came up, and iOS keeps a connection where it opened. Pausing
    /// everything for a moment closes it, as a VPN that goes does, then all get through again.
    func testTurningTheSwitchOnEndsConnectionsOpenedBeforeTheVPN() throws {
        var saved = WireGuardSetup.new()
        let ipad = try XCTUnwrap(saved.addPeer(name: "iPad"))
        makeSession(saved: saved)
        address = hotspot
        session.syncWithHotspot()
        XCTAssertTrue(session.setProxy(on: true))
        let before = server.setups.count
        vpn = "utun5"
        session.checkVPN()
        XCTAssertEqual(server.setups.count, before, "switch off: a VPN changes nothing")

        onlyThroughVPN = true
        session.checkVPN()
        XCTAssertFalse(session.blockedWithoutVPN)
        let changes = server.setups.dropFirst(before)
        XCTAssertEqual(changes.count, 2, "paused, then let through again")
        XCTAssertNotNil(changes.first?.serverPeers.first { $0.id == ipad.id }?.paused)
        XCTAssertNotNil(changes.first?.proxy?.paused)
        XCTAssertNil(server.lastSetup?.serverPeers.first { $0.id == ipad.id }?.paused)
        XCTAssertNil(server.lastSetup?.proxy?.paused)

        session.checkVPN()
        XCTAssertEqual(server.setups.count, before + 2, "only when it's turned on")
    }

    /// A start while there's no VPN starts with every device kept out, not let through for a round.
    func testAStartWithoutAVPNKeepsTheDevicesOutFromTheStart() throws {
        var saved = WireGuardSetup.new()
        _ = try XCTUnwrap(saved.addPeer(name: "iPad"))
        onlyThroughVPN = true
        makeSession(saved: saved)
        address = hotspot
        session.syncWithHotspot()
        XCTAssertTrue(server.running)
        XCTAssertEqual(server.lastSetup?.serverPeers.allSatisfy { $0.paused != nil }, true)
    }

    /// A device added while there's no VPN connects, paused, and isn't taken for one whose config no
    /// longer works: the code's key stays on the server.
    func testTheCodeStillWorksWithoutAVPNButLetsNothingThrough() throws {
        onlyThroughVPN = true
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.openAddWindow()
        let ready = try XCTUnwrap(devices.setup.ready)
        let onServer = try XCTUnwrap(server.lastSetup?.serverPeers.first { $0.id == ready.peer.id }, "the code's key is let in")
        XCTAssertNotNil(onServer.paused, "but nothing gets through")
        XCTAssertNil(devices.setup.ready?.paused, "the saved code isn't paused")

        vpn = "utun5"
        session.checkVPN()
        XCTAssertNil(server.lastSetup?.serverPeers.first { $0.id == ready.peer.id }?.paused)
    }

    /// Devices kept out for want of a VPN are still there, so the idle stop waits for them, and they
    /// get through by themselves once a VPN is on.
    func testDevicesKeptOutWithoutAVPNHoldOffTheIdleStop() {
        idleAfter = .tenMinutes
        onlyThroughVPN = true
        shareInTheBackground()
        server.connected = ["10.7.0.2"]
        now = minutes(5)
        session.watch()
        now = minutes(30)
        session.watch()
        XCTAssertTrue(session.sharing)
        XCTAssertNil(session.idleStopped)
    }

    /// A device paused for a set time with its tunnel up comes back when the time is up (#312), so the
    /// idle stop waits for it as for a connected one. Paused until resumed, it doesn't.
    func testADevicePausedForATimeHoldsOffTheIdleStop() throws {
        idleAfter = .tenMinutes
        shareInTheBackground()
        let ipad = try XCTUnwrap(devices.connectReady())
        server.connected = [ipad.address]
        session.watch()
        session.pauseWireGuardDevice(ipad.id, for: .halfHour)
        for m in [5.0, 15, 29] {
            now = minutes(m)
            session.watch()
            XCTAssertTrue(session.sharing, "at \(m) minutes")
        }
        now = minutes(30)
        session.watch()
        XCTAssertNil(devices.setup.peers.first { $0.id == ipad.id }?.paused, "the time is up")
        XCTAssertTrue(session.sharing)
        XCTAssertTrue(server.running)

        session.pauseWireGuardDevice(ipad.id)
        now = minutes(40)
        session.watch()
        now = minutes(50)
        session.watch()
        XCTAssertFalse(session.sharing, "paused until resumed, it isn't coming back by itself")
    }

    /// The proxy paused for a set time comes back when the time is up too, so it holds off the idle
    /// stop until then, with only devices on the proxy and no tunnel up.
    func testTheProxyPausedForATimeHoldsOffTheIdleStop() throws {
        idleAfter = .tenMinutes
        shareInTheBackground()
        XCTAssertTrue(session.setProxy(on: true))
        let proxy = try XCTUnwrap(devices.setup.proxy?.id)
        session.pauseWireGuardDevice(proxy, for: .halfHour)
        for m in [5.0, 15, 29] {
            now = minutes(m)
            session.watch()
            XCTAssertTrue(session.sharing, "at \(m) minutes")
        }
        now = minutes(30)
        session.watch()
        XCTAssertNil(devices.setup.proxy?.paused, "the time is up")
        XCTAssertTrue(session.sharing)
    }

    /// After a stop nobody is connected, also once a pause or a resume publishes the list again.
    func testAResumeAfterAStopConnectsNobody() throws {
        idleAfter = .tenMinutes
        shareInTheBackground()
        let ipad = try XCTUnwrap(devices.connectReady())
        server.connected = [ipad.address]
        session.pauseWireGuardDevice(ipad.id)
        session.watch()
        now = minutes(10)
        session.watch()
        XCTAssertFalse(session.sharing, "a device paused by you holds nothing off")
        session.resumeWireGuardDevice(ipad.id)
        XCTAssertEqual(session.connectedNow, [])
        XCTAssertEqual(session.wireGuardConnected, [])
    }

    /// A timed pause that ends in the round the idle time runs out: the device is back in that round,
    /// so nothing stops.
    func testATimedPauseEndingAtTheIdleDeadlineCountsInThatRound() throws {
        idleAfter = .thirtyMinutes
        shareInTheBackground()
        let ipad = try XCTUnwrap(devices.connectReady())
        session.pauseWireGuardDevice(ipad.id, for: .halfHour)
        now = minutes(1)
        session.watch() // no tunnel up, so the idle time starts
        now = minutes(31)
        server.connected = [ipad.address]
        session.watch()
        XCTAssertNil(devices.setup.peers.first { $0.id == ipad.id }?.paused)
        XCTAssertTrue(session.sharing)
        XCTAssertNil(session.idleStopped)
    }

    /// Over its limit when its time is up, a timed pause becomes paused at the limit in one save, not a
    /// resume and then a pause, where a second save that failed let the device through.
    func testATimedPauseOverItsLimitIsPausedAtTheLimitInOneSave() throws {
        shareInTheBackground()
        let ipad = try XCTUnwrap(devices.connectReady())
        server.connected = [ipad.address]
        XCTAssertTrue(session.setLimit(ipad.id, 1_000))
        session.pauseWireGuardDevice(ipad.id, for: .halfHour)
        server.peerTraffic = [ipad.address: TrafficTotals(bytesUp: 0, bytesDown: 2_000)]
        session.watch()
        now = minutes(30)
        secrets.savesLeft = 1 // one save works, as the resume alone did, and the next fails
        session.watch()
        XCTAssertEqual(devices.setup.peers.first { $0.id == ipad.id }?.paused, .atLimit, "one save, straight to the limit")
        XCTAssertNotNil(server.lastSetup?.serverPeers.first { $0.id == ipad.id }?.paused, "Go keeps it out")
    }

    /// A tunnel for one family while the other goes around it: the devices stay out, and the session
    /// says which family the tunnel carries, for the screen (#334).
    func testAVPNForOneFamilyKeepsTheDevicesOutAndSaysWhich() {
        onlyThroughVPN = true
        onlyFamily = .ipv4
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        XCTAssertTrue(session.blockedWithoutVPN)
        XCTAssertNil(session.vpnInterface)
        XCTAssertEqual(session.vpnOnlyFamily, .ipv4)
        onlyFamily = nil
        vpn = "utun5"
        session.checkVPN()
        XCTAssertFalse(session.blockedWithoutVPN)
        XCTAssertNil(session.vpnOnlyFamily, "a VPN for both: nothing to say")
    }

    /// Off screen with the switch off, a round doesn't read the routes again: `Model` hears of a
    /// change from the system. With it on, each round does.
    func testARoundReadsTheVPNOnlyWhenItCounts() {
        makeSession(sceneActive: false)
        address = hotspot
        session.watch()
        XCTAssertNil(session.vpnInterface)
        vpn = "utun5"
        session.watch()
        XCTAssertNil(session.vpnInterface, "not read again")
        onlyThroughVPN = true
        session.watch()
        XCTAssertEqual(session.vpnInterface, "utun5")
    }

    /// The proxy carries for devices without WireGuard, so it's kept out the same way.
    func testOnlyThroughAVPNPausesTheProxyWithoutOne() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        XCTAssertTrue(session.setProxy(on: true))
        XCTAssertNil(server.lastSetup?.proxy?.paused, "off: it carries")

        onlyThroughVPN = true
        session.checkVPN()
        XCTAssertNotNil(server.lastSetup?.proxy?.paused, "no VPN: paused")
        XCTAssertNil(devices.setup.proxy?.paused, "the saved proxy isn't paused")

        vpn = "utun5"
        session.checkVPN()
        XCTAssertNil(server.lastSetup?.proxy?.paused, "a VPN: it carries again")
    }

    /// Stop on a widget stops at once, stays stopped with the hotspot on, and tells nothing.
    func testStopFromAWidgetStopsUntilStartTether() {
        shareInTheBackground()
        XCTAssertTrue(session.awake)
        XCTAssertTrue(session.stopNow(), "it was sharing")
        XCTAssertFalse(session.sharing)
        XCTAssertFalse(server.running)
        XCTAssertFalse(sound.playing, "so iOS suspends Tether")
        XCTAssertFalse(session.awake)
        XCTAssertFalse(session.up)
        XCTAssertEqual(session.idleStopped?.byYou, true)
        XCTAssertTrue(session.shortcutState().stoppedByYou)
        now = minutes(5)
        session.watch()
        XCTAssertFalse(server.running, "the hotspot is still on, but it stays stopped")
        XCTAssertFalse(session.stopNow(), "stopping again changes nothing")
        XCTAssertTrue(session.wake())
        XCTAssertTrue(server.running)
        XCTAssertTrue(session.awake)
        XCTAssertFalse(session.shortcutState().stoppedByYou)
    }

    /// The widgets are told right after a Stop, with no round in between, so nobody is listed as
    /// connected to the stopped server.
    func testAStopLeavesNobodyConnected() throws {
        var saved = WireGuardSetup.new()
        let ipad = try XCTUnwrap(saved.addPeer(name: "iPad"))
        makeSession(sceneActive: false, saved: saved)
        server.connected = [ipad.address]
        address = hotspot
        session.wake()
        session.watch()
        XCTAssertEqual(session.connectedPeers.map(\.id), [ipad.id])
        XCTAssertTrue(session.stopNow())
        XCTAssertEqual(session.connectedPeers.map(\.id), [])
        XCTAssertEqual(session.connectedNow, [])
    }

    /// The Live Activity lasts through a call, which takes the sound for a while.
    func testTetherIsUpWhileTheSoundIsSilent() {
        makeSession(sceneActive: false)
        sound.silent = true
        address = hotspot
        session.wake()
        session.watch()
        XCTAssertFalse(session.awake, "the widgets don't say Sharing")
        XCTAssertTrue(session.up, "but nothing stopped it")
    }

    /// On screen nothing stops Tether but the hotspot, and opening it is what starts it again, so a
    /// Stop from Control Center over the open app does nothing.
    func testStopFromAWidgetDoesNothingWhileTetherIsOnScreen() {
        makeSession(sceneActive: true)
        address = hotspot
        session.syncWithHotspot()
        XCTAssertFalse(session.stopNow())
        XCTAssertTrue(session.sharing)
        XCTAssertNil(session.idleStopped)
        XCTAssertTrue(session.awake)
    }

    /// The sound didn't start, so iOS suspends Tether soon (#164): the widgets mustn't say it shares.
    func testTheWidgetsAreNotToldSharingWhenTetherCantKeepRunning() {
        makeSession(sceneActive: false)
        sound.silent = true
        address = hotspot
        session.wake()
        session.watch()
        XCTAssertTrue(session.sharing, "the server runs for now")
        XCTAssertFalse(session.staysRunning)
        XCTAssertFalse(session.awake)
        session.cameOnScreen()
        XCTAssertTrue(session.staysRunning, "on screen it runs whatever the sound does")
        XCTAssertTrue(session.awake)
    }

    /// The widgets list the connected devices in the list's order, and two with one name stay two.
    func testTheWidgetsGetTheConnectedDevices() throws {
        var saved = WireGuardSetup.new()
        let first = try XCTUnwrap(saved.addPeer(name: "iPhone"))
        let second = try XCTUnwrap(saved.addPeer(name: "iPhone"))
        _ = try XCTUnwrap(saved.addPeer(name: "iPad"))
        makeSession(saved: saved)
        server.connected = [second.address, first.address]
        address = hotspot
        session.syncWithHotspot()
        session.sampleTraffic()
        XCTAssertEqual(session.connectedPeers.map(\.id), [first.id, second.id])
    }

    func testStartTetherSharesAgain() {
        idleAfter = .tenMinutes
        shareInTheBackground()
        now = minutes(10)
        session.watch()
        XCTAssertTrue(session.wake())
        XCTAssertNil(session.idleStopped)
        XCTAssertTrue(server.running)
        XCTAssertFalse(session.shortcutState().idleStopped)
    }

    /// Woken right after a stop, before any round saw sharing off, it still stops again later.
    func testItStopsAgainAfterSharingAgain() {
        idleAfter = .tenMinutes
        shareInTheBackground()
        now = minutes(10)
        session.watch()
        now = minutes(11)
        session.wake()
        session.watch()
        now = minutes(20.9)
        session.watch()
        XCTAssertTrue(session.sharing)
        now = minutes(21)
        session.watch()
        XCTAssertFalse(session.sharing)
        XCTAssertEqual(session.idleStopped, IdleStopped(at: minutes(21), after: .tenMinutes))
    }

    func testAConnectedDeviceKeepsItSharing() {
        idleAfter = .tenMinutes
        shareInTheBackground()
        server.connected = ["10.7.0.2"]
        now = minutes(5)
        session.watch()
        now = minutes(60)
        session.watch()
        XCTAssertTrue(session.sharing)
        server.connected = []
        session.watch()
        now = minutes(69.9)
        session.watch()
        XCTAssertTrue(session.sharing)
        now = minutes(70)
        session.watch()
        XCTAssertFalse(session.sharing)
    }

    func testNeverStopsByDefault() {
        shareInTheBackground()
        now = minutes(24 * 60)
        session.watch()
        XCTAssertTrue(session.sharing)
        XCTAssertNil(session.idleStopped)
    }

    func testOnScreenItNeverStops() {
        idleAfter = .tenMinutes
        makeSession(sceneActive: true)
        address = hotspot
        session.watch()
        now = minutes(60)
        session.watch()
        XCTAssertTrue(session.sharing)
    }

    // MARK: What the screen sees

    /// Model relies on this to redraw, as `@Published` would: each change is announced while the old value is still there.
    func testEveryChangeIsAnnouncedBeforeItHappens() throws {
        makeSession(locked: true)
        session.openAddWindow()
        var announced: [String] = []
        session.willChange = { [unowned self] in
            announced.append("\(session.running) \(session.wireGuardProblem ?? "-") \(session.wireGuardPeers.count)")
        }
        address = hotspot
        session.syncWithHotspot()
        XCTAssertEqual(announced.last, "false \(locked) 0", "running")
        secrets.failing = false
        announced = []
        session.syncWithHotspot()
        XCTAssertTrue(announced.contains("true \(locked) 0"), "the problem going")
        server.connected = [try XCTUnwrap(session.wireGuardReady).address]
        session.sampleTraffic() // claims it
        let peer = try XCTUnwrap(session.wireGuardPeers.first)
        announced = []
        session.removeWireGuardDevice(peer.id)
        XCTAssertTrue(announced.contains("true - 1"), "the devices")
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
        // The speeds, the connected devices and their stats change with a sample, each announced.
        announced = []
        now = now.addingTimeInterval(1)
        server.totals = TrafficTotals(bytesUp: 1000, bytesDown: 1000)
        server.connected = ["10.7.0.99"] // nobody's, so nothing else changes
        session.sampleTraffic()
        XCTAssertEqual(announced.count, 4, "down, up, the connected devices and their stats")
    }

    // MARK: Speeds

    func testSpeedHistoryKeepsThirtySecondsIncludingUnchangedAndIdleReadings() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.sampleTraffic()
        XCTAssertTrue(session.speedHistory.samples.isEmpty, "the baseline isn't a speed reading")
        for second in 1...45 {
            now = start.addingTimeInterval(Double(second))
            server.totals = TrafficTotals(bytesUp: UInt64(second * 125), bytesDown: UInt64(second * 250))
            session.sampleTraffic()
        }
        XCTAssertEqual(session.speedHistory.samples.count, 31)
        XCTAssertEqual(session.speedHistory.samples.first?.at, start.addingTimeInterval(15))
        XCTAssertTrue(session.speedHistory.samples.allSatisfy { $0.up == 1000 && $0.down == 2000 })
        now = now.addingTimeInterval(1)
        session.sampleTraffic()
        XCTAssertEqual(session.speedHistory.samples.last?.up, 0)
        XCTAssertEqual(session.speedHistory.samples.last?.down, 0)
        now = now.addingTimeInterval(40)
        session.sampleTraffic()
        XCTAssertEqual(session.speedHistory.samples.count, 1, "a delayed sample prunes by elapsed time too")
    }

    func testSpeedHistoryClearsAcrossBackgroundAndHotspotRestart() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.sampleTraffic()
        now = now.addingTimeInterval(1)
        session.sampleTraffic()
        XCTAssertFalse(session.speedHistory.samples.isEmpty)
        session.leftScreen()
        XCTAssertTrue(session.speedHistory.samples.isEmpty)
        now = now.addingTimeInterval(600)
        session.cameOnScreen()
        session.sampleTraffic()
        XCTAssertTrue(session.speedHistory.samples.isEmpty, "returning establishes a fresh baseline")
        now = now.addingTimeInterval(1)
        session.sampleTraffic()
        XCTAssertEqual(session.speedHistory.samples.count, 1)
        address = "172.20.10.3"
        session.syncWithHotspot()
        XCTAssertTrue(session.speedHistory.samples.isEmpty)
        session.sampleTraffic()
        now = now.addingTimeInterval(1)
        session.sampleTraffic()
        address = nil
        session.syncWithHotspot()
        session.sampleTraffic()
        XCTAssertTrue(session.speedHistory.samples.isEmpty)
    }

    // MARK: A config that no longer works

    /// A device knocking with a config that no longer works shows for a minute after its last
    /// handshake (#89). It keeps trying every 5 s while it has something to send, so a minute is
    /// "it's still trying", and once it gives up the line goes.
    func testAStaleConfigShowsForAMinuteAfterItKnocks() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.sampleTraffic()
        XCTAssertFalse(session.showsStaleConfig)
        server.stale = StaleConfig(kind: .device, at: now)
        session.sampleTraffic()
        XCTAssertEqual(session.staleConfig, StaleConfig(kind: .device, at: now))
        XCTAssertTrue(session.showsStaleConfig)
        now = now.addingTimeInterval(59)
        XCTAssertTrue(session.showsStaleConfig)
        now = now.addingTimeInterval(1)
        XCTAssertFalse(session.showsStaleConfig, "a minute with no knock")
        // Another knock brings it back.
        server.stale = StaleConfig(kind: .server, at: now)
        session.sampleTraffic()
        XCTAssertTrue(session.showsStaleConfig)
    }

    /// A stopped server knows of no knock, and its last one goes with it.
    func testAStaleConfigGoesWithTheHotspot() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        server.stale = StaleConfig(kind: .device, at: now)
        session.sampleTraffic()
        XCTAssertTrue(session.showsStaleConfig)
        address = nil
        session.syncWithHotspot()
        session.sampleTraffic()
        XCTAssertNil(session.staleConfig)
        XCTAssertFalse(session.showsStaleConfig)
    }

    /// The page reads the knock when it's asked (#63): off screen, nothing keeps it between reads.
    func testThePageReadsAKnockWhenItsAsked() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        session.leftScreen()
        server.stale = StaleConfig(kind: .device, at: now, from: "172.20.10.3:51820")
        XCTAssertTrue(body(page.ask(.page, from: "172.20.10.3")).contains("This device's config no longer works."))
        XCTAssertFalse(body(page.ask(.page, from: "172.20.10.4")).contains("no longer works"))
        // Another device knocked since: each one's page still tells it.
        server.earlierStale = [StaleConfig(kind: .device, at: now, from: "172.20.10.3:51820")]
        server.stale = StaleConfig(kind: .device, at: now, from: "172.20.10.4:51820")
        XCTAssertTrue(body(page.ask(.page, from: "172.20.10.3")).contains("This device's config no longer works."))
        XCTAssertTrue(body(page.ask(.page, from: "172.20.10.4")).contains("This device's config no longer works."))
        server.earlierStale = []
        server.stale = StaleConfig(kind: .server, at: now)
        XCTAssertTrue(body(page.ask(.page, from: "172.20.10.4")).contains("A device here has an old config."))
        XCTAssertFalse(body(page.ask(.page, from: hotspot)).contains("old config"), "it came through a tunnel that works")
    }

    /// The page says a device is connected when it asks from where a device whose tunnel is live
    /// connects from (#63): its WireGuard sends the page's address around the tunnel. Live is an
    /// unpaused device that sent anything in the last minute, keepalives too, see `PeerActivity`.
    func testThePageSaysWhetherThisDeviceIsConnected() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        let ipad = try XCTUnwrap(devices.connectReady())
        let laptop = try XCTUnwrap(devices.connectReady())
        // Both behind one travel router: one address for both.
        server.connected = [ipad.address, laptop.address]
        server.endpoints = [ipad.address: "172.20.10.3:51820", laptop.address: "172.20.10.3:51821"]
        server.received = [ipad.address: 100, laptop.address: 100]
        session.sampleTraffic()
        let connected = "This device is connected to Tether."
        let notConnected = "This device isn't connected to Tether."
        XCTAssertTrue(body(page.ask(.page, from: "172.20.10.3")).contains(notConnected), "a count read once says nothing of when it went up")
        now = now.addingTimeInterval(10)
        server.received[ipad.address] = 132
        session.sampleTraffic()
        XCTAssertTrue(body(page.ask(.page, from: "172.20.10.3")).contains(connected), "one live device at that address is enough")
        XCTAssertTrue(body(page.ask(.page, from: hotspot)).contains(connected), "through a tunnel or the proxy")
        XCTAssertTrue(body(page.ask(.page, from: "172.20.10.4")).contains(notConnected))
        now = now.addingTimeInterval(PeerActivity.liveFor + 1)
        XCTAssertTrue(body(page.ask(.page, from: "172.20.10.3")).contains(notConnected), "quiet for a minute: its tunnel is off")
        server.received[ipad.address] = 164
        session.sampleTraffic()
        XCTAssertTrue(body(page.ask(.page, from: "172.20.10.3")).contains(connected))
        session.pauseWireGuardDevice(ipad.id)
        XCTAssertTrue(body(page.ask(.page, from: "172.20.10.3")).contains(notConnected), "nothing gets through a paused device")
    }

    func testSpeedsAreBitsPerSecondBetweenTwoSamples() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        server.totals = TrafficTotals(bytesUp: 1000, bytesDown: 5000)
        session.sampleTraffic()
        XCTAssertEqual(session.upSpeed, 0, "the first sample has nothing to compare with")
        XCTAssertEqual(session.downSpeed, 0)
        now = now.addingTimeInterval(2)
        server.totals = TrafficTotals(bytesUp: 2000, bytesDown: 9000)
        session.sampleTraffic()
        XCTAssertEqual(session.upSpeed, 4000)
        XCTAssertEqual(session.downSpeed, 16000)
        // Off screen and back: the time away isn't averaged in.
        session.leftScreen()
        now = now.addingTimeInterval(600)
        server.totals = TrafficTotals(bytesUp: 3000, bytesDown: 10000)
        session.sampleTraffic()
        now = now.addingTimeInterval(1)
        server.totals = TrafficTotals(bytesUp: 3250, bytesDown: 10000)
        session.sampleTraffic()
        XCTAssertEqual(session.upSpeed, 2000)
        XCTAssertEqual(session.downSpeed, 0)
    }

    func testEachDeviceStatsArePublished() throws {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        let peer = try XCTUnwrap(devices.connectReady())
        server.connected = [peer.address]
        server.peerTraffic = [peer.address: TrafficTotals(bytesUp: 5, bytesDown: 1000)]
        session.sampleTraffic()
        XCTAssertEqual(session.wireGuardPeerStats[peer.address],
                       PeerStats(traffic: TrafficTotals(bytesUp: 5, bytesDown: 1000), connected: true))
        address = nil
        session.syncWithHotspot()
        session.sampleTraffic()
        XCTAssertEqual(session.wireGuardPeerStats[peer.address]?.traffic, TrafficTotals(bytesUp: 5, bytesDown: 1000),
                       "with the hotspot off, what it used still shows")
        XCTAssertEqual(session.wireGuardPeerStats[peer.address]?.connected, false)
    }

    func testANewHotspotStartsFromZero() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        server.connected = ["10.7.0.2"]
        session.sampleTraffic()
        now = now.addingTimeInterval(1)
        server.totals = TrafficTotals(bytesUp: 100, bytesDown: 100)
        session.sampleTraffic()
        XCTAssertEqual(session.downSpeed, 800)
        address = "172.20.10.3"
        session.syncWithHotspot()
        XCTAssertEqual(session.downSpeed, 0, "a new address restarts without passing through off")
        XCTAssertEqual(session.upSpeed, 0)
        XCTAssertEqual(session.wireGuardConnected, ["10.7.0.2"], "until the next sample")
        address = nil
        session.syncWithHotspot()
        session.sampleTraffic()
        XCTAssertTrue(session.wireGuardConnected.isEmpty)
    }

    // MARK: Devices not using Tether (#109)

    /// Sharing on screen, with the iPad on WireGuard from .2 and a laptop on the proxy from .3.
    private func shareWithNeighbors() throws -> FakeKnocker {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        XCTAssertTrue(session.setProxy(on: true))
        session.openAddWindow()
        let ipad = try XCTUnwrap(session.wireGuardReady).address
        server.connected = [ipad]
        server.endpoints = [ipad: "172.20.10.2:52345"]
        server.handshakes = [ipad: now]
        server.proxyServed = ["172.20.10.3"]
        session.sampleTraffic()
        knocker.answers = [HotspotKnock(address: "172.20.10.2", answer: .open),
                           HotspotKnock(address: "172.20.10.3", answer: .refused),
                           HotspotKnock(address: "172.20.10.4", answer: .nobody),
                           HotspotKnock(address: "172.20.10.6", answer: .refused)]
        return knocker
    }

    func testTheKnockListsWhoIsOnTheHotspotButNotOnWireGuardOrTheProxy() async throws {
        let knocker = try shareWithNeighbors()
        await session.knockNeighbors()
        XCTAssertEqual(session.notUsingTether, ["172.20.10.6"])
        XCTAssertEqual(knocker.rounds.count, 1)
        XCTAssertEqual(knocker.rounds.first?.addresses, HotspotNeighbors.addresses)
        XCTAssertEqual(knocker.rounds.first?.ports, [62078, 9])
        XCTAssertEqual(knocker.rounds.first?.timeout, 1.5)
    }

    /// A knock can make iOS ask about Local Network, so none goes out before Continue on the screen
    /// that comes first.
    func testNoKnockBeforeTheLocalNetworkScreensContinue() async throws {
        let knocker = try shareWithNeighbors()
        session.localNetworkIntroduced = { false }
        await session.knockNeighbors()
        XCTAssertTrue(knocker.rounds.isEmpty)
        XCTAssertEqual(session.notUsingTether, [])
        session.localNetworkIntroduced = { true }
        await session.knockNeighbors()
        XCTAssertEqual(knocker.rounds.count, 1)
        XCTAssertEqual(session.notUsingTether, ["172.20.10.6"])
    }

    /// Only the on-screen line shows it, so nothing knocks off screen or while not sharing.
    func testNoKnockOffScreenOrWithoutSharing() async {
        makeSession(sceneActive: false)
        address = hotspot
        session.syncWithHotspot()
        knocker.answers = [HotspotKnock(address: "172.20.10.6", answer: .open)]
        await session.knockNeighbors()
        XCTAssertTrue(knocker.rounds.isEmpty)
        XCTAssertEqual(session.notUsingTether, [])
        makeSession()
        knocker.answers = [HotspotKnock(address: "172.20.10.6", answer: .open)]
        await session.knockNeighbors() // no hotspot
        XCTAssertTrue(knocker.rounds.isEmpty)
        XCTAssertEqual(session.notUsingTether, [])
    }

    /// Leaving the screen or the hotspot going away empties the list, and the next round starts from
    /// nothing: an address that answered before isn't held for `holdFor` after.
    func testTheListStartsOverWhenSharingStopsOrTetherLeavesTheScreen() async throws {
        let knocker = try shareWithNeighbors()
        await session.knockNeighbors()
        XCTAssertEqual(session.notUsingTether, ["172.20.10.6"])
        session.leftScreen()
        XCTAssertEqual(session.notUsingTether, [])
        session.cameOnScreen()
        knocker.answers = []
        await session.knockNeighbors()
        XCTAssertEqual(session.notUsingTether, [], "not the answer from before leaving")
        knocker.answers = [HotspotKnock(address: "172.20.10.6", answer: .refused)]
        await session.knockNeighbors()
        XCTAssertEqual(session.notUsingTether, ["172.20.10.6"])
        address = nil
        session.syncWithHotspot()
        XCTAssertEqual(session.notUsingTether, [])
    }

    /// A round still knocking when Tether leaves the screen is dropped, even if it's back by the time it answers.
    func testARoundOvertakenByLeavingTheScreenIsDropped() async throws {
        let knocker = try shareWithNeighbors()
        knocker.meanwhile = { [unowned self] in
            session.leftScreen()
            session.cameOnScreen()
        }
        await session.knockNeighbors()
        XCTAssertEqual(session.notUsingTether, [])
    }

    /// The same for sharing stopping and starting again while a round knocks.
    func testARoundOvertakenBySharingStoppingIsDropped() async throws {
        let knocker = try shareWithNeighbors()
        knocker.meanwhile = { [unowned self] in
            address = nil
            session.syncWithHotspot()
            address = hotspot
            session.syncWithHotspot()
        }
        await session.knockNeighbors()
        XCTAssertEqual(session.notUsingTether, [])
    }

    /// Every round would redraw the screen otherwise (#166), also the watcher's while not sharing.
    func testTheListIsPublishedOnlyWhenItChanges() async throws {
        makeSession()
        var changes = 0
        session.willChange = { changes += 1 }
        session.syncWithHotspot()
        session.syncWithHotspot()
        await session.knockNeighbors()
        XCTAssertEqual(changes, 0, "nothing to clear while not sharing")
        let knocker = try shareWithNeighbors()
        await session.knockNeighbors()
        changes = 0
        session.willChange = { changes += 1 }
        now = now.addingTimeInterval(10)
        await session.knockNeighbors()
        XCTAssertEqual(changes, 0)
        knocker.answers.append(HotspotKnock(address: "172.20.10.9", answer: .open))
        await session.knockNeighbors()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(session.notUsingTether, ["172.20.10.6", "172.20.10.9"])
    }

    func testACounterGoingBackwardsIsNoSpeed() {
        makeSession()
        address = hotspot
        session.syncWithHotspot()
        server.totals = TrafficTotals(bytesUp: 1000, bytesDown: 1000)
        session.sampleTraffic()
        now = now.addingTimeInterval(1)
        server.totals = TrafficTotals(bytesUp: 10, bytesDown: 10)
        session.sampleTraffic()
        XCTAssertEqual(session.upSpeed, 0)
        XCTAssertEqual(session.downSpeed, 0)
    }
}

final class InternetVPNTests: XCTestCase {
    /// The internet's local address is on a tunnel: a VPN carries it. On cellular or Wi-Fi, or a tunnel
    /// that only holds an address (Tailscale without an exit node), no.
    func testAVPNIsTheInterfaceTheInternetsAddressIsOn() {
        let lines = ["pdp_ip0: 10.180.2.3", "en0: 192.168.1.158", "utun5: 10.2.0.2", "utun3: fe80::1%utun3", "ipsec2: 10.9.0.4"]
        XCTAssertEqual(Interfaces.vpn(in: lines, local: ["10.2.0.2"]), "utun5")
        XCTAssertEqual(Interfaces.vpn(in: lines, local: ["10.9.0.4"]), "ipsec2")
        XCTAssertNil(Interfaces.vpn(in: lines, local: ["10.180.2.3"]))
        XCTAssertNil(Interfaces.vpn(in: lines, local: ["192.168.1.158"]))
        XCTAssertNil(Interfaces.vpn(in: lines, local: []))
        XCTAssertEqual(Interfaces.vpn(in: lines, local: ["10.2.0.2", "10.9.0.4"]), "utun5", "both through a tunnel")
    }

    /// IPv4 over cellular and IPv6 through the tunnel, or the other way round: one of them would
    /// leave without the VPN, so it doesn't count. With no route for the other, the one is enough.
    func testAVPNThatCarriesOnlyIPv4OrOnlyIPv6IsNotOne() {
        let lines = ["pdp_ip0: 10.180.2.3", "pdp_ip0: 2607:fb90:1234::5", "utun5: 10.2.0.2", "utun5: fd00::2"]
        XCTAssertNil(Interfaces.vpn(in: lines, local: ["10.180.2.3", "fd00::2"]), "IPv4 leaves over cellular")
        XCTAssertNil(Interfaces.vpn(in: lines, local: ["10.2.0.2", "2607:fb90:1234::5"]), "IPv6 leaves over cellular")
        XCTAssertEqual(Interfaces.vpn(in: lines, local: ["10.2.0.2", "fd00::2"]), "utun5")
        XCTAssertEqual(Interfaces.vpn(in: lines, local: ["fd00::2"]), "utun5", "an iPhone with no IPv4 route")
        XCTAssertNil(Interfaces.vpn(in: lines, local: ["10.2.0.2", "198.51.100.7"]), "an address on no interface")
    }

    /// VPN apps leave the special-purpose ranges out of their tunnel by default (Shadowrocket's TUN
    /// Excluded Routes holds 198.51.100.0/24, for one), so a probe there reads a full tunnel as none.
    /// Every probe is ordinary global unicast, outside the IANA special-purpose registries (RFC 6890
    /// and its updates), and the second of each family is no public resolver's.
    func testTheProbesAreAddressesEveryTunnelCarries() {
        let special = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
                       "192.0.0.0/24", "192.0.2.0/24", "192.31.196.0/24", "192.52.193.0/24", "192.88.99.0/24",
                       "192.168.0.0/16", "192.175.48.0/24", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24",
                       "224.0.0.0/4", "240.0.0.0/4", "255.255.255.255/32",
                       "::/128", "::1/128", "::ffff:0:0/96", "64:ff9b::/96", "64:ff9b:1::/48", "100::/64",
                       "2001::/23", "2001:db8::/32", "2002::/16", "2620:4f:8000::/48", "3fff::/20",
                       "5f00::/16", "fc00::/7", "fe80::/10", "ff00::/8"]
        let resolvers = ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112", "208.67.222.222",
                         "208.67.220.220", "94.140.14.14", "76.76.2.0", "2606:4700:4700::1111", "2606:4700:4700::1001",
                         "2001:4860:4860::8888", "2001:4860:4860::8844", "2620:fe::fe", "2620:fe::9",
                         "2620:119:35::35", "2a10:50c0::ad1:ff", "2606:1a40::"]
        for probe in Interfaces.internetProbes {
            for range in special {
                XCTAssertFalse(Self.address(probe, isIn: range), "\(probe) is in \(range), which tunnels leave out")
            }
        }
        let ipv4 = Interfaces.internetProbes.filter { !$0.contains(":") }
        let ipv6 = Interfaces.internetProbes.filter { $0.contains(":") }
        XCTAssertEqual(ipv4.count, 2)
        XCTAssertEqual(ipv6.count, 2)
        XCTAssertFalse(resolvers.contains(ipv4[1]), "a DNS app's tunnel can carry \(ipv4[1]) alone")
        XCTAssertFalse(resolvers.contains(ipv6[1]), "a DNS app's tunnel can carry \(ipv6[1]) alone")
        XCTAssertTrue(Self.address("198.51.100.1", isIn: "198.51.100.0/24"))
        XCTAssertTrue(Self.address("2001:db8::1", isIn: "2001:db8::/32"))
        XCTAssertFalse(Self.address("2001:db9::1", isIn: "2001:db8::/32"))
    }

    private static func address(_ address: String, isIn range: String) -> Bool {
        let parts = range.split(separator: "/")
        guard let base = bytes(String(parts[0])), let mine = bytes(address), base.count == mine.count,
              let length = Int(parts[1]) else { return false }
        for bit in 0..<length where (base[bit / 8] >> (7 - bit % 8)) & 1 != (mine[bit / 8] >> (7 - bit % 8)) & 1 {
            return false
        }
        return true
    }

    private static func bytes(_ address: String) -> [UInt8]? {
        if address.contains(":") {
            var a = in6_addr()
            guard inet_pton(AF_INET6, address, &a) == 1 else { return nil }
            return withUnsafeBytes(of: &a) { Array($0) }
        }
        var a = in_addr()
        guard inet_pton(AF_INET, address, &a) == 1 else { return nil }
        return withUnsafeBytes(of: &a) { Array($0) }
    }

    /// A question that failed says nothing, so it isn't a VPN. No route for one family is an answer:
    /// the other decides.
    func testARouteNothingIsKnownAboutIsNotAVPN() {
        let lines = ["pdp_ip0: 2607:fb90:1234::5", "utun5: 10.2.0.2", "utun5: fd00::2"]
        XCTAssertEqual(Interfaces.vpn(in: lines, routes: [.local("10.2.0.2"), .local("fd00::2")]), "utun5")
        XCTAssertEqual(Interfaces.vpn(in: lines, routes: [.local("10.2.0.2"), .none]), "utun5")
        XCTAssertNil(Interfaces.vpn(in: lines, routes: [.local("10.2.0.2"), .unknown]))
        XCTAssertNil(Interfaces.vpn(in: lines, routes: [.none, .none]), "no internet at all")
        XCTAssertNil(Interfaces.vpn(in: lines, routes: []))
        XCTAssertTrue(Interfaces.Route.local("10.2.0.2").isIPv4)
        XCTAssertFalse(Interfaces.Route.local("fd00::2").isIPv4)
        XCTAssertFalse(Interfaces.Route.none.isIPv4)
    }

    /// A VPN's inner address can be the same as one the carrier gave: then it isn't known which the
    /// traffic leaves from.
    func testAnAddressAlsoOnCellularIsNotAVPN() {
        let lines = ["utun5: 10.180.2.3", "pdp_ip0: 10.180.2.3"]
        XCTAssertNil(Interfaces.vpn(in: lines, local: ["10.180.2.3"]))
    }

    /// An IPv6-only carrier with no CLAT, and a VPN that carries 2000::/3: every IPv6 address, but not
    /// the well-known NAT64 prefix. The carrier's own NAT64 prefix is inside 2000::/3, so the devices'
    /// IPv4 traffic goes through the VPN too, and the probe has to be in that prefix to see it.
    func testTheNAT64ProbeIsInThePrefixTheServerUses() {
        let lines = ["pdp_ip0: 2607:fb90:1234::5", "utun5: fd00::2"]
        var probed: [String] = []
        let route: (String) -> Interfaces.Route = { host in
            probed.append(host)
            if !host.contains(":") { return .none } // no IPv4 route
            return host.hasPrefix("2") ? .local("fd00::2") : .local("2607:fb90:1234::5") // 2000::/3 through the VPN
        }
        XCTAssertEqual(Interfaces.internetVPN(nat64: { "2607:7700:0:1d::/96" }, addresses: lines, route: route), "utun5")
        XCTAssertEqual(probed.last, "2607:7700:0:1d::101:101")
        XCTAssertNil(Interfaces.internetVPN(nat64: { "64:ff9b::/96" }, addresses: lines, route: route),
                     "the carrier has no prefix of its own, so IPv4 leaves over cellular")
        XCTAssertNil(Interfaces.internetVPN(nat64: { nil }, addresses: lines, route: route), "no server yet: the well-known prefix")
        XCTAssertEqual(probed.last, "64:ff9b::101:101")
        XCTAssertNil(Interfaces.internetVPN(nat64: { "" }, addresses: lines, route: route), "still looked up, so nothing is known")
        XCTAssertNil(Interfaces.internetVPN(nat64: { "2607:7700::/64" }, addresses: lines, route: route), "not a /96")
    }

    /// With an IPv4 route, nothing goes through a NAT64, and the server isn't asked for its prefix.
    func testWithAnIPv4RouteTheNAT64IsNotProbed() {
        let lines = ["pdp_ip0: 10.180.2.3", "utun5: 10.2.0.2", "utun5: fd00::2"]
        let route: (String) -> Interfaces.Route = { $0.contains(":") ? .local("fd00::2") : .local("10.2.0.2") }
        XCTAssertEqual(Interfaces.internetVPN(nat64: { XCTFail("asked for the prefix"); return nil }, addresses: lines, route: route), "utun5")
    }

    func testTheNAT64ProbeIsOnePointOnePointOnePointOneBehindThePrefix() {
        XCTAssertEqual(Interfaces.nat64Probe(prefix: "64:ff9b::/96"), "64:ff9b::101:101")
        XCTAssertEqual(Interfaces.nat64Probe(prefix: "2001:db8:64::/96"), "2001:db8:64::101:101")
        XCTAssertEqual(Interfaces.nat64Probe(prefix: nil), "64:ff9b::101:101")
        XCTAssertNil(Interfaces.nat64Probe(prefix: ""))
        XCTAssertNil(Interfaces.nat64Probe(prefix: "64:ff9b::"))
        XCTAssertNil(Interfaces.nat64Probe(prefix: "10.0.0.0/96"))
    }

    /// Tailscale without an exit node holds its tailnet address on a utun interface, but the internet
    /// still goes out over cellular, so it isn't a VPN here. With an exit node it is.
    func testTailscaleWithoutAnExitNodeIsNotAVPN() {
        let lines = ["pdp_ip0: 10.180.2.3", "pdp_ip0: 2607:fb90:1234::5", "utun4: 100.101.102.103", "utun4: fd7a:115c:a1e0::1"]
        XCTAssertNil(Interfaces.vpn(in: lines, local: ["10.180.2.3", "2607:fb90:1234::5"]))
        XCTAssertEqual(Interfaces.vpn(in: lines, local: ["100.101.102.103", "fd7a:115c:a1e0::1"]), "utun4", "with an exit node")
    }
}
