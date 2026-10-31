import XCTest
@testable import Grove

/// The census decides what a new user's Today looks like, so these tests are
/// mostly about the rungs: that a grove cannot skip one, and that the evidence
/// bar bends for a small grove without falling low enough to be gamed.
final class GroveCensusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Stages

    func testNoPlantsReadsAsEmpty() {
        let census = GroveCensus.take(plants: [], observations: [], score: nil)

        XCTAssertEqual(census.stage, .empty)
        XCTAssertEqual(census.deepestRecordFrameCount, 0)
    }

    func testPlantsWithoutPhotographsStopAtPlanted() {
        let plant = plant()
        let census = GroveCensus.take(
            plants: [plant],
            observations: [observation(plantID: plant.id, photo: nil)],
            score: nil
        )

        XCTAssertEqual(
            census.stage,
            .planted,
            "An observation with no photograph leaves nothing for the hero to draw from"
        )
        XCTAssertEqual(census.photographedPlantCount, 0)
    }

    func testOnePhotographReachesObservedButNotComparing() {
        let plant = plant()
        let census = GroveCensus.take(
            plants: [plant],
            observations: [observation(plantID: plant.id)],
            score: nil
        )

        XCTAssertEqual(census.stage, .observed)
        XCTAssertEqual(census.deepestRecordFrameCount, 1)
    }

    /// The rule the Today record card rests on: a time-lapse needs two frames
    /// of *one* plant, and ten plants photographed once each is not that.
    func testFramesSpreadAcrossPlantsDoNotUnlockComparing() {
        let plants = (0..<10).map { _ in plant() }
        let observations = plants.map { observation(plantID: $0.id) }

        let census = GroveCensus.take(
            plants: plants,
            observations: observations,
            score: nil
        )

        XCTAssertEqual(census.stage, .observed)
        XCTAssertEqual(census.deepestRecordFrameCount, 1)
        XCTAssertEqual(census.photographedPlantCount, 10)
    }

    func testTwoFramesOnOnePlantReachComparing() {
        let plant = plant()
        let census = GroveCensus.take(
            plants: [plant],
            observations: [
                observation(plantID: plant.id, date: now.addingTimeInterval(-86_400 * 30)),
                observation(plantID: plant.id, date: now)
            ],
            score: nil
        )

        XCTAssertEqual(census.stage, .comparing)
        XCTAssertEqual(census.deepestRecordFrameCount, 2)
    }

    func testObservationsForDeletedPlantsAreIgnored() {
        let plant = plant()
        let census = GroveCensus.take(
            plants: [plant],
            observations: [
                observation(plantID: UUID()),
                observation(plantID: UUID())
            ],
            score: nil
        )

        XCTAssertEqual(census.stage, .planted)
        XCTAssertEqual(census.deepestRecordFrameCount, 0)
    }

    // MARK: - The evidence bar

    func testTheEvidenceBarScalesWithGroveSize() {
        XCTAssertLessThan(
            GroveCensus.fullEvidenceDays(forPlantCount: 1),
            GroveCensus.fullEvidenceDays(forPlantCount: 5),
            "One plant cannot produce looking-days at the rate five plants can"
        )
    }

    func testTheEvidenceBarNeverExceedsTheCeiling() {
        for count in 1...50 {
            XCTAssertLessThanOrEqual(
                GroveCensus.fullEvidenceDays(forPlantCount: count),
                GroveScore.Rules.fullEvidenceDays
            )
        }
    }

    /// The bar bends for small groves, but the property it was defending is
    /// calendar time. Anything reachable in a single sitting would give that
    /// away, so the floor stays well clear of it.
    func testTheEvidenceBarStaysAboveWhatOneSittingCouldProduce() {
        for count in 0...50 {
            XCTAssertGreaterThanOrEqual(
                GroveCensus.fullEvidenceDays(forPlantCount: count),
                5
            )
        }
    }

    // MARK: - Fixtures

    private func plant(named nickname: String = "Fern") -> Plant {
        Plant(
            id: UUID(),
            nickname: nickname,
            species: "Plant",
            scientificName: "Plantae",
            location: "Home",
            healthScore: 88,
            healthBand: HealthBand(score: 88),
            trend: .stable,
            confidence: 100,
            nextCheckIn: now,
            symbol: "leaf.fill",
            palette: .fern,
            summary: "",
            positiveSigns: [],
            concerns: [],
            nextActions: []
        )
    }

    private func observation(
        plantID: UUID,
        date: Date? = nil,
        photo: URL? = URL(fileURLWithPath: "/tmp/frame.jpg")
    ) -> PlantObservation {
        PlantObservation(
            id: UUID(),
            plantID: plantID,
            createdAt: date ?? now,
            previousScore: 88,
            score: 88,
            band: HealthBand(score: 88),
            note: "",
            appearance: .same,
            soilMoisture: .comfortable,
            hasNewGrowth: false,
            photoURL: photo,
            actorName: "You"
        )
    }
}
