import SwiftUI

/// The first launch's screen: what Local Network access is for, before iOS asks for it. Continue
/// makes iOS ask, see `LocalNetworkIntro`. In the paper and ink look (#349): TETHER on top, a light
/// large title, the text in ink and secondary, and Continue filled in ink.
struct LocalNetworkIntroView: View {
    @ObservedObject var model: Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // The app's name, as on top of Home. VoiceOver hears it in the title.
                Text("Tether")
                    .monoCaps()
                    .accessibilityHidden(true)
                    .padding(.top, 48)
                Text("Tether needs Local Network")
                    .font(.system(.largeTitle, weight: .light))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("intro.title")
                Text("Your devices connect to Tether over the hotspot.")
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("intro.why")
                Text("iOS may ask if Tether can find and connect to devices on your local network. Tap Allow. Without it, no device can connect.")
                    .font(.body)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("intro.ask")
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .paperBackground()
        // The button stays in reach at every text size, the text scrolls under it.
        .safeAreaInset(edge: .bottom) {
            Button { model.finishLocalNetworkIntro() } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(InkCapsuleButtonStyle())
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(Theme.paper)
            .accessibilityIdentifier("intro.continue")
        }
        .interactiveDismissDisabled()
    }
}
