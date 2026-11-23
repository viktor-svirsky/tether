import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// The Settings sheet, opened with the gear on the main screen: when sharing stops while idle, the
/// DNS server Tether asks for the devices, whether they reach the iPhone's local networks, a switch for each kind of notification, a button for the permission before Tether asked for it
/// itself, the way to Settings when iOS has Tether's notifications off, the log to share for a bug
/// report, the server's counters (`DiagnosticsView`), and what this build is.
struct SettingsView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    /// Read by `HotspotSession` each watcher round, see `IdleStop`.
    @AppStorage private var idleStopAfter: IdleStop.After
    /// The day the counts and limits start over, 31 for the last day, see `ResetDay`.
    @AppStorage private var resetDay: Int
    /// Read by `HotspotSession` for each config it makes, see `DNSChoice`.
    @AppStorage private var dns: DNSChoice
    @AppStorage private var dnsOther: String
    @AppStorage private var dnsControlD: String
    /// Read by `HotspotSession` for each config it makes, see `LocalNetworks`.
    @AppStorage private var localNetworksAllowed: Bool

    init(model: Model) {
        self.model = model
        _idleStopAfter = AppStorage(wrappedValue: .default, IdleStop.After.key, store: model.settingsDefaults)
        _resetDay = AppStorage(wrappedValue: ResetDay.default.day, ResetDay.key, store: model.settingsDefaults)
        _dns = AppStorage(wrappedValue: .default, DNSChoice.key, store: model.settingsDefaults)
        _dnsOther = AppStorage(wrappedValue: "", DNSChoice.otherKey, store: model.settingsDefaults)
        _dnsControlD = AppStorage(wrappedValue: "", DNSChoice.controlDKey, store: model.settingsDefaults)
        _localNetworksAllowed = AppStorage(wrappedValue: false, LocalNetworks.key, store: model.settingsDefaults)
    }

    var body: some View {
        NavigationStack {
            List {
                sharing
                newDevices
                localNetworks
                notices
                help
                about
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // From iOS 26, the system's close button: a tinted text button fails contrast on the glass.
                ToolbarItem(placement: .topBarTrailing) {
                    if #available(iOS 26, *) {
                        Button(role: .close) { dismiss() }
                            .accessibilityIdentifier("settings.done")
                    } else {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("settings.done")
                    }
                }
            }
        }
        // Settings may have changed it while Tether was away.
        .task { await model.refreshNoticePermission() }
    }

    private var help: some View {
        Section {
            ShareLink(item: LogFile(), preview: SharePreview("Tether log")) {
                Label("Share the log", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("settings.log")
            NavigationLink("Diagnostics") { DiagnosticsView(model: model) }
                .accessibilityIdentifier("settings.diagnostics")
            Link("Help and source code", destination: URL(string: "https://github.com/viktor-svirsky/tether")!)
                .accessibilityIdentifier("settings.help")
        } header: {
            Text("Help")
        } footer: {
            Text("The log is a text file of what Tether did lately, for a bug report. Keys and full addresses are left out.")
                .accessibilityIdentifier("settings.logFooter")
        }
    }

    @ViewBuilder private var about: some View {
        Section {
            LabeledContent("Version", value: Model.version)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.version")
            if let expires = model.expires {
                LabeledContent("Stops opening", value: expires.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.expires")
            }
            LabeledContent("License", value: "MIT")
        } header: {
            Text("About")
        } footer: {
            if model.expires != nil {
                Text("With a free Apple ID, refresh Tether in SideStore or AltStore before then.")
                    .accessibilityIdentifier("settings.expiresFooter")
            }
        }
    }

    private var sharing: some View {
        Section {
            Picker("Stop sharing when idle", selection: $idleStopAfter) {
                ForEach(IdleStop.After.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("sharing.idleStop")
            Picker("Data counts start on", selection: $resetDay) {
                ForEach(ResetDay.choices, id: \.self) { Text($0.label).tag($0.day) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("sharing.resetDay")
            // The screens show the new dates as soon as Settings closes (#187).
            .onChange(of: resetDay) { model.resetDayChanged() }
        } header: {
            Text("Sharing")
        } footer: {
            Text("Idle means no device is connected and nothing goes through the proxy. Stopping saves battery. Open Tether to share again. Data counts start again on this day each month. Set it to your plan's billing day so the limits match your carrier.")
                .accessibilityIdentifier("sharing.footer")
        }
    }

    private var newDevices: some View {
        Section {
            Picker("DNS", selection: $dns) {
                ForEach(DNSChoice.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("newDevices.dns")
            if dns == .other {
                TextField("Server address", text: $dnsOther, prompt: Text("9.9.9.10"))
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { model.dnsChanged() }
                    .accessibilityIdentifier("newDevices.other")
                if DNSChoice.servers(typed: dnsOther) == nil {
                    Text("One or two IPv4 addresses, like 9.9.9.10. Until then, Tether asks 1.1.1.1.")
                        .font(.subheadline)
                        .accessibilityIdentifier("newDevices.otherProblem")
                }
            }
            if dns == .controlD {
                TextField("Resolver ID or DoH link", text: $dnsControlD, prompt: Text("Resolver ID or DoH link"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { model.dnsChanged() }
                    .accessibilityIdentifier("newDevices.controlD")
                if DNSChoice.controlD(typed: dnsControlD) == nil {
                    Text("Your profile's resolver ID or DoH link, from Control D's dashboard. Until then, Tether asks 1.1.1.1.")
                        .font(.subheadline)
                        .accessibilityIdentifier("newDevices.controlDProblem")
                }
            }
        } header: {
            Text("DNS for your devices")
        } footer: {
            Text(dns == .controlD && DNSChoice.controlD(typed: dnsControlD) != nil ? Self.controlDFooter : Self.footer)
                // In the label colour: this footer's grey just misses the contrast audit.
                .foregroundStyle(Color(.label))
                .accessibilityIdentifier("newDevices.footer")
        }
        // A device whose config names Tether asks the new choice from its next lookup. What's typed is
        // passed on when it's submitted or Settings closes, not each keystroke: every start of an ID
        // looks like one, and the devices' lookups would go to each in turn.
        .onChange(of: dns) { model.dnsChanged() }
        .onDisappear { model.dnsChanged() }
    }

    private static let footer = "Your devices ask Tether, and Tether asks this server, so a change reaches them at once. A device whose DNS in WireGuard isn't 10.7.0.1 keeps its own: set it to 10.7.0.1 there, or add the device again. The server can see which sites your devices visit."
    private static let controlDFooter = "Your devices ask Tether, and Tether asks your Control D profile over HTTPS. Pick the country sites see in Control D, under Redirect (a paid plan). A device whose DNS in WireGuard isn't 10.7.0.1 keeps its own: set it to 10.7.0.1 there. Control D can see which sites your devices visit."

    private var localNetworks: some View {
        Section {
            Toggle("Local networks", isOn: $localNetworksAllowed)
                .accessibilityIdentifier("localNetworks.toggle")
        } header: {
            Text("What your devices can reach")
        } footer: {
            Text("Off: your devices reach the internet, but not the iPhone's Wi-Fi network, a VPN's private addresses or a Tailscale network. Tether's page still opens.")
                // In the label colour, like the DNS footer: the grey just misses the contrast audit.
                .foregroundStyle(Color(.label))
                .accessibilityIdentifier("localNetworks.footer")
        }
        // Turning it off closes what the devices have open there at once (#230).
        .onChange(of: localNetworksAllowed) { model.localNetworksChanged() }
    }

    @ViewBuilder private var notices: some View {
        if model.noticePermission == .notAsked {
            Section {
                Button("Allow notifications") { model.askForNotices() }
                    .accessibilityIdentifier("notices.allow")
            } footer: {
                Text("Or Tether asks the first time it has something to tell you.")
            }
        }
        if model.noticePermission == .denied {
            Section {
                Label {
                    Text("Notifications are off for Tether in iOS Settings.")
                } icon: {
                    Image(systemName: "bell.slash").accessibilityHidden(true)
                }
                // One element: on iOS 26 the symbol is a separate one named "Notifications Off".
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("notices.denied")
                Button("Open iOS Settings") {
                    UIApplication.shared.open(URL(string: UIApplication.openNotificationSettingsURLString)!)
                }
                .accessibilityIdentifier("notices.settings")
            }
        }
        Section {
            ForEach(NoticeKind.allCases, id: \.self) { kind in
                NoticeSwitch(kind: kind, store: model.settingsDefaults)
            }
        } header: {
            Text("Notify me when")
        } footer: {
            Text("Only while Tether is in the background. While it's open, you see it on screen.")
                .accessibilityIdentifier("notices.footer")
        }
    }
}

/// The log as a file to share, see `DebugLog`. It's written when the share sheet asks for it, so it
/// has the lines up to then.
private struct LogFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in SentTransferredFile(try Model.writeLog()) }
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
        Toggle(kind.label, isOn: $on)
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
