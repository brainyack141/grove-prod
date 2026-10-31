import SwiftUI

/// A due care task, and — for everything except a check-in — the means to
/// finish it without leaving the list.
///
/// Ticking off care used to cost a tap into a detail screen, a tap on the
/// button, and a tap back out, for every task, every day. The work itself is a
/// second of thought ("is the soil dry?"), so three screens of ceremony around
/// it is most of the effort. The tick is now on the row, with an undo behind
/// it, and long-press carries the two decisions the detail screen also offers.
/// Check-ins keep their screen: they need the guided photo to mean anything, so
/// their marker opens the flow rather than pretending it can be waved away.
///
/// Lives outside `TodayView` because Today is no longer its only home: the row
/// is also the whole of `CareQueueView`, and duplicating it would be how the
/// two lists start disagreeing about what a task looks like.
///
/// The schedule's own front door on Today is this same row with
/// `opensSchedule` set: it leads into the schedule rather than into a task, and
/// is otherwise indistinguishable, so the column keeps one anatomy and one left
/// edge instead of arriving as a second kind of card.
struct CareTaskRow: View {
    @Environment(GroveStore.self) private var store
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    @Environment(SyncEngine.self) private var syncEngine: SyncEngine?
    @Environment(ConnectivityMonitor.self) private var connectivity: ConnectivityMonitor?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: CareTask

    /// Whether a tap opens the whole schedule rather than this task's own page.
    ///
    /// The schedule's front door on Today wears the care rows' anatomy so the
    /// column keeps one left edge, but it is a door: its job is to show what is
    /// coming, not to send the reader to a task that has not arrived. This flag
    /// is the only difference — marker, copy, and trailing day are the row's.
    var opensSchedule: Bool = false

    /// Set the instant the tick is pressed, before the store hears about it.
    ///
    /// Completing a task used to be a mutation and nothing else: the row was in
    /// the list on one frame and gone on the next, with a three-beat haptic
    /// playing over a hard cut. The work is now split in two — the tick fills
    /// under the finger, *then* the row leaves — because the confirmation the
    /// user is waiting for is that Grove heard them, and that has to land on the
    /// control they actually touched.
    @State private var isTicked = false

    /// How long the filled tick is held before the row departs. Long enough to
    /// read as an answer, short enough that it never feels like latency.
    private static let tickDwell: Duration = .milliseconds(260)

    /// A check-in is the one care task that cannot be honestly ticked off from
    /// a list: without the comparison photo there is nothing to compare.
    private var canTickOff: Bool { task.kind != .checkIn }

    private var route: AppRoute {
        if opensSchedule { return .care }
        return task.kind == .checkIn ? .checkIn(task.plantID) : .careTask(task.id)
    }

    var body: some View {
        if let plant = store.plant(id: task.plantID) {
            // The tick is a real control sitting *over* the row rather than
            // inside its label: a button nested in a `NavigationLink`'s label is
            // drawn but never pressed, so the row would have shown an
            // untappable tick and pushed the task page instead.
            ZStack(alignment: .trailing) {
                NavigationLink(value: route) {
                    rowContent(for: plant)
                }
                .buttonStyle(GroveCardPressStyle())
                .accessibilityIdentifier("careTask.\(plant.nickname)")
                .accessibilityLabel("\(plant.nickname). \(status.text). \(task.detail)")
                .accessibilityHint(accessibilityHint)
                .contextMenu {
                    if canTickOff && !opensSchedule {
                        Button {
                            tickOff(plant)
                        } label: {
                            Label("Mark as done", systemImage: "checkmark.circle")
                        }
                    }
                    if let tomorrow = tomorrowReminder {
                        Button {
                            remindTomorrow(at: tomorrow)
                        } label: {
                            Label("Remind me tomorrow", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }

                trailingControl(for: plant)
            }
            // The row answers the tick before it leaves: the whole thing eases
            // back a fraction and lightens, so the departure reads as a
            // consequence of the press rather than a list refreshing itself.
            .opacity(isTicked && !reduceMotion ? 0.55 : 1)
            .scaleEffect(isTicked && !reduceMotion ? 0.985 : 1)
            .groveAnimation(GroveMotion.settle, value: isTicked)
            .groveRowTransition()
        }
    }

    // MARK: - Trailing control

    /// What the row can do about the thing it just told you.
    ///
    /// This used to be a disc in a gutter to the *left* of the card, one column
    /// outside the row it belonged to, so a column of care read as two lists
    /// standing side by side — a strip of floating circles and a strip of
    /// floating cards. It also fought the app's one leading element: every other
    /// list in Grove opens a row with the plant's own photograph, and this one
    /// opened with a symbol.
    ///
    /// So the photo takes the left edge, like everywhere else, and the control
    /// moves to the trailing slot where the rest of the app puts its in-place
    /// actions. That also makes the slot honest about what it is: a tick where
    /// the work can truly be finished from a list, and a chevron where it cannot
    /// — a check-in needs the guided photo, and a schedule row leads to the
    /// schedule. The inert green disc that used to sit beside check-ins looked
    /// like a button that had stopped working.
    private var showsTick: Bool { canTickOff && !opensSchedule }

    private var trailingSlotWidth: CGFloat { showsTick ? 38 : 16 }

    @ViewBuilder
    private func trailingControl(for plant: Plant) -> some View {
        if showsTick {
            Button {
                tickOff(plant)
            } label: {
                CareRowMarker(kind: .tick(isTicked: isTicked))
            }
            // The tile style's own haptic is suppressed: the tick answers with
            // `Haptics.complete()` a moment later, and two taps for one press
            // reads as a stutter.
            .buttonStyle(GroveTilePressStyle(haptics: false))
            .disabled(isTicked)
            .accessibilityLabel("Mark \(task.kind.loggedTitle) for \(plant.nickname) as done")
        } else {
            GroveRowChevron()
        }
    }

    // MARK: - Row

    private var nameLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 7))
    }

    private func rowContent(for plant: Plant) -> some View {
        HStack(spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                // The plant as the user last saw it, at the one thumbnail size
                // and radius every plant row in Grove uses.
                PlantThumbnail(plant: plant, height: PlantRow<EmptyView>.thumbnailSize, maxDimension: 220)
                    .frame(width: PlantRow<EmptyView>.thumbnailSize,
                           height: PlantRow<EmptyView>.thumbnailSize)
                    .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 3) {
                nameLayout {
                    Text(plant.nickname)
                        .font(.headline)
                        .foregroundStyle(GroveTheme.ink)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    if task.isSittingTask {
                        Text("Sitting")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(GroveTheme.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(GroveTheme.purple.opacity(0.10), in: Capsule())
                    }
                }
                // One status line where there used to be three.
                //
                // The row carried the care kind in accent green, then the task's
                // own sentence truncated to a single line ("One fresh photo.
                // Grove lin…"), then a tracked-caps day label out on the
                // trailing edge in red. Three slots, two of them saying *when*,
                // one of them saying nothing at all once it was clipped — and
                // the caps label was the only uppercase voice in the app outside
                // `GroveEyebrow`. What kind of work it is and when it is due are
                // one fact, so they are now one sentence, and the sentence that
                // explains the work stays on the task's own page where there is
                // room to finish it.
                GroveStatusLabel(status: status, lineLimit: dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }

            Spacer(minLength: 8)

            // The slot the real control is overlaid into.
            Color.clear
                .frame(width: trailingSlotWidth, height: trailingSlotWidth)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// What this row is asking for, and how late it is.
    ///
    /// `opensSchedule` rows are a door rather than a job: they say when the work
    /// arrives, never that it is owed now, because a tap opens the schedule.
    private var status: GroveStatus {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: .now),
            to: calendar.startOfDay(for: task.dueDate)
        ).day ?? 0
        // The noun, not the instruction: `title` reads "Water only if it's
        // dry", which turns into "Water only if it's dry overdue" here.
        let noun = task.kind.scheduleNoun
        switch days {
        case ..<0: return GroveStatus(.late, "\(noun) overdue")
        case 0: return GroveStatus(.due, "\(noun) today")
        case 1: return GroveStatus(.quiet, "\(noun) tomorrow")
        case let days: return GroveStatus(.quiet, "\(noun) in \(days) days")
        }
    }

    /// The row's destination, said aloud. A scheduled row opens the schedule
    /// rather than the task, so it must not promise the task's page.
    private var accessibilityHint: String {
        if opensSchedule { return "Opens your care schedule" }
        return task.kind == .checkIn ? "Opens the guided health check-in" : "Opens care task details"
    }

    // MARK: - Actions

    /// Marks the task done in two beats: the tick fills, then the row leaves.
    ///
    /// The store mutation is deliberately the *second* beat. Doing it first
    /// would destroy this view — and the filled tick with it — on the same frame
    /// as the press, which is precisely the cut this is here to remove.
    private func tickOff(_ plant: Plant) {
        guard !isTicked else { return }
        // Checked *before* the tick fills, not after the dwell. `complete`
        // refuses a task that is missing or already done, and the confirmation
        // beat plays on press — so without this the row answered a press it was
        // about to fail, playing success and then error for one tap.
        guard store.task(id: task.id)?.isCompleted == false else {
            Haptics.error()
            return
        }
        // A scheduled watering is still a watering. Refusing after the tick
        // would be a dead tap; the row has to say why before the success beat.
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
                self.beginTicking(plant, force: true)
            }
            return
        }
        beginTicking(plant)
    }

    /// Fills the tick, then commits the completion after the dwell. The forced
    /// path starts the same way, so a watering the user has confirmed is dry
    /// still answers under the finger before the row leaves.
    private func beginTicking(_ plant: Plant, force: Bool = false) {
        withAnimation(GroveMotion.pop) { isTicked = true }
        Haptics.complete()

        Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(for: Self.tickDwell)
            }
            commitCompletion(for: plant, force: force)
        }
    }

    private func commitCompletion(for plant: Plant, force: Bool = false) {
        let store = self.store
        // Assigned out of the animation block rather than returned from it:
        // `complete` is `@discardableResult`, so a single-expression closure
        // infers `Void` and the binding never sees the task.
        var outcome: CareTask?
        withAnimation(GroveMotion.settle) {
            outcome = store.complete(taskID: task.id, force: force)
        }
        guard let completed = outcome else {
            // `tickOff` already established the task was completable, so
            // reaching here means something else claimed it during the dwell
            // (a sync bootstrap, the Watch, another surface). Give the press
            // back silently: the work did happen, just not by this tap, and a
            // second haptic on top of the confirmation reads as a fault.
            withAnimation(GroveMotion.settle) { isTicked = false }
            return
        }
        toasts?.show(
            "Recorded \(completed.kind.loggedTitle) for \(plant.nickname)",
            symbol: completed.kind.icon,
            actionTitle: "Undo"
        ) {
            // The row comes back into the list, so the undo animates too. The
            // discard keeps the closure returning `Void` for the toast.
            withAnimation(GroveMotion.settle) {
                _ = store.undoCompletion(taskID: completed.id)
            }
        }
        enqueueCompletion(completed)
    }

    /// Tomorrow's reminder slot, or nil when the offer would be a lie.
    ///
    /// "Tomorrow" is the calendar day after today at the reminder hour, the
    /// same instant the snooze sheet and the lock-screen action resolve to.
    /// It used to be the due date plus a day at the current clock time, so on
    /// a "Coming up" row due in six days the action quietly moved the task to
    /// day seven. A task already due after tomorrow has no use for it.
    private var tomorrowReminder: Date? {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)),
              let dayAfter = calendar.date(byAdding: .day, value: 1, to: tomorrow),
              task.dueDate < dayAfter else { return nil }
        let hour = UserDefaults.standard.object(forKey: GroveDefaults.reminderHour) as? Int
            ?? NotificationService.reminderHour
        return NotificationService.reminderDate(for: tomorrow, now: .now, hour: hour)
    }

    private func remindTomorrow(at date: Date) {
        var snoozed: CareTask?
        withAnimation(GroveMotion.settle) {
            snoozed = store.snooze(taskID: task.id, until: date, reason: "Remind me tomorrow")
        }
        guard snoozed != nil else {
            Haptics.error()
            return
        }
        Haptics.commit()
        toasts?.show(
            "Moved to tomorrow",
            symbol: "clock.fill"
        )
        let request = CareTaskMutationRequest(
            taskID: task.id,
            outcome: .snoozed,
            occurredAt: .now,
            rescheduledFor: date,
            reason: "Remind me tomorrow",
            clientRequestID: UUID()
        )
        enqueue(request)
    }

    /// Holds the completion back until the undo window has closed.
    ///
    /// The sync contract has no "un-complete" mutation, so sending the
    /// completion the instant it happens would leave the server holding a
    /// completion the user has since taken back. Waiting until the offer has
    /// expired — and re-checking that the task is still completed — keeps the
    /// two honest. A completion is already durable locally, so a relaunch
    /// inside the window costs nothing but a later reconciliation.
    private func enqueueCompletion(_ completed: CareTask) {
        let store = self.store
        let syncEngine = self.syncEngine
        let connectivity = self.connectivity
        let request = CareTaskMutationRequest(
            taskID: completed.id,
            outcome: .completed,
            occurredAt: .now,
            rescheduledFor: nil,
            reason: nil,
            clientRequestID: UUID()
        )
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard store.task(id: completed.id)?.isCompleted == true else { return }
            guard let syncEngine else { return }
            await syncEngine.enqueue(.updateCareTask(request), isConnected: connectivity?.isConnected ?? false)
        }
    }

    private func enqueue(_ request: CareTaskMutationRequest) {
        guard let syncEngine else { return }
        let isConnected = connectivity?.isConnected ?? false
        Task { await syncEngine.enqueue(.updateCareTask(request), isConnected: isConnected) }
    }
}

// MARK: - The leading marker

/// The disc that leads a care row, shared so every row keeps one column width.
///
/// It is deliberately not the row's category icon: the copy already names the
/// work, and a badge in the gutter does not read as something to press. What
/// varies between the cases is only how much the disc asks of the reader — a
/// tick to finish ordinary care, Grove's own reticle for a check-in that needs
/// the camera, and a quiet neutral disc for work that is scheduled rather than
/// due. Drawing all of them here is what keeps a column of rows on one left
/// edge, whether the row beside them is a task, a check-in, or the schedule's
/// own door.
struct CareRowMarker: View {
    enum Kind {
        /// Ordinary care, finishable here. `isTicked` drives the fill.
        case tick(isTicked: Bool)
        /// A check-in: the reticle the camera, tab button and check-in flow draw.
        case checkIn
        /// Scheduled, not due: a quiet calendar.
        case scheduled
        /// More work than the page had room to show.
        case more
    }

    let kind: Kind

    var body: some View {
        Group {
            switch kind {
            case .tick(let isTicked): tick(isTicked: isTicked)
            case .checkIn: checkIn
            case .scheduled: neutral(symbol: "calendar")
            case .more: neutral(symbol: "ellipsis")
            }
        }
        .frame(width: 38, height: 38)
        .contentShape(Circle())
    }

    /// The fill is a scaling disc rather than a colour change, so the tick
    /// floods from its own centre outward — the shape of an answer arriving,
    /// not of a property being set.
    private func tick(isTicked: Bool) -> some View {
        ZStack {
            Circle().fill(GroveTheme.surface)
            Circle()
                .fill(GroveTheme.accent)
                .scaleEffect(isTicked ? 1 : 0.01)
                .opacity(isTicked ? 1 : 0)
            Circle()
                .strokeBorder(GroveTheme.separator, lineWidth: 1.5)
                .opacity(isTicked ? 0 : 1)
            // A checkmark, not the care kind's own glyph: the row already says
            // what the task is, and a category badge does not read as something
            // to press.
            Image(systemName: "checkmark")
                .font(.footnote.weight(.black))
                .foregroundStyle(isTicked ? .white : GroveTheme.accent)
                .scaleEffect(isTicked ? 1.18 : 1)
        }
        .groveAnimation(GroveMotion.pop, value: isTicked)
    }

    /// A check-in is a scan of a plant already in the record, so its marker is
    /// Grove's own reticle — the same four corners the tab button and the camera
    /// draw — rather than the stock viewfinder symbol. The soft wash replaces a
    /// dashed ring, because a dash means *provisional* everywhere else in Grove
    /// (see `GroveEmptyArt`); a check-in is not provisional, it is simply
    /// waiting on a photo. The tick's ring is ink and open; this disc is green
    /// and filled, so one column reads as two kinds of work.
    private var checkIn: some View {
        ZStack {
            Circle().fill(GroveTheme.softAccent)
            Circle()
                .strokeBorder(GroveTheme.accent.opacity(0.18), lineWidth: 1)
            GroveScanReticleGlyph(phase: .rest, tint: GroveTheme.accent)
                .frame(width: 17, height: 17)
        }
    }

    /// Neither actionable nor a check-in: a neutral disc, a step below the
    /// canvas so it reads as a slot rather than as a button.
    private func neutral(symbol: String) -> some View {
        ZStack {
            Circle().fill(GroveTheme.secondarySurface)
            Circle().strokeBorder(GroveTheme.separator, lineWidth: 1)
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GroveTheme.subtleInk)
        }
    }
}
