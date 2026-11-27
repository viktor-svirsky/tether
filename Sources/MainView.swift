import SwiftUI
import Charts

struct MainView: View {
    @ObservedObject private var model = Model.shared
    @Environment(\.dynamicTypeSize) private var textSize

    /// A device's name and state side by side. At the accessibility text sizes they'd break words
    /// ("Connect-ed"), so the state goes under the name.
    private var deviceRow: AnyLayout {
        textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout())
    }

    @State private var showSettings = false
    @State private var addingDevice = false
    /// The gear's circle grows with the text size, so the symbol stays inside it.
    @ScaledMetric(relativeTo: .title3) private var gearSize: CGFloat = 44

    var body: some View {
        NavigationStack {
            List {
                // The big title and the gear, outside any card, like the system's own large titles.
                Section {
                    HStack {
                        Text("Tether")
                            .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.primary)
                                .frame(width: gearSize, height: gearSize)
                                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                        }
                        // Plain, or a tap anywhere in the row (the title too) opens Settings.
                        .buttonStyle(.plain)
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settings.open")
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section {
                    StatusCard(model: model)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if let warning = model.expiryWarning {
                    Section {
                        Label {
                            Text(warning)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("app.expiry")
                    }
                }

                // Above Add a device, so a reason it doesn't work and the way out are both here.
                WireGuardProblemSection(model: model)

                if model.blockedWithoutVPN {
                    Section {
                        Label {
                            Text("No VPN is on, so no device gets through until one is. Turn your VPN on, or turn off Only share through a VPN in Settings.")
                        } icon: {
                            Image(systemName: "lock.shield").foregroundStyle(.orange)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("vpn.blocked")
                    }
                }

                if model.staleConfigShown {
                    Section {
                        Label {
                            Text("A device is trying to connect with a config that no longer works. Delete its tunnel in WireGuard and add it again.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("stale.warning")
                    }
                }

                if !model.wireGuardPeers.isEmpty || model.proxyOn || !model.notUsingTether.isEmpty {
                    Section("Devices") {
                        ForEach(model.wireGuardPeers) { peer in
                            NavigationLink { DeviceView(model: model, peer: peer) } label: {
                                // A plain row: LabeledContent with a Label on its right grows several
                                // rows tall inside a NavigationLink on iOS 27.
                                VStack(alignment: .leading, spacing: 4) {
                                    deviceRow {
                                        Text(peer.name)
                                        if !textSize.isAccessibilitySize { Spacer() }
                                        DeviceStatusLabel(status: DeviceStatus(peer, connected: model.wireGuardConnected))
                                            .font(.subheadline)
                                    }
                                    // The label colour: grey text on the card fails the contrast audit.
                                    Text(Format.used(model.usage(of: peer.id).thisMonth.total, model.usagePeriod))
                                        .font(.subheadline)
                                    if model.needsNewConfig(peer) { OldAddressLabel().font(.footnote) }
                                }
                            }
                            .accessibilityIdentifier("device.\(peer.name)")
                        }
                        if model.proxyOn, let proxy = model.proxy {
                            proxyRow(proxy)
                        }
                        // Opens Add a device, to set that device up (#109).
                        if !model.notUsingTether.isEmpty {
                            Button { addingDevice = true } label: {
                                Text(Format.notUsingTether(model.notUsingTether))
                                    .font(.subheadline)
                            }
                            .accessibilityHint("Opens Add a device")
                            .accessibilityIdentifier("devices.notUsingTether")
                        }
                    }
                }

                AddDeviceSection(model: model, first: model.wireGuardPeers.isEmpty && !model.proxyOn) { addingDevice = true }
            }
            // The title above draws it big, so the bar stays hidden. It's still set, because the
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
        let status = ProxyStatus(proxy, stats: model.proxyStats, hotspotOn: model.running)
        return NavigationLink { ProxyView(model: model) } label: {
            VStack(alignment: .leading, spacing: 4) {
                deviceRow {
                    Text(ProxyStatus.name)
                    if !textSize.isAccessibilitySize { Spacer() }
                    DeviceStatusLabel(status: status.look, text: status.label)
                        .font(.subheadline)
                }
                Text(Format.used(model.usage(of: proxy.id).thisMonth.total, model.usagePeriod))
                    .font(.subheadline)
            }
        }
        .accessibilityIdentifier("proxy.row")
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
            Text("Settings > Personal Hotspot > Allow Others to Join")
                .underline()
                .multilineTextAlignment(.leading)
                .foregroundStyle(Color.primary)
        }
        // Plain, or a tap anywhere in the card or the row opens Settings.
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings")
    }
}

/// Recent throughput, with the newest sample at the right edge and both directions on one scale.
/// It moves without an animation: a one-second animation per sample would redraw it every frame.
struct SpeedHistoryGraph: View {
    @ObservedObject var history: SpeedHistory
    private var samples: [SpeedSample] { history.samples }
    @Environment(\.dynamicTypeSize) private var textSize
    /// Grows with the text, so the speed labels at the side don't overlap at the larger sizes. Capped,
    /// since at the accessibility sizes only one of them shows.
    @ScaledMetric(relativeTo: .caption) private var scaledHeight: CGFloat = 120
    private var height: CGFloat { min(scaledHeight, 200) }

    private var end: Date { samples.last?.at ?? Date() }
    private var peak: Double { max(1_000, samples.map { max($0.up, $0.down) }.max() ?? 0) }

    var body: some View {
        VStack(spacing: 4) {
            Chart {
                ForEach(samples) { sample in
                    LineMark(x: .value("Time", sample.at), y: .value("Download", sample.down),
                             series: .value("Direction", "Download"))
                        .foregroundStyle(Direction.download)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    LineMark(x: .value("Time", sample.at), y: .value("Upload", sample.up),
                             series: .value("Direction", "Upload"))
                        .foregroundStyle(Direction.upload)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
                if let latest = samples.last {
                    PointMark(x: .value("Time", latest.at), y: .value("Download", latest.down))
                        .foregroundStyle(Direction.download)
                        .symbolSize(16)
                    PointMark(x: .value("Time", latest.at), y: .value("Upload", latest.up))
                        .foregroundStyle(Direction.upload)
                        .symbolSize(16)
                }
            }
            .chartXScale(domain: end.addingTimeInterval(-SpeedSample.historyDuration)...end)
            .chartYScale(domain: 0...(peak * 1.15))
            .chartXAxis {
                AxisMarks(preset: .aligned, values: [end]) { _ in
                    AxisValueLabel(centered: false, anchor: .topTrailing) {
                        Text("Now").font(.caption)
                    }
                }
            }
            .chartYAxis {
                // At the accessibility sizes only the top line has a label, no bigger than at the largest
                // size below them, so it can't take over the width. The speeds above say it in full.
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    if !textSize.isAccessibilitySize || value.index == value.count - 1 {
                        AxisValueLabel {
                            if let speed = value.as(Double.self) {
                                Text(Format.speed(speed)).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            }
                        }
                    }
                }
            }
            .chartPlotStyle { plot in plot.clipped() }
            .frame(height: height)
            // Under the chart, not an axis label, so it can't run into "Now".
            Text("Last 30 seconds")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed history, last 30 seconds")
        .accessibilityValue(samples.isEmpty ? "Waiting for traffic samples" :
            "Peak download \(Format.speed(samples.map(\.down).max() ?? 0)), peak upload \(Format.speed(samples.map(\.up).max() ?? 0))")
        .accessibilityIdentifier("traffic.history")
    }
}

/// How fast data moves right now, down and up. At the accessibility text sizes the two don't fit
/// side by side, and each would break over three lines, so they stack (#176).
struct SpeedRow: View {
    let down: Double
    let up: Double
    @Environment(\.dynamicTypeSize) private var textSize

    private var layout: AnyLayout {
        textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 16))
    }

    var body: some View {
        layout {
            Text("\(Image(systemName: "arrow.down")) \(Format.speed(down))")
                .foregroundStyle(Direction.download)
            Text("\(Image(systemName: "arrow.up")) \(Format.speed(up))")
                .foregroundStyle(Direction.upload)
        }
        .font(.headline.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Download \(Format.speed(down)), upload \(Format.speed(up))")
        .accessibilityIdentifier("traffic.speeds")
    }
}

extension Color {
    /// A filled button's blue, under white text. The accent is light in dark mode, for text and links
    /// on black, and white on it fails the contrast audit, so a filled button keeps a darker blue.
    static let filledButton = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.0, green: 0.40, blue: 0.82, alpha: 1)
            : UIColor(red: 0.0, green: 0.45, blue: 0.78, alpha: 1)
    })
}

/// Download and upload colours, the same in every speed and card. Orange and red stay for warnings.
enum Direction {
    static let download = Color.accentColor
    /// Darker than the system teal in light mode and lighter in dark mode, so the upload speed
    /// keeps a 4.5:1 contrast on the card in both.
    static let upload = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.35, green: 0.85, blue: 0.80, alpha: 1)
            : UIColor(red: 0.0, green: 0.47, blue: 0.48, alpha: 1)
    })
}

/// The one-second answer: is this phone sharing right now, and is anyone using it. Turning off
/// Personal Hotspot is how sharing stops, so it says that instead of having a switch. The orb is
/// the screen's one bold thing: the app icon's colours while sharing, grey while waiting, orange
/// when the hotspot is on but WireGuard isn't.
struct StatusCard: View {
    @ObservedObject var model: Model
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.colorScheme) private var colorScheme

    private var sharing: Bool { model.sharing && !blocked }
    /// Local Network is off for Tether, so its replies never reach the devices and none can connect.
    /// That comes first, hotspot or not: nothing works until it's on.
    private var blocked: Bool { model.localNetworkDenied }
    private var look: StatusOrb.Look { sharing ? .sharing : blocked || model.running ? .problem : .waiting }
    private var title: String {
        blocked ? "Devices can't connect" : sharing ? "Sharing" : model.running ? "Tether can't share yet" : "Waiting for a device on the hotspot"
    }

    /// Opens Settings at its main screen, where Personal Hotspot is near the top. Nothing goes
    /// straight to the Personal Hotspot page any more: on iOS 27, App-prefs:INTERNET_TETHERING and
    /// every App-prefs spelling of it open Settings > Apps, and iOS refuses prefs:root= links from apps.
    static func openHotspotSettings() {
        UIApplication.shared.open(URL(string: "App-prefs:")!)
    }

    private var headline: String {
        let proxy = model.proxy.map { ProxyStatus($0, stats: model.proxyStats, hotspotOn: model.running).inUse } ?? false
        return UsingTether.headline(devices: model.wireGuardConnected.count, proxy: proxy)
    }

    /// The orb sits left of the text. At the accessibility text sizes a row would squeeze the text
    /// into a narrow column, so the orb goes above it.
    private var layout: AnyLayout {
        textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 18))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            layout {
                StatusOrb(look: look)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .accessibilityIdentifier("status.title")
                    if blocked {
                        Text("Local Network is off for Tether")
                            .font(.headline)
                            .accessibilityIdentifier("status.headline")
                    } else if sharing {
                        Text(headline)
                            .font(.headline)
                            .accessibilityIdentifier("status.headline")
                    } else if model.running {
                        // The WireGuard section under the card says why, and what to do.
                        Text("Personal Hotspot is on, but WireGuard isn't running.")
                            .font(.headline)
                            .accessibilityIdentifier("status.headline")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if blocked {
                Divider()
                LocalNetworkWarning(id: "localNetwork")
            } else if sharing {
                Divider()
                SpeedRow(down: model.downSpeed, up: model.upSpeed)
                SpeedHistoryGraph(history: model.speedHistory)
                hint {
                    Text("To stop, turn off Personal Hotspot.")
                        .accessibilityIdentifier("status.stopHint")
                }
            } else if !model.running {
                Divider()
                hint {
                    HotspotWaitingHint(id: "status")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            // The only shadow on the screen, so this card reads first. Dark mode has none, like the system's
            // cards. On the shape alone: on the whole card every letter gets a grey halo, which fails contrast.
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.07), radius: 14, y: 6)
        }
    }

    /// One line under the divider, after a grey info symbol. The text keeps the label colour.
    private func hint(@ViewBuilder _ content: () -> some View) -> some View {
        Label { content() } icon: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
            .font(.subheadline)
    }
}

/// The large round sign of the state. Each look is its own layer, so a change cross-fades.
struct StatusOrb: View {
    enum Look { case sharing, waiting, problem }
    let look: Look
    /// Grows with the text size, like the title next to it.
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 84
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The app icon's gradient, sampled from its corners.
    static let iconColors = [Color(red: 0.12, green: 0.40, blue: 0.94), Color(red: 0.08, green: 0.74, blue: 0.75)]

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: Self.iconColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .opacity(look == .sharing ? 1 : 0)
            Circle().fill(Color(.systemGray5)).opacity(look == .waiting ? 1 : 0)
            Circle().fill(Color.orange.opacity(0.18)).opacity(look == .problem ? 1 : 0)
            Circle().strokeBorder(.white.opacity(look == .sharing ? 0.25 : 0), lineWidth: size * 0.06)
            Image(systemName: "link")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(look == .sharing ? AnyShapeStyle(.white) : look == .problem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: look)
        .accessibilityHidden(true)
    }
}

#Preview("Main screen") {
    MainView()
}
