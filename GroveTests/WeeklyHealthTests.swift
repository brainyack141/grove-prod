import XCTest
@testable import Grove

/// The "Your week" card on Home is a chart, and a chart is a claim. These pin
/// down what it is allowed to claim: which looks count as looks, how a day with
/// uneven attention is averaged, and what happens to a reading Grove never
/// actually measured.
@MainActor
final class WeeklyHealthTests: XCTestCase {
    /// The bug the card shipped with. Adopting a plant and diagnosing one both
    /// photograph a real plant and write a real health score — and neither
    /// produced a check-in observation, so a gardener who had spent the week
    /// scanning was told "No readings, 0 of 7 days looked in".
    func testAScanOfAPlantInTheGroveCountsAsLookingIn() {
        let fern = plant(score: 70)
        let store = store(plants: [fern], scans: [scan(plantID: fern.id, score: 82, daysAgo: 0)])

        let today = store.currentWeekCheckIns.first { $0.isToday }
        XCTAssertEqual(today?.averageScore, 82)
        XCTAssertEqual(today?.plantsSeen, 1)
        XCTAssertEqual(store.currentWeekCheckIns.filter(\.didCheckIn).count, 1)
    }

    /// A scan whose plant was never adopted — an identify of someone else's
    /// hedge — is not a reading of this grove's health.
    func testAScanNotAttachedToAPlantIsIgnored() {
        let store = store(plants: [plant(score: 70)], scans: [scan(plantID: nil, score: 20, daysAgo: 0)])

        XCTAssertTrue(store.currentWeekCheckIns.allSatisfy { !$0.didCheckIn })
    }

    /// Weighting by reading rather than by plant lets attention masquerade as
    /// decline: three looks at the sick one and one at the healthy one is not a
    /// grove averaging 47.
    func testADayIsAveragedPerPlantNotPerReading() {
        let sick = plant(score: 40)
        let well = plant(score: 90)
        let store = store(
            plants: [sick, well],
            observations: [
                observation(plantID: sick.id, score: 40, daysAgo: 0),
                observation(plantID: sick.id, score: 42, daysAgo: 0),
                observation(plantID: sick.id, score: 44, daysAgo: 0),
                observation(plantID: well.id, score: 90, daysAgo: 0)
            ]
        )

        let today = store.currentWeekCheckIns.first { $0.isToday }
        // Sick averages 42, well 90 — the grove reads 66, not the 54 a flat
        // mean of the four readings would have drawn.
        XCTAssertEqual(today?.averageScore, 66)
        XCTAssertEqual(today?.plantsSeen, 2)
        XCTAssertEqual(today?.readingCount, 4)
    }

    /// The offline estimate nudges the previous score from three form answers
    /// and never sees the photo. It is a look — the axis shows it — but it is
    /// not a measurement, and the line must not pretend otherwise.
    func testAnOfflineEstimateCountsAsALookButNotAsAReading() {
        let fern = plant(score: 70)
        let store = store(
            plants: [fern],
            observations: [observation(plantID: fern.id, score: 95, daysAgo: 0, isEstimated: true)]
        )

        let today = store.currentWeekCheckIns.first { $0.isToday }
        XCTAssertTrue(today?.didCheckIn == true)
        XCTAssertTrue(today?.isUnscored == true)
        XCTAssertNil(today?.averageScore, "An estimate is not a reading of the plant")
    }

    /// A measured reading on the same day rescues it: the estimate drops out,
    /// the measurement stands alone.
    func testAMeasuredReadingOutranksAnEstimateOnTheSameDay() {
        let fern = plant(score: 70)
        let store = store(
            plants: [fern],
            observations: [
                observation(plantID: fern.id, score: 95, daysAgo: 0, isEstimated: true),
                observation(plantID: fern.id, score: 61, daysAgo: 0)
            ]
        )

        XCTAssertEqual(store.currentWeekCheckIns.first { $0.isToday }?.averageScore, 61)
    }

    /// History for a plant deleted on another device can outlive the sync that
    /// removed it. An average over plants you no longer own is an average of
    /// nothing.
    func testReadingsForAPlantNoLongerInTheGroveAreDropped() {
        let ghost = UUID()
        let store = store(
            plants: [plant(score: 70)],
            observations: [observation(plantID: ghost, score: 10, daysAgo: 0)],
            scans: [scan(plantID: ghost, score: 10, daysAgo: 0)]
        )

        XCTAssertTrue(store.currentWeekCheckIns.allSatisfy { !$0.didCheckIn })
    }

    /// A day nobody looked reports nothing, never a zero — a zero would draw
    /// the grove as dead on every day off.
    func testADayNobodyLookedHasNoScore() {
        let fern = plant(score: 70)
        let store = store(plants: [fern], scans: [scan(plantID: fern.id, score: 82, daysAgo: 0)])

        let quiet = store.currentWeekCheckIns.filter { !$0.isToday }
        XCTAssertFalse(quiet.isEmpty)
        XCTAssertTrue(quiet.allSatisfy { $0.averageScore == nil && !$0.didCheckIn })
    }

    func testTheWeekIsSevenDaysAndKnowsWhichIsToday() {
        let week = store(plants: [plant(score: 70)]).currentWeekCheckIns

        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.filter(\.isToday).count, 1)
        XCTAssertEqual(week.map(\.id), Array(0..<7))
        XCTAssertTrue(
            week.filter(\.isFuture).allSatisfy { !$0.didCheckIn },
            "A day that hasn't happened cannot hold a reading"
        )
    }

    // MARK: - Fixtures

    private func store(
        plants: [Plant],
        observations: [PlantObservation] = [],
        scans: [ScanHistoryRecord] = []
    ) -> GroveStore {
        GroveStore(
            plants: plants,
            observations: observations,
            scanHistory: scans,
            persistenceEnabled: false
        )
    }

    private func plant(score: Int) -> Plant {
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
            nextActions: []
        )
    }

    private func observation(
        plantID: UUID,
        score: Int,
        daysAgo: Int,
        isEstimated: Bool = false
    ) -> PlantObservation {
        PlantObservation(
            id: UUID(),
            plantID: plantID,
            createdAt: date(daysAgo: daysAgo),
            previousScore: score,
            score: score,
            band: HealthBand(score: score),
            note: "",
            appearance: .same,
            soilMoisture: .comfortable,
            hasNewGrowth: false,
            photoURL: nil,
            actorName: "You",
            isEstimated: isEstimated
        )
    }

    private func scan(plantID: UUID?, score: Int, daysAgo: Int) -> ScanHistoryRecord {
        ScanHistoryRecord(
            id: UUID(),
            createdAt: date(daysAgo: daysAgo),
            mode: .diagnose,
            commonName: "Monstera",
            scientificName: "Monstera deliciosa",
            identificationConfidence: 92,
            healthScore: score,
            healthBand: HealthBand(score: score),
            photoURL: nil,
            plantID: plantID
        )
    }

    /// Midday, so a fixture never lands either side of a day boundary.
    private func date(daysAgo: Int) -> Date {
        let calendar = Calendar.current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: .now) ?? .now
        return calendar.date(byAdding: .day, value: -daysAgo, to: noon) ?? noon
    }
}
