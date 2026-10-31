import XCTest
@testable import Grove

/// The score is a trust feature, so these tests concentrate on the seams a
/// person (or imperfect synced data) could otherwise exploit: repeat taps,
/// duplicate reminders, orphaned history, weak evidence and instant recovery.
final class GroveScoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testEmptyGroveHasNoScore() {
        XCTAssertNil(
            GroveScore.measure(
                plants: [],
                observations: [],
                diagnoses: [],
                scans: [],
                tasks: [],
                streak: 0,
                now: now,
                calendar: calendar
            )
        )
    }

    func testSameDayRetakesEarnOnlyOneEvidenceDay() throws {
        let plant = plant(score: 92)
        let scans = (0..<12).map { offset in
            scan(plantID: plant.id, score: 92, date: now.addingTimeInterval(Double(offset)))
        }

        let score = try measured(plants: [plant], scans: scans)

        XCTAssertEqual(score.lookDays, 1)
        XCTAssertEqual(score.fullEvidenceDays, GroveCensus.fullEvidenceDays(forPlantCount: 1))
        XCTAssertEqual(
            score.evidenceWeight,
            1 / Double(score.fullEvidenceDays),
            accuracy: 0.0001
        )
    }

    func testEstimatedAndDeletedPlantEvidenceCannotFirmTheScore() throws {
        let plant = plant(score: 92)
        let deletedPlantID = UUID()
        let weakReading = observation(
            plantID: plant.id,
            score: 92,
            date: now,
            isEstimated: true
        )
        let orphanedScans = (0..<GroveScore.Rules.fullEvidenceDays).map { offset in
            scan(plantID: deletedPlantID, score: 99, date: date(daysAgo: offset))
        }

        let score = try measured(
            plants: [plant],
            observations: [weakReading],
            scans: orphanedScans
        )

        XCTAssertEqual(score.lookDays, 0)
        XCTAssertEqual(score.evidenceWeight, 0)
        XCTAssertEqual(score.total, 50)
    }

    func testEvidenceRequiresDistinctCalendarDays() throws {
        let plant = plant(score: 92)
        let scans = evidenceScans(for: plant.id)

        let score = try measured(plants: [plant], scans: scans)

        XCTAssertEqual(score.lookDays, GroveScore.Rules.fullEvidenceDays)
        XCTAssertEqual(score.evidenceWeight, 1)
        XCTAssertGreaterThan(score.total, 50)
        XCTAssertEqual(score.total, score.pillars.reduce(0) { $0 + $1.points })
    }

    func testOlderHealthyReadingCountsForLessThanFreshEvidence() throws {
        let plant = plant(score: 95)
        let fresh = (0..<GroveScore.Rules.fullEvidenceDays).map {
            scan(plantID: plant.id, score: 95, date: date(daysAgo: $0))
        }
        let older = (15..<(15 + GroveScore.Rules.fullEvidenceDays)).map {
            scan(plantID: plant.id, score: 95, date: date(daysAgo: $0))
        }

        let freshScore = try measured(plants: [plant], scans: fresh)
        let olderScore = try measured(plants: [plant], scans: older)

        XCTAssertLessThan(
            try XCTUnwrap(olderScore.pillar(.wellbeing)).fraction,
            try XCTUnwrap(freshScore.pillar(.wellbeing)).fraction
        )
    }

    func testWorstPlantCannotHideInsideHealthyAverage() throws {
        let first = plant(named: "Fern", score: 94)
        let second = plant(named: "Palm", score: 94)
        let healthyScans = evidenceScans(for: first.id) + evidenceScans(for: second.id)

        var struggling = second
        struggling.healthScore = 35
        struggling.healthBand = .attention
        let mixedScans = evidenceScans(for: first.id) + evidenceScans(for: second.id, score: 35)

        let healthyScore = try measured(plants: [first, second], scans: healthyScans)
        let mixedScore = try measured(plants: [first, struggling], scans: mixedScans)

        XCTAssertLessThan(
            try XCTUnwrap(mixedScore.pillar(.wellbeing)).points,
            try XCTUnwrap(healthyScore.pillar(.wellbeing)).points
        )
        XCTAssertLessThan(mixedScore.total, healthyScore.total)
    }

    func testDuplicateOldAndInferredCareCannotDistortTimeliness() throws {
        let plant = plant(score: 90)
        let due = date(daysAgo: 5)
        let completed = careTask(
            plantID: plant.id,
            dueDate: due,
            isCompleted: true,
            completedAt: due
        )
        let duplicateReminder = careTask(
            plantID: plant.id,
            dueDate: due,
            isCompleted: false
        )
        let oldOverdue = careTask(
            plantID: plant.id,
            dueDate: date(daysAgo: GroveScore.Rules.careWindowDays + 10),
            isCompleted: false
        )
        let inferredLegacyCompletion = careTask(
            plantID: plant.id,
            dueDate: date(daysAgo: 8),
            isCompleted: true,
            completedAt: nil
        )
        let orphanedOverdue = careTask(
            plantID: UUID(),
            dueDate: date(daysAgo: 2),
            isCompleted: false
        )

        let score = try measured(
            plants: [plant],
            scans: evidenceScans(for: plant.id),
            tasks: [completed, duplicateReminder, oldOverdue, inferredLegacyCompletion, orphanedOverdue]
        )

        // One real due event, completed on time: 80% outcome + 0% streak.
        XCTAssertEqual(try XCTUnwrap(score.pillar(.timeliness)).points, 20)
    }

    func testRecoveryMustHoldAcrossDifferentDaysForAWeek() throws {
        let plant = plant(score: 82)
        let sameDay = [
            observation(plantID: plant.id, score: 45, date: now),
            observation(plantID: plant.id, score: 82, date: now.addingTimeInterval(60))
        ]
        let held = [
            observation(plantID: plant.id, score: 45, date: date(daysAgo: 9)),
            observation(plantID: plant.id, score: 82, date: now)
        ]

        let sameDayScore = try measured(
            plants: [plant],
            observations: sameDay,
            scans: evidenceScans(for: plant.id)
        )
        let heldScore = try measured(
            plants: [plant],
            observations: held,
            scans: evidenceScans(for: plant.id)
        )

        XCTAssertEqual(try XCTUnwrap(sameDayScore.pillar(.recovery)).points, 0)
        XCTAssertEqual(try XCTUnwrap(heldScore.pillar(.recovery)).points, 15)
    }

    func testLowConfidenceReadingIsTempered() throws {
        let proven = plant(score: 98, confidence: 100)
        var uncertain = proven
        uncertain.confidence = 20
        let scans = evidenceScans(for: proven.id, score: 98)

        let provenScore = try measured(plants: [proven], scans: scans)
        let uncertainScore = try measured(plants: [uncertain], scans: scans)

        XCTAssertLessThan(
            try XCTUnwrap(uncertainScore.pillar(.wellbeing)).points,
            try XCTUnwrap(provenScore.pillar(.wellbeing)).points
        )
    }

    // MARK: - Settling
    //
    // Today's toolbar control withholds the number while the reading is still
    // settling, so `isSettling` is now load-bearing for what a new user sees
    // rather than only for a caption on the score page.

    func testAFreshGroveReadsAsSettlingRatherThanAsAScore() throws {
        let plant = plant(score: 92)

        let score = try measured(
            plants: [plant],
            scans: [scan(plantID: plant.id, score: 92, date: now)]
        )

        XCTAssertTrue(
            score.isSettling,
            "A grove one day old has no business showing a two-digit grade"
        )
        XCTAssertLessThan(score.evidenceWeight, 1)
    }

    func testTheScoreStopsSettlingOnceTheEvidenceIsIn() throws {
        let plant = plant(score: 92)

        let score = try measured(plants: [plant], scans: evidenceScans(for: plant.id))

        XCTAssertFalse(
            score.isSettling,
            "Ten distinct looking-days is the whole bar; past it the number stands"
        )
        XCTAssertEqual(score.evidenceWeight, 1)
    }

    // MARK: - Fixtures

    private func measured(
        plants: [Plant],
        observations: [PlantObservation] = [],
        scans: [ScanHistoryRecord] = [],
        tasks: [CareTask] = []
    ) throws -> GroveScore {
        try XCTUnwrap(
            GroveScore.measure(
                plants: plants,
                observations: observations,
                diagnoses: [],
                scans: scans,
                tasks: tasks,
                streak: 0,
                now: now,
                calendar: calendar
            )
        )
    }

    private func plant(
        named nickname: String = "Fern",
        score: Int,
        confidence: Int = 100
    ) -> Plant {
        Plant(
            id: UUID(),
            nickname: nickname,
            species: "Plant",
            scientificName: "Plantae",
            location: "Home",
            healthScore: score,
            healthBand: HealthBand(score: score),
            trend: .stable,
            confidence: confidence,
            nextCheckIn: now,
            symbol: "leaf.fill",
            palette: .fern,
            summary: "",
            positiveSigns: [],
            concerns: [],
            nextActions: []
        )
    }

    private func evidenceScans(
        for plantID: UUID,
        score: Int = 90
    ) -> [ScanHistoryRecord] {
        (0..<GroveScore.Rules.fullEvidenceDays).map {
            scan(plantID: plantID, score: score, date: date(daysAgo: $0))
        }
    }

    private func scan(plantID: UUID?, score: Int, date: Date) -> ScanHistoryRecord {
        ScanHistoryRecord(
            id: UUID(),
            createdAt: date,
            mode: .diagnose,
            commonName: "Plant",
            scientificName: "Plantae",
            identificationConfidence: 95,
            healthScore: score,
            healthBand: HealthBand(score: score),
            photoURL: nil,
            plantID: plantID
        )
    }

    private func observation(
        plantID: UUID,
        score: Int,
        date: Date,
        isEstimated: Bool = false
    ) -> PlantObservation {
        PlantObservation(
            id: UUID(),
            plantID: plantID,
            createdAt: date,
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

    private func careTask(
        plantID: UUID,
        dueDate: Date,
        isCompleted: Bool,
        completedAt: Date? = nil
    ) -> CareTask {
        CareTask(
            id: UUID(),
            plantID: plantID,
            kind: .water,
            dueDate: dueDate,
            detail: "",
            isCompleted: isCompleted,
            isSittingTask: false,
            ownerName: nil,
            completedAt: completedAt
        )
    }

    private func date(daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
    }
}
