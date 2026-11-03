import SwiftUI

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

                if !model.wireGuardPeers.isEmpty {
                    Section("Devices") {
                        ForEach(model.wireGuardPeers) { peer in
                            NavigationLink { DeviceView(model: model, peer: peer) } label: {
                                // A plain row: LabeledContent with a Label on its right grows several
                                // rows tall inside a NavigationLink on iOS 27.
                                VStack(alignment: .leading, spacing: 4) {
                                    deviceRow {
                                        Text(peer.name)
                                        if !textSize.isAccessibilitySize { Spacer() }
                                        ConnectedLabel(connected: model.wireGuardConnected.contains(peer.address))
                                            .font(.subheadline)
                                    }
                                    if model.needsNewConfig(peer) { OldAddressLabel().font(.footnote) }
                                }
                            }
                            .accessibilityIdentifier("device.\(peer.name)")
                        }
                    }
                }

                AddDeviceSection(model: model, first: model.wireGuardPeers.isEmpty) { addingDevice = true }
            }
            // The title above draws it big, so the bar stays hidden. It's still set, because the
            // screens pushed from here use it for their back button.
            .navigationTitle("Tether")
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { SettingsView(model: model) }
            .sheet(isPresented: $addingDevice) { AddDeviceSheet(model: model) }
            // Some demos open on a sheet, for the screenshots and the tests.
            .onAppear {
                if model.opensSettings { showSettings = true }
                if model.opensAddDevice { addingDevice = true }
            }
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

/// How fast data moves right now, down and up.
struct SpeedRow: View {
    let down: Double
    let up: Double

    var body: some View {
        HStack(spacing: 16) {
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
        blocked ? "Devices can't connect" : sharing ? "Sharing" : model.running ? "Tether can't share yet" : "Turn on Personal Hotspot"
    }

    /// The warning's text and button, darker than the system orange so they pass the contrast audit.
    static let warningText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.72, blue: 0.40, alpha: 1)
            : UIColor(red: 0.60, green: 0.29, blue: 0.0, alpha: 1)
    })
    static let warningFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 0.22)
            : UIColor(red: 1.0, green: 0.94, blue: 0.85, alpha: 1)
    })

    /// Opens Settings at its main screen, where Personal Hotspot is near the top. Nothing goes
    /// straight to the Personal Hotspot page any more: on iOS 27, App-prefs:INTERNET_TETHERING and
    /// every App-prefs spelling of it open Settings > Apps, and iOS refuses prefs:root= links from apps.
    static func openHotspotSettings() {
        UIApplication.shared.open(URL(string: "App-prefs:")!)
    }

    private var headline: String {
        switch model.wireGuardConnected.count {
        case 0: return "No device is using Tether yet"
        case 1: return "1 device connected"
        case let n: return "\(n) devices connected"
        }
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
                Text("iOS blocks Tether's answers to your devices until it's on.")
                    .font(.subheadline)
                    .accessibilityIdentifier("localNetwork.problem")
                Button {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                } label: {
                    Text("Turn on in Settings")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(Self.warningText)
                        .background(Self.warningFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("localNetwork.open")
            } else if sharing {
                Divider()
                SpeedRow(down: model.downSpeed, up: model.upSpeed)
                hint {
                    Text("To stop, turn off Personal Hotspot.")
                        .accessibilityIdentifier("status.stopHint")
                }
            } else if !model.running {
                Divider()
                hint {
                    HotspotSettingsLink()
                        .accessibilityIdentifier("status.hotspotPath")
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

#Preview("Sharing") {
    let model = Model()
    model.running = true
    model.wireGuardConnected = ["10.7.0.2"]
    return StatusCard(model: model).padding()
}

#Preview("Hotspot on, no device") {
    let model = Model()
    model.running = true
    return StatusCard(model: model).padding()
}

#Preview("Waiting") {
    StatusCard(model: Model()).padding()
}

#Preview("Main screen") {
    MainView()
}
