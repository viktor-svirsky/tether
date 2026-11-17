import AppIntents

// Actions for the Shortcuts app, Siri, Spotlight and the Action button. iOS suspends Tether once
// nothing has been on the hotspot for 10 minutes (KeepAlivePolicy), and Shortcuts has no trigger
// for Personal Hotspot turning on. So a shortcut turns the hotspot on with Shortcuts' own Set Personal Hotspot
// action, then runs Start Tether, which wakes Tether in the background without opening it.

struct StartTetherIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Tether"
    static var description = IntentDescription(
        "Wakes Tether in the background, the same as opening it. It shares as soon as a device joins Personal Hotspot in the next 10 minutes. Put it after Set Personal Hotspot.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let model = Model.shared
        let keptAlive = model.wake()
        let state = model.shortcutState()
        return .result(value: state.sharing, dialog: "\(ShortcutReply.start(state, keptAlive: keptAlive))")
    }
}

struct TetherStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Is Tether Sharing?"
    static var description = IntentDescription(
        "True while Tether is sharing Personal Hotspot, for an If in a shortcut. It also says how many devices are connected, and whether the proxy is in use.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let model = Model.shared
        model.syncWithHotspot() // a cold launch for this action hasn't looked at the hotspot yet
        let state = model.shortcutState()
        return .result(value: state.sharing, dialog: "\(ShortcutReply.status(state))")
    }
}

/// Ready in Shortcuts, Siri and Spotlight as soon as Tether is installed, with nothing to set up.
struct TetherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartTetherIntent(),
                    phrases: ["Start \(.applicationName)", "Share internet with \(.applicationName)"],
                    shortTitle: "Start Tether", systemImageName: "link")
        AppShortcut(intent: TetherStatusIntent(),
                    phrases: ["Is \(.applicationName) sharing", "\(.applicationName) status"],
                    shortTitle: "Is Tether Sharing?", systemImageName: "link.circle")
    }
}
