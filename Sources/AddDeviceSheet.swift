import CoreImage.CIFilterBuiltins
import SwiftUI

/// Adding one device, in three steps on a line that fills with the icon's colours as each one ticks
/// off by itself: join the hotspot, give it the config, turn its tunnel on. It follows the code that
/// was ready when it opened, see `AddDeviceProgress`. The page and the connected list keep up only
/// while Tether is on screen, so in the background the steps wait, and they catch up when it's back.
/// The code works only while the sheet is on screen and for 10 minutes after, see
/// `AddWindow`, so opening it after that shows a new code.
struct AddDeviceSheet: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    /// The device behind the code. Until it's claimed, a new code (after starting over, say) takes its place.
    @State private var readyID: WireGuardSetup.Peer.ID?
    /// Which way the device gets its config: a phone or tablet scans, a computer downloads.
    @State private var kind = Kind.phone
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    enum Kind: Hashable { case phone, computer }

    init(model: Model) {
        self.model = model
        _readyID = State(initialValue: model.addDeviceFollows ?? model.wireGuardReady?.id)
        _kind = State(initialValue: model.addDeviceStartsOnComputer ? .computer : .phone)
    }

    private var progress: AddDeviceProgress {
        AddDeviceProgress(ready: readyID, peers: model.wireGuardPeers, connected: model.wireGuardConnected, hotspotOn: model.running)
    }

    var body: some View {
        let progress = progress
        let current = Self.current(progress)
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Above the steps: a device scanned first would only learn after that it can't work.
                    if model.localNetworkDenied && !progress.finished {
                        localNetworkWarning
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Self.card)
                    }
                    if progress.device == nil {
                        // Every step after this assumes WireGuard is on the other device (#169).
                        Text("Install the free WireGuard app on the other device: App Store, Google Play, or wireguard.com/install.")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("add.install")
                    }
                    VStack(spacing: 0) {
                        StepRow(number: 1, mark: mark(progress.joined, step: 1, current: current), lineDone: progress.joined == .done,
                                title: "Join this iPhone's hotspot", id: "add.step1") {
                            if progress.joined == .done {
                                note("The hotspot is on. Join it on the new device too.")
                            } else {
                                HotspotWaitingHint(id: "add")
                                    .font(.subheadline)
                            }
                        }
                        StepRow(number: 2, mark: mark(progress.config, step: 2, current: current), lineDone: progress.config == .done,
                                title: "Give it the config", id: "add.step2") {
                            config(progress)
                        }
                        StepRow(number: 3, mark: mark(progress.tunnel, step: 3, current: current), lineDone: nil,
                                title: "Turn its tunnel on", id: "add.step3") {
                            switch (progress.tunnel, progress.device) {
                            case (.done, _): note("Connected")
                            // It won't tick off by itself: the warning above says why.
                            case _ where model.localNetworkDenied: note("Waiting for Local Network to be on")
                            case _ where model.staleConfigShown:
                                Text("A device is trying to connect with a config that no longer works. If it's this one, delete its tunnel in WireGuard and give it the config again.")
                                    .font(.subheadline)
                                    .foregroundStyle(LocalNetworkWarning.text)
                                    .accessibilityIdentifier("add.stale")
                            case (.waiting, let device?): note("Waiting for \(device.name) to connect")
                            default: note("This ticks off by itself when it connects.")
                            }
                        }
                    }
                    .padding(EdgeInsets(top: 20, leading: 14, bottom: 20, trailing: 18))
                    .background(Self.card)

                    if progress.finished, let device = progress.device {
                        VStack(spacing: 14) {
                            StatusOrb(look: .sharing)
                            Text("\(device.name) is connected")
                                .font(.system(.title, design: .rounded, weight: .heavy))
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("add.result")
                            Text("It uses this iPhone's data now. Tap it in your devices to rename it.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 12)
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                if progress.finished {
                    Button { dismiss() } label: {
                        Text("Done").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.filledButton)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    // Large text scrolls the connected message under it.
                    .background(.bar)
                    .accessibilityIdentifier("add.done")
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
            // The demos that open on the sheet open the window the same way.
            .onAppear {
                model.openAddWindow()
                UIApplication.shared.isIdleTimerDisabled = self.progress.keepsScreenAwake
            }
            .onChange(of: progress.keepsScreenAwake) { _, awake in UIApplication.shared.isIdleTimerDisabled = awake }
            .onDisappear {
                model.closeAddWindow()
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    private static var card: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(.secondarySystemGroupedBackground))
    }

    /// The first step that isn't done, the one the person is on.
    static func current(_ progress: AddDeviceProgress) -> Int {
        [progress.joined, progress.config, progress.tunnel].firstIndex { $0 != .done }.map { $0 + 1 } ?? 4
    }

    private func mark(_ step: AddDeviceProgress.Step, step number: Int, current: Int) -> StepMark.Look {
        switch step {
        case .done: .done
        case .waiting: .waiting
        case .toDo: number == current ? .current : .later
        }
    }

    private var localNetworkWarning: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Local Network is off for Tether")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LocalNetworkWarning.text)
                .accessibilityIdentifier("add.localNetwork.title")
            LocalNetworkWarning(id: "add.localNetwork")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    /// The device picks how it gets the config. The browser needs the hotspot, and on a carrier
    /// with IPv6 only the code does too, see `HotspotSession.deviceHost`.
    @ViewBuilder private func config(_ progress: AddDeviceProgress) -> some View {
        if let device = progress.device {
            note("\(device.name) has it")
        } else if let ready = model.wireGuardReady, let config = model.wireGuardConfig(for: ready) {
            let code = ReadyCode.for(config)
            VStack(alignment: .leading, spacing: 14) {
                Picker("Kind of device", selection: $kind) {
                    Text("iPhone or iPad").tag(Kind.phone)
                    Text("Computer").tag(Kind.computer)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("add.kind")
                switch kind {
                case .phone: scan(code.qr)
                case .computer: download(hosts: model.pageHosts, file: code.file)
                }
            }
        } else if model.wireGuardReady != nil {
            note("It shows up here once the device is on the hotspot.")
                .accessibilityIdentifier("add.joinFirst")
        } else if let problem = model.wireGuardReadyProblem {
            // A new code for this time couldn't be saved, and the old one no longer works.
            note(problem)
                .accessibilityIdentifier("add.codeProblem")
        }
    }

    @ViewBuilder private func scan(_ qr: UIImage?) -> some View {
        if let qr {
            Image(uiImage: qr)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 200)
                // The QR standard's quiet zone, four modules or more, which a dark card doesn't give (#178).
                .padding(16)
                .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("QR code for the next device")
                .accessibilityIdentifier("add.qr")
        }
        Text("In WireGuard, tap + and Create from QR code.")
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("add.scan")
        windowNote(id: "add.codeWindow")
    }

    /// `hosts`: where the page is, see `HotspotSession.pageHosts`. On a carrier that gives the iPhone
    /// IPv6 only, 172.20.10.1 and then the iPhone's IPv6 address, the one a Mac reaches. A Mac with
    /// IPv6 off for the hotspot can't reach either (#94).
    @ViewBuilder private func download(hosts: [String], file: URL?) -> some View {
        Text("Open this in the computer's browser while Tether is on screen:")
            .font(.subheadline)
            .accessibilityIdentifier("add.laptop")
        if let first = hosts.first {
            addressRow(ConfigPage.url(host: first), id: "add.address", copyID: "add.copy")
        }
        if hosts.count > 1, let mac = hosts.last {
            Text("On a Mac, or if that one doesn't open:")
                .font(.subheadline)
                .accessibilityIdentifier("add.macLabel")
            addressRow(ConfigPage.url(host: mac), id: "add.addressMac", copyID: "add.copyMac")
            ipv6Note
        }
        if let file {
            HStack(spacing: 10) {
                Rectangle().fill(Color(.separator)).frame(height: 1)
                Text("or").font(.footnote).foregroundStyle(.secondary)
                Rectangle().fill(Color(.separator)).frame(height: 1)
            }
            .accessibilityHidden(true)
            ShareLink(item: file) {
                Label("Share the file", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("add.share")
            Text("AirDrop it to a Mac, then open it in WireGuard.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("add.airdrop")
            windowNote(id: "add.fileWindow")
        }
    }

    /// One address of the page, with a button to copy it.
    private func addressRow(_ address: String, id: String, copyID: String) -> some View {
        // At accessibility sizes the copy button goes under the address, which then has the whole width.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                                         : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            // An IPv6 address is up to 47 characters with http:// and its brackets, with no space to
            // break a line at. A zero-width space after each colon lets it wrap, to as many lines as it
            // needs: it's typed into another device, so none of it may be cut (#170). Plain text, not a
            // link: a tap would open the page on this iPhone (#184). Not selectable either, which would
            // copy the zero-width spaces: the copy button copies the address as it is.
            Text(address.replacingOccurrences(of: ":", with: ":\u{200B}"))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // VoiceOver says what it is, then the address, which as a label alone fails the audit.
                .accessibilityLabel("Page address")
                .accessibilityValue(address)
                .accessibilityIdentifier(id)
            Button {
                UIPasteboard.general.string = address
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Copy the address")
            .accessibilityIdentifier(copyID)
        }
        .padding(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 6))
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Under an IPv6 address: a computer with IPv6 off for the hotspot can't reach it (#94).
    private var ipv6Note: some View {
        Text("If neither opens, turn on IPv6 for the computer's Wi-Fi.")
            .font(.subheadline)
            .accessibilityIdentifier("add.ipv6")
    }

    /// How long the code and the shared file work, see `AddWindow`. Not under the
    /// page's address: a download from the page is listed at once, so it works on after that.
    private func windowNote(id: String) -> some View {
        Text("Works while this screen is open, and for \(Int(AddWindow.afterClose / 60)) minutes after you close it or leave Tether.")
            // In the label colour, like the line above it: grey fails the contrast audit on this card.
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(id)
    }
}

/// One step on the line: its mark, the title and what to do, and the line down to the next step,
/// in the icon's colours once this step is done. The last step has no line.
private struct StepRow<Content: View>: View {
    let number: Int
    let mark: StepMark.Look
    /// Nil for the last step.
    let lineDone: Bool?
    let title: String
    let id: String
    @ViewBuilder let content: Content
    @ScaledMetric(relativeTo: .headline) private var markSize: CGFloat = 30

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                StepMark(number: number, state: mark)
                    .frame(width: markSize, height: markSize)
                    .accessibilityIdentifier("\(id).mark")
                if let lineDone {
                    Capsule()
                        .fill(lineDone ? AnyShapeStyle(LinearGradient(colors: StatusOrb.iconColors, startPoint: .top, endPoint: .bottom))
                                       : AnyShapeStyle(Color(.systemGray5)))
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                        .accessibilityHidden(true)
                }
            }
            // As wide as the mark, which grows with the text size.
            .frame(width: markSize + 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(id)
                content
            }
            // The title's first line sits level with the mark.
            .padding(.top, 4)
            .padding(.bottom, lineDone == nil ? 0 : 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Sized to the content, so the line grows to the next step.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A step's mark: a tick in the icon's colours when done, the number in a ring for the current step
/// (with a spinner while it waits for the device), and a grey ring for the steps after it.
private struct StepMark: View {
    enum Look { case done, current, waiting, later }
    let number: Int
    let state: Look
    /// The icon's blue to a darker teal than its own, so the white tick keeps a 4.5:1 contrast.
    static let doneColors = [StatusOrb.iconColors[0], Color(red: 0.04, green: 0.48, blue: 0.49)]

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(LinearGradient(colors: Self.doneColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(.white)
            case .current:
                Circle().strokeBorder(Color.accentColor, lineWidth: 2.5)
                Text("\(number)").font(.subheadline.weight(.bold)).foregroundStyle(Color.accentColor)
            case .waiting:
                Circle().strokeBorder(Color.accentColor, lineWidth: 2.5)
                ProgressView().controlSize(.small)
            case .later:
                Circle().strokeBorder(Color(.systemGray3), lineWidth: 2)
                Text("\(number)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(state == .current ? "Current" : "")
    }

    private var label: String {
        switch state {
        case .done: "Done"
        case .waiting: "Waiting"
        case .current, .later: "Step \(number) of 3"
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
        let code = (text: text, qr: QRCode.image(text), file: ConfigFile.write(text, named: ""))
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
