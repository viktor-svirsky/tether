import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// The Settings sheet, opened with the gear on the main screen: when sharing stops while idle, a
/// switch for each kind of notification, a button for the permission before Tether asked for it
/// itself, the way to Settings when iOS has Tether's notifications off, the log to share for a bug
/// report, and what this build is.
struct SettingsView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    /// Read by `HotspotSession` each watcher round, see `IdleStop`.
    @AppStorage private var idleStopAfter: IdleStop.After

    init(model: Model) {
        self.model = model
        _idleStopAfter = AppStorage(wrappedValue: .default, IdleStop.After.key, store: model.settingsDefaults)
    }

    var body: some View {
        NavigationStack {
            List {
                sharing
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshNoticePermission() }
        }
    }

    private var help: some View {
        Section {
            ShareLink(item: LogFile(), preview: SharePreview("Tether log")) {
                Label("Share the log", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("settings.log")
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
        Section("About") {
            LabeledContent("Version", value: Model.version)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.version")
            if let expires = model.expires {
                LabeledContent("Stops opening", value: expires.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.expires")
            }
            LabeledContent("License", value: "MIT")
        }
    }

    private var sharing: some View {
        Section {
            Picker("Stop sharing when idle", selection: $idleStopAfter) {
                ForEach(IdleStop.After.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("sharing.idleStop")
        } header: {
            Text("Sharing")
        } footer: {
            Text("Idle means no device is connected. Stopping saves battery. Open Tether to share again.")
                .accessibilityIdentifier("sharing.footer")
        }
    }

    @ViewBuilder private var notices: some View {
        if model.noticePermission == .notAsked {
            Section {
                Button("Allow notifications") { model.askForNotices() }
                    .accessibilityIdentifier("notices.allow")
            } footer: {
                Text("Or Tether asks the first time something happens that it would tell.")
            }
        }
        if model.noticePermission == .denied {
            Section {
                Label("Notifications are off for Tether in iOS Settings.", systemImage: "bell.slash")
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
            Text("Only while Tether is in the background. On screen, the screen shows it.")
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
/// on screen iOS shows none, since nothing here asks it to.
@MainActor
final class SystemNoticeCenter: NoticeCenter {
    private let center = UNUserNotificationCenter.current()
    private let log: @MainActor (String) -> Void

    init(log: @escaping @MainActor (String) -> Void) {
        self.log = log
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
