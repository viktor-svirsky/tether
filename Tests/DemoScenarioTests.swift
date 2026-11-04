import XCTest
@testable import TetherCore

/// Each demo runs the real session against the fakes, so what a UI test sees is what the session
/// publishes. These check what each demo's session publishes: the hotspot, the connected iPad, the
/// speeds, the problems and the QR code. The expiry warning and Local Network are Model's own, set
/// from the demo in Model.init, and the UI tests check those screens.
@MainActor
final class DemoScenarioTests: XCTestCase {
    private let waiting: Set<DemoScenario> = [.waiting, .wireGuardLockedWaiting]
    /// The list shows both states: the iPad connected, the Windows PC not.
    private let iPadConnected: Set<DemoScenario> = [.sharing, .expiring, .qrCodeUnsaved, .notificationsOff, .notifying,
                                                    .notificationsScreen, .addDeviceWaiting, .addDeviceDone, .oldAddress]
    private let noSpeed: Set<DemoScenario> = [.waiting, .wireGuardLockedWaiting, .noDevices, .wireGuardUnsaved,
                                              .addDeviceScreen, .addDeviceComputer]

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

    func testTheProblemDemosShowTheirProblem() {
        for scenario in DemoScenario.allCases {
            let session = DemoState(scenario).makeSession()
            let hasProblem = [.wireGuardLocked, .wireGuardLockedWaiting, .wireGuardNeedsReset, .wireGuardUnsaved].contains(scenario)
            XCTAssertEqual(session.wireGuardProblem != nil, hasProblem, "\(scenario): \(session.wireGuardProblem ?? "no problem")")
            XCTAssertEqual(session.wireGuardNeedsReset, scenario == .wireGuardNeedsReset, "\(scenario)")
            XCTAssertEqual(session.wireGuardReady == nil, hasProblem || scenario == .qrCodeUnsaved, "\(scenario): the QR code")
        }
    }

    /// The iPad used 3.12 GB in October (the demo's month) and 11.4 GB in September, and is connected.
    /// The Windows PC never connected.
    func testTheIPadShowsItsDataWhereTheListShowsBothStates() throws {
        for scenario in iPadConnected {
            let session = DemoState(scenario).makeSession()
            let ipad = try XCTUnwrap(session.wireGuardPeers.first { $0.name == "iPad" }, "\(scenario)")
            let pc = try XCTUnwrap(session.wireGuardPeers.first { $0.name == "Windows PC" }, "\(scenario)")
            XCTAssertEqual(session.deviceUsage[ipad.id],
                           DeviceUsage(thisMonth: TrafficTotals(bytesUp: 420_000_000, bytesDown: 2_700_000_000),
                                       lastMonth: TrafficTotals(bytesUp: 1_400_000_000, bytesDown: 10_000_000_000),
                                       lastConnected: DemoScenario.now), "\(scenario)")
            XCTAssertEqual(session.deviceUsage[pc.id], DeviceUsage(), "\(scenario)")
        }
    }

    func testTheOldAddressDemoNeedsTheWindowsPCAddedAgain() throws {
        let session = DemoState(.oldAddress).makeSession()
        let pc = try XCTUnwrap(session.wireGuardPeers.first { $0.name == "Windows PC" })
        XCTAssertTrue(session.needsNewConfig(pc))
    }
}
