import SwiftUI
import UIKit

/// Settings > Diagnostics (#256): the server's counters, read each second, see `Diagnostics`. A tap
/// on a row, or Copy in its menu, copies its value, and says so for a moment.
struct DiagnosticsView: View {
    @ObservedObject var model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A value was just copied: "Copied" shows at the bottom for a moment. Not the value, which is
    /// on the row, and a long one would cover it.
    @State private var copied = false

    /// How long "Copied" shows, in seconds. A UI test under load can take longer than 2 s to look
    /// after a menu closes, so in a Debug build it can pass `-diagnostics.copiedShownFor <s>`.
    private static var copiedShownFor: Double {
        #if DEBUG
        let s = UserDefaults.standard.double(forKey: "diagnostics.copiedShownFor")
        if s > 0 { return s }
        #endif
        return 2
    }

    var body: some View {
        // The counters change at most once a second, here. Each value animates only when it changed.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            List {
                PaperTitle("Diagnostics")
                ForEach(Diagnostics.sections(model.serverDiagnostics, sharing: model.sharing)) { section in
                    Section {
                        ForEach(section.rows) { row($0) }
                    } header: {
                        PaperHeader(title: section.title)
                    } footer: {
                        // Not behind an (i): when not sharing, this says why every count is 0.
                        if !section.footer.isEmpty {
                            Text(section.footer)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                                .accessibilityIdentifier("diagnostics.\(section.id)Footer")
                        }
                    }
                    .paperRow()
                }
            }
            .listStyle(.grouped)
            .paperList()
        }
        .overlay(alignment: .bottom) {
            if copied {
                Text("Copied")
                    .font(.subheadline)
                    .foregroundStyle(Theme.paper)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.ink, in: Capsule())
                    .padding()
                    .accessibilityIdentifier("diagnostics.copied")
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(Self.copiedShownFor))
            if !Task.isCancelled { withAnimation(PaperMotion.change) { copied = false } }
        }
        .paperNavigationBar("Diagnostics")
    }

    private func copy(_ row: Diagnostics.Row) {
        UIPasteboard.general.string = row.value
        withAnimation(PaperMotion.change) { copied = true }
        AccessibilityNotification.Announcement("Copied").post()
    }

    private func row(_ row: Diagnostics.Row) -> some View {
        Button { copy(row) } label: {
            if row.wide {
                VStack(alignment: .leading, spacing: 2) {
                    DashLabel(row.title)
                    // Breaks after each ":", so the largest text doesn't split an address mid-number.
                    AddressText(row.value)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
            } else {
                LabeledContent {
                    // The digits roll to the new count, and only when it changed: the animation adds
                    // no redraw of its own. With Reduce Motion they fade.
                    Text(row.value)
                        .foregroundStyle(Theme.secondary)
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                        .animation(PaperMotion.change, value: row.value)
                } label: {
                    DashLabel(row.title)
                }
            }
        }
        // A row, not a link: the title in ink.
        .foregroundStyle(Theme.ink)
        // A long press has Copy too, the way iOS copies elsewhere.
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copy(row) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Copies the value")
        .accessibilityIdentifier("diagnostics.\(row.id)")
    }
}
