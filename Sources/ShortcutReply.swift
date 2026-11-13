import Foundation

/// What the Shortcuts actions (Shortcuts.swift) say back. Foundation only, so `swift test` covers it.
enum ShortcutReply {
    /// Where Tether stands. `problem` is why WireGuard isn't running, see `Model.wireGuardProblem`.
    struct State: Equatable {
        var running: Bool
        var connected: Int
        var problem: String?
        /// Sharing stopped after a time with no device connected, see `IdleStop`.
        var idleStopped = false
        /// The silent sound plays while the hotspot is on. Without it iOS suspends Tether as soon as
        /// the action ends, so it isn't sharing for long (#164).
        var keptAlive = true
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

    static func status(_ state: State) -> String {
        if state.running, let problem = state.problem { return "Personal Hotspot is on, but WireGuard isn't running. \(problem)" }
        if state.running, !state.keptAlive { return "Tether couldn't keep running in the background. Open it once." }
        if state.idleStopped { return "Tether stopped sharing while idle. Open it, or run Start Tether, to share again." }
        // iOS makes the hotspot's network only while a device is on it, so no device and the hotspot off look the same.
        guard state.running else { return "Tether is waiting for a device to join Personal Hotspot." }
        switch state.connected {
        case 0: return "Tether is sharing. No device is using it yet."
        case 1: return "Tether is sharing with 1 device."
        case let n: return "Tether is sharing with \(n) devices."
        }
    }
}
