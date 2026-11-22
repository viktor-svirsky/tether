import Foundation
import Network

/// The real `HotspotKnocker` (#109): a TCP connect to each address and port, all at once, on its own
/// queue so the main actor never waits for it. Nothing is sent: each connection is cancelled at its
/// first answer, or once `timeout` passed.
struct NetworkKnocker: HotspotKnocker {
    func knock(_ addresses: [String], ports: [UInt16], timeout: TimeInterval) async -> [HotspotKnock] {
        await withTaskGroup(of: HotspotKnock.self) { group in
            for address in addresses {
                for port in ports {
                    group.addTask { await Self.knock(address, port: port, timeout: timeout) }
                }
            }
            var knocks: [HotspotKnock] = []
            for await knock in group { knocks.append(knock) }
            return knocks
        }
    }

    private static let queue = DispatchQueue(label: "tether.hotspot-knock")

    private static func knock(_ address: String, port: UInt16, timeout: TimeInterval) async -> HotspotKnock {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return HotspotKnock(address: address, answer: .nobody) }
        let parameters = NWParameters.tcp
        // The hotspot's addresses are on its bridge. Never knock them over cellular.
        parameters.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: parameters)
        let answer = await withCheckedContinuation { (done: CheckedContinuation<HotspotKnock.Answer, Never>) in
            let once = Once(done)
            connection.stateUpdateHandler = { state in
                if let answer = Self.answer(state) { once.finish(answer) }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.finish(.nobody) }
        }
        connection.cancel()
        return HotspotKnock(address: address, answer: answer)
    }

    /// What a state says: a connection is open, a reset is a device with the port closed, and any other
    /// error is nobody (EHOSTDOWN, EHOSTUNREACH). Nil while it's still trying. NWConnection waits rather
    /// than fails on a refusal, so `.waiting` counts too.
    static func answer(_ state: NWConnection.State) -> HotspotKnock.Answer? {
        switch state {
        case .ready: .open
        case .waiting(let error), .failed(let error):
            if case .posix(.ECONNREFUSED) = error { .refused } else { .nobody }
        default: nil
        }
    }

    /// Resumes the continuation once: the first of an answer and the timeout wins.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done: CheckedContinuation<HotspotKnock.Answer, Never>?

        init(_ done: CheckedContinuation<HotspotKnock.Answer, Never>) { self.done = done }

        func finish(_ answer: HotspotKnock.Answer) {
            lock.lock()
            let done = self.done
            self.done = nil
            lock.unlock()
            done?.resume(returning: answer)
        }
    }
}
