import AppIntents

// Actions for the Shortcuts app, Siri, Spotlight and the Action button. iOS suspends Tether once
// nothing has been on the hotspot for 10 minutes (KeepAlivePolicy), and Shortcuts has no trigger
// for Personal Hotspot turning on. So a shortcut turns the hotspot on with Shortcuts' own Set Personal Hotspot
// action, then runs Start Tether, which wakes Tether in the background without opening it.

struct StartTetherIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Tether"
    static let description = IntentDescription(
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
    static let title: LocalizedStringResource = "Is Tether Sharing?"
    static let description = IntentDescription(
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
        // Pause and Resume need a device, so they stay actions with no phrase.
        AppShortcut(intent: ListTetherDevicesIntent(),
                    phrases: ["List \(.applicationName) devices"],
                    shortTitle: "List Tether Devices", systemImageName: "laptopcomputer.and.iphone")
    }
}

/// A device in Tether's list, for List Tether Devices and the device in Pause and Resume Tether
/// Device (#310). Picked from the list, or typed by its name. The proxy isn't one: it has no name.
struct TetherDeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tether Device"
    static let defaultQuery = TetherDeviceQuery()

    var id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Status") var status: String

    init(_ device: ShortcutReply.Device) {
        id = device.id
        name = device.name
        status = device.status
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(status)")
    }
}

struct TetherDeviceQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [TetherDeviceEntity] {
        devices().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching name: String) async throws -> [TetherDeviceEntity] {
        devices().filter { $0.name.localizedCaseInsensitiveContains(name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TetherDeviceEntity] {
        devices()
    }

    /// A launch for the action hasn't read the saved list yet.
    @MainActor
    private func devices() -> [TetherDeviceEntity] {
        let model = Model.shared
        model.syncWithHotspot()
        return model.shortcutDevices().map(TetherDeviceEntity.init)
    }
}

/// How long Pause Tether Device pauses for, the four choices of the Pause menu (#312).
enum TetherPauseLength: String, AppEnum {
    case halfHour, hour, untilTomorrow, untilResumed

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pause Length"
    static let caseDisplayRepresentations: [TetherPauseLength: DisplayRepresentation] = [
        .halfHour: "For 30 minutes",
        .hour: "For 1 hour",
        .untilTomorrow: "Until tomorrow",
        .untilResumed: "Until I resume it",
    ]

    var length: WireGuardSetup.PauseLength {
        switch self {
        case .halfHour: .halfHour
        case .hour: .hour
        case .untilTomorrow: .untilTomorrow
        case .untilResumed: .untilResumed
        }
    }
}

struct ListTetherDevicesIntent: AppIntent {
    static let title: LocalizedStringResource = "List Tether Devices"
    static let description = IntentDescription(
        "Every device in Tether's list, and whether it's connected or paused, in the words of its row in Tether.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[TetherDeviceEntity]> & ProvidesDialog {
        let model = Model.shared
        model.syncWithHotspot() // a cold launch for this action hasn't read the saved list yet
        let devices = model.shortcutDevices()
        return .result(value: devices.map(TetherDeviceEntity.init), dialog: "\(ShortcutReply.devices(devices))")
    }
}

struct PauseTetherDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Tether Device"
    static let description = IntentDescription(
        "Stops a device from connecting for a while, or until it's resumed, as Pause on its screen in Tether does.")

    @Parameter(title: "Device") var device: TetherDeviceEntity
    @Parameter(title: "For", default: .untilResumed) var length: TetherPauseLength

    static var parameterSummary: some ParameterSummary { Summary("Pause \(\.$device) \(\.$length)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = Model.shared
        model.syncWithHotspot()
        return .result(dialog: "\(model.shortcutPause(device.id, named: device.name, for: length.length))")
    }
}

struct ResumeTetherDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Tether Device"
    static let description = IntentDescription("Lets a paused device connect again, as Resume on its screen in Tether does.")

    @Parameter(title: "Device") var device: TetherDeviceEntity

    static var parameterSummary: some ParameterSummary { Summary("Resume \(\.$device)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = Model.shared
        model.syncWithHotspot()
        return .result(dialog: "\(model.shortcutResume(device.id, named: device.name))")
    }
}
