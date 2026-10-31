import XCTest
@testable import Grove

/// The streak sheet is the only place Grove writes its streak rules down, so
/// what it claims has to stay tied to what `recordTend` actually does.
@MainActor
final class StreakSummaryTests: XCTestCase {
    private func store(streak: Int, longest: Int? = nil, shields: Int = 0, lastTendDaysAgo: Int?) -> GroveStore {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        store.gardener.currentStreak = streak
        store.gardener.longestStreak = longest ?? streak
        store.gardener.streakShields = shields
        store.gardener.lastTendDay = lastTendDaysAgo.flatMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: .now)
        }
        return store
    }

    func testWeekMarksTheDaysInTheRunAndLeavesTodayPending() {
        let summary = store(streak: 3, lastTendDaysAgo: 1).streakSummary

        XCTAssertEqual(summary.week.count, 7)
        XCTAssertEqual(summary.week.last?.state, .pending, "Today is still open when the last tend was yesterday")
        XCTAssertTrue(summary.week.last?.isToday == true)
        XCTAssertEqual(
            summary.week.filter { $0.state == .kept }.count,
            3,
            "A three-day run ending yesterday fills exactly three days"
        )
        XCTAssertEqual(summary.week.prefix(3).filter { $0.state == .missed }.count, 3)
    }

    func testTodayReadsAsKeptOnceItHasCounted() {
        let summary = store(streak: 4, lastTendDaysAgo: 0).streakSummary

        XCTAssertTrue(summary.countedToday)
        XCTAssertEqual(summary.week.last?.state, .kept)
        XCTAssertTrue(summary.status.contains("Come back tomorrow"))
    }

    func testAShieldedLapseHoldsYesterdayRatherThanBreakingTheRow() {
        let summary = store(streak: 8, shields: 1, lastTendDaysAgo: 2).streakSummary

        XCTAssertTrue(summary.isShielded)
        XCTAssertEqual(summary.current, 8, "A banked shield keeps the run standing through one missed day")
        XCTAssertEqual(summary.week.last?.state, .pending)
        XCTAssertEqual(summary.week.dropLast().last?.state, .shielded)
        XCTAssertEqual(summary.badge?.text, "Shield in use")
    }

    func testALapsedRunReportsZeroAndPointsAtTheBestRun() {
        let summary = store(streak: 5, longest: 11, shields: 0, lastTendDaysAgo: 4).streakSummary

        XCTAssertEqual(summary.current, 0)
        XCTAssertFalse(summary.week.contains { $0.state == .kept }, "Nothing is kept once the run has lapsed")
        XCTAssertTrue(summary.status.contains("11 days"))
    }

    func testNextShieldLandsOnTheNextSeventhDayOfTheRun() {
        XCTAssertEqual(store(streak: 0, lastTendDaysAgo: nil).streakSummary.nextShieldDay, 7)
        XCTAssertEqual(store(streak: 3, lastTendDaysAgo: 0).streakSummary.nextShieldDay, 7)
        XCTAssertEqual(store(streak: 7, lastTendDaysAgo: 0).streakSummary.nextShieldDay, 14)
        XCTAssertEqual(store(streak: 13, lastTendDaysAgo: 0).streakSummary.nextShieldDay, 14)
    }

    func testAFirstTimeGardenerIsToldWhatStartsAStreak() {
        let summary = store(streak: 0, longest: 0, lastTendDaysAgo: nil).streakSummary

        XCTAssertEqual(summary.current, 0)
        XCTAssertNil(summary.badge, "There is no state worth chipping when nothing has happened yet")
        XCTAssertTrue(summary.status.contains("Check in on any plant"))
    }

    /// The summary is a readout, not a mutation — opening the sheet must never
    /// be the thing that advances or resets a streak.
    func testReadingTheSummaryLeavesTheStreakAlone() {
        let subject = store(streak: 6, shields: 2, lastTendDaysAgo: 1)

        _ = subject.streakSummary

        XCTAssertEqual(subject.gardener.currentStreak, 6)
        XCTAssertEqual(subject.gardener.streakShields, 2)
        XCTAssertEqual(subject.displayStreak, 6)
    }
}
