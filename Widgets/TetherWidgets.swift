import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct TetherWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        TetherLiveActivity()
        if #available(iOS 18, *) { TetherControl() }
    }
}

// MARK: Home and Lock Screen

struct StatusEntry: TimelineEntry {
    let date: Date
    let state: WidgetState
}

/// One entry, from what the app wrote.
struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), state: WidgetState(sharing: true, awake: true, connected: [WidgetState.Device(id: UUID(), name: "MacBook")], vpn: true))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : StatusEntry(date: Date(), state: .load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // The app asks for a new one when something changes. While Tether is awake the widget also
        // looks again by itself, rarely, in case iOS closed Tether, which nothing announces.
        let now = Date()
        let state = WidgetState.load(now: now)
        completion(Timeline(entries: [StatusEntry(date: now, state: state)],
                            policy: state.awake ? .after(now.addingTimeInterval(WidgetState.lookAgainAfter)) : .never))
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TetherStatus", provider: StatusProvider()) { entry in
            StatusView(state: entry.state)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Tether")
        .description("Whether Tether is sharing, the connected devices, and Start or Stop.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct StatusView: View {
    let state: WidgetState
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: icon)
                    Text("\(state.connected.count)").font(.headline)
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Label(state.title, systemImage: icon).font(.headline)
                Text(state.detail).font(.caption)
            }
        default:
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(state.sharing && !state.blockedWithoutVPN ? .green : .secondary)
                    Text(state.title).font(.headline)
                    Text(state.detail).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(intent: SetSharingIntent(!state.awake, fromWidget: true)) {
                        Text(state.awake ? "Stop" : "Start").frame(maxWidth: .infinity)
                    }
                    .tint(state.awake ? .red : .green)
                }
                if family == .systemMedium {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.connected.prefix(4)) { Label($0.name, systemImage: "laptopcomputer").font(.caption).privacySensitive() }
                        if state.connected.isEmpty, state.sharing { Text("No device connected").font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var icon: String {
        if state.sharing, state.blockedWithoutVPN { return "lock.shield" }
        return state.sharing ? "link.circle.fill" : "link.circle"
    }
}

// MARK: Control Center

@available(iOS 18, *)
struct TetherControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TetherControl", provider: Provider()) { awake in
            ControlWidgetToggle("Tether", isOn: awake, action: SetSharingIntent()) { on in
                Label(on ? "On" : "Off", systemImage: on ? "link.circle.fill" : "link.circle")
            }
        }
        .displayName("Tether")
        .description("Start or stop Tether.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }
        func currentValue() async throws -> Bool { WidgetState.load().awake }
    }
}

// MARK: Live Activity

struct TetherLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TetherActivityAttributes.self) { context in
            HStack {
                Image(systemName: context.state.blockedWithoutVPN ? "lock.shield" : "link.circle.fill")
                    .font(.title2)
                    .foregroundStyle(context.state.blockedWithoutVPN ? .orange : .green)
                VStack(alignment: .leading) {
                    Text(context.isStale ? "Open Tether to check" : headline(context.state)).font(.headline)
                    if !context.isStale {
                        Text(names(context.state)).font(.caption).foregroundStyle(.secondary).privacySensitive()
                    }
                }
                Spacer()
                if !context.isStale { Text(context.state.vpn ? "VPN" : "No VPN").font(.caption.bold()) }
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Tether", systemImage: "link.circle.fill").foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.isStale { Text(context.state.vpn ? "VPN" : "No VPN").font(.caption.bold()) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "Open Tether to check" : "\(headline(context.state)) · \(names(context.state))")
                        .font(.caption).privacySensitive()
                }
            } compactLeading: {
                Image(systemName: "link").foregroundStyle(.green)
            } compactTrailing: {
                // Not a count nobody has stood by since: Tether may be gone, see `activityFreshFor`.
                Text(context.isStale ? "?" : "\(context.state.count)")
            } minimal: {
                Image(systemName: "link").foregroundStyle(.green)
            }
        }
    }

    private func headline(_ state: TetherActivityAttributes.ContentState) -> String {
        WidgetState.activityHeadline(sharing: state.sharing, count: state.count, blockedWithoutVPN: state.blockedWithoutVPN, problem: state.problem)
    }

    private func names(_ state: TetherActivityAttributes.ContentState) -> String {
        WidgetState.activityLine(sharing: state.sharing, count: state.count, names: state.connected, problem: state.problem)
    }
}
