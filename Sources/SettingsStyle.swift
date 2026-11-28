import SwiftUI

// The paper and ink pieces Settings and Diagnostics share (#349). They could move into Theme.swift
// once the other screens settle on the same ones.

/// A screen's large light title, the first row of its list. The navigation bar keeps the same title
/// for VoiceOver's screen change and the UI tests, but doesn't show it (see `paperNavigationBar`).
struct PaperTitle: View {
    let title: String
    /// 52 points at the default text size, and larger with Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 52

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: size, weight: .light))
            .tracking(-1.2)
            .foregroundStyle(Theme.ink)
            // One word: at the largest text sizes it shrinks to fit, rather than break inside the word.
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 8, trailing: 20))
            .paperRow()
    }
}

/// A row's title after a dash in the secondary colour. VoiceOver and the UI tests read only the title.
struct DashLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("–")
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(Theme.ink)
        }
    }
}

/// A section's title in ink, as text the UI tests find as written, with an (i) when the section
/// has help behind it.
struct PaperHeader: View {
    let title: String
    var help: Binding<Bool>?
    /// For the (i): `<id>.info`.
    var id: String = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let help {
                Button {
                    withAnimation(PaperMotion.change(reduceMotion: reduceMotion)) { help.wrappedValue.toggle() }
                } label: {
                    Image(systemName: help.wrappedValue ? "info.circle.fill" : "info.circle")
                        .font(.body)
                        .foregroundStyle(Theme.ink)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About \(title)")
                .accessibilityValue(help.wrappedValue ? "Shown" : "Hidden")
                .accessibilityIdentifier("\(id).info")
            }
        }
        .textCase(nil)
        .padding(.top, 8)
    }
}

/// Help text in the secondary colour, shown under a section's title once its (i) is tapped.
struct PaperHelp: View {
    let text: String
    let id: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(id)
            .paperRow()
    }
}

/// The one ease every change on these screens uses. A List animates its own rows coming and going
/// and ignores a row's `.transition`, so with Reduce Motion rows come and go at once instead.
enum PaperMotion {
    static let change: Animation = .easeInOut(duration: 0.25)

    static func change(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : change
    }
}

extension View {
    /// The bar of a paper screen: no visible title (the list's `PaperTitle` shows it) and no bar
    /// background, so the paper and its dots run up to the top. `navigationTitle` still names the
    /// screen for VoiceOver and the UI tests.
    func paperNavigationBar(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}
