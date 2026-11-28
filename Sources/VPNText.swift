import Foundation

/// What Settings and the main screen say about Only share through a VPN. Foundation only, so `swift
/// test` covers it.
enum VPNText {
    /// Settings > VPN > Now. With the switch on and no VPN, the effect too (M8), in the Live
    /// Activity's words.
    static func now(vpn: Bool, onlyFamily: Interfaces.Family?, onlyThroughVPN: Bool) -> String {
        if vpn { return "Through a VPN" }
        let what = onlyFamily.map { "VPN for \($0.rawValue) only" } ?? "No VPN"
        return onlyThroughVPN ? "\(what), devices kept out" : what
    }

    /// The status card's line under "Devices kept out" (H1).
    static func keptOutLine(onlyFamily: Interfaces.Family?) -> String {
        onlyFamily.map { "Your VPN carries only \($0.rawValue)" } ?? "No VPN is on"
    }

    /// A kept-out device's row and the proxy's (H1): "Kept out, no VPN", or the VPN that carries one family.
    static func keptOutRow(onlyFamily: Interfaces.Family?) -> String {
        "Kept out, " + (onlyFamily.map { "VPN for \($0.rawValue) only" } ?? "no VPN")
    }

    /// Under "Kept out" on a device's screen and the proxy's, in the status card's words.
    static func keptOutDetail(onlyFamily: Interfaces.Family?) -> String {
        let why = keptOutLine(onlyFamily: onlyFamily)
        guard let family = onlyFamily else { return "\(why), so nothing gets through. It works again when a VPN is on." }
        return "\(why), so nothing gets through. It works again when it carries \(family.other.rawValue) too."
    }

    /// The status card's text under that line while the devices are kept out (H1).
    static func blocked(onlyFamily: Interfaces.Family?) -> String {
        guard let family = onlyFamily else {
            return "No device gets through until a VPN is on. Turn your VPN on, or turn off Only share through a VPN in Settings."
        }
        let other = family.other.rawValue
        return "This iPhone's \(other) goes around it, so no device gets through. Turn on \(other) in your VPN, or turn off Only share through a VPN in Settings."
    }
}
