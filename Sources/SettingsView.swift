import SwiftUI
import UserNotifications

/// The Settings sheet, opened with the gear on the main screen: when sharing stops while idle or at low battery, the
/// DNS server Tether asks for the devices, whether they reach the iPhone's local networks, a switch for each kind of notification, a button for the permission before Tether asked for it
/// itself, the way to Settings when iOS has Tether's notifications off, the log to share for a bug
/// report, the server's counters (`DiagnosticsView`), and what this build is.
/// Paper and ink (#349): plain rows on the paper, and each section's long help behind an (i).
struct SettingsView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Read by `HotspotSession` each watcher round, see `IdleStop`.
    @AppStorage private var idleStopAfter: IdleStop.After
    /// Read by `HotspotSession` each watcher round, see `LowBatteryStop`.
    @AppStorage private var lowBatteryStop: LowBatteryStop.Level
    /// The day the counts and limits start over, 31 for the last day, see `ResetDay`.
    @AppStorage private var resetDay: Int
    /// Read by `HotspotSession` for each config it makes, see `DNSChoice`.
    @AppStorage private var dns: DNSChoice
    @AppStorage private var dnsOther: String
    @AppStorage private var dnsControlD: String
    /// Read by `HotspotSession` for each config it makes, see `LocalNetworks`.
    @AppStorage private var localNetworksAllowed: Bool
    /// Read by `HotspotSession.checkVPN`, which runs at once on a change.
    @AppStorage private var onlyThroughVPN: Bool
    /// The sections whose help shows, by the id of their help text.
    @State private var helpShown: Set<String> = []
    @State private var showDiagnostics = false

    init(model: Model) {
        self.model = model
        _idleStopAfter = AppStorage(wrappedValue: .default, IdleStop.After.key, store: model.settingsDefaults)
        _lowBatteryStop = AppStorage(wrappedValue: .default, LowBatteryStop.Level.key, store: model.settingsDefaults)
        _resetDay = AppStorage(wrappedValue: ResetDay.default.day, ResetDay.key, store: model.settingsDefaults)
        _dns = AppStorage(wrappedValue: .default, DNSChoice.key, store: model.settingsDefaults)
        _dnsOther = AppStorage(wrappedValue: "", DNSChoice.otherKey, store: model.settingsDefaults)
        _dnsControlD = AppStorage(wrappedValue: "", DNSChoice.controlDKey, store: model.settingsDefaults)
        _localNetworksAllowed = AppStorage(wrappedValue: false, LocalNetworks.key, store: model.settingsDefaults)
        _onlyThroughVPN = AppStorage(wrappedValue: false, HotspotSession.onlyThroughVPNKey, store: model.settingsDefaults)
    }

    var body: some View {
        NavigationStack {
            List {
                PaperTitle("Settings")
                sharing
                vpn
                newDevices
                localNetworks
                notices
                help
                about
            }
            .listStyle(.grouped)
            .listSectionSpacing(.compact)
            .paperList()
            .tint(Theme.ink)
            // The DNS field and its problem line come and go with the choice and what's typed.
            .animation(PaperMotion.change(reduceMotion: reduceMotion), value: dns)
            .animation(PaperMotion.change(reduceMotion: reduceMotion), value: DNSChoice.servers(typed: dnsOther) == nil)
            .animation(PaperMotion.change(reduceMotion: reduceMotion), value: DNSChoice.controlD(typed: dnsControlD) == nil)
            .paperNavigationBar("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("Tether")
                        .monoCaps()
                        // Its own width: the bar gives a leading item less and cut it to "TET...".
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
                // The system's close button: a tinted text button fails contrast on the glass.
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
            }
            .navigationDestination(isPresented: $showDiagnostics) { DiagnosticsView(model: model) }
        }
        // Settings may have changed it while Tether was away.
        .task { await model.refreshNoticePermission() }
    }

    /// A section's header. With `help`, the id of its help text, it has an (i) named `<info>.info`
    /// that shows and hides that text.
    private func header(_ title: String, help id: String? = nil, info: String = "") -> PaperHeader {
        guard let id else { return PaperHeader(title: title) }
        let shown = Binding { helpShown.contains(id) } set: { on in
            if on { helpShown.insert(id) } else { helpShown.remove(id) }
        }
        return PaperHeader(title: title, help: shown, id: info)
    }

    @ViewBuilder private func helpText(_ text: String, id: String) -> some View {
        if helpShown.contains(id) {
            PaperHelp(text: text, id: id)
        }
    }

    /// A short line under a section that always shows, like what a switch does right now.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.secondary)
    }

    /// A value on the right of a row, in the secondary colour.
    private func row(_ title: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(Theme.secondary)
                .contentTransition(.opacity)
                .animation(PaperMotion.change(reduceMotion: reduceMotion), value: value)
        } label: {
            DashLabel(title)
        }
        .accessibilityElement(children: .combine)
    }

    private var help: some View {
        Section {
            helpText(Self.logHelp, id: "settings.logFooter")
            ShareLink(item: LogFile(), preview: SharePreview("Tether log")) {
                DashLabel("Share the log")
            }
            .accessibilityIdentifier("settings.log")
            Button { showDiagnostics = true } label: {
                DashLabel("Diagnostics")
            }
            .accessibilityIdentifier("settings.diagnostics")
            Link(destination: URL(string: "https://github.com/viktor-svirsky/tether")!) {
                DashLabel("Help and source code")
            }
            .accessibilityIdentifier("settings.help")
        } header: {
            header("Help", help: "settings.logFooter", info: "help")
        }
        .paperRow()
    }

    static let logHelp = "The log is a text file of what Tether did lately, for a bug report. Keys and full addresses are left out."

    @ViewBuilder private var about: some View {
        Section {
            row("Version", value: Model.version)
                .accessibilityIdentifier("settings.version")
            if let expires = model.expires {
                row("Stops opening", value: expires.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityIdentifier("settings.expires")
            }
            row("License", value: "MIT")
        } header: {
            header("About")
        } footer: {
            // Not behind an (i): when the build stops opening is a status, not help.
            if model.expires != nil {
                note("With a free Apple ID, refresh Tether in SideStore or AltStore before then.")
                    .accessibilityIdentifier("settings.expiresFooter")
            }
        }
        .paperRow()
    }

    private var sharing: some View {
        Section {
            helpText(Self.sharingHelp, id: "sharing.footer")
            Picker(selection: $idleStopAfter) {
                ForEach(IdleStop.After.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                DashLabel("Stop sharing when idle")
            }
            .pickerStyle(.menu)
            .tint(Theme.secondary)
            .accessibilityIdentifier("sharing.idleStop")
            Picker(selection: $lowBatteryStop) {
                ForEach(LowBatteryStop.Level.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                DashLabel("Stop sharing at low battery")
            }
            .pickerStyle(.menu)
            .tint(Theme.secondary)
            .accessibilityIdentifier("sharing.lowBattery")
            Picker(selection: $resetDay) {
                ForEach(ResetDay.choices, id: \.self) { Text($0.label).tag($0.day) }
            } label: {
                DashLabel("Data counts start on")
            }
            .pickerStyle(.menu)
            .tint(Theme.secondary)
            .accessibilityIdentifier("sharing.resetDay")
            // The screens show the new dates as soon as Settings closes (#187).
            .onChange(of: resetDay) { model.resetDayChanged() }
        } header: {
            header("Sharing", help: "sharing.footer", info: "sharing")
        }
        .paperRow()
    }

    static let sharingHelp = "Idle means no device is connected and nothing goes through the proxy. Stopping saves battery, and at low battery only happens while the iPhone isn't charging. Open Tether to share again. Data counts start again on this day each month. Set it to your plan's billing day so the limits match your carrier."

    private var vpn: some View {
        Section {
            helpText(Self.vpnHelp, id: "vpn.footer")
            Toggle(isOn: $onlyThroughVPN) { DashLabel("Only share through a VPN") }
                .toggleStyle(.ink)
                .onChange(of: onlyThroughVPN) { model.checkVPN() }
                .accessibilityIdentifier("vpn.only")
            row("Now", value: VPNText.now(vpn: model.vpnInterface != nil, onlyFamily: model.vpnOnlyFamily))
                .accessibilityIdentifier("vpn.now")
        } header: {
            header("VPN", help: "vpn.footer", info: "vpn")
        }
        .paperRow()
    }

    static let vpnHelp = "When it's on and no VPN carries this iPhone's internet, no device gets through. Tether pauses the devices when it sees the VPN go, which can take a few seconds. Turn a VPN on in its app, or with Set VPN in Shortcuts: Tether can't pick one."

    private var newDevices: some View {
        Section {
            helpText(dns == .controlD && DNSChoice.controlD(typed: dnsControlD) != nil ? Self.controlDFooter : Self.footer,
                     id: "newDevices.footer")
            Picker(selection: $dns) {
                ForEach(DNSChoice.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                DashLabel("DNS")
            }
            .pickerStyle(.menu)
            .tint(Theme.secondary)
            .accessibilityIdentifier("newDevices.dns")
            if dns == .other {
                TextField("Server address", text: $dnsOther, prompt: Text("9.9.9.10").foregroundStyle(Theme.secondary))
                    .foregroundStyle(Theme.ink)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { model.dnsChanged() }
                    .accessibilityIdentifier("newDevices.other")
                if DNSChoice.servers(typed: dnsOther) == nil {
                    problem("One or two IPv4 addresses, like 9.9.9.10. Until then, Tether asks 1.1.1.1.")
                        .accessibilityIdentifier("newDevices.otherProblem")
                }
            }
            if dns == .controlD {
                TextField("Resolver ID or DoH link", text: $dnsControlD,
                          prompt: Text("Resolver ID or DoH link").foregroundStyle(Theme.secondary))
                    .foregroundStyle(Theme.ink)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { model.dnsChanged() }
                    .accessibilityIdentifier("newDevices.controlD")
                if DNSChoice.controlD(typed: dnsControlD) == nil {
                    problem("Your profile's resolver ID or DoH link, from Control D's dashboard. Until then, Tether asks 1.1.1.1.")
                        .accessibilityIdentifier("newDevices.controlDProblem")
                }
            }
        } header: {
            header("DNS for your devices", help: "newDevices.footer", info: "newDevices")
        }
        .paperRow()
        // A device whose config names Tether asks the new choice from its next lookup. What's typed is
        // passed on when it's submitted or Settings closes, not each keystroke: every start of an ID
        // looks like one, and the devices' lookups would go to each in turn.
        .onChange(of: dns) { model.dnsChanged() }
        .onDisappear { model.dnsChanged() }
    }

    /// What's wrong with what's typed, and what Tether does until it's right. Not behind an (i).
    private func problem(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.ink)
    }

    private static let footer = "Your devices ask Tether, and Tether asks this server, so a change reaches them at once. A device whose DNS in WireGuard isn't 10.7.0.1 keeps its own: set it to 10.7.0.1 there, or add the device again. The server can see which sites your devices visit."
    private static let controlDFooter = "Your devices ask Tether, and Tether asks your Control D profile over HTTPS. Pick the country sites see in Control D, under Redirect (a paid plan). A device whose DNS in WireGuard isn't 10.7.0.1 keeps its own: set it to 10.7.0.1 there. Control D can see which sites your devices visit."

    private var localNetworks: some View {
        Section {
            helpText(Self.localNetworksHelp, id: "localNetworks.footer")
            Toggle(isOn: $localNetworksAllowed) { DashLabel("Local networks") }
                .toggleStyle(.ink)
                .accessibilityIdentifier("localNetworks.toggle")
        } header: {
            header("What your devices can reach", help: "localNetworks.footer", info: "localNetworks")
        }
        .paperRow()
        // Turning it off closes what the devices have open there at once (#230).
        .onChange(of: localNetworksAllowed) { model.localNetworksChanged() }
    }

    static let localNetworksHelp = "Off: your devices reach the internet, but not the iPhone's Wi-Fi network, a VPN's private addresses or a Tailscale network. Tether's page still opens."

    @ViewBuilder private var notices: some View {
        if model.noticePermission == .notAsked {
            Section {
                Button { model.askForNotices() } label: { DashLabel("Allow notifications") }
                    .accessibilityIdentifier("notices.allow")
            } footer: {
                note("Or Tether asks the first time it has something to tell you.")
            }
            .paperRow()
        }
        if model.noticePermission == .denied {
            Section {
                Label {
                    Text("Notifications are off for Tether in iOS Settings.")
                        .foregroundStyle(Theme.ink)
                } icon: {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(Theme.ink)
                        .accessibilityHidden(true)
                }
                // One element: on iOS 26 the symbol is a separate one named "Notifications Off".
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("notices.denied")
                Button {
                    UIApplication.shared.open(URL(string: UIApplication.openNotificationSettingsURLString)!)
                } label: {
                    DashLabel("Open iOS Settings")
                }
                .accessibilityIdentifier("notices.settings")
            }
            .paperRow()
        }
        Section {
            ForEach(NoticeKind.allCases, id: \.self) { kind in
                NoticeSwitch(kind: kind, store: model.settingsDefaults)
            }
        } header: {
            header("Notify me when")
        } footer: {
            // Short, and says when these apply at all, so it stays out from behind an (i).
            note("Only while Tether is in the background. While it's open, you see it on screen.")
                .accessibilityIdentifier("notices.footer")
        }
        .paperRow()
    }
}


/// One kind's switch, saved where `Notifier` reads it.
private struct NoticeSwitch: View {
    let kind: NoticeKind
    @AppStorage private var on: Bool

    init(kind: NoticeKind, store: UserDefaults) {
        self.kind = kind
        _on = AppStorage(wrappedValue: true, kind.key, store: store)
    }

    var body: some View {
        Toggle(isOn: $on) { DashLabel(kind.label) }
            .toggleStyle(.ink)
            .accessibilityIdentifier("notices.\(kind.rawValue)")
    }
}

/// The system's notification center, for `NoticePoster`. Each notice shows at once. While Tether is
/// on screen it shows none: the screen says the same.
@MainActor
final class SystemNoticeCenter: NSObject, NoticeCenter, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let log: @MainActor (String) -> Void

    init(log: @escaping @MainActor (String) -> Void) {
        self.log = log
        super.init()
        center.delegate = self
    }

    /// iOS asks this when it thinks Tether is in front. Right after Tether leaves the screen it still
    /// does, and with no answer it dropped a notice posted then (#235). Only an active app keeps it quiet.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await UIApplication.shared.applicationState == .active ? [] : [.banner, .list, .sound]
    }

    func permission() async -> NoticePermission {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notAsked
        case .denied: .denied
        default: .allowed // also provisional and ephemeral, which deliver
        }
    }

    func ask() async -> Bool {
        do {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound])
            log("notifications \(allowed ? "allowed" : "refused")")
            return allowed
        } catch {
            log("notifications: asking failed: \(error)")
            return false
        }
    }

    func add(_ notice: Notice) async {
        await post(notice, trigger: nil)
    }

    func schedule(_ notice: Notice, after: TimeInterval) async {
        // A request with the same id replaces a waiting one, but not one that showed.
        center.removeDeliveredNotifications(withIdentifiers: [notice.id])
        await post(notice, trigger: UNTimeIntervalNotificationTrigger(timeInterval: after, repeats: false))
    }

    func remove(_ id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    private func post(_ notice: Notice, trigger: UNNotificationTrigger?) async {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: trigger))
        } catch {
            log("notification \(notice.kind.rawValue) not posted: \(error)")
        }
    }
}
