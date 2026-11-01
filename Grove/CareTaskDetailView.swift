import Pow
import SwiftUI

struct CareTaskDetailView: View {
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    @Environment(\.dismiss) private var dismiss

    let taskID: UUID

    @State private var showingSnooze = false
    /// Ticking a task off is the single most repeated satisfying act in a care
    /// app, and it used to consist of a button greying out. This drives the
    /// mark that confirms it.
    @State private var justCompleted = false
    /// Counts completions so Pow's spray has something to fire on.
    @State private var completionTick = 0

    var body: some View {
        Group {
            if let task = store.task(id: taskID), let plant = store.plant(id: task.plantID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                        // The queue row this screen opens from already shows the
                        // plant's newest photograph, so arriving here used to
                        // replace a picture of the actual plant with a drawing
                        // of it. The photo is the point: it is what tells you
                        // which plant you are about to water.
                        PlantThumbnail(plant: plant, height: 180, maxDimension: 1400, breathes: true)
                            .groveHeroShape()

                        VStack(alignment: .leading, spacing: 10) {
                            Label(task.kind.title, systemImage: task.kind.icon)
                                .font(.subheadline.weight(.bold))
                                .textCase(.uppercase)
                                .tracking(1.2)
                                .foregroundStyle(GroveTheme.accentStrong)
                            GroveDisplayHeading(text: task.detail, style: .section)
                            Label(dueText(for: task), systemImage: "calendar")
                                .foregroundStyle(GroveTheme.mutedInk)
                            if task.isSittingTask {
                                Label("Care for \(task.ownerName ?? "a friend")", systemImage: "person.2.fill")
                                    .foregroundStyle(GroveTheme.purple)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .groveCard()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Check this first")
                                .font(.headline)
                            Text(safetyPrompt(for: task.kind))
                                .foregroundStyle(GroveTheme.mutedInk)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .groveCard()

                        // The stroked capsule is Grove's secondary action; a
                        // system bordered button here was the only one of its
                        // kind on the cream canvas.
                        NavigationLink(value: AppRoute.plant(plant.id)) {
                            GroveOutlineLabel(title: "View \(plant.nickname)’s profile", systemImage: "leaf.fill")
                        }
                        .buttonStyle(GrovePressStyle())
                        .groveHeroSource(.plant(plant.id))
                    }
                    .padding(.horizontal, GroveTheme.pagePadding)
                    .padding(.top, GroveTheme.pageTopPadding)
                    .padding(.bottom, 28)
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 10) {
                        primaryActions(for: task, plant: plant)

                        Button {
                            Haptics.tap()
                            showingSnooze = true
                        } label: {
                            Text("Not yet, here's why")
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .font(.subheadline.weight(.semibold))
                        .disabled(task.isCompleted)
                        .accessibilityIdentifier("snoozeCareTask")
                    }
                    .groveActionBar()
                }
                // The mark lands over the page and clears itself. It is a
                // confirmation, not a screen, so it never asks to be dismissed.
                .overlay {
                    if justCompleted {
                        GroveSuccessMark(size: 132)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .sheet(isPresented: $showingSnooze) {
                    SnoozeCareTaskView { date, reason in
                        snooze(task, until: date, reason: reason)
                    }
                    .presentationDetents([.medium, .large])
                }
                .groveEditorialPage(plant.nickname)
            } else {
                GroveEmptyState(
                    scene: .allClear,
                    title: "This task is gone",
                    message: "It was probably done, here or on another device."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .groveBackground()
    }

    @ViewBuilder
    private func primaryActions(for task: CareTask, plant: Plant) -> some View {
        if task.kind == .checkIn && !task.isCompleted {
            // A check-in is a photograph, and the card above says to take it
            // before touching the plant. Leading with "Mark as done" invited
            // ticking it off with no photo at all, so the camera comes first
            // and completing without one is quietly demoted.
            NavigationLink(value: AppRoute.checkIn(plant.id)) {
                GroveCTALabel(title: "Take today's photo", systemImage: "camera.fill")
            }
            .buttonStyle(GrovePressStyle())
            .accessibilityIdentifier("startCheckInFromTask")

            Button {
                complete(task)
            } label: {
                Text("Mark as done without a photo")
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .font(.subheadline.weight(.semibold))
            // A burst of leaves off the button itself, so the confirmation
            // starts where the finger was.
            .changeEffect(
                .spray(origin: UnitPoint(x: 0.5, y: 0.4)) {
                    Image(systemName: "leaf.fill")
                        .foregroundStyle(GroveTheme.accent)
                },
                value: completionTick
            )
            .accessibilityIdentifier("completeCareTask")
        } else {
            Button {
                complete(task)
            } label: {
                GroveCTALabel(
                    title: task.isCompleted ? "Done" : "Mark as done",
                    systemImage: "checkmark"
                )
            }
            .buttonStyle(GrovePressStyle())
            // A burst of leaves off the button itself, so the confirmation
            // starts where the finger was.
            .changeEffect(
                .spray(origin: UnitPoint(x: 0.5, y: 0.4)) {
                    Image(systemName: "leaf.fill")
                        .foregroundStyle(GroveTheme.accent)
                },
                value: completionTick
            )
            .disabled(task.isCompleted)
            .opacity(task.isCompleted ? 0.5 : 1)
            .animation(GroveMotion.settle, value: task.isCompleted)
            .accessibilityIdentifier("completeCareTask")
        }
    }

    private func complete(_ task: CareTask) {
        if task.kind == .water, let last = store.lastWatering(for: task.plantID) {
            Haptics.warning()
            let store = self.store
            toasts?.show(
                RecentWateringGuard.message(lastWateredAt: last.performedAt),
                symbol: "drop.triangle",
                actionTitle: "It's dry, water"
            ) {
                guard store.task(id: task.id)?.isCompleted == false else {
                    Haptics.error()
                    return
                }
                self.finishCompletion(task, force: true)
            }
            return
        }
        finishCompletion(task, force: false)
    }

    private func finishCompletion(_ task: CareTask, force: Bool) {
        guard store.complete(taskID: task.id, force: force) != nil else {
            Haptics.error()
            return
        }
        // Two beats — a light contact then the weight settling — because that
        // is what ticking something off actually feels like.
        Haptics.complete()
        completionTick += 1
        withAnimation(GroveMotion.celebrate) { justCompleted = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            withAnimation(.easeOut(duration: 0.35)) { justCompleted = false }
        }
        let request = CareTaskMutationRequest(
            taskID: task.id,
            outcome: .completed,
            occurredAt: .now,
            rescheduledFor: nil,
            reason: nil,
            clientRequestID: UUID()
        )
        Task { await syncEngine.enqueue(.updateCareTask(request), isConnected: connectivity.isConnected) }
    }

    private func snooze(_ task: CareTask, until date: Date, reason: String) {
        guard store.snooze(taskID: task.id, until: date, reason: reason) != nil else {
            Haptics.error()
            return
        }
        // Postponing is a decision, not an achievement: it is acknowledged
        // rather than celebrated.
        Haptics.commit()
        let request = CareTaskMutationRequest(
            taskID: task.id,
            outcome: .snoozed,
            occurredAt: .now,
            rescheduledFor: date,
            reason: reason,
            clientRequestID: UUID()
        )
        Task { await syncEngine.enqueue(.updateCareTask(request), isConnected: connectivity.isConnected) }
        dismiss()
    }

    private func dueText(for task: CareTask) -> String {
        if Calendar.current.isDateInToday(task.dueDate) { return "Due today" }
        if task.dueDate < .now { return "Overdue since \(task.dueDate.formatted(date: .abbreviated, time: .omitted))" }
        return "Due \(task.dueDate.formatted(date: .abbreviated, time: .omitted))"
    }

    private func safetyPrompt(for kind: CareKind) -> String {
        switch kind {
        case .water, .inspectSoil:
            "Water only if the soil is dry, not because it is on the list. A fresh check-in records what you found."
        case .fertilise:
            "Feed only during active growth, and follow the product label rather than increasing the dose."
        case .treat:
            "Make sure the symptom is still there, then stick to the existing plan. Never combine two products."
        case .prune:
            "Clean tools, and take only what is clearly dead or damaged."
        case .rotate:
            "Check the stems are steady, then turn the pot gently. Don't swing it into different light."
        case .cleanLeaves:
            "Support each leaf and use plain water unless the plan says otherwise."
        case .repot:
            "Change the pot only when the roots or drainage justify it, and avoid an oversized replacement."
        case .relocate:
            "Move it gradually when the new spot is much brighter or colder than the old one."
        case .monitor:
            "Look for the expected response before making another change."
        case .checkIn:
            "Take the comparison photo before you change anything."
        }
    }
}

private struct SnoozeCareTaskView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (Date, String) -> Void

    @State private var date = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
    @State private var reason = SnoozeReason.needMoreTime
    @AppStorage(GroveDefaults.reminderHour) private var reminderHour = NotificationService.reminderHour

    /// The instant the reminder will actually arrive.
    ///
    /// This screen used to offer an hour and a minute, and then
    /// `NotificationService` pulled anything not landing later today back to the
    /// delivery hour — so choosing 7am for tomorrow quietly became 9am, and 8pm
    /// became 9am the same morning. Grove's whole position on care reminders is
    /// that they are never urgent to the minute, so the honest fix was to stop
    /// offering a precision it deliberately does not keep, and to say plainly
    /// when the reminder lands instead.
    private var arrival: Date {
        NotificationService.reminderDate(for: date, now: .now, hour: reminderHour) ?? date
    }

    private var earliest: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What's holding it up?") {
                    Picker("Reason", selection: $reason) {
                        ForEach(SnoozeReason.allCases) { reason in
                            Text(reason.title).tag(reason)
                        }
                    }
                }
                Section {
                    // From tomorrow, not from now. With the clock gone from this
                    // picker, "today" resolves to a slot that has already passed
                    // for most of the day, and `GroveStore.snooze` refuses a date
                    // in the past — so the Save button would have done nothing at
                    // all, silently, every afternoon.
                    DatePicker("Remind me", selection: $date, in: earliest..., displayedComponents: [.date])
                } header: {
                    Text("New reminder")
                } footer: {
                    Text("Arrives \(arrival.formatted(.relative(presentation: .named))) at \(arrival.formatted(date: .omitted, time: .shortened)).")
                }
                Section {
                    Text("Your reason is saved with the plant's care history.")
                        .font(.footnote)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
            }
            .formStyle(.grouped)
            .groveGroupedContent()
            .grovePageTitle("Snooze care")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // The resolved arrival, not the raw picker value, so the
                        // task is stored with exactly the instant the footer
                        // above just promised.
                        onSave(arrival, reason.title)
                        dismiss()
                    }
                    .accessibilityIdentifier("confirmSnoozeCareTask")
                }
            }
        }
    }
}

private enum SnoozeReason: String, CaseIterable, Identifiable {
    case needMoreTime
    case soilStillMoist
    case plantUnavailable
    case waitingForSupplies

    var id: Self { self }

    var title: String {
        switch self {
        case .needMoreTime: "Need more time"
        case .soilStillMoist: "Soil is still moist"
        case .plantUnavailable: "Plant is not accessible"
        case .waitingForSupplies: "Waiting for supplies"
        }
    }
}
