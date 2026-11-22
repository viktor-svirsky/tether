import Foundation

/// The device Add a device follows (#181): the one behind the code that was ready when the sheet
/// opened. Until it's claimed, a new code (after starting over, say) takes its place. See
/// `AddDeviceProgress` for how far it has got.
struct AddDeviceFollow {
    private(set) var ready: WireGuardSetup.Peer.ID?

    /// `follows` is the listed device a demo opens on, see `Model.addDeviceFollows`, and `ready` the
    /// code ready when the sheet opened.
    init(follows: WireGuardSetup.Peer.ID?, ready: WireGuardSetup.Peer.ID?) {
        self.ready = follows ?? ready
    }

    func progress(peers: [WireGuardSetup.Peer], connected: Set<String>, hotspotOn: Bool) -> AddDeviceProgress {
        AddDeviceProgress(ready: ready, peers: peers, connected: connected, hotspotOn: hotspotOn)
    }

    /// A new ready code takes the device's place while it isn't listed: not claimed yet, or removed.
    mutating func readyChanged(to new: WireGuardSetup.Peer.ID?, peers: [WireGuardSetup.Peer]) {
        if !peers.contains(where: { $0.id == ready }) { ready = new }
    }

    /// Only on the WireGuard steps, until the device connects: the page hands out the config only
    /// while Tether is on screen. The proxy works with the screen off.
    static func keepsScreenAwake(on way: AddDeviceWay?, _ progress: AddDeviceProgress) -> Bool {
        way == .wireGuard && progress.keepsScreenAwake
    }
}
