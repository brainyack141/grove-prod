import Foundation
import XCTest
@testable import Grove

/// Covers the pipeline gaps the scan audit found: evidence that was collected
/// and then discarded before it could reach a screen, a person or the model.
///
/// Each test names the gap it closes rather than the method it calls, because
/// every one of these regressions looked correct at the call site — the data
/// was computed, the type was right, and nothing read it.
@MainActor
final class ScanEvidencePipelineRegressionTests: XCTestCase {

    // MARK: - Pot facts reach a live screen

    /// `reasons` shows three lines and the dated evidence always takes one of
    /// them, so a pot with two problems could only ever name one. The plant
    /// page reads `potReasons`, which is uncapped.
    func testEveryAlarmingPotFactSurvivesTheGaugesThreeLineCap() {
        let read = moistureRead(
            conditions: conditions(
                drainage: .cachepot,
                surfaceSigns: [.fungusGnats, .standingWater],
                potFit: .oversized
            )
        )

        let ids = read.potReasons.map(\.id)
        XCTAssertTrue(ids.contains("drainage"), "\(ids)")
        XCTAssertTrue(ids.contains("sign-fungusGnats"), "\(ids)")
        XCTAssertTrue(ids.contains("sign-standingWater"), "\(ids)")
        XCTAssertTrue(ids.contains("fit"), "\(ids)")
        XCTAssertEqual(read.reasons.count, 3, "The gauge itself still shows three.")
    }

    /// The pot facts were rendered by a card that the plant-page rebuild left
    /// orphaned. They now travel on the moisture indicator itself, so the tile
    /// that reports the soil can also say what the scan saw of the pot.
    func testMoistureIndicatorCarriesThePotFactsToThePlantPage() throws {
        var plant = Self.plant()
        plant.growingConditions = conditions(drainage: .noHoles)

        let indicators = PlantHealthIndicators.make(
            for: plant,
            observations: [],
            diagnosis: nil,
            tasks: []
        )
        let moisture = try XCTUnwrap(indicators.first { $0.kind == .moisture })

        XCTAssertTrue(
            moisture.potFacts.contains { $0.text == "No drainage holes" },
            "\(moisture.potFacts.map(\.text))"
        )
    }

    /// A pot nobody scanned is itself the reason the tile is empty, so the
    /// fact list is never silently absent.
    func testAnUnscannedPotStillExplainsItselfOnTheTile() throws {
        let indicators = PlantHealthIndicators.make(
            for: Self.plant(),
            observations: [],
            diagnosis: nil,
            tasks: []
        )
        let moisture = try XCTUnwrap(indicators.first { $0.kind == .moisture })

        XCTAssertEqual(moisture.potFacts.map(\.text), ["Pot never scanned"])
    }

    // MARK: - Surface signs reach the dry-down estimate

    /// Standing water is drainage failing in front of the camera. It used to
    /// change the wording of a card nobody could see and nothing else.
    func testStandingWaterSlowsTheDryDownEstimate() {
        let plain = dryDown(surfaceSigns: [])
        let pooled = dryDown(surfaceSigns: [.standingWater])

        XCTAssertGreaterThan(pooled.days, plain.days)
    }

    /// A hydrophobic rootball sheds water down the sides instead of absorbing
    /// it, so the pot is drier than the last watering implies, not wetter.
    func testHydrophobicSoilSpeedsTheDryDownEstimate() {
        XCTAssertLessThan(dryDown(surfaceSigns: [.hydrophobic]).days, dryDown(surfaceSigns: []).days)
    }

    /// Gnats, algae and mould are three names for one condition. A pot with all
    /// three is the same wet pot observed three ways, not eight times slower.
    func testCorrelatedWetSignsDoNotCompound() {
        let one = dryDown(surfaceSigns: [.fungusGnats])
        let three = dryDown(surfaceSigns: [.fungusGnats, .algae, .mould])

        XCTAssertEqual(one.days, three.days, accuracy: 0.001)
    }

    /// Salt is left behind by water that evaporated. It dates the watering
    /// history and says nothing about the rate.
    func testANeutralSignLeavesTheEstimateAlone() {
        XCTAssertEqual(
            dryDown(surfaceSigns: [.saltCrust]).days,
            dryDown(surfaceSigns: []).days,
            accuracy: 0.001
        )
    }

    // MARK: - Check-ins keep what they re-read

    /// A check-in photographs the same pot again, and pots change. The
    /// conditions were read on every check-in and dropped on every one of them,
    /// so a cover added in August stayed invisible until the next full scan.
    func testACheckInStoresThePotItJustRead() throws {
        let store = GroveStore(plants: [Self.plant()], persistenceEnabled: false)
        let plantID = try XCTUnwrap(store.plants.first?.id)
        XCTAssertNil(store.plants[0].growingConditions)

        _ = store.applyCheckIn(
            plantID: plantID,
            score: 74,
            band: .healthy,
            note: "Steady.",
            growingConditions: conditions(drainage: .cachepot, potFit: .oversized)
        )

        let saved = try XCTUnwrap(store.plants.first?.growingConditions)
        XCTAssertEqual(saved.drainage, .cachepot)
        XCTAssertEqual(saved.potFit, .oversized)
        XCTAssertNotNil(saved.capturedAt, "The store stamps the read date on the way in.")
    }

    /// An analysis that saw nothing must not erase a pot an earlier scan read.
    func testACheckInThatSawNothingKeepsTheEstablishedRecord() throws {
        var plant = Self.plant()
        plant.growingConditions = conditions(drainage: .cachepot)
        let store = GroveStore(plants: [plant], persistenceEnabled: false)

        _ = store.applyCheckIn(
            plantID: plant.id,
            score: 74,
            band: .healthy,
            note: "Steady.",
            growingConditions: nil
        )

        XCTAssertEqual(store.plants.first?.growingConditions?.drainage, .cachepot)
    }

    // MARK: - Canonical taxon ids

    /// GBIF's search is fuzzy and will answer a query with a sibling species.
    /// Accepting that would attach one plant's toxicity record to another, so
    /// only a name that comes back as itself resolves.
    func testOnlyAnExactNameMatchResolvesToATaxonID() async {
        let client = StubSpeciesSearchClient(results: [
            "Ficus benghalensis": [
                Self.candidate(scientificName: "Ficus benjamina", taxonID: "gbif:5361879")
            ]
        ])

        let resolved = await PlantTaxonResolver.resolve(
            names: ["Ficus benghalensis"],
            regionCode: nil,
            using: client
        )

        XCTAssertTrue(resolved.isEmpty, "\(resolved)")
    }

    func testAnExactNameMatchResolves() async {
        let client = StubSpeciesSearchClient(results: [
            "Monstera deliciosa": [
                Self.candidate(scientificName: "Monstera deliciosa", taxonID: "gbif:2868241"),
                Self.candidate(scientificName: "Monstera adansonii", taxonID: "gbif:2868250")
            ]
        ])

        let resolved = await PlantTaxonResolver.resolve(
            names: ["Monstera deliciosa"],
            regionCode: nil,
            using: client
        )

        XCTAssertEqual(resolved["Monstera deliciosa"], "gbif:2868241")
    }

    /// Two taxa of the same name is an ambiguity, not a match.
    func testADuplicateNameIsLeftUnresolved() async {
        let client = StubSpeciesSearchClient(results: [
            "Monstera deliciosa": [
                Self.candidate(scientificName: "Monstera deliciosa", taxonID: "gbif:2868241"),
                Self.candidate(scientificName: "Monstera deliciosa", taxonID: "gbif:9999999")
            ]
        ])

        let resolved = await PlantTaxonResolver.resolve(
            names: ["Monstera deliciosa"],
            regionCode: nil,
            using: client
        )

        XCTAssertTrue(resolved.isEmpty, "\(resolved)")
    }

    /// A genus id would match the safety record of a sibling species, and the
    /// scan's own placeholder is not a name at all.
    func testGenusOnlyAndPlaceholderNamesAreNeverLookedUp() {
        XCTAssertFalse(PlantTaxonResolver.isResolvable("Monstera"))
        XCTAssertFalse(PlantTaxonResolver.isResolvable("Species unconfirmed"))
        XCTAssertFalse(PlantTaxonResolver.isResolvable("   "))
        XCTAssertTrue(PlantTaxonResolver.isResolvable("Monstera deliciosa"))
    }

    /// The backfill fills the id and changes nothing a person can see. A pass
    /// that renamed a plant would be re-identifying it behind the owner's back.
    func testTheBackfillFillsTheIDAndLeavesTheIdentityAlone() throws {
        var plant = Self.plant()
        plant.identityConfirmation = .photoMatch
        let store = GroveStore(plants: [plant], persistenceEnabled: false)

        let applied = store.applyCanonicalTaxonIDs(["monstera  DELICIOSA": "gbif:2868241"])

        XCTAssertEqual(applied, 1)
        XCTAssertEqual(store.plants.first?.canonicalTaxonID, "gbif:2868241")
        XCTAssertEqual(store.plants.first?.species, plant.species)
        XCTAssertEqual(store.plants.first?.scientificName, plant.scientificName)
        XCTAssertEqual(store.plants.first?.identityConfirmation, .photoMatch)
    }

    /// An id the user confirmed by hand outranks anything a background pass
    /// works out, so a plant that already has one is never revisited.
    func testAPlantThatAlreadyHasATaxonIDIsLeftAlone() throws {
        var plant = Self.plant()
        plant.canonicalTaxonID = "gbif:1111111"
        let store = GroveStore(plants: [plant], persistenceEnabled: false)

        XCTAssertEqual(store.applyCanonicalTaxonIDs(["Monstera deliciosa": "gbif:2868241"]), 0)
        XCTAssertEqual(store.plants.first?.canonicalTaxonID, "gbif:1111111")
        XCTAssertTrue(store.scientificNamesAwaitingTaxonID.isEmpty)
    }

    func testTheBacklogListsEachUnresolvedNameOnce() {
        var first = Self.plant()
        var second = Self.plant()
        second.scientificName = "monstera deliciosa"
        var third = Self.plant()
        third.scientificName = "Ficus lyrata"
        first.canonicalTaxonID = nil

        let store = GroveStore(plants: [first, second, third], persistenceEnabled: false)

        XCTAssertEqual(store.scientificNamesAwaitingTaxonID.count, 2)
    }

    // MARK: - The model is told the truth about the gate

    /// The gateway tells the model "on-device quality gate found no warning"
    /// whenever an image carries no warnings. A check-in never ran the gate, so
    /// that sentence was being said about photos nothing had looked at.
    func testCheckInImagesCarryTheirMeasuredQualityWarnings() async throws {
        let client = RecordingAnalysisClient()
        let session = ScanSession(analysisClient: client)

        _ = try await session.analyseCheckIn(
            imageData: Data([0xFF, 0xD8, 0xFF]),
            qualityWarnings: [.lowLight, .softFocus],
            plant: Self.plant(),
            regionCode: "NZ",
            answers: [:]
        )

        let sent = try XCTUnwrap(client.request?.images.first { $0.stage == .wholePlant })
        XCTAssertEqual(sent.qualityWarnings, ["lowLight", "softFocus"])
    }

    /// A clean photo still has to be distinguishable from an ungated one, so
    /// "no warnings" is sent as absent rather than as an empty list.
    func testACleanCheckInPhotoSendsNoWarningsField() async throws {
        let client = RecordingAnalysisClient()
        let session = ScanSession(analysisClient: client)

        _ = try await session.analyseCheckIn(
            imageData: Data([0xFF, 0xD8, 0xFF]),
            plant: Self.plant(),
            regionCode: "NZ",
            answers: [:]
        )

        let sent = try XCTUnwrap(client.request?.images.first { $0.stage == .wholePlant })
        XCTAssertNil(sent.qualityWarnings)
    }

    // MARK: - Ari gets the pot

    /// The coach could see "soil wet" at three check-ins and had no way to
    /// reach the one fact that explains it.
    func testAriIsToldWhenTheGrowingPotStandsInACover() {
        var plant = Self.plant()
        plant.growingConditions = conditions(drainage: .cachepot)

        let text = BotanistContext.text(
            plant: plant,
            observations: [],
            tasks: [],
            profile: UserProfile(name: "Alex", username: "alex", initials: "A", friendCount: 0)
        )

        XCTAssertTrue(text.contains("water cannot leave the growing pot"), text)
    }

    /// Every number Grove hands the coach is an estimate, and the coach will
    /// quote it. The prompt has to say so in the same sentence.
    func testAriIsToldTheMoistureReadIsCalculatedRatherThanMeasured() {
        let text = BotanistContext.text(
            plant: Self.plant(),
            observations: [],
            tasks: [],
            profile: UserProfile(name: "Alex", username: "alex", initials: "A", friendCount: 0)
        )

        XCTAssertTrue(text.contains("calculated, never measured"), text)
        XCTAssertTrue(text.contains("Estimated dry-down"), text)
    }

    /// A plant nobody scanned must not let the coach offer a watering interval
    /// as though it were a read of this pot.
    func testAriIsToldWhenThePotWasNeverScanned() {
        let text = BotanistContext.text(
            plant: Self.plant(),
            observations: [],
            tasks: [],
            profile: UserProfile(name: "Alex", username: "alex", initials: "A", friendCount: 0)
        )

        XCTAssertTrue(text.contains("Pot and growing conditions: never scanned"), text)
    }

    // MARK: - The retake the model actually asked for

    /// The model is prompted to name the exact retake and the one view that
    /// would help most. Both were discarded for a sentence that fits every
    /// failure and describes none of them.
    func testAnUnreadableSetShowsTheModelsOwnReasonAndStage() throws {
        let guidance = try XCTUnwrap(
            ScanEvidenceRetryGuidance(
                evidence: Self.evidence(
                    usableForIdentification: false,
                    retakeStage: .leaf,
                    retakeReason: "The leaf close-up is out of focus, so the spotting can't be read."
                )
            )
        )

        XCTAssertEqual(guidance.kind, .unreadablePlant)
        XCTAssertEqual(guidance.retakeStage, .leaf)
        XCTAssertEqual(guidance.title, "Retake the leaf photo")
        XCTAssertEqual(guidance.detail, "The leaf close-up is out of focus, so the spotting can't be read.")
        XCTAssertEqual(guidance.actionTitle, "Retake the leaf photo")
    }

    /// The sanitizer substitutes a generic sentence when the model wrote
    /// nothing usable, and it says less than the stage instruction it replaces.
    func testTheSanitizersPlaceholderReasonFallsBackToTheStageInstruction() throws {
        let guidance = try XCTUnwrap(
            ScanEvidenceRetryGuidance(
                evidence: Self.evidence(
                    usableForIdentification: false,
                    retakeStage: .stem,
                    retakeReason: "The photos do not show one readable plant clearly enough."
                )
            )
        )

        XCTAssertEqual(guidance.detail, ScanCaptureStage.stem.instruction)
    }

    /// A bouquet is not fixed by retaking one stage, so the structural failures
    /// never offer one.
    func testStructuralFailuresNeverOfferAStageRetake() throws {
        let guidance = try XCTUnwrap(
            ScanEvidenceRetryGuidance(
                evidence: Self.evidence(subjectKind: .multiplePlants, subjectCount: 4, retakeStage: .leaf)
            )
        )

        XCTAssertNil(guidance.retakeStage)
        XCTAssertEqual(guidance.title, "Choose one plant")
    }

    // MARK: - Helpers

    private func conditions(
        drainage: PlantGrowingConditions.Drainage = .drains,
        surfaceSigns: [PlantGrowingConditions.SurfaceSign] = [],
        potFit: PlantGrowingConditions.PotFit = .balanced
    ) -> PlantGrowingConditions {
        PlantGrowingConditions(
            potMaterial: .plastic,
            potSize: .medium,
            drainage: drainage,
            substrate: .standard,
            soilSurface: .damp,
            surfaceSigns: surfaceSigns,
            potFit: potFit,
            confidence: 80,
            capturedAt: .now
        )
    }

    private func dryDown(surfaceSigns: [PlantGrowingConditions.SurfaceSign]) -> SoilDryDown {
        var plant = Self.plant()
        plant.growingConditions = conditions(surfaceSigns: surfaceSigns)
        return SoilDryDown(plant: plant)
    }

    private func moistureRead(conditions: PlantGrowingConditions) -> SoilMoistureRead {
        var plant = Self.plant()
        plant.growingConditions = conditions
        return SoilMoistureRead(plant: plant, observations: [], tasks: [])
    }

    private static func candidate(scientificName: String, taxonID: String) -> SpeciesCandidate {
        SpeciesCandidate(
            id: taxonID,
            commonName: scientificName,
            scientificName: scientificName,
            confidence: 100,
            distinguishingTraits: [],
            regionalFit: nil,
            canonicalTaxonID: taxonID
        )
    }

    private static func evidence(
        subjectKind: PlantEvidenceSubjectKind = .plant,
        subjectCount: Int = 1,
        usableForIdentification: Bool = true,
        retakeStage: PlantEvidenceRetakeStage = .none,
        retakeReason: String = ""
    ) -> PlantEvidenceQuality {
        PlantEvidenceQuality(
            subjectKind: subjectKind,
            subjectCount: subjectCount,
            sameSubject: true,
            usableForIdentification: usableForIdentification,
            usableForCondition: true,
            qualityScore: 40,
            retakeStage: retakeStage,
            retakeReason: retakeReason
        )
    }

    private static func plant() -> Plant {
        Plant(
            id: UUID(),
            nickname: "Pesto",
            species: "Swiss cheese plant",
            scientificName: "Monstera deliciosa",
            location: "Kitchen",
            healthScore: 78,
            healthBand: .healthy,
            trend: .stable,
            confidence: 86,
            nextCheckIn: Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now,
            symbol: "leaf.fill",
            palette: .fern,
            summary: "Settled.",
            positiveSigns: [],
            concerns: [],
            nextActions: []
        )
    }
}

@MainActor
private final class StubSpeciesSearchClient: PlantSpeciesSearchClient {
    private let results: [String: [SpeciesCandidate]]

    init(results: [String: [SpeciesCandidate]]) { self.results = results }

    func search(query: String, regionCode: String?) async throws -> [SpeciesCandidate] {
        results[query] ?? []
    }
}

@MainActor
private final class RecordingAnalysisClient: PlantAnalysisClient {
    private(set) var request: PlantAnalysisRequest?

    func analyse(request: PlantAnalysisRequest) async throws -> PlantAnalysisResult {
        self.request = request
        return PlantAnalysisResult(
            identification: PlantIdentificationResult(
                commonName: "Swiss cheese plant",
                scientificName: "Monstera deliciosa",
                confidence: 90,
                alternatives: [],
                distinguishingTraits: []
            ),
            condition: PlantConditionResult(
                healthScore: 80,
                healthBand: .healthy,
                confidence: 80,
                summary: "Steady.",
                positiveSigns: [],
                concerns: [],
                possibleCauses: [],
                nextActions: []
            ),
            providerName: "Test",
            limitations: []
        )
    }
}
