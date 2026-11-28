import SwiftUI

/// One device: whether it's connected or paused, pausing and resuming it, what it used against its
/// data limit, renaming it, and removing it. Rename, or tapping the title, renames it (#173). A change
/// that couldn't be saved says so at the top, and so does a config that no longer reaches this iPhone,
/// with the way to give it a new one (M1). Paper and ink (#349): its name big on top, the usage in the
/// floating card, the rest as plain rows. Pause comes right after the status, Rename next to Remove (L6).
struct DeviceView: View {
    @ObservedObject var model: Model
    let peer: WireGuardSetup.Peer
    @State private var confirmRemove = false
    @State private var limitQuestions = LimitQuestions()
    @State private var renaming = false
    @State private var typedName = ""
    /// Selects the name when its field starts editing, see `SelectsAllOnEdit`.
    @State private var selectsName = false
    /// Add a device, giving this one a new config (M1).
    @State private var givingNewConfig = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The saved device, so a new name shows at once.
    private var current: WireGuardSetup.Peer { model.wireGuardPeers.first { $0.id == peer.id } ?? peer }
    private var status: DeviceStatus { DeviceStatus(current, connected: model.wireGuardConnected, keptOut: model.blockedWithoutVPN, onlyFamily: model.vpnOnlyFamily) }
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

    private var limitChoice: DataLimitChoice {
        DataLimitChoice(name: current.name, limit: current.limit, paused: current.paused,
                        used: model.usage(of: peer.id).thisMonth.total, resets: model.nextResetDay) { model.setLimit(peer.id, $0) }
    }

    var body: some View {
        let newConfig = model.newConfig(current)
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
                if let newConfig {
                    Section {
                        InkWarningLabel(newConfig == .nameNotAnswered
                                        ? "Its config uses this iPhone's name, which isn't answering on the hotspot, so it can't connect."
                                        : "Its config points at an old address of this iPhone, so it can't connect.")
                            .accessibilityIdentifier("device.oldAddress")
                        // Add a device for this entry: the new code takes its place, with its name, limit and use.
                        Button {
                            model.openAddWindow(replacing: peer.id)
                            givingNewConfig = true
                        } label: {
                            InkOutline(title: Copy.giveNewConfig)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("device.newConfig")
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
                        // What to do on that device (M1), unless the warning above says it needs a new config.
                        if status == .notConnected, newConfig == nil {
                            Text(Copy.notConnectedHint)
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(DeviceScreenMotion.appear)
                                .accessibilityIdentifier("device.notConnectedHint")
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
                    .animation(PaperMotion.change(reduceMotion: reduceMotion), value: rows)
                    // Only while it isn't connected (#73): connected says it all, and a paused one says why.
                    if status == .notConnected {
                        LabeledContent { Text(model.lastConnected(of: peer.id)).foregroundStyle(Theme.secondary) } label: { DashLabel("Last connected") }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("device.lastConnected")
                    }
                }
                .paperRow()
                PauseSection(paused: current.paused != nil, id: "device",
                             footer: "Pause stops it from connecting for a while, or until you resume it.",
                             pause: { model.pauseWireGuardDevice(peer.id, for: $0) },
                             resume: { model.resumeWireGuardDevice(peer.id) })
                usageSection
                Section {
                    // A row anyone finds, since the title's menu is easy to miss (#173).
                    Button {
                        typedName = current.name
                        selectsName = true
                        renaming = true
                    } label: {
                        Text("Rename").underline().foregroundStyle(Theme.ink)
                    }
                    .accessibilityIdentifier("device.rename")
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
            .animation(PaperMotion.change(reduceMotion: reduceMotion), value: rows)
            // Remove is at the bottom, so a removal that fails says so up there, out of sight with large text.
            .onChange(of: problem) { _, problem in
                if problem != nil { withAnimation(PaperMotion.change(reduceMotion: reduceMotion)) { proxy.scrollTo("problem", anchor: .top) } }
            }
        }
        .navigationTitle(Binding(get: { current.name }, set: { model.renameWireGuardDevice(peer.id, to: $0) }))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .dataLimitQuestions($limitQuestions, limitChoice)
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
        // Closing it any way leaves this device as it was, unless its new config was claimed.
        .sheet(isPresented: $givingNewConfig) { AddDeviceSheet(model: model) }
    }
}

extension DeviceView {
    /// What it used, both ways, counted the way the main screen counts (#75). iOS Settings > Cellular
    /// adds the iPhone's own headers on top, so it says "through Tether". The card says when the count
    /// resets, so the footer doesn't say it again (L7), unless there's no limit and so no date on the card.
    private var usageSection: some View {
        let usage = model.usage(of: peer.id)
        let resets = model.nextResetDay
        return Section {
            UsageCard(month: usage.thisMonth, limit: current.limit, period: model.usagePeriod, resets: resets)
                .accessibilityIdentifier("device.thisMonth")
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            if model.overLimit(peer.id) {
                Text("Over its limit until \(resets), because you resumed it.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("device.overLimit")
            }
            LabeledContent { Text(Format.bytes(usage.lastMonth.total)).foregroundStyle(Theme.secondary) } label: { DashLabel(model.lastPeriodLabel) }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("device.lastMonth")
            DataLimitPicker(choice: limitChoice, questions: $limitQuestions, id: "device.limit")
        } header: {
            PaperHeader(title: "Data through Tether")
        } footer: {
            Text(current.limit == nil
                 ? "Counts data both ways. With a limit, Tether pauses \(current.name) when it reaches it, until the count resets on \(resets)."
                 : "Counts data both ways. When \(current.name) reaches it, Tether pauses \(current.name) until the count resets. You can resume it sooner.")
                .foregroundStyle(Theme.secondary)
                .accessibilityIdentifier("device.limitFooter")
        }
        .paperRow()
    }
}

/// Under a device's row on the main screen: its config points at an old address of this iPhone,
/// see `HotspotSession.needsNewConfig`. The text keeps the label colour, since orange or grey text on
/// the grouped background fails the contrast audit. The icon carries the orange.
struct OldAddressLabel: View {
    var reason = HotspotSession.NewConfig.oldAddress

    var body: some View {
        Label {
            Text(reason == .nameNotAnswered ? "Its config uses this iPhone's name, which isn't answering. \(Copy.giveNewConfig)."
                 : "Its config points at an old address. \(Copy.giveNewConfig).")
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
                case .keptOut: Image(systemName: "lock.shield").foregroundStyle(.orange)
                }
            }
            .accessibilityHidden(true)
            Text(text ?? status.label)
        }
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
