import SwiftUI

struct MainView: View {
    @ObservedObject private var model = Model.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showSettings = false
    @State private var addingDevice = false
    /// The Settings button grows with the text size, so the dots stay inside its tap area.
    @ScaledMetric(relativeTo: .title3) private var settingsSize: CGFloat = 44

    /// A state change on this screen: the status, a warning that comes or goes, and a device or the
    /// proxy that comes, goes, connects or pauses. The list animates it, so rows and blocks fade in
    /// and out and the heights ease instead of jumping.
    private struct Change: Equatable {
        let status: HomeStatus
        let notes: [String]
        let others: [Bool]
        let devices: [Int]
        let proxy: Int?
    }

    private var change: Change {
        Change(status: model.homeStatus,
               notes: model.homeNotes.map(\.id),
               others: [model.notUsingTether.isEmpty, model.wireGuardReady != nil],
               devices: model.wireGuardPeers.map {
                   var hasher = Hasher()
                   hasher.combine($0.id)
                   hasher.combine(DeviceStatus($0, connected: model.wireGuardConnected, keptOut: model.blockedWithoutVPN, onlyFamily: model.vpnOnlyFamily).hashKey)
                   hasher.combine(model.limitStanding(of: $0.id).hashValue)
                   return hasher.finalize()
               },
               proxy: model.proxyOn ? model.proxy.map { ProxyStatus($0, stats: model.proxyStats, hotspotOn: model.running, keptOut: model.blockedWithoutVPN, onlyFamily: model.vpnOnlyFamily).look.hashKey } : nil)
    }

    /// Sharing, devices kept out or not: turning off the hotspot stops it either way.
    private var sharing: Bool {
        switch model.homeStatus {
        case .sharing, .keptOut: true
        default: false
        }
    }

    /// A sheet or the intro covers Home, so its chart needn't move.
    private var covered: Bool { showSettings || addingDevice || model.showsLocalNetworkIntro }

    var body: some View {
        NavigationStack {
            List {
                // TETHER and the Settings button, outside any card.
                Section {
                    HStack {
                        Text("Tether")
                            .monoCaps()
                            // As written, whatever the capitals on screen do to the label.
                            .accessibilityLabel("Tether")
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button { showSettings = true } label: {
                            Image(systemName: "ellipsis")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .frame(width: settingsSize, height: settingsSize)
                                .contentShape(.rect)
                        }
                        // Plain, or a tap anywhere in the row opens Settings.
                        .buttonStyle(.plain)
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settings.open")
                    }
                    // In the same section, so no section gap opens between TETHER and the title.
                    StatusCard(model: model, covered: covered) { showSettings = true }
                }
                .paperRow()
                .listRowInsets(.vertical, 0)

                // The status card says what keeps the devices out. The rest is here, in one order.
                HomeNotesSection(model: model)

                if !model.wireGuardPeers.isEmpty || model.proxyOn || !model.notUsingTether.isEmpty {
                    Section {
                        ForEach(model.wireGuardPeers) { peer in
                            let status = DeviceStatus(peer, connected: model.wireGuardConnected, keptOut: model.blockedWithoutVPN, onlyFamily: model.vpnOnlyFamily)
                            NavigationLink { DeviceView(model: model, peer: peer) } label: {
                                HomeDeviceRow(name: peer.name, status: status,
                                              state: status.label(now: model.clockNow, standing: model.limitStanding(of: peer.id)),
                                              used: Format.used(model.usage(of: peer.id).thisMonth.total, model.usagePeriod, limit: peer.limit),
                                              newConfig: model.newConfig(peer))
                            }
                            .navigationLinkIndicatorVisibility(.hidden)
                            .accessibilityIdentifier("device.\(peer.name)")
                        }
                        if model.proxyOn, let proxy = model.proxy {
                            proxyRow(proxy)
                        }
                        // Opens Add a device, to set that device up (#109).
                        if !model.notUsingTether.isEmpty {
                            Button { addingDevice = true } label: {
                                // Underlined, like the app's other links, since it opens a sheet.
                                Text(Format.notUsingTether(model.notUsingTether))
                                    .font(.subheadline)
                                    .underline()
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(Theme.ink)
                            }
                            .accessibilityHint("Opens Add a device")
                            .accessibilityIdentifier("devices.notUsingTether")
                        }
                    } header: {
                        Text("Devices")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .textCase(nil)
                    }
                    .paperRow()
                }

                AddDeviceSection(model: model, first: model.wireGuardPeers.isEmpty && !model.proxyOn) { addingDevice = true }
                    .paperRow()

                // At the foot of the screen, like the board: turning the hotspot off is the switch. Kept
                // out is sharing too. A sentence, not the board's mono capitals: it's an instruction (M11).
                if sharing {
                    Section {
                        Text(Copy.stopHint)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("status.stopHint")
                    }
                    .paperRow()
                }
            }
            .paperList()
            // TETHER near the top, like the board, not a grouped list's gap down.
            .contentMargins(.top, 4, for: .scrollContent)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: change)
            // TETHER above is the screen's name, so the bar stays hidden. It's still set, because the
            // screens pushed from here use it for their back button.
            .navigationTitle("Tether")
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { SettingsView(model: model) }
            .sheet(isPresented: $addingDevice) { AddDeviceSheet(model: model) }
            // Only its Continue closes it, see `LocalNetworkIntro`.
            .fullScreenCover(isPresented: .constant(model.showsLocalNetworkIntro)) { LocalNetworkIntroView(model: model) }
            // Some demos open on a sheet, for the screenshots and the tests.
            .onAppear {
                if model.opensSettings { showSettings = true }
                if model.opensAddDevice { addingDevice = true }
            }
        }
    }

}

extension MainView {
    /// The proxy's row under the devices (#78), once it's on: like a device's, with how many
    /// connections are open in place of Connected.
    private func proxyRow(_ proxy: WireGuardSetup.Proxy) -> some View {
        let status = ProxyStatus(proxy, stats: model.proxyStats, hotspotOn: model.running, keptOut: model.blockedWithoutVPN, onlyFamily: model.vpnOnlyFamily)
        return NavigationLink { ProxyView(model: model) } label: {
            HomeDeviceRow(name: ProxyStatus.name, status: status.look, state: status.label(now: model.clockNow),
                          used: Format.used(model.usage(of: proxy.id).thisMonth.total, model.usagePeriod, limit: proxy.limit))
        }
        .navigationLinkIndicatorVisibility(.hidden)
        .accessibilityIdentifier("proxy.row")
    }
}

private extension DeviceStatus {
    /// Which state, without a pause's end: a new end isn't a change the list animates.
    var hashKey: Int {
        switch self {
        case .connected: 0
        case .notConnected: 1
        case .paused: 2
        case .keptOut: 3
        }
    }
}

/// A device on Home, like the board: a dash and the name, what it used on the right, and its state
/// in words under it, after the live dot when it's connected. One that isn't connected is drawn in
/// the secondary colour. Where the two don't fit on one line, as "3.12 GB of 10 GB this month" with a
/// long name, and always at the accessibility text sizes, the use goes under the name, or the name
/// would break inside words.
struct HomeDeviceRow: View {
    let name: String
    let status: DeviceStatus
    /// The state in words, like Connected or Paused until 18:00.
    let state: String
    let used: String
    var newConfig: HotspotSession.NewConfig? = nil
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if textSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        nameText.lineLimit(1)
                        Spacer(minLength: 8)
                        usedText.lineLimit(1)
                    }
                    stacked
                }
            }
            HStack(spacing: 6) {
                if status == .connected {
                    Circle().fill(Theme.live).frame(width: 6, height: 6).accessibilityHidden(true)
                }
                Text(state)
            }
            .font(.subheadline)
            .foregroundStyle(Theme.secondary)
            if let newConfig { OldAddressLabel(reason: newConfig).font(.footnote) }
        }
        .frame(minHeight: 44)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 4) {
            nameText
            usedText
        }
    }

    private var nameText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("– ").foregroundStyle(Theme.secondary).accessibilityHidden(true)
            Text(name).foregroundStyle(status == .connected ? Theme.ink : Theme.secondary)
        }
    }

    private var usedText: some View {
        Text(used)
            .font(.subheadline)
            .foregroundStyle(Theme.secondary)
    }
}

/// Waiting for the hotspot's network doesn't distinguish off from on with no device joined.
/// On Home it also says Tether sleeps once it's left waiting (H2): Add a device is open while the
/// person is in Tether, so it doesn't.
struct HotspotWaitingHint: View {
    let id: String
    var sleeps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Turn on Personal Hotspot, then join it from the other device. Tether starts when the first device joins.")
                .accessibilityIdentifier("\(id).hotspotHint")
            HotspotSettingsLink()
                .accessibilityIdentifier("\(id).hotspotPath")
            // After the path, so the link stays under the sentence it's for.
            if sleeps {
                Text(HomeStatus.sleepHint)
                    .padding(.top, 8)
                    .accessibilityIdentifier("\(id).sleepHint")
            }
        }
    }
}

/// Where Personal Hotspot is turned on, as a link to Settings.
struct HotspotSettingsLink: View {
    var body: some View {
        Button(action: StatusCard.openHotspotSettings) {
            Text(Copy.hotspotPath)
                .underline()
                .multilineTextAlignment(.leading)
                .foregroundStyle(Theme.ink)
        }
        // Plain, or a tap anywhere in the card or the row opens Settings.
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings")
    }
}

/// The last 30 seconds as one ink line for download, upload as faint dots every half second, and a red dot
/// at now on the download line. No grid and no axis: PEAK under it says what the top means.
///
/// Motion: each new sample draws the lines once, at their new place (`SpeedLine.Step`). They start
/// out shifted right by one second and scaled to the old peak, so they look as before, then ease
/// into place in 0.3 s and hold still until the next sample. Only that offset and scale animate, so
/// a frame of the move redraws no path. Under Reduce Motion or in Low Power Mode the line steps once
/// a second instead.
struct SpeedHistoryGraph: View {
    @ObservedObject var history: SpeedHistory
    /// A sheet covers Home: the line steps instead of moving, as nobody sees it.
    var covered = false
    /// Off while another screen is pushed over Home.
    @State private var onScreen = false
    private var samples: [SpeedSample] { history.samples }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize
    /// Grows a little with the text, capped, so the line keeps its shape at the largest sizes.
    @ScaledMetric(relativeTo: .caption) private var scaledHeight: CGFloat = 104
    private var height: CGFloat { min(scaledHeight, 160) }

    /// What's drawn: the samples and their scale.
    @State private var frame = SpeedLine.Frame()
    /// Where the current move starts, see `SpeedLine.Step`.
    @State private var start = Move()
    /// One more per move: each change plays the move once.
    @State private var moves = 0

    struct Move {
        var slide: CGFloat = 0
        var stretch: CGFloat = 1
        var dotRise: CGFloat = 0
    }

    static let ease: TimeInterval = 0.3

    private var footer: AnyLayout {
        textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
    }

    private var moving: Bool { Self.motionAllowed(reduceMotion: reduceMotion) && onScreen && !covered }

    /// Whether the speeds move between samples: not under Reduce Motion, nor in Low Power Mode,
    /// read at each sample, so turning it on stops the motion at the next second.
    static func motionAllowed(reduceMotion: Bool) -> Bool {
        !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        VStack(spacing: 14) {
            GeometryReader { geometry in
                plot(geometry.size)
            }
            .frame(height: height)
            // Side by side, or one under the other at the accessibility sizes, where the peak would break.
            footer {
                Text("Peak \(Format.speed(SpeedLine.peak(samples)))")
                    .contentTransition(.numericText())
                    .animation(moving ? .easeOut(duration: Self.ease) : nil, value: SpeedLine.peak(samples))
                if !textSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text("30 s")
            }
            .monoCaps()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed history, last 30 seconds")
        .accessibilityValue(samples.isEmpty ? "Waiting for traffic samples" :
            "Peak download \(Format.speed(samples.map(\.down).max() ?? 0)), peak upload \(Format.speed(samples.map(\.up).max() ?? 0))")
        .accessibilityIdentifier("traffic.history")
        .onAppear {
            onScreen = true
            frame = SpeedLine.Step(from: nil, to: samples).frame
        }
        .onDisappear { onScreen = false }
        .onChange(of: samples) { _, new in advance(to: new) }
    }

    private func advance(to samples: [SpeedSample]) {
        let step = SpeedLine.Step(from: frame, to: samples)
        frame = step.frame
        guard moving, step.slide > 0 || step.stretch != 1 || step.dotRise != 0 else { return }
        start = Move(slide: step.slide, stretch: step.stretch, dotRise: step.dotRise)
        moves &+= 1
    }

    private func plot(_ size: CGSize) -> some View {
        let down = SpeedLine.points(frame.shown, \.down, top: frame.top, size: size)
        let up = SpeedLine.dots(frame.shown, \.up, top: frame.top, size: size)
        let start = start
        return ZStack(alignment: .topLeading) {
            ZStack {
                Path { path in
                    for dot in up { path.addEllipse(in: CGRect(x: dot.x - 0.8, y: dot.y - 0.8, width: 1.6, height: 1.6)) }
                }
                .fill(Theme.secondary)
                Path(SpeedLine.path(through: down))
                    .stroke(Theme.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            .keyframeAnimator(initialValue: Move(), trigger: moves) { content, move in
                content
                    .scaleEffect(x: 1, y: move.stretch, anchor: .bottom)
                    .offset(x: move.slide * size.width)
            } keyframes: { _ in
                KeyframeTrack(\.slide) {
                    MoveKeyframe(start.slide)
                    LinearKeyframe(0, duration: Self.ease, timingCurve: .easeOut)
                }
                KeyframeTrack(\.stretch) {
                    MoveKeyframe(start.stretch)
                    LinearKeyframe(1, duration: Self.ease, timingCurve: .easeOut)
                }
            }
            .frame(width: size.width, height: size.height)
            // Cut at the left and right edges, with room for the stroke at the bottom.
            .mask(Rectangle().padding(.vertical, -2))
            // Outside the cut and the scale, so it stays round at the right edge, easing up or down.
            if let now = down.last {
                LiveDot()
                    .keyframeAnimator(initialValue: CGFloat(0), trigger: moves) { content, rise in
                        content.offset(y: -rise * size.height)
                    } keyframes: { _ in
                        MoveKeyframe(start.dotRise)
                        LinearKeyframe(0, duration: Self.ease, timingCurve: .easeOut)
                    }
                    .position(now)
            }
        }
    }
}

/// The red dot at now: a solid dot in a faint ring.
private struct LiveDot: View {
    var body: some View {
        ZStack {
            Circle().fill(Theme.live.opacity(0.16)).frame(width: 18, height: 18)
            Circle().fill(Theme.live).frame(width: 8, height: 8)
        }
    }
}

/// How fast data moves right now, down in ink and up in the secondary colour, the numbers rolling
/// to each new value. At the accessibility text sizes the two don't fit side by side, and each
/// would break over three lines, so they stack (#176).
struct SpeedRow: View {
    let down: Double
    let up: Double
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layout: AnyLayout {
        textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    var body: some View {
        layout {
            speed("arrow.down", down)
                .foregroundStyle(Theme.ink)
                .accessibilityLabel("Download \(Format.speed(down))")
                .accessibilityIdentifier("traffic.download")
            speed("arrow.up", up)
                .foregroundStyle(Theme.secondary)
                .accessibilityLabel("Upload \(Format.speed(up))")
                .accessibilityIdentifier("traffic.upload")
        }
        .animation(SpeedHistoryGraph.motionAllowed(reduceMotion: reduceMotion) ? .snappy(duration: 0.3) : nil, value: [down, up])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("traffic.speeds")
    }

    /// "↓ 3.2" big, with "Mbit/s" small and secondary after it.
    private func speed(_ symbol: String, _ bps: Double) -> some View {
        let text = Format.speed(bps)
        let space = text.lastIndex(of: " ") ?? text.endIndex
        let number = String(text[..<space]), unit = String(text[space...])
        return Text("\(Text(Image(systemName: symbol)).font(.title2)) \(number)\(Text(unit).font(.subheadline.weight(.regular)).foregroundStyle(Theme.secondary))")
            .font(.title.weight(.medium).monospacedDigit())
            .contentTransition(.numericText(value: bps))
            // One line each, the unit too: at the largest text sizes "400 kbit/s" would break.
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: textSize.isAccessibilitySize ? nil : .infinity, alignment: .leading)
    }
}

/// The one-second answer at the top of Home: a big light title saying whether this phone shares,
/// with the live dot while it does, who uses it, and under that the speeds while sharing, or what's
/// wrong and what to do (`HomeStatus`). Turning off Personal Hotspot is how sharing stops, so
/// there's no switch.
struct StatusCard: View {
    @ObservedObject var model: Model
    /// A sheet covers Home, see `SpeedHistoryGraph.covered`.
    var covered = false
    /// Opens Tether's Settings sheet, the way to Only share through a VPN while it keeps the devices out.
    var openSettings: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The board's 52 points, growing with the text and capped so a long title still fits a few lines.
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 52

    private var status: HomeStatus { model.homeStatus }

    /// Opens Settings at its main screen, where Personal Hotspot is near the top. Nothing goes
    /// straight to the Personal Hotspot page any more: on iOS 27, App-prefs:INTERNET_TETHERING and
    /// every App-prefs spelling of it open Settings > Apps, and iOS refuses prefs:root= links from apps.
    static func openHotspotSettings() {
        UIApplication.shared.open(URL(string: "App-prefs:")!)
    }

    /// The line under the title: who uses Tether while sharing, the state's own line otherwise.
    private var headline: String? {
        guard status == .sharing else { return status.line }
        let proxy = model.proxy.map { ProxyStatus($0, stats: model.proxyStats, hotspotOn: model.running, keptOut: model.blockedWithoutVPN, onlyFamily: model.vpnOnlyFamily).inUse } ?? false
        return UsingTether.headline(devices: model.wireGuardConnected.count, proxy: proxy,
                                    paused: model.wireGuardPeers.filter { $0.paused != nil }.count,
                                    added: !model.wireGuardPeers.isEmpty || model.proxyOn)
    }

    /// A WireGuard problem's line keeps the identifier its text had under the card before (M9).
    private var headlineID: String {
        if case .problem = status { return "wireguard.problem" }
        return "status.headline"
    }

    /// Whether anything shows under the line: a problem without a button has only its two lines.
    private var hasBody: Bool {
        if case let .problem(problem) = status { return problem.action != nil }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(status.title)
                    .font(.system(size: min(titleSize, 80), weight: .light))
                    .tracking(-1)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("status.title")
                if status.live {
                    Circle()
                        .fill(Theme.live)
                        .frame(width: 10, height: 10)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            if let headline {
                Text(headline)
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .padding(.top, 10)
                    .accessibilityIdentifier(headlineID)
                    .transition(.opacity)
            }
            Group {
                switch status {
                case .localNetworkOff:
                    VStack(alignment: .leading, spacing: 12) {
                        // Its text and its button: two views, so this stack spaces them.
                        LocalNetworkWarning(id: "localNetwork")
                    }
                case .sharing:
                    VStack(alignment: .leading, spacing: 14) {
                        SpeedRow(down: model.downSpeed, up: model.upSpeed)
                        SpeedHistoryGraph(history: model.speedHistory, covered: covered)
                    }
                    .liveCard()
                case .keptOut:
                    keptOut
                case .waiting:
                    HotspotWaitingHint(id: "status", sleeps: true)
                        .font(.callout)
                        .foregroundStyle(Theme.ink)
                case let .problem(problem):
                    if let action = problem.action {
                        WireGuardProblemAction(model: model, action: action)
                    }
                }
            }
            .padding(.top, hasBody ? 28 : 0)
            .transition(.opacity)
        }
        .padding(.top, 36)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: headline)
    }

    /// Only share through a VPN keeps every device out (H1): what to do, and the way to the switch.
    /// No button that turns the rule off here: one wrong tap would send traffic outside the VPN.
    private var keptOut: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status.body ?? "")
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("vpn.blocked")
            Button(action: openSettings) {
                Text(Copy.openTetherSettings)
                    .underline()
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
            }
            // Plain, or a tap anywhere in the card opens Settings.
            .buttonStyle(.plain)
            .accessibilityHint("Opens Tether's Settings")
            .accessibilityIdentifier("status.openSettings")
        }
        .font(.callout)
        .foregroundStyle(Theme.ink)
    }
}

#Preview("Main screen") {
    MainView()
}
