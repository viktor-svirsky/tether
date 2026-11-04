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

/// One device: whether it's connected, its data this month and last, when it last connected, and
/// removing it. Tapping the title renames it. A rename or removal that couldn't be saved says so at
/// the top, and so does a config that points at an old address of this iPhone.
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
    private var usage: DeviceUsage { model.deviceUsage[peer.id] ?? DeviceUsage() }

    var body: some View {
        ScrollViewReader { list in
            content
                // Remove is at the bottom, and at a large text size the top is off screen, so a
                // problem that appears there is scrolled to and read out.
                .onChange(of: problem) { _, problem in
                    guard let problem else { return }
                    withAnimation { list.scrollTo(Self.problemRow, anchor: .top) }
                    AccessibilityNotification.Announcement(problem).post()
                }
        }
    }

    private static let problemRow = "problem"

    private var content: some View {
        List {
            // On top, where a rename is made, and the screen a failed removal stays on.
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("device.problem")
                }
                .id(Self.problemRow)
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
                    ConnectedLabel(connected: connected)
                        .accessibilityIdentifier("device.status")
                    if !connected, usage.lastConnected == nil {
                        Text("It hasn't connected yet.")
                            .font(.subheadline)
                            .foregroundStyle(Color.detailText)
                            .accessibilityIdentifier("device.statusDetail")
                    }
                }
            }
            Section {
                DataUseCard(usage: usage, now: model.now)
            }
            Section {
                ValueRow(title: "Last month", value: Format.lastMonth(usage.lastMonth))
                    .accessibilityIdentifier("device.lastMonth")
                // While it's connected, the status says it.
                if !connected {
                    ValueRow(title: "Last connected", value: Format.lastConnected(usage.lastConnected, now: model.now, calendar: .current))
                        .accessibilityIdentifier("device.lastConnected")
                }
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

/// A device's data this month, both ways together, then down and up, and when the count starts again.
struct DataUseCard: View {
    let usage: DeviceUsage
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Format.thisMonth(usage.thisMonth))
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("device.thisMonth")
            // Side by side, or one under the other where they don't fit, at a large text size.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { resets; Spacer(); downAndUp }
                VStack(alignment: .leading, spacing: 4) { resets; downAndUp }
            }
            .font(.footnote)
        }
        .padding(.vertical, 4)
    }

    private var resets: some View {
        Text(Format.resetsOn(now: now, calendar: .current))
            .foregroundStyle(Color.detailText)
            .accessibilityIdentifier("device.resets")
    }

    /// One text, so VoiceOver reads it as one line, in its two colours.
    private var downAndUp: some View {
        (Text("↓ \(Format.bytes(usage.thisMonth.bytesDown))").foregroundStyle(Direction.download)
            + Text("  ")
            + Text("↑ \(Format.bytes(usage.thisMonth.bytesUp))").foregroundStyle(Direction.upload))
            .monospacedDigit()
            .accessibilityLabel(Format.downAndUpSpoken(usage.thisMonth))
            .accessibilityIdentifier("device.downAndUp")
    }
}

/// A title and its value in one row, read as one by VoiceOver. The value keeps a grey that passes
/// the contrast audit, unlike LabeledContent's.
struct ValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(Color.detailText)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
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

/// "Connected" or "Not connected". The text keeps the label colour in both states, since green or
/// grey text on the grouped background fails the contrast audit. The icon tells them apart.
struct ConnectedLabel: View {
    let connected: Bool

    var body: some View {
        Label {
            Text(connected ? "Connected" : "Not connected")
        } icon: {
            Image(systemName: connected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(connected ? .green : .secondary)
        }
    }
}
