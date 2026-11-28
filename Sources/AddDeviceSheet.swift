import CoreImage.CIFilterBuiltins
import SwiftUI

/// Adding one device. First it asks whether an app can go on the device (#78, H4): WireGuard, four steps
/// on a line that fills in ink as each one ticks off by itself: join the hotspot, install WireGuard,
/// get the config into it, turn it on (M12). Without an app, the proxy's three steps, see `proxySteps`.
/// Given a device to replace (M1), it opens on the WireGuard steps for that device's new config.
/// The WireGuard way follows the code that
/// was ready when it opened, see `AddDeviceFollow` and `AddDeviceProgress`. The page and the
/// connected list keep up only while Tether is on screen, so in the background the steps wait, and
/// they catch up when it's back.
/// The code works only while the sheet is on screen and for 10 minutes after, see
/// `AddWindow`, so opening it after that shows a new code. Once the device connects, it asks for
/// its name, filled with the one it got ("Device 2") and selected, so typing replaces it (#173).
struct AddDeviceSheet: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    /// The device behind the code, see `AddDeviceFollow`.
    @State private var follow: AddDeviceFollow
    /// Which way the device gets its config: a phone or tablet scans, a computer or a travel router
    /// gets the file (#171).
    @State private var kind = Kind.phone
    /// The device's name, typed once it connects and saved when the sheet closes.
    @State private var naming = AddDeviceNaming()
    @FocusState private var nameFocused: Bool
    /// Where the name box ends and Done starts on screen, to see when the box runs under Done.
    @State private var nameBoxBottom: CGFloat = 0
    @State private var doneTop: CGFloat = .infinity
    /// Selects the name when the field starts editing, once, see `SelectsAllOnEdit`.
    @State private var selectsName = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The way picked at the first question, empty while it shows.
    @State private var path: [AddDeviceWay]
    /// The proxy's last step, from when its screen opened.
    @State private var proxyProgress: ProxyProgress?
    /// The device this gives a new config to (M1), as it was when the sheet opened. Nil to add one.
    /// Kept as it was then, like `follow`, so the sheet doesn't change pages if the device goes.
    @State private var replacing: WireGuardSetup.Peer?
    /// The Copied capsule at the bottom, after a copy button's tap (L4).
    @State private var copied = false

    enum Kind: Hashable { case phone, computer }

    /// `replacing`: the device to give a new config to, from its screen (M1). Its name, limit, pause and
    /// use stay, see `HotspotSession.openAddWindow(replacing:)`.
    init(model: Model, replacing: WireGuardSetup.Peer.ID? = nil) {
        self.model = model
        let replaced = (replacing ?? model.addDeviceReplaces).flatMap { id in model.wireGuardPeers.first { $0.id == id } }
        _replacing = State(initialValue: replaced)
        _follow = State(initialValue: AddDeviceFollow(follows: model.addDeviceFollows, ready: model.wireGuardReady?.id, replacing: replaced))
        _kind = State(initialValue: model.addDeviceStartsOnComputer ? .computer : .phone)
        // A new config is for a WireGuard device, so there's no question to come back to.
        _path = State(initialValue: replaced == nil ? model.addDeviceOpensOn.map { [$0] } ?? [] : [])
    }

    private var progress: AddDeviceProgress {
        follow.progress(peers: model.wireGuardPeers, connected: model.wireGuardConnected, hotspotOn: model.running)
    }

    var body: some View {
        let progress = progress
        NavigationStack(path: $path) {
            Group {
                if replacing != nil {
                    wireGuardSteps
                } else {
                    choice
                        .navigationTitle("Add a device")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { closeButton }
                }
            }
            .navigationDestination(for: AddDeviceWay.self) { way in
                switch way {
                case .wireGuard: wireGuardSteps
                case .proxy: proxySteps
                }
            }
        }
        // Links and the system buttons in ink, like the rest of the paper look (#349).
        .tint(Theme.ink)
        .onChange(of: model.wireGuardReady?.id) { _, new in follow.readyChanged(to: new, peers: model.wireGuardPeers) }
        // The demos that open on the sheet open the window the same way.
        .onAppear {
            model.openAddWindow(replacing: replacing?.id)
            UIApplication.shared.isIdleTimerDisabled = keepsScreenAwake
        }
        .onChange(of: progress) { old, new in
            if let text = new.announcement(after: old) { AccessibilityNotification.Announcement(text).post() }
        }
        .onChange(of: keepsScreenAwake) { _, awake in UIApplication.shared.isIdleTimerDisabled = awake }
        // The first time it connects, the keyboard comes up with the name it got, selected, so
        // typing replaces it. Its tunnel dropping after that leaves the step as it is. A device given
        // a new config keeps its name, so it has no field.
        .onChange(of: progress, initial: true) { _, progress in
            guard naming.device == nil else { return }
            naming.follow(progress)
            if naming.device != nil, replacing == nil {
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

    /// A new config opens on the WireGuard steps with nothing on the path.
    private var keepsScreenAwake: Bool {
        AddDeviceFollow.keepsScreenAwake(on: replacing == nil ? path.last : .wireGuard, progress)
    }

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

    /// The first question: an app on the device, WireGuard, or the proxy for a device that can't take
    /// one (#78). WireGuard is said to be free and recommended up front (H4).
    private var choice: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Can you install an app on the other device?")
                    .font(Self.titleFont)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("add.question")
                VStack(spacing: 4) {
                    wayButton(.wireGuard, title: "Yes, install WireGuard",
                              detail: "Recommended. The app is free. Everything on it goes through Tether, games and calls too.",
                              id: "add.way.wireGuard")
                    wayButton(.proxy, title: "No, use the proxy",
                              detail: "No app needed. For a TV, a console or a work laptop. Most apps go through Tether, some don't.",
                              id: "add.way.proxy")
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Self.margin)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .paperBackground()
    }

    /// One answer, as a plain row on the paper that opens its steps: the title in ink, the detail in
    /// the secondary colour, and an arrow instead of a chevron.
    private func wayButton(_ way: AddDeviceWay, title: String, detail: String, id: String) -> some View {
        NavigationLink(value: way) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3)
                    Text(detail).font(.subheadline).foregroundStyle(Theme.secondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right")
                    .font(.body)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.ink)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// The light large title of the paper look, which scales with Dynamic Type.
    private static let titleFont = Font.system(.largeTitle, weight: .light)
    /// The space at the sides of each page.
    private static let margin: CGFloat = 24

    /// The WireGuard way's four steps (M12). Join comes first: the hotspot gives the device the
    /// internet it needs to install the app.
    private var wireGuardSteps: some View {
        let progress = progress
        let current = progress.current ?? 5
        let steps = progress.steps
        return ScrollViewReader { scroll in ScrollView {
            VStack(spacing: 24) {
                stepCount(progress.heldByPause ? nil : progress.current, of: 4)
                // Above the steps: a device scanned first would only learn after that it can't work.
                if model.localNetworkDenied && !progress.finished {
                    localNetworkWarning
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Self.box)
                        .transition(.opacity)
                }
                VStack(spacing: 0) {
                    StepRow(number: 1, of: 4, mark: mark(steps[0], step: 1, current: current), lineDone: steps[0] == .done,
                            title: "Join this iPhone's hotspot", id: "add.step1") {
                        if progress.joined == .done {
                            note("The hotspot is on. Join it on the new device too.")
                        } else {
                            HotspotWaitingHint(id: "add")
                                .font(.subheadline)
                        }
                    }
                    // Every step after this assumes WireGuard is on the other device (#169).
                    StepRow(number: 2, of: 4, mark: mark(steps[1], step: 2, current: current), lineDone: steps[1] == .done,
                            title: "Install WireGuard on it", id: "add.step2") {
                        Text("The app is free: App Store, Google Play, or wireguard.com/install.")
                            .font(.subheadline)
                            .foregroundStyle(steps[1] == .done ? Theme.secondary : Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("add.install")
                    }
                    // The code shows while step 2 is the current one too: only WireGuard can use it.
                    StepRow(number: 3, of: 4, mark: mark(steps[2], step: 3, current: current), lineDone: steps[2] == .done,
                            title: kind == .phone ? "Scan the code with WireGuard" : "Get the file into WireGuard", id: "add.step3") {
                        config(progress)
                    }
                    StepRow(number: 4, of: 4, mark: mark(steps[3], step: 4, current: current), lineDone: nil,
                            title: "Turn it on in WireGuard", id: "add.step4") {
                        switch (progress.tunnel, progress.device) {
                        case (.done, _): note("Connected")
                        // Its pause keeps it out, so it won't tick off: the end below says so.
                        case (_, let device?) where progress.heldByPause: note("\(device.name) is paused, so it can't connect yet.")
                        // It won't tick off by itself: the warning above says why.
                        case _ where model.localNetworkDenied: note("Waiting for Local Network to be on")
                        case _ where model.staleConfigShown:
                            Text("A device is trying to connect with a config that no longer works. If it's this one, delete its tunnel in WireGuard and scan the code or get the file again.")
                                .font(.subheadline)
                                .foregroundStyle(LocalNetworkWarning.text)
                                .accessibilityIdentifier("add.stale")
                        case (.waiting, let device?): note("Waiting for \(device.name) to connect")
                        default: note("In WireGuard, turn on the tunnel you just added. This ticks off by itself when it connects.")
                        }
                    }
                }

                if showsEnd(progress) {
                    end(progress)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Self.margin)
            .padding(.bottom, 24)
            // Each step ticking off, the code giving way to Connected, and the kind of device
            // changing cross-fade, and the page's height follows, instead of a cut (#349).
            .animation(motion, value: progress)
            .animation(motion, value: naming.device)
            .animation(motion, value: kind)
            .animation(motion, value: model.localNetworkDenied)
            .animation(motion, value: model.staleConfigShown)
        }
        .paperBackground()
        // Under Done's inset, not over it. Gone when the page goes: its timer stops with the page.
        .copiedToast($copied, id: "add.copied")
        .onDisappear { copied = false }
        // Lowering the keyboard needs a way other than its Done, which saves and closes.
        .scrollDismissesKeyboard(.immediately)
        // iOS scrolls only the text of a focused field above the keyboard, not the box around
        // it, which then ran under Done. The box's padding and the space above Done, as
        // room under the scrolling content (#173).
        .safeAreaPadding(.bottom, Self.nameBoxRoom)
        .safeAreaInset(edge: .bottom) {
            // Its own animation: the inset is outside the page's VStack, so Done fades in with Connected.
            VStack { if showsEnd(progress) {
                Button(action: finish) {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(InkCapsuleButtonStyle())
                .padding(.horizontal, Self.margin)
                .padding(.vertical, 8)
                // Large text scrolls the connected message under it.
                .background(Theme.paper)
                .transition(.opacity)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY.rounded() } action: { doneTop = $0 }
                .accessibilityIdentifier("add.done")
            } }
            .animation(motion, value: showsEnd(progress))
        }
        .navigationTitle(replacing.map { "New config for \($0.name)" } ?? "Use WireGuard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { closeButton }
        // It connected while another page showed: the keyboard comes up for its name here.
        .onAppear { if naming.device != nil, replacing == nil { nameFocused = true } }
        // iOS keeps the focused field's text above the keyboard, but on a slow device it can leave
        // the box around it under Done. Whenever the box is seen under Done while typing, or typing
        // starts with it there, it goes above Done (#173). This runs on the measured overlap, not on
        // a keyboard event, which can come before the layout settles.
        .onChange(of: nameFocused ? max(0, nameBoxBottom - doneTop) : 0) { _, under in
            if under > 0 { scroll.scrollTo(Self.nameBoxID, anchor: .bottom) }
        }
        } // ScrollViewReader
    }

    /// The end of the steps, with Done: connected once, or held by a pause it kept, which would
    /// otherwise wait for ever.
    private func showsEnd(_ progress: AddDeviceProgress) -> Bool { naming.device != nil || progress.heldByPause }

    /// Once it connects: that it did, and its name to type. A device given a new config keeps its name,
    /// and its old tunnel is still in WireGuard on it. A paused one ends at Paused instead.
    private func end(_ progress: AddDeviceProgress) -> some View {
        let paused = naming.device == nil && progress.heldByPause
        return VStack(spacing: 14) {
            // The live dot says it in colour, and the word says it to everyone. Paused has an empty ring.
            HStack(spacing: 12) {
                ZStack {
                    if paused {
                        Circle().strokeBorder(Theme.secondary, lineWidth: 1.5)
                    } else {
                        Circle().fill(Theme.live)
                    }
                }
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
                Text(paused ? "Paused" : "Connected")
                    .accessibilityIdentifier("add.result")
            }
            .font(Self.titleFont)
            Text(paused ? "It has its \(replacing == nil ? "" : "new ")config. It connects once it's resumed: tap it under Devices, then Resume."
                        : "It uses this iPhone's data now.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("add.resultDetail")
            if replacing != nil {
                Text("Delete the old tunnel in WireGuard on that device.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("add.oldTunnel")
            } else if !paused {
                nameField
            }
        }
        .padding(.top, 12)
    }

    /// The name to type once it connects, with why it couldn't be saved above it.
    @ViewBuilder private var nameField: some View {
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
                .background(Self.box)
                // The box, for the tests: the text field's own frame is only the text.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("add.nameBox")
                .id(Self.nameBoxID)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY.rounded() } action: { nameBoxBottom = $0 }
        }
    }

    /// The name box's padding under the text, and the space between the box and Done.
    private static let nameBoxRoom: CGFloat = 12 + 16
    private static let nameBoxID = "nameBox"

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

    /// A box on the paper for what's typed or copied, and for a warning: the card's colour with a
    /// thin edge in the secondary colour, 3:1 or more like a control's edge, since white on paper
    /// alone doesn't show. No shadow: that's the live card's, for what moves.
    private static var box: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.card)
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.secondary, lineWidth: 1) }
    }

    /// A short ease when a step's state changes. Nothing moves with Reduce Motion: it changes at once.
    private var motion: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.3) }

    /// STEP 2 OF 4 above the steps, the digit rolling to the next one. VoiceOver reads the step with
    /// each title instead, see `StepRow`. Gone once every step is done.
    @ViewBuilder private func stepCount(_ step: Int?, of total: Int) -> some View {
        if let step {
            Text("Step \(step) of \(total)")
                .monoCaps()
                .contentTransition(.numericText(value: Double(step)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
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
            .foregroundStyle(Theme.secondary)
            .transition(.opacity)
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
                case .phone:
                    VStack(alignment: .leading, spacing: 14) { scan(code.qr) }
                        .transition(.opacity)
                case .computer:
                    VStack(alignment: .leading, spacing: 14) { download(hosts: model.pageHosts, file: code.file) }
                        .transition(.opacity)
                }
            }
            // The code fades out as the device's name fades in, see `wireGuardSteps`.
            .transition(.opacity)
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
                // The QR standard's quiet zone, four modules or more, which dark paper doesn't give
                // (#178). White in dark mode too, with the card's edge there instead of a shadow.
                .padding(22)
                .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    if scheme == .dark {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardEdge, lineWidth: 1)
                    }
                }
                .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.08), radius: 15, y: 10)
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
                Rectangle().fill(Theme.secondary.opacity(0.35)).frame(height: 1)
                Text("or").font(.footnote).foregroundStyle(Theme.secondary)
                Rectangle().fill(Theme.secondary.opacity(0.35)).frame(height: 1)
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
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("add.share")
            Text("AirDrop it to a Mac, then open it in WireGuard.")
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("add.airdrop")
            Text("On a travel router, import the file in its VPN settings, under WireGuard.")
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
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
            CopyButton(text: address, label: copyLabel, copied: $copied)
                .accessibilityIdentifier(copyID)
        }
        .padding(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 6))
        .background(Self.box)
    }

    // MARK: The proxy (#78)

    /// The proxy's three steps: join the hotspot, set the proxy in the device's Wi-Fi settings, open a
    /// page. Opening them turns nothing on (H5): while the proxy is off or paused, step 2 says so, with
    /// the button that turns it on, and it stays on after: its own screen turns it off. The last step
    /// ticks off once a page goes through it, see `ProxyProgress`, and the steps end like the WireGuard
    /// ones, with Done (L3).
    private var proxySteps: some View {
        let working = proxyProgress?.working == true
        let hotspot = model.running
        let blocked = ProxyStatus.blocked(model.proxy)
        return ScrollView {
            VStack(spacing: 24) {
                stepCount(working ? nil : hotspot ? 2 : 1, of: 3)
                if model.localNetworkDenied && !working {
                    localNetworkWarning
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Self.box)
                        .transition(.opacity)
                }
                if let problem = model.proxyProblem {
                    WarningLabel(problem)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Self.box)
                        .accessibilityIdentifier("add.proxy.problem")
                        .transition(.opacity)
                }
                VStack(spacing: 0) {
                    StepRow(number: 1, of: 3, mark: hotspot ? .done : .current, lineDone: hotspot,
                            title: "Join this iPhone's hotspot", id: "add.proxy.step1") {
                        if hotspot {
                            note("The hotspot is on. Join it on the new device too.")
                        } else {
                            HotspotWaitingHint(id: "add.proxy")
                                .font(.subheadline)
                        }
                    }
                    StepRow(number: 2, of: 3, mark: working ? .done : hotspot ? .current : .later, lineDone: working,
                            title: "In its Wi-Fi settings, set the proxy", id: "add.proxy.step2") {
                        if let blocked {
                            proxyBlocked(blocked)
                                .transition(.opacity)
                        } else {
                            proxySettings(ProxyAddress.servers(model.proxyStats.addresses))
                                .transition(.opacity)
                        }
                    }
                    StepRow(number: 3, of: 3, mark: working ? .done : hotspot && blocked == nil ? .waiting : .later, lineDone: nil,
                            title: "Open a page on it", id: "add.proxy.step3") {
                        // Nothing while it's off or paused: step 2 says why.
                        if working || blocked == nil {
                            note(working ? "Working" : "Waiting for the first page")
                                .accessibilityIdentifier("add.proxy.result")
                        }
                    }
                }

                if working {
                    proxyEnd
                        .transition(.opacity)
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Self.margin)
            .padding(.bottom, 24)
            .animation(motion, value: working)
            .animation(motion, value: hotspot)
            .animation(motion, value: blocked)
            .animation(motion, value: model.localNetworkDenied)
            .animation(motion, value: model.proxyProblem)
        }
        .paperBackground()
        .copiedToast($copied, id: "add.copied")
        .onDisappear { copied = false }
        .safeAreaInset(edge: .bottom) {
            VStack { if working {
                Button { dismiss() } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(InkCapsuleButtonStyle())
                .padding(.horizontal, Self.margin)
                .padding(.vertical, 8)
                .background(Theme.paper)
                .transition(.opacity)
                .accessibilityIdentifier("add.proxy.done")
            } }
            .animation(motion, value: working)
        }
        .navigationTitle("Use the proxy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { closeButton }
        .onAppear { proxyProgress = ProxyProgress(at: model.proxyStats) }
        .onChange(of: model.proxyStats) { _, stats in
            let was = proxyProgress?.working
            proxyProgress?.follow(stats)
            if was == false, proxyProgress?.working == true { AccessibilityNotification.Announcement("The proxy is working").post() }
        }
    }

    /// Why the proxy can't carry a page yet, and the button that turns it on or resumes it. At its data
    /// limit there's no button: Resume is on its screen, where its use shows.
    private func proxyBlocked(_ blocked: ProxyStatus.Blocked) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(blocked.text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("add.proxy.blocked")
            if let button = blocked.button {
                Button(button) { model.setProxy(on: true) }
                    .buttonStyle(InkCapsuleButtonStyle())
                    .accessibilityIdentifier("add.proxy.turnOn")
            }
        }
    }

    /// Once a page went through: the end of the proxy's steps, like Connected on the WireGuard ones.
    /// No name: the proxy's devices can't be told apart.
    private var proxyEnd: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Theme.live)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text("Working")
                    .accessibilityIdentifier("add.proxy.end")
            }
            .font(Self.titleFont)
            Text("It uses this iPhone's data now. Other devices can use the same server and port.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("add.proxy.endDetail")
        }
        .padding(.top, 12)
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
            Text(Copy.proxyIsOn)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("add.proxy.isOn")
            ProxyPlaces()
            // A Mac sets it for its Wi-Fi, not for one network, and Windows for every network.
            Text("A Mac or a Windows PC keeps the proxy on other networks too. Turn it off on that device when you leave this hotspot.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("add.proxy.turnOff")
        }
    }

    /// Under an IPv6 address: a computer with IPv6 off for the hotspot can't reach it (#94).
    private var ipv6Note: some View {
        Text("If neither opens, turn on IPv6 for the computer's Wi-Fi.")
            .font(.subheadline)
            .accessibilityIdentifier("add.ipv6")
    }

    /// How long the code and the shared file work, see `AddWindow`. Not under the
    /// page's address: a download from the page is listed at once, so it works on after that. A new
    /// config's code ends when the sheet closes, see `HotspotSession.closeAddWindow`.
    private func windowNote(id: String) -> some View {
        let minutes = Int(AddWindow.afterClose / 60)
        return Text(replacing == nil ? "Works while this screen is open, and for \(minutes) minutes after you close it or leave Tether."
                                     : "Works while this screen is open, and for \(minutes) minutes after you leave Tether. Closing this screen ends it.")
            // Secondary on paper passes the contrast audit, where grey on the old card didn't.
            .font(.subheadline)
            .foregroundStyle(Theme.secondary)
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
/// "Copied" (#175). A second tap starts the tick again. Given `copied`, the screen's Copied capsule
/// shows too, see `CopiedToast` (L4), and says it to VoiceOver instead. A tap while it shows still
/// says it, since the capsule doesn't come again.
struct CopyButton: View {
    let text: String
    /// What VoiceOver calls it, "Copy the address".
    let label: String
    /// Behind the icon: the card's colour on the sheet's paper, a fill on a list row.
    var fill = Theme.card
    /// The screen's `copiedToast`, nil for none.
    var copied: Binding<Bool>?
    @State private var ticked = false
    @State private var reset: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            ticked = true
            if let copied, !copied.wrappedValue {
                withAnimation(PaperMotion.change(reduceMotion: reduceMotion)) { copied.wrappedValue = true }
            } else {
                AccessibilityNotification.Announcement(Copy.copied).post()
            }
            reset?.cancel()
            reset = Task {
                guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                ticked = false
            }
        } label: {
            Image(systemName: ticked ? "checkmark" : "doc.on.doc")
                .font(.body.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: ticked)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .accessibilityLabel(label)
        .accessibilityValue(ticked ? Copy.copied : "")
    }
}

/// Where each kind of device sets the proxy, under Add a device's server and port (#78). The name
/// and the path side by side, or one under the other at the accessibility sizes.
struct ProxyPlaces: View {
    static let places = [
        ("iPhone, iPad", "Wi-Fi > (i) > Configure Proxy > Manual"),
        ("Mac", "Wi-Fi > Details > Proxies > Web and Secure Web"),
        ("Windows", "Settings > Network & internet > Proxy > Manual proxy setup"),
        ("Android", "Wi-Fi > network > Edit > Proxy > Manual"),
        ("PlayStation, Switch, TV", "In the network settings, Proxy"),
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

/// A kind of device at accessibility sizes: filled in ink like Done when chosen, an outline otherwise.
private struct KindButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(selected ? Theme.paper : Theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(selected ? Theme.ink : Color.clear, in: Capsule())
            .overlay { Capsule().strokeBorder(selected ? Theme.ink : Theme.secondary, lineWidth: 1.5) }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The one filled button of a page, Done or Continue: paper text on an ink capsule, so it keeps
/// its contrast in both modes (ink is light in dark mode). It grows with the text.
struct InkCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.paper)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.vertical, 4)
            .padding(.horizontal, 20)
            .background(Theme.ink, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// One step on the line: its mark, the title and what to do, and the line down to the next step,
/// in ink once this step is done. The last step has no line.
private struct StepRow<Content: View>: View {
    let number: Int
    /// How many steps the page has: four on the WireGuard way, three on the proxy's.
    let total: Int
    let mark: StepMark.Look
    /// Nil for the last step.
    let lineDone: Bool?
    let title: String
    let id: String
    @ViewBuilder let content: Content
    @ScaledMetric(relativeTo: .headline) private var markSize: CGFloat = 30

    init(number: Int, of total: Int, mark: StepMark.Look, lineDone: Bool?, title: String, id: String,
         @ViewBuilder content: () -> Content) {
        self.number = number
        self.total = total
        self.mark = mark
        self.lineDone = lineDone
        self.title = title
        self.id = id
        self.content = content()
    }
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
                .font(.title3)
                // A step not reached yet is in the secondary colour.
                .foregroundStyle(mark == .later ? Theme.secondary : Theme.ink)
                // The step's number and state are read with its title, as one stop (#175).
                .accessibilityLabel("Step \(number) of \(total), \(title)")
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
                        .fill(lineDone ? Theme.ink : Theme.secondary.opacity(0.3))
                        .frame(width: 2)
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
/// with the cursor at the end. One modifier serves the sheet's field and the field in Rename's alert.
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

/// A step's mark: a paper tick on ink when done, the number in an ink ring for the current step
/// (three dots while it waits for the device), and a secondary ring for the steps after it. Still
/// marks: a spinner would turn for as long as the device takes, and the waiting is said in words.
private struct StepMark: View {
    enum Look { case done, current, waiting, later }
    let number: Int
    let state: Look

    var body: some View {
        ZStack {
            switch state {
            case .done:
                ZStack {
                    Circle().fill(Theme.ink)
                    Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(Theme.paper)
                }
                .transition(.opacity)
            case .current:
                ZStack {
                    Circle().strokeBorder(Theme.ink, lineWidth: 1.5)
                    Text("\(number)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                }
                .transition(.opacity)
            case .waiting:
                ZStack {
                    Circle().strokeBorder(Theme.ink, lineWidth: 1.5)
                    Image(systemName: "ellipsis").font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                }
                .transition(.opacity)
            case .later:
                ZStack {
                    Circle().strokeBorder(Theme.secondary, lineWidth: 1.5)
                    Text("\(number)").font(.subheadline).foregroundStyle(Theme.secondary)
                }
                .transition(.opacity)
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
