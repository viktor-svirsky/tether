import SwiftUI

/// Settings > Notifications (M6): whether iOS lets Tether notify, first, then a switch for each kind.
/// Until iOS allows them the switches can't be changed, since nothing they say would be delivered.
/// Their saved values stay.
struct NotificationsView: View {
    @ObservedObject var model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List {
            PaperTitle("Notifications")
            permission
            Section {
                ForEach(NoticeKind.allCases, id: \.self) { kind in
                    NoticeSwitch(kind: kind, store: model.settingsDefaults)
                }
            } header: {
                PaperHeader(title: "Notify me when")
            } footer: {
                // Short, and says when these apply at all, so it stays out from behind an (i).
                Text("Only while Tether is in the background. While it's open, you see it on screen.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("notices.footer")
            }
            .paperRow()
            .disabled(model.noticePermission != .allowed)
        }
        .listStyle(.grouped)
        .listSectionSpacing(.compact)
        .paperList()
        .tint(Theme.ink)
        // Allowed in iOS's question or in iOS Settings: the first rows go and the switches wake up.
        .animation(PaperMotion.change(reduceMotion: reduceMotion), value: model.noticePermission)
        .paperNavigationBar("Notifications")
        .task { await model.refreshNoticePermission() }
    }

    @ViewBuilder private var permission: some View {
        switch model.noticePermission {
        case .notAsked:
            Section {
                Button { model.askForNotices() } label: { DashLabel("Allow notifications") }
                    .accessibilityIdentifier("notices.allow")
            } footer: {
                Text("Until you allow them, Tether sends none. Tether also offers this on its main screen the first time it has something to tell you.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("notices.allowFooter")
            }
            .paperRow()
        case .denied:
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
        case .allowed:
            EmptyView()
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
        Toggle(isOn: $on) { DashLabel(kind.label) }
            .toggleStyle(.ink)
            .accessibilityIdentifier("notices.\(kind.rawValue)")
    }
}
