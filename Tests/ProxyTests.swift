import XCTest
@testable import TetherCore

/// The HTTP proxy's side in Swift (#78): turned on and off, paused and limited like a device, saved
/// with the setup, sent to Go with the devices, read back from Go's stats, and counted into the month.
@MainActor
final class ProxyTests: XCTestCase {
    private let hotspot = "172.20.10.1"
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private var now = Date()
    private var sceneActive = true
    private var idleAfter = IdleStop.After.never
    private var server: FakeServer!
    private var secrets: FlakySecrets!
    private var devices: WireGuardDevices!
    private var session: HotspotSession!
    private let usageDefaults: UserDefaults = {
        let d = UserDefaults(suiteName: "ProxyTests")!
        d.removePersistentDomain(forName: "ProxyTests")
        return d
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// A session on 10 November with the hotspot on and no device yet.
    private func makeSession() {
        now = date(2026, 11, 10)
        usageDefaults.removePersistentDomain(forName: "ProxyTests")
        server = FakeServer()
        secrets = FlakySecrets()
        devices = WireGuardDevices(secrets: secrets)
        session = HotspotSession(devices: devices, server: server, keepAlive: FakeSound(), page: FakePage(),
                                 sceneActive: sceneActive, hotspotAddress: { [unowned self] in hotspot },
                                 idleStopAfter: { [unowned self] in idleAfter }, usageDefaults: usageDefaults,
                                 calendar: calendar, now: { [unowned self] in now })
        session.syncWithHotspot()
    }

    /// A session with the proxy turned on.
    private func proxyOn() throws -> WireGuardSetup.Proxy {
        makeSession()
        XCTAssertTrue(session.setProxy(on: true))
        return try XCTUnwrap(session.proxy)
    }

    /// The proxy has carried `bytes` in all, read now.
    private func carried(_ bytes: UInt64) {
        server.proxyTraffic = TrafficTotals(bytesUp: 0, bytesDown: bytes)
        session.sampleTraffic()
    }

    // MARK: Saved with the setup

    func testTheProxyIsSavedWithTheSetupAndAnOlderSetupHasNone() throws {
        var setup = WireGuardSetup.new()
        XCTAssertNil(setup.proxy, "off until it's turned on")
        setup.turnProxy(on: true)
        let proxy = try XCTUnwrap(setup.proxy)
        XCTAssertTrue(proxy.on)
        setup.limitPeer(proxy.id, 5_000_000_000)
        setup.pausePeer(proxy.id, .byYou)
        let read = try JSONDecoder().decode(WireGuardSetup.self, from: JSONEncoder().encode(setup))
        XCTAssertEqual(read, setup)
        XCTAssertEqual(read.proxy?.limit, 5_000_000_000)
        XCTAssertEqual(read.proxy?.paused, .byYou)
        // A setup saved before there was a proxy decodes with none.
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WireGuardSetup.new())) as? [String: Any])
        old["proxy"] = nil
        XCTAssertNil(try JSONDecoder().decode(WireGuardSetup.self, from: JSONSerialization.data(withJSONObject: old)).proxy)
    }

    /// Off keeps its id, limit and count, so turning it on again goes on with the month. On again
    /// lets it carry: a pause by you would leave Add a device waiting for a page that can't load.
    func testTurningOffKeepsItsIdAndLimitAndOnAgainResumesAPauseByYou() throws {
        var setup = WireGuardSetup.new()
        setup.turnProxy(on: true)
        let proxy = try XCTUnwrap(setup.proxy)
        setup.limitPeer(proxy.id, 1_000)
        setup.pausePeer(proxy.id, .byYou)
        setup.turnProxy(on: false)
        XCTAssertEqual(setup.proxy?.id, proxy.id)
        XCTAssertEqual(setup.proxy?.on, false)
        XCTAssertEqual(setup.proxy?.limit, 1_000)
        setup.turnProxy(on: true)
        XCTAssertEqual(setup.proxy?.id, proxy.id)
        XCTAssertNil(setup.proxy?.paused)
        // A pause at its limit stays: the limit still holds.
        setup.pausePeer(proxy.id, .atLimit)
        setup.turnProxy(on: true)
        XCTAssertEqual(setup.proxy?.paused, .atLimit)
    }

    func testThePausesAndLimitsOfTheProxyAndADeviceAreReadByID() throws {
        var setup = WireGuardSetup.new()
        let ipad = try XCTUnwrap(setup.addPeer(name: "iPad"))
        setup.turnProxy(on: true)
        let proxy = try XCTUnwrap(setup.proxy)
        setup.pausePeer(ipad.id, .byYou)
        setup.limitPeer(proxy.id, 7)
        XCTAssertEqual(setup.pause(of: ipad.id), .byYou)
        XCTAssertNil(setup.pause(of: proxy.id))
        XCTAssertEqual(setup.limit(of: proxy.id), 7)
        XCTAssertNil(setup.limit(of: ipad.id))
        XCTAssertNil(setup.limit(of: UUID()))
    }

    // MARK: The message to Go and the stats back

    /// The proxy is always in the message, off when there's none, so Go never guesses (boundary.go).
    func testTheDeviceListCarriesTheProxy() throws {
        func proxy(_ p: WireGuardSetup.Proxy?) throws -> [String: Bool]? {
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WireGuardServer.ConfigMessage([], proxy: p))) as? [String: Any]
            return json?["proxy"] as? [String: Bool]
        }
        XCTAssertEqual(try proxy(nil), ["on": false, "paused": false])
        var p = WireGuardSetup.Proxy()
        XCTAssertEqual(try proxy(p), ["on": true, "paused": false])
        p.paused = .atLimit
        XCTAssertEqual(try proxy(p), ["on": true, "paused": true])
        p.on = false
        XCTAssertEqual(try proxy(p), ["on": false, "paused": true])
    }

    /// Go's "proxy" in the stats: where it listens, IPv4 first, then the IPv6 one on an IPv6-only
    /// hotspot, empty while it doesn't, and its own counters.
    func testTheProxysStatsAreRead() throws {
        let json = #"{"v":1,"up":9,"down":90,"peers":[],"proxy":{"addresses":["172.20.10.1:8118","[2001:db8::1]:8118"],"paused":true,"open":2,"up":3,"down":40}}"#
        let proxy = try WireGuardServer.Stats.read(Data(json.utf8)).proxy
        XCTAssertEqual(proxy, ProxyStats(addresses: ["172.20.10.1:8118", "[2001:db8::1]:8118"], paused: true, open: 2,
                                         traffic: TrafficTotals(bytesUp: 3, bytesDown: 40)))
        let off = #"{"v":1,"up":0,"down":0,"peers":[],"proxy":{"addresses":[],"paused":false,"open":0,"up":0,"down":0}}"#
        XCTAssertEqual(try WireGuardServer.Stats.read(Data(off.utf8)).proxy, ProxyStats())
        let older = #"{"v":1,"up":0,"down":0,"peers":[]}"#
        XCTAssertEqual(try WireGuardServer.Stats.read(Data(older.utf8)).proxy, ProxyStats(), "a server without the proxy")
    }

    // MARK: The session

    func testTurningItOnAndOffReachesGoAndIsSaved() throws {
        let proxy = try proxyOn()
        XCTAssertEqual(server.lastSetup?.proxy?.on, true)
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.proxy?.id, proxy.id, "saved")
        XCTAssertEqual(session.proxyStats.addresses, ["172.20.10.1:8118"], "read at once, for Add a device")
        XCTAssertTrue(session.setProxy(on: false))
        XCTAssertEqual(server.lastSetup?.proxy?.on, false)
        XCTAssertEqual(session.proxy?.on, false)
        XCTAssertEqual(session.proxyStats.addresses, [])
    }

    func testATurnOnThatCantBeSavedChangesNothingAndSaysSo() {
        makeSession()
        secrets.savesFail = true
        XCTAssertFalse(session.setProxy(on: true))
        XCTAssertNil(session.proxy)
        XCTAssertNil(server.lastSetup?.proxy)
        XCTAssertEqual(session.proxyProblem, "The proxy couldn't be turned on.")
        secrets.savesFail = false
        XCTAssertTrue(session.setProxy(on: true))
        XCTAssertNil(session.proxyProblem)
    }

    func testItsStatsArePublishedWithEachSample() throws {
        _ = try proxyOn()
        server.proxyOpen = 2
        server.proxyAddresses = ["172.20.10.1:8118", "[2001:db8::1]:8118"]
        session.sampleTraffic()
        XCTAssertEqual(session.proxyStats.open, 2)
        XCTAssertEqual(session.proxyStats.addresses, ["172.20.10.1:8118", "[2001:db8::1]:8118"])
    }

    /// Is Tether Sharing? reads the proxy now too, off screen where the sampler doesn't run. A paused
    /// proxy ends its connections, so it isn't in use.
    func testTheShortcutCountsTheProxyWhileAConnectionIsOpenOnIt() throws {
        let proxy = try proxyOn()
        XCTAssertFalse(session.shortcutState().proxyInUse)
        server.proxyOpen = 1
        XCTAssertTrue(session.shortcutState().proxyInUse)
        XCTAssertEqual(session.shortcutState().connected, 0, "not a WireGuard device")
        session.pauseWireGuardDevice(proxy.id)
        XCTAssertFalse(session.shortcutState().proxyInUse)
    }

    func testPausingTheProxyReachesGoAndResumingLetsItCarryAgain() throws {
        let proxy = try proxyOn()
        session.pauseWireGuardDevice(proxy.id)
        XCTAssertEqual(session.proxy?.paused, .byYou)
        XCTAssertEqual(server.lastSetup?.proxy?.paused, .byYou)
        XCTAssertEqual(WireGuardDevices(secrets: secrets).setup.proxy?.paused, .byYou, "saved")
        session.resumeWireGuardDevice(proxy.id)
        XCTAssertNil(session.proxy?.paused)
        XCTAssertNil(server.lastSetup?.proxy?.paused)
    }

    func testAPauseThatCantBeSavedSaysSoOnTheProxysScreen() throws {
        let proxy = try proxyOn()
        secrets.savesFail = true
        session.pauseWireGuardDevice(proxy.id)
        XCTAssertNil(session.proxy?.paused)
        XCTAssertEqual(session.wireGuardDeviceProblem, HotspotSession.DeviceProblem(device: proxy.id, text: "The device couldn't be paused."))
    }

    /// Its data counts into the month like a device's, also once it's off.
    func testItsDataCountsIntoTheMonth() throws {
        let proxy = try proxyOn()
        carried(1_000)
        XCTAssertEqual(session.usage(of: proxy.id).thisMonth.total, 1_000)
        carried(1_500)
        XCTAssertEqual(session.usage(of: proxy.id).thisMonth.total, 1_500)
        XCTAssertTrue(session.setProxy(on: false))
        session.sampleTraffic()
        XCTAssertEqual(session.usage(of: proxy.id).thisMonth.total, 1_500, "kept while it's off")
        XCTAssertTrue(session.setProxy(on: true))
        XCTAssertEqual(session.usage(of: proxy.id).thisMonth.total, 1_500, "and when it's on again")
    }

    func testAtItsLimitTheProxyIsPausedAndToldAsProxy() throws {
        let proxy = try proxyOn()
        XCTAssertTrue(session.setLimit(proxy.id, 1_000))
        carried(900)
        XCTAssertEqual(session.limitAlerts.map(\.kind), [.near])
        XCTAssertEqual(session.limitAlerts.last?.name, "Proxy")
        carried(1_000)
        XCTAssertEqual(session.proxy?.paused, .atLimit)
        XCTAssertEqual(server.lastSetup?.proxy?.paused, .atLimit, "Go stops it")
        XCTAssertEqual(session.limitAlerts.map(\.kind), [.near, .reached])
        // Its screen says "It works again on", and so does the notification: nothing "connects" to the proxy.
        let body = session.limitAlerts.last?.notice(calendar: calendar, locale: Locale(identifier: "en_US")).body
        XCTAssertTrue(body?.hasSuffix(" this month. It works again on December 1, or when you resume it.") == true, body ?? "")
        // Resumed by hand it goes over until the count resets, then carries on by itself.
        session.resumeWireGuardDevice(proxy.id)
        XCTAssertNil(session.proxy?.paused)
        XCTAssertTrue(session.overLimit(proxy.id))
        carried(2_000)
        XCTAssertNil(session.proxy?.paused, "over it, as asked")
        // A pause at the limit lets go at the reset.
        session.pauseWireGuardDevice(proxy.id)
        XCTAssertTrue(session.setLimit(proxy.id, 1_500))
        XCTAssertEqual(session.proxy?.paused, .byYou, "by you stays by you")
        session.resumeWireGuardDevice(proxy.id)
        carried(2_100)
        XCTAssertEqual(session.proxy?.paused, .atLimit)
        now = date(2026, 12, 1)
        session.watch()
        XCTAssertNil(session.proxy?.paused, "the count reset")
    }

    /// Devices on the proxy keep Tether sharing: an idle stop would cut them off (#76).
    func testOpenProxyConnectionsKeepSharingFromAnIdleStop() throws {
        sceneActive = false
        idleAfter = .tenMinutes
        _ = try proxyOn()
        session.wake()
        server.proxyOpen = 1
        session.watch()
        now = now.addingTimeInterval(11 * 60)
        session.watch()
        XCTAssertTrue(session.sharing, "a device is on the proxy")
        XCTAssertNil(session.idleStopped)
        server.proxyOpen = 0
        session.watch()
        now = now.addingTimeInterval(11 * 60)
        session.watch()
        XCTAssertNotNil(session.idleStopped, "nobody on it any more")
    }

    /// Paused, the proxy still takes a connection to answer it with 403, so a device that keeps
    /// retrying must not hold off the idle stop while the status card says no device uses Tether.
    func testAPausedProxysConnectionsDontKeepSharing() throws {
        sceneActive = false
        idleAfter = .tenMinutes
        let proxy = try proxyOn()
        session.pauseWireGuardDevice(proxy.id)
        session.wake()
        server.proxyOpen = 1
        session.watch()
        now = now.addingTimeInterval(11 * 60)
        session.watch()
        XCTAssertNotNil(session.idleStopped, "nothing goes through a paused proxy")
    }

    // MARK: What the screens say

    func testWhereToSetTheProxy() {
        XCTAssertEqual(ProxyAddress.servers(["172.20.10.1:8118"]), ["172.20.10.1"])
        XCTAssertEqual(ProxyAddress.servers(["172.20.10.1:8118", "[2001:db8::1]:8118"]), ["172.20.10.1", "2001:db8::1"])
        XCTAssertEqual(ProxyAddress.servers([]), ["172.20.10.1"], "where it listens once it does")
        XCTAssertEqual(ProxyAddress.port, "8118")
    }

    func testWhatTheProxysRowAndScreenSay() {
        var proxy = WireGuardSetup.Proxy()
        func status(_ open: Int, hotspot: Bool = true) -> ProxyStatus {
            ProxyStatus(proxy, stats: ProxyStats(addresses: hotspot ? ["172.20.10.1:8118"] : [], open: open), hotspotOn: hotspot)
        }
        XCTAssertEqual(status(2).label, "2 open")
        XCTAssertEqual(status(2).title, "2 connections open")
        XCTAssertEqual(status(1).title, "1 connection open")
        XCTAssertEqual(status(0).label, "Idle")
        XCTAssertEqual(status(0).title, "No connections open")
        XCTAssertEqual(status(0, hotspot: false).label, "Idle")
        // The hotspot's network is there only while a device is on it, so off and on with nobody look
        // the same, see `ShortcutReply.status`.
        XCTAssertEqual(status(0, hotspot: false).title, "Waiting for a device to join Personal Hotspot")
        XCTAssertEqual(status(2).look, .connected)
        XCTAssertEqual(status(0).look, .notConnected)
        proxy.paused = .byYou
        XCTAssertEqual(status(2).label, "Paused")
        XCTAssertEqual(status(2).look, .paused(.byYou))
        XCTAssertEqual(status(2).title, "Paused")
        XCTAssertEqual(status(2).detail(resets: "December 1", period: "this month"), "Nothing goes through it until you resume it.")
        proxy.paused = .atLimit
        XCTAssertEqual(status(0).title, "Paused at its limit")
        XCTAssertEqual(status(0).detail(resets: "December 1", period: "this month"),
                       "It used its data this month. It works again on December 1, or when you resume it.")
        XCTAssertNil(ProxyStatus(WireGuardSetup.Proxy(), stats: ProxyStats(), hotspotOn: true).detail(resets: "", period: ""))
    }

    /// Add a device's last step when the proxy can't carry a page. Opening the steps turns it on and
    /// resumes a pause by you, but either can fail to be saved, so each case says what's wrong.
    func testWhatTheLastStepSaysWhenTheProxyCantCarryAPage() {
        XCTAssertNil(ProxyStatus.blocked(WireGuardSetup.Proxy()), "on and not paused")
        XCTAssertEqual(ProxyStatus.blocked(nil), "The proxy is off. Close this and pick No, use the proxy again to turn it on.")
        XCTAssertEqual(ProxyStatus.blocked(WireGuardSetup.Proxy(on: false, paused: .atLimit)),
                       "The proxy is off. Close this and pick No, use the proxy again to turn it on.", "off comes first: there's no row")
        XCTAssertEqual(ProxyStatus.blocked(WireGuardSetup.Proxy(paused: .byYou)),
                       "The proxy is paused. To resume it, close this, tap Proxy under Devices and turn off Pause.")
        XCTAssertEqual(ProxyStatus.blocked(WireGuardSetup.Proxy(paused: .atLimit)),
                       "The proxy is paused at its data limit. To use it anyway, close this, tap Proxy under Devices and turn off Pause.")
    }

    /// The status card counts the WireGuard devices, and names the proxy while a connection is open on it.
    func testTheStatusCardCountsTheProxyToo() {
        var proxy = WireGuardSetup.Proxy()
        func inUse(_ open: Int, hotspot: Bool = true) -> Bool {
            ProxyStatus(proxy, stats: ProxyStats(open: open), hotspotOn: hotspot).inUse
        }
        XCTAssertTrue(inUse(1))
        XCTAssertFalse(inUse(0))
        XCTAssertFalse(inUse(1, hotspot: false))
        proxy.paused = .byYou
        XCTAssertFalse(inUse(1), "paused, its connections are ended")
        XCTAssertEqual(UsingTether.headline(devices: 0, proxy: false), "No device is using Tether yet")
        XCTAssertEqual(UsingTether.headline(devices: 0, proxy: true), "The proxy is in use")
        XCTAssertEqual(UsingTether.headline(devices: 1, proxy: false), "1 device connected")
        XCTAssertEqual(UsingTether.headline(devices: 1, proxy: true), "1 device connected and the proxy in use")
        XCTAssertEqual(UsingTether.headline(devices: 3, proxy: true), "3 devices connected and the proxy in use")
    }

    /// Add a device's last step ticks off once the proxy carries something after the screen opened.
    /// An open connection alone doesn't: it may still be waiting for a lookup that fails.
    func testTheProxyPathWorksOnceSomethingGoesThrough() {
        let opened = ProxyStats(traffic: TrafficTotals(bytesUp: 10, bytesDown: 100))
        var progress = ProxyProgress(at: opened)
        XCTAssertFalse(progress.working)
        progress.follow(opened)
        XCTAssertFalse(progress.working, "nothing new")
        progress.follow(ProxyStats(traffic: TrafficTotals(bytesUp: 10, bytesDown: 101)))
        XCTAssertTrue(progress.working)
        progress.follow(ProxyStats())
        XCTAssertTrue(progress.working, "once it works it stays ticked")
        var open = ProxyProgress(at: ProxyStats())
        open.follow(ProxyStats(open: 1))
        XCTAssertFalse(open.working, "a connection let in, with nothing through it yet")
    }
}
