import AVFoundation
import UIKit

/// Plays a looping silent sound so iOS keeps the app (and its listener) running in the background.
/// It mixes with other audio, so music keeps playing. A phone call, Siri or an alarm interrupts it,
/// and iOS does not resume it, so it restarts itself when the interruption ends. When the media
/// services die it asks iOS for background time, and sets itself up again from scratch until
/// the sound plays.
/// Fine for a personally installed app. App Store review would reject it.
/// `KeepAlivePolicy` says when it plays.
final class KeepAlive {
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    /// The background time that keeps Tether running while the media services are gone.
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

    func start() {
        if player?.isPlaying == true { return }
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
                    let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.restart(after: .interruptionEnded) }
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
        stopHoldingOn()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restart(after event: KeepAlivePolicy.AudioEvent) {
        switch KeepAlivePolicy.restart(after: event, started: playing) {
        case .resume: start()
        case .holdOn: holdOn()
        case .rebuild:
            player = nil
            start()
            log("media services back, keep-alive sound \(sounding ? "playing" : "silent")")
            stopHoldingOn()
        case nil: break
        }
    }

    private func holdOn() {
        guard holdingOn == .invalid else { return }
        holdingOn = UIApplication.shared.beginBackgroundTask(withName: "Media services reset") { [weak self] in
            self?.log("media services still gone when the background time ran out")
            // The dead player isn't nil and may still say it plays, which would stop the next
            // watcher round from starting a new one.
            self?.player = nil
            self?.stopHoldingOn()
        }
        if holdingOn == .invalid {
            log("media services lost, and iOS gave no background time to wait for them")
        } else {
            log("media services lost, holding on until the sound plays again")
        }
        // The player is dead. mediaServicesWereReset only comes once the app uses audio again, so
        // waiting for it waits for nothing: start a new player until one plays.
        player = nil
        if holdingOn == .invalid { start() } else { startAgainWhileHoldingOn() }
    }

    /// Tries once a second until the sound plays, or the background time runs out.
    private func startAgainWhileHoldingOn() {
        guard holdingOn != .invalid else { return }
        start()
        if sounding {
            log("keep-alive sound back after the media services were lost")
            stopHoldingOn()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startAgainWhileHoldingOn() }
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
