import XCTest
@testable import TetherCore

/// The paper and ink colours keep WCAG contrast in both appearances (#349).
final class PaletteTests: XCTestCase {
    func testTheContrastRatioMatchesWCAGsEnds() {
        let black = Palette.RGB(0x000000), white = Palette.RGB(0xFFFFFF)
        XCTAssertEqual(black.contrast(with: white), 21, accuracy: 0.001)
        XCTAssertEqual(white.contrast(with: white), 1, accuracy: 0.001)
        XCTAssertEqual(white.contrast(with: black), black.contrast(with: white), accuracy: 0.001)
    }

    func testEveryTextColourReadsOnEveryBackgroundInBothModes() {
        for dark in [false, true] {
            for text in Palette.textRoles {
                for background in Palette.backgroundRoles {
                    let ratio = Palette.color(text, dark: dark).contrast(with: Palette.color(background, dark: dark))
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(text) on \(background), \(dark ? "dark" : "light"): \(ratio)")
                }
            }
        }
    }

    /// The live dot and the switch's parts are marks, not text, so they need 3:1 (WCAG 1.4.11).
    func testMarksAndSwitchPartsStandOutInBothModes() {
        for dark in [false, true] {
            let paper = Palette.color(.paper, dark: dark)
            let marks: [(String, Palette.Role, Palette.Role)] = [
                ("live dot on paper", .live, .paper),
                ("live dot on the card", .live, .card),
                ("switch on: knob on the ink track", .paper, .ink),
                ("switch off: edge and knob on paper", .secondary, .paper),
            ]
            for (name, mark, background) in marks {
                let ratio = Palette.color(mark, dark: dark).contrast(with: Palette.color(background, dark: dark))
                XCTAssertGreaterThanOrEqual(ratio, 3, "\(name), \(dark ? "dark" : "light"): \(ratio)")
            }
            XCTAssertGreaterThanOrEqual(Palette.color(.ink, dark: dark).contrast(with: paper), 3, "switch on: track on paper")
        }
    }

    /// The grid is a texture: it must show, but stay far below the text.
    func testTheDotsAreFaintButVisible() {
        for dark in [false, true] {
            let ratio = Palette.color(.dot, dark: dark).contrast(with: Palette.color(.paper, dark: dark))
            XCTAssertGreaterThan(ratio, 1.1, dark ? "dark" : "light")
            XCTAssertLessThan(ratio, 1.6, dark ? "dark" : "light")
        }
    }

    /// The card's edge shows in dark mode, where the card has no shadow.
    func testTheCardEdgeShowsInDarkMode() {
        XCTAssertGreaterThan(Palette.color(.cardEdge, dark: true).contrast(with: Palette.color(.card, dark: true)), 1.2)
    }
}
