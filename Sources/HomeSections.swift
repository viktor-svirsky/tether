import SwiftUI

/// The way to add a device from the main screen: a button that opens `AddDeviceSheet`, the
/// prominent one while there's no device yet. When the next code couldn't be saved, it says so
/// instead, and there's no button: the devices that have a code still connect.
struct AddDeviceSection: View {
    @ObservedObject var model: Model
    let first: Bool
    let add: () -> Void

    var body: some View {
        if model.wireGuardReady != nil {
            Section {
                VStack(spacing: 10) {
                    addButton
                    if first {
                        Text("An iPad, a laptop or a travel router. It takes a minute.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 20)
                            .accessibilityIdentifier("add.hint")
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } else if let problem = model.wireGuardReadyProblem {
            Section {
                WarningLabel(problem)
                    .accessibilityIdentifier("add.problem")
            } header: {
                Text(title)
            }
        }
    }

    private var title: String { first ? "Add a device" : "Add another device" }

    private var addButton: some View {
        // The icon and the title side by side: a Label in a list row can drop its icon.
        Button(action: add) {
            HStack(spacing: 8) {
                Image(systemName: "plus").fontWeight(.bold).accessibilityHidden(true)
                Text(title)
            }
        }
        .buttonStyle(InkCapsuleButtonStyle())
        .accessibilityIdentifier("add.open")
    }
}

/// The way out of a WireGuard problem, under its title and line on the status card (M9): start over
/// with new keys, after the same question as before, or share the log for a GitHub issue.
struct WireGuardProblemAction: View {
    @ObservedObject var model: Model
    let action: WireGuardProblem.Action
    @State private var confirmReset = false

    var body: some View {
        switch action {
        case .startOver:
            // Every device has to be added again, and an update may have read the keys (#174).
            Button(action.title) { confirmReset = true }
                .buttonStyle(InkCapsuleButtonStyle())
                .accessibilityIdentifier("wireguard.reset")
                .confirmationDialog("Start over with new keys?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Start Over", role: .destructive) { model.resetWireGuard() }
                } message: {
                    Text("Every device has to be added again. If you went back to an older Tether, update it instead.")
                }
        case .shareLog:
            VStack(alignment: .leading, spacing: 12) {
                ShareLink(item: LogFile(), preview: SharePreview("Tether log")) {
                    Text(action.title)
                }
                .buttonStyle(InkCapsuleButtonStyle())
                .accessibilityIdentifier("wireguard.shareLog")
                Link(destination: URL(string: "https://\(Copy.issuesLink)")!) {
                    Text(Copy.issuesLink)
                        .font(.subheadline)
                        .underline()
                        .foregroundStyle(Theme.ink)
                }
                // Plain, or a tap anywhere in the card opens GitHub.
                .buttonStyle(.plain)
                .accessibilityHint("Opens GitHub")
                .accessibilityIdentifier("wireguard.issues")
            }
        }
    }
}
