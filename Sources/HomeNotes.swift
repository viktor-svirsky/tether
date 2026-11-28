import SwiftUI

/// The warnings and notes between the status card and Devices (M13), in `HomeNote`'s order: one or
/// two all show, three or more show the first and a link to the rest. A warning goes by itself once
/// it's no longer true. A note stays until "Got it" (H3, M11), and the one that offers notifications
/// until it's answered (M7).
struct HomeNotesSection: View {
    @ObservedObject var model: Model
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fold = HomeNote.fold(model.homeNotes, expanded: expanded)
        ForEach(fold.shown) { note in
            Section {
                HomeNoteRow(model: model, note: note, animate: animate)
                if let more = fold.more, note == fold.shown.last {
                    Button { animate { expanded = true } } label: {
                        Text(more)
                            .font(.subheadline)
                            .underline()
                            .foregroundStyle(Theme.ink)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    // Plain, or a tap anywhere in the row opens them.
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the other notes")
                    .accessibilityIdentifier("notes.more")
                }
            }
            .paperRow()
            .transition(.opacity)
        }
        // Folded again the next time there are three or more.
        .onChange(of: model.homeNotes.count) { _, count in
            if count < 3 { expanded = false }
        }
    }

    /// A tap's change eases like the list's, or happens at once under Reduce Motion.
    private func animate(_ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(.easeInOut(duration: 0.3), change) }
    }
}

/// One warning or note: its mark and its words, in ink, and a note's links under them.
private struct HomeNoteRow: View {
    @ObservedObject var model: Model
    let note: HomeNote
    let animate: (() -> Void) -> Void

    var body: some View {
        // The links inside the label, so they line up with the words they answer, not the mark.
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.text(of: note))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(note.id)
                if note == .offerNotifications {
                    // Side by side, or one under the other where the text is too big for that.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) { notificationLinks }
                        VStack(alignment: .leading, spacing: 0) { notificationLinks }
                    }
                } else if note.isNote {
                    link(Copy.gotIt, id: "\(note.id).gotIt") { model.dismiss(note) }
                }
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(note.isNote ? Theme.secondary : Theme.danger)
                .accessibilityHidden(true) // the words say it, and iOS 26 would read the symbol
        }
    }

    @ViewBuilder private var notificationLinks: some View {
        link(Copy.allowNotifications, id: "\(note.id).allow") { model.allowNotificationsFromNote() }
        link(Copy.notNow, id: "\(note.id).notNow") { model.dismiss(note) }
    }

    private var icon: String {
        switch note {
        case .lowBattery: "battery.25percent"
        case .staleConfig, .expiry: "exclamationmark.triangle.fill"
        case .lastStop: "stop.circle"
        case .stopIgnored: "hand.raised"
        case .offerNotifications: "bell"
        }
    }

    private func link(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button { animate(action) } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .underline()
                .foregroundStyle(Theme.ink)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        // Plain, so each link is its own tap target in the row.
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
