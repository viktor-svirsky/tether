import Foundation
import Network

/// Serves `ConfigPage` on the hotspot's addresses only, one listener each (172.20.10.1, and the
/// iPhone's IPv6 address on a carrier that gives it IPv6 only, #98). Each connection sends one request, gets one
/// answer and is closed. `respond` decides the answer. Everything runs on the main queue: a few
/// small requests from a laptop or two are no work, and HotspotSession, which answers, is there.
@MainActor
final class ConfigPageServer {
    /// The answer to a request, and who asked: the device's address on the hotspot.
    var respond: @MainActor (ConfigPage.Request, _ client: String) -> ConfigPage.Response = { _, _ in ConfigPage.notFound }
    /// Called when `readyHosts` changes.
    var onChange: @MainActor () -> Void = {}
    /// Called when a listener fails, after all of them have stopped.
    var onFailure: @MainActor (Error) -> Void = { _ in }
    /// A client that isn't on the hotspot, refused without an answer.
    var onRefused: @MainActor (_ client: String) -> Void = { _ in }

    /// Started, and not failed or stopped since. HotspotSession starts one that isn't again.
    var running: Bool { !listeners.isEmpty }
    /// Taking connections, on one address at least.
    var listening: Bool { !readyHosts.isEmpty }
    /// The addresses whose listener is taking connections, in the order they got ready. The WireGuard
    /// server opens the page's port to the devices on these only (#27).
    private(set) var readyHosts: [String] = []
    /// The port it listens on: the one asked for, or the one the system picked for port 0.
    private(set) var port: UInt16?

    private var listeners: [NWListener] = []
    /// Where it listens, for the Host check and the hotspot check, see `ConfigPage`.
    private var hosts: [String] = []
    /// Stopped listeners whose socket isn't closed yet. It closes a moment after `cancel`, when the
    /// listener reports `.cancelled`, and until then a listener on the same address and port fails
    /// with "address in use" (#102). New listeners start once these are gone.
    private var closing: [NWListener] = []
    private var open = 0
    /// A request that hasn't arrived whole by then gets no answer, so a stalled client can't hold a connection.
    private let timeout: TimeInterval
    private static let maxHead = 8 * 1024
    /// A browser opens two or so. More than this get closed at once.
    private static let maxConnections = 8

    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    /// Listens on port at each of `hosts` only, in place of listeners already running. Whether it
    /// worked comes later: `listening` turns true, or one fails, all stop, and `onFailure` says why.
    /// The port must be one for all of them, not 0, with more than one address.
    func start(hosts: [String], port: UInt16) {
        stop()
        self.hosts = hosts
        for host in hosts {
            let parameters = NWParameters.tcp
            // Without it a listener on 172.20.10.1 takes the port for IPv6 too, and the one on the
            // IPv6 address fails with "address in use". The same address twice is still refused.
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
            let listener: NWListener
            do {
                listener = try NWListener(using: parameters)
            } catch {
                stop()
                onFailure(error)
                return
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    if case .cancelled = state, let listener { self?.closed(listener) }
                    // A listener this one replaced reports its end too.
                    guard let self, let listener, self.listeners.contains(where: { $0 === listener }) else { return }
                    self.changed(to: state, listener, host)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self else { return connection.cancel() }
                    self.accept(connection)
                }
            }
            listeners.append(listener)
        }
        startOnceClosed()
    }

    private func startOnceClosed() {
        guard closing.isEmpty else { return }
        listeners.filter { $0.queue == nil }.forEach { $0.start(queue: .main) }
    }

    private func closed(_ listener: NWListener) {
        closing.removeAll { $0 === listener }
        startOnceClosed()
    }

    /// Connections already open finish on their own, within `timeout`.
    func stop() {
        closing += listeners.filter { $0.queue != nil } // one never started has no socket, and reports nothing
        listeners.forEach { $0.cancel() }
        listeners = []
        port = nil
        setReady([])
    }

    private func changed(to state: NWListener.State, _ listener: NWListener, _ host: String) {
        switch state {
        case .ready:
            port = listener.port?.rawValue
            if !readyHosts.contains(host) { setReady(readyHosts + [host]) }
        case let .failed(error), let .waiting(error):
            // Waiting is for an address that isn't there (yet), an IPv6 one still being checked
            // say. All stop, and the next watcher round starts them again. Serving on with the
            // other one would never try this one again.
            stop()
            onFailure(error)
        default:
            break
        }
    }

    private func setReady(_ hosts: [String]) {
        guard hosts != readyHosts else { return }
        readyHosts = hosts
        onChange()
    }

    private func accept(_ connection: NWConnection) {
        // Before it takes a place: the internet mustn't fill them, see `ConfigPage.onHotspot`.
        let client = Self.client(of: connection)
        guard ConfigPage.onHotspot(client, hosts: hosts) else {
            onRefused(client)
            return connection.cancel()
        }
        guard open < Self.maxConnections else { return connection.cancel() }
        open += 1
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed: connection.cancel()
                case .cancelled: self?.open -= 1
                default: break
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak connection] in connection?.cancel() }
        receive(connection, head: Data())
    }

    /// Reads until the head is complete, too long, or the client stops sending.
    private func receive(_ connection: NWConnection, head: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHead) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, error == nil else { return connection.cancel() }
                var head = head
                if let data { head.append(data) }
                if ConfigPage.headComplete(head) {
                    self.answer(connection, ConfigPage.Request(head, hosts: self.hosts))
                } else if head.count >= Self.maxHead || (isComplete && !head.isEmpty) {
                    self.answer(connection, .malformed)
                } else if isComplete {
                    connection.cancel()
                } else {
                    self.receive(connection, head: head)
                }
            }
        }
    }

    private func answer(_ connection: NWConnection, _ request: ConfigPage.Request) {
        let response = respond(request, Self.client(of: connection))
        // The final message ends the stream, so the client reads the whole body before the close.
        connection.send(content: response.bytes, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in Self.drain(connection) })
    }

    /// Reads and drops what the client still sends until it closes its side, then closes. A close with
    /// bytes left unread sends a reset, and the reset can throw away the answer before the client reads
    /// it: a head over 8 KB got no 400. `timeout` still ends a client that never closes.
    private nonisolated static func drain(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, isComplete, error in
            if isComplete || error != nil { connection.cancel() } else { drain(connection) }
        }
    }

    private static func client(of connection: NWConnection) -> String {
        if case let .hostPort(host, _) = connection.endpoint {
            if case let .ipv4(address) = host { return "\(address)" }
            if case let .ipv6(address) = host { return "\(address)" }
        }
        return "\(connection.endpoint)"
    }
}
