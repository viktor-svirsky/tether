import CoreImage.CIFilterBuiltins
import SwiftUI

/// Adding one device. First it asks whether the device has the WireGuard app (#78): with it, three steps
/// on a line that fills with the icon's colours as each one ticks off by itself: join the hotspot,
/// give it the config, turn its tunnel on. Without it, the proxy's three steps, see `proxySteps`.
/// The WireGuard way follows the code that
/// was ready when it opened, see `AddDeviceProgress`. The page and the connected list keep up only
/// while Tether is on screen, so in the background the steps wait, and they catch up when it's back.
/// The code works only while the sheet is on screen and for 10 minutes after, see
/// `AddWindow`, so opening it after that shows a new code. Once the device connects, it asks for
/// its name, filled with the one it got ("Device 2") and selected, so typing replaces it (#173).
struct AddDeviceSheet: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    /// The device behind the code. Until it's claimed, a new code (after starting over, say) takes its place.
    @State private var readyID: WireGuardSetup.Peer.ID?
    /// Which way the device gets its config: a phone or tablet scans, a computer or a travel router
    /// gets the file (#171).
    @State private var kind = Kind.phone
    /// The device's name, typed once it connects and saved when the sheet closes.
    @State private var naming = AddDeviceNaming()
    @FocusState private var nameFocused: Bool
    /// Selects the name when the field starts editing, once, see `SelectsAllOnEdit`.
    @State private var selectsName = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The way picked at the first question, empty while it shows.
    @State private var path: [AddDeviceWay]
    /// The proxy's last step, from when its screen opened.
    @State private var proxyProgress: ProxyProgress?

    enum Kind: Hashable { case phone, computer }

    init(model: Model) {
        self.model = model
        _readyID = State(initialValue: model.addDeviceFollows ?? model.wireGuardReady?.id)
        _kind = State(initialValue: model.addDeviceStartsOnComputer ? .computer : .phone)
        _path = State(initialValue: model.addDeviceOpensOn.map { [$0] } ?? [])
    }

    private var progress: AddDeviceProgress {
        AddDeviceProgress(ready: readyID, peers: model.wireGuardPeers, connected: model.wireGuardConnected, hotspotOn: model.running)
    }

    var body: some View {
        let progress = progress
        NavigationStack(path: $path) {
            choice
                .navigationTitle("Add a device")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { closeButton }
                .navigationDestination(for: AddDeviceWay.self) { way in
                    switch way {
                    case .wireGuard: wireGuardSteps
                    case .proxy: proxySteps
                    }
                }
        }
        .onChange(of: model.wireGuardReady?.id) { _, new in
            if self.progress.device == nil { readyID = new }
        }
        // The demos that open on the sheet open the window the same way.
        .onAppear {
            model.openAddWindow()
            UIApplication.shared.isIdleTimerDisabled = keepsScreenAwake
        }
        .onChange(of: progress) { old, new in
            if let text = new.announcement(after: old) { AccessibilityNotification.Announcement(text).post() }
        }
        .onChange(of: keepsScreenAwake) { _, awake in UIApplication.shared.isIdleTimerDisabled = awake }
        // The first time it connects, the keyboard comes up with the name it got, selected, so
        // typing replaces it. Its tunnel dropping after that leaves the step as it is.
        .onChange(of: progress, initial: true) { _, progress in
            guard naming.device == nil else { return }
            naming.follow(progress)
            if naming.device != nil {
                selectsName = true
                nameFocused = true
            }
        }
        .modifier(SelectsAllOnEdit(pending: $selectsName))
        // Claimed: its file now holds a key that works.
        .onChange(of: progress.device != nil) { _, claimed in if claimed { ReadyCode.forget() } }
        .onDisappear {
            // Closed another way than Done keeps what was typed too.
            _ = saveName()
            ReadyCode.forget()
            model.closeAddWindow()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// Only on the WireGuard steps: the page hands out the config only while Tether is on screen. The
    /// proxy works with the screen off.
    private var keepsScreenAwake: Bool { path.last == .wireGuard && progress.keepsScreenAwake }

    /// The same close button as Settings, on every page of the sheet.
    @ToolbarContentBuilder private var closeButton: some ToolbarContent {
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

    /// The first question: the WireGuard app, or the proxy for a device without it (#78).
    private var choice: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Does the other device have the WireGuard app?")
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("add.question")
                wayButton(.wireGuard, title: "Yes, use WireGuard", detail: "Everything on it goes through Tether, games and calls too.",
                          id: "add.way.wireGuard")
                wayButton(.proxy, title: "No, use the proxy", detail: "No app needed. Most apps go through Tether, some don't.",
                          id: "add.way.proxy")
                Text("Can't install apps? A TV, a console or a work laptop can use the proxy.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("add.wayHint")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// One answer, as a card that opens its steps. The detail keeps the label colour: grey fails the
    /// contrast audit on the card.
    private func wayButton(_ way: AddDeviceWay, title: String, detail: String, id: String) -> some View {
        NavigationLink(value: way) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.primary)
            .padding(16)
            .background(Self.card)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// The WireGuard way's three steps, as they were before the question.
    private var wireGuardSteps: some View {
        let progress = progress
        let current = Self.current(progress)
        return ScrollView {
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

                if naming.device != nil {
                    connected
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        // Lowering the keyboard needs a way other than its Done, which saves and closes.
        .scrollDismissesKeyboard(.immediately)
        // iOS scrolls only the text of a focused field above the keyboard, not the box around
        // it, which then ran under Done. The box's padding and the space above Done, as
        // room under the scrolling content (#173).
        .safeAreaPadding(.bottom, Self.nameBoxRoom)
        .safeAreaInset(edge: .bottom) {
            if naming.device != nil {
                Button(action: finish) {
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
        .navigationTitle("Use WireGuard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { closeButton }
        // It connected while another page showed: the keyboard comes up for its name here.
        .onAppear { if naming.device != nil { nameFocused = true } }
    }

    /// Once it connects: that it did, and its name to type.
    private var connected: some View {
        VStack(spacing: 14) {
            StatusOrb(look: .sharing)
            // The tick is the step marks' own, and VoiceOver reads the word.
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LinearGradient(colors: StepMark.doneColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .accessibilityHidden(true)
                Text("Connected")
                    .accessibilityIdentifier("add.result")
            }
            .font(.system(.title, design: .rounded, weight: .heavy))
            Text("It uses this iPhone's data now.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // Above the field, so the keyboard doesn't cover it. The draft stays to try again.
            if let problem = nameProblem {
                WarningLabel(problem)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("add.nameProblem")
            }
            VStack(alignment: .leading, spacing: 6) {
                // The field says Name to VoiceOver itself.
                Text("Name")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHidden(true)
                TextField("Name", text: $naming.draft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit(finish)
                    // The prompt alone isn't the label once the field holds a name.
                    .accessibilityLabel("Name")
                    .accessibilityIdentifier("add.name")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    // The box, for the tests: the text field's own frame is only the text.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("add.nameBox")
            }
        }
        .padding(.top, 12)
    }

    /// The name box's padding under the text, and the space between the box and Done.
    private static let nameBoxRoom: CGFloat = 12 + 16

    /// Done: saves the name and closes, or stays with the draft when it couldn't be saved.
    private func finish() {
        if saveName() { dismiss() }
    }

    /// True when the name saved or there was nothing to save, see `AddDeviceNaming.change`. A failed
    /// save keeps the old name and says why, on the device's screen too.
    private func saveName() -> Bool {
        guard let change = naming.change(in: model.wireGuardPeers) else { return true }
        model.renameWireGuardDevice(change.id, to: change.name)
        guard let problem = model.wireGuardDeviceProblem, problem.device == change.id else { return true }
        AccessibilityNotification.Announcement(problem.text).post()
        return false
    }

    /// Why the device's name couldn't be saved.
    private var nameProblem: String? {
        model.wireGuardDeviceProblem.flatMap { $0.device == naming.device ? $0.text : nil }
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
                if dynamicTypeSize.isAccessibilitySize {
                    // A segmented control keeps its small text at every size, so here the two kinds
                    // are full-width buttons, one under the other (#176).
                    kindButton("Phone or tablet", .phone, id: "add.kind.phone")
                    kindButton("Computer or router", .computer, id: "add.kind.computer")
                } else {
                    Picker("Kind of device", selection: $kind) {
                        Text("Phone or tablet").tag(Kind.phone)
                        Text("Computer or router").tag(Kind.computer)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("add.kind")
                }
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

    /// One kind of device at accessibility sizes, filled when it's the one chosen. One button whose
    /// style changes, so VoiceOver keeps its focus on it after a tap.
    private func kindButton(_ title: String, _ value: Kind, id: String) -> some View {
        Button(title) { kind = value }
            .buttonStyle(KindButtonStyle(selected: kind == value))
            .accessibilityAddTraits(kind == value ? .isSelected : [])
            .accessibilityIdentifier(id)
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
        // WireGuard for Android says Scan from QR code (#171).
        Text("In WireGuard, tap + and Create from QR code. On Android, tap + and Scan from QR code.")
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
                Group {
                    // At accessibility sizes the icon goes above the text: on one line the text
                    // breaks inside a word (#176).
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up").accessibilityHidden(true)
                            Text("Share the file")
                        }
                    } else {
                        Label("Share the file", systemImage: "square.and.arrow.up")
                    }
                }
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
            Text("On a travel router, import the file in its VPN settings, under WireGuard.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("add.router")
            windowNote(id: "add.fileWindow")
        }
    }

    /// One address of the page, with a button to copy it. `caption` names it above, for the proxy's
    /// server and port, and `name` is what VoiceOver says it is.
    private func addressRow(_ address: String, caption: String? = nil, name: String = "Page address", copyLabel: String = "Copy the address",
                            id: String, copyID: String) -> some View {
        // At accessibility sizes the copy button goes under the address, which then has the whole width.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                                         : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                if let caption {
                    Text(caption)
                        .font(.footnote.weight(.semibold))
                        .accessibilityHidden(true) // the address's own label says it
                }
                AddressText(address)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // VoiceOver says what it is, then the address, which as a label alone fails the audit.
                    .accessibilityLabel(name)
                    .accessibilityValue(address)
                    .accessibilityIdentifier(id)
            }
            CopyButton(text: address, label: copyLabel)
                .accessibilityIdentifier(copyID)
        }
        .padding(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 6))
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: The proxy (#78)

    /// The proxy's three steps: join the hotspot, set the proxy in the device's Wi-Fi settings, open a
    /// page. The proxy turns on when this opens, and stays on: its own screen turns it off. The last
    /// step ticks off once a page goes through it, see `ProxyProgress`.
    private var proxySteps: some View {
        let working = proxyProgress?.working == true
        let hotspot = model.running
        let paused = model.proxy?.paused != nil
        return ScrollView {
            VStack(spacing: 24) {
                if model.localNetworkDenied && !working {
                    localNetworkWarning
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Self.card)
                }
                if let problem = model.proxyProblem {
                    WarningLabel(problem)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Self.card)
                        .accessibilityIdentifier("add.proxy.problem")
                }
                VStack(spacing: 0) {
                    StepRow(number: 1, mark: hotspot ? .done : .current, lineDone: hotspot,
                            title: "Join this iPhone's hotspot", id: "add.proxy.step1") {
                        if hotspot {
                            note("The hotspot is on. Join it on the new device too.")
                        } else {
                            HotspotWaitingHint(id: "add.proxy")
                                .font(.subheadline)
                        }
                    }
                    StepRow(number: 2, mark: working ? .done : hotspot ? .current : .later, lineDone: working,
                            title: "In its Wi-Fi settings, set the proxy", id: "add.proxy.step2") {
                        proxySettings(ProxyAddress.servers(model.proxyStats.addresses))
                    }
                    StepRow(number: 3, mark: working ? .done : hotspot && !paused ? .waiting : .later, lineDone: nil,
                            title: "Open a page on it", id: "add.proxy.step3") {
                        Group {
                            if working {
                                note("Working")
                            } else if paused {
                                note("The proxy is paused. Resume it on its screen, under Devices.")
                            } else {
                                note("Waiting for the first page")
                            }
                        }
                        .accessibilityIdentifier("add.proxy.result")
                    }
                }
                .padding(EdgeInsets(top: 20, leading: 14, bottom: 20, trailing: 18))
                .background(Self.card)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Use the proxy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { closeButton }
        .onAppear {
            if !model.proxyOn || model.proxy?.paused == .byYou { model.setProxy(on: true) }
            proxyProgress = ProxyProgress(at: model.proxyStats)
        }
        .onChange(of: model.proxyStats) { _, stats in
            let was = proxyProgress?.working
            proxyProgress?.follow(stats)
            if was == false, proxyProgress?.working == true { AccessibilityNotification.Announcement("The proxy is working").post() }
        }
    }

    /// Where the proxy is, to type into the device, and where each kind of device takes it. Two servers
    /// on a hotspot that gives Apple devices IPv6 only: 172.20.10.1 for the others, then the IPv6 one.
    @ViewBuilder private func proxySettings(_ servers: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            addressRow(servers[0], caption: "Server", name: "Server", copyLabel: "Copy the server", id: "add.proxy.server",
                       copyID: "add.proxy.copyServer")
            if servers.count > 1 {
                Text("An iPhone, iPad or Mac gets only IPv6 on this hotspot, so on those:")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("add.proxy.ipv6Label")
                addressRow(servers[1], caption: "Server", name: "Server for an iPhone, iPad or Mac", copyLabel: "Copy that server",
                           id: "add.proxy.serverIPv6", copyID: "add.proxy.copyServerIPv6")
            }
            addressRow(ProxyAddress.port, caption: "Port", name: "Port", copyLabel: "Copy the port", id: "add.proxy.port",
                       copyID: "add.proxy.copyPort")
            ProxyPlaces()
        }
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

/// An address typed into another device. An IPv6 address is up to 47 characters with http:// and
/// its brackets, with no space to break a line at. A zero-width space after each colon lets it wrap,
/// to as many lines as it needs, so none of it is cut (#170). Plain text, not a link: a tap would
/// open the page on this iPhone (#184). Not selectable either, which would copy the zero-width
/// spaces: `CopyButton` copies the address as it is.
struct AddressText: View {
    let address: String
    init(_ address: String) { self.address = address }

    var body: some View {
        Text(address.replacingOccurrences(of: ":", with: ":\u{200B}"))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Copies `text`, and says it worked for a moment: the icon turns into a tick, and VoiceOver hears
/// "Copied" (#175). A second tap starts the moment again.
struct CopyButton: View {
    let text: String
    /// What VoiceOver calls it, "Copy the address".
    let label: String
    /// Behind the icon: the card's colour on the sheet's grey, a fill on a list row.
    var fill = Color(.secondarySystemGroupedBackground)
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            AccessibilityNotification.Announcement("Copied").post()
            reset?.cancel()
            reset = Task {
                guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel(label)
        .accessibilityValue(copied ? "Copied" : "")
    }
}

/// Where each kind of device sets the proxy, under Add a device's server and port (#78). The name
/// and the path side by side, or one under the other at the accessibility sizes.
struct ProxyPlaces: View {
    static let places = [
        ("iPhone, iPad", "Wi-Fi > (i) > Configure Proxy > Manual"),
        ("Mac", "Wi-Fi > Details > Proxies > Web and Secure Web"),
        ("Windows", "Settings > Proxy > Use a proxy server"),
        ("Android", "Wi-Fi > network > Edit > Proxy > Manual"),
        ("PlayStation, Xbox, TV", "In the network settings, Proxy"),
    ]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                                                         : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.places.indices, id: \.self) { i in
                layout {
                    Text(Self.places[i].0)
                        .fontWeight(.semibold)
                        .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 96, alignment: .leading)
                    Text(Self.places[i].1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("add.proxy.where\(i + 1)")
            }
        }
    }
}

/// A kind of device at accessibility sizes: filled like Done when chosen, plain otherwise.
private struct KindButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(selected ? Color.white : Color.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(selected ? Color.filledButton : Color(.tertiarySystemFill), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // The mark goes above the text, which then has the whole width instead of a word or two
            // a line (#176). There is no room for the line beside it.
            VStack(alignment: .leading, spacing: 8) {
                stepMark
                text
            }
            .padding(.bottom, lineDone == nil ? 0 : 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            row
        }
    }

    private var stepMark: some View {
        StepMark(number: number, state: mark)
            .frame(width: markSize, height: markSize)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                // The step's number and state are read with its title, as one stop (#175).
                .accessibilityLabel("Step \(number) of 3, \(title)")
                .accessibilityValue(mark.spoken)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(id)
            content
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                stepMark
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
            text
            // The title's first line sits level with the mark.
            .padding(.top, 4)
            .padding(.bottom, lineDone == nil ? 0 : 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Sized to the content, so the line grows to the next step.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Selects a text field's whole text when it starts editing, while `pending` is on, and turns it
/// off, so a name is replaced by typing and a later tap can place the cursor. iOS starts editing
/// with the cursor at the end, and SwiftUI has no selection before iOS 18.
struct SelectsAllOnEdit: ViewModifier {
    @Binding var pending: Bool

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { note in
            guard pending, let field = note.object as? UITextField else { return }
            pending = false
            // Selecting while editing begins doesn't hold.
            DispatchQueue.main.async { field.selectAll(nil) }
        }
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
        // Read with the step's title instead, see `StepRow`.
        .accessibilityHidden(true)
    }
}

extension StepMark.Look {
    /// How far the step is, read after its title. Nothing for a step not reached yet.
    var spoken: String {
        switch self {
        case .done: "Done"
        case .current: "Current"
        case .waiting: "Waiting"
        case .later: ""
        }
    }
}

/// The ready device's QR code and file, made once for each config: a new ready device, or a new
/// hotspot address. The sheet redraws every second with the speeds the model publishes, and making
/// them on each redraw cost a CIContext and a file write every second.
@MainActor
enum ReadyCode {
    private static var made: (text: String, qr: UIImage?, file: URL?)?

    /// Only a new config is made again, not each redraw: checking the file was a disk call a second.
    /// A file that couldn't be written is tried again on the next redraw.
    static func `for`(_ text: String) -> (qr: UIImage?, file: URL?) {
        if let made, made.text == text, made.file != nil { return (made.qr, made.file) }
        let code = (text: text, qr: QRCode.image(text), file: ConfigFile.write(text, named: ""))
        made = code
        return (code.qr, code.file)
    }

    /// The file holds a private key that works once a device has claimed it, so it goes when the
    /// sheet closes or the code is claimed (#183). The next code writes a new one.
    static func forget() {
        made = nil
        ConfigFile.removeAll()
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
