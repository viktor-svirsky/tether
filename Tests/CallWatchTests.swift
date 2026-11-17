import XCTest
@testable import TetherCore

/// CallWatch with fake calls and a fake radio: the lines a call leaves in the shared log (#191).
@MainActor
final class CallWatchTests: XCTestCase {
    private final class FakeCalls: CallObserving {
        var calls: [CallState] = []
        var onChange: @MainActor () -> Void = {}

        func set(_ calls: [CallState]) {
            self.calls = calls
            onChange()
        }
    }

    private struct FakeRadio: RadioReading {
        var dataLine: String?
        var radios: [String: String]
    }

    private let first = "0000000100000001"
    private let second = "0000000100000002"
    private let call = UUID()
    private var calls: FakeCalls!
    private var logged: [String] = []
    private var watch: CallWatch!

    private func makeWatch(_ radio: FakeRadio) {
        calls = FakeCalls()
        logged = []
        watch = CallWatch(calls: calls, radio: radio, log: { [unowned self] in logged.append($0) })
    }

    private var oneLine: FakeRadio { FakeRadio(dataLine: first, radios: [first: "CTRadioAccessTechnologyLTE"]) }

    func testAnAnsweredCallLogsRingingConnectedAndEnded() {
        makeWatch(oneLine)
        calls.set([CallState(id: call, outgoing: false, connected: false, ended: false)])
        calls.set([CallState(id: call, outgoing: false, connected: true, ended: false)])
        calls.set([CallState(id: call, outgoing: false, connected: true, ended: true)])
        calls.set([])
        XCTAssertEqual(logged, [
            "call: incoming, ringing (data line: LTE)",
            "call: connected (data line: LTE)",
            "call: ended (data line: LTE)",
        ])
    }

    func testAnOutgoingCallThatNeverConnects() {
        makeWatch(oneLine)
        calls.set([CallState(id: call, outgoing: true, connected: false, ended: false)])
        calls.set([CallState(id: call, outgoing: true, connected: false, ended: true)])
        XCTAssertEqual(logged, [
            "call: outgoing, dialing (data line: LTE)",
            "call: ended, never connected (data line: LTE)",
        ])
    }

    /// CallKit reports a call again on hold, unhold and the like: only a new stage is a line.
    func testTheSameStageIsLoggedOnce() {
        makeWatch(oneLine)
        let connected = CallState(id: call, outgoing: false, connected: true, ended: false)
        for _ in 0..<5 { calls.set([connected]) }
        let ended = CallState(id: call, outgoing: false, connected: true, ended: true)
        for _ in 0..<3 { calls.set([ended]) }
        XCTAssertEqual(logged, ["call: connected (data line: LTE)", "call: ended (data line: LTE)"])
    }

    /// Tether opened during a call: it starts at the stage it finds.
    func testACallAlreadyConnectedAtLaunch() {
        calls = FakeCalls()
        calls.calls = [CallState(id: call, outgoing: false, connected: true, ended: false)]
        watch = CallWatch(calls: calls, radio: oneLine, log: { [unowned self] in logged.append($0) })
        XCTAssertEqual(logged, ["call: connected (data line: LTE)"])
    }

    /// A second call while the first goes on (call waiting) has its own lines.
    func testTwoCalls() {
        makeWatch(oneLine)
        let other = UUID()
        calls.set([CallState(id: call, outgoing: false, connected: true, ended: false)])
        calls.set([CallState(id: call, outgoing: false, connected: true, ended: false),
                   CallState(id: other, outgoing: false, connected: false, ended: false)])
        calls.set([CallState(id: call, outgoing: false, connected: true, ended: true),
                   CallState(id: other, outgoing: false, connected: true, ended: false)])
        XCTAssertEqual(logged, [
            "call: connected (data line: LTE)",
            "call: incoming, ringing (data line: LTE)",
            "call: ended (data line: LTE)",
            "call: connected (data line: LTE)",
        ])
    }

    /// The log goes into public bug reports: no call ID, no service identifier, nothing but the radio's name.
    func testNothingPrivateIsLogged() {
        makeWatch(FakeRadio(dataLine: second, radios: [first: "CTRadioAccessTechnologyNR", second: "something 0000000100000002"]))
        calls.set([CallState(id: call, outgoing: true, connected: false, ended: false)])
        calls.set([CallState(id: call, outgoing: true, connected: true, ended: true)])
        XCTAssertEqual(logged.count, 2)
        for line in logged {
            XCTAssertFalse(line.contains(call.uuidString), line)
            XCTAssertFalse(line.contains(call.uuidString.lowercased()), line)
            XCTAssertFalse(line.contains(first), line)
            XCTAssertFalse(line.contains(second), line)
            XCTAssertFalse(line.contains("something"), line)
            XCTAssertEqual(LogRedaction.redact(line), line) // nothing in it for the redaction to cut
        }
    }

    // MARK: The radio

    func testTheDataLineIsSaidByItsRadioAndLineNumber() {
        let cases: [(radio: FakeRadio, said: String, line: UInt)] = [
            (oneLine, "data line: LTE", #line),
            (FakeRadio(dataLine: first, radios: [first: "CTRadioAccessTechnologyNRNSA"]), "data line: NRNSA", #line),
            (FakeRadio(dataLine: nil, radios: [:]), "data line: no radio", #line),
            (FakeRadio(dataLine: first, radios: [:]), "data line: no radio", #line),
            // Dual SIM: the lines in the order of their identifiers.
            (FakeRadio(dataLine: first, radios: [first: "CTRadioAccessTechnologyNR", second: "CTRadioAccessTechnologyLTE"]),
             "data line: NR on line 1, line 2: LTE", #line),
            (FakeRadio(dataLine: second, radios: [first: "CTRadioAccessTechnologyNR", second: "CTRadioAccessTechnologyLTE"]),
             "data line: LTE on line 2, line 1: NR", #line),
            // The data line has no radio now, as on a call on the other line without data switching.
            (FakeRadio(dataLine: second, radios: [first: "CTRadioAccessTechnologyLTE"]), "data line: none, line 1: LTE", #line),
            (FakeRadio(dataLine: nil, radios: [first: "CTRadioAccessTechnologyLTE", second: "CTRadioAccessTechnologyWCDMA"]),
             "data line: unknown, line 1: LTE, line 2: WCDMA", #line),
            // Anything that isn't a radio's name is left out.
            (FakeRadio(dataLine: first, radios: [first: "0000000100000001"]), "data line: other", #line),
        ]
        for c in cases {
            XCTAssertEqual(Cellular.dataLine(c.radio), c.said, line: c.line)
        }
    }

    // MARK: pdp_ip0

    /// pdp_ip0 carries the cellular data: whether it still has an address when the hotspot goes away
    /// says whether the data went too, or only the hotspot.
    func testWhatPdpIp0Has() {
        let cases: [(interfaces: [String], said: String, line: UInt)] = [
            ([], "pdp_ip0: no address", #line),
            (["bridge100: 172.20.10.1", "en0: 192.168.1.5"], "pdp_ip0: no address", #line),
            (["pdp_ip0: fe80::1%pdp_ip0"], "pdp_ip0: no address", #line), // link-local only
            (["pdp_ip0: 2607:fb91::1", "pdp_ip0: fe80::1%pdp_ip0"], "pdp_ip0: IPv6", #line),
            (["pdp_ip0: 2607:fb91::1", "pdp_ip0: 192.0.0.2"], "pdp_ip0: IPv6", #line), // a CLAT's isn't the carrier's IPv4
            (["pdp_ip0: 10.20.30.40"], "pdp_ip0: IPv4", #line),
            (["pdp_ip0: 10.20.30.40", "pdp_ip0: 2607:fb91::1"], "pdp_ip0: IPv4 and IPv6", #line),
            (["pdp_ip1: 2607:fb91::2"], "pdp_ip0: no address", #line), // VoLTE's own interface
        ]
        for c in cases {
            XCTAssertEqual(Interfaces.pdpIp0(in: c.interfaces), c.said, line: c.line)
            XCTAssertFalse(Interfaces.pdpIp0(in: c.interfaces).contains("2607"), line: c.line)
            XCTAssertEqual(LogRedaction.redact(c.said), c.said, line: c.line)
        }
    }
}
