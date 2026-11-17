import SwiftUI
import UIKit

/// Settings > Diagnostics (#256): the server's counters, read each second, see `Diagnostics`. A tap
/// on a row, or Copy in its menu, copies its value, and says so for a moment.
struct DiagnosticsView: View {
    @ObservedObject var model: Model
    /// A value was just copied: "Copied" shows at the bottom for a moment. Not the value, which is
    /// on the row, and a long one would cover it.
    @State private var copied = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            List {
                ForEach(Diagnostics.sections(model.serverDiagnostics, sharing: model.sharing)) { section in
                    Section {
                        ForEach(section.rows) { row($0) }
                    } header: {
                        Text(section.title)
                    } footer: {
                        if !section.footer.isEmpty {
                            Text(section.footer)
                                // In the label colour, like Settings' footers: the grey just misses the contrast audit.
                                .foregroundStyle(Color(.label))
                                .accessibilityIdentifier("diagnostics.\(section.id)Footer")
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if copied {
                Text("Copied")
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .accessibilityIdentifier("diagnostics.copied")
            }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func copy(_ row: Diagnostics.Row) {
        UIPasteboard.general.string = row.value
        copied = true
        AccessibilityNotification.Announcement("Copied").post()
    }

    private func row(_ row: Diagnostics.Row) -> some View {
        Button { copy(row) } label: {
            if row.wide {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                    // Breaks after each ":", so the largest text doesn't split an address mid-number.
                    AddressText(row.value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent(row.title, value: row.value)
            }
        }
        // A row, not a link: the title in the text colour.
        .foregroundStyle(Color(.label))
        // A long press has Copy too, the way iOS copies elsewhere.
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copy(row) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Copies the value")
        .accessibilityIdentifier("diagnostics.\(row.id)")
    }
}
