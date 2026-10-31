import XCTest
@testable import Grove

/// The plant page's one-line state read.
///
/// These used to be tests of `PlantStatePercentageDistribution` — the
/// largest-remainder rounding that forced five overlapping signal strengths to
/// sum to 100 so a donut could be drawn from them. The donut is gone; the
/// inference under it is what mattered, and what is worth pinning down is which
/// state it picks, not what the runners-up were scored.
final class PlantStateReadTests: XCTestCase {
    func testUrgentBandIsNeverDescribedAsComfortable() {
        let read = PlantStateRead.strongest(
            for: plant(score: 20, band: .urgent, concerns: ["Collapsed stems"]),
            latest: nil,
            diagnosis: nil
        )

        XCTAssertEqual(read, .stressed)
    }

    /// The positive states tie for a thriving plant — its score feeds both — and
    /// case order is what resolves it. Growth is the more specific, more legible
    /// thing to say, so it has to win.
    func testThrivingPlantWithNewGrowthLeadsWithFlourishing() {
        let read = PlantStateRead.strongest(
            for: plant(score: 95, band: .thriving, positiveSigns: ["New growth on the crown"]),
            latest: observation(
                score: 95,
                band: .thriving,
                appearance: .better,
                moisture: .comfortable,
                newGrowth: true
            ),
            diagnosis: nil
        )

        XCTAssertEqual(read, .flourishing)
    }

    /// A named condition carries more weight than the band's generic stress
    /// signal, so the read points at the cause rather than the symptom.
    func testDiagnosedRootRotOutranksTheBandsGenericStress() {
        let read = PlantStateRead.strongest(
            for: plant(score: 60, band: .monitor, concerns: ["Yellowing lower leaves"]),
            latest: observation(
                score: 60,
                band: .monitor,
                appearance: .same,
                moisture: .wet,
                newGrowth: false
            ),
            diagnosis: diagnosis(
                band: .monitor,
                condition: "Root rot",
                confidence: 88,
                explanation: "Excess moisture held around the roots."
            )
        )

        XCTAssertEqual(read, .waterlogged)
    }

    /// Dryness and stress tie for a plant needing attention with dry soil. The
    /// actionable one is the one worth putting on screen.
    func testDrySoilNamesTheCauseRatherThanTheStress() {
        let read = PlantStateRead.strongest(
            for: plant(score: 40, band: .attention, concerns: ["Crisp leaf tips"]),
            latest: observation(
                score: 40,
                band: .attention,
                appearance: .same,
                moisture: .dry,
                newGrowth: false
            ),
            diagnosis: nil
        )

        XCTAssertEqual(read, .dehydrated)
    }

    /// With nothing current to read from, the honest answer is that Grove
    /// cannot say — not its most reassuring sentence. A returning user standing
    /// over a plant they think looks ill must not be told the evidence "looks
    /// settled overall" on the strength of a six-week-old check-in.
    func testNoCurrentEvidenceIsAdmittedRatherThanReassured() {
        let read = PlantStateRead.strongest(
            for: plant(score: 76, band: .healthy),
            latest: nil,
            diagnosis: nil,
            hasCurrentEvidence: false
        )

        XCTAssertEqual(read, .unassessed)
    }

    /// A moisture reading the owner entered outranks an inference drawn from
    /// the score. The whole healthy band used to beat `.waterlogged`, so the
    /// page withheld the overwatering warning until overwatering had already
    /// pulled the score below 75 — by which point it was no longer news.
    func testWetSoilLeadsEvenWhileTheBandIsStillHealthy() {
        let read = PlantStateRead.strongest(
            for: plant(score: 82, band: .healthy),
            latest: observation(
                score: 82,
                band: .healthy,
                appearance: .same,
                moisture: .wet,
                newGrowth: false
            ),
            diagnosis: nil
        )

        XCTAssertEqual(read, .waterlogged)
    }

    /// The same guard, in the other direction, so a dry-soil plant is not told
    /// it looks settled either.
    func testDrySoilLeadsEvenWhileTheBandIsStillHealthy() {
        let read = PlantStateRead.strongest(
            for: plant(score: 80, band: .healthy),
            latest: observation(
                score: 80,
                band: .healthy,
                appearance: .same,
                moisture: .dry,
                newGrowth: false
            ),
            diagnosis: nil
        )

        XCTAssertEqual(read, .dehydrated)
    }

    // MARK: - Ari's plant-page read

    /// A healthy scan still has a diagnosis, and the read must carry it. Before
    /// this, a `.comfortable` plant was told "Nothing needs doing today" — the
    /// band, not what the analysis saw — so a good result read as no result.
    func testHealthyReadCarriesTheScansDiagnosisInsteadOfNothing() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var subject = plant(score: 82, band: .healthy)
        subject.assessmentDate = now
        subject.assessmentSource = .baselinePhoto
        subject.summary = "The plant appears healthy overall. One lower leaf shows mild yellowing, so inspect soil moisture before watering."

        let takeaway = try XCTUnwrap(
            AriScanTakeaway.make(plant: subject, diagnoses: [], scans: [], now: now)
        )
        let copy = PlantAriReadCopy.make(
            plant: subject,
            read: .comfortable,
            hasCurrentEvidence: true,
            takeaway: takeaway
        )

        XCTAssertEqual(copy.headline, "Looking good")
        XCTAssertEqual(copy.finding, "Pesto appears healthy overall.")
        XCTAssertEqual(
            copy.explanation,
            "One lower leaf shows mild yellowing, so inspect soil moisture before watering."
        )
        XCTAssertNotEqual(copy.finding, "Nothing needs doing today. Check the soil before you water.")
    }

    /// With no scan on record, the band fallback is still the honest thing to
    /// say — the diagnosis preference must not invent one.
    func testReadFallsBackToBandCopyWhenThereIsNoScan() {
        let copy = PlantAriReadCopy.make(
            plant: plant(score: 82, band: .healthy),
            read: .comfortable,
            hasCurrentEvidence: true,
            takeaway: nil
        )

        XCTAssertEqual(copy.headline, "Looking good")
        XCTAssertEqual(copy.finding, "Nothing needs doing today. Check the soil before you water.")
        XCTAssertNil(copy.explanation)
    }

    /// An aged-out read keeps asking for a fresh look rather than borrowing the
    /// verdict of a scan the page has already stopped counting.
    func testReadWithNoCurrentEvidenceAsksForAFreshLook() {
        let copy = PlantAriReadCopy.make(
            plant: plant(score: 82, band: .healthy),
            read: .unassessed,
            hasCurrentEvidence: false,
            takeaway: nil
        )

        XCTAssertEqual(copy.headline, "Time for a fresh photo")
        XCTAssertTrue(copy.finding.contains("Pesto"))
        XCTAssertNil(copy.explanation)
    }

    /// Ari calls a plant by its name. A saved scan that opens on "The plant"
    /// gets the name in its place; anything else is left exactly as written.
    func testAriReadNamesThePlantInsteadOfTheGenericSubject() {
        XCTAssertEqual(
            PlantAriReadCopy.naming("The plant appears vigorous with firm leaves.", nickname: "Bird of paradise"),
            "Bird of paradise appears vigorous with firm leaves."
        )
        XCTAssertEqual(
            PlantAriReadCopy.naming("This plant's new leaf is unfurling.", nickname: "Monty"),
            "Monty's new leaf is unfurling."
        )
        XCTAssertEqual(
            PlantAriReadCopy.naming("The planter is too small.", nickname: "Monty"),
            "The planter is too small."
        )
        XCTAssertEqual(
            PlantAriReadCopy.naming("Leaves are firm and upright.", nickname: "Monty"),
            "Leaves are firm and upright."
        )
    }

    // MARK: - Fixtures

    private func plant(
        score: Int,
        band: HealthBand,
        positiveSigns: [String] = [],
        concerns: [String] = []
    ) -> Plant {
        Plant(
            id: UUID(),
            nickname: "Pesto",
            species: "Monstera",
            scientificName: "Monstera deliciosa",
            location: "Kitchen",
            healthScore: score,
            healthBand: band,
            trend: .stable,
            confidence: 90,
            nextCheckIn: .now,
            symbol: "leaf.fill",
            palette: .fern,
            summary: "The latest photos are the basis for this read.",
            positiveSigns: positiveSigns,
            concerns: concerns,
            nextActions: []
        )
    }

    private func observation(
        score: Int,
        band: HealthBand,
        appearance: ObservationAppearance,
        moisture: ObservationSoilMoisture,
        newGrowth: Bool
    ) -> PlantObservation {
        PlantObservation(
            id: UUID(),
            plantID: UUID(),
            createdAt: .now,
            previousScore: score,
            score: score,
            band: band,
            note: "",
            appearance: appearance,
            soilMoisture: moisture,
            hasNewGrowth: newGrowth,
            photoURL: nil,
            actorName: "Ari"
        )
    }

    private func diagnosis(
        band: HealthBand,
        condition: String,
        confidence: Int,
        explanation: String
    ) -> PlantDiagnosis {
        PlantDiagnosis(
            id: UUID(),
            plantID: UUID(),
            createdAt: .now,
            summary: "One condition leads the evidence.",
            healthBand: band,
            confidence: confidence,
            possibleConditions: [
                PlantConditionCandidate(
                    id: condition,
                    name: condition,
                    confidence: confidence,
                    explanation: explanation,
                    evidence: ["Soft base"],
                    alternativeExplanation: nil
                )
            ],
            actionsToTake: [],
            actionsToAvoid: [],
            providerName: nil,
            identificationConfidence: nil,
            identificationRequiresConfirmation: nil,
            visiblePositiveSigns: nil,
            visibleConcerns: nil,
            clarifyingQuestions: nil,
            limitations: nil,
            photoURL: nil
        )
    }
}
