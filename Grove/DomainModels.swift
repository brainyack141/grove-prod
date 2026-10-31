import CoreLocation
import Foundation

enum HealthBand: String, CaseIterable, Codable, Hashable, Sendable {
    case thriving
    case healthy
    case monitor
    case attention
    case urgent

    var title: String {
        switch self {
        case .thriving: "Thriving"
        case .healthy: "Healthy"
        case .monitor: "Keep an eye on it"
        case .attention: "Needs attention"
        case .urgent: "Urgent"
        }
    }

    var shortTitle: String {
        switch self {
        case .monitor: "Monitor"
        case .attention: "Attention"
        default: title
        }
    }

    // Band colours live in `DesignSystem.swift` (`HealthBand.color`) so the
    // model stays presentation-free.

    var icon: String {
        switch self {
        case .thriving: "sparkles"
        case .healthy: "checkmark.circle.fill"
        case .monitor: "eye.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .urgent: "cross.case.fill"
        }
    }

    /// The band a 0–100 score falls in. One mapping for the whole app, so a
    /// band stored on a check-in and a band derived later from an average
    /// never disagree about what 87 means.
    init(score: Int) {
        self = score >= 90
            ? .thriving
            : score >= 75
                ? .healthy
                : score >= 55
                    ? .monitor
                    : score >= 30 ? .attention : .urgent
    }
}

extension HealthBand {
    /// Whether this band is asking for something. Drives emphasis in charts: a
    /// calm week stays in a single colour, and only a reading that slipped
    /// flags itself.
    var needsAttention: Bool {
        switch self {
        case .thriving, .healthy: false
        case .monitor, .attention, .urgent: true
        }
    }
}

enum HealthTrend: String, Codable, Hashable, Sendable {
    case improving
    case stable
    case declining
    case baseline

    var title: String {
        switch self {
        case .improving: "Improving"
        case .stable: "Stable"
        case .declining: "Declining"
        case .baseline: "Baseline"
        }
    }

    var icon: String {
        switch self {
        case .improving: "arrow.up.right"
        case .stable: "arrow.right"
        case .declining: "arrow.down.right"
        case .baseline: "circle.dashed"
        }
    }

    // Trend colours live in `DesignSystem.swift` (`HealthTrend.color`).
}

/// One of the six health signals Grove follows for every plant.
///
/// This lives in the domain layer rather than in `PlantDetailView`: indicator
/// readings are evidence records now, not values recreated when a tile appears.
enum PlantHealthIndicatorKind: String, CaseIterable, Codable, Hashable, Sendable {
    case moisture
    case light
    case foliage
    case posture
    case growth
    case care
}

/// How directly a health-indicator value is grounded.
///
/// `measured` is reserved for an instrument. A person's soil check and a photo
/// review are observations; a species/placement calculation is an estimate.
/// Keeping those words durable stops a sync or a future UI rewrite from turning
/// an estimate into a measurement.
enum PlantHealthIndicatorEvidenceLevel: String, Codable, Hashable, Sendable {
    case measured
    case observed
    case estimated
    case unavailable
}

enum PlantHealthIndicatorSource: String, Codable, Hashable, Sendable {
    case ownerReport
    case photoAnalysis
    case speciesGuide
    case careHistory
    case sensor
    case legacyInference
    case none
}

/// An immutable snapshot of what one indicator said at an assessment.
///
/// `value` is the stable raw vocabulary (for example `comfortable`, `upright`
/// or `new-growth`). `score` is optional because a direct categorical reading
/// must not acquire a made-up percentage merely to fill a progress bar.
struct PlantHealthIndicatorReading: Codable, Hashable, Sendable {
    let kind: PlantHealthIndicatorKind
    let value: String
    let score: Int?
    let status: String
    let detail: String
    let evidenceLevel: PlantHealthIndicatorEvidenceLevel
    let source: PlantHealthIndicatorSource
    let confidence: Int?
    let evidence: [String]
    let measuredAt: Date
    let validUntil: Date?
    let algorithmVersion: String
}

/// Structured visual output from the analysis gateway. Unlike the old keyword
/// search, each result names the signal, severity, confidence, and exact visible
/// evidence that supports it.
struct PlantVisualIndicatorFinding: Codable, Hashable, Sendable {
    enum State: String, Codable, Hashable, Sendable {
        case good
        case watch
        case neutral
        case unavailable
    }

    let kind: PlantHealthIndicatorKind
    let state: State
    let severity: Int
    let confidence: Int
    let evidence: [String]
}

/// Where a plant stands in relation to the light.
///
/// `Plant.location` is a room name, and a room name says nothing a plant cares
/// about: "Bedroom" covers both a pane-side windowsill and a dark corner three
/// metres away, which differ by more than an order of magnitude in the light
/// they deliver. This is the missing half — four positions, because that is as
/// fine a distinction as anyone can make honestly without a light meter, and
/// because each one changes different advice.
enum PlantLightPlacement: String, Codable, CaseIterable, Hashable, Sendable {
    /// On the sill, or close enough to touch the glass.
    case sill
    /// A step or two into the room from a window that gets direct sun.
    case bright
    /// Across the room, or at a window the sun never reaches directly.
    case shaded
    /// Outside — garden, balcony, doorstep.
    case outdoors

    var title: String {
        switch self {
        case .sill: "On the windowsill"
        case .bright: "Near a bright window"
        case .shaded: "Away from the window"
        case .outdoors: "Outdoors"
        }
    }

    var detail: String {
        switch self {
        case .sill: "Touching the glass, or on the ledge"
        case .bright: "A step or two into the room"
        case .shaded: "No direct sun reaches it"
        case .outdoors: "Garden, balcony, doorstep"
        }
    }

    var icon: String {
        switch self {
        case .sill: "sun.horizon.fill"
        case .bright: "window.vertical.closed"
        // A dim sun, not a moon: "away from the window" is a fact about
        // daytime. A moon says night, which is somewhere every plant lives
        // half the time.
        case .shaded: "sun.min.fill"
        case .outdoors: "tree.fill"
        }
    }

    /// Roughly the share of outdoor light that reaches a plant here.
    ///
    /// Glass alone costs a plant a fifth or so; the rest is geometry. Light
    /// falls away sharply with distance from the opening, and a spot with no
    /// direct sun is living on sky-glow. These are honest orders of magnitude,
    /// not measurements, and every surface that uses them says so.
    var outdoorLightShare: Double {
        switch self {
        case .sill: 0.5
        case .bright: 0.2
        case .shaded: 0.05
        case .outdoors: 1
        }
    }

    var isIndoors: Bool { self != .outdoors }

    /// Whether cold and heat coming through the glass reach this plant. A pane
    /// on a frosty night is a cold surface, and only the plants leaning on it
    /// feel that.
    var feelsTheGlass: Bool { self == .sill }

    /// The best guess when nobody has been asked yet, from the room name the
    /// adopt form did collect.
    static func inferred(fromLocation location: String) -> PlantLightPlacement? {
        let name = location.lowercased()
        let outdoorWords = ["garden", "balcony", "patio", "porch", "deck", "yard", "terrace", "doorstep", "greenhouse", "outdoor", "outside", "allotment", "veg patch", "vegetable patch", "window box", "courtyard"]
        // These are only outdoors as whole words: "Bed 3" is a bed, "Bedroom"
        // is not, so the name is split on anything that is not a letter.
        let outdoorTokens: Set<String> = ["bed", "beds", "plot", "plots", "border"]
        let tokens = name.split(whereSeparator: { !$0.isLetter }).map(String.init)
        // Explicit closure rather than `where: name.contains`. Same partial
        // application that crashed `GroveSky.Grove.named` in optimised builds,
        // and this runs inside that very filter — see the note there.
        let namedOutdoors = outdoorWords.contains { name.contains($0) }
        let tokenOutdoors = tokens.contains { outdoorTokens.contains($0) }
        return namedOutdoors || tokenOutdoors ? .outdoors : nil
    }
}

enum PlantLifecycleState: String, Codable, CaseIterable, Hashable, Sendable {
    /// The ordinary living record. Health is modelled separately by
    /// `HealthBand`; this value is about whether the plant is still in active
    /// care, not how well it looks today.
    case active
    case dormant
    case archived
    case deceased

    var title: String {
        switch self {
        case .active: "Active"
        case .dormant: "Dormant"
        case .archived: "Archived"
        case .deceased: "Remembered"
        }
    }

    var detail: String {
        switch self {
        case .active: "Included in care, reminders and health check-ins."
        case .dormant: "Kept in the grove, with routine growth reminders paused."
        case .archived: "Kept as a record without appearing in the active care queue."
        case .deceased: "The living record is preserved and future care is paused."
        }
    }

    var icon: String {
        switch self {
        case .active: "leaf.fill"
        case .dormant: "moon.zzz.fill"
        case .archived: "archivebox.fill"
        case .deceased: "heart.fill"
        }
    }

    var receivesCareReminders: Bool { self == .active }
}

enum PlantAssessmentSource: String, Codable, Hashable, Sendable {
    case baselinePhoto
    case checkInPhoto
    case diagnosisPhoto
    case offlineEstimate
    case imported

    var title: String {
        switch self {
        case .baselinePhoto: "Baseline photo"
        case .checkInPhoto: "Check-in photo"
        case .diagnosisPhoto: "Diagnosis photos"
        case .offlineEstimate: "Saved without photo analysis"
        case .imported: "Imported record"
        }
    }
}

enum PlantEnvironmentSource: String, Codable, CaseIterable, Hashable, Sendable {
    case measured
    case estimated
    case ownerReported

    var title: String {
        switch self {
        case .measured: "Measured"
        case .estimated: "Estimated"
        case .ownerReported: "Owner reported"
        }
    }
}

/// A dated reading of the conditions around this particular plant. Species
/// preferences remain in `PlantCareProfile`; these are the facts about the
/// windowsill, room or garden the plant actually lives in.
struct PlantEnvironmentReading: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var recordedAt: Date
    var source: PlantEnvironmentSource
    var temperatureCelsius: Double?
    var humidityPercent: Double?
    var lightLux: Double?
    var note: String

    var hasMeasurements: Bool {
        temperatureCelsius != nil || humidityPercent != nil || lightLux != nil
    }
}

enum PlantCarePlanStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case proposed
    case active
    case completed
    case replaced
    case abandoned

    var title: String { rawValue.capitalized }
}

enum PlantCarePlanActionState: String, Codable, CaseIterable, Hashable, Sendable {
    case proposed
    case due
    case completed
    case skipped

    var title: String { rawValue.capitalized }
}

/// One ordered step in a plant's maintenance or recovery plan. Unlike the
/// legacy `[String]` next-actions list, this keeps the reason, due window and
/// expected response attached to the instruction through follow-up.
struct PlantCarePlanAction: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var kind: CareKind
    var instruction: String
    var rationale: String
    var dueFrom: Date?
    var dueUntil: Date?
    var expectedResponse: String
    var state: PlantCarePlanActionState
    var completedAt: Date?
    /// For a check ("scratch the trunk"), the results it could turn up. Nil
    /// for a step that is itself the care, and for plans made before checks
    /// carried their results.
    var outcomes: [PlantCheckOutcome]? = nil
    /// The outcome the owner said the check turned up.
    var findingID: String? = nil

    var finding: PlantCheckOutcome? {
        guard let findingID else { return nil }
        return outcomes?.first { $0.id == findingID }
    }
}

/// One result a check can turn up: what the owner saw, what it says about the
/// plant, and the step it leads to. The answer to "I did it, now what?".
struct PlantCheckOutcome: Identifiable, Codable, Hashable, Sendable {
    var id: String
    /// In the owner's words, short enough for a button: "Green under the bark".
    var title: String
    /// One sentence on what that result means for this plant.
    var meaning: String
    /// The step it leads to. Empty when the right move is to wait for the
    /// next photo.
    var nextStep: String
}

/// A next action the analysis marked as a check, with its possible results.
struct PlantCheck: Codable, Hashable, Sendable {
    var action: String
    var outcomes: [PlantCheckOutcome]
}

struct PlantCarePlan: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var goal: String
    var actions: [PlantCarePlanAction]
    var startedAt: Date
    var reviewAt: Date?
    var status: PlantCarePlanStatus
    /// Written at follow-up so a completed plan retains what happened rather
    /// than being overwritten by the next set of actions.
    var outcome: String?
}

/// How the plant's current taxonomic identity was established.
///
/// Safety can still surface a conservative warning from a photo match, but a
/// reassuring finding is shown only after a person has selected the identity
/// from the candidate list. Free text remains useful as a record without being
/// silently promoted to a checked catalogue identity.
enum PlantIdentityConfirmation: String, Codable, Hashable, Sendable {
    case photoMatch
    case userConfirmed
    case manualEntry
    case unknown

    var permitsReassurance: Bool { self == .userConfirmed }
}

struct Plant: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var nickname: String
    var species: String
    var scientificName: String
    /// Stable taxonomic identity from the catalogue, currently a `gbif:<key>`
    /// value. Optional for plants saved before catalogue identity was retained
    /// and for photo/manual names that have not been resolved to a taxon.
    var canonicalTaxonID: String? = nil
    var identityConfirmation: PlantIdentityConfirmation? = nil
    var location: String
    /// Where it stands relative to the light. Optional: plants added before
    /// Grove asked have never been told, and a guess written into the record
    /// would be indistinguishable from an answer.
    var lightPlacement: PlantLightPlacement? = nil
    /// What the scan could see of the pot and the soil. Nil for plants adopted
    /// before Grove read them, which the watering card states rather than hides.
    var growingConditions: PlantGrowingConditions? = nil
    var healthScore: Int
    var healthBand: HealthBand
    var trend: HealthTrend
    /// Grove's confidence in the current *health* reading, 0–100.
    ///
    /// This is not the confidence in the plant's identity. The two were one
    /// field until a species correction — which sets identification confidence
    /// to 100 — started making the plant page claim high confidence in a health
    /// score nothing had recomputed. See `identificationConfidence`.
    var confidence: Int
    /// Grove's confidence that the species is right, 0–100, or nil when the
    /// plant predates the split and nothing has re-identified it since.
    ///
    /// Optional so an existing grove decodes without migration.
    var identificationConfidence: Int? = nil
    var nextCheckIn: Date
    var symbol: String
    var palette: PlantPalette
    var summary: String
    var positiveSigns: [String]
    var concerns: [String]
    var nextActions: [String]
    /// Optional additions keep snapshots written before the persistent plant
    /// profile shipped decodable without a migration pass.
    var lifecycleState: PlantLifecycleState? = nil
    var acquiredAt: Date? = nil
    var notes: String? = nil
    var environmentReadings: [PlantEnvironmentReading]? = nil
    var carePlan: PlantCarePlan? = nil
    var carePlanHistory: [PlantCarePlan]? = nil
    var assessmentDate: Date? = nil
    var assessmentSource: PlantAssessmentSource? = nil
    /// Latest durable snapshot of the six indicator readings. Historical
    /// snapshots live on observations and diagnoses; this copy makes the current
    /// plant summary cheap to render and survives a cross-device bootstrap.
    var healthIndicatorReadings: [PlantHealthIndicatorReading]? = nil
    /// How often the owner wants to be asked for a check-in photo, in days.
    /// `nil` means automatic: Grove picks the cadence from the plant's health.
    /// Optional-with-default so an existing grove decodes without migration.
    var checkInFrequencyDays: Int? = nil

    var effectiveLifecycleState: PlantLifecycleState {
        lifecycleState ?? .active
    }

    /// Whether Grove holds a real health reading for this plant.
    ///
    /// A plant saved without a usable assessment (no analysis, or the scan said
    /// a clearer photo is needed) is stamped `.offlineEstimate`. Its stored score
    /// and band are a neutral placeholder that no surface may present as a reading.
    /// A later photo check-in sets `.checkInPhoto` and the plant becomes assessed.
    var hasHealthReading: Bool {
        assessmentSource != .offlineEstimate
    }

    /// Stored for a plant with no reading so the non-optional score fields stay
    /// valid. Never displayed: every health surface checks `hasHealthReading`.
    static let unassessedPlaceholderScore = 70

    /// The health-reading confidence, decayed by age.
    ///
    /// `confidence` was written once, at assessment time, and never revised:
    /// after nine check-ins the "confidence" beside "Measured yesterday" could
    /// be the number the adoption scan produced months ago. A reading nobody has
    /// re-taken for a month is not as certain as one taken this morning, and the
    /// page should not imply it is. Falls no faster than half the original value
    /// and never below a floor, so a real assessment is not erased outright.
    func effectiveHealthConfidence(at date: Date = .now) -> Int {
        guard let assessedAt = assessmentDate, assessedAt <= date else { return confidence }
        let days = max(0, Int(date.timeIntervalSince(assessedAt) / 86_400))
        guard days > 30 else { return confidence }
        let decayed = Double(confidence) * pow(0.5, Double(days - 30) / 120)
        return max(10, min(confidence, Int(decayed.rounded())))
    }

    var profileNotes: String {
        notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var latestEnvironmentReading: PlantEnvironmentReading? {
        environmentReadings?.max { $0.recordedAt < $1.recordedAt }
    }

    /// What Grove will act on: the answer if there is one, otherwise whatever
    /// the room name gives away. Nil means Grove genuinely does not know, and
    /// advice that depends on it must leave this plant out rather than assume.
    var effectiveLightPlacement: PlantLightPlacement? {
        lightPlacement ?? PlantLightPlacement.inferred(fromLocation: location)
    }

    var daysUntilCheckIn: Int {
        // Compare day boundaries, not raw timestamps: counting elapsed
        // 24-hour intervals shows "Due today" the evening before, and keeps
        // showing it for most of the day after it was due.
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: .now),
            to: calendar.startOfDay(for: nextCheckIn)
        ).day ?? 0
    }

    /// How much of the current check-in interval has elapsed.
    ///
    /// The schedule's beginning comes from recorded evidence rather than an
    /// assumed cadence: recovery windows vary by plant and can be adjusted
    /// after every assessment. If older synced data has no evidence date, the
    /// progress stays empty until the check-in is due.
    func checkInProgress(since startDate: Date?, at date: Date = .now) -> Double {
        guard date < nextCheckIn else { return 1 }
        guard let startDate, startDate < nextCheckIn else { return 0 }

        let duration = nextCheckIn.timeIntervalSince(startDate)
        let elapsed = date.timeIntervalSince(startDate)
        return min(1, max(0, elapsed / duration))
    }

    /// The cadences offered on the edit screen.
    static let checkInFrequencyOptions = [3, 7, 14, 30]

    static func checkInFrequencyTitle(days: Int) -> String {
        switch days {
        case 3: return "Every 3 days"
        case 7: return "Every week"
        case 14: return "Every 2 weeks"
        case 30: return "Every month"
        default: return "Every \(days) days"
        }
    }
}

enum ObservationAppearance: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case better
    case same
    case worse

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum ObservationSoilMoisture: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case dry
    case comfortable
    case wet

    var id: Self { self }
    var title: String { rawValue.capitalized }

    /// The answer as an owner would give it, with the knuckle test in it.
    /// `title` is the storage word: "Comfortable" is not something anyone says
    /// about soil, and asking the question in those terms gets a worse answer.
    var feltTitle: String {
        switch self {
        case .dry: "Dry to the knuckle"
        case .comfortable: "Damp, about right"
        case .wet: "Wet"
        }
    }

    /// The same answer in the past tense, for a confirmation.
    var feltPhrase: String {
        switch self {
        case .dry: "dry"
        case .comfortable: "about right"
        case .wet: "wet"
        }
    }
}

struct PlantObservation: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let plantID: UUID
    let createdAt: Date
    let previousScore: Int
    let score: Int
    let band: HealthBand
    var note: String
    let appearance: ObservationAppearance
    let soilMoisture: ObservationSoilMoisture
    let hasNewGrowth: Bool
    /// Mutable so `GroveStore` can re-root it when the app's data container
    /// changes on reinstall — see `GroveMediaPath`.
    var photoURL: URL?
    let actorName: String
    /// True when the score came from `CheckInView`'s on-device arithmetic rather
    /// than from an assessment that looked at the photograph. Offline is one
    /// possible cause; provider, quota and image failures can also require it.
    ///
    /// The estimate nudges the previous score from three form answers and, by
    /// its own comment, knows nothing about the image. Without this flag it
    /// entered the history indistinguishable from a real reading — drawn in the
    /// same stroke on the trend line, folded into the "since you started" delta,
    /// and counted in "9 readings" — which is exactly the "score should not
    /// change dramatically from weak evidence alone" rule being broken by
    /// stripping the weakness off before storage.
    ///
    /// Optional-with-default so an existing grove decodes without migration.
    var isEstimated: Bool = false
    /// Assessment metadata and the six indicator snapshots are optional for old
    /// records, but every new check-in writes them.
    var confidence: Int? = nil
    var actionability: DiagnosisActionability? = nil
    var assessmentAvailable: Bool? = nil
    var analysisVersion: String? = nil
    var providerName: String? = nil
    var limitations: [String]? = nil
    var referenceObservationID: UUID? = nil
    var indicatorReadings: [PlantHealthIndicatorReading]? = nil
}

extension PlantObservation {
    private enum CodingKeys: String, CodingKey {
        case id, plantID, createdAt, previousScore, score, band, note
        case appearance, soilMoisture, hasNewGrowth, photoURL, actorName
        case isEstimated, confidence, actionability, assessmentAvailable
        case analysisVersion, providerName, limitations, referenceObservationID
        case indicatorReadings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        plantID = try container.decode(UUID.self, forKey: .plantID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        previousScore = try container.decode(Int.self, forKey: .previousScore)
        score = try container.decode(Int.self, forKey: .score)
        band = try container.decode(HealthBand.self, forKey: .band)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        appearance = try container.decodeIfPresent(ObservationAppearance.self, forKey: .appearance) ?? .same
        soilMoisture = try container.decodeIfPresent(ObservationSoilMoisture.self, forKey: .soilMoisture) ?? .comfortable
        hasNewGrowth = try container.decodeIfPresent(Bool.self, forKey: .hasNewGrowth) ?? false
        photoURL = try container.decodeIfPresent(URL.self, forKey: .photoURL)
        actorName = try container.decodeIfPresent(String.self, forKey: .actorName) ?? "You"
        isEstimated = try container.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false
        confidence = try container.decodeIfPresent(Int.self, forKey: .confidence)
        actionability = try container.decodeIfPresent(DiagnosisActionability.self, forKey: .actionability)
        assessmentAvailable = try container.decodeIfPresent(Bool.self, forKey: .assessmentAvailable)
        analysisVersion = try container.decodeIfPresent(String.self, forKey: .analysisVersion)
        providerName = try container.decodeIfPresent(String.self, forKey: .providerName)
        limitations = try container.decodeIfPresent([String].self, forKey: .limitations)
        referenceObservationID = try container.decodeIfPresent(UUID.self, forKey: .referenceObservationID)
        indicatorReadings = try container.decodeIfPresent([PlantHealthIndicatorReading].self, forKey: .indicatorReadings)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(plantID, forKey: .plantID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(previousScore, forKey: .previousScore)
        try container.encode(score, forKey: .score)
        try container.encode(band, forKey: .band)
        try container.encode(note, forKey: .note)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(soilMoisture, forKey: .soilMoisture)
        try container.encode(hasNewGrowth, forKey: .hasNewGrowth)
        try container.encodeIfPresent(photoURL, forKey: .photoURL)
        try container.encode(actorName, forKey: .actorName)
        try container.encode(isEstimated, forKey: .isEstimated)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encodeIfPresent(actionability, forKey: .actionability)
        try container.encodeIfPresent(assessmentAvailable, forKey: .assessmentAvailable)
        try container.encodeIfPresent(analysisVersion, forKey: .analysisVersion)
        try container.encodeIfPresent(providerName, forKey: .providerName)
        try container.encodeIfPresent(limitations, forKey: .limitations)
        try container.encodeIfPresent(referenceObservationID, forKey: .referenceObservationID)
        try container.encodeIfPresent(indicatorReadings, forKey: .indicatorReadings)
    }
}

struct PlantDiagnosis: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let plantID: UUID
    let createdAt: Date
    let summary: String
    let healthBand: HealthBand
    let confidence: Int
    let possibleConditions: [PlantConditionCandidate]
    let actionsToTake: [String]
    let actionsToAvoid: [String]
    /// Structured Gemini-to-Botanist bridge. Optional so diagnoses saved before
    /// this schema continue to decode without losing the user's history.
    let providerName: String?
    let identificationConfidence: Int?
    let identificationRequiresConfirmation: Bool?
    let visiblePositiveSigns: [String]?
    let visibleConcerns: [String]?
    let clarifyingQuestions: [DiagnosisQuestion]?
    let limitations: [String]?
    var analysisVersion: String? = nil
    /// Whether this diagnosis was allowed to change the plant's canonical
    /// health/care state. Optional preserves histories saved before the gate.
    var actionability: DiagnosisActionability? = nil
    /// Mutable so `GroveStore` can re-root it — see `GroveMediaPath`.
    var photoURL: URL?
    /// Structured visible signals captured with this diagnosis. Optional keeps
    /// diagnoses written before the indicator contract decodable.
    var indicatorReadings: [PlantHealthIndicatorReading]? = nil

    /// A server-safe record. Local protected-file URLs have meaning only on the
    /// device that owns them and must never be uploaded as diagnosis metadata.
    var withoutLocalPhoto: PlantDiagnosis {
        var copy = self
        copy.photoURL = nil
        return copy
    }
}

struct ScanHistoryRecord: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let mode: ScanMode
    let commonName: String
    let scientificName: String
    let identificationConfidence: Int
    let healthScore: Int
    let healthBand: HealthBand
    /// Mutable so `GroveStore` can re-root it — see `GroveMediaPath`.
    var photoURL: URL?
    var plantID: UUID? = nil
    var summary: String? = nil
    var isUnknown: Bool? = nil
    var analysisVersion: String? = nil
}

/// Named artwork colourways for plants, collections, and badges. The gradient
/// values live in `DesignSystem.swift` (`PlantPalette.colors`).
/// Grove's colourways, in two groups.
///
/// The first five are *botanical*: they colour foliage in `PlantPortrait` and
/// each one carries a growth habit, so a plant's palette is also its silhouette.
/// The rest are collection-only — they tint covers and badges but never front a
/// portrait, which is why they are absent from `allBotanicalCases`. Keeping them
/// in one enum means a collection cover and a plant pot are drawn from the same
/// gradient vocabulary; splitting the *list* is what stops a lavender monstera.
enum PlantPalette: String, Codable, Hashable, Sendable {
    case fern
    case lime
    case sage
    case sunset
    case moss
    case bloom
    case lavender
    case rain
    case honey
    case bark
}

/// A user-created, cross-cutting grouping of plants. Independent of a plant's
/// physical `location`: a plant can belong to several collections at once, and
/// collections carry no care semantics — they are purely how the owner chooses
/// to organise and, later, delegate their Grove.
struct PlantCollection: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var symbol: String
    var palette: PlantPalette
    var plantIDs: [UUID]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "folder.fill",
        palette: PlantPalette = .fern,
        plantIDs: [UUID] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.palette = palette
        self.plantIDs = plantIDs
        self.createdAt = createdAt
    }
}

extension PlantCollection {
    /// Stable identifiers retained for decoding existing collections. The UI
    /// maps these to Grove's custom botanical artwork rather than exposing a
    /// mixture of generic system glyphs.
    static let iconChoices: [String] = [
        "folder.fill",
        "leaf.fill",
        "tree.fill",
        "house.fill",
        "sofa.fill",
        "bed.double.fill",
        "sun.max.fill",
        "moon.fill",
        "drop.fill",
        "fork.knife",
        "pawprint.fill",
        "cross.case.fill",
        "gift.fill",
        "star.fill",
        "sparkles"
    ]

    static let iconAssets: [String: String] = [
        "folder.fill": "CollectionIconAllPlants",
        "leaf.fill": "CollectionIconPropagation",
        "tree.fill": "CollectionIconGarden",
        "house.fill": "CollectionIconWindow",
        "sofa.fill": "CollectionIconShelf",
        "bed.double.fill": "CollectionIconBedroom",
        "sun.max.fill": "CollectionIconSunny",
        "moon.fill": "CollectionIconLowLight",
        "drop.fill": "CollectionIconHumidity",
        "fork.knife": "CollectionIconKitchen",
        "pawprint.fill": "CollectionIconPetSafe",
        "cross.case.fill": "CollectionIconRescue",
        "gift.fill": "CollectionIconGifted",
        "star.fill": "CollectionIconFavourite",
        "sparkles": "CollectionIconThriving"
    ]

    static let iconLabels: [String: String] = [
        "folder.fill": "All plants",
        "leaf.fill": "Propagation",
        "tree.fill": "Garden",
        "house.fill": "Window plants",
        "sofa.fill": "Plant shelf",
        "bed.double.fill": "Bedroom",
        "sun.max.fill": "Sunny spot",
        "moon.fill": "Low light",
        "drop.fill": "Humidity lovers",
        "fork.knife": "Kitchen herbs",
        "pawprint.fill": "Pet safe",
        "cross.case.fill": "Plant rescues",
        "gift.fill": "Gifted plants",
        "star.fill": "Favourites",
        "sparkles": "Thriving"
    ]

    static func iconAsset(for symbol: String) -> String? {
        iconAssets[symbol]
    }

    static func iconLabel(for symbol: String) -> String {
        iconLabels[symbol] ?? "Collection"
    }

    /// Palettes offered as colourways, mirroring the plant artwork gradients.
    /// Greens first, because most collections are just corners of the grove;
    /// the warmer and cooler ones follow for the collections that want to be
    /// told apart at a glance on My Grove.
    static let paletteChoices: [PlantPalette] = [
        .fern, .lime, .sage, .moss, .rain,
        .sunset, .honey, .bark, .bloom, .lavender
    ]
}

enum CareKind: String, Codable, CaseIterable, Hashable, Sendable {
    case checkIn
    case inspectSoil
    case water
    case fertilise
    case rotate
    case cleanLeaves
    case treat
    case prune
    case repot
    case relocate
    case monitor

    var title: String {
        switch self {
        case .checkIn: "Health check-in"
        case .inspectSoil: "Feel the soil"
        case .water: "Water only if it's dry"
        case .fertilise: "Fertilise"
        case .rotate: "Turn the pot"
        case .cleanLeaves: "Clean the leaves"
        case .treat: "Treatment due"
        case .prune: "Trim what's damaged"
        case .repot: "Repot"
        case .relocate: "Move to a better spot"
        case .monitor: "Monitor the change"
        }
    }

    var icon: String {
        switch self {
        case .checkIn: "camera.viewfinder"
        case .inspectSoil: "hand.point.down.fill"
        case .water: "drop.fill"
        case .fertilise: "leaf.circle.fill"
        case .rotate: "rotate.right.fill"
        case .cleanLeaves: "sparkles"
        case .treat: "cross.case.fill"
        case .prune: "scissors"
        case .repot: "cylinder.split.1x2"
        case .relocate: "arrow.up.and.down.and.arrow.left.and.right"
        case .monitor: "eye.fill"
        }
    }

    /// How the action reads as something already done — "logged watering",
    /// "logged a soil check". `title` is phrased as an instruction ("Water if
    /// dry"), which reads as nonsense in a past-tense confirmation.
    var loggedTitle: String {
        switch self {
        case .checkIn: "a health check-in"
        case .inspectSoil: "a soil check"
        case .water: "watering"
        case .fertilise: "fertilising"
        case .rotate: "a rotation"
        case .cleanLeaves: "a leaf clean"
        case .treat: "a treatment"
        case .prune: "pruning"
        case .repot: "repotting"
        case .relocate: "a move"
        case .monitor: "a progress check"
        }
    }

    /// The label offered in the "log care" picker, phrased as the thing the
    /// user just did.
    var logTitle: String {
        switch self {
        case .checkIn: "Completed a check-in"
        case .inspectSoil: "Checked the soil"
        case .water: "Watered"
        case .fertilise: "Fertilised"
        case .rotate: "Rotated"
        case .cleanLeaves: "Cleaned leaves"
        case .treat: "Treated"
        case .prune: "Pruned"
        case .repot: "Repotted"
        case .relocate: "Moved"
        case .monitor: "Monitored"
        }
    }

    /// The task named as a *thing* rather than as an instruction, for places
    /// that print it beside its own timing — "Check-in · in 4 days".
    ///
    /// `title` is phrased as a command and cannot be reused there: "Water only
    /// if it's dry tomorrow" is not a sentence, and shortening it to "Water"
    /// would turn Grove's one deliberate refusal — it never tells you to water
    /// on a calendar — into a calendar reminder. A noun names the open task
    /// without instructing anything.
    var scheduleNoun: String {
        switch self {
        case .checkIn: "Check-in"
        case .inspectSoil: "Soil check"
        case .water: "Watering"
        case .fertilise: "Fertilising"
        case .rotate: "Rotation"
        case .cleanLeaves: "Leaf clean"
        case .treat: "Treatment"
        case .prune: "Trim"
        case .repot: "Repotting"
        case .relocate: "Move"
        case .monitor: "Review"
        }
    }

    /// The actions a user can record by hand, in the order they come up in real
    /// care. A check-in is deliberately absent: it needs the guided photo flow
    /// to be worth anything, so it can never be a one-tap log.
    ///
    /// `inspectSoil` is also absent now: the "feel the soil" ritual is retired,
    /// and a soil observation arrives with a photo check-in instead. The case
    /// and its stored history remain, so old records still decode and render.
    static let loggable: [CareKind] = [
        .water, .fertilise, .prune, .rotate, .cleanLeaves,
        .treat, .repot, .relocate, .monitor
    ]
}

struct CareTask: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let plantID: UUID
    var kind: CareKind
    var dueDate: Date
    var detail: String
    var isCompleted: Bool
    var isSittingTask: Bool
    var ownerName: String?
    /// What the soil actually felt like, when the owner was asked.
    ///
    /// Set only by the plant page's watering card, which asks the question at
    /// the one moment it is answerable — finger in the soil, standing over the
    /// plant. That makes a soil check a dated *reading* rather than a tick, and
    /// it is the cheapest evidence in the product: three seconds, no photo, and
    /// it collapses the whole moisture estimate to a known value.
    ///
    /// Optional-with-default so an existing grove decodes without migration.
    var soilMoisture: ObservationSoilMoisture? = nil
    /// The moment this care was actually carried out.
    ///
    /// `dueDate` is a schedule, not a record. Ticking Monday's watering off on
    /// Thursday filed it under Monday, so every history Grove drew from these
    /// rows was wrong by however late the owner ran — and a watering rhythm is
    /// nothing but the gaps between these dates, so it has to be the real one.
    ///
    /// Self-logged care was always correct (`logCare` stamps `dueDate` with
    /// `.now`); it is the scheduled-then-ticked path that drifted.
    ///
    /// Optional-with-default so an existing grove decodes without migration.
    /// Rows written before this shipped keep their due date as the best
    /// evidence they have, and `dateIsInferred` marks them so nothing presents
    /// a reminder date as a record of what happened.
    var completedAt: Date? = nil

    /// When this care happened, for completed tasks.
    ///
    /// Falls back to the due date for anything ticked before Grove recorded the
    /// moment. Meaningless on an incomplete task, where it is simply the date
    /// the task is *due*; every caller filters on `isCompleted` first.
    var performedAt: Date { completedAt ?? dueDate }

    /// True when `performedAt` is a reminder date standing in for a record.
    ///
    /// The same honesty rule `PlantObservation.isEstimated` follows: a derived
    /// value may be shown, but never dressed as a measured one.
    var dateIsInferred: Bool { completedAt == nil }
}

enum ActivityKind: String, Codable, Hashable, Sendable {
    case improvement
    case sitterCare
    case friendQuestion
    case assignment
    case milestone
    case friendship

    var icon: String {
        switch self {
        case .improvement: "chart.line.uptrend.xyaxis"
        case .sitterCare: "person.2.fill"
        case .friendQuestion: "questionmark.bubble.fill"
        case .assignment: "calendar.badge.checkmark"
        case .milestone: "sparkles"
        case .friendship: "person.badge.plus"
        }
    }
}

struct ActivityEvent: Identifiable, Hashable, Codable, Sendable {
    /// How both ends of the app name the account reading the feed. The server
    /// resolves actors viewer-relatively and sends the same literal back, so a
    /// row is "mine" if and only if it carries this name.
    static let selfActorName = "You"

    let id: UUID
    var kind: ActivityKind
    var actorName: String
    var actorInitials: String
    var message: String
    var plantID: UUID?
    var timestamp: Date

    /// Whether this is a record of the reader's own action rather than news.
    ///
    /// The distinction is what makes the Updates badge mean anything: watering
    /// your own plant is not a notification, and a dot that lights for it lights
    /// permanently. Only somebody else's action is worth a dot.
    var isSelfAuthored: Bool { actorName == Self.selfActorName }
}

enum SittingStatus: String, Codable, Hashable, Sendable {
    case invited
    case upcoming
    case active
    case completed
    case declined
    case revoked

    var title: String { rawValue.capitalized }
}

/// Turns the two dates a sitting composer collects into the window they are
/// meant to describe.
///
/// Both composers seed their pickers from `.now` plus an offset and render them
/// with `displayedComponents: .date`, so the dates carry a time of day the user
/// can neither see nor change — whatever o'clock it happened to be when the
/// screen opened. Stored raw, that time became the real boundary: an owner who
/// arranged "3–10 August" at 15:00 locked their sitter out at 15:00 on the 10th
/// and left them unable to start until 15:00 on the 3rd, missing the last
/// evening's watering and the first morning's. A sitting window covers whole
/// days, so it is stored as whole days.
enum SittingWindow {
    /// The first instant of `start`'s day, and the last of `end`'s.
    static func normalized(
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let first = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: max(start, end))
        let last = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: lastDay) ?? lastDay
        return (first, max(first, last))
    }

    /// Reads the days as they appeared in the date picker, then materialises
    /// those whole-day boundaries in the Grove's timezone. This matters most
    /// once the owner is already abroad: `Calendar.current` follows the phone,
    /// while the plants and sitter remain at home.
    static func normalized(
        start: Date,
        end: Date,
        timeZone: TimeZone,
        displayCalendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let units: Set<Calendar.Component> = [.year, .month, .day]
        let startComponents = displayCalendar.dateComponents(units, from: start)
        let endComponents = displayCalendar.dateComponents(units, from: end)
        var homeCalendar = Calendar(identifier: .gregorian)
        homeCalendar.timeZone = timeZone

        guard let first = homeCalendar.date(from: startComponents) else {
            return normalized(start: start, end: end, calendar: displayCalendar)
        }
        let candidateLastDay = homeCalendar.date(from: endComponents) ?? first
        let lastDay = max(first, candidateLastDay)
        let last = homeCalendar.date(
            byAdding: DateComponents(day: 1, second: -1),
            to: lastDay
        ) ?? lastDay
        return (first, max(first, last))
    }
}

struct SittingAssignment: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var sitterName: String
    var sitterInitials: String
    var startDate: Date
    var endDate: Date
    var plantIDs: [UUID]
    /// Where the *invitation* got to. The trip's own progress is read from the
    /// dates — see `currentStatus`.
    var status: SittingStatus
    var completedTasks: Int
    var totalTasks: Int
    /// Whether the sitter may complete check-ins as well as log care. Chosen by
    /// the owner when the assignment is created.
    var canCheckIn: Bool = true
    /// Whether the sitter may record care actions for the selected plants.
    var canLogCare: Bool = true
    /// Plant-care handover only. Sensitive access instructions belong in their
    /// separately permissioned store and are never put on a plant profile.
    var ownerNotes: String? = nil
    /// The Grove timezone in which the owner chose these calendar days.
    var timeZoneIdentifier: String? = nil
    /// The owner is the counterparty when this account is doing the sitting.
    /// Kept separate from `sitterName` so owner-facing cards remain compatible
    /// with snapshots written before incoming handovers shipped.
    var ownerName: String? = nil
    /// Viewer-relative direction supplied by bootstrap. `false` is the safe
    /// default for older snapshots, which only ever contained owner rows.
    var isIncoming: Bool = false

    /// The id of the activity entry that announces this assignment.
    ///
    /// Derived from the assignment rather than freshly minted so the client and
    /// the server name the same entry without a round trip: the client writes it
    /// locally, sends it with the mutation, and the server's mirrored row lands
    /// on the same id. A bootstrap then dedupes the two instead of showing the
    /// invitation twice.
    var activityEventID: UUID { id }

    /// The status to show today.
    ///
    /// `status` is only ever written once, when the invitation is sent, and
    /// nothing in the app advances it afterwards — so an assignment the user
    /// arranged for last spring still read "Invited", still counted as live,
    /// and still contradicted the promise on the plant-sitting screen that
    /// "access ends by itself when the trip does". The dates already know all
    /// of that, so they decide it.
    ///
    /// An invitation that was never accepted cannot become `active`: the
    /// plants were never handed over. It simply expires with the trip.
    func currentStatus(now: Date = .now) -> SittingStatus {
        if status == .declined || status == .revoked { return status }
        if status == .completed || endDate < now { return .completed }
        if status == .invited { return .invited }
        return startDate <= now ? .active : .upcoming
    }

    /// True once the trip is over, however far the invitation itself got.
    func hasEnded(now: Date = .now) -> Bool {
        [.completed, .declined, .revoked].contains(currentStatus(now: now))
    }

    private enum CodingKeys: String, CodingKey {
        case id, sitterName, sitterInitials, startDate, endDate, plantIDs, status
        case completedTasks, totalTasks, canCheckIn, canLogCare, ownerNotes, timeZoneIdentifier
        case ownerName, isIncoming
    }

    init(
        id: UUID,
        sitterName: String,
        sitterInitials: String,
        startDate: Date,
        endDate: Date,
        plantIDs: [UUID],
        status: SittingStatus,
        completedTasks: Int,
        totalTasks: Int,
        canCheckIn: Bool = true,
        canLogCare: Bool = true,
        ownerNotes: String? = nil,
        timeZoneIdentifier: String? = nil,
        ownerName: String? = nil,
        isIncoming: Bool = false
    ) {
        self.id = id
        self.sitterName = sitterName
        self.sitterInitials = sitterInitials
        self.startDate = startDate
        self.endDate = endDate
        self.plantIDs = plantIDs
        self.status = status
        self.completedTasks = completedTasks
        self.totalTasks = totalTasks
        self.canCheckIn = canCheckIn
        self.canLogCare = canLogCare
        self.ownerNotes = ownerNotes
        self.timeZoneIdentifier = timeZoneIdentifier
        self.ownerName = ownerName
        self.isIncoming = isIncoming
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sitterName = try container.decode(String.self, forKey: .sitterName)
        sitterInitials = try container.decode(String.self, forKey: .sitterInitials)
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decode(Date.self, forKey: .endDate)
        plantIDs = try container.decode([UUID].self, forKey: .plantIDs)
        status = try container.decode(SittingStatus.self, forKey: .status)
        completedTasks = try container.decode(Int.self, forKey: .completedTasks)
        totalTasks = try container.decode(Int.self, forKey: .totalTasks)
        // Snapshots written before the permission existed granted it, which is
        // what those assignments were created under.
        canCheckIn = try container.decodeIfPresent(Bool.self, forKey: .canCheckIn) ?? true
        canLogCare = try container.decodeIfPresent(Bool.self, forKey: .canLogCare) ?? true
        ownerNotes = try container.decodeIfPresent(String.self, forKey: .ownerNotes)
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        ownerName = try container.decodeIfPresent(String.self, forKey: .ownerName)
        isIncoming = try container.decodeIfPresent(Bool.self, forKey: .isIncoming) ?? false
    }
}

/// A handover that travels as a link rather than as an invitation to an
/// account.
///
/// The existing `SittingAssignment` hands plants to someone who is already a
/// Grove friend, which is the wrong shape for the thing people actually do:
/// they ask a neighbour, in person, the week before they fly. That person will
/// not install an app to water a fern. So an invite resolves to a plain web
/// page — the plants, what they need, and nothing else about the grove — and
/// stops resolving when the trip ends.
struct SittingInvite: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    /// What the owner calls whoever they handed it to. Theirs alone: it is a
    /// label for the list, never shown on the page the sitter opens.
    var sitterLabel: String
    var startDate: Date
    var endDate: Date
    var plantIDs: [UUID]
    /// Whether the sitter can tick tasks off, or only read them.
    var canLogCare: Bool
    /// The plant-care handover shown on the tokenised sitter page. It must not
    /// contain door codes or other sensitive access information.
    var ownerNotes: String? = nil
    /// IANA timezone for the Grove whose calendar days define this window.
    var timeZoneIdentifier: String? = nil
    /// The shareable link. Held in the owner's device Keychain so it can be sent
    /// again to a second phone or a lost message; the server keeps only a hash
    /// of the token inside it, and so cannot re-issue this.
    var shareURL: URL?
    var createdAt: Date
    var revokedAt: Date?
    /// Set while a durable revoke is waiting for server confirmation. Access
    /// may still work in this state, so it must never masquerade as revoked.
    var revocationRequestedAt: Date? = nil
    /// Server acknowledgement that the care sheet was opened at least once.
    var lastOpenedAt: Date? = nil
    var openCount: Int? = nil
    /// Care actions completed through this bearer during the handover.
    var completedCareCount: Int? = nil
    /// `true` when the server confirms this row exists even though this device
    /// can never recover its bearer URL. Optional keeps older local snapshots
    /// compatible; a stored URL is proof for those rows.
    var wasMinted: Bool? = nil

    var isRevoked: Bool { revokedAt != nil }
    var isMinted: Bool { wasMinted == true || shareURL != nil }
    var isRevocationPending: Bool { revocationRequestedAt != nil && !isRevoked }
    var hasBeenOpened: Bool { lastOpenedAt != nil || (openCount ?? 0) > 0 }
    var effectiveTimeZone: TimeZone {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    /// Whether this link's care sheet is currently available — it exists, it
    /// has not been pulled, and its sitting window is active.
    func isLive(on date: Date = .now) -> Bool {
        isMinted && !isRevoked && date >= startDate && date <= endDate
    }

    /// A minted URL is only an invitation. It becomes actual sitting cover
    /// once the server confirms that somebody opened the care sheet.
    func providesCover(on date: Date = .now) -> Bool {
        isLive(on: date) && hasBeenOpened && !isRevocationPending
    }

    /// Whether the owner should still see this row.
    ///
    /// Broader than `isLive` on purpose: a local attempt whose response dropped
    /// still needs to remain visible because revocation goes by invite id, and
    /// a server-confirmed row is visible before its start date too.
    func isOutstanding(on date: Date = .now) -> Bool {
        !isRevoked && date < endDate
    }
}

struct FriendPlant: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var nickname: String
    var species: String
    var symbol: String
    var palette: PlantPalette
    var healthBand: HealthBand
}

struct PlantFriend: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var username: String
    var initials: String
    var sharedPlantCount: Int
    var lastActiveAt: Date
    var sharedPlants: [FriendPlant] = []

    private enum CodingKeys: String, CodingKey {
        case id, name, username, initials, sharedPlantCount, lastActiveAt, sharedPlants
    }

    init(
        id: String,
        name: String,
        username: String,
        initials: String,
        sharedPlantCount: Int,
        lastActiveAt: Date,
        sharedPlants: [FriendPlant] = []
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.initials = initials
        self.sharedPlantCount = sharedPlantCount
        self.lastActiveAt = lastActiveAt
        self.sharedPlants = sharedPlants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        username = try container.decode(String.self, forKey: .username)
        initials = try container.decode(String.self, forKey: .initials)
        sharedPlantCount = try container.decode(Int.self, forKey: .sharedPlantCount)
        lastActiveAt = try container.decode(Date.self, forKey: .lastActiveAt)
        sharedPlants = try container.decodeIfPresent([FriendPlant].self, forKey: .sharedPlants) ?? []
    }
}

enum FriendInvitationDirection: String, Codable, Hashable, Sendable {
    case incoming
    case outgoing
}

struct FriendInvitation: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var accountID: String?
    var name: String
    var username: String
    var initials: String
    var direction: FriendInvitationDirection
    var createdAt: Date
}

struct UserProfile: Hashable, Codable, Sendable {
    var name: String
    var username: String
    var initials: String
    var friendCount: Int
    /// A deliberately chosen Grove illustration. `nil` keeps the stable,
    /// account-seeded default used by profiles created before avatar editing.
    var avatarAssetName: String? = nil
    /// The protected on-device copy of a photo chosen for this profile.
    /// Optional keeps older snapshots and the current server contract
    /// backwards-compatible.
    var avatarPhotoURL: URL? = nil
    var regionCode: String? = nil
    var usesMetricSystem: Bool? = nil
    var isPrivate: Bool? = nil
    var location: GroveLocation? = nil
    /// The personalization built during onboarding. Optional because accounts
    /// created before the plan was persisted have none, and because a user can
    /// clear it. See `GrovePlan`.
    var plan: GrovePlan? = nil
}

/// The single, Grove-wide location a user pins for their overall garden.
/// This is not stored per-plant — it describes where the Grove lives.
struct GroveLocation: Hashable, Codable, Sendable {
    var latitude: Double
    var longitude: Double
    /// Human-readable place name, e.g. "Seattle, United States".
    var label: String
    /// ISO 3166-1 alpha-2 code for the country the pin sits in, e.g. "GB".
    ///
    /// Both this and `timeZoneIdentifier` are what `TravelWatcher` compares the
    /// phone against to notice the owner has gone away. Optional because every
    /// location saved before this existed has neither — see
    /// `GroveLocation.backfilled(from:)` for how those are repaired.
    var countryCode: String? = nil
    /// IANA identifier of the time zone the pin sits in, e.g. "Europe/London".
    var timeZoneIdentifier: String? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The part of `label` worth putting in a sentence — "Bristol" out of
    /// "Bristol, United Kingdom". Falls back to the whole label.
    var shortLabel: String {
        let head = label.split(separator: ",").first.map(String.init) ?? label
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? label : trimmed
    }

    init(
        latitude: Double,
        longitude: Double,
        label: String,
        countryCode: String? = nil,
        timeZoneIdentifier: String? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.label = label
        self.countryCode = countryCode?.uppercased()
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    init(
        coordinate: CLLocationCoordinate2D,
        label: String,
        countryCode: String? = nil,
        timeZoneIdentifier: String? = nil
    ) {
        self.init(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            label: label,
            countryCode: countryCode,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }
}

enum ScanMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case identify
    case add
    case diagnose

    var id: Self { self }

    var title: String {
        switch self {
        case .identify: "Identify"
        case .add: "Add to my grove"
        case .diagnose: "Diagnose"
        }
    }

    var subtitle: String {
        switch self {
        case .identify: "Name any plant from a photo"
        case .add: "Name it, read its health, start its record"
        case .diagnose: "Work out what it is and what to do"
        }
    }

    var icon: String {
        switch self {
        case .identify: "viewfinder"
        case .add: "plus.circle.fill"
        case .diagnose: "stethoscope"
        }
    }
}

struct PlantIdentificationResult: Codable, Hashable, Sendable {
    var commonName: String
    var scientificName: String
    var confidence: Int
    /// The runner-up names, as the sanitizer derives them from `candidates`.
    ///
    /// Nothing in the app reads this and nothing should: `candidates` carries
    /// the same list with the confidence, the traits and the taxon id that make
    /// a row adoptable, and a bare name cannot become a plant. It is decoded
    /// rather than dropped because it is part of the gateway contract and shows
    /// up in a logged response, which is where it earns its keep.
    var alternatives: [String]
    var distinguishingTraits: [String]
    var candidates: [SpeciesCandidate]? = nil
    var isUnknown: Bool? = nil
    var requiresConfirmation: Bool? = nil
    var regionCode: String? = nil
    /// The sanitizer's aggregate of every photo's quality complaint, which it
    /// reads back to decide `requiresConfirmation` and whether a result is
    /// provisional. The app's own live path is per-image
    /// (`PlantAnalysisImage.qualityWarnings`), set by `ScanImageQualityAnalyzer`
    /// before the request goes out, so this side is server-owned and read only
    /// there.
    var imageQualityWarnings: [String]? = nil
    /// Filled when a user chooses a result from the taxonomic catalogue.
    var canonicalTaxonID: String? = nil
    var identityConfirmation: PlantIdentityConfirmation? = nil
}

struct SpeciesCandidate: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var commonName: String
    var scientificName: String
    var confidence: Int
    var distinguishingTraits: [String]
    var regionalFit: String?
    /// The candidate row's `id` is also used for local/model candidates, so the
    /// canonical identifier is explicit rather than inferred from any slug.
    var canonicalTaxonID: String? = nil
}

struct PlantConditionCandidate: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var confidence: Int
    var explanation: String
    var evidence: [String]
    var alternativeExplanation: String?
}

struct DiagnosisQuestion: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var prompt: String
    var options: [DiagnosisAnswerOption]
    var reason: String?
}

struct DiagnosisAnswerOption: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
}

/// One clarifying question the owner answered, as it goes to the analysis
/// gateway and as it is shown back once the read has been updated.
struct DiagnosisObservation: Codable, Hashable, Sendable {
    var questionID: String
    var question: String
    var answer: String

    /// The gateway's answer value. Earlier scans sent the option id, which the
    /// model had invented on a previous call and could not remember, so every
    /// "refine" was a fresh scan that asked three fresh questions. The answer
    /// leads so a long prompt can never truncate the part that carries the
    /// information.
    var gatewayValue: String { "\(answer) · asked: \(question)" }
}

enum DiagnosisActionability: String, Codable, Hashable, Sendable {
    /// Evidence is strong enough to update the plant's current health and plan.
    case actionable
    /// Useful observations exist, but identity, quality, or the differential
    /// still needs confirmation before it changes ongoing care.
    case provisional
    /// The photos cannot support a condition assessment; only retake/checking
    /// guidance is safe to surface.
    case insufficientEvidence
}

struct PlantConditionResult: Codable, Hashable, Sendable {
    var healthScore: Int
    var healthBand: HealthBand
    var confidence: Int
    var summary: String
    var positiveSigns: [String]
    var concerns: [String]
    var possibleCauses: [String]
    var nextActions: [String]
    /// The next actions that are checks, each with the results it could turn
    /// up. Nil from gateways older than the checks contract.
    var checks: [PlantCheck]? = nil
    var possibleConditions: [PlantConditionCandidate]? = nil
    var questions: [DiagnosisQuestion]? = nil
    var actionsToAvoid: [String]? = nil
    var urgentFlags: [String]? = nil
    var followUpDays: Int? = nil
    /// Server-derived policy state. Optional keeps saved pre-policy results
    /// decodable and lets local fixtures retain their historical behaviour.
    var actionability: DiagnosisActionability? = nil
    /// False means the photos could not support a health read at all. This is
    /// separate from a genuinely urgent low score.
    var assessmentAvailable: Bool? = nil
    /// Structured photo-grounded readings for foliage, posture, and growth.
    /// User-reported soil and deterministic light/care readings are added by the
    /// app when it assembles the complete six-indicator snapshot.
    var indicatorFindings: [PlantVisualIndicatorFinding]? = nil
}

enum PlantEvidenceSubjectKind: String, Codable, Hashable, Sendable {
    case plant
    case nonPlant
    case multiplePlants
    case uncertain
}

enum PlantEvidenceRetakeStage: String, Codable, Hashable, Sendable {
    case wholePlant
    case leaf
    case stem
    case symptom
    case none
}

struct PlantEvidenceQuality: Codable, Hashable, Sendable {
    var subjectKind: PlantEvidenceSubjectKind
    var subjectCount: Int
    var sameSubject: Bool
    var usableForIdentification: Bool
    var usableForCondition: Bool
    /// Evidence quality, not plant health, 0-100. The sanitizer gates a
    /// decisive identification on this (>= 65) before the result reaches the
    /// phone, so the client deliberately does not re-apply a threshold of its
    /// own: two gates on one number is how a scan the server was happy with
    /// starts asking for a retake.
    var qualityScore: Int
    /// The single view that would help most, and why, both in the model's own
    /// words. `ScanEvidenceRetryGuidance` shows them.
    var retakeStage: PlantEvidenceRetakeStage
    var retakeReason: String
}

struct PlantAnalysisResult: Codable, Hashable, Sendable {
    var identification: PlantIdentificationResult
    var condition: PlantConditionResult
    var evidenceQuality: PlantEvidenceQuality? = nil
    /// Optional so results saved before the scan reported them still decode.
    var growingConditions: PlantGrowingConditions? = nil
    var providerName: String
    var limitations: [String]
    /// Server-stamped analysis/sanitizer contract, never model-authored.
    var analysisVersion: String? = nil
}

/// The physical facts about how a plant is potted, read from the scan photos.
///
/// These exist for one purpose: how fast this particular pot dries out. That
/// number is what separates "check the soil" from "water it", and it varies by
/// an order of magnitude between a 10cm terracotta pot on a sill and a 35cm
/// glazed cachepot in a hallway — a difference no species-level watering
/// interval can express.
///
/// Every field can be `unknown`, and unknown is not a failure: it widens the
/// uncertainty band on the plant page rather than being papered over with a
/// guess. The scan reads them because a photograph can — the alternative is
/// asking an owner what their substrate is, which is a question most people
/// cannot answer and nobody wants to be asked.
struct PlantGrowingConditions: Codable, Hashable, Sendable {
    enum PotMaterial: String, Codable, Hashable, Sendable {
        case terracotta, plastic, glazed, metal, fabric, concrete, unpotted, unknown
    }

    /// Widest diameter: small under 12cm, medium 12–20, large 20–30, xlarge over 30.
    enum PotSize: String, Codable, Hashable, Sendable {
        case small, medium, large, xlarge, unknown
    }

    enum Drainage: String, Codable, Hashable, Sendable {
        /// Holes, a saucer, or a pot standing free on a surface.
        case drains
        /// The growing pot stands inside a cover, basket or tin: water cannot leave.
        case cachepot
        case noHoles
        case unknown
    }

    enum Substrate: String, Codable, Hashable, Sendable {
        case gritty, standard, dense, bark, moss, semiHydro, unknown
    }

    /// How the top of the substrate read in the photo. A weak hint, never a
    /// reading: the surface dries hours before the root zone does, which is
    /// exactly the mistake that makes people water a plant that is still wet
    /// underneath.
    enum SoilSurface: String, Codable, Hashable, Sendable {
        case dry, damp, wet
        /// Covered by pebbles, bark, moss or another top dressing.
        case obscured
        case unknown
    }

    enum PotFit: String, Codable, Hashable, Sendable {
        case snug, balanced, oversized, unknown
    }

    enum SurfaceSign: String, Codable, Hashable, Sendable {
        case saltCrust, algae, mould, fungusGnats, moss
        case hydrophobic, standingWater, compacted, rootsAtSurface, topDressed
    }

    var potMaterial: PotMaterial = .unknown
    var potSize: PotSize = .unknown
    var drainage: Drainage = .unknown
    var substrate: Substrate = .unknown
    var soilSurface: SoilSurface = .unknown
    var surfaceSigns: [SurfaceSign] = []
    var potFit: PotFit = .unknown
    /// How much of the pot and soil the scan could actually see, 0–100.
    var confidence: Int = 0
    /// When these were read. Absent on the wire — the store stamps it on the way
    /// in, because `soilSurface` ages out in days while the rest holds for months.
    var capturedAt: Date? = nil

    /// How many of the four dry-down inputs the scan could not resolve. Drives
    /// how wide the plant page draws its uncertainty band.
    var unknownDryDownInputs: Int {
        [potMaterial == .unknown, potSize == .unknown, substrate == .unknown, drainage == .unknown]
            .filter { $0 }
            .count
    }

    /// True when the scan resolved nothing worth retaining. Soil-surface and
    /// pot-fit observations do not set the dry-down rate by themselves, but
    /// they still support the baseline indicators and must survive adoption.
    var isEmpty: Bool {
        unknownDryDownInputs == 4
            && soilSurface == .unknown
            && potFit == .unknown
            && surfaceSigns.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case potMaterial, potSize, drainage, substrate
        case soilSurface, surfaceSigns, potFit, confidence, capturedAt
    }

    /// A value off the vocabulary decodes as `unknown` rather than throwing. The
    /// gateway already clamps every field, so this only has to survive an older
    /// record or a provider that invents a term — and losing a whole plant's
    /// analysis over one unrecognised word would be a poor trade.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func word<T: RawRepresentable>(_ key: CodingKeys) -> T? where T.RawValue == String {
            guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
            return T(rawValue: raw)
        }
        potMaterial = word(.potMaterial) ?? .unknown
        potSize = word(.potSize) ?? .unknown
        drainage = word(.drainage) ?? .unknown
        substrate = word(.substrate) ?? .unknown
        soilSurface = word(.soilSurface) ?? .unknown
        potFit = word(.potFit) ?? .unknown
        let rawSigns = (try? container.decodeIfPresent([String].self, forKey: .surfaceSigns)) ?? []
        surfaceSigns = rawSigns.compactMap(SurfaceSign.init(rawValue:))
        confidence = (try? container.decodeIfPresent(Int.self, forKey: .confidence)) ?? 0
        capturedAt = (try? container.decodeIfPresent(Date.self, forKey: .capturedAt)) ?? nil
    }

    init(
        potMaterial: PotMaterial = .unknown,
        potSize: PotSize = .unknown,
        drainage: Drainage = .unknown,
        substrate: Substrate = .unknown,
        soilSurface: SoilSurface = .unknown,
        surfaceSigns: [SurfaceSign] = [],
        potFit: PotFit = .unknown,
        confidence: Int = 0,
        capturedAt: Date? = nil
    ) {
        self.potMaterial = potMaterial
        self.potSize = potSize
        self.drainage = drainage
        self.substrate = substrate
        self.soilSurface = soilSurface
        self.surfaceSigns = surfaceSigns
        self.potFit = potFit
        self.confidence = confidence
        self.capturedAt = capturedAt
    }
}

enum ScanCaptureStage: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case wholePlant
    case leaf
    case stem
    case symptom
    /// A prior photo supplied only for longitudinal comparison. It is never a
    /// camera step and must not be interpreted as today's condition.
    case reference

    var id: Self { self }

    var title: String {
        switch self {
        case .wholePlant: "Whole plant"
        case .leaf: "Leaf detail"
        case .stem: "Stem and soil line"
        case .symptom: "Symptom close-up"
        case .reference: "Previous whole-plant photo"
        }
    }

    var instruction: String {
        switch self {
        case .wholePlant: "Whole plant in frame, in even light. Include the pot down to its base."
        case .leaf: "The front of one typical leaf. Get close instead of zooming."
        case .stem: "The stems, the soil, and where the two meet."
        case .symptom: "Fill the frame with the problem area and keep it sharp."
        case .reference: "An earlier whole-plant photo used only for comparison."
        }
    }

    var icon: String {
        switch self {
        case .wholePlant: "camera.viewfinder"
        case .leaf: "leaf"
        case .stem: "point.bottomleft.forward.to.point.topright.scurvepath"
        case .symptom: "scope"
        case .reference: "clock.arrow.circlepath"
        }
    }
}

struct PlantAnalysisRequest: Codable, Hashable, Sendable {
    var clientRequestID: UUID? = nil
    var mode: ScanMode
    var images: [PlantAnalysisImage]
    var regionCode: String?
    var existingPlant: PlantAnalysisPlantContext?
    var answers: [String: String]
}

struct PlantAnalysisImage: Codable, Hashable, Sendable {
    var stage: ScanCaptureStage
    var mimeType: String
    var base64Data: String
    /// Deterministic on-device quality signals. They are advisory evidence for
    /// confidence policy and never replace the provider's semantic subject gate.
    var qualityWarnings: [String]? = nil
    var localMediaID: UUID? = nil
    var localFileURL: URL? = nil
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil

    private enum CodingKeys: String, CodingKey {
        case stage
        case mimeType
        case base64Data
        case qualityWarnings
    }
}

struct PlantAnalysisPlantContext: Codable, Hashable, Sendable {
    var id: UUID
    var commonName: String
    var scientificName: String
    var location: String
    var recentSummary: String
}
