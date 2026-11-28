import SwiftUI

// The pieces a device's screen and the proxy's screen share in the paper and ink look (#349).

/// The big light name on top of the screen, with the live dot while something is connected. The
/// status itself is a text under it, so the dot is never the only sign.
struct DeviceScreenTitle: View {
    let name: String
    let live: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 52
    @ScaledMetric(relativeTo: .largeTitle) private var dot: CGFloat = 10

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
                .font(.system(size: size, weight: .light))
                .tracking(-1.2)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if live {
                Circle()
                    .fill(Theme.live)
                    .frame(width: dot, height: dot)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A problem on one of these screens. Problems use words, not a second colour, so the icon is ink.
/// Same shape as `WarningLabel`, which the other screens still use: the icon carries the identifier too.
struct InkWarningLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text).foregroundStyle(Theme.ink)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.ink)
                .accessibilityHidden(true)
        }
    }
}

/// The paper look's outlined button, like Pause on the board: ink edge, ink text.
struct InkOutline: View {
    let title: String

    var body: some View {
        Text(title)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.ink, lineWidth: 1) }
            .contentShape(.rect)
    }
}

/// The motion of these two screens, on top of `PaperMotion`: a state change eases in 0.25 s, and only
/// when a value changes. With Reduce Motion nothing moves: rows appear in place, and words only fade.
enum DeviceScreenMotion {
    /// A line that comes and goes inside a row. List animates whole rows itself. With Reduce Motion
    /// the animation is nil, so the line appears in place.
    static let appear = AnyTransition.opacity.combined(with: .move(edge: .top))
}

extension View {
    /// A text that changes: numbers roll, words cross-fade. With Reduce Motion only a fade.
    func deviceScreenChange<Value: Equatable>(_ value: Value, numbers: Bool = false, reduceMotion: Bool) -> some View {
        contentTransition(numbers && !reduceMotion ? .numericText() : .opacity)
            .animation(PaperMotion.change, value: value)
    }
}

// MARK: Shared by a device's screen and the proxy's (M4)

/// What it used this period in the floating card, counted the way the main screen counts (#75): the
/// period as a small label, the use as a big number, and with a limit a meter against it and when
/// the count resets. Down and up under it once there's any. Nothing used says so in words (M4).
/// VoiceOver reads the card as one line. The caller gives it its identifier.
struct UsageCard: View {
    let month: TrafficTotals
    let limit: UInt64?
    /// "this month", see `Model.usagePeriod`.
    let period: String
    /// "November 1", see `Model.nextResetDay`.
    let resets: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let used = month.total
        Group {
            if let limit {
                VStack(alignment: .leading, spacing: 10) {
                    Text(period).monoCaps()
                    bigNumber(Format.bytes(used), of: " of \(Format.bytes(limit))")
                    if used > 0 { downAndUp }
                    let fraction = limit == 0 ? 1 : min(1, Double(used) / Double(limit))
                    // Keyed on whole percents, so a traffic sample that doesn't move the line doesn't animate.
                    LimitMeter(fraction: fraction)
                        .animation(PaperMotion.change(reduceMotion: reduceMotion), value: Int(fraction * 100))
                    Text("Resets on \(resets)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(["\(Format.bytes(used)) of \(Format.bytes(limit)) \(period)",
                                            used > 0 ? downAndUpSpoken : nil, "Resets on \(resets)"]))
            } else if used == 0 {
                Text(Format.used(0, period))
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(period).monoCaps()
                    bigNumber(Format.bytes(used), of: nil)
                    downAndUp
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(["\(Format.bytes(used)) \(period)", downAndUpSpoken]))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liveCard()
    }

    /// "3.12 GB" big, with " of 10 GB" after it in the second colour. The number rolls as it grows.
    private func bigNumber(_ number: String, of rest: String?) -> some View {
        // One text, so it wraps with large text instead of squeezing the number.
        Text("\(Text(number).font(.largeTitle.weight(.medium)).foregroundStyle(Theme.ink))\(Text(rest ?? "").font(.subheadline).foregroundStyle(Theme.secondary))")
            .fixedSize(horizontal: false, vertical: true)
            .deviceScreenChange(number + (rest ?? ""), numbers: true, reduceMotion: reduceMotion)
    }

    /// "↓ 3 GB ↑ 120 MB", which VoiceOver reads as "3 GB down, 120 MB up" rather than the arrows.
    private var downAndUp: some View {
        let down = Format.bytes(month.bytesDown), up = Format.bytes(month.bytesUp)
        return Text("↓ \(down) ↑ \(up)")
            .font(.subheadline)
            .foregroundStyle(Theme.secondary)
            .deviceScreenChange("\(down) \(up)", numbers: true, reduceMotion: reduceMotion)
            .accessibilityLabel(downAndUpSpoken)
    }

    private var downAndUpSpoken: String {
        "\(Format.bytes(month.bytesDown)) down, \(Format.bytes(month.bytesUp)) up"
    }

    /// The card's lines as VoiceOver reads them, the way a combined element joins its texts.
    private func spoken(_ lines: [String?]) -> String {
        lines.compactMap { $0 }.joined(separator: ", ")
    }
}

/// This month's data against the limit: a thin ink line on a faint track, like the board. At the
/// limit the line is full, and the words under the card say what that means.
private struct LimitMeter: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.dot)
                Rectangle()
                    .fill(Theme.ink)
                    .frame(width: max(3, geometry.size.width * fraction))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// Under the status: Pause, outlined in ink, which asks how long as Do Not Disturb does (#312), or
/// Resume once it's paused, filled in ink since it's the main action then. Both sit in the same place.
/// `id` is "device" or "proxy": `<id>.pause` and `<id>.resume`.
struct PauseSection: View {
    let paused: Bool
    let id: String
    let footer: String
    let pause: (WireGuardSetup.PauseLength) -> Void
    let resume: () -> Void

    var body: some View {
        if paused {
            Section {
                Button(action: resume) {
                    Text("Resume")
                        .font(.headline)
                        .foregroundStyle(Theme.paper)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.ink, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(id).resume")
            }
            .paperRow()
            .listRowInsets(EdgeInsets())
        } else {
            Section {
                Menu {
                    // The last one is the pause it always was.
                    ForEach(WireGuardSetup.PauseLength.allCases, id: \.self) { length in
                        Button(length.title) { pause(length) }
                    }
                } label: {
                    // The whole row opens it, as the button it replaced did.
                    InkOutline(title: "Pause")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("\(id).pause")
            } footer: {
                Text(footer)
                    .foregroundStyle(Theme.secondary)
            }
            .paperRow()
        }
    }
}

/// A choice in a device's Data limit menu, and the proxy's.
enum LimitPick: Hashable {
    case preset(UInt64?)
    case other

    /// The menu's choices, with a typed amount `limit` is, then Other amount.
    static func picks(_ limit: UInt64?) -> [LimitPick] {
        var picks = DataLimit.choices.map(LimitPick.preset)
        if let limit, !DataLimit.choices.contains(limit) { picks.append(.preset(limit)) }
        return picks + [.other]
    }
}

/// The questions around a Data limit: the amount typed under Other, and before a limit that pauses
/// it at once, whether to (L1). One per screen, kept by the screen and shown by `dataLimitQuestions`.
struct LimitQuestions {
    /// Other amount was picked: the alert asks for GB.
    var typing = false
    var typed = ""
    /// A limit that would pause it now, until it's confirmed or cancelled.
    var confirming: UInt64?
}

/// A device's or the proxy's Data limit, as one: the menu, and what it asks before a limit counts.
struct DataLimitChoice {
    let name: String
    let limit: UInt64?
    let paused: WireGuardSetup.Pause?
    let used: UInt64
    let resets: String
    let set: (UInt64?) -> Void

    /// A picked or typed limit: set at once, or asked about first when it would pause it now (L1).
    func choose(_ new: UInt64?, _ questions: inout LimitQuestions) {
        if let new, LimitRules.pausesNow(new, current: limit, used: used, paused: paused) {
            questions.confirming = new
        } else {
            set(new)
        }
    }
}

/// The Data limit menu: None, 5, 10, 20, 50 GB, a typed amount it has, and Other amount.
struct DataLimitPicker: View {
    let choice: DataLimitChoice
    @Binding var questions: LimitQuestions
    let id: String

    var body: some View {
        Picker(selection: Binding(get: { LimitPick.preset(choice.limit) }, set: { pick in
            switch pick {
            case let .preset(limit): choice.choose(limit, &questions)
            case .other:
                questions.typed = ""
                questions.typing = true
            }
        })) {
            ForEach(LimitPick.picks(choice.limit), id: \.self) { pick in
                switch pick {
                case let .preset(limit): Text(DataLimit.label(limit)).tag(pick)
                case .other: Text("Other amount").tag(pick)
                }
            }
        } label: {
            DashLabel(Copy.dataLimit)
        }
        .pickerStyle(.menu)
        .tint(Theme.secondary)
        .accessibilityIdentifier(id)
    }
}

extension View {
    /// The alert that asks for a typed amount, and the one before a limit that pauses it at once
    /// (L1). On the list, not on the menu's row, where a List can drop them.
    func dataLimitQuestions(_ questions: Binding<LimitQuestions>, _ choice: DataLimitChoice) -> some View {
        alert("Data limit", isPresented: questions.typing) {
            TextField("GB", text: questions.typed)
                .keyboardType(.decimalPad)
            Button("Set") {
                if let bytes = DataLimit.bytes(typedGB: questions.wrappedValue.typed) { choice.choose(bytes, &questions.wrappedValue) }
            }
            // Nothing to set until it's an amount, rather than closing as if it were.
            .disabled(DataLimit.bytes(typedGB: questions.wrappedValue.typed) == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Per month, both ways, in GB.")
        }
        .alert(questions.wrappedValue.confirming.map {
            LimitRules.PausesNowQuestion(name: choice.name, used: choice.used, limit: $0, resets: choice.resets).title
        } ?? "", isPresented: Binding(get: { questions.wrappedValue.confirming != nil },
                                      set: { if !$0 { questions.wrappedValue.confirming = nil } }),
        presenting: questions.wrappedValue.confirming) { limit in
            Button(LimitRules.PausesNowQuestion.confirm, role: .destructive) { choice.set(limit) }
            Button("Cancel", role: .cancel) {}
        } message: { limit in
            Text(LimitRules.PausesNowQuestion(name: choice.name, used: choice.used, limit: limit, resets: choice.resets).message)
        }
    }
}
