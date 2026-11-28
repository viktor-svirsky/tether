import XCTest
@testable import TetherCore

/// Each demo runs the real session against the fakes, so what a UI test sees is what the session
/// publishes. These check what each demo's session publishes: the hotspot, the connected iPad, the
/// speeds, the problems and the QR code. The expiry warning and Local Network are Model's own, set
/// from the demo in Model.init, and the UI tests check those screens.
@MainActor
final class DemoScenarioTests: XCTestCase {
    private let waiting: Set<DemoScenario> = [.waiting, .wireGuardLockedWaiting, .localNetworkIntro]
    /// The list shows both states: the iPad connected, the Windows PC not.
    private let iPadConnected: Set<DemoScenario> = [.sharing, .expiring, .qrCodeUnsaved, .notificationsOff, .notifying,
                                                    .notificationsScreen, .addDeviceWaiting, .addDeviceDone, .addDeviceDoneUnsaved, .oldAddress, .nameNotAnswered, .staleConfig,
                                                    .notUsingTether, .vpnIPv4Only, .proxy, .proxyIPv6, .addDeviceProxy, .addDeviceProxyWorking,
                                                    .vpnBlocked, .stoppedIdle, .stoppedBattery, .manyWarnings, .addDeviceProxyOff,
                                                    .askNotifications, .replaceDevice]
    private let noSpeed: Set<DemoScenario> = [.waiting, .wireGuardLockedWaiting, .localNetworkIntro, .noDevices, .wireGuardUnsaved,
                                              .addDeviceScreen, .addDeviceComputer, .addDeviceComputerIPv6, .addDeviceConnects]

    /// Only its own demo has a device on the hotspot that isn't using Tether. The iPad answers the
    /// knock too, from where its handshake comes, so it isn't listed (#109).
    func testOnlyItsDemoHasADeviceNotUsingTether() {
        for scenario in DemoScenario.allCases {
            let session = DemoState(scenario).makeSession()
            XCTAssertEqual(session.notUsingTether, scenario == .notUsingTether ? ["172.20.10.3"] : [], "\(scenario)")
        }
    }

    func testTheHotspotIsOnExceptWhileWaiting() {
        for scenario in DemoScenario.allCases {
            XCTAssertEqual(DemoState(scenario).makeSession().running, !waiting.contains(scenario), "\(scenario)")
        }
    }

    func testTheIPadIsConnectedWhereTheListShowsBothStates() {
        for scenario in DemoScenario.allCases {
            let session = DemoState(scenario).makeSession()
            let connected: Set<String> = scenario == .limits ? ["10.7.0.2", "10.7.0.4"] : iPadConnected.contains(scenario) ? ["10.7.0.2"] : []
            XCTAssertEqual(session.wireGuardConnected, connected, "\(scenario)")
            if iPadConnected.contains(scenario) {
                XCTAssertEqual(session.wireGuardPeers.first { $0.address == "10.7.0.2" }?.name, "iPad", "\(scenario)")
            }
        }
    }

    func testTheSpeedsAreThe3Point2MbitDemoWhereItShowsOne() {
        for scenario in DemoScenario.allCases {
            let session = DemoState(scenario).makeSession()
            XCTAssertEqual(session.downSpeed, noSpeed.contains(scenario) ? 0 : 3_200_000, "\(scenario)")
            XCTAssertEqual(session.upSpeed, noSpeed.contains(scenario) ? 0 : 400_000, "\(scenario)")
        }
    }

    /// The Windows PC last connected two hours before the demo's clock, so its screen says when (#73).
    func testTheWindowsPCLastConnectedTwoHoursBefore() throws {
        let session = DemoState(.sharing).makeSession()
        let pc = try XCTUnwrap(session.wireGuardPeers.first { $0.name == "Windows PC" })
        XCTAssertEqual(session.lastConnected(of: pc.id), DemoScenario.now.addingTimeInterval(-2 * 3600))
    }

    /// The iPad connects from an address on the hotspot, so its screen says it (#73). Not while it's paused.
    func testTheIPadConnectsFromAHotspotAddress() throws {
        for scenario in [DemoScenario.sharing, .paused] {
            let session = DemoState(scenario).makeSession()
            let ipad = try XCTUnwrap(session.wireGuardPeers.first { $0.name == "iPad" })
            XCTAssertEqual(session.connectsFrom(of: ipad.id), scenario == .sharing ? "172.20.10.2" : nil, "\(scenario)")
        }
    }

    func testTheProblemDemosShowTheirProblem() {
        for scenario in DemoScenario.allCases {
            let session = DemoState(scenario).makeSession()
            let hasProblem = [.wireGuardLocked, .wireGuardLockedWaiting, .wireGuardNeedsReset, .wireGuardUnsaved].contains(scenario)
            XCTAssertEqual(session.wireGuardProblem != nil, hasProblem, "\(scenario): \(session.wireGuardProblem.map { "\($0)" } ?? "no problem")")
            XCTAssertEqual(session.wireGuardNeedsReset, scenario == .wireGuardNeedsReset, "\(scenario)")
            XCTAssertEqual(session.wireGuardReady == nil, hasProblem || [.qrCodeUnsaved, .addDeviceDoneUnsaved].contains(scenario), "\(scenario): the QR code")
        }
    }

    /// The sheet's name for the iPad can't be saved, and the session says so for the iPad.
    func testNamingTheIPadFailsInTheUnsavedAddDeviceDemo() throws {
        let session = DemoState(.addDeviceDoneUnsaved).makeSession()
        let ipad = try XCTUnwrap(session.wireGuardPeers.first { $0.name == "iPad" })
        session.renameWireGuardDevice(ipad.id, to: "Living room")
        XCTAssertEqual(session.wireGuardDeviceProblem?.device, ipad.id)
        XCTAssertEqual(session.wireGuardPeers.first { $0.id == ipad.id }?.name, "iPad")
    }

    func testOnlyTheStaleConfigDemosShowOne() {
        for scenario in DemoScenario.allCases {
            XCTAssertEqual(DemoState(scenario).makeSession().showsStaleConfig, [.staleConfig, .manyWarnings].contains(scenario), "\(scenario)")
        }
    }

    func testTheOldAddressDemosNeedTheWindowsPCGivenANewConfig() throws {
        for scenario in [DemoScenario.oldAddress, .replaceDevice] {
            let session = DemoState(scenario).makeSession()
            let pc = try XCTUnwrap(session.wireGuardPeers.first { $0.name == "Windows PC" })
            XCTAssertEqual(session.newConfig(pc), .oldAddress, "\(scenario)")
        }
    }

    // MARK: The 1.14 UX demos (#349)

    /// Only `vpnBlocked` has Only share through a VPN on, and it doesn't leak into the next demo.
    func testOnlyTheVPNBlockedDemoKeepsTheDevicesOut() {
        for scenario in DemoScenario.allCases {
            XCTAssertEqual(DemoState(scenario).makeSession().blockedWithoutVPN, scenario == .vpnBlocked, "\(scenario)")
        }
    }

    /// The stopped demos have a last stop for Home's note, 4:00 PM on the demo's day, and the others none.
    func testTheStoppedDemosHaveTheirLastStop() {
        let at = DemoScenario.now.addingTimeInterval(-2 * 3600)
        for scenario in DemoScenario.allCases {
            let expected: LastStop? = switch scenario {
            case .stoppedIdle, .manyWarnings: LastStop(at: at, reason: .idle(.thirtyMinutes))
            case .stoppedBattery: LastStop(at: at, reason: .lowBattery(.twenty))
            default: nil
            }
            let session = DemoState(scenario).makeSession()
            XCTAssertEqual(session.lastStop, expected, "\(scenario)")
            XCTAssertNil(session.idleStopped, "\(scenario): sharing again since")
        }
    }

    /// `limits`: the iPad near its limit and connected, the Windows PC paused at its, the Pixel resumed over its.
    func testTheLimitsDemoHasOneNearOneAtAndOneOver() throws {
        let session = DemoState(.limits).makeSession()
        let ipad = try XCTUnwrap(session.wireGuardPeers.first { $0.name == "iPad" })
        let pc = try XCTUnwrap(session.wireGuardPeers.first { $0.name == "Windows PC" })
        let pixel = try XCTUnwrap(session.wireGuardPeers.first { $0.name == "Pixel" })
        XCTAssertNil(ipad.paused)
        XCTAssertEqual(session.limitStanding(of: ipad.id), .near)
        XCTAssertEqual(pc.paused, .atLimit)
        XCTAssertNil(pixel.paused)
        XCTAssertEqual(session.limitStanding(of: pixel.id), .over)
        XCTAssertTrue(session.overLimit(pixel.id))
        XCTAssertEqual(session.shortcutDevices()?.map(\.status),
                       ["Connected, near its limit", "Paused at its limit", "Connected, over its limit"])
    }

    /// `manyWarnings`: the battery at the stop level, a stale config and a last stop at once.
    func testTheManyWarningsDemoHasEveryWarning() {
        let session = DemoState(.manyWarnings).makeSession()
        XCTAssertEqual(session.belowBatteryStop, BelowBatteryStop(percent: 15, level: .twenty))
        XCTAssertTrue(session.sharing, "on screen it doesn't stop")
        XCTAssertTrue(session.showsStaleConfig)
        XCTAssertNotNil(session.lastStop)
        XCTAssertNotNil(DemoState(.manyWarnings).expires)
    }

    func testTheProxyOffDemoHasNoProxyAndOnlyAskNotificationsOffersThem() {
        XCTAssertNil(DemoState(.addDeviceProxyOff).makeSession().proxy)
        XCTAssertEqual(ProxyStatus.blocked(DemoState(.addDeviceProxyOff).makeSession().proxy), .off)
        for scenario in DemoScenario.allCases {
            XCTAssertEqual(DemoState(scenario).offersNotifications, scenario == .askNotifications, "\(scenario)")
        }
    }

    /// The Windows PC's config uses the iPhone's name, which the demo never answers (#65).
    func testTheNameNotAnsweredDemoSaysSoForTheWindowsPC() throws {
        let session = DemoState(.nameNotAnswered).makeSession()
        let pc = try XCTUnwrap(session.wireGuardPeers.first { $0.name == "Windows PC" })
        XCTAssertEqual(session.newConfig(pc), .nameNotAnswered)
        XCTAssertNil(session.newConfig(try XCTUnwrap(session.wireGuardPeers.first { $0.name == "iPad" })))
    }

    /// The proxy demos (#78) have it on, with the iPad and the Windows PC, and only they do. `proxy`
    /// has two connections open and 85 MB this month, `proxyIPv6` listens at both addresses, and Add a
    /// device's waits for the first page or has one loading through it.
    func testTheProxyDemosHaveTheProxyOn() throws {
        let on: Set<DemoScenario> = [.proxy, .proxyIPv6, .addDeviceProxy, .addDeviceProxyWorking]
        for scenario in DemoScenario.allCases {
            XCTAssertEqual(DemoState(scenario).makeSession().proxy?.on == true, on.contains(scenario), "\(scenario)")
        }
        let proxy = DemoState(.proxy).makeSession()
        XCTAssertEqual(proxy.proxyStats.open, 2)
        XCTAssertEqual(proxy.proxyStats.addresses, ["172.20.10.1:8118"])
        XCTAssertEqual(proxy.usage(of: try XCTUnwrap(proxy.proxy?.id)).thisMonth.total, 85_000_000)
        XCTAssertEqual(DemoState(.proxyIPv6).makeSession().proxyStats.addresses,
                       ["172.20.10.1:8118", "[2001:db8:9e74:4eaa:459:5cd0:7ec7:f792]:8118"])
        XCTAssertEqual(DemoState(.addDeviceProxy).makeSession().proxyStats.open, 0)
        XCTAssertEqual(DemoState(.addDeviceProxyWorking).makeSession().proxyStats.open, 1)
    }

    /// In `addDeviceConnects` nothing connects until Add a device lets the code in. Then the device
    /// behind it connects from the hotspot and is listed (#315).
    func testTheConnectingDemoConnectsTheCodesDeviceOnceTheSheetIsOpen() async throws {
        var demo = DemoState(.addDeviceConnects)
        demo.connectsAfter = 1
        let session = demo.makeSession()
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(session.wireGuardConnected, [], "not before the sheet opens")
        XCTAssertEqual(session.wireGuardPeers, [])
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        for _ in 0..<40 where session.wireGuardConnected.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(session.wireGuardConnected, [ready.address])
        let device = try XCTUnwrap(session.wireGuardPeers.first { $0.address == ready.address }, "listed")
        XCTAssertEqual(session.connectsFrom(of: device.id), "172.20.10.4")
    }

    /// Closing the sheet doesn't start the wait over: the code is still let in for 10 minutes, and
    /// the device behind it connects then, as a real one could.
    func testTheConnectingDemoStillConnectsAfterTheSheetCloses() async throws {
        var demo = DemoState(.addDeviceConnects)
        demo.connectsAfter = 2
        let session = demo.makeSession()
        session.openAddWindow()
        let ready = try XCTUnwrap(session.wireGuardReady)
        session.closeAddWindow()
        XCTAssertTrue(session.addWindowOpen, "the code still works")
        for _ in 0..<50 where session.wireGuardConnected.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(session.wireGuardConnected, [ready.address])
    }

    /// A demo's log is its own, emptied at each launch, so the app's log never gets a demo's lines.
    func testADemoKeepsItsOwnLogEmptiedAtEachLaunch() {
        let log = DemoState(.sharing).debugLog()
        log.append("from a demo")
        XCTAssertTrue(log.export(header: "").contains("from a demo"))
        XCTAssertTrue(DemoState(.sharing).debugLog().export(header: "").hasSuffix("Nothing logged yet.\n"))
    }
}
