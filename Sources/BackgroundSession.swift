import BackgroundTasks
import UIKit

/// Prototype for #229, ported from ktg3769/tether@1201199: keeps Tether running in the background
/// with iOS 26's continued processing task, in place of the silent sound. It stands in for that
/// sound behind `KeepAliveSound`.
///
/// iOS takes the request only while Tether is on screen, so `Model` requests it each time Tether
/// comes on screen. The system shows the task in its own Live Activity, where it can be cancelled.
/// Tether sets no time limit of its own: the task runs until it's cancelled in that Live Activity,
/// ended by iOS, or Tether is closed in the app switcher. Every step is logged with how long the
/// task had run, so the debug log shows how long iOS keeps it.
///
/// A proxy has no "done", so progress is a heartbeat: the completed units keep growing and the total
/// stays about twice that, so the bar sits near half and never looks finished or stuck.
@available(iOS 26.0, *)
@MainActor
final class BackgroundSession: KeepAliveSound {
    private static let title = "Tether"
    private static let subtitle = "Sharing Personal Hotspot"
    /// Info.plist allows `$(PRODUCT_BUNDLE_IDENTIFIER).keepalive.*`. Each request gets its own
    /// identifier, because one identifier can be registered only once per launch.
    private static var prefix: String { (Bundle.main.bundleIdentifier ?? "tether") + ".keepalive." }
    /// How often a running task logs its progress, so the last such line shows when iOS suspended Tether.
    private static let progressEvery: TimeInterval = 60

    private let log: (String) -> Void
    private var identifier: String?
    private var requestedAt: Date?
    private var task: BGContinuedProcessingTask?
    private var startedAt: Date?
    private var beats: Int64 = 0
    private var progressLoggedAt = Date.distantPast
    private var expirations = 0
    /// So HotspotSession's stop, repeated every watcher round, is logged once per task.
    private var stopLogged = false

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    // MARK: KeepAliveSound, as HotspotSession uses it

    var playing: Bool { task != nil }
    var sounding: Bool { task != nil }
    /// No audio, so no call can interrupt it.
    func takeInterruption() -> Bool { false }

    /// HotspotSession calls this on every watcher round while it wants Tether kept running. A task
    /// can't be requested from here (Tether may be off screen), so it only keeps a running one moving.
    func start() { heartbeat() }

    /// HotspotSession calls this once the hotspot has been gone for 10 minutes, or on an idle stop.
    /// The prototype keeps running to see how long iOS allows, so the call is only logged.
    func stop() {
        guard task != nil, !stopLogged else { return }
        stopLogged = true
        log("background task: Tether would stop keeping alive now (no hotspot or idle), ignored, task keeps running \(elapsed)")
    }

    // MARK: Requests

    /// Asks iOS for the task. Call only with Tether on screen. Nothing happens while one is
    /// requested or running.
    func request() {
        guard task == nil, identifier == nil else { return }
        // A request left over from an earlier launch could hold up the queue.
        BGTaskScheduler.shared.cancelAllTaskRequests()

        let id = Self.prefix + UUID().uuidString.lowercased()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let continued = task as? BGContinuedProcessingTask, self.identifier == id else {
                    self?.log("background task: iOS launched a task this launch didn't ask for (\(task.identifier)), ending it")
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attach(continued)
            }
        }
        guard registered else {
            log("background task: denied, couldn't register \(id) (identifier not allowed by Info.plist?)")
            return
        }

        let request = BGContinuedProcessingTaskRequest(identifier: id, title: Self.title, subtitle: Self.subtitle)
        request.strategy = .queue
        identifier = id
        requestedAt = Date()
        log("background task: requested (\(Self.short(id)), strategy queue)")
        do {
            try BGTaskScheduler.shared.submit(request)
            log("background task: granted, submit accepted, waiting for iOS to start it")
        } catch {
            identifier = nil
            requestedAt = nil
            log("background task: denied, submit failed: \(Self.describe(error))")
        }
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        self.task = task
        startedAt = Date()
        beats = 0
        stopLogged = false
        progressLoggedAt = Date()
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 1
        task.expirationHandler = { [weak self] in
            // iOS may call this off the main thread.
            Task { @MainActor [weak self] in self?.expired() }
        }
        let wait = requestedAt.map { Self.spell(Date().timeIntervalSince($0)) } ?? "?"
        log("background task: started by iOS \(wait) after the request (\(Self.short(task.identifier)))")
    }

    private func heartbeat() {
        guard let task else { return }
        beats += 1
        task.progress.totalUnitCount = beats * 2 + 100
        task.progress.completedUnitCount = beats
        let now = Date()
        if now.timeIntervalSince(progressLoggedAt) >= Self.progressEvery {
            progressLoggedAt = now
            log("background task: running \(elapsed), progress \(task.progress.completedUnitCount)/\(task.progress.totalUnitCount), \(Self.appState)")
        }
    }

    /// Cancelled in the system's Live Activity, or ended by iOS. iOS suspends Tether after this, and
    /// it's requested again the next time Tether comes on screen.
    private func expired() {
        expirations += 1
        guard let task else {
            log("background task: expiration handler called again (#\(expirations)) with no task running")
            return
        }
        log("background task: expiration handler called (#\(expirations)) after running \(elapsed), \(Self.appState): cancelled in the Live Activity or ended by iOS")
        self.task = nil
        identifier = nil
        requestedAt = nil
        startedAt = nil
        task.setTaskCompleted(success: false)
        log("background task: ended, marked completed (success false)")
    }

    /// How long the running task has run, as "for 12m 5s".
    private var elapsed: String {
        startedAt.map { "for " + Self.spell(Date().timeIntervalSince($0)) } ?? "(not started)"
    }

    private static var appState: String {
        let app = UIApplication.shared
        switch app.applicationState {
        case .active: return "on screen"
        case .inactive: return "inactive"
        case .background:
            let left = app.backgroundTimeRemaining
            return left > 1e6 ? "in background, no time limit" : "in background, \(spell(left)) left"
        @unknown default: return "state \(app.applicationState.rawValue)"
        }
    }

    private static func spell(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    /// The last part of the identifier, enough to tell requests apart in the log.
    private static func short(_ id: String) -> String { String(id.suffix(8)) }

    private static func describe(_ error: Error) -> String {
        if let error = error as? BGTaskScheduler.Error {
            switch error.code {
            case .unavailable: return "not available on this device"
            case .notPermitted: return "identifier not permitted by Info.plist"
            case .tooManyPendingTaskRequests: return "too many pending requests"
            case .immediateRunIneligible: return "not eligible to run now"
            @unknown default: return "BGTaskScheduler error \(error.code.rawValue)"
            }
        }
        return error.localizedDescription
    }
}
