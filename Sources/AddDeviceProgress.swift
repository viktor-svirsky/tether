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

/// A name typed for a device, on Add a device once it connects or through Rename on its screen.
enum DeviceName {
    /// Longer names are cut, which still fits a list row.
    static let maxLength = 40

    /// The name as it's saved: without the spaces around it, and cut to `maxLength`.
    static func saved(_ typed: String) -> String {
        String(typed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
    }

    /// What to save, or nil when there's nothing to: a blank field, or the name it has once it's
    /// cut. Done without a change saves nothing, so a store that can't save doesn't say a rename
    /// failed, and a name saved by Done isn't saved again when the sheet goes.
    static func toSave(typed: String, current: String) -> String? {
        let name = saved(typed)
        return name.isEmpty || name == current ? nil : name
    }
}

/// Add a device's naming step, from the moment the code's device first connects (#173). It stays
/// with that device while its tunnel drops and comes back, so the draft is filled once, and a
/// close while it's down still saves it.
struct AddDeviceNaming: Equatable {
    private(set) var device: WireGuardSetup.Peer.ID?
    var draft = ""

    /// Starts the step, with the device's name, the first time it connects. Later changes leave it be.
    mutating func follow(_ progress: AddDeviceProgress) {
        guard device == nil, progress.finished, let peer = progress.device else { return }
        device = peer.id
        draft = peer.name
    }

    /// The device and the name to save, or nil when there's nothing to save: no step yet, no
    /// change (see `DeviceName.toSave`), or the device was removed meanwhile.
    func change(in peers: [WireGuardSetup.Peer]) -> (id: WireGuardSetup.Peer.ID, name: String)? {
        guard let device, let peer = peers.first(where: { $0.id == device }),
              let name = DeviceName.toSave(typed: draft, current: peer.name) else { return nil }
        return (device, name)
    }
}

/// How the device in Add a device goes through Tether, its first question (#78): WireGuard, all of
/// it, or the proxy, with no app.
enum AddDeviceWay: Hashable {
    case wireGuard, proxy
}

/// Add a device's proxy path (#78): its last step ticks off once the far end answers a device
/// through the proxy that it hadn't answered lately when the screen opened, and stays ticked. The
/// proxy's connections and bytes can't tell: a TV already on it opens and moves them too (#285),
/// and a connection let in may still fail its lookup and load nothing.
struct ProxyProgress: Equatable {
    /// The devices already on the proxy: every one served in the first `settling` of a listening
    /// proxy, since a server that just started knows none yet and Go marks a busy device again
    /// every 10 s. With the server stopped or a read failed, the list is empty and says nothing. A
    /// device leaves once Go drops it after 2 minutes without traffic, so it counts as new again.
    private var opened: Set<String> = []
    private var listeningSince: Date?
    private(set) var working = false
    static let settling: TimeInterval = 12

    init(at stats: ProxyStats, now: Date = .now) {
        follow(stats, now: now)
    }

    mutating func follow(_ stats: ProxyStats, now: Date = .now) {
        guard !stats.addresses.isEmpty else { return }
        let since = listeningSince ?? now
        listeningSince = since
        if now.timeIntervalSince(since) < Self.settling {
            opened.formUnion(stats.served)
            return
        }
        if !stats.served.isSubset(of: opened) { working = true }
        opened.formIntersection(stats.served)
    }
}
