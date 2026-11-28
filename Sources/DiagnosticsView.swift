import SwiftUI
import UIKit

/// Settings > Diagnostics (#256): the server's counters, read each second, see `Diagnostics`. A tap
/// on a row, or Copy in its menu, copies its value, and Copy all copies every row with what this
/// build, iOS and iPhone are (L5). Each copy says so the same way as the other screens (L4).
struct DiagnosticsView: View {
    @ObservedObject var model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied: Date?
    /// The room under the list for the Copied capsule, grown with the text like the capsule.
    @ScaledMetric(relativeTo: .subheadline) private var copiedRoom: CGFloat = 72

    var body: some View {
        // The counters change at most once a second, here. Each value animates only when it changed.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let sections = Diagnostics.sections(model.serverDiagnostics, sharing: model.sharing)
            List {
                PaperTitle("Diagnostics")
                Section {
                    Button { copy(Diagnostics.all(sections, header: Model.logHeader)) } label: {
                        DashLabel("Copy all")
                    }
                    .foregroundStyle(Theme.ink)
                    .accessibilityHint("Copies every row, for a bug report")
                    .accessibilityIdentifier("diagnostics.copyAll")
                }
                .paperRow()
                ForEach(sections) { section in
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
            .listSectionSpacing(.compact)
            .paperList()
            // Room under the last row, so "Copied" doesn't cover it.
            .contentMargins(.bottom, copiedRoom, for: .scrollContent)
        }
        .copiedToast($copied, id: "diagnostics.copied")
        .paperNavigationBar("Diagnostics")
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        // The toast announces each copy, and a copy while it shows starts its time again.
        withAnimation(PaperMotion.change) { copied = Date() }
    }

    private func row(_ row: Diagnostics.Row) -> some View {
        Button { copy(row.value) } label: {
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
            Button("Copy", systemImage: "doc.on.doc") { copy(row.value) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Copies the value")
        .accessibilityIdentifier("diagnostics.\(row.id)")
    }
}
