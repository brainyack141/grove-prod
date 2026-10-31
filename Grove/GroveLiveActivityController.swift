import ActivityKit
import Foundation
import Observation

/// Keeps Grove's Live Activities in step with the store.
///
/// Two activities, at most one of each, because a Lock Screen with a card per
/// thirsty plant is a Lock Screen people turn Live Activities off for:
///
/// - **Watering** — the one plant most in need of water today, but only when
///   its watering rhythm is readable (three real gaps) so both ends of the
///   drying track are recorded dates rather than guesses. Logging the watering
///   ends it on a short "Watered" confirmation.
/// - **Plant-sitting** — the owner's active handover, with the sitter's
///   progress. Ends with the trip.
///
/// The controller is driven by observation, not by call sites in the views: it
/// re-reads the store whenever `plants`, `tasks`, `assignments` or the calendar
/// day change, so any screen that logs care is covered without knowing this
/// type exists.
@MainActor
final class GroveLiveActivityController {
    static let shared = GroveLiveActivityController()

    private var isRunning = false

    private init() {}

    /// Runs for the life of the scene. Safe to call more than once; later calls
    /// return immediately.
    func run(store: GroveStore) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        while !Task.isCancelled {
            // Observation fires once per registration, on the first change to
            // anything `desiredState` read. The stream buffers that one signal,
            // so a change that lands while `apply` is awaiting is not lost.
            let (changed, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let desired = withObservationTracking {
                Self.desiredState(store: store, now: .now)
            } onChange: {
                continuation.yield()
                continuation.finish()
            }

            await apply(desired)

            // Ends on the next change, or when the task is cancelled. A short
            // settle afterwards folds a burst of writes (complete task →
            // reschedule → sync) into one pass.
            for await _ in changed { break }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    // MARK: - Desired state

    struct Desired: Sendable {
        var watering: (attributes: GroveWateringActivityAttributes, state: GroveWateringActivityAttributes.ContentState)?
        var sitting: (attributes: GroveSittingActivityAttributes, state: GroveSittingActivityAttributes.ContentState)?
        /// Plants with a watering logged today, so an ending activity can tell
        /// "watered" (close on a confirmation) from "superseded" (just go).
        var wateredTodayPlantIDs: Set<String>
    }

    private static func desiredState(store: GroveStore, now: Date) -> Desired {
        // Read so a midnight rollover re-evaluates "today" without a store write.
        _ = store.calendarDay
        // Active plants only: an archived plant's open watering is not a
        // reason to light up the Lock Screen.
        let plants = store.activePlants
        let tasks = store.tasks
        let assignments = store.assignments
        return Desired(
            watering: wateringState(plants: plants, tasks: tasks, now: now),
            sitting: sittingState(plants: store.plants, tasks: tasks, assignments: assignments, now: now),
            wateredTodayPlantIDs: Set(
                tasks
                    .filter { $0.kind == .water && $0.isCompleted && Calendar.current.isDate($0.performedAt, inSameDayAs: now) }
                    .map(\.plantID.uuidString)
            )
        )
    }

    private static func wateringState(
        plants: [Plant],
        tasks: [CareTask],
        now: Date
    ) -> (attributes: GroveWateringActivityAttributes, state: GroveWateringActivityAttributes.ContentState)? {
        let calendar = Calendar.current
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return nil
        }

        // Due today, or overdue and still undone — either way it is a watering
        // the owner should do today. The owner's own care only: a sitter's
        // tasks belong to the sitter.
        let dueWaterings = tasks
            .filter { $0.kind == .water && !$0.isCompleted && !$0.isSittingTask && $0.dueDate < endOfToday }
            .sorted { $0.dueDate < $1.dueDate }

        for task in dueWaterings {
            guard let plant = plants.first(where: { $0.id == task.plantID }) else { continue }
            let rhythm = WateringRhythm(plantID: plant.id, tasks: tasks, now: now, calendar: calendar)
            // The track has to agree with the title. The task can come due
            // days before the owner's own rhythm says the soil is usually dry,
            // and "soil check" beside an amber "Fri" contradicts itself, so
            // the activity waits until the rhythm reaches today too.
            guard rhythm.isReadable,
                  let typicalDays = rhythm.typicalDays,
                  let last = rhythm.waterings.last?.date,
                  let dryAt = calendar.date(byAdding: .day, value: typicalDays, to: last),
                  dryAt < endOfToday else { continue }
            return (
                GroveWateringActivityAttributes(plantID: plant.id.uuidString),
                .init(plantName: plant.nickname, wateredAt: last, dryAt: dryAt, typicalDays: typicalDays)
            )
        }
        return nil
    }

    private static func sittingState(
        plants: [Plant],
        tasks: [CareTask],
        assignments: [SittingAssignment],
        now: Date
    ) -> (attributes: GroveSittingActivityAttributes, state: GroveSittingActivityAttributes.ContentState)? {
        // Outgoing handovers only: the owner is the one who wants the glance.
        guard let assignment = assignments
            .filter({ !$0.isIncoming && $0.currentStatus(now: now) == .active })
            .sorted(by: { $0.startDate < $1.startDate })
            .first else { return nil }

        let names = Dictionary(plants.map { ($0.id, $0.nickname) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        let recent = tasks
            .filter {
                $0.isSittingTask && $0.isCompleted
                    && assignment.plantIDs.contains($0.plantID)
                    && $0.performedAt >= assignment.startDate && $0.performedAt <= now
            }
            .sorted { $0.performedAt > $1.performedAt }
            .compactMap { task -> String? in
                guard seen.insert(task.plantID).inserted else { return nil }
                return names[task.plantID]
            }

        return (
            GroveSittingActivityAttributes(
                assignmentID: assignment.id.uuidString,
                sitterName: assignment.sitterName,
                sitterInitials: assignment.sitterInitials,
                startDate: assignment.startDate,
                endDate: assignment.endDate
            ),
            .init(
                completedTasks: max(0, assignment.completedTasks),
                totalTasks: max(0, assignment.totalTasks),
                recentPlantNames: Array(recent.prefix(3))
            )
        )
    }

    // MARK: - Apply

    private func apply(_ desired: Desired) async {
        await reconcileWatering(desired.watering, wateredToday: desired.wateredTodayPlantIDs)
        await reconcileSitting(desired.sitting)
    }

    private func reconcileWatering(
        _ desired: (attributes: GroveWateringActivityAttributes, state: GroveWateringActivityAttributes.ContentState)?,
        wateredToday: Set<String>
    ) async {
        let staleDate = Self.endOfToday()
        for activity in Activity<GroveWateringActivityAttributes>.activities {
            // Ended ones linger in the list until dismissed; leave them be.
            guard activity.activityState == .active || activity.activityState == .stale else { continue }
            if let desired, activity.attributes == desired.attributes {
                if activity.content.state != desired.state {
                    await activity.update(ActivityContent(state: desired.state, staleDate: staleDate))
                }
                continue
            }
            guard wateredToday.contains(activity.attributes.plantID) else {
                // Superseded rather than done — deleted plant, rescheduled task,
                // rhythm no longer readable. Nothing to confirm, so just go.
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            // Watered. Close on the fact rather than vanishing, then step aside.
            var finished = activity.content.state
            finished.isDone = true
            await activity.end(
                ActivityContent(state: finished, staleDate: nil),
                dismissalPolicy: .after(.now.addingTimeInterval(20 * 60))
            )
        }

        guard let desired,
              !Activity<GroveWateringActivityAttributes>.activities.contains(where: {
                  $0.attributes == desired.attributes && ($0.activityState == .active || $0.activityState == .stale)
              }),
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try Activity.request(
                attributes: desired.attributes,
                content: ActivityContent(state: desired.state, staleDate: staleDate)
            )
        } catch {
            // Most often: requested while the app was in the background, or the
            // per-app activity limit. The next foreground pass tries again.
        }
    }

    private func reconcileSitting(
        _ desired: (attributes: GroveSittingActivityAttributes, state: GroveSittingActivityAttributes.ContentState)?
    ) async {
        for activity in Activity<GroveSittingActivityAttributes>.activities {
            // Ended ones linger in the list until dismissed; leave them be.
            guard activity.activityState == .active || activity.activityState == .stale else { continue }
            if let desired, activity.attributes == desired.attributes {
                if activity.content.state != desired.state {
                    await activity.update(ActivityContent(state: desired.state, staleDate: desired.attributes.endDate))
                }
                continue
            }
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        guard let desired,
              !Activity<GroveSittingActivityAttributes>.activities.contains(where: {
                  $0.attributes == desired.attributes && ($0.activityState == .active || $0.activityState == .stale)
              }),
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try Activity.request(
                attributes: desired.attributes,
                content: ActivityContent(state: desired.state, staleDate: desired.attributes.endDate)
            )
        } catch {
            // See reconcileWatering.
        }
    }

    private static func endOfToday() -> Date? {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))
    }
}
