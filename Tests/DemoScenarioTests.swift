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
                                                    .notificationsScreen, .addDeviceWaiting, .addDeviceDone, .addDeviceDoneUnsaved, .oldAddress, .staleConfig,
                                                    .proxy, .proxyIPv6, .addDeviceProxy, .addDeviceProxyWorking]
    private let noSpeed: Set<DemoScenario> = [.waiting, .wireGuardLockedWaiting, .localNetworkIntro, .noDevices, .wireGuardUnsaved,
                                              .addDeviceScreen, .addDeviceComputer, .addDeviceComputerIPv6]

    func testTheHotspotIsOnExceptWhileWaiting() {
        for scenario in DemoScenario.allCases {
            XCTAssertEqual(DemoState(scenario).makeSession().running, !waiting.contains(scenario), "\(scenario)")
        }
    }

    func testTheIPadIsConnectedWhereTheListShowsBothStates() {
        for scenario in DemoScenario.allCases {
            let session = DemoState(scenario).makeSession()
            XCTAssertEqual(session.wireGuardConnected, iPadConnected.contains(scenario) ? ["10.7.0.2"] : [], "\(scenario)")
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
            XCTAssertEqual(session.wireGuardProblem != nil, hasProblem, "\(scenario): \(session.wireGuardProblem ?? "no problem")")
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

    func testOnlyTheStaleConfigDemoShowsOne() {
        for scenario in DemoScenario.allCases {
            XCTAssertEqual(DemoState(scenario).makeSession().showsStaleConfig, scenario == .staleConfig, "\(scenario)")
        }
    }

    func testTheOldAddressDemoNeedsTheWindowsPCAddedAgain() throws {
        let session = DemoState(.oldAddress).makeSession()
        let pc = try XCTUnwrap(session.wireGuardPeers.first { $0.name == "Windows PC" })
        XCTAssertTrue(session.needsNewConfig(pc))
    }

    /// The proxy demos (#78) have it on, with the iPad and the Windows PC, and only they do. `proxy`
    /// has two connections open and 85 MB this month, `proxyIPv6` listens at both addresses, and Add a
    /// device's waits for the first page or has one open.
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

    /// A demo's log is its own, emptied at each launch, so the app's log never gets a demo's lines.
    func testADemoKeepsItsOwnLogEmptiedAtEachLaunch() {
        let log = DemoState(.sharing).debugLog()
        log.append("from a demo")
        XCTAssertTrue(log.export(header: "").contains("from a demo"))
        XCTAssertTrue(DemoState(.sharing).debugLog().export(header: "").hasSuffix("Nothing logged yet.\n"))
    }
}
