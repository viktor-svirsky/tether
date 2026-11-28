import Foundation

/// The device Add a device follows (#181): the one behind the code that was ready when the sheet
/// opened. Until it's claimed, a new code (after starting over, say) takes its place. See
/// `AddDeviceProgress` for how far it has got.
struct AddDeviceFollow {
    private(set) var ready: WireGuardSetup.Peer.ID?
    /// The device given a new config (M1), as it was when the sheet opened. It keeps its id when the
    /// code is claimed, so it's followed by its key: listed with another key, it has the new config.
    private let replacing: WireGuardSetup.Peer?

    /// `follows` is the listed device a demo opens on, see `Model.addDeviceFollows`, and `ready` the
    /// code ready when the sheet opened. `replacing` is the device the sheet gives a new config to,
    /// see `Model.openAddWindow(replacing:)`.
    init(follows: WireGuardSetup.Peer.ID?, ready: WireGuardSetup.Peer.ID?, replacing: WireGuardSetup.Peer? = nil) {
        self.ready = follows ?? ready
        self.replacing = replacing
    }

    func progress(peers: [WireGuardSetup.Peer], connected: Set<String>, hotspotOn: Bool) -> AddDeviceProgress {
        guard let replacing else { return AddDeviceProgress(ready: ready, peers: peers, connected: connected, hotspotOn: hotspotOn) }
        // Until its key changes, the device the sheet follows isn't there yet.
        let claimed = peers.filter { $0.id != replacing.id || $0.publicKey != replacing.publicKey }
        return AddDeviceProgress(ready: replacing.id, peers: claimed, connected: connected, hotspotOn: hotspotOn)
    }

    /// A new ready code takes the device's place while it isn't listed: not claimed yet, or removed.
    /// Not for a device given a new config, which is followed by its own id.
    mutating func readyChanged(to new: WireGuardSetup.Peer.ID?, peers: [WireGuardSetup.Peer]) {
        guard replacing == nil else { return }
        if !peers.contains(where: { $0.id == ready }) { ready = new }
    }

    /// Only on the WireGuard steps, until the device connects: the page hands out the config only
    /// while Tether is on screen. The proxy works with the screen off.
    static func keepsScreenAwake(on way: AddDeviceWay?, _ progress: AddDeviceProgress) -> Bool {
        way == .wireGuard && progress.keepsScreenAwake
    }
}
