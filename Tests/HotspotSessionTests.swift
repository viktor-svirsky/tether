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
    private let usageDefaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: "HotspotSessionTests.usage")!
        defaults.removePersistentDomain(forName: "HotspotSessionTests.usage")
        return defaults
    }()
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var session: HotspotSession!

    /// `saved` is a setup already in the Keychain at launch.
    private func makeSession(sceneActive: Bool = true, locked: Bool = false, saved: WireGuardSetup? = nil,
                             log: @escaping @MainActor (String) -> Void = { _ in }) {
        server = FakeServer()
        sound = FakeSound()
        page = FakePage()
        secrets = FlakySecrets()
        secrets.failing = locked
        secrets.data = saved.flatMap { try? JSONEncoder().encode($0) }
        devices = WireGuardDevices(secrets: secrets)
        session = HotspotSession(devices: devices, server: server, keepAlive: sound, page: page,
                                 sceneActive: sceneActive, hotspotAddress: { [unowned self] in address },
                                 carrierIPv6Only: { [unowned self] in ipv6Only }, idleStopAfter: { [unowned self] in idleAfter },
                                 dns: { [unowned self] in dns }, usageDefaults: usageDefaults,
                                 now: { [unowned self] in now }, log: log)
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

    func testTheSetupProblemComesBeforeTheStartProblem() {
        run([
            Round(address: hotspot, locked: true, startFails: true, problem: locked, serverRunning: false),
            Round(address: hotspot, startFails: true, problem: couldntStart, serverRunning: false),
            Round(address: hotspot, problem: nil, serverRunning: true),
        ])
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
        XCTAssertTrue(body(page.ask(.page)).contains("href=\"/Tether.conf\""))
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
        now = now.addingTimeInterval(59)
        XCTAssertEqual(page.ask(.configHead, from: "172.20.10.2"), first.forHead)
        XCTAssertEqual(page.ask(.config, from: "172.20.10.2"), first)
        XCTAssertEqual(session.wireGuardPeers.count, 1)
        let other = page.ask(.config, from: "172.20.10.3")
        XCTAssertNotEqual(other.body, first.body, "another device gets its own")
        now = now.addingTimeInterval(61)
        XCTAssertNotEqual(page.ask(.config, from: "172.20.10.3").body, other.body, "a minute later it's a new device")
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
        XCTAssertEqual(page.ask(.pageHead), ConfigPage.page(.ready).forHead)
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
        XCTAssertEqual(page.ask(.page), ConfigPage.page(.openAddDevice))
        let closed = page.ask(.config)
        XCTAssertEqual(closed.status, .notFound)
        XCTAssertFalse(body(closed).contains("PrivateKey"))
        XCTAssertTrue(session.wireGuardPeers.isEmpty)
        session.openAddWindow()
        XCTAssertEqual(page.ask(.page), ConfigPage.page(.ready))
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
        now = minutes(10)
        session.watch()
        XCTAssertEqual(session.wireGuardPeers.map(\.id), [ready.id])
        XCTAssertEqual(letIn, [ready.publicKey], "the device, not the next code")
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
        var plays: Bool
        var line: UInt = #line
    }

    private func run(_ rounds: [SoundRound]) {
        makeSession(sceneActive: rounds.first?.onScreen ?? true)
        for round in rounds {
            now = minutes(round.minute)
            address = round.hotspot ? hotspot : nil
            session.sceneActive = round.onScreen
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
