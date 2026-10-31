import SwiftUI

// MARK: - Gardener level

/// The player's overall rank. Purely a function of accumulated XP, so it can be
/// recomputed from a single stored number and never drifts out of sync.
enum GardenerLevel: Int, CaseIterable, Codable, Hashable, Comparable {
    case seedling
    case sprout
    case sapling
    case gardener
    case botanist
    case groveKeeper
    case arborist
    case conservator
    case oldGrowth

    /// Cumulative XP required to *reach* this level. The first six thresholds
    /// are frozen — they shipped, and nobody gets demoted because the ladder
    /// grew a top. Everything above `groveKeeper` was appended.
    var xpThreshold: Int {
        switch self {
        case .seedling: 0
        case .sprout: 120
        case .sapling: 320
        case .gardener: 640
        case .botanist: 1_100
        case .groveKeeper: 1_800
        case .arborist: 2_900
        case .conservator: 4_400
        case .oldGrowth: 6_800
        }
    }

    var title: String {
        switch self {
        case .seedling: "Seedling"
        case .sprout: "Sprout"
        case .sapling: "Sapling"
        case .gardener: "Gardener"
        case .botanist: "Botanist"
        case .groveKeeper: "Grove Keeper"
        case .arborist: "Arborist"
        case .conservator: "Conservator"
        case .oldGrowth: "Old Growth"
        }
    }

    /// The line shown under the title on the level-up takeover. A plain
    /// statement of what the player did to get here, and nothing more (see
    /// `VOICE.md`: no aphorisms). The number is read from `xpThreshold` so the
    /// copy can't drift if the top of the ladder is retuned.
    var promotionBlurb: String {
        switch self {
        case .seedling: "Everyone starts here."
        case .oldGrowth: "You've earned \(xpThreshold.formatted()) XP. This is the top level."
        default: "You've earned \(xpThreshold.formatted()) XP from check-ins, lessons and Journey steps."
        }
    }

    var symbol: String {
        switch self {
        case .seedling: "circle.hexagongrid.fill"
        case .sprout: "leaf.fill"
        case .sapling: "camera.macro"
        case .gardener: "tree.fill"
        case .botanist: "graduationcap.fill"
        case .groveKeeper: "crown.fill"
        case .arborist: "mountain.2.fill"
        case .conservator: "shield.lefthalf.filled"
        case .oldGrowth: "laurel.leading"
        }
    }

    /// The commissioned rank family. Keeping the mapping beside the progression
    /// rules makes every place that wears a rank use the same artwork.
    var artworkAsset: String {
        switch self {
        case .seedling: "JourneySeedling"
        case .sprout: "JourneySprout"
        case .sapling: "JourneySapling"
        case .gardener: "JourneyGardener"
        case .botanist: "JourneyBotanist"
        case .groveKeeper: "JourneyGroveKeeper"
        case .arborist: "JourneyArborist"
        case .conservator: "JourneyConservator"
        case .oldGrowth: "JourneyOldGrowth"
        }
    }

    /// The level a given amount of XP resolves to.
    static func forXP(_ xp: Int) -> GardenerLevel {
        allCases.last { xp >= $0.xpThreshold } ?? .seedling
    }

    /// The next level up, or `nil` once the player has maxed out.
    var next: GardenerLevel? {
        GardenerLevel(rawValue: rawValue + 1)
    }

    static func < (lhs: GardenerLevel, rhs: GardenerLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A rank mark without a surrounding tile, for compact HUDs and profile chips.
struct GardenerLevelIcon: View {
    let level: GardenerLevel
    var size: CGFloat

    var body: some View {
        Image(level.artworkAsset)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Badges

enum BadgeCategory: String, CaseIterable, Identifiable, Hashable {
    case grove
    case observation
    case health
    case learning
    case sharedCare

    var id: Self { self }

    var title: String {
        switch self {
        case .grove: "Your grove"
        case .observation: "Check-ins & care"
        case .health: "Plant health"
        case .learning: "Learning & habit"
        case .sharedCare: "Plant sitting"
        }
    }

    var blurb: String {
        switch self {
        case .grove: "Grow your grove and give each plant a room."
        case .observation: "Check in on your plants and log what you do."
        case .health: "Healthy plants, new growth and plants you brought back."
        case .learning: "Grove Academy lessons and your daily streak."
        case .sharedCare: "Hand your plants to someone you trust."
        }
    }
}

/// A collectible achievement. Content is static; unlocked IDs live in
/// ``GardenerProgress``.
struct Badge: Identifiable, Hashable {
    let id: String
    let title: String
    let blurb: String
    /// Commissioned badge artwork. `symbol` remains the resilient fallback for
    /// a missing catalog entry and for non-visual contexts.
    let artworkAsset: String
    let symbol: String
    let palette: PlantPalette
    let category: BadgeCategory
}

// MARK: - Learning achievements

/// A badge earned purely through the Grove Academy: finishing lessons and
/// keeping the learning streak alive. Evaluated by the store whenever a
/// lesson completes, and worth bonus XP so learning also drives levels.
struct LearnAchievement: Identifiable, Hashable {
    enum Requirement: Hashable {
        /// At least `min` Academy lessons learned.
        case lessonsLearned(min: Int)
        /// Longest learning streak has reached `days`.
        case streakReached(days: Int)
    }

    let badge: Badge
    let requirement: Requirement
    let bonusXP: Int
    var id: String { badge.id }
}

/// A badge evaluated directly from Grove's care history rather than from a
/// gated campaign node. These carry no extra XP: the real work already pays
/// through the Journey, while the badge remains an honest record that can be
/// backfilled without changing somebody's level.
struct CareAchievement: Identifiable, Hashable {
    let badge: Badge
    let requirement: MilestoneRequirement
    var id: String { badge.id }
}

// MARK: - Player progression (persisted)

/// The entire mutable game state for one account. Small, `Codable`, and stored
/// inside the Grove snapshot so it inherits account isolation, reset, and
/// deletion for free.
///
/// Every field added after the first release is optional or defaulted — but a
/// default alone is *not* enough to make an old snapshot decode. See the
/// `Decodable` conformance below, which is what actually delivers that promise.
struct GardenerProgress: Codable, Hashable, Sendable {
    var xp: Int = 0
    /// Milestones that have been awarded. Guards award idempotency.
    var completedMilestoneIDs: Set<String> = []
    /// Lesson/quiz nodes the player has explicitly tapped through.
    var completedInteractiveIDs: Set<String> = []
    var unlockedBadgeIDs: Set<String> = []
    /// Real unlock dates for badges earned after this field shipped. Historical
    /// badges deliberately remain undated rather than pretending they were all
    /// earned on migration day.
    var unlockedBadgeDates: [String: Date] = [:]

    // Streak — plant-safe: driven by learning and inspection, never watering.
    var currentStreak: Int = 0
    var longestStreak: Int = 0
    /// Start-of-day of the most recent qualifying "tend". Used to advance,
    /// hold, or reset the streak.
    var lastTendDay: Date?
    /// Start-of-day of the most recent daily-refresher XP payout, so a repeat
    /// lesson pays at most once per day. Optional so older snapshots decode.
    var lastRefresherXPDay: Date?

    // MARK: Chests, keepsakes, shields

    /// Chests the player has actually opened. A chest is never paid out until
    /// it has been opened by hand — the whole point of a chest is the opening.
    var openedChestIDs: Set<String> = []
    /// Cosmetics earned and permanently planted in the player's world.
    var keepsakeIDs: Set<String> = []
    /// Authored landmarks the player has found while exploring the campaign.
    /// These are separate from keepsakes because discoveries are map moments,
    /// not rewards for a care milestone.
    var discoveredLandmarkIDs: Set<String> = []
    /// Unspent streak shields. One is burned automatically to cover a single
    /// missed day, so a good habit survives one bad week.
    var streakShields: Int = 0
    /// Streak length at which the last shield was granted, so the seven-day
    /// grant fires once per seven days rather than on every tend.
    var lastShieldStreak: Int = 0

    // MARK: Daily quests

    /// Start-of-day the quest counters below belong to. When it isn't today,
    /// the counters are stale and read as zero.
    var questDay: Date?
    var questCheckIns: Int = 0
    var questCareLogged: Int = 0
    var questLessons: Int = 0
    var questPlantsAdded: Int = 0
    /// Quest IDs already paid out today. Cleared with the counters.
    var claimedQuestIDs: Set<String> = []

    static let new = GardenerProgress()

    var level: GardenerLevel { GardenerLevel.forXP(xp) }

    /// XP earned inside the current level band, and the size of that band.
    var levelProgress: (earned: Int, needed: Int) {
        let current = level
        guard let next = current.next else { return (0, 0) }
        return (xp - current.xpThreshold, next.xpThreshold - current.xpThreshold)
    }

    var fractionToNextLevel: Double {
        let (earned, needed) = levelProgress
        guard needed > 0 else { return 1 }
        return min(1, max(0, Double(earned) / Double(needed)))
    }
}

// Swift's synthesised `Decodable` ignores a property's default value: a key
// that is absent from the JSON throws `keyNotFound` rather than falling back to
// the default. That is unusually expensive here. This type is stored inside the
// account-wide `Snapshot`, which is decoded as a single object behind a `try?`
// — so one key missing from `gardener` did not merely reset the Journey, it
// failed the whole snapshot, and the store then re-persisted an empty account
// over the user's real one. Chests, keepsakes, shields and quests all landed
// after a shipped release, so every pre-existing install hit exactly that.
//
// Decoding every field with `decodeIfPresent` keeps an old snapshot readable,
// and keeps a future added field from being able to do this again. The
// conformance lives in an extension so the memberwise and no-argument
// initialisers survive.
extension GardenerProgress {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }

        xp = try value(.xp, 0)
        completedMilestoneIDs = try value(.completedMilestoneIDs, [])
        completedInteractiveIDs = try value(.completedInteractiveIDs, [])
        unlockedBadgeIDs = try value(.unlockedBadgeIDs, [])
        unlockedBadgeDates = try value(.unlockedBadgeDates, [:])

        currentStreak = try value(.currentStreak, 0)
        longestStreak = try value(.longestStreak, 0)
        lastTendDay = try container.decodeIfPresent(Date.self, forKey: .lastTendDay)
        lastRefresherXPDay = try container.decodeIfPresent(Date.self, forKey: .lastRefresherXPDay)

        openedChestIDs = try value(.openedChestIDs, [])
        keepsakeIDs = try value(.keepsakeIDs, [])
        discoveredLandmarkIDs = try value(.discoveredLandmarkIDs, [])
        streakShields = try value(.streakShields, 0)
        lastShieldStreak = try value(.lastShieldStreak, 0)

        questDay = try container.decodeIfPresent(Date.self, forKey: .questDay)
        questCheckIns = try value(.questCheckIns, 0)
        questCareLogged = try value(.questCareLogged, 0)
        questLessons = try value(.questLessons, 0)
        questPlantsAdded = try value(.questPlantsAdded, 0)
        claimedQuestIDs = try value(.claimedQuestIDs, [])
    }
}

// MARK: - Milestones

enum MilestoneKind: String, Codable, Hashable {
    case lesson
    case quiz
    case action
    case goal
    case chest

    var glyph: String {
        switch self {
        case .lesson: "book.fill"
        case .quiz: "questionmark"
        case .action: "checkmark"
        case .goal: "flag.fill"
        case .chest: "shippingbox.fill"
        }
    }

    var label: String {
        switch self {
        case .lesson: "Lesson"
        case .quiz: "Quiz"
        case .action: "Step"
        case .goal: "Goal"
        case .chest: "Chest"
        }
    }
}

/// What has to be true for a milestone to count as complete. Requirements are
/// evaluated against real Grove state, so the game rewards genuine plant care
/// and nothing else — there is no busywork objective in the campaign.
enum MilestoneRequirement: Codable, Hashable {
    /// Player tapped through a lesson or passed a quiz (recorded explicitly).
    case interactive
    /// A chest: unlocked by the node before it, paid out only once opened.
    case chest
    /// At least `min` non-check-in care tasks completed.
    case careLogged(min: Int)
    /// At least `min` check-ins completed (each produces one observation).
    case checkInsCompleted(min: Int)
    /// The Grove holds at least `min` plants.
    case plantsOwned(min: Int)
    /// Any plant is at least as healthy as `band`.
    case plantReachedBand(HealthBand)
    /// At least `min` plants sit at Healthy or better.
    case plantsHealthy(min: Int)
    /// At least `min` plants sit at Thriving.
    case plantsThriving(min: Int)
    /// Longest streak has reached `days`.
    case streakReached(days: Int)
    /// At least `min` Grove Academy lessons finished.
    case lessonsLearned(min: Int)
    /// One single plant has at least `min` check-ins behind it — a real
    /// timeline, not a scatter of first looks.
    case deepestTimeline(min: Int)
    /// Plants live in at least `min` distinct rooms.
    case distinctLocations(min: Int)
    /// At least `min` collections created.
    case collectionsCreated(min: Int)
    /// A plant that was once at Needs attention or worse now sits at Healthy
    /// or better. The single best thing a plant owner can do.
    case recoveredPlant
    /// A sitter has been invited to look after part of the Grove.
    case sitterInvited
    /// At least `min` check-ins recorded visible new growth.
    case newGrowthObserved(min: Int)
    /// The longest run of consecutive Healthy-or-better observations for one
    /// plant has reached `min`.
    case healthyCheckInRun(min: Int)
    /// At least `min` distinct plants have genuinely recovered.
    case recoveredPlants(min: Int)
    /// At least `min` assigned sitting tasks have actually been completed.
    case sitterCareCompleted(min: Int)
}

struct JourneyMilestone: Identifiable, Hashable {
    let id: String
    let kind: MilestoneKind
    let title: String
    let blurb: String
    let xpReward: Int
    let requirement: MilestoneRequirement
    /// Bridges a lesson node to existing Grove Academy content.
    var lessonTopicID: String?
    /// Optional quiz payload for `.quiz` nodes.
    var quiz: JourneyQuiz?
    /// Badge unlocked when this milestone completes.
    var badgeID: String?
    /// Cosmetic planted in the player's world when this milestone completes.
    var keepsakeID: String?
    /// Streak shields paid out. Chests are the main source.
    var shieldReward: Int = 0

    var isChest: Bool { requirement == .chest }
}

/// A single multiple-choice question used by `.quiz` milestones.
struct JourneyQuiz: Hashable {
    let prompt: String
    let options: [String]
    let correctIndex: Int
    let explanation: String
}

enum MilestoneStatus: Hashable {
    case completed
    /// A chest standing open-able. Does not gate the nodes after it: a chest is
    /// a gift, never a toll gate.
    case ready
    case current
    case locked

    var isPlayable: Bool { self == .current || self == .ready }
}

/// A milestone paired with its resolved status and progress for a given player.
struct ResolvedMilestone: Identifiable, Hashable {
    let milestone: JourneyMilestone
    let status: MilestoneStatus
    /// How far along a countable requirement is, for the ring around the node.
    let current: Int
    let target: Int
    var id: String { milestone.id }

    /// 0…1 for the node's progress ring. Binary requirements read as empty or
    /// full, which is exactly right.
    var fraction: Double {
        guard target > 0 else { return status == .completed ? 1 : 0 }
        return min(1, max(0, Double(current) / Double(target)))
    }

    /// Whether the ring is worth drawing at all — a 0/1 requirement has nothing
    /// interesting to show.
    var showsProgress: Bool {
        target > 1 && status != .completed && status != .locked
    }
}

// MARK: - Chapters

/// The scenery a chapter runs through. Each biome is a distinct band of the
/// world, so scrolling the map is travelling somewhere rather than reading a
/// longer list.
enum JourneyBiome: String, Hashable, Codable {
    case meadow
    case woodland
    case orchard
    case highland
    case canopy
}

/// One region of the campaign. Chapters unlock in order, and a chapter's
/// milestones only start paying out once its region is open — so the world
/// reveals itself at the pace of the player's actual grove.
struct JourneyChapter: Identifiable, Hashable {
    let id: String
    let number: Int
    let title: String
    /// The one-line promise of the chapter, shown on its gate banner.
    let theme: String
    let biome: JourneyBiome
    let palette: PlantPalette
    let milestones: [JourneyMilestone]

    /// Milestones that gate the next chapter. Chests never gate anything.
    var gatingMilestones: [JourneyMilestone] {
        milestones.filter { !$0.isChest }
    }
}

/// A chapter resolved against a player: its nodes, whether the region is open,
/// and how far through it they are.
struct ResolvedChapter: Identifiable, Hashable {
    let chapter: JourneyChapter
    let milestones: [ResolvedMilestone]
    let isUnlocked: Bool
    var id: String { chapter.id }

    /// Non-chest nodes finished, out of the non-chest nodes that exist. Chests
    /// are excluded so an unopened gift never makes a chapter look unfinished.
    var completedCount: Int {
        milestones.filter { $0.status == .completed && !$0.milestone.isChest }.count
    }

    var totalCount: Int {
        milestones.filter { !$0.milestone.isChest }.count
    }

    var isComplete: Bool { totalCount > 0 && completedCount == totalCount }

    var fraction: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    /// Chests sitting unopened in this chapter.
    var readyChests: [ResolvedMilestone] {
        milestones.filter { $0.status == .ready }
    }
}

// MARK: - Metrics

/// A snapshot of the real Grove state a milestone can be judged against.
/// Everything here is derived from plants, observations, tasks, collections and
/// assignments the player genuinely has — no counter exists that only the game
/// knows about.
struct JourneyMetrics: Hashable {
    var plantsOwned: Int
    var careLogged: Int
    var checkInsCompleted: Int
    /// Best (healthiest) band across all owned plants, if any.
    var bestBand: HealthBand?
    var healthyPlants: Int
    var thrivingPlants: Int
    var longestStreak: Int
    var lessonsLearned: Int
    var deepestTimeline: Int
    var distinctLocations: Int
    var collectionsCreated: Int
    var recoveredPlants: Int
    var sittersInvited: Int
    var newGrowthObservations: Int
    var longestHealthyCheckInRun: Int
    var sitterCareCompleted: Int

    static let empty = JourneyMetrics(
        plantsOwned: 0,
        careLogged: 0,
        checkInsCompleted: 0,
        bestBand: nil,
        healthyPlants: 0,
        thrivingPlants: 0,
        longestStreak: 0,
        lessonsLearned: 0,
        deepestTimeline: 0,
        distinctLocations: 0,
        collectionsCreated: 0,
        recoveredPlants: 0,
        sittersInvited: 0,
        newGrowthObservations: 0,
        longestHealthyCheckInRun: 0,
        sitterCareCompleted: 0
    )
}

extension HealthBand {
    /// Higher is healthier. Lets goals compare "at least as healthy as".
    var goodnessRank: Int {
        switch self {
        case .urgent: 0
        case .attention: 1
        case .monitor: 2
        case .healthy: 3
        case .thriving: 4
        }
    }
}

// MARK: - Evaluator (pure)

/// Pure resolution of the campaign against a player's progress. No side
/// effects, so it is trivially unit-testable and safe to call on every state
/// change.
enum JourneyEvaluator {

    /// How far along a requirement is, as a countable pair. Binary
    /// requirements report `(0, 1)` or `(1, 1)`.
    static func progress(
        _ requirement: MilestoneRequirement,
        milestoneID: String,
        progress: GardenerProgress,
        metrics: JourneyMetrics,
        previousCompleted: Bool
    ) -> (current: Int, target: Int) {
        func binary(_ done: Bool) -> (Int, Int) { (done ? 1 : 0, 1) }

        switch requirement {
        case .interactive:
            return binary(progress.completedInteractiveIDs.contains(milestoneID))
        case .chest:
            return binary(previousCompleted && progress.openedChestIDs.contains(milestoneID))
        case .careLogged(let min):
            return (metrics.careLogged, min)
        case .checkInsCompleted(let min):
            return (metrics.checkInsCompleted, min)
        case .plantsOwned(let min):
            return (metrics.plantsOwned, min)
        case .plantReachedBand(let band):
            return binary((metrics.bestBand?.goodnessRank ?? -1) >= band.goodnessRank)
        case .plantsHealthy(let min):
            return (metrics.healthyPlants, min)
        case .plantsThriving(let min):
            return (metrics.thrivingPlants, min)
        case .streakReached(let days):
            return (metrics.longestStreak, days)
        case .lessonsLearned(let min):
            return (metrics.lessonsLearned, min)
        case .deepestTimeline(let min):
            return (metrics.deepestTimeline, min)
        case .distinctLocations(let min):
            return (metrics.distinctLocations, min)
        case .collectionsCreated(let min):
            return (metrics.collectionsCreated, min)
        case .recoveredPlant:
            return binary(metrics.recoveredPlants >= 1)
        case .sitterInvited:
            return binary(metrics.sittersInvited >= 1)
        case .newGrowthObserved(let min):
            return (metrics.newGrowthObservations, min)
        case .healthyCheckInRun(let min):
            return (metrics.longestHealthyCheckInRun, min)
        case .recoveredPlants(let min):
            return (metrics.recoveredPlants, min)
        case .sitterCareCompleted(let min):
            return (metrics.sitterCareCompleted, min)
        }
    }

    /// Whether a milestone's requirement is satisfied, ignoring ordering.
    /// `previousCompleted` supplies the answer for chest gates.
    static func isSatisfied(
        _ requirement: MilestoneRequirement,
        milestoneID: String,
        progress: GardenerProgress,
        metrics: JourneyMetrics,
        previousCompleted: Bool
    ) -> Bool {
        let (current, target) = Self.progress(
            requirement,
            milestoneID: milestoneID,
            progress: progress,
            metrics: metrics,
            previousCompleted: previousCompleted
        )
        return current >= target
    }

    /// Resolve every milestone in a chapter to a status, in order. The first
    /// not-yet-complete node is `.current`; everything after it is `.locked`.
    /// Chests are the exception twice over: an unlocked one is `.ready`, and
    /// neither its state nor its position blocks anything downstream.
    static func resolve(
        chapter: JourneyChapter,
        progress: GardenerProgress,
        metrics: JourneyMetrics,
        isUnlocked: Bool = true
    ) -> [ResolvedMilestone] {
        var previousCompleted = true // the first node is always reachable
        var reachedCurrent = false
        var resolved: [ResolvedMilestone] = []

        for milestone in chapter.milestones {
            let (current, target) = Self.progress(
                milestone.requirement,
                milestoneID: milestone.id,
                progress: progress,
                metrics: metrics,
                previousCompleted: previousCompleted
            )
            let alreadyAwarded = progress.completedMilestoneIDs.contains(milestone.id)
            let satisfied = current >= target
            let completed = alreadyAwarded || satisfied

            let status: MilestoneStatus
            if completed {
                status = .completed
            } else if !isUnlocked {
                status = .locked
            } else if milestone.isChest {
                // A chest waiting to be opened, or still sealed behind the node
                // before it. Either way it never becomes "the current step".
                status = previousCompleted ? .ready : .locked
            } else if !reachedCurrent {
                status = .current
                reachedCurrent = true
            } else {
                status = .locked
            }

            resolved.append(
                ResolvedMilestone(milestone: milestone, status: status, current: current, target: target)
            )
            // Chests are gifts, not toll gates: they never hold up the path.
            if !milestone.isChest { previousCompleted = completed }
        }
        return resolved
    }

    /// Resolve the whole campaign. A chapter opens once every gating milestone
    /// in the chapter before it is complete.
    static func resolveCampaign(
        chapters: [JourneyChapter] = JourneyLibrary.chapters,
        progress: GardenerProgress,
        metrics: JourneyMetrics
    ) -> [ResolvedChapter] {
        var unlocked = true
        var result: [ResolvedChapter] = []
        for chapter in chapters {
            let milestones = resolve(
                chapter: chapter,
                progress: progress,
                metrics: metrics,
                isUnlocked: unlocked
            )
            let resolvedChapter = ResolvedChapter(
                chapter: chapter,
                milestones: milestones,
                isUnlocked: unlocked
            )
            result.append(resolvedChapter)
            // The next region opens only when this one is genuinely finished.
            unlocked = unlocked && resolvedChapter.isComplete
        }
        return result
    }

    /// Milestones newly satisfied that have not yet been awarded, in order,
    /// across every *unlocked* chapter. The store uses this to grant XP,
    /// badges, and keepsakes exactly once.
    static func newlyCompleted(
        chapters: [JourneyChapter] = JourneyLibrary.chapters,
        progress: GardenerProgress,
        metrics: JourneyMetrics
    ) -> [JourneyMilestone] {
        resolveCampaign(chapters: chapters, progress: progress, metrics: metrics)
            .filter(\.isUnlocked)
            .flatMap(\.milestones)
            .filter { $0.status == .completed && !progress.completedMilestoneIDs.contains($0.id) }
            .map(\.milestone)
    }
}
