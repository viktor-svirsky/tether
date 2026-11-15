import Foundation

/// How far adding one device has got, for the Add a device sheet. It follows the device behind the
/// code that was ready when the sheet opened: that device keeps its id when it's claimed, by a
/// download from the page or its first handshake, and is listed from then on. A scanned code is
/// claimed only by the handshake, so its last two steps tick together.
struct AddDeviceProgress: Equatable {
    enum Step: Equatable {
        case toDo
        /// The device is listed and its tunnel isn't on yet.
        case waiting
        case done
    }

    /// The device, once it's listed.
    let device: WireGuardSetup.Peer?
    /// Something is on the hotspot. Tether can't tell which device it is.
    let joined: Step
    let config: Step
    let tunnel: Step

    var finished: Bool { tunnel == .done }
    /// The sheet keeps the screen on until then: the page hands out the config only while Tether is
    /// on screen, and a locked iPhone isn't.
    var keepsScreenAwake: Bool { !finished }

    init(ready: WireGuardSetup.Peer.ID?, peers: [WireGuardSetup.Peer], connected: Set<String>, hotspotOn: Bool) {
        device = ready.flatMap { id in peers.first { $0.id == id } }
        let isConnected = device.map { connected.contains($0.address) } ?? false
        joined = hotspotOn || isConnected ? .done : .toDo
        config = device == nil ? .toDo : .done
        tunnel = isConnected ? .done : device == nil ? .toDo : .waiting
    }
}

/// A name typed for a device, on Add a device once it connects or through Rename on its screen.
enum DeviceName {
    /// What to save, or nil when there's nothing to: a blank field, or the name it has. Done without
    /// a change saves nothing, so a store that can't save doesn't say a rename failed. Saving cuts
    /// a long name, see `WireGuardSetup.renamePeer`.
    static func toSave(typed: String, current: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == current ? nil : trimmed
    }
}
