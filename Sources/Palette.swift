import Foundation

/// The colours of the paper and ink look (#349), one value per role for light and for dark mode.
/// They live here as numbers, not as colour sets in the asset catalog, so `swift test` on the Mac
/// can check their contrast: the package doesn't build the app's asset catalog. `Theme` turns
/// them into SwiftUI colours that follow the iPhone's appearance.
enum Palette {
    struct RGB: Equatable {
        let red: Double, green: Double, blue: Double

        /// From a hex like 0xFAFAF7.
        init(_ hex: UInt32) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
        }

        /// WCAG 2 relative luminance.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// WCAG 2 contrast ratio, 1 to 21. Text needs 4.5, a mark or a control's edge 3.
        func contrast(with other: RGB) -> Double {
            let (light, dark) = luminance > other.luminance ? (luminance, other.luminance) : (other.luminance, luminance)
            return (light + 0.05) / (dark + 0.05)
        }
    }

    enum Role: CaseIterable {
        /// The background of every screen.
        case paper
        /// The faint dot grid on the paper. Light enough that secondary text over a dot still reads.
        case dot
        /// Text, icons and filled buttons.
        case ink
        /// Second-line text: details, counts, footers.
        case secondary
        /// The one floating card, for what moves (the speed).
        case card
        /// The card's edge in dark mode, where a shadow doesn't show.
        case cardEdge
        /// The dot for what's live, like sharing or a connected device. A mark, never text.
        case live
        /// Remove and other actions that can't be undone.
        case danger
    }

    /// `highContrast` is iOS's Increase Contrast setting. It only changes secondary text, which
    /// has the least margin: there it reaches 7:1 on every background.
    static func color(_ role: Role, dark: Bool, highContrast: Bool = false) -> RGB {
        if highContrast, role == .secondary { return dark ? RGB(0xB8B7B1) : RGB(0x4A4945) }
        return dark ? darkValue(role) : lightValue(role)
    }

    private static func lightValue(_ role: Role) -> RGB {
        switch role {
        case .paper: RGB(0xFAFAF7)
        case .dot: RGB(0xE6E5DF)
        case .ink: RGB(0x141413)
        case .secondary: RGB(0x676661)
        case .card: RGB(0xFFFFFF)
        case .cardEdge: RGB(0xFFFFFF) // no edge: the card has a shadow in light mode
        case .live: RGB(0xE5432F)
        case .danger: RGB(0xB3261E)
        }
    }

    private static func darkValue(_ role: Role) -> RGB {
        switch role {
        case .paper: RGB(0x0E0E0D)
        case .dot: RGB(0x262624)
        case .ink: RGB(0xF2F1EC)
        case .secondary: RGB(0xA3A29C)
        case .card: RGB(0x1A1A19)
        case .cardEdge: RGB(0x2C2C2A)
        case .live: RGB(0xFF5A43)
        case .danger: RGB(0xFF7A6E)
        }
    }

    /// Text colours and every background they sit on.
    static let textRoles: [Role] = [.ink, .secondary, .danger]
    static let backgroundRoles: [Role] = [.paper, .dot, .card]
}
