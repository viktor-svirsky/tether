import CoreImage.CIFilterBuiltins
import SwiftUI

/// Adding one device, in three steps that tick off by themselves: join the hotspot, get the config,
/// turn the tunnel on. It follows the code that was ready when it opened, see `AddDeviceProgress`.
/// The page and the connected list keep up only while Tether is on screen, so in the background the
/// steps wait, and they catch up when it's back.
struct AddDeviceSheet: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    /// The device behind the code. Until it's claimed, a new code (after starting over, say) takes its place.
    @State private var readyID: WireGuardSetup.Peer.ID?

    init(model: Model) {
        self.model = model
        _readyID = State(initialValue: model.addDeviceFollows ?? model.wireGuardReady?.id)
    }

    private var progress: AddDeviceProgress {
        AddDeviceProgress(ready: readyID, peers: model.wireGuardPeers, connected: model.wireGuardConnected, hotspotOn: model.running)
    }

    var body: some View {
        let progress = progress
        NavigationStack {
            List {
                Section {
                    StepRow(number: 1, title: "Join this iPhone's hotspot on the device", step: progress.joined, id: "add.step1") {
                        if progress.joined == .done {
                            Text("The hotspot is on.")
                        } else {
                            HotspotSettingsLink()
                                .accessibilityIdentifier("add.hotspotPath")
                        }
                    }
                    StepRow(number: 2, title: "Get the config", step: progress.config, id: "add.step2") {
                        config(progress)
                    }
                    StepRow(number: 3, title: "Turn the tunnel on in WireGuard", step: progress.tunnel, id: "add.step3") {
                        if let device = progress.device {
                            Text(progress.finished ? "\(device.name) is connected. Rename it in the list." : "Waiting for \(device.name) to connect.")
                                .accessibilityIdentifier("add.result")
                        }
                    }
                }
                if progress.finished {
                    Section {
                        Button { dismiss() } label: {
                            Text("Done").font(.headline).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("add.done")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .navigationTitle("Add a device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The same close button as Settings.
                ToolbarItem(placement: .topBarTrailing) {
                    if #available(iOS 26, *) {
                        Button(role: .close) { dismiss() }
                            .accessibilityIdentifier("add.close")
                    } else {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("add.close")
                    }
                }
            }
            .onChange(of: model.wireGuardReady?.id) { _, new in
                if self.progress.device == nil { readyID = new }
            }
        }
    }

    /// The code and the two ways for a laptop, until the device is listed. The browser needs the
    /// hotspot, and on a carrier with IPv6 only the code does too, see `HotspotSession.deviceHost`.
    @ViewBuilder private func config(_ progress: AddDeviceProgress) -> some View {
        if let device = progress.device {
            Text("\(device.name) has its config.")
        } else if let ready = model.wireGuardReady, let config = model.wireGuardConfig(for: ready), let host = model.deviceHost {
            let code = ReadyCode.for(config)
            if let qr = code.qr {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("QR code for the next device")
                    .accessibilityIdentifier("add.qr")
            }
            Text("iPhone or iPad: in WireGuard, tap + > Create from QR code. This ticks off once its tunnel is on.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("add.scan")
            Text("Mac, Windows or Linux: share the file, or open \(ConfigPage.url(host: host)) in its browser while Tether is on screen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("add.laptop")
            if let file = code.file {
                ShareLink(item: file) {
                    Label("Share file", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("add.share")
            }
        } else if model.wireGuardReady != nil {
            Text("It shows up here once the device is on the hotspot.")
                .accessibilityIdentifier("add.joinFirst")
        }
    }
}

/// One step: its mark, the title, and what to do. The mark is the number while it's to do, a
/// spinner while it waits for the device, and a tick when it's done.
private struct StepRow<Content: View>: View {
    let number: Int
    let title: String
    let step: AddDeviceProgress.Step
    let id: String
    @ViewBuilder let content: Content
    @ScaledMetric(relativeTo: .title2) private var markSize: CGFloat = 30

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            mark
                .frame(width: markSize, height: markSize)
                .accessibilityIdentifier("\(id).mark")
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(id)
                content
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var mark: some View {
        switch step {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green) // the same tick as Connected
                .accessibilityLabel("Done")
        case .waiting:
            ProgressView()
                .accessibilityLabel("Waiting")
        case .toDo:
            Image(systemName: "\(number).circle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Step \(number) of 3")
        }
    }
}

/// The ready device's QR code and file, made once for each config: a new ready device, or a new
/// hotspot address. The sheet redraws every second with the speeds the model publishes, and making
/// them on each redraw cost a CIContext and a file write every second.
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
