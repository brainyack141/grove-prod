import SwiftUI
import UIKit

/// The state a badge can honestly present from Grove's persisted progress.
///
/// The persisted unlock set is the source of truth. New awards also carry real
/// timestamps; migrated awards stay undated instead of pretending migration
/// day is when the work happened.
enum JourneyBadgeDisplayState: Hashable {
    case earned
    case locked(detail: String, fraction: Double?)

    var isEarned: Bool {
        if case .earned = self { return true }
        return false
    }

    var detail: String {
        switch self {
        case .earned:
            "Earned"
        case .locked(let detail, _):
            detail
        }
    }

    var fraction: Double? {
        if case .locked(_, let fraction) = self { return fraction }
        return nil
    }
}

struct JourneyBadgePresentation: Identifiable, Hashable {
    let badge: Badge
    let state: JourneyBadgeDisplayState
    let earnedAt: Date?
    let guidance: JourneyBadgeGuidance
    /// Campaign badges only become actionable once their chapter is open.
    /// Learning and care-history badges are available from the start.
    let isAvailable: Bool

    var id: String { badge.id }

    /// "3 Aug", or "3 Aug 2025" for an earlier year. Nil for a badge earned
    /// before dates were kept.
    var earnedDateText: String? {
        guard let earnedAt else { return nil }
        let thisYear = Calendar.current.isDate(earnedAt, equalTo: .now, toGranularity: .year)
        return thisYear
            ? earnedAt.formatted(.dateTime.day().month(.abbreviated))
            : earnedAt.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// The instruction behind a collectible.
///
/// Progress answers "how far?"; this answers the more important first-use
/// question, "what do I actually do?" Keeping it structured also lets the
/// detail sheet offer the right next move without parsing display copy.
struct JourneyBadgeGuidance: Hashable {
    enum Action: Hashable {
        case addPlant
        case checkIn
        /// An Academy lesson: the only lessons `lessonsLearned` counts.
        case learn
        /// A lesson or quiz step on the Journey itself.
        case journeyStep
        case plantSitting
        case streak
    }

    let goal: String
    let explanation: String
    let action: Action?

    var isStreak: Bool { action == .streak }
}

enum JourneyBadgeGuidanceResolver {
    static func guidance(for badge: Badge) -> JourneyBadgeGuidance {
        if let achievement = JourneyLibrary.learnAchievements.first(where: { $0.badge.id == badge.id }) {
            return guidance(for: achievement.requirement)
        }
        if let achievement = JourneyLibrary.careAchievements.first(where: { $0.badge.id == badge.id }) {
            return guidance(
                for: achievement.requirement,
                fallbackGoal: badge.title,
                fallbackExplanation: badge.blurb
            )
        }
        if let milestone = JourneyLibrary.chapters
            .lazy
            .flatMap(\.milestones)
            .first(where: { $0.badgeID == badge.id }) {
            return guidance(
                for: milestone.requirement,
                fallbackGoal: milestone.title,
                fallbackExplanation: milestone.blurb
            )
        }
        return JourneyBadgeGuidance(
            goal: "Keep growing your grove",
            explanation: badge.blurb,
            action: nil
        )
    }

    /// What to do for a keepsake that isn't kept yet: the goal of the step
    /// that awards it.
    static func goal(forKeepsake keepsakeID: String) -> String? {
        guard let milestone = JourneyLibrary.chapters
            .lazy
            .flatMap(\.milestones)
            .first(where: { $0.keepsakeID == keepsakeID })
        else { return nil }
        return guidance(
            for: milestone.requirement,
            fallbackGoal: milestone.title,
            fallbackExplanation: milestone.blurb
        ).goal
    }

    private static func guidance(for requirement: LearnAchievement.Requirement) -> JourneyBadgeGuidance {
        switch requirement {
        case .lessonsLearned(let target):
            return lessonGuidance(target: target)
        case .streakReached(let days):
            return streakGuidance(days: days)
        }
    }

    private static func guidance(
        for requirement: MilestoneRequirement,
        fallbackGoal: String,
        fallbackExplanation: String
    ) -> JourneyBadgeGuidance {
        switch requirement {
        case .interactive:
            return JourneyBadgeGuidance(
                goal: fallbackGoal,
                explanation: fallbackExplanation,
                action: .journeyStep
            )
        case .chest:
            return JourneyBadgeGuidance(
                goal: fallbackGoal,
                explanation: fallbackExplanation,
                action: nil
            )
        case .careLogged(let target):
            return JourneyBadgeGuidance(
                goal: "Log \(target) real care \(target == 1 ? "action" : "actions")",
                explanation: "Log care you actually did, like a trim, a turn or a repot.",
                action: nil
            )
        case .checkInsCompleted(let target):
            return JourneyBadgeGuidance(
                goal: "Complete \(target) plant \(target == 1 ? "check-in" : "check-ins")",
                explanation: "Save a check-in whenever a plant is due one.",
                action: .checkIn
            )
        case .plantsOwned(let target):
            return JourneyBadgeGuidance(
                goal: target == 1 ? "Add your first plant" : "Add \(target) plants to your grove",
                explanation: "Give each plant a name, a place, and a record in Grove.",
                action: .addPlant
            )
        case .plantReachedBand(let band):
            return JourneyBadgeGuidance(
                goal: "Help one plant reach \(band.title)",
                explanation: "Use regular check-ins to follow one plant until its current health reaches \(band.title).",
                action: .checkIn
            )
        case .plantsHealthy(let target):
            return JourneyBadgeGuidance(
                goal: "Have \(target) plants Healthy at once",
                explanation: "Keep checking in until \(target) plants are Healthy or Thriving on the same day.",
                action: .checkIn
            )
        case .plantsThriving(let target):
            return JourneyBadgeGuidance(
                goal: "Have \(target) plants Thriving at once",
                explanation: "Keep checking in until \(target) plants are Thriving on the same day.",
                action: .checkIn
            )
        case .streakReached(let days):
            return streakGuidance(days: days)
        case .lessonsLearned(let target):
            return lessonGuidance(target: target)
        case .deepestTimeline(let target):
            return JourneyBadgeGuidance(
                goal: "Check in on one plant \(target) times",
                explanation: "Return to the same plant so its check-ins become a useful timeline.",
                action: .checkIn
            )
        case .distinctLocations(let target):
            return JourneyBadgeGuidance(
                goal: "Keep plants in \(target) different rooms",
                explanation: "Give your plants rooms so care advice matches where they live.",
                action: .addPlant
            )
        case .collectionsCreated(let target):
            return JourneyBadgeGuidance(
                goal: target == 1 ? "Create a plant collection" : "Create \(target) plant collections",
                explanation: "Group plants in My Grove in a way that helps you care for them.",
                action: nil
            )
        case .recoveredPlant:
            return JourneyBadgeGuidance(
                goal: "Help one plant recover to Healthy",
                explanation: "Follow a plant from Needs attention or worse back to Healthy with check-ins.",
                action: .checkIn
            )
        case .sitterInvited:
            return JourneyBadgeGuidance(
                goal: "Invite someone to sit for your plants",
                explanation: "Set up plant sitting and give your sitter the notes they need.",
                action: .plantSitting
            )
        case .newGrowthObserved(let target):
            return JourneyBadgeGuidance(
                goal: "Record new growth in \(target) check-ins",
                explanation: "Mark new growth when you genuinely see it during a plant check-in.",
                action: .checkIn
            )
        case .healthyCheckInRun(let target):
            return JourneyBadgeGuidance(
                goal: "Keep one plant Healthy for \(target) check-ins",
                explanation: "Record \(target) Healthy-or-better check-ins in a row for the same plant.",
                action: .checkIn
            )
        case .recoveredPlants(let target):
            return JourneyBadgeGuidance(
                goal: "Help \(target) plants recover to Healthy",
                explanation: "Bring \(target) different plants from Needs attention or worse back to Healthy.",
                action: .checkIn
            )
        case .sitterCareCompleted(let target):
            return JourneyBadgeGuidance(
                goal: "Finish \(target) plant sitting \(target == 1 ? "task" : "tasks")",
                explanation: "Give your sitter real plant care to do and have them mark it done.",
                action: .plantSitting
            )
        }
    }

    /// Only Academy lessons count here. Lesson steps on the Journey pay their
    /// own XP but never add to `lessonsLearned`.
    private static func lessonGuidance(target: Int) -> JourneyBadgeGuidance {
        JourneyBadgeGuidance(
            goal: "Finish \(target) Academy \(target == 1 ? "lesson" : "lessons")",
            explanation: "Each Academy lesson ends with one question.",
            action: .learn
        )
    }

    private static func streakGuidance(days: Int) -> JourneyBadgeGuidance {
        JourneyBadgeGuidance(
            goal: "Keep a \(days)-day streak",
            explanation: "On \(days) consecutive days, do one thing that counts, like a check-in or a lesson.",
            action: .streak
        )
    }
}

/// Resolves badge presentation in one pass for both My Grove and Badges.
/// Campaign badges read the same evaluated milestones as the Journey;
/// learning badges read the Academy totals that actually award them.
@MainActor
enum JourneyBadgePresentationResolver {
    static func presentations(store: GroveStore) -> [JourneyBadgePresentation] {
        let unlocked = store.gardener.unlockedBadgeIDs
        let campaign = store.resolvedCampaign()
        let learnedLessons = store.learnedLessonCount(in: LearnLibrary.all)

        var campaignMilestones: [String: (ResolvedMilestone, ResolvedChapter)] = [:]
        for chapter in campaign {
            for milestone in chapter.milestones {
                if let badgeID = milestone.milestone.badgeID {
                    campaignMilestones[badgeID] = (milestone, chapter)
                }
            }
        }

        let learningAchievements = Dictionary(
            uniqueKeysWithValues: JourneyLibrary.learnAchievements.map { ($0.badge.id, $0) }
        )
        let careAchievements = Dictionary(
            uniqueKeysWithValues: JourneyLibrary.careAchievements.map { ($0.badge.id, $0) }
        )

        return JourneyLibrary.badges.map { badge in
            let guidance = JourneyBadgeGuidanceResolver.guidance(for: badge)

            if unlocked.contains(badge.id) {
                return JourneyBadgePresentation(
                    badge: badge,
                    state: .earned,
                    earnedAt: store.gardener.unlockedBadgeDates[badge.id],
                    guidance: guidance,
                    isAvailable: true
                )
            }

            if let (resolved, chapter) = campaignMilestones[badge.id] {
                return JourneyBadgePresentation(
                    badge: badge,
                    state: campaignState(for: resolved, in: chapter),
                    earnedAt: nil,
                    guidance: guidance,
                    isAvailable: chapter.isUnlocked
                )
            }

            if let achievement = learningAchievements[badge.id] {
                return JourneyBadgePresentation(
                    badge: badge,
                    state: learningState(
                        for: achievement,
                        learnedLessons: learnedLessons,
                        longestStreak: store.gardener.longestStreak
                    ),
                    earnedAt: nil,
                    guidance: guidance,
                    isAvailable: true
                )
            }

            if let achievement = careAchievements[badge.id] {
                return JourneyBadgePresentation(
                    badge: badge,
                    state: careState(for: achievement, store: store),
                    earnedAt: nil,
                    guidance: guidance,
                    isAvailable: true
                )
            }

            return JourneyBadgePresentation(
                badge: badge,
                state: .locked(detail: "Keep growing", fraction: nil),
                earnedAt: nil,
                guidance: guidance,
                isAvailable: false
            )
        }
    }

    private static func campaignState(
        for resolved: ResolvedMilestone,
        in chapter: ResolvedChapter
    ) -> JourneyBadgeDisplayState {
        guard chapter.isUnlocked else {
            return .locked(detail: "Chapter \(chapter.chapter.number)", fraction: nil)
        }

        let current = min(resolved.current, resolved.target)
        let target = resolved.target
        let fraction = target > 1 ? Double(current) / Double(target) : nil
        let detail: String

        switch resolved.milestone.requirement {
        case .careLogged:
            detail = counted(current, target, singular: "care log", plural: "care logs")
        case .checkInsCompleted, .deepestTimeline:
            detail = counted(current, target, singular: "check-in", plural: "check-ins")
        case .plantsOwned:
            detail = counted(current, target, singular: "plant", plural: "plants")
        case .plantsHealthy:
            detail = "\(current) of \(target) healthy"
        case .plantsThriving:
            detail = "\(current) of \(target) thriving"
        case .streakReached:
            detail = "Best: " + counted(current, target, singular: "day", plural: "days")
        case .lessonsLearned:
            detail = counted(current, target, singular: "lesson", plural: "lessons")
        case .distinctLocations:
            detail = counted(current, target, singular: "room", plural: "rooms")
        case .collectionsCreated:
            detail = counted(current, target, singular: "collection", plural: "collections")
        case .interactive, .plantReachedBand, .recoveredPlant, .sitterInvited, .chest:
            // One-off steps have no count to show; the sheet reads this as
            // the value under "Progress".
            detail = "Not yet"
        case .newGrowthObserved:
            detail = counted(current, target, singular: "new-growth check-in", plural: "new-growth check-ins")
        case .healthyCheckInRun:
            detail = "\(current) of \(target) healthy in a row"
        case .recoveredPlants:
            detail = "\(current) of \(target) recovered"
        case .sitterCareCompleted:
            detail = counted(current, target, singular: "sitting task", plural: "sitting tasks")
        }

        return .locked(detail: detail, fraction: fraction)
    }

    private static func careState(
        for achievement: CareAchievement,
        store: GroveStore
    ) -> JourneyBadgeDisplayState {
        let progress = store.badgeProgress(for: achievement)
        let current = min(progress.current, progress.target)
        let target = progress.target
        let fraction = target > 1 ? Double(current) / Double(target) : nil
        let detail: String

        switch achievement.requirement {
        case .deepestTimeline:
            detail = counted(current, target, singular: "check-in", plural: "check-ins")
        case .newGrowthObserved:
            detail = counted(current, target, singular: "new-growth check-in", plural: "new-growth check-ins")
        case .healthyCheckInRun:
            detail = "\(current) of \(target) healthy in a row"
        case .recoveredPlants:
            detail = "\(current) of \(target) recovered"
        case .sitterCareCompleted:
            detail = counted(current, target, singular: "sitting task", plural: "sitting tasks")
        default:
            detail = "Keep growing"
        }

        return .locked(detail: detail, fraction: fraction)
    }

    private static func learningState(
        for achievement: LearnAchievement,
        learnedLessons: Int,
        longestStreak: Int
    ) -> JourneyBadgeDisplayState {
        switch achievement.requirement {
        case .lessonsLearned(let target):
            let current = min(learnedLessons, target)
            return .locked(
                detail: counted(current, target, singular: "lesson", plural: "lessons"),
                fraction: Double(current) / Double(target)
            )
        case .streakReached(let target):
            let current = min(longestStreak, target)
            return .locked(
                detail: "Best: " + counted(current, target, singular: "day", plural: "days"),
                fraction: Double(current) / Double(target)
            )
        }
    }

    private static func counted(
        _ current: Int,
        _ target: Int,
        singular: String,
        plural: String
    ) -> String {
        "\(current) of \(target) \(target == 1 ? singular : plural)"
    }
}

/// The shared badge artwork. Locked badges keep the same commissioned image so
/// the user can recognise what they are working toward; only its material loses
/// colour. The SF Symbol remains a runtime fallback if an asset is ever missing.
///
/// Drawn flat, like every object on the board: one even disc behind the art,
/// no light raking across it and no coloured glow under it.
struct JourneyBadgeMedallion: View {
    let badge: Badge
    let state: JourneyBadgeDisplayState
    var size: CGFloat = 68

    private var symbolSize: CGFloat { size * 0.42 }
    private var lockSize: CGFloat { max(20, size * 0.31) }

    private var disc: Color {
        state.isEarned
            ? (badge.palette.colors.last ?? GroveTheme.accent).opacity(0.14)
            : GroveTheme.secondarySurface
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(disc)

            if UIImage(named: badge.artworkAsset) != nil {
                Image(badge.artworkAsset)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size * 0.88, height: size * 0.88)
                    .saturation(state.isEarned ? 1 : 0)
                    .opacity(state.isEarned ? 1 : 0.44)
            } else {
                Image(systemName: badge.symbol)
                    .font(.system(size: symbolSize, weight: .bold))
                    .foregroundStyle(
                        state.isEarned ? GroveTheme.accentStrong : GroveTheme.subtleInk.opacity(0.72)
                    )
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if !state.isEarned {
                Circle().strokeBorder(GroveTheme.separator, lineWidth: 1)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !state.isEarned {
                Image(systemName: "lock.fill")
                    .font(.system(size: lockSize * 0.38, weight: .black))
                    .foregroundStyle(GroveTheme.mutedInk)
                    .frame(width: lockSize, height: lockSize)
                    .background(GroveTheme.surface, in: Circle())
                    .overlay { Circle().stroke(GroveTheme.separator, lineWidth: 1) }
                    .offset(x: 2, y: 2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One badge, opened from the Badges page: what it is, how far along you are,
/// and the one thing to do next.
struct JourneyBadgeDetailSheet: View {
    let item: JourneyBadgePresentation

    @Environment(GroveStore.self) private var store
    @Environment(IntentRouter.self) private var intentRouter
    @Environment(\.dismiss) private var dismiss
    @State private var routeOnExit: AppRoute?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Still, every time. The turn and the burst of light belong
                    // to the moment a badge is won, which the unlock overlay
                    // owns; a badge opened again is being looked at, not won
                    // again.
                    JourneyBadgeMedallion(badge: item.badge, state: item.state, size: 112)

                    headline

                    if !facts.isEmpty {
                        JourneyFactRow(facts: facts)
                    }

                    if !item.state.isEarned {
                        if item.guidance.isStreak {
                            StreakQualifyingActionsCard()
                        }

                        Text("It joins your badges the moment you earn it.")
                            .font(.footnote)
                            .foregroundStyle(GroveTheme.subtleInk)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .groveBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) { callToAction }
            .groveEditorialPage("Badge")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onDisappear {
            guard let routeOnExit else { return }
            intentRouter.pushedRoute = routeOnExit
        }
    }

    private var headline: some View {
        VStack(spacing: 8) {
            GroveEyebrow(
                text: eyebrow,
                color: item.state.isEarned ? GroveTheme.goldDeep : GroveTheme.mutedInk
            )
            GroveDisplayHeading(text: item.badge.title, style: .title)
                .multilineTextAlignment(.center)

            Text(item.state.isEarned ? item.badge.blurb : item.guidance.goal)
                .font(item.state.isEarned ? .body : .title3.weight(.semibold))
                .foregroundStyle(item.state.isEarned ? GroveTheme.mutedInk : GroveTheme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if !item.state.isEarned {
                Text(item.guidance.explanation)
                    .font(.body)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var eyebrow: String {
        if item.state.isEarned { return "Earned" }
        return item.isAvailable ? "How to earn it" : "Not open yet"
    }

    // MARK: Facts

    /// Where this badge stands, as small caps over values. Every number and
    /// date on the sheet lives here rather than in a coloured line of text.
    private var facts: [JourneyFactRow.Fact] {
        if item.state.isEarned {
            var facts: [JourneyFactRow.Fact] = []
            if let date = item.earnedAt {
                facts.append(.init(
                    label: "Earned",
                    value: date.formatted(.dateTime.day().month(.abbreviated).year())
                ))
            }
            facts.append(.init(label: "Badges", value: "\(earnedBadgeCount) of \(JourneyLibrary.badges.count)"))
            return facts
        }

        guard item.isAvailable else {
            return [.init(label: "Opens in", value: item.state.detail)]
        }

        if item.guidance.isStreak {
            let streak = store.displayStreak
            return [
                .init(label: "Best run", value: bestRunValue),
                .init(
                    label: "Streak",
                    value: streak == 1 ? "1 day" : "\(streak) days",
                    tint: streak > 0 ? GroveTheme.streak : nil
                ),
                .init(label: "Today", value: store.streakCountedToday ? "Counted" : "Not yet")
            ]
        }

        var facts: [JourneyFactRow.Fact] = [.init(label: "Progress", value: item.state.detail)]
        // Nothing due today means no button, so say when the next chance is
        // rather than leave the sheet without a way forward.
        if item.guidance.action == .checkIn,
           dueCheckInPlant == nil,
           let next = store.plants.min(by: { $0.nextCheckIn < $1.nextCheckIn }) {
            facts.append(.init(
                label: "Next check-in",
                value: next.nextCheckIn.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            ))
        }
        return facts
    }

    /// The resolver spells a streak badge's progress as "Best: 1 of 3 days";
    /// under a "Best run" label the prefix would say it twice.
    private var bestRunValue: String {
        let detail = item.state.detail
        let prefix = "Best: "
        return detail.hasPrefix(prefix) ? String(detail.dropFirst(prefix.count)) : detail
    }

    private var earnedBadgeCount: Int {
        let unlocked = store.gardener.unlockedBadgeIDs
        return JourneyLibrary.badges.filter { unlocked.contains($0.id) }.count
    }

    /// The plant due a check-in soonest, if one is due by tonight. A badge
    /// never asks for an early photo just to move a number.
    private var dueCheckInPlant: Plant? {
        let calendar = Calendar.current
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
        return store.plants
            .filter { $0.nextCheckIn < endOfToday }
            .min { $0.nextCheckIn < $1.nextCheckIn }
    }

    // MARK: Action

    @ViewBuilder
    private var callToAction: some View {
        if let action = nextAction {
            GroveCTAButton(title: action.title) {
                routeOnExit = action.route
                dismiss()
            }
            .groveActionBar()
        }
    }

    private var nextAction: (title: String, route: AppRoute)? {
        guard !item.state.isEarned, item.isAvailable, let action = item.guidance.action else {
            return nil
        }

        switch action {
        case .addPlant:
            return ("Add a plant", .addPlant)
        case .checkIn:
            guard !store.plants.isEmpty else { return ("Add your first plant", .addPlant) }
            return checkInAction
        case .learn:
            return lessonAction
        case .journeyStep:
            return ("Open your Journey", .journey)
        case .plantSitting:
            return store.plants.isEmpty
                ? ("Add your first plant", .addPlant)
                : ("Set up plant sitting", .sitting)
        case .streak:
            guard !store.streakCountedToday else { return nil }
            return checkInAction ?? lessonAction
        }
    }

    private var checkInAction: (title: String, route: AppRoute)? {
        guard let plant = dueCheckInPlant else { return nil }
        return ("Check in on \(plant.nickname)", .checkIn(plant.id))
    }

    /// The next Academy lesson not yet finished. Lessons are what count, so
    /// the button goes straight to one.
    private var lessonAction: (title: String, route: AppRoute)? {
        guard let next = LearnLibrary.all.first(where: { !store.isLessonLearned($0.id) }) else {
            return nil
        }
        return ("Read “\(next.title)”", .learnTopic(next.id))
    }
}
