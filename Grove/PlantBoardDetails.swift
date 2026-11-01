import Charts
import SwiftUI

// MARK: - What to do, inside Ari's card

/// The plan the last assessment left, as steps the owner can tick off.
///
/// The scan's next actions were collected, stored, synced and then shown
/// nowhere on the board: Ari said what the photo found and stopped. These are
/// the same instructions, read from the structured care plan when there is one
/// (so a step can be marked done and stay done) and from the legacy
/// `nextActions` list when there is not (shown, but not tickable).
struct PlantPlanSteps: Equatable {
    struct Step: Identifiable, Equatable {
        let id: String
        /// The care-plan action this step records against. Nil for a legacy
        /// instruction, which has nowhere to keep its state.
        let actionID: UUID?
        let instruction: String
        let isDone: Bool
        /// The results this check could turn up, when the diagnosis gave them.
        var outcomes: [PlantCheckOutcome] = []
        /// The result the owner tapped.
        var finding: PlantCheckOutcome? = nil

        /// The check can be answered with a tap rather than a tick.
        var isAnswerable: Bool { outcomes.count >= 2 && actionID != nil }

        /// A step that asks the owner to look rather than act: "scratch the
        /// trunk", "bend a twig", "push a skewer into the rootball". Ticking
        /// one off proves nothing; what it turned up is the whole point.
        var isCheck: Bool {
            if !outcomes.isEmpty { return true }
            let text = " " + instruction.lowercased()
            return Self.checkCues.contains { text.contains($0) }
        }

        /// The check itself, without the reason Ari gave for it, so the
        /// findings draft reads "Gently bend a small outer twig: " and not a
        /// line and a half of explanation before the blank.
        var checkLabel: String {
            var label = instruction
            for purpose in Self.purposeClauses {
                if let range = label.range(of: purpose, options: .caseInsensitive) {
                    label = String(label[..<range.lowerBound])
                }
            }
            return label.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        }

        private static let checkCues = [
            " check", " test", " inspect", " examine", " look for", " look at", " look under",
            " see if", " see whether", " feel ", " bend", " probe", " skewer", " sniff",
        ]
        private static let purposeClauses = [
            " to check", " to see", " to determine", " to confirm", " to find", " to tell", " to test",
            " and see", ", and ",
        ]
    }

    let steps: [Step]

    var isEmpty: Bool { steps.isEmpty }
    var doneCount: Int { steps.filter(\.isDone).count }
    var isTrackable: Bool { steps.contains { $0.actionID != nil } }

    /// Checks the owner ticked without saying what they found. Once there is
    /// one, the plan's next step is theirs to report, not a photo to wait for.
    /// A check answered with a tap has already been reported.
    var finishedChecks: [Step] { steps.filter { $0.isDone && $0.isCheck && $0.finding == nil } }

    /// The message that hands the owner's findings to Ari: one line per check
    /// with a blank to fill, so the answer can be a treatment, not a guess.
    func findingsDraft(nickname: String) -> String? {
        let checks = finishedChecks
        guard !checks.isEmpty else { return nil }
        let lines = checks.map { "\($0.checkLabel): " }.joined(separator: "\n")
        return "I did the checks on \(nickname). Here's what I found:\n\n\(lines)"
    }

    static func make(plant: Plant) -> PlantPlanSteps {
        if let plan = plant.carePlan, plan.status == .active {
            let steps = plan.actions
                .filter { $0.state != .skipped }
                .compactMap { action -> Step? in
                    let instruction = action.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !instruction.isEmpty else { return nil }
                    return Step(
                        id: action.id.uuidString,
                        actionID: action.id,
                        instruction: instruction,
                        isDone: action.state == .completed,
                        outcomes: action.outcomes ?? [],
                        finding: action.finding
                    )
                }
            if !steps.isEmpty { return PlantPlanSteps(steps: steps) }
        }
        let legacy = plant.nextActions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { Step(id: "legacy-\($0.offset)", actionID: nil, instruction: $0.element, isDone: false) }
        return PlantPlanSteps(steps: legacy)
    }

    /// The sentence that closes the loop: which photo will say whether the
    /// steps worked. Grove cannot know that yet, so it says when it will.
    static func reviewLine(for date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch days {
        case ..<1: return "Today's photo will show if it worked."
        case 1: return "Tomorrow's photo will show if it worked."
        case 2...6: return "\(date.formatted(.dateTime.weekday(.wide)))'s photo will show if it worked."
        default: return "The photo on \(date.formatted(.dateTime.day().month(.abbreviated))) will show if it worked."
        }
    }
}

/// The steps, drawn on Ari's night green. Ticking one records it against the
/// care plan; it does not log care, because a step's care kind is inferred
/// from its wording and "Skip watering until it's dry" must never be recorded
/// as a watering.
struct AriPlanSteps: View {
    let plant: Plant
    let plan: PlantPlanSteps

    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?

    private var heading: String {
        guard plan.isTrackable, plan.doneCount > 0 else { return "What to do" }
        return plan.doneCount == plan.steps.count
            ? "What to do · all done"
            : "What to do · \(plan.doneCount) of \(plan.steps.count) done"
    }

    /// The next photo look. The task is the authority because it is what the
    /// reminder fires on; the plant's own date is the fallback.
    private var reviewDate: Date {
        store.pendingTasks
            .filter { $0.plantID == plant.id && $0.kind == .checkIn && !$0.isSittingTask }
            .min { $0.dueDate < $1.dueDate }?
            .dueDate ?? plant.nextCheckIn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(.white.opacity(0.14))
                .frame(height: 1)
                .padding(.bottom, 14)
                .accessibilityHidden(true)

            GroveEyebrow(text: heading, color: GroveTheme.mapCaption)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)

            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                row(step, number: index + 1)
            }

            // A check's result is in the owner's hands now, not in a photo.
            // Saying "the photo will show if it worked" after a scratch test
            // left them holding an answer with nowhere to put it.
            Label {
                Text(plan.finishedChecks.isEmpty
                    ? PlantPlanSteps.reviewLine(for: reviewDate)
                    : "What you found decides the next step. Tell Ari.")
            } icon: {
                Image(systemName: plan.finishedChecks.isEmpty ? "camera.fill" : "text.bubble.fill")
                    .accessibilityHidden(true)
            }
            .font(.footnote)
            .foregroundStyle(GroveTheme.mapCaption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
        }
    }

    private func row(_ step: PlantPlanSteps.Step, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle().fill(.white.opacity(0.12))
                    if step.isDone {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(GroveTheme.mapThriving)
                    } else {
                        Text("\(number)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

                Text(step.instruction)
                    .font(.subheadline)
                    .strikethrough(step.isDone, color: .white.opacity(0.5))
                    .foregroundStyle(step.isDone ? .white.opacity(0.5) : .white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // A check with known results is answered, not ticked: "Done"
                // would throw away the one thing the check was for.
                if !step.isDone, !step.isAnswerable, let actionID = step.actionID {
                    Button {
                        complete(actionID)
                    } label: {
                        GroveOutlineLabel(title: "Done", size: .compact, onDark: true)
                    }
                    .buttonStyle(GrovePressStyle())
                    .accessibilityLabel("Mark done: \(step.instruction)")
                }
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: step.isDone || step.actionID == nil || step.isAnswerable ? .combine : .contain)
            .accessibilityValue(step.isDone ? "Done" : "")

            if let finding = step.finding {
                findingNote(finding)
            } else if !step.isDone, step.isAnswerable, let actionID = step.actionID {
                answers(for: step, actionID: actionID)
            }
        }
        .padding(.vertical, 6)
    }

    /// What the check turned up and what that means, kept under the check so
    /// the reason for the step below it stays in sight.
    private func findingNote(_ finding: PlantCheckOutcome) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Found: \(finding.title)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GroveTheme.mapThriving)
            Text(finding.meaning)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.82))
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 36)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    private func answers(for step: PlantPlanSteps.Step, actionID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What did you find?")
                .font(.footnote)
                .foregroundStyle(GroveTheme.mapCaption)
                .accessibilityAddTraits(.isHeader)
            GroveFlowLayout(spacing: 8) {
                ForEach(step.outcomes) { outcome in
                    Button {
                        record(outcome, for: actionID)
                    } label: {
                        answerChip(outcome.title, filled: true)
                    }
                    .buttonStyle(GrovePressStyle())
                    .accessibilityLabel("Found: \(outcome.title)")
                }
                // The listed results are the likely ones, not all of them.
                // Anything else goes to Ari with the check already named.
                NavigationLink(
                    value: AppRoute.askAboutLatestScan(
                        plant.id,
                        initialDraft: "I did this check on \(plant.nickname): \(step.checkLabel). What I found: "
                    )
                ) {
                    answerChip("Something else", filled: false)
                }
                .buttonStyle(GrovePressStyle())
                .accessibilityLabel("Found something else. Tell Ari.")
            }
        }
        .padding(.leading, 36)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func answerChip(_ title: String, filled: Bool) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(filled ? GroveTheme.inkOnLight : .white)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.10)), in: Capsule())
            .overlay {
                if !filled { Capsule().stroke(.white.opacity(0.45), lineWidth: 1.5) }
            }
            .contentShape(Capsule())
    }

    private func record(_ outcome: PlantCheckOutcome, for actionID: UUID) {
        guard let before = store.plants.first(where: { $0.id == plant.id })?.carePlan else { return }
        let updated = withAnimation(GroveMotion.snap) {
            store.recordCheckFinding(plantID: plant.id, actionID: actionID, outcomeID: outcome.id)
        }
        guard let updated else {
            Haptics.error()
            return
        }
        Haptics.complete()
        sync(updated)
        toasts?.show("Found: \(outcome.title)", symbol: "checkmark.circle.fill", actionTitle: "Undo") {
            let restored = withAnimation(GroveMotion.snap) {
                store.restoreCarePlan(plantID: plant.id, to: before)
            }
            if let restored {
                Haptics.tap()
                sync(restored)
            }
        }
    }

    private func sync(_ updated: Plant) {
        let request = UpdatePlantRequest(plant: updated, clientRequestID: UUID())
        let syncEngine = syncEngine
        let isConnected = connectivity.isConnected
        Task { await syncEngine.enqueue(.updatePlant(request), isConnected: isConnected) }
    }

    private func complete(_ actionID: UUID) {
        guard setState(.completed, for: actionID) else {
            Haptics.error()
            return
        }
        Haptics.complete()
        toasts?.show("Marked done", symbol: "checkmark.circle.fill", actionTitle: "Undo") {
            if setState(.due, for: actionID) { Haptics.tap() }
        }
    }

    @discardableResult
    private func setState(_ state: PlantCarePlanActionState, for actionID: UUID) -> Bool {
        let updated = withAnimation(GroveMotion.snap) {
            store.updateCarePlanAction(plantID: plant.id, actionID: actionID, state: state)
        }
        guard let updated else { return false }
        sync(updated)
        return true
    }
}

// MARK: - Health, with its working

/// Where a plant's readings usually sit, so a score can be read against the
/// plant itself rather than against a 0–100 scale it has never lived near.
///
/// The latest reading is left out: the question is whether *it* is unusual,
/// and a range that already contains it cannot answer that. The middle half of
/// the earlier readings is used once there are enough of them, so one bad week
/// in spring does not widen "usual" for good.
struct PlantUsualRange: Equatable {
    enum Position: Equatable { case below, within, above }

    let low: Int
    let high: Int

    /// Readings before the latest one needed before Grove calls anything usual.
    static let minimumPriorReadings = 3

    /// `scores` oldest first, including the latest.
    static func make(scores: [Int]) -> PlantUsualRange? {
        let prior = Array(scores.dropLast())
        guard prior.count >= minimumPriorReadings else { return nil }
        let sorted = prior.sorted()
        let trim = sorted.count / 4
        var low = sorted[trim]
        var high = sorted[sorted.count - 1 - trim]
        // A plant that has held one score is still a range, not a line.
        if high - low < 4 {
            let middle = (low + high) / 2
            low = max(0, middle - 2)
            high = min(100, middle + 2)
        }
        return PlantUsualRange(low: low, high: high)
    }

    func position(of score: Int) -> Position {
        if score < low { return .below }
        if score > high { return .above }
        return .within
    }
}

struct PlantHealthSheet: View {
    let plantID: UUID
    let readAge: String?

    @Environment(GroveStore.self) private var store
    @Environment(IntentRouter.self) private var intentRouter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Held until the sheet has gone, then pushed, so the destination never
    /// lands underneath a sheet that is still animating away.
    @State private var routeOnExit: AppRoute?

    var body: some View {
        NavigationStack {
            Group {
                if let plant = store.plant(id: plantID) {
                    content(for: plant)
                } else {
                    GroveEmptyState(
                        scene: .vanished,
                        title: "Plant not found",
                        message: "It was probably removed from your grove, here or on another device."
                    )
                }
            }
            .groveBackground()
            .navigationTitle("Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.bold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear {
            guard let routeOnExit else { return }
            intentRouter.pushedRoute = routeOnExit
        }
    }

    private func content(for plant: Plant) -> some View {
        let observations = store.observations(for: plant.id)
        let progress = PlantPageProgress.make(
            plant: plant,
            observations: observations,
            scans: store.scanHistory,
            tasks: store.tasks
        )
        let usual = PlantUsualRange.make(scores: progress.readings.map(\.score))
        let indicators = PlantHealthIndicatorPresentation.prioritized(
            PlantHealthIndicators.make(
                for: plant,
                observations: observations,
                diagnosis: store.currentDiagnosis(for: plant.id),
                tasks: store.tasks,
                location: store.profile.location
            )
        )
        let waterings = Self.waterings(for: plant.id, in: store.tasks, since: progress.readings.first?.date)

        return ScrollView {
            VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                headline(plant: plant, usual: usual, readingCount: progress.readings.count)

                if progress.readings.count >= 2 {
                    VStack(alignment: .leading, spacing: 10) {
                        PlantHealthRangeChart(
                            readings: progress.readings,
                            usual: usual,
                            usualLabel: "\(plant.nickname)'s usual",
                            waterings: waterings,
                            latestTint: plant.healthBand.color
                        )
                        if !waterings.isEmpty {
                            HStack(spacing: 6) {
                                Circle().fill(GroveTheme.hydration).frame(width: 7, height: 7)
                                Text(waterings.count == 1 ? "1 watering you logged" : "\(waterings.count) waterings you logged")
                            }
                            .font(.footnote)
                            .foregroundStyle(GroveTheme.mutedInk)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                if let comparison = progress.comparison {
                    thenAndNow(comparison, plant: plant)
                }

                if !indicators.isEmpty {
                    signals(indicators)
                }

                totals(plant: plant, progress: progress, checkIns: observations.count)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
    }

    /// Waterings logged across the chart's span. None before the first
    /// reading: the chart has no x position to put them at.
    static func waterings(for plantID: UUID, in tasks: [CareTask], since start: Date?, now: Date = .now) -> [Date] {
        guard let start else { return [] }
        return tasks
            .filter { $0.plantID == plantID && $0.kind == .water && $0.isCompleted }
            .map(\.performedAt)
            .filter { $0 >= start && $0 <= now }
            .sorted()
    }

    // MARK: Headline

    private func headline(plant: Plant, usual: PlantUsualRange?, readingCount: Int) -> some View {
        let position = usual?.position(of: plant.healthScore)
        let verdict: String = switch position {
        case .below: "Below its usual"
        case .within: "Within its usual"
        case .above: "Above its usual"
        case nil: plant.healthBand.title
        }
        let line: String
        if let usual {
            line = "It usually sits between \(usual.low) and \(usual.high)."
        } else if readingCount == 0 {
            line = "No check-ins yet. A check-in photo adds the first point."
        } else {
            let needed = PlantUsualRange.minimumPriorReadings + 1 - readingCount
            line = needed == 1
                ? "One more check-in shows \(plant.nickname)'s usual range."
                : "\(needed) more check-ins show \(plant.nickname)'s usual range."
        }

        return VStack(alignment: .leading, spacing: 8) {
            GroveEyebrow(text: readAge.map { "\(plant.nickname) · photo \($0)" } ?? plant.nickname)
            if plant.hasHealthReading {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(plant.healthScore)")
                        .font(GroveTheme.display(GroveDisplayStyle.hero.points))
                        .tracking(-0.4)
                        .monospacedDigit()
                        .foregroundStyle(plant.healthBand.color)
                    Text(verdict)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(plant.healthBand.color)
                }
            } else {
                Text("No reading yet")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            Text(line)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Then and now

    private func thenAndNow(_ comparison: PlantChangeStory.Comparison, plant: Plant) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Then and now")
            HStack(alignment: .top, spacing: 10) {
                photo(comparison.beforeURL, date: comparison.beforeDate)
                photo(comparison.nowURL, date: comparison.nowDate)
            }
            Button {
                Haptics.tap()
                routeOnExit = .plantStory(plant.id)
                dismiss()
            } label: {
                HStack {
                    Text("See every photo")
                        .font(.body)
                        .foregroundStyle(GroveTheme.ink)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GroveTheme.subtleInk)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func photo(_ url: URL, date: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ObservationThumbnail(url: url)
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
            Text(date.formatted(.dateTime.day().month(.abbreviated).year()))
                .font(.footnote)
                .foregroundStyle(GroveTheme.mutedInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Photo from \(date.formatted(date: .abbreviated, time: .omitted))")
    }

    // MARK: What the photo read

    private func signals(_ indicators: [PlantHealthIndicator]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                sectionTitle("What the last photo showed")
                Text("The same six things, every check-in")
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            VStack(spacing: 0) {
                ForEach(Array(indicators.enumerated()), id: \.element.id) { index, indicator in
                    if index > 0 {
                        Rectangle().fill(GroveTheme.separator).frame(height: 1).padding(.leading, 16)
                    }
                    signalRow(indicator)
                }
            }
            .groveCard(padding: 0)
        }
    }

    private func signalRow(_ indicator: PlantHealthIndicator) -> some View {
        let presentation = PlantHealthIndicatorPresentation(indicator: indicator)
        // Red is the plant (DESIGN.md 9b): a signal asking for attention takes
        // the plant-attention colour, never the calendar's amber.
        let tint: Color = !indicator.hasReading
            ? GroveTheme.subtleInk
            : presentation.priority == 0 ? GroveTheme.healthAttention : GroveTheme.healthHealthy
        let value = indicator.hasReading ? presentation.title : "Not checked yet"
        return HStack(spacing: 10) {
            Text(indicator.kind.label)
                .font(.body)
                .foregroundStyle(GroveTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(presentation.priority == 0 && indicator.hasReading ? tint : GroveTheme.mutedInk)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }

    // MARK: So far

    private func totals(plant: Plant, progress: PlantPageProgress, checkIns: Int) -> some View {
        let since = plant.acquiredAt ?? store.observations(for: plant.id).map(\.createdAt).min()
        let first = progress.readings.first?.score
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("So far")
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 18) {
                        GroveStatCell(
                            label: "In your grove",
                            value: since.map { $0.formatted(.dateTime.day().month(.abbreviated).year()) } ?? "New"
                        )
                        GroveStatCell(label: "Check-ins", value: "\(checkIns)")
                        if let first, progress.readings.count >= 2 {
                            GroveStatCell(label: "First health", value: "\(first)")
                            GroveStatCell(
                                label: "Health now",
                                value: "\(plant.healthScore)",
                                tint: plant.healthScore < first ? GroveTheme.danger
                                    : plant.healthScore > first ? GroveTheme.healthThriving : GroveTheme.ink
                            )
                        }
                    }
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 18) {
                        GridRow {
                            GroveStatCell(
                                label: "In your grove",
                                value: since.map { $0.formatted(.dateTime.day().month(.abbreviated).year()) } ?? "New"
                            )
                            GroveStatCell(label: "Check-ins", value: "\(checkIns)")
                        }
                        if let first, progress.readings.count >= 2 {
                            GridRow {
                                GroveStatCell(label: "First health", value: "\(first)")
                                GroveStatCell(
                                    label: "Health now",
                                    value: "\(plant.healthScore)",
                                    tint: plant.healthScore < first ? GroveTheme.danger
                                        : plant.healthScore > first ? GroveTheme.healthThriving : GroveTheme.ink
                                )
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .groveCard()
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .foregroundStyle(GroveTheme.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Health over time against the plant's own usual range, with the waterings
/// logged along the floor so a run of them can be seen beside a fall.
private struct PlantHealthRangeChart: View {
    let readings: [PlantPageProgress.Reading]
    let usual: PlantUsualRange?
    let usualLabel: String
    let waterings: [Date]
    let latestTint: Color

    /// Clamped to a minimum span so three points of noise cannot fill the
    /// frame and read as a collapse.
    private var domain: ClosedRange<Int> {
        let scores = readings.map(\.score) + [usual?.low, usual?.high].compactMap { $0 }
        let smallest = scores.min() ?? 50
        let largest = scores.max() ?? 90
        let span = max(30, largest - smallest + 12)
        var low = max(0, (smallest + largest - span) / 2)
        let high = min(100, low + span)
        if high - low < span { low = max(0, high - span) }
        return low...high
    }

    var body: some View {
        let domain = domain
        Chart {
            if let usual, let first = readings.first?.date, let last = readings.last?.date {
                RectangleMark(
                    xStart: .value("From", first),
                    xEnd: .value("To", last),
                    yStart: .value("Usual low", usual.low),
                    yEnd: .value("Usual high", usual.high)
                )
                .foregroundStyle(GroveTheme.softAccent)
                .annotation(position: .overlay, alignment: .topLeading) {
                    Text(usualLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GroveTheme.accentStrong)
                        .padding(4)
                }
            }
            ForEach(Array(readings.enumerated()), id: \.offset) { _, reading in
                LineMark(x: .value("Date", reading.date), y: .value("Health", reading.score))
                    .foregroundStyle(GroveTheme.accentStrong)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let last = readings.last {
                PointMark(x: .value("Date", last.date), y: .value("Health", last.score))
                    .foregroundStyle(latestTint)
                    .symbolSize(80)
            }
            ForEach(waterings, id: \.self) { date in
                PointMark(x: .value("Watered", date), y: .value("Health", domain.lowerBound))
                    .foregroundStyle(GroveTheme.hydration)
                    .symbolSize(24)
            }
        }
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(GroveTheme.separator)
                AxisValueLabel()
            }
        }
        .frame(height: 180)
        .accessibilityLabel("Health over time")
        .accessibilityValue(spoken)
    }

    private var spoken: String {
        guard let first = readings.first, let last = readings.last else { return "" }
        var text = "\(readings.count) scores, from \(first.score) on \(first.date.formatted(date: .abbreviated, time: .omitted)) to \(last.score) on \(last.date.formatted(date: .abbreviated, time: .omitted))."
        if let usual { text += " Usual range \(usual.low) to \(usual.high)." }
        return text
    }
}

// MARK: - Care guide

/// The species guide, one tap from the board. It was built, reviewed and
/// sourced, and then left unreachable when the page became a board.
struct PlantCareGuideSheet: View {
    let plant: Plant

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                PlantCareGuide(plant: plant)
                    .groveCard()
                    .padding(.horizontal, GroveTheme.pagePadding)
                    .padding(.vertical, 18)
            }
            .groveBackground()
            .navigationTitle("Care guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.bold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// The short answer for the board's row: the light this species wants,
    /// up to the first qualification.
    static func rowDetail(for plant: Plant) -> String {
        let profile = PlantCareProfile(plant: plant)
        guard profile.matchedSpecies else {
            return PlantIdentityState.needsResolving(plant) ? "Not confirmed" : "No guide yet"
        }
        return profile.lightHeadline
    }
}
