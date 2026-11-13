import Foundation

/// What the config page answers. It hands out the config only while the add window is open and
/// Tether is on screen, the same as the QR code. A download comes back as `.download` for the
/// session to save, see `HotspotSession.pageResponse`. A HEAD adds nothing. It keeps the last download, so the same device asking again soon gets the same config:
/// a browser or download manager that fetches twice mustn't list a second device.
struct ConfigPageHandler {
    /// What the session knows for this request.
    struct Inputs {
        /// The add window is open, so the server lets the ready device in.
        let letIn: Bool
        let onScreen: Bool
        let ready: WireGuardSetup.Ready?
        /// Where the config points, see `HotspotSession.deviceHost`.
        let host: String?
        /// The ready device's config pointing at `host`.
        let config: String?
        /// Each address's config that knocked but no longer works, read for this request.
        let stale: [StaleConfig]
        /// Where Tether listens. A request from there came through a tunnel that works, or from the
        /// iPhone itself, so a stale config isn't its.
        let hosts: [String]
        let now: Date
    }

    enum Decision: Equatable {
        case answer(ConfigPage.Response)
        /// Save `ready` as a device pointing at `host`, then answer with its config.
        case download(WireGuardSetup.Ready, host: String, config: String)
    }

    /// How long the same client gets the same download. A browser that fetches twice does it within a
    /// second or two. Longer, and two computers behind one address (a travel router's) would get one
    /// key (#160).
    static let repeatWithin: TimeInterval = 5

    private var lastDownload: (client: String, at: Date, response: ConfigPage.Response)?
    /// Why the page last failed, so a page that fails every round is logged once.
    private var problem: String?

    func answer(_ request: ConfigPage.Request, from client: String, _ inputs: Inputs) -> Decision {
        let state: ConfigPage.State = !inputs.letIn ? .openAddDevice : !inputs.onScreen ? .openTether
            : inputs.ready == nil ? .noConfig : .ready
        let address = PeerStats.address(client)
        // Its own knock first (#63): other devices may knock too, and old keys may be anyone's.
        let knocks = address.map(inputs.hosts.contains) == true ? [] : inputs.stale.filter { $0.shown(at: inputs.now) }
        let stale: ConfigPage.Stale? = knocks.contains { $0.kind == .device && address != nil && PeerStats.address($0.from) == address } ? .thisDevice
            : knocks.contains { $0.kind == .server } ? .oldKeys : nil
        // Only while a download could happen anyway: a closed window or Tether off screen hands out
        // no key, a repeated one neither (#160).
        let repeated = state != .ready ? nil : lastDownload.flatMap {
            $0.client == client && inputs.now.timeIntervalSince($0.at) < Self.repeatWithin ? $0.response : nil
        }
        switch request {
        case .page:
            return .answer(ConfigPage.page(state, stale: stale))
        case .pageHead:
            return .answer(ConfigPage.page(state, stale: stale).forHead)
        case .configHead:
            if let repeated { return .answer(repeated.forHead) }
            guard state == .ready, let config = inputs.config else { return .answer(ConfigPage.page(state, stale: stale, status: .notFound).forHead) }
            return .answer(ConfigPage.config(config, fileName: WireGuardSetup.fileName(for: "")).forHead)
        case .config:
            if let repeated { return .answer(repeated) }
            guard state == .ready, let ready = inputs.ready, let host = inputs.host, let config = inputs.config else {
                return .answer(ConfigPage.page(state, stale: stale, status: .notFound))
            }
            return .download(ready, host: host, config: config)
        case .notFound: return .answer(ConfigPage.notFound)
        case .notGet: return .answer(ConfigPage.notGet)
        case .malformed: return .answer(ConfigPage.malformed)
        }
    }

    /// The session saved the device and answers with `response`.
    mutating func downloaded(_ response: ConfigPage.Response, by client: String, at now: Date) {
        lastDownload = (client, now, response)
    }

    /// That config mustn't be handed out again: the hotspot went, the keys started over, or a device was removed.
    mutating func forget() {
        lastDownload = nil
    }

    /// The line to log for this failure, nil when the last one said the same.
    mutating func failed(_ error: String) -> String? {
        guard error != problem else { return nil }
        problem = error
        return "config page: \(error)"
    }

    /// A page that listens again logs its next failure.
    mutating func listening() {
        problem = nil
    }
}
