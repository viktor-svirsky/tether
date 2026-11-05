import Foundation

/// The data limit per month a device can have, picked on its screen (#75): the menu's choices, their
/// words, and an amount typed under Other. In bytes, both ways, the way `MonthlyUsage` counts.
/// Foundation only, so `swift test` covers it.
enum DataLimit {
    /// None, then 5, 10, 20 and 50 GB, as signed off in #75.
    static let choices: [UInt64?] = [nil, 5_000_000_000, 10_000_000_000, 20_000_000_000, 50_000_000_000]
    /// Typed amounts above this many GB are taken for a typo.
    static let maxGB = 100_000.0

    static func label(_ limit: UInt64?) -> String {
        limit.map(Format.bytes) ?? "None"
    }

    /// GB typed under Other, like "7.5" (or "7,5"), as bytes. Nil for anything else, zero or less, or
    /// more than `maxGB`.
    static func bytes(typedGB: String) -> UInt64? {
        let text = typedGB.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let gb = Double(text), gb > 0, gb <= maxGB else { return nil }
        return UInt64((gb * 1_000_000_000).rounded())
    }
}
