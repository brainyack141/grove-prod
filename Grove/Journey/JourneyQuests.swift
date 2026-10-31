import SwiftUI

// MARK: - Model

/// One of today's three jobs. Quests are the Journey's session loop: the reason
/// there is something to do *today* rather than only when a plant happens to
/// cross a milestone.
///
/// Every quest is a real care action Grove already asks for. There is no
/// "open the app" quest and there never will be — `GROVE.md` rules out
/// mechanics that reward engagement for its own sake, and a quest board is the
/// easiest place in a product to break that rule by accident.
struct DailyQuest: Identifiable, Hashable {
    enum Objective: String, Hashable {
        /// A completed check-in, or adding a plant.
        case look
        /// Do something for a plant and write it down.
        case tend
        /// Ask Ari about a plant, or finish an Academy lesson.
        case learn
        /// All three of the above, in one day.
        case sweep
    }

    let id: String
    let objective: Objective
    let title: String
    let detail: String
    let xp: Int
    let target: Int
    let current: Int
    let isClaimed: Bool

    var isComplete: Bool { current >= target }
    var isClaimable: Bool { isComplete && !isClaimed }

    var fraction: Double {
        guard target > 0 else { return 0 }
        return min(1, Double(current) / Double(target))
    }

    /// The colour a finished quest's mark takes wherever the board is
    /// summarised (the Today card's dots). Green means done, so each of the
    /// three finishes green; the bonus is gold because it is a reward.
    /// Learning used to be purple, which is plant sitting's colour.
    var tint: Color {
        switch objective {
        case .look, .tend, .learn: GroveTheme.accent
        case .sweep: GroveTheme.goldDeep
        }
    }
}

/// Builds today's board. Pure and deterministic: the same day and the same
/// progress always produce the same three quests, so the board never reshuffles
/// under the player mid-session.
enum JourneyQuestBoard {

    /// Wording rotates by day so the board doesn't read like a printed form,
    /// while the underlying objective stays the same three things.
    ///
    /// Every variant names a check-in, because a check-in (or adding a plant)
    /// is the only thing that finishes it. The soil check these used to name
    /// is retired, and "go and see how one is doing" promised credit for
    /// looking that the counter never paid.
    private static let checkInCopy = [
        "Check in on one plant",
        "Do one check-in",
        "Take a check-in photo"
    ]
    private static let tendCopy = [
        "Do one care job, and log it",
        "Log something you did today",
        "One care job, written down"
    ]
    // Surface-agnostic since Ask replaced the Learn tab: a question about a real
    // plant and an Academy lesson both satisfy this.
    private static let learnCopy = [
        "Learn one thing",
        "Ask about one of your plants",
        "Finish a lesson, or ask Ari"
    ]

    /// Today's quests, in board order.
    ///
    /// The check-in quest always asks for one. It used to ask for two on a
    /// third of days, but a check-in only happens when a plant is due one, and
    /// most days none is: asking for two made an already scarce quest
    /// impossible.
    ///
    /// - Parameters:
    ///   - progress: the player's stored counters.
    ///   - plantsOwned: with no plants there is nothing to check in on, so the
    ///     quest asks for the first plant instead.
    ///   - date: the day being scored. Defaults to now.
    static func quests(
        progress: GardenerProgress,
        plantsOwned: Int,
        date: Date = .now
    ) -> [DailyQuest] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        let isToday = progress.questDay.map { calendar.isDate($0, inSameDayAs: today) } ?? false
        let checkIns = isToday ? progress.questCheckIns : 0
        let care = isToday ? progress.questCareLogged : 0
        let lessons = isToday ? progress.questLessons : 0
        let claimed = isToday ? progress.claimedQuestIDs : []

        let dayIndex = calendar.ordinality(of: .day, in: .year, for: today) ?? 0
        let variant = dayIndex % 3

        let look = DailyQuest(
            id: "q-look",
            objective: .look,
            title: plantsOwned == 0 ? "Add your first plant" : checkInCopy[variant],
            detail: plantsOwned == 0
                ? "Adding a plant counts for today."
                : "A check-in counts. So does adding a plant.",
            xp: 20,
            target: 1,
            current: checkIns,
            isClaimed: claimed.contains("q-look")
        )
        let tend = DailyQuest(
            id: "q-tend",
            objective: .tend,
            title: tendCopy[variant],
            detail: "A trim, a turn, a wipe of the leaves, a repot.",
            xp: 15,
            target: 1,
            current: care,
            isClaimed: claimed.contains("q-tend")
        )
        let learn = DailyQuest(
            id: "q-learn",
            objective: .learn,
            title: learnCopy[variant],
            detail: "Ask Ari about one of your plants, or finish an Academy lesson.",
            xp: 15,
            target: 1,
            current: lessons,
            isClaimed: claimed.contains("q-learn")
        )

        let doneCount = [look, tend, learn].filter(\.isComplete).count
        let sweep = DailyQuest(
            id: "q-sweep",
            objective: .sweep,
            title: "Clean sweep",
            detail: "A bonus for doing all three today.",
            xp: 30,
            target: 3,
            current: doneCount,
            isClaimed: claimed.contains("q-sweep")
        )

        return [look, tend, learn, sweep]
    }

    /// How many of the three real quests are finished today, ignoring the
    /// sweep bonus, and how many rewards (bonus included) wait to be collected.
    /// Powers the Today card and the board's own "Done" fact.
    static func summary(_ quests: [DailyQuest]) -> (done: Int, total: Int, claimable: Int) {
        let core = quests.filter { $0.objective != .sweep }
        return (
            core.filter(\.isComplete).count,
            core.count,
            quests.filter(\.isClaimable).count
        )
    }
}

// MARK: - Board

/// Today's three, presented as a sheet from the Journey page.
///
/// One list rather than a stack of cards: each quest is a hairline row with its
/// state drawn as a small mark, what counts written underneath, and the one
/// thing you can do about it at the end. A row that can be finished somewhere
/// else opens that place when tapped; a finished one offers its XP in place.
struct QuestBoardView: View {
    @Environment(GroveStore.self) private var store
    @Environment(IntentRouter.self) private var intentRouter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var quests: [DailyQuest] {
        JourneyQuestBoard.quests(progress: store.gardener, plantsOwned: store.plants.count)
    }

    var body: some View {
        let board = quests
        let outlook = checkInOutlook

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(lede(board))
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)

                facts(board)

                VStack(spacing: 0) {
                    ForEach(Array(board.enumerated()), id: \.element.id) { index, quest in
                        QuestBoardRow(
                            quest: quest,
                            detail: detail(for: quest, outlook: outlook),
                            destination: destination(for: quest, outlook: outlook),
                            onClaim: { claim(quest) }
                        )
                        if index < board.count - 1 {
                            GroveRowDivider(inset: QuestBoardRow.markWidth + 12)
                        }
                    }
                }
                .padding(.top, 8)

                Text("Watering, feeding and treating never count, here or towards your streak.")
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.subtleInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 20)
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, GroveTheme.pageTopPadding)
            .padding(.bottom, 28)
        }
        .groveBackground()
        .groveEditorialPage("Today's three")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }

    // MARK: Header

    private func lede(_ board: [DailyQuest]) -> String {
        if board.allSatisfy(\.isClaimed) { return "All collected for today. New ones at midnight." }
        if board.contains(where: \.isClaimable) { return "Resets at midnight. Collect before then." }
        return "Resets at midnight."
    }

    private func facts(_ board: [DailyQuest]) -> some View {
        let summary = JourneyQuestBoard.summary(board)
        let collected = board.filter(\.isClaimed).reduce(0) { $0 + $1.xp }
        let streak = store.displayStreak
        return JourneyFactRow(facts: [
            .init(
                label: "Done",
                value: "\(summary.done) of \(summary.total)",
                tint: summary.done == summary.total ? GroveTheme.accent : nil
            ),
            .init(
                label: "Collected",
                value: "\(collected) XP",
                tint: collected > 0 ? GroveTheme.goldDeep : nil
            ),
            .init(
                label: "Streak",
                value: streak == 1 ? "1 day" : "\(streak) days",
                tint: streak > 0 ? GroveTheme.streak : nil
            )
        ])
    }

    // MARK: The check-in quest

    /// Whether today can hold a check-in at all. The counters behind the board
    /// can't know when a plant is due, so the board itself says it: a quest
    /// that only a check-in can finish should name the plant that is due, or
    /// say plainly that none is.
    private enum CheckInOutlook {
        case noPlants
        case due(plantID: UUID, name: String, others: Int)
        case next(name: String, on: Date)
        case unscheduled
    }

    private var checkInOutlook: CheckInOutlook {
        guard !store.plants.isEmpty else { return .noPlants }
        let scheduled = store.pendingTasks.filter { $0.kind == .checkIn && !$0.isSittingTask }
        guard let soonest = scheduled.first else { return .unscheduled }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: store.calendarDay)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let due = scheduled.filter { $0.dueDate < tomorrow }
        if let first = due.first {
            let others = Set(due.map(\.plantID)).subtracting([first.plantID]).count
            return .due(plantID: first.plantID, name: name(of: first.plantID), others: others)
        }
        return .next(name: name(of: soonest.plantID), on: soonest.dueDate)
    }

    private func name(of plantID: UUID) -> String {
        store.plant(id: plantID)?.nickname ?? "A plant"
    }

    private func detail(for quest: DailyQuest, outlook: CheckInOutlook) -> String {
        guard quest.objective == .look, !quest.isComplete else { return quest.detail }
        switch outlook {
        case .due(_, let name, let others):
            return others == 0
                ? "\(name) is due a check-in."
                : "\(name) and \(others) more are due a check-in."
        case .next(let name, let date):
            return "No check-ins due today. \(name) is next, \(Self.when(date, from: store.calendarDay))."
        case .noPlants, .unscheduled:
            return quest.detail
        }
    }

    /// "tomorrow", "on Thursday", "on 14 Oct".
    private static func when(_ date: Date, from today: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: today),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        if days <= 1 { return "tomorrow" }
        if days < 7 { return "on \(date.formatted(.dateTime.weekday(.wide)))" }
        return "on \(date.formatted(.dateTime.day().month(.abbreviated)))"
    }

    // MARK: Actions

    /// Where tapping an unfinished row goes. Nil when there is nowhere honest
    /// to send someone: a check-in that isn't due yet, or a care job with more
    /// than one plant to choose from.
    private func destination(for quest: DailyQuest, outlook: CheckInOutlook) -> QuestDestination? {
        guard !quest.isComplete else { return nil }
        switch quest.objective {
        case .look:
            switch outlook {
            case .noPlants:
                return QuestDestination(hint: "Opens the camera to add a plant") {
                    dismiss()
                    // The camera is a cover over the whole app. Raising it
                    // while this sheet is still leaving puts two presentations
                    // in one frame, and one of them loses.
                    let router = intentRouter
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        router.startScan(.add)
                    }
                }
            case .due(let plantID, _, _):
                return QuestDestination(hint: "Starts the check-in") {
                    leave { intentRouter.startCheckIn(plantID) }
                }
            case .next, .unscheduled:
                // Sending someone to a photo check-in their care plan says is
                // days away is how the board taught people to over-check.
                return nil
            }
        case .tend:
            guard store.plants.count == 1, let plant = store.plants.first else { return nil }
            return QuestDestination(hint: "Opens \(plant.nickname)") {
                leave { intentRouter.openPlant(plant.id) }
            }
        case .learn:
            return QuestDestination(hint: "Opens Ask") {
                leave { intentRouter.requestedTab = .ask }
            }
        case .sweep:
            return nil
        }
    }

    private func leave(then route: () -> Void) {
        route()
        dismiss()
    }

    private func claim(_ quest: DailyQuest) {
        var claimed = false
        withAnimation(reduceMotion ? Animation.easeInOut(duration: 0.2) : GroveMotion.settle) {
            claimed = store.claimQuest(quest)
        }
        guard claimed else { return }
        Haptics.success()
    }
}

/// Where a board row goes when tapped, and how VoiceOver says so.
private struct QuestDestination {
    let hint: String
    let open: () -> Void
}

// MARK: - Row

/// One quest as a list row. Three shapes, by what the row can do:
/// - finished and uncollected: the summary, and a Collect button in place;
/// - unfinished with somewhere to go: the whole row is a button, ending in a
///   chevron;
/// - anything else: it only informs.
private struct QuestBoardRow: View {
    static let markWidth: CGFloat = 22

    let quest: DailyQuest
    let detail: String
    let destination: QuestDestination?
    let onClaim: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isLargeType: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        Group {
            if quest.isClaimable {
                claimable
            } else if let destination {
                Button(action: destination.open) {
                    HStack(spacing: 12) {
                        summary
                        if !isLargeType { xpText }
                        GroveRowChevron()
                    }
                    .contentShape(Rectangle())
                }
                // The press style's own haptic is the only one: no extra tap.
                .buttonStyle(GroveTilePressStyle())
                .accessibilityLabel(spokenSummary)
                .accessibilityHint(destination.hint)
            } else {
                HStack(spacing: 12) {
                    summary
                    if !isLargeType { xpText }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenSummary)
            }
        }
        .padding(.vertical, 12)
    }

    /// The summary and the button stay two VoiceOver elements, so Collect is
    /// always reachable. At accessibility sizes the button drops under the
    /// text rather than squeezing it to a word per line.
    private var claimable: some View {
        let layout: AnyLayout = isLargeType
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            summary
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenSummary)
            GroveInkButton(title: "Collect +\(quest.xp) XP", size: .compact, action: onClaim)
                .padding(.leading, isLargeType ? Self.markWidth + 12 : 0)
                .transition(.opacity)
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            QuestProgressMark(quest: quest)
                .frame(width: Self.markWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(quest.title)
                    .font(.body)
                    .foregroundStyle(quest.isClaimed ? GroveTheme.mutedInk : GroveTheme.ink)
                    .lineLimit(isLargeType ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .lineLimit(isLargeType ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                if isLargeType, !quest.isClaimable {
                    xpText.padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The bonus is the one reward on the board that isn't a job, so its XP
    /// is the gold one until it is collected.
    private var xpText: some View {
        Text("+\(quest.xp) XP")
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(
                quest.objective == .sweep && !quest.isClaimed ? GroveTheme.goldDeep : GroveTheme.mutedInk
            )
    }

    private var spokenSummary: String {
        if quest.isClaimed { return "\(quest.title). Collected \(quest.xp) XP." }
        if quest.isClaimable { return "\(quest.title). Done." }
        var text = "\(quest.title). \(detail)"
        if quest.target > 1 {
            text += " \(min(quest.current, quest.target)) of \(quest.target) done."
        }
        return text + (quest.objective == .sweep ? " \(quest.xp) XP bonus." : " \(quest.xp) XP.")
    }
}

/// A quest's state at glyph size: an empty ring, a green arc as it fills, a
/// gold ring when there is XP waiting, and a green tick once it is collected.
private struct QuestProgressMark: View {
    let quest: DailyQuest

    var body: some View {
        ZStack {
            if quest.isClaimed {
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(GroveTheme.accent)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Circle()
                    .strokeBorder(
                        quest.isComplete ? GroveTheme.gold : GroveTheme.subtleInk.opacity(0.45),
                        lineWidth: quest.isComplete ? 2 : 1.5
                    )
                if !quest.isComplete, quest.fraction > 0 {
                    Circle()
                        .inset(by: 1)
                        .trim(from: 0, to: quest.fraction)
                        .stroke(GroveTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
