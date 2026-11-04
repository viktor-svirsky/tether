import Foundation

/// The speeds from how far the server's totals moved since the last sample. `HotspotSession` samples
/// every second on screen and resets it when the time since the last sample means nothing (off
/// screen, a new hotspot), so the first speed back doesn't average the time away in.
struct TrafficSampler {
    private var last: (totals: TrafficTotals, at: Date)?

    /// Bits per second up and down since the last sample, or nil when there's nothing to compare
    /// with: the first sample, or one at the same instant as the last.
    mutating func sample(_ totals: TrafficTotals, at now: Date) -> (up: Double, down: Double)? {
        defer { last = (totals, now) }
        guard let last else { return nil }
        let seconds = now.timeIntervalSince(last.at)
        guard seconds > 0 else { return nil }
        return (Self.bps(totals.bytesUp, last.totals.bytesUp, seconds), Self.bps(totals.bytesDown, last.totals.bytesDown, seconds))
    }

    mutating func reset() {
        last = nil
    }

    /// The server's counters never go backwards. The guard is only a safety net.
    private static func bps(_ new: UInt64, _ old: UInt64, _ seconds: TimeInterval) -> Double {
        new >= old ? Double(new - old) * 8 / seconds : 0
    }
}
