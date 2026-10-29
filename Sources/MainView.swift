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

    var body: some View {
        NavigationStack {
            List {
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

                // Above the QR code, so a reason it doesn't work and the way out are both here.
                WireGuardProblemSection(model: model)

                if model.sharing {
                    Section {
                        SpeedRow(down: model.downSpeed, up: model.upSpeed)
                    }
                }

                if !model.wireGuardPeers.isEmpty {
                    Section("Devices") {
                        ForEach(model.wireGuardPeers) { peer in
                            NavigationLink { DeviceView(model: model, peer: peer) } label: {
                                // A plain row: LabeledContent with a Label on its right grows several
                                // rows tall inside a NavigationLink on iOS 27.
                                deviceRow {
                                    Text(peer.name)
                                    if !textSize.isAccessibilitySize { Spacer() }
                                    ConnectedLabel(connected: model.wireGuardConnected.contains(peer.address))
                                        .font(.subheadline)
                                }
                            }
                            .accessibilityIdentifier("device.\(peer.name)")
                        }
                    }
                }

                AddDeviceSection(model: model, first: model.wireGuardPeers.isEmpty)
            }
            // The status card says what this screen is, so the root drops the big title. It's still set,
            // because the screens pushed from here use it for their back button.
            .navigationTitle("Tether")
            .toolbar(.hidden, for: .navigationBar)
        }
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
/// Personal Hotspot is how sharing stops, so it says that instead of having a switch.
struct StatusCard: View {
    @ObservedObject var model: Model

    private var tint: Color { model.sharing ? .green : .orange }
    private var sharing: Bool { model.sharing }
    /// Grows with the text size, like the title under it.
    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 30
    @ScaledMetric(relativeTo: .title2) private var dotSize: CGFloat = 12
    @Environment(\.dynamicTypeSize) private var textSize

    /// Sharing gets the brand's two colours, softly. Waiting stays orange, the warning colour.
    private var background: some ShapeStyle {
        sharing
            ? AnyShapeStyle(LinearGradient(colors: [Direction.download.opacity(0.22), Direction.upload.opacity(0.18)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
            : AnyShapeStyle(tint.opacity(0.15))
    }

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

    /// The icon sits left of the text, so the card stays a few lines tall. At the accessibility text
    /// sizes a row would squeeze the text into a narrow column, so the icon goes above it.
    private var layout: AnyLayout {
        textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
    }

    var body: some View {
        layout {
            Image(systemName: "link")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.tint)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(tint)
                        .frame(width: dotSize, height: dotSize)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: dotSize / 6))
                        .offset(x: dotSize / 3, y: dotSize / 4)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(sharing ? "Sharing" : model.running ? "Tether can't share yet" : "Turn on Personal Hotspot")
                    .font(.title2.bold())
                    .accessibilityIdentifier("status.title")
                if sharing {
                    Text(headline)
                        .font(.headline)
                        .accessibilityIdentifier("status.headline")
                    Text("To stop, turn off Personal Hotspot.")
                        .font(.subheadline)
                        .accessibilityIdentifier("status.stopHint")
                } else if model.running {
                    // The WireGuard section under the card says why, and what to do.
                    Text("Personal Hotspot is on, but WireGuard isn't running.")
                        .font(.headline)
                        .accessibilityIdentifier("status.headline")
                } else {
                    Button(action: Self.openHotspotSettings) {
                        // The tint fails contrast on the orange card, so the text is the label colour and the underline
                        // says "tap". Color.primary, because inside a button `.primary` is the button's tint.
                        Text("Settings > Personal Hotspot > Allow Others to Join")
                            .font(.subheadline)
                            .underline()
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(Color.primary)
                    }
                    .accessibilityIdentifier("status.hotspotPath")
                    .accessibilityHint("Opens Settings")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.smooth, value: sharing)
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
