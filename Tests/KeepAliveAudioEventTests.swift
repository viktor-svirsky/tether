import XCTest
@testable import TetherCore

final class KeepAliveAudioEventTests: XCTestCase {
    /// Right after a call the Phone app can still hold the audio, so a single try fails (#106).
    func testHoldsOnUntilTheSoundPlaysAfterACall() {
        XCTAssertEqual(KeepAlivePolicy.restart(after: .interruptionEnded, started: true), .holdOn)
    }

    func testRebuildsEverythingAfterAMediaServicesReset() {
        XCTAssertEqual(KeepAlivePolicy.restart(after: .mediaServicesReset, started: true), .rebuild)
    }

    func testHoldsOnWhileTheMediaServicesAreGone() {
        XCTAssertEqual(KeepAlivePolicy.restart(after: .mediaServicesLost, started: true), .holdOn)
    }

    func testAStoppedKeepAliveStaysStopped() {
        XCTAssertNil(KeepAlivePolicy.restart(after: .interruptionEnded, started: false))
        XCTAssertNil(KeepAlivePolicy.restart(after: .mediaServicesLost, started: false))
        XCTAssertNil(KeepAlivePolicy.restart(after: .mediaServicesReset, started: false))
    }
}
