import Foundation

/// What a device's row on the main screen and its own screen say about it. Foundation only, so
/// `swift test` covers the words.
enum DeviceStatus: Equatable {
    case connected
    case notConnected
    case paused(WireGuardSetup.Pause)

    /// Paused comes first: a paused device's tunnel can still be up, but nothing gets through.
    init(_ peer: WireGuardSetup.Peer, connected: Set<String>) {
        if let pause = peer.paused {
            self = .paused(pause)
        } else {
            self = connected.contains(peer.address) ? .connected : .notConnected
        }
    }

    /// The row's word.
    var label: String {
        switch self {
        case .connected: "Connected"
        case .notConnected: "Not connected"
        case .paused: "Paused"
        }
    }

    /// The first line on its screen: the row's word, or what paused it.
    var title: String {
        switch self {
        case let .paused(pause): pause.title
        default: label
        }
    }

    /// The line under the title on its screen, for a paused device only.
    var detail: String? {
        switch self {
        case let .paused(pause): pause.detail
        default: nil
        }
    }
}

extension WireGuardSetup.Pause {
    var title: String {
        switch self {
        case .byYou: "Paused"
        case .atLimit: "Paused at its limit"
        }
    }

    var detail: String {
        switch self {
        case .byYou: "It can't connect until you resume it."
        case .atLimit: "It used its data for this month. It connects again on the 1st, or when you resume it."
        }
    }
}
