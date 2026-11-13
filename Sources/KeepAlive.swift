import AVFoundation
import UIKit

/// Plays a looping silent sound so iOS keeps the app (and its listener) running in the background.
/// It mixes with other audio, so music keeps playing. A phone call, Siri or an alarm interrupts it,
/// and iOS does not resume it. When the interruption ends, or the media services die, it asks iOS
/// for background time and keeps starting the sound in it until it plays.
/// Fine for a personally installed app. App Store review would reject it.
/// `KeepAlivePolicy` says when it plays.
final class KeepAlive {
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    /// The background time that keeps Tether running until the sound plays again.
    private var holdingOn: UIBackgroundTaskIdentifier = .invalid
    /// The last reason the sound didn't start, so a failure that repeats every watcher round is logged once.
    private var lastFailure: String?
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    /// Started and not stopped, also while a call has paused it.
    var playing: Bool { player != nil }
    /// Making its sound right now. Starting it can fail, in the background say.
    var sounding: Bool { player?.isPlaying == true }
    /// A call, Siri or an alarm took the audio, and the sound hasn't played since. iOS doesn't always
    /// say when a call is over, so the next sound that plays is what ends it.
    private(set) var interrupted = false

    func start() {
        if player?.isPlaying == true {
            interrupted = false // it plays again, by itself after the interruption, say
            return
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        // Nobody hears it, so latency doesn't matter. The longest buffer iOS gives wakes the CPU
        // the fewest times a second to feed the audio hardware.
        try? session.setPreferredIOBufferDuration(0.5)
        do {
            try session.setActive(true)
            if player == nil {
                player = try AVAudioPlayer(data: Self.silentWav(seconds: 1))
                player?.numberOfLoops = -1
                player?.volume = 0
            }
            if player?.play() != true { throw Silent() }
            interrupted = false
            lastFailure = nil
        } catch {
            let failure = "keep-alive sound didn't start: \(error)"
            if failure != lastFailure { log(failure) }
            lastFailure = failure
        }
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: session, queue: .main
                ) { [weak self] note in
                    self?.interrupted(note.userInfo ?? [:])
                },
                // Apple doesn't say which object posts these, so they listen to any. The observers
                // themselves live through a reset.
                center.addObserver(
                    forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    self?.restart(after: .mediaServicesLost)
                },
                center.addObserver(
                    forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    self?.restart(after: .mediaServicesReset)
                },
            ]
        }
    }

    func stop() {
        player?.stop()
        player = nil
        interrupted = false
        stopHoldingOn()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func interrupted(_ info: [AnyHashable: Any]) {
        guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
        switch AVAudioSession.InterruptionType(rawValue: raw) {
        case .began:
            let reason = (info[AVAudioSessionInterruptionReasonKey] as? UInt).map(String.init) ?? "none"
            log("a call, Siri or an alarm interrupted the keep-alive sound (reason \(reason))")
            interrupted = true
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            log("interruption over (shouldResume: \(options.contains(.shouldResume)))")
            restart(after: .interruptionEnded)
        default: break
        }
    }

    private func restart(after event: KeepAlivePolicy.AudioEvent) {
        switch KeepAlivePolicy.restart(after: event, started: playing) {
        case .holdOn: holdOn(after: event)
        case .rebuild:
            player = nil
            start()
            log("media services back, keep-alive sound \(sounding ? "playing" : "silent")")
            stopHoldingOn()
        case nil: break
        }
    }

    private func holdOn(after event: KeepAlivePolicy.AudioEvent) {
        let lost = event == .mediaServicesLost
        // After a media services loss the player is dead. mediaServicesWereReset only comes once the
        // app uses audio again, so waiting for it waits for nothing: start a new player until one
        // plays. Drop it even when a hold after a call is already running, or that hold would take the
        // dead player for a playing one. After a call the player is fine and plays again once the
        // session is back.
        if lost { player = nil }
        guard holdingOn == .invalid else { return }
        holdingOn = UIApplication.shared.beginBackgroundTask(withName: lost ? "Media services reset" : "Interruption over") { [weak self] in
            if lost {
                self?.log("media services still gone when the background time ran out")
                // The dead player isn't nil and may still say it plays, which would stop the next
                // watcher round from starting a new one.
                self?.player = nil
            } else {
                self?.log("sound still silent when the background time ran out, waiting to be opened")
            }
            self?.stopHoldingOn()
        }
        // After an interruption the line before says it is over.
        let cause = lost ? "media services lost, " : ""
        log(holdingOn == .invalid
            ? "\(cause)iOS gave no background time to wait for the sound"
            : "\(cause)holding on until the sound plays")
        if holdingOn == .invalid { start() } else { startAgainWhileHoldingOn(holdingOn, after: event, tries: 1) }
    }

    /// Tries once a second until the sound plays, or the background time `task` runs out. A try left
    /// over from an earlier hold stops, so two never run at once.
    private func startAgainWhileHoldingOn(_ task: UIBackgroundTaskIdentifier, after event: KeepAlivePolicy.AudioEvent, tries: Int) {
        guard holdingOn == task else { return }
        start()
        if sounding {
            let cause = event == .mediaServicesLost ? "the media services were lost" : "the interruption"
            log("keep-alive sound back after \(cause), \(tries) \(tries == 1 ? "try" : "tries")")
            stopHoldingOn()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startAgainWhileHoldingOn(task, after: event, tries: tries + 1)
        }
    }

    private func stopHoldingOn() {
        guard holdingOn != .invalid else { return }
        UIApplication.shared.endBackgroundTask(holdingOn)
        holdingOn = .invalid
    }

    /// `play()` said no without an error.
    private struct Silent: Error, CustomStringConvertible {
        var description: String { "the player refused to play" }
    }

    private static func silentWav(seconds: Int) -> Data {
        let rate: UInt32 = 8000
        let samples = UInt32(seconds) * rate
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate); u16(1); u16(8)
        d.append(contentsOf: Array("data".utf8)); u32(samples)
        d.append(Data(repeating: 128, count: Int(samples)))
        return d
    }
}
