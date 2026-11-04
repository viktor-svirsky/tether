import SwiftUI

/// Why no device can connect while Local Network is off for Tether, and the way to Settings. On the
/// status card, and in Add a device's last step, because that sheet covers the card.
struct LocalNetworkWarning: View {
    /// The start of its accessibility identifiers. The card's and the sheet's are in the tree at once.
    let id: String

    /// The text and the button, darker than the system orange so they pass the contrast audit.
    static let text = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.72, blue: 0.40, alpha: 1)
            : UIColor(red: 0.60, green: 0.29, blue: 0.0, alpha: 1)
    })
    static let fill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 0.22)
            : UIColor(red: 1.0, green: 0.94, blue: 0.85, alpha: 1)
    })

    var body: some View {
        Text("iOS blocks Tether's answers to your devices until it's on.")
            .font(.subheadline)
            .accessibilityIdentifier("\(id).problem")
        Button {
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        } label: {
            Text("Turn on in Settings")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(Self.text)
                .background(Self.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(id).open")
    }
}
