import SwiftUI

/// One way to say a copy worked (L4): "Copied" in a small ink capsule at the bottom, for a moment,
/// on Diagnostics, Add a device and the proxy's screen. Not the value, which is on screen already,
/// and a long one would cover it. VoiceOver hears it too. Set `shown` to the copy's time with
/// `PaperMotion.change`: a new copy while it shows starts its time again.
struct CopiedToast: ViewModifier {
    /// When the last copy was, nil while it doesn't show.
    @Binding var shown: Date?
    /// Its accessibility identifier, for the UI tests, like `diagnostics.copied`.
    let id: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long it shows, in seconds. A UI test under load can take longer than 2 s to look after a
    /// menu closes, so in a Debug build it can pass `-copiedToast.shownFor <s>`.
    static var shownFor: Double {
        #if DEBUG
        let s = UserDefaults.standard.double(forKey: "copiedToast.shownFor")
        if s > 0 { return s }
        #endif
        return 2
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if shown != nil {
                    Text(Copy.copied)
                        .font(.subheadline)
                        .foregroundStyle(Theme.paper)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.ink, in: Capsule())
                        .padding()
                        .accessibilityIdentifier(id)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .task(id: shown) {
                guard shown != nil else { return }
                AccessibilityNotification.Announcement(Copy.copied).post()
                try? await Task.sleep(for: .seconds(Self.shownFor))
                if !Task.isCancelled { withAnimation(PaperMotion.change) { shown = nil } }
            }
    }
}

extension View {
    /// See `CopiedToast`.
    func copiedToast(_ shown: Binding<Date?>, id: String) -> some View {
        modifier(CopiedToast(shown: shown, id: id))
    }
}
