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

/// Why WireGuard isn't running, with the way out when the saved keys can't be read.
struct WireGuardProblemSection: View {
    @ObservedObject var model: Model
    @State private var confirmReset = false

    var body: some View {
        if let problem = model.wireGuardProblem {
            Section {
                WarningLabel(problem.text)
                    .accessibilityIdentifier("wireguard.problem")
                if model.wireGuardNeedsReset {
                    // Every device has to be added again, and an update may have read the keys (#174).
                    Button("Start over with new keys", role: .destructive) { confirmReset = true }
                        .accessibilityIdentifier("wireguard.reset")
                        .confirmationDialog("Start over with new keys?", isPresented: $confirmReset, titleVisibility: .visible) {
                            Button("Start Over", role: .destructive) { model.resetWireGuard() }
                        } message: {
                            Text("Every device has to be added again. If you went back to an older Tether, update it instead.")
                        }
                }
            } header: {
                Text("WireGuard isn't running")
            }
        }
    }
}
