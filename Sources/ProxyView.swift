import SwiftUI

/// The HTTP proxy's own screen, from its row under Devices (#78), like a device's: whether a device
/// has a connection open, what it used, where it is with Copy, Pause, its data limit, what still goes
/// out as hotspot data, and Turn off. Paused and limited by its id, the way a device is.
struct ProxyView: View {
    @ObservedObject var model: Model
    /// Other amount, typed in GB.
    @State private var typingLimit = false
    @State private var typedLimit = ""
    /// Pause was turned on: how long is asked, as for a device (#312).
    @State private var askingPauseLength = false
    @Environment(\.dismiss) private var dismiss

    /// Off once turned off from here, until the screen goes.
    private var proxy: WireGuardSetup.Proxy { model.proxy ?? WireGuardSetup.Proxy(on: false) }
    private var status: ProxyStatus { ProxyStatus(proxy, stats: model.proxyStats, hotspotOn: model.running) }
    /// A pause, limit or turn off that couldn't be saved.
    private var problem: String? {
        model.wireGuardDeviceProblem.flatMap { $0.device == proxy.id ? $0.text : nil } ?? model.proxyProblem
    }

    var body: some View {
        let servers = ProxyAddress.servers(model.proxyStats.addresses)
        List {
            if let problem {
                Section {
                    WarningLabel(problem)
                        .accessibilityIdentifier("proxy.problem")
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Status") {
                        DeviceStatusLabel(status: status.look, text: status.title(now: model.clockNow))
                            .foregroundStyle(Color.primary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("proxy.status")
                    if let detail = status.detail(resets: model.nextResetDay, period: model.usagePeriod) {
                        // The label colour, like a device's: grey text on the card fails the contrast audit.
                        Text(detail)
                            .font(.subheadline)
                            .accessibilityIdentifier("proxy.statusDetail")
                    }
                }
                usageRow
                serverRow(servers[0], label: "Server", copyLabel: "Copy the server", id: "proxy.server")
                if servers.count > 1 {
                    serverRow(servers[1], label: "Server for an iPhone, iPad or Mac", copyLabel: "Copy that server", id: "proxy.serverIPv6")
                }
                serverRow(ProxyAddress.port, label: "Port", copyLabel: "Copy the port", id: "proxy.port")
                Toggle("Pause", isOn: Binding(get: { proxy.paused != nil }, set: { pause in
                    if pause { askingPauseLength = true } else { model.resumeWireGuardDevice(proxy.id) }
                }))
                .accessibilityIdentifier("proxy.pause")
                limitPicker
            } footer: {
                Text("Games, calls and apps that skip the proxy still go out as hotspot data. For those, use WireGuard on that device.")
                    // In the label colour: a footer's grey just misses the contrast audit.
                    .foregroundStyle(Color(.label))
                    .accessibilityIdentifier("proxy.note")
            }
            Section {
                Button("Turn off the proxy", role: .destructive) {
                    model.setProxy(on: false)
                    if !model.proxyOn { dismiss() }
                }
                .accessibilityIdentifier("proxy.off")
            }
        }
        .navigationTitle(ProxyStatus.name)
        .navigationBarTitleDisplayMode(.inline)
        // On the list, not the row: on the row its choices didn't run.
        .confirmationDialog("Pause", isPresented: $askingPauseLength, titleVisibility: .hidden) {
            ForEach(WireGuardSetup.PauseLength.allCases, id: \.self) { length in
                Button(length.title) { model.pauseWireGuardDevice(proxy.id, for: length) }
            }
        }
        .alert("Data limit", isPresented: $typingLimit) {
            TextField("GB", text: $typedLimit)
                .keyboardType(.decimalPad)
            Button("Set") {
                if let bytes = DataLimit.bytes(typedGB: typedLimit) { model.setLimit(proxy.id, bytes) }
            }
            .disabled(DataLimit.bytes(typedGB: typedLimit) == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Per month, both ways, in GB.")
        }
    }

    /// "This month 85 MB", or "85 MB of 10 GB" with a limit, counted like a device's (#75).
    private var usageRow: some View {
        let used = model.usage(of: proxy.id).thisMonth.total
        let value = proxy.limit.map { "\(Format.bytes(used)) of \(Format.bytes($0))" } ?? Format.bytes(used)
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent(Self.capitalized(model.usagePeriod), value: value)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("proxy.thisMonth")
            if model.overLimit(proxy.id) {
                Text("Over its limit until \(model.nextResetDay), because you resumed it.")
                    .font(.subheadline)
                    .accessibilityIdentifier("proxy.overLimit")
            }
        }
    }

    /// "this month" as a row's label.
    private static func capitalized(_ period: String) -> String {
        period.prefix(1).uppercased() + period.dropFirst()
    }

    /// The server or the port, typed into the device, with a button that copies it.
    private func serverRow(_ text: String, label: String, copyLabel: String, id: String) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                AddressText(text)
                    .foregroundStyle(Color.primary)
                    .accessibilityLabel(label)
                    .accessibilityValue(text)
                    .accessibilityIdentifier(id)
                CopyButton(text: text, label: copyLabel, fill: Color(.tertiarySystemFill))
                    .accessibilityIdentifier("\(id).copy")
            }
        } label: {
            // Not hidden from VoiceOver: the audit flags text on screen it can't reach.
            Text(label)
        }
    }

    private var limitPicker: some View {
        Picker("Data limit", selection: Binding(get: { LimitPick.preset(proxy.limit) }, set: { pick in
            switch pick {
            case let .preset(limit): model.setLimit(proxy.id, limit)
            case .other:
                typedLimit = ""
                typingLimit = true
            }
        })) {
            ForEach(LimitPick.picks(proxy.limit), id: \.self) { pick in
                switch pick {
                case let .preset(limit): Text(DataLimit.label(limit)).tag(pick)
                case .other: Text("Other amount").tag(pick)
                }
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("proxy.limit")
    }
}
