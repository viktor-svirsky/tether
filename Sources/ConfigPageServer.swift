import Foundation
import Network

/// Serves `ConfigPage` on one address, the hotspot's. Each connection sends one request, gets one
/// answer and is closed. `respond` decides the answer. Everything runs on the main queue: a few
/// small requests from a laptop or two are no work, and HotspotSession, which answers, is there.
@MainActor
final class ConfigPageServer {
    /// The answer to a request, and who asked: the device's address on the hotspot.
    var respond: @MainActor (ConfigPage.Request, _ client: String) -> ConfigPage.Response = { _, _ in ConfigPage.notFound }
    /// Called when `listening` changes.
    var onChange: @MainActor () -> Void = {}
    /// Called when the listener fails, after it has stopped itself.
    var onFailure: @MainActor (Error) -> Void = { _ in }

    /// Started, and not failed or stopped since. HotspotSession starts one that isn't again.
    var running: Bool { listener != nil }
    /// Taking connections.
    private(set) var listening = false
    /// The port it listens on: the one asked for, or the one the system picked for port 0.
    private(set) var port: UInt16?

    private var listener: NWListener?
    private var open = 0
    /// A request that hasn't arrived whole by then gets no answer, so a stalled client can't hold a connection.
    private let timeout: TimeInterval
    private static let maxHead = 8 * 1024
    /// A browser opens two or so. More than this get closed at once.
    private static let maxConnections = 8

    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    /// Listens on host:port only, in place of a listener already running. Whether it worked comes
    /// later: `listening` turns true, or the listener stops and `onFailure` says why.
    func start(host: String, port: UInt16) {
        stop()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            onFailure(error)
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                // A listener this one replaced reports its end too.
                guard let self, let listener, listener === self.listener else { return }
                self.changed(to: state, listener)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                self.accept(connection)
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    /// Connections already open finish on their own, within `timeout`.
    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        setListening(false)
    }

    private func changed(to state: NWListener.State, _ listener: NWListener) {
        switch state {
        case .ready:
            port = listener.port?.rawValue
            setListening(true)
        case let .failed(error), let .waiting(error):
            // Waiting is for an address that isn't there (yet). The next watcher round starts again.
            stop()
            onFailure(error)
        default:
            break
        }
    }

    private func setListening(_ value: Bool) {
        guard value != listening else { return }
        listening = value
        onChange()
    }

    private func accept(_ connection: NWConnection) {
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
                    self.answer(connection, ConfigPage.Request(head))
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
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func client(of connection: NWConnection) -> String {
        if case let .hostPort(host, _) = connection.endpoint, case let .ipv4(address) = host { return "\(address)" }
        return "\(connection.endpoint)"
    }
}
