import CoreImage.CIFilterBuiltins
import SwiftUI

/// The QR code for the next device, always on the main screen, with buttons to share it as a file
/// and to give the address of the page that hands out the same config. It's the ready device's
/// config: the first time something connects with it or downloads it, that device is listed and a
/// new code takes its place. When the next code couldn't be saved, it says so instead. The page runs
/// once a device is on the hotspot, and its address never changes, so Browser is there before that.
/// Except on a carrier that gives the iPhone IPv6 only: there the address comes with the hotspot's
/// first device, so the code and both buttons wait for one, see `HotspotSession.deviceHost`.
struct AddDeviceSection: View {
    @ObservedObject var model: Model
    let first: Bool
    /// The page's address, while the alert that gives it is up.
    @State private var pageAddress: String?

    var body: some View {
        if let ready = model.wireGuardReady {
            let config = model.wireGuardConfig(for: ready)
            Section {
                if let config, let host = model.deviceHost {
                    let code = ReadyCode.for(config)
                    qrAndButtons(qr: code.qr, file: code.file, host: host)
                } else {
                    Label("Join this iPhone's hotspot on the device first. The code shows up here once it's on.", systemImage: "personalhotspot")
                        .accessibilityIdentifier("add.joinFirst")
                }
            } header: {
                header
            } footer: {
                if config != nil {
                    Text("Scan it with WireGuard: + > Create from QR code.")
                        .accessibilityIdentifier("add.steps")
                }
            }
            .alert("Open in a browser", isPresented: Binding { pageAddress != nil } set: { if !$0 { pageAddress = nil } }) {
                Button("OK") {}
            } message: {
                Text("Join this iPhone's hotspot on the device, then open \(pageAddress ?? "") in its browser. Keep Tether on screen.")
            }
        } else if let problem = model.wireGuardReadyProblem {
            Section {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("add.problem")
            } header: {
                header
            }
        }
    }

    /// The QR code, with Share file and Browser under it.
    @ViewBuilder private func qrAndButtons(qr: UIImage?, file: URL?, host: String) -> some View {
        if let qr {
            Image(uiImage: qr)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityLabel("QR code for the next device")
                .accessibilityIdentifier("add.qr")
        }
        // Side by side, so the card stays short. Bordered, or the row takes one tap for both.
        HStack {
            if let file {
                ShareLink(item: file) {
                    Label("Share file", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("add.share")
            }
            Button {
                pageAddress = ConfigPage.url(host: host)
            } label: {
                Label("Browser", systemImage: "globe")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("add.page")
        }
        .buttonStyle(.bordered)
    }

    private var header: Text { Text(first ? "Add a device" : "Add another device") }
}

/// Why WireGuard isn't running, with the way out when the saved keys can't be read.
struct WireGuardProblemSection: View {
    @ObservedObject var model: Model

    var body: some View {
        if let problem = model.wireGuardProblem {
            Section {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("wireguard.problem")
                if model.wireGuardNeedsReset {
                    Button("Start over with new keys", role: .destructive) { model.resetWireGuard() }
                        .accessibilityIdentifier("wireguard.reset")
                }
            } header: {
                Text("WireGuard isn't running")
            }
        }
    }
}

/// One device: whether it's connected, and removing it. Tapping the title renames it. A rename or
/// removal that couldn't be saved says so at the top.
struct DeviceView: View {
    @ObservedObject var model: Model
    let peer: WireGuardSetup.Peer
    @State private var confirmRemove = false
    @Environment(\.dismiss) private var dismiss

    /// The saved device, so a new name shows at once.
    private var current: WireGuardSetup.Peer { model.wireGuardPeers.first { $0.id == peer.id } ?? peer }
    private var connected: Bool { model.wireGuardConnected.contains(peer.address) }
    /// A rename or removal of this device that couldn't be saved.
    private var problem: String? { model.wireGuardDeviceProblem.flatMap { $0.device == peer.id ? $0.text : nil } }

    var body: some View {
        List {
            // On top, where a rename is made, and the screen a failed removal stays on.
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("device.problem")
                }
            }
            Section {
                ConnectedLabel(connected: connected)
                    .accessibilityIdentifier("device.status")
            }
            Section {
                Button("Remove device", role: .destructive) { confirmRemove = true }
                    .accessibilityIdentifier("device.remove")
            } footer: {
                Text("It can't connect any more. Delete its tunnel in its WireGuard app too.")
            }
        }
        .navigationTitle(Binding(get: { current.name }, set: { model.renameWireGuardDevice(peer.id, to: $0) }))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .confirmationDialog("Remove \(current.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                // A removal that couldn't be saved stays here, and the screen says so.
                if model.removeWireGuardDevice(peer.id) { dismiss() }
            }
        }
    }
}

/// "Connected" or "Not connected". The text keeps the normal colours, since green text on the
/// grouped background fails the contrast audit. The icon carries the green.
struct ConnectedLabel: View {
    let connected: Bool

    var body: some View {
        Label {
            Text(connected ? "Connected" : "Not connected")
                .foregroundStyle(connected ? .primary : .secondary)
        } icon: {
            Image(systemName: connected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(connected ? .green : .secondary)
        }
    }
}

/// The ready device's QR code and file, made once for each config: a new ready device, or a new
/// hotspot address. The main screen redraws every second with the speeds, and making them on each
/// redraw cost a CIContext and a file write every second.
@MainActor
enum ReadyCode {
    private static var made: (text: String, qr: UIImage?, file: URL?)?

    static func `for`(_ text: String) -> (qr: UIImage?, file: URL?) {
        // The system may clear the temporary directory, so a missing file is written again.
        if let made, made.text == text, made.file.map({ FileManager.default.fileExists(atPath: $0.path) }) ?? false {
            return (made.qr, made.file)
        }
        let code = (text: text, qr: QRCode.image(text), file: ConfigFile.write(text, named: "Tether"))
        made = code
        return (code.qr, code.file)
    }
}

/// The config as a .conf file to share. WireGuard names the tunnel after the file. It holds a
/// private key, so it lives in the temporary directory.
enum ConfigFile {
    static func write(_ config: String, named name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(WireGuardSetup.fileName(for: name))
        return (try? config.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
    }
}

enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
