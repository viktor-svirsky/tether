import SwiftUI

/// The HTTP proxy's own screen, from its row under Devices (#78), built from the same parts as a
/// device's (M4): whether a device has a connection open, Pause, what it used against its data limit,
/// where it is with Copy, what still goes out as hotspot data, and Turn off, which asks first. Paused
/// and limited by its id, the way a device is. Paper and ink (#349).
struct ProxyView: View {
    @ObservedObject var model: Model
    @State private var limitQuestions = LimitQuestions()
    @State private var confirmTurnOff = false
    /// A server or the port was copied: "Copied" shows at the bottom for a moment (L4).
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Off once turned off from here, until the screen goes.
    private var proxy: WireGuardSetup.Proxy { model.proxy ?? WireGuardSetup.Proxy(on: false) }
    private var status: ProxyStatus { ProxyStatus(proxy, stats: model.proxyStats, hotspotOn: model.running, keptOut: model.blockedWithoutVPN, onlyFamily: model.vpnOnlyFamily) }
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
        let used: Bool
        let overLimit: Bool
    }

    private func rows(servers: Int) -> Rows {
        Rows(look: status.look, detail: status.detail(resets: model.nextResetDay, period: model.usagePeriod) != nil, problem: problem,
             servers: servers, limited: proxy.limit != nil, used: model.usage(of: proxy.id).thisMonth.total > 0, overLimit: model.overLimit(proxy.id))
    }

    private var limitChoice: DataLimitChoice {
        DataLimitChoice(name: ProxyStatus.name, limit: proxy.limit, paused: proxy.paused,
                        used: model.usage(of: proxy.id).thisMonth.total, resets: model.nextResetDay) { model.setLimit(proxy.id, $0) }
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
            PauseSection(paused: proxy.paused != nil, id: "proxy", footer: Copy.proxyPauseFooter,
                         pause: { model.pauseWireGuardDevice(proxy.id, for: $0) },
                         resume: { model.resumeWireGuardDevice(proxy.id) })
            usageSection
            Section {
                serverRow(servers[0], label: "Server", copyLabel: "Copy the server", id: "proxy.server")
                if servers.count > 1 {
                    serverRow(servers[1], label: "Server for an iPhone, iPad or Mac", copyLabel: "Copy that server", id: "proxy.serverIPv6")
                }
                serverRow(ProxyAddress.port, label: "Port", copyLabel: "Copy the port", id: "proxy.port")
            } header: {
                PaperHeader(title: "Details")
            } footer: {
                Text("Games, calls and apps that skip the proxy still go out as hotspot data. For those, use WireGuard on that device.")
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("proxy.note")
            }
            .paperRow()
            Section {
                Button(role: .destructive) { confirmTurnOff = true } label: {
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
        // Room under Turn off, so the Copied capsule does not cover it (L4).
        .contentMargins(.bottom, 64, for: .scrollContent)
        .animation(PaperMotion.change(reduceMotion: reduceMotion), value: rows(servers: servers.count))
        // Only the copy buttons write the pasteboard here, by tap, VoiceOver or a keyboard alike.
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            withAnimation(PaperMotion.change(reduceMotion: reduceMotion)) { copied = true }
        }
        .copiedToast($copied, id: "proxy.copied")
        .navigationTitle(ProxyStatus.name)
        .navigationBarTitleDisplayMode(.inline)
        .dataLimitQuestions($limitQuestions, limitChoice)
        .confirmationDialog(Copy.turnOffProxyTitle, isPresented: $confirmTurnOff, titleVisibility: .visible) {
            Button(Copy.turnOffProxyButton, role: .destructive) {
                model.setProxy(on: false)
                if !model.proxyOn { dismiss() }
            }
        } message: {
            Text(Copy.turnOffProxyMessage)
        }
    }

    /// What it used this period, like a device's (M4): the card, last month and its data limit.
    private var usageSection: some View {
        let usage = model.usage(of: proxy.id)
        return Section {
            UsageCard(month: usage.thisMonth, limit: proxy.limit, period: model.usagePeriod, resets: model.nextResetDay)
                .accessibilityIdentifier("proxy.thisMonth")
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            if model.overLimit(proxy.id) {
                Text("Over its limit until \(model.nextResetDay), because you resumed it.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("proxy.overLimit")
            }
            LabeledContent { Text(Format.bytes(usage.lastMonth.total)).foregroundStyle(Theme.secondary) } label: { DashLabel(model.lastPeriodLabel) }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("proxy.lastMonth")
            DataLimitPicker(choice: limitChoice, questions: $limitQuestions, id: "proxy.limit")
        } header: {
            PaperHeader(title: "Data through Tether")
        }
        .paperRow()
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
}
