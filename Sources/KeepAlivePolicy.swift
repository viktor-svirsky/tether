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
        /// A phone call, Siri or an alarm took the audio. With no sound iOS suspends Tether in the
        /// background for the whole call, and it doesn't hear the call end either. A mixed sound
        /// plays again as soon as the call has the audio, on iOS 27.2 at the first try (#191).
        case interruptionBegan
        /// A phone call, Siri or an alarm is over. iOS does not resume the sound by itself. Right
        /// after a call the Phone app can still hold the audio, so one try to play can fail, and
        /// with no sound iOS suspends Tether again until it is opened (#106).
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
        /// Ask iOS for background time, and keep starting the sound in it until it plays.
        case holdOn
        /// Drop the player and set the session up again with a new one, as Apple asks after a reset.
        case rebuild
    }

    /// Nil once `KeepAlive` is stopped, so an event never brings back a sound that was meant to stop.
    static func restart(after event: AudioEvent, started: Bool) -> AudioRestart? {
        guard started else { return nil }
        switch event {
        case .interruptionBegan, .interruptionEnded, .mediaServicesLost: return .holdOn
        case .mediaServicesReset: return .rebuild
        }
    }
}

/// The retry loop `KeepAlive` runs while iOS gives it background time after an audio event: start the
/// sound, and again once a second until it plays or that hold ends. Foundation only, so it's tested
/// with a fake sound and clock; `KeepAlive` gives it the real ones.
final class KeepAliveRetry {
    private let start: () -> Void
    private let sounding: () -> Bool
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private let log: (String) -> Void
    private let done: () -> Void

    /// `after` runs its work that many seconds later, `done` ends the hold once the sound plays.
    init(start: @escaping () -> Void, sounding: @escaping () -> Bool,
         after: @escaping (TimeInterval, @escaping () -> Void) -> Void, log: @escaping (String) -> Void,
         done: @escaping () -> Void) {
        self.start = start
        self.sounding = sounding
        self.after = after
        self.log = log
        self.done = done
    }

    /// Tries now, then once a second, while `isCurrent` says the hold it was started for still runs:
    /// a try left over from an earlier hold stops, so two never run at once.
    func run(after event: KeepAlivePolicy.AudioEvent, tries: Int = 1, isCurrent: @escaping () -> Bool) {
        guard isCurrent() else { return }
        start()
        if sounding() {
            log(Self.back(after: event, tries: tries))
            done()
            return
        }
        after(1) { [weak self] in
            self?.run(after: event, tries: tries + 1, isCurrent: isCurrent)
        }
    }

    /// The log line once the sound plays again.
    static func back(after event: KeepAlivePolicy.AudioEvent, tries: Int) -> String {
        let cause = switch event {
        case .mediaServicesLost: "the media services were lost"
        case .interruptionBegan: "the interruption began"
        default: "the interruption"
        }
        return "keep-alive sound back after \(cause), \(tries) \(tries == 1 ? "try" : "tries")"
    }
}
