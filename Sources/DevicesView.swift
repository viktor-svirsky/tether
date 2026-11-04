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
                Label(problem, systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("add.problem")
            } header: {
                Text(title)
            }
        }
    }

    private var title: String { first ? "Add a device" : "Add another device" }

    @ViewBuilder private var addButton: some View {
        // The icon and the title side by side: a Label in a list row can drop its icon.
        let button = Button(action: add) {
            HStack(spacing: 8) {
                Image(systemName: "plus").fontWeight(.bold).accessibilityHidden(true)
                Text(title)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .accessibilityIdentifier("add.open")
        if first { button.buttonStyle(.borderedProminent).tint(.filledButton) } else { button.buttonStyle(.bordered) }
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

/// One device: whether it's connected or paused, pausing and resuming it, and removing it. Tapping
/// the title renames it. A change that couldn't be saved says so at the top, and so does a config
/// that points at an old address of this iPhone.
struct DeviceView: View {
    @ObservedObject var model: Model
    let peer: WireGuardSetup.Peer
    @State private var confirmRemove = false
    @Environment(\.dismiss) private var dismiss

    /// The saved device, so a new name shows at once.
    private var current: WireGuardSetup.Peer { model.wireGuardPeers.first { $0.id == peer.id } ?? peer }
    private var status: DeviceStatus { DeviceStatus(current, connected: model.wireGuardConnected) }
    /// A change to this device that couldn't be saved.
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
            if model.needsNewConfig(current) {
                Section {
                    Label("Its config points at an old address of this iPhone, so it can't connect. Remove it, then add it again.",
                          systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("device.oldAddress")
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    DeviceStatusLabel(status: status, text: status.title)
                        .accessibilityIdentifier("device.status")
                    if let detail = status.detail {
                        // The label colour, like the status: grey text on the card fails the contrast audit.
                        Text(detail)
                            .font(.subheadline)
                            .accessibilityIdentifier("device.statusDetail")
                    }
                }
            }
            pauseSection
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

extension DeviceView {
    /// Under the status: Pause, or Resume once it's paused, filled since it's the main action then.
    @ViewBuilder private var pauseSection: some View {
        if current.paused == nil {
            Section {
                Button("Pause") { model.pauseWireGuardDevice(peer.id) }
                    .accessibilityIdentifier("device.pause")
            } footer: {
                Text("Pause stops it from connecting until you resume it.")
            }
        } else {
            Section {
                Button { model.resumeWireGuardDevice(peer.id) } label: {
                    Text("Resume")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.filledButton)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier("device.resume")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }
}

/// Under a device's row on the main screen: its config points at an old address of this iPhone,
/// see `HotspotSession.needsNewConfig`. The text keeps the label colour, since orange or grey text on
/// the grouped background fails the contrast audit. The icon carries the orange.
struct OldAddressLabel: View {
    var body: some View {
        Label {
            Text("Its config points at an old address. Add it again.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

/// "Connected", "Not connected" or "Paused", see `DeviceStatus`. The text keeps the label colour in
/// every state, since green, orange or grey text on the grouped background fails the contrast audit.
/// The icon tells them apart. It sits beside the text rather than in a Label, whose text element
/// spans the icon too, so the audit read the orange icon on the card as text that fails. VoiceOver
/// skips it, since the word says the same. `text` is the row's word, or the screen's title.
struct DeviceStatusLabel: View {
    let status: DeviceStatus
    var text: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch status {
                case .connected: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .notConnected: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                }
            }
            .accessibilityHidden(true)
            Text(text ?? status.label)
        }
    }
}
