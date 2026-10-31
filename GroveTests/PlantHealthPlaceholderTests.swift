import XCTest
@testable import Grove

/// A plant saved without a reading carries the neutral placeholder score so its
/// non-optional health fields stay valid. These tests pin down that the grove
/// summaries never count that placeholder as a real reading.
final class PlantHealthPlaceholderTests: XCTestCase {
    func testAverageIgnoresAnUnassessedPlant() {
        let assessed = plant(score: 90)
        let unassessed = plant(
            score: Plant.unassessedPlaceholderScore,
            source: .offlineEstimate
        )

        let average = MyGroveHealthAverage.measure(
            plants: [assessed, unassessed],
            observations: []
        )

        XCTAssertEqual(average?.value, 90)
        XCTAssertNil(average?.trend)
    }

    func testAverageIsNilWhenNoPlantHasAReading() {
        let first = plant(
            score: Plant.unassessedPlaceholderScore,
            source: .offlineEstimate
        )
        let second = plant(
            score: Plant.unassessedPlaceholderScore,
            source: .offlineEstimate
        )

        XCTAssertNil(
            MyGroveHealthAverage.measure(
                plants: [first, second],
                observations: []
            )
        )
    }

    func testMostImprovedIgnoresAnUnassessedPlant() {
        let assessed = plant(score: 90)
        let unassessed = plant(
            score: Plant.unassessedPlaceholderScore,
            source: .offlineEstimate
        )

        let improvement = MyGroveImprovement.mostImproved(
            plants: [assessed, unassessed],
            observations: [
                observation(plantID: assessed.id, previousScore: 80, score: 90),
                observation(
                    plantID: unassessed.id,
                    previousScore: 10,
                    score: Plant.unassessedPlaceholderScore
                )
            ]
        )

        XCTAssertEqual(improvement?.plant.id, assessed.id)
        XCTAssertEqual(improvement?.gain, 10)
    }

    func testMostImprovedIsNilWhenNoPlantHasAReading() {
        let unassessed = plant(
            score: Plant.unassessedPlaceholderScore,
            source: .offlineEstimate
        )

        XCTAssertNil(
            MyGroveImprovement.mostImproved(
                plants: [unassessed],
                observations: [
                    observation(
                        plantID: unassessed.id,
                        previousScore: 10,
                        score: Plant.unassessedPlaceholderScore
                    )
                ]
            )
        )
    }

    private func plant(
        score: Int,
        source: PlantAssessmentSource? = .checkInPhoto
    ) -> Plant {
        Plant(
            id: UUID(),
            nickname: "Pesto",
            species: "Monstera",
            scientificName: "Monstera deliciosa",
            location: "Kitchen",
            healthScore: score,
            healthBand: HealthBand(score: score),
            trend: .stable,
            confidence: 90,
            nextCheckIn: .now,
            symbol: "leaf.fill",
            palette: .fern,
            summary: "",
            positiveSigns: [],
            concerns: [],
            nextActions: [],
            assessmentSource: source
        )
    }

    private func observation(
        plantID: UUID,
        previousScore: Int,
        score: Int
    ) -> PlantObservation {
        PlantObservation(
            id: UUID(),
            plantID: plantID,
            createdAt: .now,
            previousScore: previousScore,
            score: score,
            band: HealthBand(score: score),
            note: "",
            appearance: .same,
            soilMoisture: .comfortable,
            hasNewGrowth: false,
            photoURL: nil,
            actorName: "You"
        )
    }
}
