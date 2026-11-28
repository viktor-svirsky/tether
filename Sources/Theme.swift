import SwiftUI
import UIKit

/// The paper and ink look (#349) as SwiftUI colours and modifiers. The values are in `Palette`.
/// Each screen moves over in its own change.
enum Theme {
    static let paper = color(.paper)
    static let dot = color(.dot)
    static let ink = color(.ink)
    static let secondary = color(.secondary)
    static let card = color(.card)
    static let cardEdge = color(.cardEdge)
    static let live = color(.live)
    static let danger = color(.danger)

    /// A colour that follows the iPhone's appearance and its Increase Contrast setting.
    static func color(_ role: Palette.Role) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = Palette.color(role, dark: traits.userInterfaceStyle == .dark,
                                    highContrast: traits.accessibilityContrast == .high)
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    }

    /// The gap between the dots of the grid, in points.
    static let dotSpacing: CGFloat = 16
}

/// The dot grid, one row of dots taller than the view. `offset` (0 up to one spacing) moves it.
/// The dots themselves are `DotPattern`, which has no inputs, so a scroll changes only the
/// offset around it. The columns are centred, so no dot is cut at an edge.
struct DotGrid: View {
    var offset: CGFloat = 0

    var body: some View {
        DotPattern()
            .padding(.bottom, -Theme.dotSpacing)
            .offset(y: -offset)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

private struct DotPattern: View {
    var body: some View {
        let spacing = Theme.dotSpacing
        Canvas { context, size in
            let columns = Int(size.width / spacing)
            let left = (size.width - CGFloat(max(columns - 1, 0)) * spacing) / 2
            var dots = Path()
            var y = spacing / 2
            while y < size.height {
                for column in 0..<columns {
                    dots.addEllipse(in: CGRect(x: left + CGFloat(column) * spacing - 1, y: y - 1, width: 2, height: 2))
                }
                y += spacing
            }
            context.fill(dots, with: .color(Theme.dot))
        }
    }
}

extension View {
    /// Paper behind a screen that doesn't scroll, with the dot grid if `dots`.
    func paperBackground(dots: Bool = true) -> some View {
        background {
            ZStack {
                Theme.paper
                if dots { DotGrid() }
            }
            .ignoresSafeArea()
        }
    }

    /// A `List` on paper: the list's own background goes, and the dot grid moves with the rows.
    /// The cells still draw their grouped background and separators until each row or section
    /// gets `paperRow()`: those are row modifiers, which do nothing on the `List` itself.
    func paperList(dots: Bool = true) -> some View {
        modifier(PaperList(dots: dots))
    }

    /// A row of a `paperList`: no cell background, no separators. Put it on each row, or on a
    /// `Section`, which passes it to its rows.
    func paperRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
    }

    /// The floating card: a shadow in light mode, a thin edge in dark mode.
    func liveCard() -> some View {
        modifier(LiveCard())
    }

    /// The small spaced-out label in capitals, like TETHER on top of a screen. VoiceOver and the
    /// UI tests still read the words as written, since only the display is upper case.
    func monoCaps() -> some View {
        font(.system(.caption, design: .monospaced))
            .tracking(2)
            .textCase(.uppercase)
            .foregroundStyle(Theme.secondary)
    }
}

private struct PaperList: ViewModifier {
    let dots: Bool
    /// Only the scroll position within one dot row, 0 up to one spacing. It changes while the list
    /// scrolls, and `DotGrid` moves by it.
    @State private var shift: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) {
                // Always 0 up to one spacing, also while the list bounces past its top.
                let spacing = Theme.dotSpacing
                let remainder = ($0.contentOffset.y + $0.contentInsets.top).truncatingRemainder(dividingBy: spacing)
                return remainder < 0 ? remainder + spacing : remainder
            } action: { _, new in
                shift = new
            }
            .background {
                ZStack(alignment: .top) {
                    Theme.paper
                    if dots { DotGrid(offset: shift) }
                }
                .ignoresSafeArea()
            }
    }
}

private struct LiveCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 18)
            .padding(.horizontal, 20)
            .background {
                // The shadow on the shape alone: on the whole card every line and letter gets a grey halo.
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.card)
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.08), radius: 15, y: 10)
            }
            .overlay {
                if scheme == .dark { RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.cardEdge, lineWidth: 1) }
            }
    }
}

/// A switch drawn in ink. On: an ink track with a paper knob, so the knob stays visible in dark
/// mode, where ink is light. Off: a secondary edge and knob. The whole row dims when disabled, like
/// a system switch. Only the switch takes taps, padded to 44 by 44 points, so tapping the label
/// does nothing. VoiceOver and the UI tests see a plain switch.
struct InkToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        InkToggle(configuration: configuration)
    }
}

private struct InkToggle: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack {
            configuration.label
            Spacer()
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Theme.ink : Color.clear)
                    .overlay { Capsule().strokeBorder(configuration.isOn ? Theme.ink : Theme.secondary, lineWidth: 1.5) }
                Circle()
                    .fill(configuration.isOn ? Theme.paper : Theme.secondary)
                    .padding(3)
            }
            .frame(width: 46, height: 28)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: configuration.isOn)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
            .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityRepresentation {
            // The system style, so this inner Toggle doesn't draw itself with InkToggleStyle again.
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

extension ToggleStyle where Self == InkToggleStyle {
    static var ink: InkToggleStyle { InkToggleStyle() }
}
