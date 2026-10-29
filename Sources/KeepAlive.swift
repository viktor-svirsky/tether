import AVFoundation

/// Plays a looping silent sound so iOS keeps the app (and its listener) running in the background.
/// It mixes with other audio, so music keeps playing. A phone call, Siri or an alarm interrupts it,
/// and iOS does not resume it, so it restarts itself when the interruption ends. After a media
/// services reset it sets itself up again from scratch.
/// Fine for a personally installed app. App Store review would reject it.
/// `KeepAlivePolicy` says when it plays.
final class KeepAlive {
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []

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
        try? session.setActive(true)
        if player == nil {
            player = try? AVAudioPlayer(data: Self.silentWav(seconds: 1))
            player?.numberOfLoops = -1
            player?.volume = 0
        }
        player?.play()
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: session, queue: .main
                ) { [weak self] note in
                    let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.restart(after: .interruptionEnded) }
                },
                // Apple doesn't say which object posts it, so this listens to any. The observers
                // themselves live through a reset.
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
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restart(after event: KeepAlivePolicy.AudioEvent) {
        switch KeepAlivePolicy.restart(after: event, started: playing) {
        case .resume: start()
        case .rebuild:
            player = nil
            start()
        case nil: break
        }
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
