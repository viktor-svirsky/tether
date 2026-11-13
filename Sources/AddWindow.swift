import Foundation

/// When the code behind Add a device works, by the clock: while the sheet is on screen, and for 10
/// minutes after it closes or Tether leaves the screen with it open. So a photo of the code, or a
/// .conf from days ago, doesn't connect later. A device that used the code is listed and works any
/// time. Whether the server lets the code in right now is `HotspotSession`'s, see `followAddWindow`.
struct AddWindow {
    /// How long the code still works after the sheet closes, or Tether leaves the screen with it open.
    static let afterClose: TimeInterval = 10 * 60

    /// The sheet is presented. It holds the window open only while Tether is on screen.
    private var sheetShown = false
    /// When the window closes, once the sheet has closed or Tether has left the screen with it.
    /// Nil at launch, so the window starts closed.
    private(set) var ends: Date?

    func isOpen(now: Date, sceneActive: Bool) -> Bool {
        if sheetShown, sceneActive { return true }
        return ends.map { now < $0 } ?? false
    }

    mutating func sheetOpened() {
        sheetShown = true
    }

    /// Off screen, the 10 minutes already run from leaving it.
    mutating func sheetClosed(now: Date, sceneActive: Bool) {
        sheetShown = false
        if sceneActive { ends = now.addingTimeInterval(Self.afterClose) }
    }

    mutating func leftScreen(now: Date) {
        if sheetShown { ends = now.addingTimeInterval(Self.afterClose) }
    }
}
