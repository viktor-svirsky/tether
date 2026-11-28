import SwiftUI

/// The HTTP proxy's own screen, from its row under Devices (#78), like a device's: whether a device
/// has a connection open, what it used, where it is with Copy, Pause, its data limit, what still goes
/// out as hotspot data, and Turn off. Paused and limited by its id, the way a device is. Paper and
/// ink (#349), the same look as a device's screen.
struct ProxyView: View {
    @ObservedObject var model: Model
    /// Other amount, typed in GB.
    @State private var typingLimit = false
    @State private var typedLimit = ""
    /// Pause was turned on: how long is asked, as for a device (#312).
    @State private var askingPauseLength = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Off once turned off from here, until the screen goes.
    private var proxy: WireGuardSetup.Proxy { model.proxy ?? WireGuardSetup.Proxy(on: false) }
    private var status: ProxyStatus { ProxyStatus(proxy, stats: model.proxyStats, hotspotOn: model.running, keptOut: model.blockedWithoutVPN) }
    /// A pause, limit or turn off that couldn't be saved.
    private var problem: String? {
        model.wireGuardDeviceProblem.flatMap { $0.device == proxy.id ? $0.text : nil } ?? model.proxyProblem
    }

    /// What decides which rows the screen has, see `DeviceView.Rows`. The look, not the count of
    /// connections, so 2 open turning into 3 rolls the number without moving the rows.
    private struct Rows: Equatable {
        let look: DeviceStatus
        let detail: Bool
        let problem: String?
        let servers: Int
        let limited: Bool
        let overLimit: Bool
    }

    private func rows(servers: Int) -> Rows {
        Rows(look: status.look, detail: status.detail(resets: model.nextResetDay, period: model.usagePeriod) != nil, problem: problem, servers: servers, limited: proxy.limit != nil, overLimit: model.overLimit(proxy.id))
    }

    var body: some View {
        let servers = ProxyAddress.servers(model.proxyStats.addresses)
        List {
            if let problem {
                Section {
                    InkWarningLabel(problem)
                        .accessibilityIdentifier("proxy.problem")
                }
                .paperRow()
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    DeviceScreenTitle(name: ProxyStatus.name, live: status.inUse)
                    let title = status.title(now: model.clockNow)
                    Text(title)
                        .font(.body)
                        .tracking(0.4)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .deviceScreenChange(title, numbers: true, reduceMotion: reduceMotion)
                        // Read as the row it was, "Status, 2 connections open".
                        .accessibilityLabel("Status, \(title)")
                        .accessibilityIdentifier("proxy.status")
                    if let detail = status.detail(resets: model.nextResetDay, period: model.usagePeriod) {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(DeviceScreenMotion.appear)
                            .accessibilityIdentifier("proxy.statusDetail")
                    }
                }
                .animation(PaperMotion.change(reduceMotion: reduceMotion), value: rows(servers: servers.count))
            }
            .paperRow()
            usageSection
            Section {
                serverRow(servers[0], label: "Server", copyLabel: "Copy the server", id: "proxy.server")
                if servers.count > 1 {
                    serverRow(servers[1], label: "Server for an iPhone, iPad or Mac", copyLabel: "Copy that server", id: "proxy.serverIPv6")
                }
                serverRow(ProxyAddress.port, label: "Port", copyLabel: "Copy the port", id: "proxy.port")
                Toggle(isOn: Binding(get: { proxy.paused != nil }, set: { pause in
                    if pause { askingPauseLength = true } else { model.resumeWireGuardDevice(proxy.id) }
                })) {
                    DashLabel("Pause")
                }
                .toggleStyle(.ink)
                .accessibilityIdentifier("proxy.pause")
                limitPicker
            } header: {
                PaperHeader(title: "Details")
            } footer: {
                Text("Games, calls and apps that skip the proxy still go out as hotspot data. For those, use WireGuard on that device.")
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("proxy.note")
            }
            .paperRow()
            Section {
                Button(role: .destructive) {
                    model.setProxy(on: false)
                    if !model.proxyOn { dismiss() }
                } label: {
                    Text("Turn off the proxy").foregroundStyle(Theme.danger)
                }
                .accessibilityIdentifier("proxy.off")
            }
            .paperRow()
        }
        .paperList()
        .tint(Theme.ink)
        // Closer than a grouped list's gaps, like the board's rows.
        .listSectionSpacing(12)
        .animation(PaperMotion.change(reduceMotion: reduceMotion), value: rows(servers: servers.count))
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

    /// "85 MB" big in the floating card, or "85 MB of 10 GB" with a limit, counted like a device's
    /// (#75). VoiceOver reads it as the row it was, "This month, 85 MB".
    private var usageSection: some View {
        let used = Format.bytes(model.usage(of: proxy.id).thisMonth.total)
        let limit = proxy.limit.map { " of \(Format.bytes($0))" } ?? ""
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.usagePeriod).monoCaps()
                Text("\(Text(used).font(.largeTitle.weight(.medium)).foregroundStyle(Theme.ink))\(Text(limit).font(.subheadline).foregroundStyle(Theme.secondary))")
                    .fixedSize(horizontal: false, vertical: true)
                    .deviceScreenChange(used + limit, numbers: true, reduceMotion: reduceMotion)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .liveCard()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Self.capitalized(model.usagePeriod)), \(used)\(limit)")
            .accessibilityIdentifier("proxy.thisMonth")
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            if model.overLimit(proxy.id) {
                Text("Over its limit until \(model.nextResetDay), because you resumed it.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("proxy.overLimit")
            }
        }
        .paperRow()
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
                    .foregroundStyle(Theme.ink)
                    .accessibilityLabel(label)
                    .accessibilityValue(text)
                    .accessibilityIdentifier(id)
                CopyButton(text: text, label: copyLabel, fill: Theme.dot)
                    .accessibilityIdentifier("\(id).copy")
            }
        } label: {
            // Not hidden from VoiceOver: the audit flags text on screen it can't reach.
            DashLabel(label)
        }
    }

    private var limitPicker: some View {
        Picker(selection: Binding(get: { LimitPick.preset(proxy.limit) }, set: { pick in
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
        } label: {
            DashLabel("Data limit")
        }
        .pickerStyle(.menu)
        .tint(Theme.secondary)
        .accessibilityIdentifier("proxy.limit")
    }
}
