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

    /// What VoiceOver says when steps tick off by themselves since `old`, nil when none did. Otherwise
    /// a VoiceOver user doesn't hear the sheet move on (#175). A scan ticks the last two steps at
    /// once, and the connection says it all.
    func announcement(after old: AddDeviceProgress) -> String? {
        if finished, !old.finished, let device { return "\(device.name) is connected" }
        let before = [old.joined, old.config, old.tunnel], now = [joined, config, tunnel]
        let ticked = now.indices.filter { now[$0] == .done && before[$0] != .done }.map { String($0 + 1) }
        switch ticked.count {
        case 0: return nil
        case 1: return "Step \(ticked[0]) done"
        default: return "Steps \(ticked.joined(separator: " and ")) done"
        }
    }

    init(ready: WireGuardSetup.Peer.ID?, peers: [WireGuardSetup.Peer], connected: Set<String>, hotspotOn: Bool) {
        device = ready.flatMap { id in peers.first { $0.id == id } }
        let isConnected = device.map { connected.contains($0.address) } ?? false
        joined = hotspotOn || isConnected ? .done : .toDo
        config = device == nil ? .toDo : .done
        tunnel = isConnected ? .done : device == nil ? .toDo : .waiting
    }
}
