import Foundation

/// One call as CallKit reports it. `id` tells the calls apart and never goes into the log.
struct CallState: Equatable {
    let id: UUID
    let outgoing: Bool
    let connected: Bool
    let ended: Bool
}

/// The calls on this iPhone, cellular ones too. `SystemCalls` is the real one, the tests have a fake.
@MainActor
protocol CallObserving: AnyObject {
    /// The calls on now, read at launch.
    var calls: [CallState] { get }
    /// Called with a call that starts, connects, ends or changes otherwise. iOS may have dropped an
    /// ended call from `calls` by then.
    var onChange: @MainActor (CallState) -> Void { get set }
}

/// The cellular radio of each line. `SystemRadio` is the real one, the tests have a fake.
protocol RadioReading {
    /// The service identifier of the line that carries cellular data, nil when iOS doesn't say.
    var dataLine: String? { get }
    /// Each line's radio, like "CTRadioAccessTechnologyLTE", by service identifier.
    var radios: [String: String] { get }
}

/// Writes a line to the shared log when a call rings or dials, connects and ends, with the data
/// line's radio, so a log shows whether the hotspot went away during a call and whether the call
/// moved the data to another radio or line (#191). Never a number, a contact or an identifier.
/// Foundation only.
@MainActor
final class CallWatch {
    private enum Stage: Int, Comparable {
        case started, connected, ended
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    /// Kept, since CallKit holds its delegate weakly.
    private let calls: CallObserving
    private let cellular: Cellular
    private let log: @MainActor (String) -> Void
    /// The last stage logged for each call, kept for the app's life: a few a day, and CallKit may
    /// report an ended call again.
    private var stages: [UUID: Stage] = [:]

    init(calls: CallObserving, cellular: Cellular, log: @escaping @MainActor (String) -> Void) {
        self.calls = calls
        self.cellular = cellular
        self.log = log
        calls.onChange = { [weak self] in self?.update($0) }
        calls.calls.forEach(update) // a call that was on before Tether launched
    }

    /// CallKit reports a call again on hold and the like, so only a later stage is a line.
    private func update(_ call: CallState) {
        let stage: Stage = call.ended ? .ended : call.connected ? .connected : .started
        if let logged = stages[call.id], stage <= logged { return }
        stages[call.id] = stage
        let what = switch stage {
        case .started: call.outgoing ? "outgoing, dialing" : "incoming, ringing"
        case .connected: "connected"
        case .ended: call.connected ? "ended" : "ended, never connected"
        }
        log("call: \(what) (\(cellular.dataLine()))")
    }
}

/// The data line's radio as the log says it.
@MainActor
final class Cellular {
    private let radio: RadioReading
    /// Every line's identifier seen so far, kept for the app's life, so a line that loses its
    /// service keeps its number and doesn't renumber the other.
    private var seen: Set<String> = []

    init(radio: RadioReading) {
        self.radio = radio
    }

    /// Like "data line: LTE", and on Dual SIM "data line: NR on line 1, line 2: LTE". The lines are
    /// numbered in the order of their identifiers, which are left out, and so is anything that
    /// isn't a radio's name. A line seen before with no radio now says "no service".
    func dataLine() -> String {
        let radios = radio.radios
        let dataLine = radio.dataLine
        seen.formUnion(radios.keys)
        if let dataLine { seen.insert(dataLine) }
        guard !seen.isEmpty else { return "data line: no radio" }
        let lines = seen.sorted().enumerated().map { (number: $0.offset + 1, id: $0.element) }
        let name = { (id: String) in radios[id].map(Self.name) ?? "no service" }
        if let data = lines.first(where: { $0.id == dataLine }) {
            let head = lines.count == 1 ? "data line: \(name(data.id))" : "data line: \(name(data.id)) on line \(data.number)"
            return ([head] + lines.filter { $0.id != data.id }.map { "line \($0.number): \(name($0.id))" }).joined(separator: ", ")
        }
        return (["data line: unknown"] + lines.map { "line \($0.number): \(name($0.id))" }).joined(separator: ", ")
    }

    /// "LTE" from "CTRadioAccessTechnologyLTE", "other" for anything else.
    private static func name(_ radio: String) -> String {
        let prefix = "CTRadioAccessTechnology"
        let short = radio.hasPrefix(prefix) ? radio.dropFirst(prefix.count) : ""
        let plain = !short.isEmpty && short.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return plain ? String(short) : "other"
    }
}

#if canImport(CallKit) && os(iOS)
import CallKit
import CoreTelephony

/// CallKit's calls, cellular ones too. It needs no permission.
@MainActor
final class SystemCalls: NSObject, CallObserving, CXCallObserverDelegate {
    private let observer = CXCallObserver()
    var onChange: @MainActor (CallState) -> Void = { _ in }

    override init() {
        super.init()
        observer.setDelegate(self, queue: .main)
    }

    var calls: [CallState] { observer.calls.map(Self.state) }

    /// From the call iOS hands over, which may be gone from `observer.calls` once it ended.
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let state = Self.state(call)
        MainActor.assumeIsolated { onChange(state) }
    }

    private nonisolated static func state(_ call: CXCall) -> CallState {
        CallState(id: call.uuid, outgoing: call.isOutgoing, connected: call.hasConnected, ended: call.hasEnded)
    }
}

/// Read each time, so a line shows the radio of the moment.
final class SystemRadio: RadioReading {
    private let info = CTTelephonyNetworkInfo()
    var dataLine: String? { info.dataServiceIdentifier }
    var radios: [String: String] { info.serviceCurrentRadioAccessTechnology ?? [:] }
}
#endif
