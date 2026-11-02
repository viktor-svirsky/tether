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
                addButton
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } else if let problem = model.wireGuardReadyProblem {
            Section {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("add.problem")
            } header: {
                Text(title)
            }
        }
    }

    private var title: String { first ? "Add a device" : "Add another device" }

    @ViewBuilder private var addButton: some View {
        let button = Button(action: add) {
            Label(title, systemImage: "plus")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .accessibilityIdentifier("add.open")
        if first { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
    }
}

/// Why WireGuard isn't running, with the way out when the saved keys can't be read.
struct WireGuardProblemSection: View {
    @ObservedObject var model: Model

    var body: some View {
        if let problem = model.wireGuardProblem {
            Section {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("wireguard.problem")
                if model.wireGuardNeedsReset {
                    Button("Start over with new keys", role: .destructive) { model.resetWireGuard() }
                        .accessibilityIdentifier("wireguard.reset")
                }
            } header: {
                Text("WireGuard isn't running")
            }
        }
    }
}

/// One device: whether it's connected, and removing it. Tapping the title renames it. A rename or
/// removal that couldn't be saved says so at the top.
struct DeviceView: View {
    @ObservedObject var model: Model
    let peer: WireGuardSetup.Peer
    @State private var confirmRemove = false
    @Environment(\.dismiss) private var dismiss

    /// The saved device, so a new name shows at once.
    private var current: WireGuardSetup.Peer { model.wireGuardPeers.first { $0.id == peer.id } ?? peer }
    private var connected: Bool { model.wireGuardConnected.contains(peer.address) }
    /// A rename or removal of this device that couldn't be saved.
    private var problem: String? { model.wireGuardDeviceProblem.flatMap { $0.device == peer.id ? $0.text : nil } }

    var body: some View {
        List {
            // On top, where a rename is made, and the screen a failed removal stays on.
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("device.problem")
                }
            }
            Section {
                ConnectedLabel(connected: connected)
                    .accessibilityIdentifier("device.status")
            }
            Section {
                Button("Remove device", role: .destructive) { confirmRemove = true }
                    .accessibilityIdentifier("device.remove")
            } footer: {
                Text("It can't connect any more. Delete its tunnel in its WireGuard app too.")
            }
        }
        .navigationTitle(Binding(get: { current.name }, set: { model.renameWireGuardDevice(peer.id, to: $0) }))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .confirmationDialog("Remove \(current.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                // A removal that couldn't be saved stays here, and the screen says so.
                if model.removeWireGuardDevice(peer.id) { dismiss() }
            }
        }
    }
}

/// "Connected" or "Not connected". The text keeps the normal colours, since green text on the
/// grouped background fails the contrast audit. The icon carries the green.
struct ConnectedLabel: View {
    let connected: Bool

    var body: some View {
        Label {
            Text(connected ? "Connected" : "Not connected")
                .foregroundStyle(connected ? .primary : .secondary)
        } icon: {
            Image(systemName: connected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(connected ? .green : .secondary)
        }
    }
}
