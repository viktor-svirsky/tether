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
    /// Other amount, typed in GB.
    @State private var typingLimit = false
    @State private var typedLimit = ""
    @Environment(\.dismiss) private var dismiss

    /// The saved device, so a new name shows at once.
    private var current: WireGuardSetup.Peer { model.wireGuardPeers.first { $0.id == peer.id } ?? peer }
    private var status: DeviceStatus { DeviceStatus(current, connected: model.wireGuardConnected) }
    /// A change to this device that couldn't be saved.
    private var problem: String? { model.wireGuardDeviceProblem.flatMap { $0.device == peer.id ? $0.text : nil } }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                // On top, where a rename is made, and the screen a failed removal stays on.
                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .accessibilityIdentifier("device.problem")
                    }
                    .id("problem")
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
                        if let detail = status.detail(resets: model.nextResetDay) {
                            // The label colour, like the status: grey text on the card fails the contrast audit.
                            Text(detail)
                                .font(.subheadline)
                                .accessibilityIdentifier("device.statusDetail")
                        }
                    }
                    // Only while it isn't connected (#73): connected says it all, and a paused one says why.
                    if status == .notConnected {
                        LabeledContent("Last connected", value: model.lastConnected(of: peer.id))
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("device.lastConnected")
                    }
                }
                pauseSection
                usageSection
                Section {
                    Button("Remove device", role: .destructive) { confirmRemove = true }
                        .accessibilityIdentifier("device.remove")
                } footer: {
                    Text("It can't connect any more. Delete its tunnel in its WireGuard app too.")
                }
            }
            // Remove is at the bottom, so a removal that fails says so up there, out of sight with large text.
            .onChange(of: problem) { _, problem in
                if problem != nil { withAnimation { proxy.scrollTo("problem", anchor: .top) } }
            }
        }
        .navigationTitle(Binding(get: { current.name }, set: { model.renameWireGuardDevice(peer.id, to: $0) }))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .alert("Data limit", isPresented: $typingLimit) {
            TextField("GB", text: $typedLimit)
                .keyboardType(.decimalPad)
            Button("Set") {
                if let bytes = DataLimit.bytes(typedGB: typedLimit) { model.setLimit(peer.id, bytes) }
            }
            // Nothing to set until it's an amount, rather than closing as if it were.
            .disabled(DataLimit.bytes(typedGB: typedLimit) == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Per month, both ways, in GB.")
        }
        .confirmationDialog("Remove \(current.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                // A removal that couldn't be saved stays here, and the screen says so.
                if model.removeWireGuardDevice(peer.id) { dismiss() }
            }
        }
    }
}

extension DeviceView {
    /// What it used, both ways, counted the way the main screen counts (#75). iOS Settings > Cellular
    /// adds the iPhone's own headers on top, so it says "through Tether".
    /// With a limit, a meter of this month against it and when the count resets (#75). Without one,
    /// this month as a big number (#73). Either way down and up under it, once there's any.
    private var usageSection: some View {
        let usage = model.usage(of: peer.id)
        let used = usage.thisMonth.total
        let resets = model.nextResetDay
        return Section {
            if let limit = current.limit {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(Format.bytes(used)) of \(Format.bytes(limit)) this month")
                        .font(.headline)
                    if used > 0 { downAndUp(usage.thisMonth) }
                    LimitMeter(fraction: limit == 0 ? 1 : min(1, Double(used) / Double(limit)), over: used >= limit)
                    Text("Resets on \(resets)")
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("device.thisMonth")
                if model.overLimit(peer.id) {
                    // The label colour, like the status: grey text on the card fails the contrast audit.
                    Text("Over its limit until \(resets), because you resumed it.")
                        .font(.subheadline)
                        .accessibilityIdentifier("device.overLimit")
                }
            } else if used == 0 {
                Text("Not used this month")
                    .font(.headline)
                    .accessibilityIdentifier("device.thisMonth")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    // One text, so it wraps with large text instead of squeezing the number.
                    Text("\(Text(Format.bytes(used)).font(.title.bold())) this month")
                        .font(.headline)
                    downAndUp(usage.thisMonth)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("device.thisMonth")
            }
            LabeledContent("Last month", value: Format.bytes(usage.lastMonth.total))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("device.lastMonth")
            Picker("Limit", selection: Binding(get: { LimitPick.preset(current.limit) }, set: { pick in
                switch pick {
                case let .preset(limit): model.setLimit(peer.id, limit)
                case .other:
                    typedLimit = ""
                    typingLimit = true
                }
            })) {
                ForEach(limitPicks, id: \.self) { pick in
                    switch pick {
                    case let .preset(limit): Text(DataLimit.label(limit)).tag(pick)
                    case .other: Text("Other amount").tag(pick)
                    }
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("device.limit")
        } header: {
            Text("Data through Tether")
        } footer: {
            Text(current.limit == nil
                 ? "Counts data both ways. With a limit, Tether pauses \(current.name) when it reaches it, until the count resets on \(resets)."
                 : "Counts data both ways. When \(current.name) reaches it, Tether pauses \(current.name) until the count resets on \(resets). You can resume it sooner.")
                // In the label colour: this footer's grey just misses the contrast audit.
                .foregroundStyle(Color(.label))
                .accessibilityIdentifier("device.limitFooter")
        }
    }

    /// "↓ 3 GB ↑ 120 MB", which VoiceOver reads as "3 GB down, 120 MB up" rather than the arrows.
    private func downAndUp(_ month: TrafficTotals) -> some View {
        let down = Format.bytes(month.bytesDown), up = Format.bytes(month.bytesUp)
        return Text("↓ \(down) ↑ \(up)")
            .font(.subheadline)
            .accessibilityLabel("\(down) down, \(up) up")
    }

    /// The menu's choices, with a typed amount the device has, then Other amount.
    private var limitPicks: [LimitPick] {
        var picks = DataLimit.choices.map(LimitPick.preset)
        if let limit = current.limit, !DataLimit.choices.contains(limit) { picks.append(.preset(limit)) }
        return picks + [.other]
    }

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

/// A choice in a device's Limit menu.
private enum LimitPick: Hashable {
    case preset(UInt64?)
    case other
}

/// This month's data against the limit, in the app icon's blue-to-teal, or orange, the pause's
/// colour, at the limit or over it, so a full bar never reads as all well.
private struct LimitMeter: View {
    let fraction: Double
    let over: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(over ? AnyShapeStyle(Color.orange) : AnyShapeStyle(LinearGradient(colors: StatusOrb.iconColors, startPoint: .leading, endPoint: .trailing)))
                    .frame(width: max(8, geometry.size.width * fraction))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
