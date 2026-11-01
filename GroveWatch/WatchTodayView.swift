import SwiftUI

/// The day's work, wrist-sized: the streak holding, then every task that is
/// due or overdue. Rows push to a detail whose one button logs the care —
/// completing from a glance without reading the instruction would invite the
/// blind watering "check, then act" exists to prevent.
struct WatchTodayView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Group {
                    if store.dueTasks(at: context.date).isEmpty {
                        emptyState(at: context.date)
                    } else {
                        taskList(tasks: store.dueTasks(at: context.date))
                    }
                }
            }
            .navigationTitle("Today")
            .navigationDestination(for: WatchTaskSummary.self) { task in
                WatchTaskDetailView(task: task)
            }
        }
    }

    private func taskList(tasks: [WatchTaskSummary]) -> some View {
        List {
            if store.streak > 0 {
                WatchStreakRow(streak: store.streak, isShielded: store.streakIsShielded)
            }
            ForEach(tasks) { task in
                NavigationLink(value: task) {
                    WatchTaskRow(task: task, plant: store.plant(id: task.plantID))
                }
            }
            if store.pendingCompletionCount > 0 {
                Label(
                    store.pendingCompletionCount == 1 ? "Sending 1 completion…" : "Sending \(store.pendingCompletionCount) completions…",
                    systemImage: "clock"
                )
                .font(.footnote)
                .foregroundStyle(WatchTheme.mutedInk)
                .listRowBackground(Color.clear)
            }
            if let staleNote {
                Text(staleNote)
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.subtleInk)
                    .listRowBackground(Color.clear)
            }
        }
    }

    /// Nothing due is three different situations, and only one of them earns
    /// "All tended": an empty grove has nothing to tend, and a stale queue may
    /// be hiding a plant that is drying out.
    @ViewBuilder
    private func emptyState(at date: Date) -> some View {
        let state = store.todayEmptyState(at: date)
        VStack(spacing: 8) {
            switch state {
            case .allTended:
                Image(systemName: "leaf.fill")
                    .font(.title2)
                    .foregroundStyle(WatchTheme.accent)
                Text(store.pendingCompletionCount > 0 ? "Sending completion…" : "All tended")
                    .font(.headline)
                    .accessibilityIdentifier("watchTodayAllTended")
                nextCareLine
                streakLine
            case .noPlants:
                Image(systemName: "leaf")
                    .font(.title2)
                    .foregroundStyle(WatchTheme.accent)
                Text("No plants yet")
                    .font(.headline)
                    .accessibilityIdentifier("watchTodayNoPlants")
                Text("Add a plant in Grove on your iPhone.")
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.mutedInk)
                    .multilineTextAlignment(.center)
            case .stale(let since):
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundStyle(WatchTheme.warning)
                Text("Not up to date")
                    .font(.headline)
                    .accessibilityIdentifier("watchTodayStale")
                Text("Last synced \(since.formatted(.relative(presentation: .named))). Open Grove on your iPhone to refresh.")
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.mutedInk)
                    .multilineTextAlignment(.center)
                nextCareLine
                streakLine
            }
        }
        .scenePadding()
    }

    /// The next thing worth knowing on a day with nothing due.
    @ViewBuilder
    private var nextCareLine: some View {
        if let task = store.nextTask, let plant = store.plant(id: task.plantID) {
            Text("\(task.kind.title) for \(plant.nickname) \(task.dueDate.formatted(.relative(presentation: .named)))")
                .font(.footnote)
                .foregroundStyle(WatchTheme.mutedInk)
                .multilineTextAlignment(.center)
        } else if let next = store.nextUp {
            Text("\(next.nickname)'s check-in \(next.nextCheckIn.formatted(.relative(presentation: .named)))")
                .font(.footnote)
                .foregroundStyle(WatchTheme.mutedInk)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var streakLine: some View {
        if store.streak > 0 {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(WatchTheme.streak)
                Text("\(store.streak)-day streak")
                    .foregroundStyle(WatchTheme.mutedInk)
            }
            .font(.footnote)
            .padding(.top, 4)
        }
    }

    /// Quiet honesty when the phone hasn't spoken for a while — the queue on
    /// screen may not be the queue that exists.
    private var staleNote: String? {
        guard let updatedAt = store.updatedAt,
              updatedAt < Date.now.addingTimeInterval(-WatchTodayEmptyState.staleAfter) else { return nil }
        return "Updated \(updatedAt.formatted(.relative(presentation: .named)))"
    }
}

/// One due task: what plant, what act, and — only when it matters — that it
/// has slipped past its day.
private struct WatchTaskRow: View {
    let task: WatchTaskSummary
    let plant: WatchPlantSummary?

    private var isOverdue: Bool {
        task.dueDate < Calendar.current.startOfDay(for: .now)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.kind.icon)
                .font(.body)
                .foregroundStyle(isOverdue ? WatchTheme.danger : task.kind.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(plant?.nickname ?? "A plant")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(task.kind.title)
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.mutedInk)
                    .lineLimit(2)
                if isOverdue {
                    Text("Overdue")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(WatchTheme.danger)
                }
            }
        }
    }
}

struct WatchStreakRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let streak: Int
    let isShielded: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "flame.fill")
                .foregroundStyle(WatchTheme.streak)
            Text("\(streak)-day streak")
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
            if isShielded {
                Image(systemName: "shield.fill")
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.subtleInk)
                    .fixedSize()
            }
        }
        .listRowBackground(Color.clear)
    }
}

/// The instruction, then the one button. The button names the outcome in the
/// past tense — tapping it is the wearer saying "done", not "do it".
struct WatchTaskDetailView: View {
    @Environment(WatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let task: WatchTaskSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let plant = store.plant(id: task.plantID) {
                    Text(plant.nickname)
                        .font(.title3.weight(.semibold))
                    Text(plant.species)
                        .font(.footnote)
                        .foregroundStyle(WatchTheme.mutedInk)
                }
                HStack(spacing: 6) {
                    Image(systemName: task.kind.icon)
                        .foregroundStyle(task.kind.tint)
                    Text(task.kind.title)
                        .font(.headline)
                }
                .padding(.top, 4)
                if !task.detail.isEmpty {
                    Text(task.detail)
                        .font(.footnote)
                        .foregroundStyle(WatchTheme.mutedInk)
                }
                if task.isSittingTask {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                        Text("Plant sitting")
                    }
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.sitting)
                }
                if task.kind == .checkIn {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Continue on iPhone", systemImage: "iphone")
                            .font(.headline)
                        Text("A check-in needs the comparison photo and cannot be completed from your Watch.")
                            .font(.footnote)
                            .foregroundStyle(WatchTheme.mutedInk)
                    }
                    .padding(.top, 8)
                    .accessibilityElement(children: .combine)
                } else {
                    Button {
                        store.completeTask(task)
                        dismiss()
                    } label: {
                        WatchPrimaryButtonLabel(
                            title: task.kind.logTitle,
                            systemImage: "checkmark"
                        )
                    }
                    .buttonStyle(WatchPrimaryButtonStyle())
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Due")
    }
}
