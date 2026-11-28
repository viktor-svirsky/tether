import SwiftUI

// The pieces a device's screen and the proxy's screen share in the paper and ink look (#349).

/// The big light name on top of the screen, with the live dot while something is connected. The
/// status itself is a text under it, so the dot is never the only sign.
struct DeviceScreenTitle: View {
    let name: String
    let live: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 52
    @ScaledMetric(relativeTo: .largeTitle) private var dot: CGFloat = 10

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
                .font(.system(size: size, weight: .light))
                .tracking(-1.2)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if live {
                Circle()
                    .fill(Theme.live)
                    .frame(width: dot, height: dot)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A problem on one of these screens. Problems use words, not a second colour, so the icon is ink.
/// Same shape as `WarningLabel`, which the other screens still use: the icon carries the identifier too.
struct InkWarningLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text).foregroundStyle(Theme.ink)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.ink)
                .accessibilityHidden(true)
        }
    }
}

/// The paper look's outlined button, like Pause on the board: ink edge, ink text.
struct InkOutline: View {
    let title: String

    var body: some View {
        Text(title)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.ink, lineWidth: 1) }
            .contentShape(.rect)
    }
}

/// The motion of these two screens, on top of `PaperMotion`: a state change eases in 0.25 s, and only
/// when a value changes. With Reduce Motion nothing moves: rows appear in place, and words only fade.
enum DeviceScreenMotion {
    /// A line that comes and goes inside a row. List animates whole rows itself. With Reduce Motion
    /// the animation is nil, so the line appears in place.
    static let appear = AnyTransition.opacity.combined(with: .move(edge: .top))
}

extension View {
    /// A text that changes: numbers roll, words cross-fade. With Reduce Motion only a fade.
    func deviceScreenChange<Value: Equatable>(_ value: Value, numbers: Bool = false, reduceMotion: Bool) -> some View {
        contentTransition(numbers && !reduceMotion ? .numericText() : .opacity)
            .animation(PaperMotion.change, value: value)
    }
}
