import SwiftUI
import UserNotifications

/// The Settings sheet, opened with the gear on the main screen: a switch for each kind of
/// notification, a button for the permission before Tether asked for it itself, the way to Settings
/// when iOS has Tether's notifications off, and what this build is.
struct SettingsView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss

    /// "1.1.0 (66)": the version people see, and the build number from the commit count.
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                notices
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

    @ViewBuilder private var about: some View {
        Section("About") {
            LabeledContent("Version", value: version)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.version")
            if let expires = model.expires {
                LabeledContent("Stops opening", value: expires.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.expires")
            }
            Link("Help and source code", destination: URL(string: "https://github.com/viktor-svirsky/tether")!)
                .accessibilityIdentifier("settings.help")
            LabeledContent("License", value: "MIT")
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
                NoticeSwitch(kind: kind, store: model.noticeDefaults)
            }
        } header: {
            Text("Notify me when")
        } footer: {
            Text("Only while Tether is in the background. On screen, the screen shows it.")
                .accessibilityIdentifier("notices.footer")
        }
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
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
        } catch {
            log("notification \(notice.kind.rawValue) not posted: \(error)")
        }
    }
}
