import Foundation

/// What the Shortcuts actions (Shortcuts.swift) say back. Foundation only, so `swift test` covers it.
enum ShortcutReply {
    /// Where Tether stands. `problem` is why WireGuard isn't running, see `Model.wireGuardProblem`.
    struct State: Equatable {
        var running: Bool
        var connected: Int
        var problem: String?
        /// A connection is open on the proxy. Its devices can't be told apart, so they aren't in `connected`.
        var proxyInUse = false
        /// Sharing stopped after a time with no device connected, see `IdleStop`.
        var idleStopped = false
        /// Stop on a widget or in Control Center stopped it, see `HotspotSession.stopNow`.
        var stoppedByYou = false
        /// The battery stopped it, see `LowBatteryStop` (#311).
        var lowBattery = false
        /// The silent sound plays while the hotspot is on. Without it iOS suspends Tether as soon as
        /// the action ends, so it isn't sharing for long (#164).
        var keptAlive = true
        /// Only share through a VPN is on and no VPN is, so no device gets through.
        var blockedWithoutVPN = false
        /// The hotspot is on, WireGuard runs and Tether stays running. `running` alone is only the hotspot.
        var sharing: Bool { running && problem == nil && keptAlive }
    }

    /// After Start Tether. `keptAlive` is false when the silent sound couldn't start, and then iOS
    /// suspends Tether again as soon as the action ends.
    static func start(_ state: State, keptAlive: Bool) -> String {
        if !keptAlive { return "Tether couldn't keep running in the background. Open it once." }
        if state.running { return status(state) }
        let minutes = Int(KeepAlivePolicy.grace / 60)
        return "Tether is ready. It starts sharing when a device joins Personal Hotspot in the next \(minutes) minutes."
    }

    /// After Start Tether below the battery level, not charging, see `HotspotSession.startRefusedAtLowBattery`.
    static let lowBatteryStart = "Tether stopped sharing at low battery. Charge the iPhone first, or open Tether to share again."

    static func status(_ state: State) -> String {
        if state.running, let problem = state.problem { return "Personal Hotspot is on, but WireGuard isn't running. \(problem)" }
        if state.running, !state.keptAlive { return "Tether couldn't keep running in the background. Open it once." }
        if state.stoppedByYou { return "Tether is stopped. Open it, or run Start Tether, to share again." }
        if state.lowBattery { return "Tether stopped sharing at low battery. Charge the iPhone, or open Tether, to share again." }
        if state.idleStopped { return "Tether stopped sharing while idle. Open it, or run Start Tether, to share again." }
        // iOS makes the hotspot's network only while a device is on it, so no device and the hotspot off look the same.
        guard state.running else { return "Tether is waiting for a device to join Personal Hotspot." }
        if state.blockedWithoutVPN { return "Tether is sharing, but no VPN is on, so no device gets through until one is." }
        switch (state.connected, state.proxyInUse) {
        case (0, false): return "Tether is sharing. No device is using it yet."
        case (0, true): return "Tether is sharing. The proxy is in use."
        case (1, false): return "Tether is sharing with 1 device."
        case (1, true): return "Tether is sharing with 1 device and the proxy."
        case let (n, false): return "Tether is sharing with \(n) devices."
        case let (n, true): return "Tether is sharing with \(n) devices and the proxy."
        }
    }

    /// One device in Tether's list, for List Tether Devices and the device picker in Pause and
    /// Resume Tether Device (#310). `status` is what its row says, see `DeviceStatus.label`.
    struct Device: Equatable {
        var id: UUID
        var name: String
        var status: String
    }

    /// After List Tether Devices: one line each, in the words of the device rows.
    static func devices(_ devices: [Device]) -> String {
        guard !devices.isEmpty else { return "Tether has no devices yet. Add one in Tether." }
        return devices.map { "\($0.name): \($0.status)" }.joined(separator: "\n")
    }

    /// After Pause Tether Device. `until` is when the pause ends, as the row says it, nil for one
    /// that lasts until it's resumed. A device already paused takes the new length.
    static func paused(_ name: String, until: String?, wasPaused: Bool) -> String {
        let how = until.map { "until \($0)" } ?? "until you resume it"
        return wasPaused ? "\(name) was already paused. It's now paused \(how)." : "\(name) is paused \(how)."
    }

    /// After Resume Tether Device.
    static func resumed(_ name: String) -> String { "\(name) can connect again." }

    static func notPaused(_ name: String) -> String { "\(name) isn't paused." }

    /// Removed since the shortcut picked it, by the name the shortcut has for it.
    static func gone(_ name: String) -> String { "Tether has no device called \(name) any more." }

    /// The pause or resume couldn't be saved, so nothing changed.
    static let notSaved = "Tether couldn't save the change. Try again on the device's screen in Tether."
}
