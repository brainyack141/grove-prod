import XCTest
@testable import Grove

/// The watering card's arithmetic.
///
/// What is worth pinning here is not the exact position on the scale — that is
/// an estimate and says so — but the three promises the card makes to the user:
///
/// 1. It never tells anyone to water on the strength of a guess.
/// 2. A pot Grove has not seen produces a wide band and "go and feel it", not a
///    confident answer borrowed from a species table.
/// 3. Answering the question collapses the band, and the answer survives.
final class SoilMoistureReadTests: XCTestCase {

    // MARK: - Honesty about what is not known

    func testNoEvidenceAtAllReadsAsNoReadingRatherThanAGuess() {
        let read = SoilMoistureRead(plant: plant(), observations: [], tasks: [])

        XCTAssertEqual(read.verdict, .noReading)
        XCTAssertEqual(read.headline, "No reading yet")
        XCTAssertEqual(read.action, "Push a finger two knuckles into the soil")
        XCTAssertNil(read.evidence)
    }

    /// The whole point of scanning the pot. With none of the four dry-down
    /// inputs known, the uncertainty band is wide enough to straddle the
    /// watering line however long ago the plant was watered — so Grove asks
    /// rather than asserts.
    func testUnseenPotCannotProduceAConfidentVerdict() {
        let unseen = plant(conditions: nil, light: nil)
        let watered = task(kind: .water, daysAgo: 12)

        let read = SoilMoistureRead(plant: unseen, observations: [], tasks: [watered])

        XCTAssertEqual(read.verdict, .unclear)
        XCTAssertGreaterThan(read.uncertainty, 0.3)
        XCTAssertEqual(read.headline, "Too close to call")
        XCTAssertTrue(read.reasons.contains { $0.text == "Pot never scanned" })
    }

    /// The same twelve days, with the pot measured, is a call Grove is allowed
    /// to make. This is the payoff for reading the pot at scan time.
    func testMeasuredPotTwelveDaysOnReadsAsReady() {
        let known = plant(
            conditions: PlantGrowingConditions(
                potMaterial: .terracotta,
                potSize: .small,
                drainage: .drains,
                substrate: .standard,
                soilSurface: .dry,
                potFit: .balanced,
                confidence: 88
            ),
            light: .bright
        )

        let read = SoilMoistureRead(plant: known, observations: [], tasks: [task(kind: .water, daysAgo: 12)])

        XCTAssertEqual(read.verdict, .ready)
        // Both the fast and the slow projection have run out of the bottom of
        // the scale, so the band sits on its floor.
        XCTAssertEqual(read.uncertainty, 0.03, accuracy: 0.001)
    }

    /// Even at `.ready`, the instruction is still to feel the soil. An estimate
    /// is never a reason to pour water on something — Grove only names the
    /// watering can once a person has had a finger in the pot.
    func testReadyStillAsksForAFingerBeforeNamingTheWateringCan() {
        let known = plant(
            conditions: PlantGrowingConditions(potMaterial: .terracotta, potSize: .small, drainage: .drains, substrate: .standard, confidence: 88),
            light: .bright
        )

        let read = SoilMoistureRead(plant: known, observations: [], tasks: [task(kind: .water, daysAgo: 12)])

        XCTAssertEqual(read.verdict, .ready)
        XCTAssertFalse(read.hasFreshFeel)
        XCTAssertEqual(read.action, "Push a finger two knuckles into the soil")
    }

    // MARK: - Answering the card

    func testAFreshFeelCollapsesTheBandAndNamesTheAction() {
        let felt = task(kind: .inspectSoil, daysAgo: 0, moisture: .dry)

        let read = SoilMoistureRead(plant: plant(), observations: [], tasks: [felt])

        XCTAssertTrue(read.hasFreshFeel)
        XCTAssertEqual(read.uncertainty, 0.07, accuracy: 0.001)
        XCTAssertEqual(read.verdict, .ready)
        XCTAssertEqual(read.action, "Water it slowly until it runs out of the bottom")
    }

    func testAFreshWetReadingRefusesToWaterAndSaysWhy() {
        let felt = task(kind: .inspectSoil, daysAgo: 0, moisture: .wet)

        let read = SoilMoistureRead(plant: plant(), observations: [], tasks: [felt])

        XCTAssertEqual(read.verdict, .holding)
        XCTAssertEqual(read.action, "Don't water it. Give it light and air instead")
    }

    /// A watering is real evidence — the soil was wet when it finished — but a
    /// reading someone felt is a better claim, so a same-day tie goes to the
    /// finger.
    func testAFeltReadingOutranksAWateringOfTheSameAge() {
        let moment = Date.now.addingTimeInterval(-3_600)
        let watered = CareTask(id: UUID(), plantID: Self.plantID, kind: .water, dueDate: moment, detail: "", isCompleted: true, isSittingTask: false, ownerName: nil)
        let felt = CareTask(id: UUID(), plantID: Self.plantID, kind: .inspectSoil, dueDate: moment, detail: "", isCompleted: true, isSittingTask: false, ownerName: nil, soilMoisture: .dry)

        let read = SoilMoistureRead(plant: plant(), observations: [], tasks: [watered, felt])

        XCTAssertEqual(read.evidence?.source, .soilCheck)
        XCTAssertEqual(read.evidence?.moisture, .dry)
    }

    /// A soil answer that has been undone is not evidence. `undoCompletion`
    /// flips `isCompleted`, and the read has to honour that or an undo would
    /// leave the card asserting something the user just retracted.
    func testAnUndoneSoilCheckIsNotEvidence() {
        var felt = task(kind: .inspectSoil, daysAgo: 0, moisture: .dry)
        felt.isCompleted = false

        let read = SoilMoistureRead(plant: plant(), observations: [], tasks: [felt])

        XCTAssertEqual(read.verdict, .noReading)
    }

    /// Six hours: long enough for "I felt it before work", short enough that it
    /// can never speak for yesterday.
    func testYesterdaysReadingIsNoLongerAFreshFeel() {
        let felt = task(kind: .inspectSoil, daysAgo: 1, moisture: .dry)

        let read = SoilMoistureRead(plant: plant(), observations: [], tasks: [felt])

        XCTAssertFalse(read.hasFreshFeel)
        XCTAssertEqual(read.action, "Push a finger two knuckles into the soil")
    }

    // MARK: - The pot changes the answer

    /// The overwatering trap, and the reason the scan reads drainage at all: the
    /// same plant, same species, same days since watering, in a pot water cannot
    /// leave takes far longer to be ready — so Grove must not send this owner to
    /// the tap on the schedule the free-draining pot would earn.
    func testACachepotStretchesTheIntervalWellPastAFreeDrainingOne() {
        let draining = SoilDryDown(plant: plant(
            conditions: PlantGrowingConditions(potMaterial: .plastic, potSize: .medium, drainage: .drains, substrate: .standard, confidence: 90),
            light: .bright
        ))
        let trapped = SoilDryDown(plant: plant(
            conditions: PlantGrowingConditions(potMaterial: .glazed, potSize: .xlarge, drainage: .noHoles, substrate: .dense, potFit: .oversized, confidence: 90),
            light: .shaded
        ))

        XCTAssertGreaterThan(trapped.days, draining.days * 2)
        XCTAssertTrue(trapped.holdsWater)
        XCTAssertFalse(draining.holdsWater)
    }

    /// A succulent and a fern cannot share an interval, and the reference pot is
    /// what makes the two comparable at all.
    func testSpeciesBaselineSurvivesTheDamping() {
        let fern = SoilDryDown(plant: plant(species: "Boston fern", scientificName: "Nephrolepis exaltata", conditions: reference, light: .bright))
        let succulent = SoilDryDown(plant: plant(species: "Aloe vera", scientificName: "Aloe barbadensis", conditions: reference, light: .bright))

        XCTAssertEqual(fern.days, 5, accuracy: 0.01)
        // Aloe vera has its own reviewed profile (RHS and UF/IFAS, 24 days)
        // since 6c785c9 replaced the generic 30-day succulent baseline. The
        // reference pot is neutral, so the species baseline comes through as is.
        XCTAssertEqual(succulent.days, 24, accuracy: 0.01)
        XCTAssertGreaterThan(succulent.days, fern.days * 4)
    }

    /// A plant that matched no profile is running on the conservative tropical
    /// baseline, and the band has to widen to say so rather than borrowing the
    /// confidence of a real match.
    func testAGenericSpeciesWidensTheBand() {
        let matched = SoilMoistureRead(
            plant: plant(species: "Swiss cheese plant", scientificName: "Monstera deliciosa", conditions: reference, light: .bright),
            observations: [],
            tasks: [task(kind: .water, daysAgo: 4)]
        )
        let generic = SoilMoistureRead(
            plant: plant(species: "Fiddle-leaf fig", scientificName: "Ficus lyrata", conditions: reference, light: .bright),
            observations: [],
            tasks: [task(kind: .water, daysAgo: 4)]
        )

        XCTAssertGreaterThan(generic.uncertainty, matched.uncertainty)
    }

    // MARK: - Reasons

    func testTheReasonsLeadWithTheDatedEvidenceAndFlagAPotThatHoldsWater() {
        let trapped = plant(
            conditions: PlantGrowingConditions(potMaterial: .glazed, potSize: .medium, drainage: .cachepot, substrate: .standard, surfaceSigns: [.fungusGnats], confidence: 80),
            light: .shaded
        )

        let reasons = SoilMoistureRead(plant: trapped, observations: [], tasks: [task(kind: .water, daysAgo: 3)]).reasons

        XCTAssertEqual(reasons.count, 3)
        XCTAssertEqual(reasons.first?.text, "You watered it 3 days ago")
        XCTAssertEqual(reasons[1].text, "Sits in a cover, so water can't leave")
        XCTAssertTrue(reasons[1].isAlarming)
        XCTAssertEqual(reasons[2].text, "Fungus gnats in the soil")
    }

    /// A big pot defeats a fingertip: the root zone is deeper than a finger
    /// reaches, so the instruction has to name the better instrument.
    func testALargePotAsksForTheWeightCheckAsWell() {
        let big = plant(
            conditions: PlantGrowingConditions(potMaterial: .plastic, potSize: .xlarge, drainage: .drains, substrate: .standard, confidence: 85),
            light: .bright
        )

        let read = SoilMoistureRead(plant: big, observations: [], tasks: [task(kind: .water, daysAgo: 5)])

        XCTAssertTrue(read.needsWeightCheck)
        XCTAssertEqual(read.action, "Push a finger two knuckles in, then lift the pot")
    }

    // MARK: - Fixtures

    private static let plantID = UUID(uuidString: "20000000-0000-0000-0000-0000000000AA")!

    private var reference: PlantGrowingConditions {
        PlantGrowingConditions(
            potMaterial: .plastic,
            potSize: .medium,
            drainage: .drains,
            substrate: .standard,
            potFit: .balanced,
            confidence: 90
        )
    }

    private func plant(
        species: String = "Swiss cheese plant",
        scientificName: String = "Monstera deliciosa",
        conditions: PlantGrowingConditions? = nil,
        light: PlantLightPlacement? = .bright
    ) -> Plant {
        Plant(
            id: Self.plantID,
            nickname: "Monty",
            species: species,
            scientificName: scientificName,
            location: "Living room",
            lightPlacement: light,
            growingConditions: conditions,
            healthScore: 80,
            healthBand: .healthy,
            trend: .stable,
            confidence: 85,
            nextCheckIn: .now,
            symbol: "leaf.fill",
            palette: .fern,
            summary: "",
            positiveSigns: [],
            concerns: [],
            nextActions: []
        )
    }

    private func task(
        kind: CareKind,
        daysAgo: Int,
        moisture: ObservationSoilMoisture? = nil
    ) -> CareTask {
        CareTask(
            id: UUID(),
            plantID: Self.plantID,
            kind: kind,
            dueDate: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now,
            detail: "",
            isCompleted: true,
            isSittingTask: false,
            ownerName: nil,
            soilMoisture: moisture
        )
    }
}
