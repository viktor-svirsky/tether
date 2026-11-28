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
    private struct Change: Hashable {
        let phase: StatusCard.Phase
        let warnings: [Bool]
        let devices: [Int]
        let proxy: Int?
    }

    private var change: Change {
        Change(phase: StatusCard.Phase(model),
               warnings: [model.expiryWarning != nil, model.wireGuardProblem != nil, model.blockedWithoutVPN,
                          model.sharing && model.belowBatteryStop != nil, model.staleConfigShown,
                          model.notUsingTether.isEmpty, model.wireGuardReady != nil],
               devices: model.wireGuardPeers.map {
                   var hasher = Hasher()
                   hasher.combine($0.id)
                   hasher.combine(DeviceStatus($0, connected: model.wireGuardConnected).hashKey)
                   return hasher.finalize()
               },
               proxy: model.proxyOn ? model.proxy.map { ProxyStatus($0, stats: model.proxyStats, hotspotOn: model.running).look.hashKey } : nil)
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
                    StatusCard(model: model, covered: covered)
                }
                .paperRow()
                .listRowInsets(.vertical, 0)

                if let warning = model.expiryWarning {
                    warningSection(warning, icon: "exclamationmark.triangle.fill", id: "app.expiry")
                }

                // Above Add a device, so a reason it doesn't work and the way out are both here.
                WireGuardProblemSection(model: model)
                    .paperRow()

                if model.blockedWithoutVPN {
                    warningSection(VPNText.blocked(onlyFamily: model.vpnOnlyFamily), icon: "lock.shield", id: "vpn.blocked")
                }

                if model.sharing, let below = model.belowBatteryStop {
                    warningSection(below.text, icon: "battery.25percent", id: "battery.low")
                }

                if model.staleConfigShown {
                    warningSection("A device is trying to connect with a config that no longer works. Delete its tunnel in WireGuard and add it again.",
                                   icon: "exclamationmark.triangle.fill", id: "stale.warning")
                }

                if !model.wireGuardPeers.isEmpty || model.proxyOn || !model.notUsingTether.isEmpty {
                    Section {
                        ForEach(model.wireGuardPeers) { peer in
                            let status = DeviceStatus(peer, connected: model.wireGuardConnected)
                            NavigationLink { DeviceView(model: model, peer: peer) } label: {
                                HomeDeviceRow(name: peer.name, status: status, state: status.label(now: model.clockNow),
                                              used: Format.used(model.usage(of: peer.id).thisMonth.total, model.usagePeriod),
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

                // At the foot of the screen, like the board: turning the hotspot off is the switch.
                if StatusCard.Phase(model) == .sharing {
                    Section {
                        Text("To stop, turn off Personal Hotspot.")
                            .monoCaps()
                            .accessibilityLabel("To stop, turn off Personal Hotspot.")
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

    /// A problem on its own row, in ink, with the warning mark in the danger colour.
    private func warningSection(_ text: String, icon: String, id: String) -> some View {
        Section {
            Label {
                Text(text).foregroundStyle(Theme.ink)
            } icon: {
                Image(systemName: icon).foregroundStyle(Theme.danger)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(id)
        }
        .paperRow()
    }
}

extension MainView {
    /// The proxy's row under the devices (#78), once it's on: like a device's, with how many
    /// connections are open in place of Connected.
    private func proxyRow(_ proxy: WireGuardSetup.Proxy) -> some View {
        let status = ProxyStatus(proxy, stats: model.proxyStats, hotspotOn: model.running)
        return NavigationLink { ProxyView(model: model) } label: {
            HomeDeviceRow(name: ProxyStatus.name, status: status.look, state: status.label(now: model.clockNow),
                          used: Format.used(model.usage(of: proxy.id).thisMonth.total, model.usagePeriod))
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
        }
    }
}

/// A device on Home, like the board: a dash and the name, what it used on the right, and its state
/// in words under it, after the live dot when it's connected. One that isn't connected is drawn in
/// the secondary colour. At the accessibility text sizes the use goes under the name, or the name
/// would break inside words.
struct HomeDeviceRow: View {
    let name: String
    let status: DeviceStatus
    /// The state in words, like Connected or Paused until 18:00.
    let state: String
    let used: String
    var newConfig: HotspotSession.NewConfig? = nil
    @Environment(\.dynamicTypeSize) private var textSize

    private var layout: AnyLayout {
        textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            layout {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("– ").foregroundStyle(Theme.secondary).accessibilityHidden(true)
                    Text(name).foregroundStyle(status == .connected ? Theme.ink : Theme.secondary)
                }
                if !textSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text(used)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
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
}

/// Waiting for the hotspot's network doesn't distinguish off from on with no device joined.
struct HotspotWaitingHint: View {
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Turn on Personal Hotspot, then join it from the other device. Tether starts when the first device joins.")
                .accessibilityIdentifier("\(id).hotspotHint")
            HotspotSettingsLink()
                .accessibilityIdentifier("\(id).hotspotPath")
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
/// with the live dot while it does, who uses it, and under that the speeds while sharing, or what to
/// do. Turning off Personal Hotspot is how sharing stops, so there's no switch.
struct StatusCard: View {
    @ObservedObject var model: Model
    /// A sheet covers Home, see `SpeedHistoryGraph.covered`.
    var covered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The board's 52 points, growing with the text and capped so a long title still fits a few lines.
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 52

    /// What the card shows. Local Network off comes first, hotspot or not: nothing works until it's on.
    enum Phase: Hashable {
        case blocked, sharing, cantShare, waiting

        @MainActor init(_ model: Model) {
            self = model.localNetworkDenied ? .blocked : model.sharing ? .sharing : model.running ? .cantShare : .waiting
        }
    }

    private var phase: Phase { Phase(model) }

    private var title: String {
        switch phase {
        case .blocked: "Devices can't connect"
        case .sharing: "Sharing"
        case .cantShare: "Tether can't share yet"
        case .waiting: Copy.waitingForDevice
        }
    }

    /// Opens Settings at its main screen, where Personal Hotspot is near the top. Nothing goes
    /// straight to the Personal Hotspot page any more: on iOS 27, App-prefs:INTERNET_TETHERING and
    /// every App-prefs spelling of it open Settings > Apps, and iOS refuses prefs:root= links from apps.
    static func openHotspotSettings() {
        UIApplication.shared.open(URL(string: "App-prefs:")!)
    }

    private var headline: String? {
        switch phase {
        case .blocked: return "Local Network is off for Tether"
        case .sharing:
            let proxy = model.proxy.map { ProxyStatus($0, stats: model.proxyStats, hotspotOn: model.running).inUse } ?? false
            return UsingTether.headline(devices: model.wireGuardConnected.count, proxy: proxy)
        // The WireGuard section under it says why, and what to do.
        case .cantShare: return "Personal Hotspot is on, but WireGuard isn't running."
        case .waiting: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.system(size: min(titleSize, 80), weight: .light))
                    .tracking(-1)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("status.title")
                if phase == .sharing {
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
                    .accessibilityIdentifier("status.headline")
                    .transition(.opacity)
            }
            Group {
                switch phase {
                case .blocked:
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
                case .waiting:
                    HotspotWaitingHint(id: "status")
                        .font(.callout)
                        .foregroundStyle(Theme.ink)
                case .cantShare:
                    EmptyView()
                }
            }
            .padding(.top, phase == .cantShare ? 0 : 28)
            .transition(.opacity)
        }
        .padding(.top, 36)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: headline)
    }
}

#Preview("Main screen") {
    MainView()
}
