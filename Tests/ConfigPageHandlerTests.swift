import XCTest
@testable import TetherCore

/// What the config page answers, from what the session tells it about this request. Saving the
/// device is the session's: a download comes back as a decision for it.
final class ConfigPageHandlerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let ready: WireGuardSetup.Ready = {
        var setup = WireGuardSetup.new()
        setup.prepareReady()
        return setup.ready!
    }()
    private let config = "[Interface]\nPrivateKey = x\n"

    private func inputs(letIn: Bool = true, onScreen: Bool = true, noReady: Bool = false,
                        host: String? = "172.20.10.1", config: String? = nil, at: Date? = nil) -> ConfigPageHandler.Inputs {
        ConfigPageHandler.Inputs(letIn: letIn, onScreen: onScreen, ready: noReady ? nil : ready, host: host,
                                 config: config ?? self.config, now: at ?? start)
    }

    func testThePageSaysWhatsMissing() {
        let handler = ConfigPageHandler()
        let cases: [(ConfigPageHandler.Inputs, ConfigPage.State, UInt)] = [
            (inputs(letIn: false), .openAddDevice, #line), // Add a device closed more than 10 minutes ago
            (inputs(letIn: false, onScreen: false), .openAddDevice, #line), // that comes first
            (inputs(onScreen: false), .openTether, #line),
            (inputs(noReady: true), .noConfig, #line),
            (inputs(), .ready, #line),
        ]
        for (inputs, state, line) in cases {
            XCTAssertEqual(handler.answer(.page, from: "172.20.10.3", inputs), .answer(ConfigPage.page(state)), line: line)
            XCTAssertEqual(handler.answer(.pageHead, from: "172.20.10.3", inputs), .answer(ConfigPage.page(state).forHead), line: line)
        }
    }

    func testADownloadIsTheSessionsToSave() {
        let handler = ConfigPageHandler()
        XCTAssertEqual(handler.answer(.config, from: "172.20.10.3", inputs()), .download(ready, host: "172.20.10.1", config: config))
    }

    func testNoDownloadWithoutEverythingItNeeds() {
        let handler = ConfigPageHandler()
        let cases: [(ConfigPageHandler.Inputs, ConfigPage.State, UInt)] = [
            (inputs(letIn: false), .openAddDevice, #line),
            (inputs(onScreen: false), .openTether, #line),
            (inputs(noReady: true), .noConfig, #line),
            // An IPv6-only carrier before a device joined: there's no address to point a config at.
            (inputs(host: nil), .ready, #line),
        ]
        for (inputs, state, line) in cases {
            XCTAssertEqual(handler.answer(.config, from: "172.20.10.3", inputs), .answer(ConfigPage.page(state, status: .notFound)), line: line)
        }
    }

    /// A HEAD says what a download would be and adds nothing.
    func testAHeadForTheConfigAddsNothing() {
        let handler = ConfigPageHandler()
        XCTAssertEqual(handler.answer(.configHead, from: "172.20.10.3", inputs()),
                       .answer(ConfigPage.config(config, fileName: WireGuardSetup.fileName(for: "")).forHead))
        XCTAssertEqual(handler.answer(.configHead, from: "172.20.10.3", inputs(onScreen: false)),
                       .answer(ConfigPage.page(.openTether, status: .notFound).forHead))
    }

    /// A browser or download manager that fetches twice mustn't list a second device.
    func testTheSameClientAgainWithinAMinuteGetsTheSameConfig() {
        var handler = ConfigPageHandler()
        let saved = ConfigPage.config(config, fileName: "Tether-Device.conf")
        handler.downloaded(saved, by: "172.20.10.3", at: start)
        XCTAssertEqual(handler.answer(.config, from: "172.20.10.3", inputs(at: start.addingTimeInterval(ConfigPageHandler.repeatWithin - 1))), .answer(saved))
        XCTAssertEqual(handler.answer(.configHead, from: "172.20.10.3", inputs(at: start.addingTimeInterval(ConfigPageHandler.repeatWithin - 1))), .answer(saved.forHead))
        // Even once the window has closed: it's the same download.
        XCTAssertEqual(handler.answer(.config, from: "172.20.10.3", inputs(letIn: false, at: start.addingTimeInterval(ConfigPageHandler.repeatWithin - 1))), .answer(saved))
        // Another device, or a minute later, is a new download.
        XCTAssertEqual(handler.answer(.config, from: "172.20.10.4", inputs(at: start.addingTimeInterval(1))),
                       .download(ready, host: "172.20.10.1", config: config))
        XCTAssertEqual(handler.answer(.config, from: "172.20.10.3", inputs(at: start.addingTimeInterval(ConfigPageHandler.repeatWithin))),
                       .download(ready, host: "172.20.10.1", config: config))
    }

    /// The hotspot going, a reset or a removal: that config mustn't be handed out again.
    func testAForgottenDownloadIsntRepeated() {
        var handler = ConfigPageHandler()
        handler.downloaded(ConfigPage.config(config, fileName: "Tether-Device.conf"), by: "172.20.10.3", at: start)
        handler.forget()
        XCTAssertEqual(handler.answer(.config, from: "172.20.10.3", inputs(at: start.addingTimeInterval(1))),
                       .download(ready, host: "172.20.10.1", config: config))
    }

    func testRequestsItDoesntServe() {
        let handler = ConfigPageHandler()
        XCTAssertEqual(handler.answer(.notFound, from: "x", inputs()), .answer(ConfigPage.notFound))
        XCTAssertEqual(handler.answer(.notGet, from: "x", inputs()), .answer(ConfigPage.notGet))
        XCTAssertEqual(handler.answer(.malformed, from: "x", inputs()), .answer(ConfigPage.malformed))
    }

    /// A page that fails every round is logged once, and again after it listened in between.
    func testAFailureIsLoggedOnceUntilThePageListensAgain() {
        var handler = ConfigPageHandler()
        XCTAssertEqual(handler.failed("address in use"), "config page: address in use")
        XCTAssertNil(handler.failed("address in use"))
        XCTAssertEqual(handler.failed("no route"), "config page: no route")
        handler.listening()
        XCTAssertEqual(handler.failed("no route"), "config page: no route")
    }
}
