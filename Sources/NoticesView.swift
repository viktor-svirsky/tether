import SwiftUI
import UserNotifications

/// The Notifications screen, opened from the bottom of the main screen: a switch for each kind, a
/// button for the permission before Tether asked for it itself, and the way to Settings when iOS has
/// Tether's notifications off.
struct NoticesView: View {
    @ObservedObject var model: Model

    var body: some View {
        List {
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
                    Label("Notifications are off for Tether in Settings.", systemImage: "bell.slash")
                        .accessibilityIdentifier("notices.denied")
                    Button("Open Settings") {
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
                Text("Tell me when")
            } footer: {
                Text("Only while Tether is in the background. On screen, the screen shows it.")
                    .accessibilityIdentifier("notices.footer")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        // Settings may have changed it while Tether was away.
        .task { await model.refreshNoticePermission() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshNoticePermission() }
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
