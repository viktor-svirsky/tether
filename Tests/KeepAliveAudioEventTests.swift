import XCTest
@testable import TetherCore

final class KeepAliveAudioEventTests: XCTestCase {
    func testPlaysTheSamePlayerAgainAfterACall() {
        XCTAssertEqual(KeepAlivePolicy.restart(after: .interruptionEnded, started: true), .resume)
    }

    func testRebuildsEverythingAfterAMediaServicesReset() {
        XCTAssertEqual(KeepAlivePolicy.restart(after: .mediaServicesReset, started: true), .rebuild)
    }

    func testAStoppedKeepAliveStaysStopped() {
        XCTAssertNil(KeepAlivePolicy.restart(after: .interruptionEnded, started: false))
        XCTAssertNil(KeepAlivePolicy.restart(after: .mediaServicesReset, started: false))
    }
}
