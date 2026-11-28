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
    @State private var confirmReset = false

    var body: some View {
        if let problem = model.wireGuardProblem {
            Section {
                WarningLabel(problem)
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

/// One device: whether it's connected or paused, renaming it, pausing and resuming it, and removing
/// it. Rename, or tapping the title, renames it (#173). A change that couldn't be saved says so at the top, and so does a config
/// that points at an old address of this iPhone. Paper and ink (#349): its name big on top, the usage
/// in the floating card, the rest as plain rows.
struct DeviceView: View {
    @ObservedObject var model: Model
    let peer: WireGuardSetup.Peer
    @State private var confirmRemove = false
    /// Other amount, typed in GB.
    @State private var typingLimit = false
    @State private var typedLimit = ""
    @State private var renaming = false
    @State private var typedName = ""
    /// Selects the name when its field starts editing, see `SelectsAllOnEdit`.
    @State private var selectsName = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The saved device, so a new name shows at once.
    private var current: WireGuardSetup.Peer { model.wireGuardPeers.first { $0.id == peer.id } ?? peer }
    private var status: DeviceStatus { DeviceStatus(current, connected: model.wireGuardConnected) }
    /// A change to this device that couldn't be saved.
    private var problem: String? { model.wireGuardDeviceProblem.flatMap { $0.device == peer.id ? $0.text : nil } }

    /// What decides which rows the screen has. A change eases them in and out. The counts that tick
    /// while it's used are not in it: their texts roll on their own, see `deviceScreenChange`.
    private struct Rows: Equatable {
        let status: DeviceStatus
        let problem: String?
        let newConfig: HotspotSession.NewConfig?
        let connectsFrom: Bool
        let limited: Bool
        let used: Bool
        let overLimit: Bool
    }

    private var rows: Rows {
        Rows(status: status, problem: problem, newConfig: model.newConfig(current),
             connectsFrom: status == .connected && model.connectsFrom(of: peer.id) != nil,
             limited: current.limit != nil, used: model.usage(of: peer.id).thisMonth.total > 0,
             overLimit: model.overLimit(peer.id))
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                // On top, where a rename is made, and the screen a failed removal stays on.
                if let problem {
                    Section {
                        InkWarningLabel(problem)
                            .accessibilityIdentifier("device.problem")
                    }
                    .paperRow()
                    .id("problem")
                }
                if let reason = model.newConfig(current) {
                    Section {
                        InkWarningLabel(reason == .nameNotAnswered
                                        ? "Its config uses this iPhone's name, which isn't answering on the hotspot, so it can't connect. Remove it, then add it again."
                                        : "Its config points at an old address of this iPhone, so it can't connect. Remove it, then add it again.")
                            .accessibilityIdentifier("device.oldAddress")
                    }
                    .paperRow()
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        DeviceScreenTitle(name: current.name, live: status == .connected)
                        Text(status.title(now: model.clockNow))
                            .font(.body)
                            .tracking(0.4)
                            .foregroundStyle(Theme.ink)
                            .deviceScreenChange(status.title(now: model.clockNow), reduceMotion: reduceMotion)
                            .accessibilityIdentifier("device.status")
                        if let detail = status.detail(resets: model.nextResetDay, period: model.usagePeriod) {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(DeviceScreenMotion.appear)
                                .accessibilityIdentifier("device.statusDetail")
                        }
                        // While it's connected, the address its handshake comes from, once the server says (#73).
                        // It goes under the status like a paused device's detail line, so the Pause and Resume
                        // button stays in the same place.
                        if status == .connected, let address = model.connectsFrom(of: peer.id) {
                            Text("Connects from \(address)")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                                .transition(DeviceScreenMotion.appear)
                                .accessibilityIdentifier("device.connectsFrom")
                        }
                    }
                    .animation(DeviceScreenMotion.rows(reduceMotion: reduceMotion), value: rows)
                    // Only while it isn't connected (#73): connected says it all, and a paused one says why.
                    if status == .notConnected {
                        LabeledContent { Text(model.lastConnected(of: peer.id)).foregroundStyle(Theme.secondary) } label: { DetailLabel("Last connected") }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("device.lastConnected")
                    }
                }
                .paperRow()
                // A row anyone finds, since the title's menu is easy to miss (#173).
                Section {
                    Button {
                        typedName = current.name
                        selectsName = true
                        renaming = true
                    } label: {
                        Text("Rename").underline().foregroundStyle(Theme.ink)
                    }
                    .accessibilityIdentifier("device.rename")
                }
                .paperRow()
                pauseSection
                usageSection
                Section {
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Text("Remove device").foregroundStyle(Theme.danger)
                    }
                    .accessibilityIdentifier("device.remove")
                } footer: {
                    Text("After that it can't connect. Delete its tunnel in its WireGuard app too.")
                        .foregroundStyle(Theme.secondary)
                }
                .paperRow()
            }
            .paperList()
            .tint(Theme.ink)
            // Closer than a grouped list's gaps, like the board's rows.
            .listSectionSpacing(12)
            .animation(DeviceScreenMotion.rows(reduceMotion: reduceMotion), value: rows)
            // Remove is at the bottom, so a removal that fails says so up there, out of sight with large text.
            .onChange(of: problem) { _, problem in
                if problem != nil { withAnimation(DeviceScreenMotion.rows(reduceMotion: reduceMotion)) { proxy.scrollTo("problem", anchor: .top) } }
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
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $typedName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("Save") {
                if let name = DeviceName.toSave(typed: typedName, current: current.name) { model.renameWireGuardDevice(peer.id, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .modifier(SelectsAllOnEdit(pending: $selectsName))
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
    /// In the floating card: the period as a small label, this month as a big number, and with a limit
    /// a meter against it and when the count resets (#75). Either way down and up under it, once
    /// there's any. VoiceOver reads the card as one line, as it did before the card.
    private var usageSection: some View {
        let usage = model.usage(of: peer.id)
        let used = usage.thisMonth.total
        let resets = model.nextResetDay, period = model.usagePeriod
        return Section {
            Group {
                if let limit = current.limit {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(period).monoCaps()
                        bigNumber(Format.bytes(used), of: " of \(Format.bytes(limit))")
                        if used > 0 { downAndUp(usage.thisMonth) }
                        let fraction = limit == 0 ? 1 : min(1, Double(used) / Double(limit))
                        // Keyed on whole percents, so a traffic sample that doesn't move the line doesn't animate.
                        LimitMeter(fraction: fraction)
                            .animation(reduceMotion ? nil : DeviceScreenMotion.ease, value: Int(fraction * 100))
                        Text("Resets on \(resets)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken(["\(Format.bytes(used)) of \(Format.bytes(limit)) \(period)",
                                                used > 0 ? downAndUpSpoken(usage.thisMonth) : nil,
                                                "Resets on \(resets)"]))
                } else if used == 0 {
                    Text(Format.used(0, period))
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(period).monoCaps()
                        bigNumber(Format.bytes(used), of: nil)
                        downAndUp(usage.thisMonth)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken(["\(Format.bytes(used)) \(period)", downAndUpSpoken(usage.thisMonth)]))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .liveCard()
            .accessibilityIdentifier("device.thisMonth")
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            if model.overLimit(peer.id) {
                Text("Over its limit until \(resets), because you resumed it.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("device.overLimit")
            }
            LabeledContent { Text(Format.bytes(usage.lastMonth.total)).foregroundStyle(Theme.secondary) } label: { DetailLabel(model.lastPeriodLabel) }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("device.lastMonth")
            Picker(selection: Binding(get: { LimitPick.preset(current.limit) }, set: { pick in
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
            } label: {
                DetailLabel("Limit")
            }
            .pickerStyle(.menu)
            .tint(Theme.secondary)
            .accessibilityIdentifier("device.limit")
        } header: {
            DetailHeader("Data through Tether")
        } footer: {
            Text(current.limit == nil
                 ? "Counts data both ways. With a limit, Tether pauses \(current.name) when it reaches it, until the count resets on \(resets)."
                 : "Counts data both ways. When \(current.name) reaches it, Tether pauses \(current.name) until the count resets on \(resets). You can resume it sooner.")
                .foregroundStyle(Theme.secondary)
                .accessibilityIdentifier("device.limitFooter")
        }
        .paperRow()
    }

    /// "3.12 GB" big, with " of 10 GB" after it in the second colour. The number rolls as it grows.
    private func bigNumber(_ number: String, of rest: String?) -> some View {
        // One text, so it wraps with large text instead of squeezing the number.
        Text("\(Text(number).font(.largeTitle.weight(.medium)).foregroundStyle(Theme.ink))\(Text(rest ?? "").font(.subheadline).foregroundStyle(Theme.secondary))")
            .fixedSize(horizontal: false, vertical: true)
            .deviceScreenChange(number + (rest ?? ""), numbers: true, reduceMotion: reduceMotion)
    }

    /// "↓ 3 GB ↑ 120 MB", which VoiceOver reads as "3 GB down, 120 MB up" rather than the arrows.
    private func downAndUp(_ month: TrafficTotals) -> some View {
        let down = Format.bytes(month.bytesDown), up = Format.bytes(month.bytesUp)
        return Text("↓ \(down) ↑ \(up)")
            .font(.subheadline)
            .foregroundStyle(Theme.secondary)
            .deviceScreenChange("\(down) \(up)", numbers: true, reduceMotion: reduceMotion)
            .accessibilityLabel(downAndUpSpoken(month))
    }

    private func downAndUpSpoken(_ month: TrafficTotals) -> String {
        "\(Format.bytes(month.bytesDown)) down, \(Format.bytes(month.bytesUp)) up"
    }

    /// The card's lines as VoiceOver reads them, the way a combined element joins its texts.
    private func spoken(_ lines: [String?]) -> String {
        lines.compactMap { $0 }.joined(separator: ", ")
    }

    /// The menu's choices, with a typed amount the device has, then Other amount.
    private var limitPicks: [LimitPick] { LimitPick.picks(current.limit) }

    /// Under the status: Pause, outlined in ink, or Resume once it's paused, filled in ink since
    /// it's the main action then. Both sit in the same place.
    @ViewBuilder private var pauseSection: some View {
        if current.paused == nil {
            Section {
                // How long, as Do Not Disturb asks (#312). The last one is the pause it always was.
                Menu {
                    ForEach(WireGuardSetup.PauseLength.allCases, id: \.self) { length in
                        Button(length.title) { model.pauseWireGuardDevice(peer.id, for: length) }
                    }
                } label: {
                    // The whole row opens it, as the button it replaced did.
                    InkOutline(title: "Pause")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("device.pause")
            } footer: {
                Text("Pause stops it from connecting for a while, or until you resume it.")
                    .foregroundStyle(Theme.secondary)
            }
            .paperRow()
        } else {
            Section {
                Button { model.resumeWireGuardDevice(peer.id) } label: {
                    Text("Resume")
                        .font(.headline)
                        .foregroundStyle(Theme.paper)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.ink, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("device.resume")
            }
            .paperRow()
            .listRowInsets(EdgeInsets())
        }
    }
}

/// Under a device's row on the main screen: its config points at an old address of this iPhone,
/// see `HotspotSession.needsNewConfig`. The text keeps the label colour, since orange or grey text on
/// the grouped background fails the contrast audit. The icon carries the orange.
struct OldAddressLabel: View {
    var reason = HotspotSession.NewConfig.oldAddress

    var body: some View {
        Label {
            Text(reason == .nameNotAnswered ? "Its config uses this iPhone's name, which isn't answering. Add it again."
                 : "Its config points at an old address. Add it again.")
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

/// A choice in a device's Limit menu, and the proxy's.
enum LimitPick: Hashable {
    case preset(UInt64?)
    case other

    /// The menu's choices, with a typed amount `limit` is, then Other amount.
    static func picks(_ limit: UInt64?) -> [LimitPick] {
        var picks = DataLimit.choices.map(LimitPick.preset)
        if let limit, !DataLimit.choices.contains(limit) { picks.append(.preset(limit)) }
        return picks + [.other]
    }
}

/// This month's data against the limit: a thin ink line on a faint track, like the board. At the
/// limit the line is full, and the words under the card say what that means.
private struct LimitMeter: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.dot)
                Rectangle()
                    .fill(Theme.ink)
                    .frame(width: max(3, geometry.size.width * fraction))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// A problem on a list row, with the orange warning icon the main screen uses.
struct WarningLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityHidden(true) // the text says it all, and iOS 26 would read the symbol
        }
    }
}
