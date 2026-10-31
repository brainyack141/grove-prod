import Foundation

/// The Grove Score: one 0–100 reading of how well this grove is being cared
/// for, computed entirely from evidence Grove already holds — assessed health,
/// dated care, real observations. Pure and deterministic in the shape of
/// `TodayMasthead` and `WateringRhythm`: state in, sentences and numbers out,
/// every branch testable without a store.
///
/// The design brief was "strong and can't be played", and each rule below is
/// one of the ways someone might try:
///
/// - **Outcomes outweigh activity.** The heaviest pillar is how the plants are
///   actually doing, and health scores come from photo assessments — they
///   cannot be typed in.
/// - **Days count, not taps.** Every counter that could be spammed collapses
///   to one credit per day. Thirty check-ins in one evening weigh exactly the
///   same as one.
/// - **Only real looks count.** Observations flagged `isEstimated` came from
///   offline arithmetic, not from anyone looking at a plant, and move nothing.
/// - **Evidence goes stale.** A thriving reading six weeks old proves less
///   every day. A high score has to keep being re-earned.
/// - **The worst plant drags harder than the mean.** Ten pampered cacti cannot
///   hide one dying fern.
/// - **Precision is earned, not granted.** Each pillar is shrunk toward neutral
///   until enough distinct looking-days exist, and each plant's health reading
///   is also tempered by its model confidence and its own evidence history. A
///   new account — or a burst of activity on a single day — cannot reach the
///   top or the bottom of the scale. Nothing shortcuts calendar time.
struct GroveScore: Equatable {

    // MARK: - Pillars

    struct Pillar: Equatable, Identifiable {
        enum Kind: String, CaseIterable {
            case wellbeing
            case timeliness
            case coverage
            case recovery
        }

        let kind: Kind
        /// 0…1 of this pillar's points earned.
        let fraction: Double
        /// One concrete sentence about where this stands, with real names and
        /// numbers from the grove.
        let detail: String

        var id: Kind { kind }

        var maxPoints: Int {
            switch kind {
            case .wellbeing: 40
            case .timeliness: 25
            case .coverage: 20
            case .recovery: 15
            }
        }

        var points: Int {
            min(
                maxPoints,
                max(0, Int((fraction * Double(maxPoints)).rounded(.toNearestOrEven)))
            )
        }

        var title: String {
            switch kind {
            case .wellbeing: "Plant wellbeing"
            case .timeliness: "Care on time"
            case .coverage: "Every plant seen"
            case .recovery: "Recovery & consistency"
            }
        }

        var symbol: String {
            switch kind {
            case .wellbeing: "leaf.fill"
            case .timeliness: "checkmark.circle.fill"
            case .coverage: "eye.fill"
            case .recovery: "arrow.up.right"
            }
        }
    }

    // MARK: - Tiers

    /// Where a score stands, named. Floors line up with the health bands the
    /// rest of the app uses, so 75 means "good" everywhere in Grove.
    enum Tier: Equatable, CaseIterable {
        case takingRoot
        case comingAlong
        case steadyHands
        case greenFingers
        case masterGardener

        static func forScore(_ score: Int) -> Tier {
            switch score {
            case ..<40: .takingRoot
            case ..<60: .comingAlong
            case ..<75: .steadyHands
            case ..<90: .greenFingers
            default: .masterGardener
            }
        }

        var floor: Int {
            switch self {
            case .takingRoot: 0
            case .comingAlong: 40
            case .steadyHands: 60
            case .greenFingers: 75
            case .masterGardener: 90
            }
        }

        var next: Tier? {
            switch self {
            case .takingRoot: .comingAlong
            case .comingAlong: .steadyHands
            case .steadyHands: .greenFingers
            case .greenFingers: .masterGardener
            case .masterGardener: nil
            }
        }

        var title: String {
            switch self {
            case .takingRoot: "Taking root"
            case .comingAlong: "Coming along"
            case .steadyHands: "Steady hands"
            case .greenFingers: "Green fingers"
            case .masterGardener: "Master gardener"
            }
        }

        /// One calm sentence under the number.
        var line: String {
            switch self {
            case .takingRoot: "Early days. The score builds with each real check-in."
            case .comingAlong: "Check-ins are becoming regular, and the score is rising with them."
            case .steadyHands: "Your plants get seen and cared for on time, most weeks."
            case .greenFingers: "A well-kept grove, with healthy scores across it."
            case .masterGardener: "Care on time, every plant seen, and plants that recover."
            }
        }
    }

    // MARK: - Advice

    /// The one thing most worth doing about the score, with the screen that
    /// does it. Ranked the same way Today ranks its call: a plant in trouble
    /// beats a queue, and a queue beats housekeeping.
    struct Advice: Equatable {
        let message: String
        let actionTitle: String?
        let route: AppRoute?
    }

    // MARK: - The reading

    let total: Int
    let pillars: [Pillar]
    /// Distinct days in the evidence window with at least one real look.
    let lookDays: Int
    /// 0…1 confidence in the total. Below 1 the score is still settling.
    let evidenceWeight: Double
    /// Looking-days *this* grove needs before the total carries full weight,
    /// scaled to its size by `GroveCensus.fullEvidenceDays(forPlantCount:)`.
    /// Carried on the reading so a surface can say "3 of 6" without having to
    /// re-derive the bar the number was actually measured against.
    let fullEvidenceDays: Int
    let advice: Advice

    var tier: Tier { .forScore(total) }
    var isSettling: Bool { evidenceWeight < 1 }

    /// Looking-days still owed before the score settles.
    var lookDaysRemaining: Int { max(0, fullEvidenceDays - lookDays) }

    /// How far through the current tier the score sits, for the progress bar.
    var progressToNextTier: (fraction: Double, pointsShort: Int, next: Tier)? {
        guard let next = tier.next else { return nil }
        let span = Double(next.floor - tier.floor)
        guard span > 0 else { return nil }
        let into = Double(total - tier.floor)
        return (min(1, max(0, into / span)), next.floor - total, next)
    }

    func pillar(_ kind: Pillar.Kind) -> Pillar? {
        pillars.first { $0.kind == kind }
    }

    // MARK: - Tuning

    /// Every constant the algorithm rests on, in one place.
    enum Rules {
        /// The evidence and care window: four weeks.
        static let careWindowDays = 28
        /// The recovery window: long enough for a real comeback.
        static let recoveryWindowDays = 60
        /// The ceiling on distinct looking-days needed before the score carries
        /// full weight, and the bar for any grove big enough to reach it.
        /// Days cannot be compressed into an evening, which is the point; the
        /// exact count is scaled to the grove by
        /// `GroveCensus.fullEvidenceDays(forPlantCount:)`.
        static let fullEvidenceDays = 10
        /// A plant needs more than its intake photo before an unusually high or
        /// low reading is treated as fully representative of the owner's care.
        static let fullPlantEvidenceDays = 3
        /// A health reading is fully trusted for a fortnight…
        static let freshReadingDays = 14
        /// …and stops counting entirely after six and a half weeks unseen.
        static let staleReadingDays = 45
        /// A plant counts as covered when seen inside ten days…
        static let coveredWithinDays = 10
        /// …and as forgotten past five weeks.
        static let forgottenAfterDays = 35
        /// Completed care still counts as on time this many days past due.
        static let onTimeGraceDays = 1
        /// A low and a healthy reading on the same afternoon is model noise,
        /// not a recovery. Real improvement has to survive at least a week.
        static let minimumRecoveryDays = 7
        /// What an unproven health reading decays toward: the bottom of
        /// "keep an eye on it", because unseen is unknown, not fine.
        static let unseenAnchor = 60.0
        /// Where each pillar rests with no evidence at all. Applying this to
        /// all four weighted pillars produces a neutral total of 50.
        static let neutralPillarFraction = 0.5
    }

    // MARK: - Measuring

    /// The whole calculation. Returns nil for an empty grove, which is a page
    /// state rather than a zero: nobody is a bad carer for having no plants.
    static func measure(
        plants: [Plant],
        observations: [PlantObservation],
        diagnoses: [PlantDiagnosis],
        scans: [ScanHistoryRecord],
        tasks: [CareTask],
        streak: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> GroveScore? {
        guard !plants.isEmpty else { return nil }

        let today = calendar.startOfDay(for: now)
        let plantIDs = Set(plants.map(\.id))
        func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
        func daysBetween(_ from: Date, _ to: Date) -> Int {
            calendar.dateComponents([.day], from: day(from), to: day(to)).day ?? 0
        }

        // Every dated moment somebody genuinely looked at a plant. Estimated
        // observations are excluded here, which is what keeps them out of the
        // entire score: every pillar and the evidence weight read from this.
        var looks: [(plantID: UUID, day: Date)] = []
        for observation in observations
        where plantIDs.contains(observation.plantID)
            && !observation.isEstimated
            && observation.createdAt <= now {
            looks.append((observation.plantID, day(observation.createdAt)))
        }
        for diagnosis in diagnoses
        where plantIDs.contains(diagnosis.plantID) && diagnosis.createdAt <= now {
            looks.append((diagnosis.plantID, day(diagnosis.createdAt)))
        }
        for scan in scans where scan.createdAt <= now {
            guard let plantID = scan.plantID, plantIDs.contains(plantID) else { continue }
            looks.append((plantID, day(scan.createdAt)))
        }

        var lookDaysByPlant: [UUID: Set<Date>] = [:]
        for look in looks {
            lookDaysByPlant[look.plantID, default: []].insert(look.day)
        }

        var lastLookDay: [UUID: Date] = [:]
        for look in looks {
            lastLookDay[look.plantID] = max(lastLookDay[look.plantID] ?? .distantPast, look.day)
        }

        /// Days since the plant was last genuinely looked at; nil if never.
        func daysUnseen(_ plant: Plant) -> Int? {
            guard let last = lastLookDay[plant.id] else { return nil }
            return max(0, daysBetween(last, today))
        }

        // MARK: Wellbeing — 40

        // A reading is first tempered by the model confidence and by how many
        // different days this plant has actually been seen. It then decays
        // toward the unseen anchor as it ages, and only downward: a sick plant
        // nobody looks at stays sick on the books. Recovery has to be shown,
        // not waited out.
        func countedHealth(_ plant: Plant) -> Double {
            let score = Double(plant.healthScore)
            let confidence = min(1, max(0, Double(plant.confidence) / 100))
            let confidentScore = Rules.unseenAnchor + (score - Rules.unseenAnchor) * confidence
            let plantEvidence = min(
                1,
                Double(lookDaysByPlant[plant.id]?.count ?? 0) / Double(Rules.fullPlantEvidenceDays)
            )
            let provenScore = Rules.unseenAnchor
                + (confidentScore - Rules.unseenAnchor) * plantEvidence
            guard provenScore > Rules.unseenAnchor else { return provenScore }
            let unseen = daysUnseen(plant) ?? Rules.staleReadingDays
            let staleSpan = Double(Rules.staleReadingDays - Rules.freshReadingDays)
            let past = Double(unseen - Rules.freshReadingDays)
            let freshness = min(1, max(0, 1 - past / staleSpan))
            return Rules.unseenAnchor + (provenScore - Rules.unseenAnchor) * freshness
        }

        let counted = plants.map(countedHealth)
        let meanHealth = counted.reduce(0, +) / Double(counted.count)
        let worstHealth = counted.min() ?? 0
        let wellbeing = 0.7 * (meanHealth / 100) + 0.3 * (worstHealth / 100)

        let wellbeingDetail: String = {
            if let unproven = plants.first(where: { daysUnseen($0) == nil }) {
                return "\(unproven.nickname) needs a first photo check-in before its health can count."
            }
            if let lowest = plants.min(by: { $0.healthScore < $1.healthScore }),
               lowest.healthScore < 60 {
                return "\(lowest.nickname)'s latest check-in score is \(lowest.healthScore). Helping it recover lifts this most."
            }
            if let stalest = plants
                .compactMap({ plant in daysUnseen(plant).map { (plant, $0) } })
                .max(by: { $0.1 < $1.1 }),
               stalest.1 > Rules.freshReadingDays + 7 {
                return "\(stalest.0.nickname)'s last check-in was \(stalest.1) days ago, so it counts for less."
            }
            let average = Int((plants.map { Double($0.healthScore) }.reduce(0, +) / Double(plants.count)).rounded())
            return plants.count == 1
                ? "\(plants[0].nickname) was checked in on recently and scores \(plants[0].healthScore)."
                : "Recent check-ins across \(plants.count) plants, averaging \(average)."
        }()

        // MARK: Care on time — 25

        guard let windowStart = calendar.date(
            byAdding: .day,
            value: -(Rules.careWindowDays - 1),
            to: today
        ) else {
            return nil
        }

        // One credit per plant, kind and due day: logging the same watering
        // five times is one watering, and so is ticking a duplicate reminder.
        struct DueKey: Hashable {
            let plantID: UUID
            let kind: CareKind
            let dueDay: Date
        }

        var dueResults: [DueKey: Bool] = [:]
        for task in tasks where plantIDs.contains(task.plantID) {
            let dueDay = day(task.dueDate)
            guard dueDay >= windowStart, dueDay <= today else { continue }
            let key = DueKey(plantID: task.plantID, kind: task.kind, dueDay: dueDay)
            if task.isCompleted, !task.dateIsInferred {
                let onTime = daysBetween(task.dueDate, task.performedAt) <= Rules.onTimeGraceDays
                dueResults[key] = (dueResults[key] ?? false) || onTime
            } else if !task.isCompleted, dueDay < today, dueResults[key] == nil {
                dueResults[key] = false
            }
        }

        let dueCount = dueResults.count
        let onTimeCount = dueResults.values.filter { $0 }.count
        // No demand yet is not the same as meeting demand: a mildly positive
        // neutral, with the evidence weight keeping the total honest.
        let onTimeRate = dueCount > 0 ? Double(onTimeCount) / Double(dueCount) : 0.7
        let streakNorm = min(1, Double(max(0, streak)) / 14)
        let timeliness = 0.8 * onTimeRate + 0.2 * streakNorm

        let overdueNow = Set(
            tasks
                .filter { plantIDs.contains($0.plantID) && !$0.isCompleted && day($0.dueDate) < today }
                .map { DueKey(plantID: $0.plantID, kind: $0.kind, dueDay: day($0.dueDate)) }
        ).count
        let timelinessDetail: String = {
            if dueCount == 0 {
                return "Nothing has come due yet. This fills in as care gets scheduled."
            }
            let base = "\(onTimeCount) of \(dueCount) done on time in the last four weeks."
            if overdueNow == 1 { return base + " One is overdue now." }
            if overdueNow > 1 { return base + " \(overdueNow) are overdue now." }
            return base
        }()

        // MARK: Every plant seen — 20

        func coverageScore(_ plant: Plant) -> Double {
            guard let unseen = daysUnseen(plant) else { return 0 }
            if unseen <= Rules.coveredWithinDays { return 1 }
            let span = Double(Rules.forgottenAfterDays - Rules.coveredWithinDays)
            return max(0, 1 - Double(unseen - Rules.coveredWithinDays) / span)
        }

        let coverage = plants.map(coverageScore).reduce(0, +) / Double(plants.count)
        let recentlySeen = plants.filter { (daysUnseen($0) ?? .max) <= Rules.coveredWithinDays }.count

        let coverageDetail: String = {
            if plants.count == 1 {
                guard let unseen = daysUnseen(plants[0]) else {
                    return "\(plants[0].nickname) hasn't had a check-in yet."
                }
                switch unseen {
                case 0: return "\(plants[0].nickname) was seen today."
                case 1: return "\(plants[0].nickname) was seen yesterday."
                default: return "\(plants[0].nickname) was last seen \(unseen) days ago."
                }
            }
            return "\(recentlySeen) of \(plants.count) plants seen in the last \(Rules.coveredWithinDays) days."
        }()

        // MARK: Recovery — 15

        guard let recoveryStart = calendar.date(byAdding: .day, value: -Rules.recoveryWindowDays, to: today) else {
            return nil
        }

        var strugglers: Set<UUID> = []
        var recovered: Set<UUID> = []
        var consistentlyHealthy: Set<UUID> = []

        for plant in plants {
            let history = observations
                .filter { $0.plantID == plant.id && !$0.isEstimated && $0.createdAt >= recoveryStart && $0.createdAt <= now }
                .sorted { $0.createdAt < $1.createdAt }

            // Collapse every day's attempts to its most conservative reading.
            // Retaking a photo until the model happens to return a flattering
            // number therefore cannot manufacture a same-day recovery.
            var readingByDay: [Date: Int] = [:]
            for observation in history {
                let observationDay = day(observation.createdAt)
                readingByDay[observationDay] = min(
                    readingByDay[observationDay] ?? observation.score,
                    observation.score
                )
            }
            let dailyReadings = readingByDay
                .map { (day: $0.key, score: $0.value) }
                .sorted { $0.day < $1.day }

            let sawLow = dailyReadings.contains { $0.score < 60 }
                || plant.healthBand == .attention
                || plant.healthBand == .urgent
            if sawLow {
                strugglers.insert(plant.id)
                if let low = dailyReadings.first(where: { $0.score < 60 }),
                   let healthy = dailyReadings.last(where: {
                       $0.score >= 75
                           && daysBetween(low.day, $0.day) >= Rules.minimumRecoveryDays
                   }),
                   healthy.day > low.day,
                   plant.healthScore >= 75 {
                    recovered.insert(plant.id)
                }
            } else if let first = dailyReadings.first,
                      let last = dailyReadings.last,
                      first.score >= 75,
                      last.score >= 75,
                      daysBetween(first.day, last.day) >= Rules.minimumRecoveryDays,
                      plant.healthScore >= 75 {
                consistentlyHealthy.insert(plant.id)
            }
        }

        // With nobody struggling, repeated healthy evidence is the
        // demonstration. One intake photo earns a neutral half, not a free
        // recovery badge; two healthy reads at least a week apart earn more.
        let recoveryBase = strugglers.isEmpty
            ? 0.5 + 0.5 * Double(consistentlyHealthy.count) / Double(plants.count)
            : Double(recovered.count) / Double(strugglers.count)
        let recovery = min(1, max(0, recoveryBase))

        let recoveryDetail: String = {
            if !recovered.isEmpty {
                if recovered.count == 1, let plant = plants.first(where: { recovered.contains($0.id) }) {
                    return "\(plant.nickname) came back from a rough patch. That's the strongest signal here."
                }
                return "\(recovered.count) plants came back from rough patches."
            }
            if !strugglers.isEmpty {
                if strugglers.count == 1, let plant = plants.first(where: { strugglers.contains($0.id) }) {
                    return "\(plant.nickname) is still on the way back. A recovery scores highest here."
                }
                return "\(strugglers.count) plants are still on the way back."
            }
            if consistentlyHealthy.count == plants.count {
                return "Every plant has stayed healthy across check-ins at least a week apart."
            }
            if !consistentlyHealthy.isEmpty {
                return "\(consistentlyHealthy.count) of \(plants.count) plants have stayed healthy across check-ins at least a week apart."
            }
            return "No recovery window yet. Two photo check-ins at least a week apart establish consistency."
        }()

        // MARK: Evidence weight

        let lookDays = Set(looks.filter { $0.day >= windowStart }.map(\.day)).count
        // Measured against this grove's own bar, not the flat ceiling: see
        // `GroveCensus.fullEvidenceDays(forPlantCount:)` for why a one-plant
        // grove cannot fairly be asked for the same number of looking-days as
        // a five-plant one.
        let evidenceBar = GroveCensus.fullEvidenceDays(forPlantCount: plants.count)
        let evidenceWeight = min(1, Double(lookDays) / Double(evidenceBar))

        func settled(_ raw: Double) -> Double {
            let clamped = min(1, max(0, raw))
            return Rules.neutralPillarFraction
                + (clamped - Rules.neutralPillarFraction) * evidenceWeight
        }

        let pillars = [
            Pillar(kind: .wellbeing, fraction: settled(wellbeing), detail: wellbeingDetail),
            Pillar(kind: .timeliness, fraction: settled(timeliness), detail: timelinessDetail),
            Pillar(kind: .coverage, fraction: settled(coverage), detail: coverageDetail),
            Pillar(kind: .recovery, fraction: settled(recovery), detail: recoveryDetail)
        ]

        // The headline is exactly the sum of the four numbers underneath it.
        // Banker's rounding in `Pillar.points` keeps the all-neutral state at
        // 50 while avoiding a systematic upward bias at every half point.
        let total = pillars.reduce(0) { $0 + $1.points }

        let advice = Self.advice(
            plants: plants,
            overdueCount: overdueNow,
            daysUnseen: daysUnseen,
            lookDays: lookDays
        )

        return GroveScore(
            total: total,
            pillars: pillars,
            lookDays: lookDays,
            evidenceWeight: evidenceWeight,
            fullEvidenceDays: evidenceBar,
            advice: advice
        )
    }

    /// The single most valuable next move, in Today's own priority order.
    private static func advice(
        plants: [Plant],
        overdueCount: Int,
        daysUnseen: (Plant) -> Int?,
        lookDays: Int
    ) -> Advice {
        if let urgent = plants
            .filter({ $0.healthBand == .urgent })
            .min(by: { $0.healthScore < $1.healthScore }) {
            return Advice(
                message: "\(urgent.nickname) is in trouble. A recovery moves this score more than anything else.",
                actionTitle: "Check in on \(urgent.nickname)",
                route: .checkIn(urgent.id)
            )
        }

        if overdueCount > 0 {
            return Advice(
                message: overdueCount == 1
                    ? "One task is overdue. Clearing it is the quickest lift."
                    : "\(overdueCount) tasks are overdue. Clearing them is the quickest lift.",
                actionTitle: "Open care queue",
                route: .care
            )
        }

        if let struggling = plants
            .filter({ $0.healthBand == .attention })
            .min(by: { $0.healthScore < $1.healthScore }) {
            return Advice(
                message: "\(struggling.nickname) isn't itself. Helping it back is worth the most points.",
                actionTitle: "Check in on \(struggling.nickname)",
                route: .checkIn(struggling.id)
            )
        }

        if let stale = plants
            .compactMap({ plant in daysUnseen(plant).map { (plant, $0) } })
            .filter({ $0.1 > Rules.freshReadingDays })
            .max(by: { $0.1 < $1.1 }) {
            return Advice(
                message: "\(stale.0.nickname) hasn't had a check-in in \(stale.1) days, so its score counts for less.",
                actionTitle: "Check in on \(stale.0.nickname)",
                route: .checkIn(stale.0.id)
            )
        }

        if let unproven = plants.first(where: { daysUnseen($0) == nil }) {
            return Advice(
                message: "\(unproven.nickname) hasn't had a check-in yet, so it isn't counted.",
                actionTitle: "Check in on \(unproven.nickname)",
                route: .checkIn(unproven.id)
            )
        }

        if lookDays < Rules.fullEvidenceDays {
            return Advice(
                message: "The score firms up with each day you check in.",
                actionTitle: nil,
                route: nil
            )
        }

        return Advice(
            message: "Nothing is overdue and every plant has had a recent check-in. There's nothing to fix.",
            actionTitle: nil,
            route: nil
        )
    }
}
