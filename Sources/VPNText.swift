import Foundation

/// What Settings and the main screen say about Only share through a VPN. Foundation only, so `swift
/// test` covers it.
enum VPNText {
    /// Settings > VPN > Now.
    static func now(vpn: Bool, onlyFamily: Interfaces.Family?) -> String {
        if vpn { return "Through a VPN" }
        if let onlyFamily { return "VPN for \(onlyFamily.rawValue) only" }
        return "No VPN"
    }

    /// The main screen while the devices are kept out.
    static func blocked(onlyFamily: Interfaces.Family?) -> String {
        guard let family = onlyFamily else {
            return "No VPN is on, so no device gets through until one is. Turn your VPN on, or turn off Only share through a VPN in Settings."
        }
        let other = family.other.rawValue
        return "Your VPN carries only \(family.rawValue), and this iPhone's \(other) goes around it, so no device gets through. Turn on \(other) in your VPN, or turn off Only share through a VPN in Settings."
    }
}
