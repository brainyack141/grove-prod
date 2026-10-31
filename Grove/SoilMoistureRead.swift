import Foundation

/// How long this particular pot, in this particular spot, takes to be ready for
/// water again.
///
/// A species watering interval is the wrong unit and always has been. "Check
/// every 5–7 days" is true of a monstera in a 15cm plastic pot by a window and
/// wildly wrong for the same monstera in a 35cm glazed cachepot in a hallway —
/// which is a difference of weeks, and the second one is how a monstera dies.
/// The pot is the variable that matters, so the scan reads the pot
/// (`PlantGrowingConditions`) and this bends the species baseline by it.
///
/// Every number here is an estimate and the plant page never renders one without
/// saying so. What the estimate earns is not precision — it is the *width* of
/// the uncertainty it hands to `SoilMoistureRead`, which is what decides whether
/// Grove is allowed to tell someone to water.
struct SoilDryDown: Hashable {
    /// Days from a thorough watering to ready-for-the-next-one.
    let days: Double
    /// How many of the four inputs — pot material, pot size, substrate,
    /// drainage — the scan could not resolve.
    let unknownInputs: Int
    /// Where the plant stands relative to the light, if anyone has said.
    let light: PlantLightPlacement?

    /// True when nobody has said where the plant stands relative to the light.
    var lightIsUnknown: Bool { light == nil }
    /// True when the species fell through to the conservative tropical baseline.
    let speciesIsGeneric: Bool

    /// A pot that cannot let water out. The single most useful thing the scan
    /// can notice, and the reason a plant that is "watered correctly" still rots.
    let holdsWater: Bool

    /// Kept alongside the derived numbers so the card can *name* its reasons —
    /// "sits in a cover", "20–30cm terracotta" — rather than only score them.
    /// Nil when no scan has ever seen this pot.
    let conditions: PlantGrowingConditions?

    /// How hard the stacked factors are pulled back towards the baseline.
    /// `PlantWateringEstimate` applies the same exponent factor by factor so
    /// its step-by-step working lands on this type's number.
    static let damping = 0.6

    /// `location` adds the season, the same undamped factor
    /// `PlantWateringEstimate` applies, so the moisture tile, the care score
    /// and the board's Water-every number all run on one gap. No location
    /// means no season: a guessed hemisphere is wrong half the year.
    init(plant: Plant, location: GroveLocation? = nil, now: Date = .now) {
        let profile = PlantCareProfile(plant: plant)
        let conditions = plant.growingConditions
        let light = plant.effectiveLightPlacement

        // Multiplied, then damped. Six factors multiplied raw compound far past
        // anything physical — a small terracotta pot of gritty mix on a sill
        // lands at a third of the baseline, which would have Grove watering a
        // succulent weekly. The exponent pulls the stack back towards the middle
        // while keeping every factor's direction and rough weight.
        let stacked = Self.sizeFactor(conditions?.potSize) *
            Self.materialFactor(conditions?.potMaterial) *
            Self.substrateFactor(conditions?.substrate) *
            Self.drainageFactor(conditions?.drainage) *
            Self.fitFactor(conditions?.potFit) *
            Self.surfaceFactor(conditions?.surfaceSigns ?? []) *
            Self.lightFactor(light)
        let damped = pow(stacked, Self.damping)

        let season: Double
        if plant.effectiveLifecycleState == .dormant {
            season = PlantWateringEstimate.seasonFactor(.dormancy)
        } else if let location {
            season = PlantWateringEstimate.seasonFactor(
                PlantSeasonAdvisory.season(at: location.latitude, on: now)
            )
        } else {
            season = 1
        }

        days = min(40, max(3, profile.referenceWateringDays * season * damped))
        unknownInputs = conditions?.unknownDryDownInputs ?? 4
        self.light = light
        speciesIsGeneric = !profile.matchedSpecies
        holdsWater = conditions?.drainage == .cachepot || conditions?.drainage == .noHoles
        self.conditions = conditions
    }

    static func sizeFactor(_ size: PlantGrowingConditions.PotSize?) -> Double {
        switch size {
        case .small: 0.7
        case .large: 1.3
        case .xlarge: 1.6
        case .medium, .unknown, nil: 1
        }
    }

    static func materialFactor(_ material: PlantGrowingConditions.PotMaterial?) -> Double {
        switch material {
        // Unglazed clay breathes through its wall; a glazed one is a sealed jar
        // with a hole in it.
        case .terracotta: 0.7
        case .fabric: 0.65
        case .glazed: 1.1
        case .metal: 1.05
        case .concrete: 0.9
        case .plastic, .unpotted, .unknown, nil: 1
        }
    }

    static func substrateFactor(_ substrate: PlantGrowingConditions.Substrate?) -> Double {
        switch substrate {
        case .gritty: 0.75
        case .bark: 0.8
        case .dense: 1.25
        case .moss: 0.9
        case .semiHydro: 0.9
        case .standard, .unknown, nil: 1
        }
    }

    static func drainageFactor(_ drainage: PlantGrowingConditions.Drainage?) -> Double {
        switch drainage {
        case .cachepot: 1.35
        case .noHoles: 1.5
        case .drains, .unknown, nil: 1
        }
    }

    static func fitFactor(_ fit: PlantGrowingConditions.PotFit?) -> Double {
        switch fit {
        // An oversized pot is a reservoir of wet soil the roots never reach into.
        case .oversized: 1.25
        case .snug: 0.85
        case .balanced, .unknown, nil: 1
        }
    }

    /// What is actually on the soil, as a correction to what the pot predicts.
    ///
    /// The six enumerated pot facts describe a pot in the abstract. The surface
    /// describes *this* pot after months of being watered by this person, and
    /// when the two disagree the surface is the one that was observed. Algae,
    /// mould and gnats are not causes of anything — they are what grows on soil
    /// that has not dried out, which is a direct measurement of the quantity
    /// this whole type is trying to estimate.
    ///
    /// The strongest single sign wins rather than the product of all of them.
    /// Gnats, algae and mould are three names for one condition, and a pot with
    /// all three is not eight times slower than a pot with one — it is the same
    /// wet pot, observed three ways.
    static func surfaceFactor(_ signs: [PlantGrowingConditions.SurfaceSign]) -> Double {
        let factors = signs.map(Self.factor(for:))
        guard let strongest = factors.max(by: { abs($0 - 1) < abs($1 - 1) }) else { return 1 }
        return strongest
    }

    private static func factor(for sign: PlantGrowingConditions.SurfaceSign) -> Double {
        switch sign {
        // Water standing on the surface is drainage failing in front of the
        // camera, whatever the pot said about its holes.
        case .standingWater: 1.35
        // Three symptoms of one cause: soil that has stayed damp long enough
        // for something else to live in it.
        case .algae, .mould, .fungusGnats: 1.2
        // Airless soil both holds water and refuses to let roots use it.
        case .compacted: 1.15
        // Pebbles and bark are a lid on the one surface that evaporates.
        case .topDressed: 1.1
        // Moss wants damp, but it also sits on top of a pot that may simply be
        // in a humid room. Directionally wet, weakly.
        case .moss: 1.05
        // Salt is left behind by water that evaporated. It says nothing about
        // the rate, only that watering has happened for a while.
        case .saltCrust: 1
        // A pot that is more root than soil holds far less water than its
        // diameter implies, and empties in days.
        case .rootsAtSurface: 0.85
        // Water runs down the gap and out of the bottom without ever wetting
        // the rootball, so the pot is drier than the last watering suggests.
        case .hydrophobic: 0.8
        }
    }

    static func lightFactor(_ light: PlantLightPlacement?) -> Double {
        switch light {
        case .sill: 0.85
        case .shaded: 1.35
        case .outdoors: 0.8
        case .bright, nil: 1
        }
    }
}

/// What Grove believes about the soil right now, and how sure it is allowed to
/// sound about it.
///
/// The product's whole watering philosophy is *check, then act* — the streak
/// refuses to reward watering, the care guide says "check soil every 5–7 days"
/// rather than "water every 5–7 days", and the store declines a second watering
/// inside three days. What was missing was the thing that makes checking worth
/// doing: somewhere for the answer to go. So a felt reading is stored with its
/// date (`CareTask.soilMoisture`), and everything here decays from it.
///
/// The verdict is taken from the whole uncertainty band, not from its centre. If
/// any part of the band straddles the threshold, Grove says it cannot call it
/// and asks for a finger in the soil. That is why an unseen pot produces "go and
/// feel it" and a scanned one produces an answer: the arithmetic cannot be
/// confident about a pot it never saw, and it is not allowed to pretend.
struct SoilMoistureRead: Hashable {
    enum Verdict: Hashable {
        /// Dry enough to water, and Grove is sure enough to say so.
        case ready
        /// Still holding water. Watering now is the mistake.
        case holding
        /// The estimate straddles the line. Go and feel it.
        case unclear
        /// Nothing has ever been recorded. Not the same as unclear, and the card
        /// says which.
        case noReading
    }

    /// Where the evidence came from, because a felt reading and an inferred one
    /// are not the same claim.
    enum Source: Hashable {
        case soilCheck
        case checkIn
        case watering
    }

    struct Evidence: Hashable {
        let moisture: ObservationSoilMoisture
        let recordedAt: Date
        let source: Source
    }

    /// 0 is bone dry, 1 is just watered. Grove's single best guess.
    let position: Double
    /// The wettest and driest the soil could plausibly be, given how uncertain
    /// the dry-down rate is. Deliberately not symmetric around `position`: once
    /// the nominal estimate has run into the dry end of the scale the band stops
    /// growing downwards, which is why a fortnight-old watering in a pot Grove
    /// measured becomes a firm answer while the same fortnight in an unseen pot
    /// stays open.
    let bandLow: Double
    let bandHigh: Double

    /// Half the band's width — what the card turns into "firm reading" or
    /// "rough estimate".
    var uncertainty: Double { (bandHigh - bandLow) / 2 }
    let verdict: Verdict
    let evidence: Evidence?
    let dryDown: SoilDryDown
    /// Days since the last watering Grove knows about, if there is one.
    let daysSinceWatering: Int?
    /// Days from now until the estimate reaches the watering line — nil once it
    /// already has, or when there is nothing to project from.
    let daysUntilReady: Int?

    /// A reading the owner felt themselves within the last few hours. This is
    /// the only state in which Grove will tell someone to pick up a watering can
    /// rather than to check first.
    var hasFreshFeel: Bool {
        guard let evidence, evidence.source != .watering else { return false }
        return evidence.recordedAt > Date.now.addingTimeInterval(-Self.freshFeelWindow)
    }

    /// Six hours. Long enough to cover "I felt it before work and I am looking at
    /// the app on the bus", short enough that it can never speak for yesterday.
    static let freshFeelWindow: TimeInterval = 6 * 60 * 60

    /// Below this the soil is dry enough to water; above `holdingLine` it is not.
    ///
    /// Internal rather than private because `SoilMoistureGauge` draws these two
    /// lines on its scale. A gauge that marked its thresholds at hardcoded
    /// values would be a second, silent copy of the rule — and the first time
    /// one moved, the needle would sit in a zone the verdict disagreed with.
    static let readyLine = 0.25
    static let holdingLine = 0.42
    /// No estimate is ever drawn narrower than this.
    private static let minimumBandWidth = 0.06

    private static func clamped(_ value: Double) -> Double { min(1, max(0, value)) }

    // MARK: - Derivation

    init(
        plant: Plant,
        observations: [PlantObservation],
        tasks: [CareTask],
        location: GroveLocation? = nil,
        now: Date = .now
    ) {
        let dryDown = SoilDryDown(plant: plant, location: location, now: now)
        self.dryDown = dryDown

        let plantTasks = tasks.filter { $0.plantID == plant.id && $0.isCompleted }
        // `performedAt`, not `dueDate`: the dry-down clock starts when the water
        // went in, and a watering ticked off late used to start it early — the
        // one direction of error that tells someone to water a wet pot.
        let lastWatering = plantTasks
            .filter { $0.kind == .water }
            .max { $0.performedAt < $1.performedAt }?
            .performedAt
        daysSinceWatering = lastWatering.map { Self.wholeDays(from: $0, to: now) }

        evidence = Self.newestEvidence(
            observations: observations.filter { $0.plantID == plant.id },
            tasks: plantTasks,
            lastWatering: lastWatering
        )

        guard let evidence else {
            position = 0.5
            bandLow = 0
            bandHigh = 1
            verdict = .noReading
            daysUntilReady = nil
            return
        }

        let elapsedDays = max(0, now.timeIntervalSince(evidence.recordedAt) / 86_400)
        // 0.85 of the scale between "just watered" and "ready again": the axis
        // keeps a little headroom below the watering line so a plant that has
        // been dry for a fortnight is drawn further left than one that reached
        // it yesterday.
        let ratePerDay = 0.85 / dryDown.days
        let start = Self.startingPosition(for: evidence.moisture)
        position = min(1, max(0, start - elapsedDays * ratePerDay))

        // A reading someone felt within the last few hours is the one moment
        // Grove is close to certain, whatever it does or does not know about the
        // pot: they had a finger in it.
        let isFreshFeel = evidence.source != .watering
            && evidence.recordedAt > now.addingTimeInterval(-Self.freshFeelWindow)
        var low: Double
        var high: Double
        if isFreshFeel {
            low = max(0, position - 0.07)
            high = min(1, position + 0.07)
        } else {
            // The uncertainty lives in the *rate*, not in a flat drift. Grove
            // knows roughly where the soil started; what it does not know is how
            // fast this pot gets through it — and a pot it never saw could be
            // drying at half the speed or twice. Projecting both ends is why an
            // unseen pot stays open however long you wait, while a measured one
            // closes on the answer as the fast and slow projections both run out
            // the bottom of the scale.
            let error = Self.rateError(for: dryDown)
            let fastest = start - elapsedDays * ratePerDay * (1 + error)
            let slowest = start - elapsedDays * ratePerDay * max(0.2, 1 - error)
            // A little slack at both ends for the coarseness of the starting
            // word itself: "about right" covers a lot of soil.
            low = Self.clamped(min(fastest, slowest) - 0.06)
            high = Self.clamped(max(fastest, slowest) + 0.06)
        }

        // Both projections can run off the same end of the scale, which collapses
        // the band to nothing — and a card claiming a zero-width estimate has not
        // earned it, whatever the arithmetic says. Estimates get a floor.
        if high - low < Self.minimumBandWidth {
            let centre = (high + low) / 2
            low = max(0, min(1 - Self.minimumBandWidth, centre - Self.minimumBandWidth / 2))
            high = low + Self.minimumBandWidth
        }
        bandLow = low
        bandHigh = high

        if bandHigh <= Self.readyLine {
            verdict = .ready
        } else if bandLow >= Self.holdingLine {
            verdict = .holding
        } else {
            verdict = .unclear
        }

        if position > Self.readyLine, ratePerDay > 0 {
            daysUntilReady = max(1, Int(((position - Self.readyLine) / ratePerDay).rounded()))
        } else {
            daysUntilReady = nil
        }
    }

    /// How wrong the dry-down rate could be, as a fraction of itself.
    ///
    /// A quarter is the floor: even a pot Grove measured is being modelled from
    /// six enumerated facts, and the weather, the season and the radiator are
    /// not among them. Each unresolved input adds to it, which is the whole
    /// argument for reading the pot at scan time.
    private static func rateError(for dryDown: SoilDryDown) -> Double {
        var error = 0.25
        error += 0.12 * Double(dryDown.unknownInputs)
        if dryDown.lightIsUnknown { error += 0.08 }
        if dryDown.speciesIsGeneric { error += 0.06 }
        return error
    }

    /// The newest dated fact about the soil, whatever produced it.
    ///
    /// A watering counts: the soil was wet the moment it finished, and that is a
    /// firmer starting point than most check-in answers. A felt reading of the
    /// same age wins, because it describes the soil rather than an intention.
    private static func newestEvidence(
        observations: [PlantObservation],
        tasks: [CareTask],
        lastWatering: Date?
    ) -> Evidence? {
        var candidates: [Evidence] = []

        if let felt = tasks
            .filter({ $0.soilMoisture != nil })
            .max(by: { $0.performedAt < $1.performedAt }),
           let moisture = felt.soilMoisture {
            candidates.append(Evidence(moisture: moisture, recordedAt: felt.performedAt, source: .soilCheck))
        }
        // A check-in whose own moisture reading isn't the owner's answer
        // skipped the soil question. Its stored soil value is a default, not
        // something anyone felt. Legacy check-ins without readings still count.
        if let observation = observations.max(by: { $0.createdAt < $1.createdAt }),
           let moisture = observation.answeredSoilMoisture {
            candidates.append(
                Evidence(moisture: moisture, recordedAt: observation.createdAt, source: .checkIn)
            )
        }
        if let lastWatering {
            candidates.append(Evidence(moisture: .wet, recordedAt: lastWatering, source: .watering))
        }

        // Newest wins; on a tie the one that was felt beats the one that was
        // inferred from a watering.
        return candidates.max { left, right in
            if left.recordedAt == right.recordedAt {
                return left.source == .watering && right.source != .watering
            }
            return left.recordedAt < right.recordedAt
        }
    }

    private static func startingPosition(for moisture: ObservationSoilMoisture) -> Double {
        switch moisture {
        case .wet: 1
        case .comfortable: 0.5
        case .dry: 0.15
        }
    }

    private static func wholeDays(from start: Date, to end: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: start),
            to: calendar.startOfDay(for: end)
        ).day ?? 0
    }
}

// MARK: - What the page says

extension SoilMoistureRead {
    /// The headline over the scale: what Grove thinks, in the fewest honest words.
    var headline: String {
        switch verdict {
        case .noReading: "No reading yet"
        case .unclear: "Too close to call"
        case .ready: hasFreshFeel ? "It's dry" : "Probably ready"
        case .holding: hasFreshFeel ? "Still damp" : "Probably still damp"
        }
    }

    /// The instruction, big, in the middle of the card.
    ///
    /// It is "feel the soil" in every state but one. Grove only names the
    /// watering can when the owner has just had a finger in the pot — an
    /// estimate, however narrow its band, is not a reason to pour water on
    /// something.
    var action: String {
        guard hasFreshFeel, let evidence else {
            return needsWeightCheck
                ? "Push a finger two knuckles in, then lift the pot"
                : "Push a finger two knuckles into the soil"
        }
        switch evidence.moisture {
        case .dry: return "Water it slowly until it runs out of the bottom"
        case .comfortable: return "Leave it. There's still water down there"
        case .wet: return "Don't water it. Give it light and air instead"
        }
    }

    /// The line under the instruction: why this, or what to do with the answer.
    var actionDetail: String? {
        if hasFreshFeel, let evidence {
            switch evidence.moisture {
            case .dry where dryDown.holdsWater:
                return "Then tip out whatever collects in the outer pot. It has nowhere else to go."
            case .dry:
                return "Empty the saucer afterwards so it isn't standing in water."
            case .comfortable:
                return daysUntilReady.map { "Feel it again in about \($0) \($0 == 1 ? "day" : "days")." }
            case .wet where dryDown.holdsWater:
                return "It's sitting in a pot water can't leave. Tip the outer one out."
            case .wet:
                return "Move it somewhere brighter if you can. Soil dries faster in good light."
            }
        }
        switch verdict {
        case .noReading:
            return "Nothing recorded for this pot yet. Check in to start the estimate."
        case .unclear:
            return "The estimate straddles the line, so the soil is the only thing that settles it."
        case .ready:
            return "The calendar says it's time, but the soil settles it."
        case .holding:
            return daysUntilReady.map { "Likely ready in about \($0) \($0 == 1 ? "day" : "days")." }
        }
    }

    /// Big pots and top-dressed soil defeat a fingertip: the surface is bark or
    /// pebbles, or the root zone is deeper than a finger reaches. Weight is the
    /// better instrument there, and saying so is the difference between advice
    /// that works and advice that sounds right.
    var needsWeightCheck: Bool {
        guard let conditions = dryDown.conditions else { return false }
        return conditions.potSize == .large
            || conditions.potSize == .xlarge
            || conditions.soilSurface == .obscured
            || conditions.surfaceSigns.contains(.topDressed)
    }

    /// One fact the read is standing on.
    struct Reason: Identifiable, Hashable {
        let id: String
        let text: String
        let symbol: String
        /// True for the facts that change what to do rather than merely explain
        /// it — a pot water cannot leave, gnats in the soil. Drawn warm.
        let isAlarming: Bool
    }

    /// The three facts most responsible for what this card says, strongest first.
    ///
    /// This exists because an estimate nobody can interrogate is a horoscope. The
    /// dated evidence always leads; then anything that changes the advice; then
    /// the pot and the spot, including — deliberately — the ones Grove never got
    /// to see, because "pot not seen" is why the band is wide and the user is
    /// the only one who can close it.
    var reasons: [Reason] {
        var reasons: [Reason] = [evidenceReason]
        reasons.append(contentsOf: potReasons)
        if let light = dryDown.lightPhrase {
            reasons.append(Reason(id: "light", text: light, symbol: "sun.max.fill", isAlarming: false))
        }
        return Array(reasons.prefix(3))
    }

    /// The dated fact the estimate decays from, or the absence of one.
    var evidenceReason: Reason {
        guard let evidence else {
            return Reason(id: "evidence", text: "No soil reading yet", symbol: "questionmark.circle", isAlarming: true)
        }
        return Reason(
            id: "evidence",
            text: evidence.phrase,
            symbol: evidence.source == .watering ? "drop.fill" : "hand.point.down.fill",
            isAlarming: false
        )
    }

    /// What the scan saw of the pot itself, strongest first and uncapped.
    ///
    /// Split out of `reasons` because these are the only facts here that the
    /// scan went out of its way to collect and that nothing else on the plant
    /// page can say. `reasons` shows three lines in total and the dated
    /// evidence always takes one of them, so a pot that is both sitting in a
    /// cover *and* growing gnats could never show its third fact — and the
    /// third fact is the one that gets a plant repotted. The plant page reads
    /// this list directly.
    ///
    /// Every alarming sign is listed, not just the first: "standing water" and
    /// "mould on the surface" are two different things to deal with.
    var potReasons: [Reason] { Self.potReasons(for: dryDown.conditions) }

    /// The pot facts on their own, for callers that hold a plant but have no
    /// reason to derive a whole moisture estimate. Nothing here decays, so the
    /// observations and waterings a `SoilMoistureRead` needs would be dead
    /// weight: the pot is the pot until the next scan sees it again.
    static func potReasons(for conditions: PlantGrowingConditions?) -> [Reason] {
        guard let conditions else {
            return [Reason(id: "pot", text: "Pot never scanned", symbol: "cylinder.split.1x2", isAlarming: false)]
        }

        var reasons: [Reason] = []
        switch conditions.drainage {
        case .cachepot:
            reasons.append(Reason(id: "drainage", text: "Sits in a cover, so water can't leave", symbol: "exclamationmark.triangle.fill", isAlarming: true))
        case .noHoles:
            reasons.append(Reason(id: "drainage", text: "No drainage holes", symbol: "exclamationmark.triangle.fill", isAlarming: true))
        case .drains, .unknown:
            break
        }

        for sign in conditions.surfaceSigns where sign.isAlarming {
            reasons.append(Reason(id: "sign-\(sign.rawValue)", text: sign.phrase, symbol: sign.symbol, isAlarming: true))
        }

        if conditions.potFit == .oversized {
            reasons.append(Reason(id: "fit", text: "Pot is bigger than the roots need", symbol: "arrow.up.left.and.arrow.down.right", isAlarming: true))
        }

        if let potPhrase = conditions.potPhrase {
            reasons.append(Reason(id: "pot", text: potPhrase, symbol: "cylinder.split.1x2", isAlarming: false))
        }

        return reasons
    }

    /// Where on the scale the best guess is standing, named.
    ///
    /// This is the needle's zone, not the verdict: the verdict is taken from the
    /// whole band and can say "can't call it" while the needle sits squarely in
    /// one zone. Both are true and the gauge shows both, which is the point of
    /// drawing a band at all.
    enum Zone: Hashable {
        case dry
        case drying
        case damp

        var name: String {
            switch self {
            case .dry: "Dry"
            case .drying: "Drying out"
            case .damp: "Damp"
            }
        }
    }

    var zone: Zone {
        if position <= Self.readyLine { return .dry }
        if position < Self.holdingLine { return .drying }
        return .damp
    }

    /// How much weight the reading will carry, in three words.
    ///
    /// Read straight off the band's width, because that is the only thing that
    /// earns it: a pot Grove has seen, checked this morning, closes to a firm
    /// reading, and one it has never seen never does however long you wait.
    var confidencePhrase: String {
        switch uncertainty {
        case ..<0.12: "a firm reading"
        case ..<0.25: "a fair estimate"
        default: "a rough estimate"
        }
    }

    /// How the scale's marker should be labelled for VoiceOver, which cannot see
    /// a band.
    var accessibilitySummary: String {
        let confidence = confidencePhrase
        let evidenceLine: String
        if let evidence {
            evidenceLine = "\(evidence.phrase). "
        } else {
            evidenceLine = ""
        }
        return "\(headline), \(confidence). \(evidenceLine)\(action)."
    }
}

extension SoilDryDown {
    /// The spot, as a phrase — or nothing, when nobody has said. Silence is the
    /// right output there: the card already carries "pot never scanned" for the
    /// same reason, and inventing a placement would be indistinguishable from an
    /// answer the owner gave.
    var lightPhrase: String? {
        switch light {
        case .sill: "On the sill"
        case .bright: "Near a bright window"
        case .shaded: "Back from the window"
        // Named as a limitation rather than a fact. Nothing in Grove knows
        // whether it rained on this plant last night, and an owner reading a
        // moisture estimate for something standing outside deserves to be told
        // that before they act on it.
        case .outdoors: "Outdoors. Rain isn't counted"
        case nil: nil
        }
    }
}

extension PlantGrowingConditions {
    /// The pot in one phrase: size then material, whichever of the two the scan
    /// actually resolved.
    var potPhrase: String? {
        let size: String?
        switch potSize {
        case .small: size = "Under 12cm"
        case .medium: size = "12–20cm"
        case .large: size = "20–30cm"
        case .xlarge: size = "Over 30cm"
        case .unknown: size = nil
        }
        let material: String?
        switch potMaterial {
        case .terracotta: material = "terracotta"
        case .plastic: material = "plastic"
        case .glazed: material = "glazed"
        case .metal: material = "metal"
        case .fabric: material = "fabric"
        case .concrete: material = "concrete"
        case .unpotted: return "Not in a pot"
        case .unknown: material = nil
        }
        switch (size, material) {
        case let (size?, material?): return "\(size) \(material)"
        case let (size?, nil): return "\(size) pot"
        case let (nil, material?): return material.prefix(1).uppercased() + material.dropFirst() + " pot"
        case (nil, nil): return nil
        }
    }
}

extension PlantGrowingConditions.SurfaceSign {
    /// Whether this sign changes what to do, rather than merely describing the
    /// soil. Gnats and algae both mean the same thing — it has been wet too long.
    var isAlarming: Bool {
        switch self {
        case .fungusGnats, .mould, .standingWater, .algae, .hydrophobic: true
        case .saltCrust, .moss, .compacted, .rootsAtSurface, .topDressed: false
        }
    }

    var phrase: String {
        switch self {
        case .fungusGnats: "Fungus gnats in the soil"
        case .mould: "Mould on the surface"
        case .standingWater: "Standing water"
        case .algae: "Green algae on the soil"
        case .hydrophobic: "Soil has pulled from the pot"
        case .saltCrust: "Mineral crust on the surface"
        case .moss: "Moss on the surface"
        case .compacted: "Soil looks compacted"
        case .rootsAtSurface: "Roots showing at the surface"
        case .topDressed: "Top-dressed surface"
        }
    }

    var symbol: String {
        switch self {
        case .fungusGnats: "ant.fill"
        case .mould, .algae: "aqi.medium"
        case .standingWater: "drop.triangle.fill"
        case .hydrophobic, .compacted: "square.split.diagonal.2x2"
        case .saltCrust: "sparkles"
        case .moss, .topDressed: "leaf.fill"
        case .rootsAtSurface: "point.3.connected.trianglepath.dotted"
        }
    }
}

extension SoilMoistureRead.Evidence {
    /// How the card cites this fact: what it said, and when.
    var phrase: String {
        let age = Self.age(of: recordedAt)
        switch source {
        case .watering: return "You watered it \(age)"
        case .soilCheck, .checkIn:
            let word: String
            switch moisture {
            case .dry: word = "dry"
            case .comfortable: word = "about right"
            case .wet: word = "wet"
            }
            return "Soil felt \(word) \(age)"
        }
    }

    private static func age(of date: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: .now)
        ).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case ..<14: return "\(days) days ago"
        case ..<60: return "\(days / 7) weeks ago"
        default: return "months ago"
        }
    }
}

extension PlantObservation {
    /// The soil as the owner answered it, or nil when they skipped the
    /// question. The stored `soilMoisture` is non-optional, so a skipped answer
    /// is saved as a default; the check-in's own moisture reading says whether
    /// anyone felt it. Legacy check-ins without readings are taken as answered.
    var answeredSoilMoisture: ObservationSoilMoisture? {
        guard let reading = indicatorReadings?.first(where: { $0.kind == .moisture }) else {
            return soilMoisture
        }
        return reading.source == .ownerReport ? soilMoisture : nil
    }
}
