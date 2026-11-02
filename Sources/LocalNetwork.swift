import Foundation
import Network

/// Whether iOS lets Tether answer the devices on the hotspot. Their handshakes reach Tether without
/// Local Network access, but its replies need it, so without it every handshake times out and no
/// device shows up. There's no API that says (TN3179), but a Bonjour browse needs the same access, and
/// a denied one waits with kDNSServiceErr_PolicyDenied. The browse is also what makes iOS ask, and it
/// only asks while Tether is on screen: in the background it denies without asking, and without
/// remembering, so Tether may not even be listed in Settings. So `Model` runs it on screen, and again
/// when the hotspot comes up. Each browse stops at its answer, so it doesn't keep peer-to-peer Wi-Fi
/// up while Tether is on screen. A change in Settings means leaving Tether, and coming back browses again.
@MainActor
final class LocalNetworkCheck {
    /// The service type it browses for, also in Info.plist's NSBonjourServices. Nothing advertises it.
    static let serviceType = "_tether._tcp"
    /// How long a denial has to last before it counts. iOS may deny at once while its question is
    /// still up, and try again once it's answered.
    static let settle: TimeInterval = 2

    /// Called with each settled answer: true when Tether has no Local Network access.
    var onChange: (Bool) -> Void = { _ in }

    private var browser: NWBrowser?
    private var lastDenied: Bool?
    private var pending: DispatchWorkItem?

    /// Starts a new browse, so a change in Settings is read afresh.
    func start() {
        stop()
        let parameters = NWParameters()
        // Without Wi-Fi or the hotspot there may be no other local network for iOS to ask about.
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                // A state the browse before this one queued just before it was cancelled.
                guard let self, let browser, browser === self.browser else { return }
                self.update(state)
            }
        }
        browser.browseResultsChangedHandler = { _, _ in }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        pending?.cancel()
        pending = nil
    }

    private func update(_ state: NWBrowser.State) {
        guard let denied = Self.denied(state) else { return }
        pending?.cancel()
        pending = nil
        if !denied {
            browser?.cancel()
            browser = nil
            return report(false)
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.browser?.cancel()
                self?.browser = nil
                self?.report(true)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    private func report(_ denied: Bool) {
        guard denied != lastDenied else { return }
        lastDenied = denied
        onChange(denied)
    }

    /// What a browse's state says: true for no access, false for access or a browse that failed for
    /// another reason (no warning without a reason for it), nil while it's still working it out.
    nonisolated static func denied(_ state: NWBrowser.State) -> Bool? {
        switch state {
        case .ready:
            return false
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { return true }
            if case .failed = state { return false }
            return nil
        default:
            return nil
        }
    }
}
