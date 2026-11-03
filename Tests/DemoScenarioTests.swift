import XCTest
@testable import TetherCore

/// Each demo runs the real session against the fakes, so what a UI test sees is what the session
/// publishes. These hold every demo to what its screen shows.
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

    func testTheOldAddressDemoNeedsTheWindowsPCAddedAgain() throws {
        let session = DemoState(.oldAddress).makeSession()
        let pc = try XCTUnwrap(session.wireGuardPeers.first { $0.name == "Windows PC" })
        XCTAssertTrue(session.needsNewConfig(pc))
    }
}
