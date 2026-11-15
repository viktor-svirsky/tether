import Foundation

/// Whether the devices reach the iPhone's local networks: its Wi-Fi's other devices, the private
/// addresses behind a VPN on the iPhone, a Tailscale network (#230). The server refuses them while
/// they're blocked, see local.go. The setting is in Settings, read for each config the server gets.
enum LocalNetworks {
    /// Where it's saved in UserDefaults: true when the devices reach them.
    static let key = "devices.localNetworks"

    /// The saved setting. Blocked when none is saved, which only a test sees: `settle` saves one at launch.
    static func allowed(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? false
    }

    /// Saves the setting the first time this version runs. A Tether that was already set up keeps
    /// reaching them, as it did before the setting, so a laptop or router that relies on it doesn't
    /// lose them in an update. A new one shares only the internet until the owner opens them.
    static func settle(in defaults: UserDefaults, wasSetUp: Bool) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(wasSetUp, forKey: key)
    }
}
