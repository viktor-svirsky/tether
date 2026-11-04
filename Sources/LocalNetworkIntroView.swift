import SwiftUI

/// The first launch's screen: what Local Network access is for, before iOS asks for it. Continue
/// makes iOS ask, see `LocalNetworkIntro`.
struct LocalNetworkIntroView: View {
    @ObservedObject var model: Model

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                StatusOrb(look: .sharing)
                    .padding(.top, 48)
                Text("Tether needs Local Network")
                    .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("intro.title")
                Text("Your devices connect to Tether over the hotspot.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("intro.why")
                Text("iOS may ask if Tether can find and connect to devices on your local network. Tap Allow. Without it, no device can connect.")
                    .font(.body) // in the label colour: grey fails the contrast audit on this background
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("intro.ask")
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        // The button stays in reach at every text size, the text scrolls under it.
        .safeAreaInset(edge: .bottom) {
            Button { model.finishLocalNetworkIntro() } label: {
                Text("Continue").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.filledButton)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityIdentifier("intro.continue")
        }
        .interactiveDismissDisabled()
    }
}
