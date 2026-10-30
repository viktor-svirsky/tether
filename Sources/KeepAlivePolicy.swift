import Foundation

/// When the silent sound in `KeepAlive` plays. It keeps Tether running in the background, which
/// costs battery all the time, also with nothing to share: a night in airplane mode cost more than
/// any other app. So it plays while Personal Hotspot is on, and stops once the hotspot has been
/// gone for a while. iOS then suspends Tether until it is opened again.
enum KeepAlivePolicy {
    /// Long enough for a USB cable or a Wi-Fi drop to come back, and for turning on Personal
    /// Hotspot in Settings after opening Tether.
    static let grace: TimeInterval = 10 * 60

    /// `waitingSince` is when the hotspot went away, or when Tether was last opened if that was later.
    /// Nil while the hotspot is on.
    static func plays(waitingSince: Date?, now: Date) -> Bool {
        guard let waitingSince else { return true }
        return now.timeIntervalSince(waitingSince) < grace
    }

    /// The hotspot is watched every 5 seconds on screen, where starting at once shows. In the
    /// background a device that joins waits a little longer, and Tether wakes a third as often.
    static func watchInterval(sceneActive: Bool) -> (every: Duration, tolerance: Duration) {
        sceneActive ? (.seconds(5), .seconds(1)) : (.seconds(15), .seconds(5))
    }

    /// What the audio system tells `KeepAlive` that can leave the sound silent.
    enum AudioEvent {
        /// A phone call, Siri or an alarm is over. iOS does not resume the sound by itself.
        case interruptionEnded
        /// The media server died, after a crash or Reset Media Services in Settings. Without a sound
        /// iOS suspends Tether in the background within seconds, and `mediaServicesReset` only
        /// comes once the app uses audio again, so waiting for it never ends. Seen on iOS 27.2.
        case mediaServicesLost
        /// The media server is back. It only says so once the app uses audio again. The old player
        /// is dead but not nil, so playing it again fails quietly.
        case mediaServicesReset
    }

    enum AudioRestart {
        /// Play the same player again.
        case resume
        /// Ask iOS for background time, and keep starting a new player in it until one plays.
        case holdOn
        /// Drop the player and set the session up again with a new one, as Apple asks after a reset.
        case rebuild
    }

    /// Nil once `KeepAlive` is stopped, so an event never brings back a sound that was meant to stop.
    static func restart(after event: AudioEvent, started: Bool) -> AudioRestart? {
        guard started else { return nil }
        switch event {
        case .interruptionEnded: return .resume
        case .mediaServicesLost: return .holdOn
        case .mediaServicesReset: return .rebuild
        }
    }
}
