import SwiftUI

/// One way to say a copy worked (L4): "Copied" in a small ink capsule at the bottom, for a moment,
/// on Diagnostics, Add a device and the proxy's screen. Not the value, which is on screen already,
/// and a long one would cover it. VoiceOver hears it too. Set `shown` with `PaperMotion.change`.
struct CopiedToast: ViewModifier {
    @Binding var shown: Bool
    /// Its accessibility identifier, for the UI tests, like `diagnostics.copied`.
    let id: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long it shows, in seconds. A UI test under load can take longer than 2 s to look after a
    /// menu closes, so in a Debug build it can pass `-diagnostics.copiedShownFor <s>`.
    static var shownFor: Double {
        #if DEBUG
        let s = UserDefaults.standard.double(forKey: "diagnostics.copiedShownFor")
        if s > 0 { return s }
        #endif
        return 2
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if shown {
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
                guard shown else { return }
                AccessibilityNotification.Announcement(Copy.copied).post()
                try? await Task.sleep(for: .seconds(Self.shownFor))
                if !Task.isCancelled { withAnimation(PaperMotion.change) { shown = false } }
            }
    }
}

extension View {
    /// See `CopiedToast`.
    func copiedToast(_ shown: Binding<Bool>, id: String) -> some View {
        modifier(CopiedToast(shown: shown, id: id))
    }
}
