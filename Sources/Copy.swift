import Foundation

/// Words the screens show that the UI tests check too, in one place so a change to one is a change to
/// both (#186). Foundation only, and compiled into the UI tests as well (project.yml).
enum Copy {
    static let waitingForDevice = "Waiting for a device on the hotspot"
    static let noDeviceYet = "No device is using Tether yet"
    static let notConnected = "Not connected"
    static let untilResumed = "Until I resume it"
    static let hotspotPath = "Settings > Personal Hotspot > Allow Others to Join"
}
