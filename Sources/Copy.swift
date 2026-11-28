import Foundation

/// Words the screens show that the UI tests check too, in one place so a change to one is a change to
/// both (#186). One wording per idea (#349): the screens, the widgets and the Shortcuts replies take
/// these, not their own spelling. Foundation only, and compiled into the UI tests and the widget
/// extension as well (project.yml), so nothing here can use another of Tether's types.
enum Copy {
    static let waitingForDevice = "Waiting for a device on the hotspot"
    /// The status card's line while sharing with no device added yet.
    static let noDeviceYet = "No device is using Tether yet"
    /// The same once a device or the proxy is added and none is connected.
    static let noDeviceConnected = "No device connected"
    static let notConnected = "Not connected"
    static let untilResumed = "Until I resume it"
    static let hotspotPath = "Settings > Personal Hotspot > Allow Others to Join"

    /// Only share through a VPN keeps the devices out (H1): the status title, and a device's or the
    /// proxy's screen.
    static let keptOut = "Devices kept out"
    static let keptOutTitle = "Kept out"
    /// The same on a device's row and the proxy's.
    static let keptOutRow = "Kept out, no VPN"
    /// Under "Kept out" on a device's screen and the proxy's.
    static let keptOutDetail = "No VPN is on, so nothing gets through. It works again when a VPN is on."
    /// The status card's link while devices are kept out, to the Settings sheet.
    static let openTetherSettings = "Open Tether's Settings"

    /// A device whose config no longer reaches this iPhone (M1): the button, and the end of the
    /// sentence on its row.
    static let giveNewConfig = "Give it a new config"
    /// A device's screen while it isn't connected (M1).
    static let notConnectedHint = "On that device, join the hotspot and turn on its tunnel in WireGuard."

    /// The label for a device's or the proxy's monthly cap (M4).
    static let dataLimit = "Data limit"
    /// The proxy while no connection is open on it (M4).
    static let notInUse = "Not in use"
    /// The proxy's screen, under Pause (M4).
    static let proxyPauseFooter = "Pause stops everything on it for a while, or until you resume it."
    /// The question before Turn off the proxy (M4).
    static let turnOffProxyTitle = "Turn off the proxy?"
    static let turnOffProxyMessage = "Every device on it loses its connection. Its data count and limit are kept."
    static let turnOffProxyButton = "Turn Off"
    /// Add a device's proxy steps (H5).
    static let turnOnProxy = "Turn on the proxy"
    static let resumeProxy = "Resume the proxy"
    static let proxyIsOn = "The proxy is on. To turn it off, tap Proxy under Devices."

    /// The foot of Home while sharing (M11), in sentence text.
    static let stopHint = "To stop, turn off Personal Hotspot. Stop on the widget and in Control Center works only while Tether is not on screen."
    /// A note on Home: Stop on a widget or in Control Center was pressed while Tether was open (M11).
    static let stopIgnored = "Stop does nothing while Tether is open. To stop, turn off Personal Hotspot."
    /// Every note on Home goes with this link, which takes it away (H3, M7, M11).
    static let gotIt = "Got it"
    /// The note on Home that offers notifications, instead of iOS asking by itself (M7).
    static let offerNotifications = "Tether can tell you when a device connects or sharing stops."
    static let allowNotifications = "Allow notifications"
    static let notNow = "Not now"

    /// Where to send the log, under Share the log (M9).
    static let issuesLink = "github.com/viktor-svirsky/tether/issues"

    /// What every copy button and copied row says for a moment (L4).
    static let copied = "Copied"
}
