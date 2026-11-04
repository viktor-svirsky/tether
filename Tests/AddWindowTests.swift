import XCTest
@testable import TetherCore

/// When the code behind Add a device works, by the clock: while the sheet is on screen, and for 10
/// minutes after it closes or Tether leaves the screen with it open.
final class AddWindowTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func minutes(_ m: Double) -> Date { start.addingTimeInterval(m * 60) }

    func testItStartsClosed() {
        XCTAssertFalse(AddWindow().isOpen(now: start, sceneActive: true), "a relaunch never brings an old code back")
    }

    func testOpenWhileTheSheetIsOnScreen() {
        var window = AddWindow()
        window.sheetOpened()
        XCTAssertTrue(window.isOpen(now: start, sceneActive: true))
        XCTAssertTrue(window.isOpen(now: minutes(60), sceneActive: true), "however long it stays open")
    }

    func testTenMinutesAfterTheSheetCloses() {
        var window = AddWindow()
        window.sheetOpened()
        window.sheetClosed(now: start, sceneActive: true)
        XCTAssertTrue(window.isOpen(now: minutes(9.9), sceneActive: true))
        XCTAssertFalse(window.isOpen(now: minutes(10), sceneActive: true))
        XCTAssertEqual(AddWindow.afterClose, 600)
    }

    /// The sheet stays up while Tether is in the background, but the person may be gone: the 10
    /// minutes run from leaving the screen.
    func testTenMinutesAfterLeavingTheScreenWithTheSheetOpen() {
        var window = AddWindow()
        window.sheetOpened()
        window.leftScreen(now: start)
        XCTAssertTrue(window.isOpen(now: minutes(9.9), sceneActive: false))
        XCTAssertFalse(window.isOpen(now: minutes(10), sceneActive: false))
        // Back on screen with the sheet still up, it's open again.
        XCTAssertTrue(window.isOpen(now: minutes(30), sceneActive: true))
    }

    /// Closing the sheet off screen doesn't start the 10 minutes again: they run from leaving.
    func testClosingOffScreenKeepsTheTimeFromLeaving() {
        var window = AddWindow()
        window.sheetOpened()
        window.leftScreen(now: start)
        window.sheetClosed(now: minutes(5), sceneActive: false)
        XCTAssertFalse(window.isOpen(now: minutes(10), sceneActive: false))
    }

    func testLeavingTheScreenWithoutTheSheetChangesNothing() {
        var window = AddWindow()
        window.leftScreen(now: start)
        XCTAssertFalse(window.isOpen(now: start, sceneActive: false))
    }
}
