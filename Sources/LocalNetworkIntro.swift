import Foundation

/// The screen before iOS asks for Local Network access (#92). iOS asks at the first check, with one
/// line from Tether, and a Don't Allow there means no device can connect. So Tether first says what
/// it's for, once, and runs no check before that. Every check goes through `check()`: at launch, on
/// coming back on screen and when the hotspot comes up, so none of them asks early.
/// Tether's replies to a device on the hotspot can make iOS ask too, and the server isn't held back
/// for this screen: after an update, Start Tether in Shortcuts has to share without it. So a device
/// still set up from before a reinstall can bring the question up while the screen shows.
@MainActor
final class LocalNetworkIntro {
    /// Where Continue is saved. A launch argument (`-localNetworkIntroduced YES` or `NO`) sets it for
    /// one run, which the UI tests use, and wins over Continue in that run.
    static let key = "localNetworkIntroduced"

    private let defaults: UserDefaults
    private let start: () -> Void

    /// `start` runs a check, see `LocalNetworkCheck.start`.
    init(defaults: UserDefaults, start: @escaping () -> Void) {
        self.defaults = defaults
        self.start = start
    }

    /// Until Continue.
    var shown: Bool { !defaults.bool(forKey: Self.key) }

    func check() {
        if !shown { start() }
    }

    /// Continue: this check makes iOS ask, and every check runs from now on.
    func finish() {
        defaults.set(true, forKey: Self.key)
        start()
    }
}
