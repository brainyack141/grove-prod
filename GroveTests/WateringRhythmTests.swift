import XCTest
@testable import Grove

/// The one reading on the plant page that is arithmetic rather than judgement.
///
/// So what is worth pinning is exactly that: that it reports the record and
/// nothing more. It must not smooth a holiday away, must not call noise a
/// season, must not draw a rhythm out of two waterings, and must not present a
/// reminder date as a record of what happened.
final class WateringRhythmTests: XCTestCase {

    private static let plantID = UUID()
    private static let otherPlantID = UUID()

    // MARK: - The gaps themselves

    func testIntervalsAreTheDaysBetweenConsecutiveWaterings() {
        // Watered 30, 22, 14 and 7 days ago: gaps of 8, 8 and 7.
        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: waterings(daysAgo: [30, 22, 14, 7]))

        XCTAssertEqual(rhythm.intervals.map(\.days), [8, 8, 7])
        XCTAssertEqual(rhythm.typicalDays, 8)
        XCTAssertEqual(rhythm.daysSinceLast, 7)
    }

    func testOnlyWateringsForThisPlantCount() {
        var tasks = waterings(daysAgo: [30, 22, 14, 7])
        tasks += waterings(daysAgo: [28, 21, 3], plantID: Self.otherPlantID)

        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: tasks)

        XCTAssertEqual(rhythm.intervals.map(\.days), [8, 8, 7])
    }

    func testOtherCareKindsAreNotWaterings() {
        var tasks = waterings(daysAgo: [30, 22, 14, 7])
        tasks += [task(kind: .prune, daysAgo: 18), task(kind: .inspectSoil, daysAgo: 10)]

        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: tasks)

        XCTAssertEqual(rhythm.intervals.map(\.days), [8, 8, 7])
    }

    func testUncompletedWateringsAreNotHistory() {
        var tasks = waterings(daysAgo: [30, 22, 14, 7])
        tasks.append(task(kind: .water, daysAgo: -4, isCompleted: false))

        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: tasks)

        XCTAssertEqual(rhythm.waterings.count, 4)
        XCTAssertEqual(rhythm.intervals.map(\.days), [8, 8, 7])
    }

    func testTwoWateringsOnTheSameDayAreOneEventRatherThanAZeroDayGap() {
        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: waterings(daysAgo: [20, 13, 13, 6]))

        XCTAssertEqual(rhythm.intervals.map(\.days), [7, 7])
    }

    // MARK: - The typical gap

    func testTypicalGapIsTheMedianSoOneHolidayCannotMoveIt() {
        // Seven-day rhythm with a 40-day gap in the middle. The mean is 13; no
        // watering ever happened on that rhythm.
        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: waterings(daysAgo: [75, 68, 61, 21, 14, 7]))

        XCTAssertEqual(rhythm.intervals.map(\.days), [7, 7, 40, 7, 7])
        XCTAssertEqual(rhythm.typicalDays, 7)
    }

    // MARK: - Not enough to say anything

    func testTwoWateringsIsAnAnecdoteRatherThanARhythm() {
        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: waterings(daysAgo: [14, 7]))

        XCTAssertEqual(rhythm.intervals.count, 1)
        XCTAssertFalse(rhythm.isReadable)
    }

    func testThreeGapsIsTheBarForShowingTheChart() {
        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: waterings(daysAgo: [28, 21, 14, 7]))

        XCTAssertEqual(rhythm.intervals.count, 3)
        XCTAssertTrue(rhythm.isReadable)
    }

    func testNoWateringsAtAllIsEmptyRatherThanZero() {
        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: [])

        XCTAssertTrue(rhythm.waterings.isEmpty)
        XCTAssertTrue(rhythm.intervals.isEmpty)
        XCTAssertNil(rhythm.typicalDays)
        XCTAssertNil(rhythm.daysSinceLast)
        XCTAssertFalse(rhythm.isReadable)
        XCTAssertEqual(rhythm.drift, .steady)
    }

    // MARK: - Drift, and refusing to invent it

    func testASteadyRhythmIsReportedAsSteady() {
        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: waterings(daysAgo: [42, 35, 28, 21, 14, 7]))

        XCTAssertEqual(rhythm.drift, .steady)
    }

    func testSmallWobbleIsNotReportedAsASeasonChanging() {
        // 7, 8, 7, 9, 8 — noise, not autumn.
        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: waterings(daysAgo: [39, 32, 24, 17, 8, 0]))

        XCTAssertEqual(rhythm.drift, .steady)
    }

    func testGapsGettingLongerReadsAsSlowing() {
        // Roughly weekly, then roughly fortnightly.
        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: waterings(daysAgo: [63, 56, 49, 42, 28, 14, 0]))

        XCTAssertEqual(rhythm.drift, .slowing(from: 7, to: 14))
    }

    func testGapsGettingShorterReadsAsQuickening() {
        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: waterings(daysAgo: [63, 49, 35, 21, 14, 7, 0]))

        XCTAssertEqual(rhythm.drift, .quickening(from: 14, to: 7))
    }

    // MARK: - Honesty about inferred dates

    func testARecordedCompletionIsNotMarkedApproximate() {
        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: waterings(daysAgo: [28, 21, 14, 7]))

        XCTAssertFalse(rhythm.hasApproximateIntervals)
        XCTAssertTrue(rhythm.intervals.allSatisfy { !$0.isApproximate })
    }

    func testAWateringDatedByItsReminderMarksItsGapsApproximate() {
        var tasks = waterings(daysAgo: [28, 14, 7])
        // A legacy row: ticked off before Grove recorded the moment.
        tasks.append(task(kind: .water, daysAgo: 21, completedAtIsRecorded: false))

        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: tasks)

        XCTAssertTrue(rhythm.hasApproximateIntervals)
        // The two gaps touching the inferred watering, and only those.
        XCTAssertEqual(rhythm.intervals.map(\.isApproximate), [true, true, false])
    }

    func testALateTickIsDatedWhenItHappenedNotWhenItWasDue() {
        // Due a fortnight ago, actually done three days ago.
        let due = Calendar.current.date(byAdding: .day, value: -14, to: .now)!
        let done = Calendar.current.date(byAdding: .day, value: -3, to: .now)!
        let late = CareTask(
            id: UUID(),
            plantID: Self.plantID,
            kind: .water,
            dueDate: due,
            detail: "",
            isCompleted: true,
            isSittingTask: false,
            ownerName: nil,
            completedAt: done
        )

        XCTAssertEqual(late.performedAt, done)
        XCTAssertFalse(late.dateIsInferred)

        let rhythm = WateringRhythm(plantID: Self.plantID, tasks: waterings(daysAgo: [31, 24, 17]) + [late])
        XCTAssertEqual(rhythm.intervals.map(\.days), [7, 7, 14])
        XCTAssertEqual(rhythm.daysSinceLast, 3)
    }

    // MARK: - Fixtures

    private func waterings(daysAgo: [Int], plantID: UUID? = nil) -> [CareTask] {
        daysAgo.map { task(kind: .water, daysAgo: $0, plantID: plantID) }
    }

    private func task(
        kind: CareKind,
        daysAgo: Int,
        plantID: UUID? = nil,
        isCompleted: Bool = true,
        completedAtIsRecorded: Bool = true
    ) -> CareTask {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        return CareTask(
            id: UUID(),
            plantID: plantID ?? Self.plantID,
            kind: kind,
            dueDate: date,
            detail: "",
            isCompleted: isCompleted,
            isSittingTask: false,
            ownerName: nil,
            completedAt: isCompleted && completedAtIsRecorded ? date : nil
        )
    }
}
