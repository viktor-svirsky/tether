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

    static func status(_ state: State) -> String {
        if state.running, let problem = state.problem { return "Personal Hotspot is on, but WireGuard isn't running. \(problem)" }
        if state.running, !state.keptAlive { return "Tether couldn't keep running in the background. Open it once." }
        if state.stoppedByYou { return "Tether is stopped. Open it, or run Start Tether, to share again." }
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
}
