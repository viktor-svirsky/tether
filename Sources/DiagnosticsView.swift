import SwiftUI
import UIKit

/// Settings > Diagnostics (#256): the server's counters, read each second, see `Diagnostics`. A tap
/// on a row copies its value, and says so for a moment.
struct DiagnosticsView: View {
    @ObservedObject var model: Model
    /// The value just copied, shown at the bottom until it goes.
    @State private var copied: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            List {
                ForEach(Diagnostics.sections(model.serverDiagnostics)) { section in
                    Section {
                        ForEach(section.rows) { row($0) }
                    } header: {
                        Text(section.title)
                    } footer: {
                        Text(section.footer)
                            // In the label colour, like Settings' footers: the grey just misses the contrast audit.
                            .foregroundStyle(Color(.label))
                            .accessibilityIdentifier("diagnostics.\(section.id)Footer")
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let copied {
                Text("Copied \(copied)")
                    .font(.subheadline)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .accessibilityIdentifier("diagnostics.copied")
            }
        }
        .task(id: copied) {
            guard copied != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = nil }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ row: Diagnostics.Row) -> some View {
        Button {
            UIPasteboard.general.string = row.value
            copied = row.value
            AccessibilityNotification.Announcement("Copied").post()
        } label: {
            if row.wide {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                    Text(row.value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent(row.title, value: row.value)
            }
        }
        // A row, not a link: the title in the text colour.
        .foregroundStyle(Color(.label))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Copies the value")
        .accessibilityIdentifier("diagnostics.\(row.id)")
    }
}
