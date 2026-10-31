import SwiftUI
import WidgetKit

@main
struct GroveWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        GroveTodayWidget()
    }
}

struct GroveTodayWidget: Widget {
    private let kind = "GroveTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GroveTimelineProvider()) { entry in
            GroveWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Grove Today")
        .description("See care due today and your current streak.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct GroveWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchSnapshot?
}

struct GroveTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> GroveWidgetEntry {
        GroveWidgetEntry(date: .now, snapshot: Self.placeholderSnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (GroveWidgetEntry) -> Void) {
        completion(GroveWidgetEntry(date: .now, snapshot: WatchSnapshotWidgetStore.load() ?? Self.placeholderSnapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GroveWidgetEntry>) -> Void) {
        let now = Date.now
        let snapshot = WatchSnapshotWidgetStore.load()
        let refresh = nextRefresh(after: now, snapshot: snapshot)
        completion(Timeline(entries: [GroveWidgetEntry(date: now, snapshot: snapshot)], policy: .after(refresh)))
    }

    private func nextRefresh(after date: Date, snapshot: WatchSnapshot?) -> Date {
        let calendar = Calendar.current
        let midnight = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: date)
        ) ?? date.addingTimeInterval(60 * 60)
        let nextTask = snapshot?.tasks
            .map(\.dueDate)
            .filter { $0 > date }
            .min()
        return min(midnight, nextTask ?? midnight)
    }

    private static let placeholderSnapshot = WatchSnapshot(
        generatedAt: .now,
        streak: 8,
        streakIsShielded: false,
        plants: [],
        tasks: [
            WatchTaskSummary(
                id: UUID(),
                plantID: UUID(),
                kind: .inspectSoil,
                dueDate: .now,
                detail: "",
                isSittingTask: false
            ),
        ]
    )
}

private struct GroveWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GroveWidgetEntry

    private var dueCount: Int {
        entry.snapshot?.dueTasks(at: entry.date).count ?? 0
    }

    private var streak: Int { entry.snapshot?.streak ?? 0 }

    private var isStale: Bool {
        WatchComplicationCopy.isStale(snapshot: entry.snapshot, now: entry.date)
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(inlineTitle, systemImage: statusIcon)

        case .accessoryCircular:
            VStack(spacing: 0) {
                Image(systemName: statusIcon)
                    .font(.caption)
                Text(entry.snapshot == nil ? "–" : "\(dueCount)")
                    .font(.title3.bold())
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityStatus)

        default:
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(primaryTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if entry.snapshot == nil || isStale {
                        Text(freshness)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if streak > 0 {
                        Label("\(streak)-day streak", systemImage: "flame.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(freshness)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var inlineTitle: String {
        WatchComplicationCopy.inlineTitle(
            snapshot: entry.snapshot,
            dueCount: dueCount,
            streak: streak,
            now: entry.date
        )
    }

    private var primaryTitle: String {
        WatchComplicationCopy.primaryTitle(
            snapshot: entry.snapshot,
            dueCount: dueCount,
            streak: streak,
            now: entry.date
        )
    }

    private var statusIcon: String {
        guard let snapshot = entry.snapshot else { return "iphone" }
        if dueCount == 0,
           WatchTodayEmptyState.resolve(snapshot: snapshot, now: entry.date) == .noPlants {
            return "leaf"
        }
        if isStale { return "arrow.triangle.2.circlepath" }
        return dueCount == 0 ? "leaf.fill" : "checklist"
    }

    private var accessibilityStatus: String {
        WatchComplicationCopy.accessibilityStatus(
            snapshot: entry.snapshot,
            dueCount: dueCount,
            now: entry.date
        )
    }

    private var freshness: String {
        guard let generatedAt = entry.snapshot?.generatedAt else { return "Open Grove to sync" }
        return "Updated \(generatedAt.formatted(.relative(presentation: .named)))"
    }
}
