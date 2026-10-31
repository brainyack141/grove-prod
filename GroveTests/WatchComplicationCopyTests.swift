import XCTest
@testable import Grove

/// The Watch complication's copy, checked from the phone's test bundle. The
/// widget target and the app share `GroveWatchShared`, so these are the exact
/// words the rectangular and inline families draw.
final class WatchComplicationCopyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSnapshot(
        generatedAt: Date? = nil,
        plants: [WatchPlantSummary]
    ) -> WatchSnapshot {
        WatchSnapshot(
            generatedAt: generatedAt ?? now,
            streak: 0,
            streakIsShielded: false,
            plants: plants,
            tasks: []
        )
    }

    private func makePlant() -> WatchPlantSummary {
        WatchPlantSummary(
            id: UUID(),
            nickname: "Pesto",
            species: "Basil",
            location: "Kitchen",
            healthScore: 80,
            band: .healthy,
            trend: .stable,
            nextCheckIn: now.addingTimeInterval(86_400)
        )
    }

    func testNoSnapshotStillAsksForSync() {
        XCTAssertEqual(
            WatchComplicationCopy.primaryTitle(snapshot: nil, dueCount: 0, streak: 0, now: now),
            "Open Grove to sync"
        )
        XCTAssertEqual(
            WatchComplicationCopy.inlineTitle(snapshot: nil, dueCount: 0, streak: 0, now: now),
            "Open Grove to sync"
        )
    }

    func testEmptyGroveNeverSaysAllTended() {
        let snapshot = makeSnapshot(plants: [])

        XCTAssertEqual(
            WatchComplicationCopy.primaryTitle(snapshot: snapshot, dueCount: 0, streak: 0, now: now),
            "No plants yet"
        )
        XCTAssertEqual(
            WatchComplicationCopy.inlineTitle(snapshot: snapshot, dueCount: 0, streak: 8, now: now),
            "No plants yet",
            "A streak cannot make an empty grove tended"
        )
    }

    func testEmptyGroveStaysNoPlantsEvenWhenTheSnapshotIsStale() {
        let snapshot = makeSnapshot(
            generatedAt: now.addingTimeInterval(-30 * 3600),
            plants: []
        )

        XCTAssertEqual(
            WatchComplicationCopy.primaryTitle(snapshot: snapshot, dueCount: 0, streak: 0, now: now),
            "No plants yet"
        )
        XCTAssertEqual(
            WatchComplicationCopy.inlineTitle(snapshot: snapshot, dueCount: 0, streak: 0, now: now),
            "No plants yet"
        )
    }

    func testStaleSnapshotSaysSyncNeededRatherThanAllTended() {
        let snapshot = makeSnapshot(
            generatedAt: now.addingTimeInterval(-30 * 3600),
            plants: [makePlant()]
        )

        XCTAssertEqual(
            WatchComplicationCopy.primaryTitle(snapshot: snapshot, dueCount: 0, streak: 0, now: now),
            "Sync needed"
        )
        XCTAssertEqual(
            WatchComplicationCopy.inlineTitle(snapshot: snapshot, dueCount: 0, streak: 3, now: now),
            "0 care tasks due · sync needed"
        )
    }

    func testFreshTendedGroveUsesTheStreakOnlyInline() {
        let snapshot = makeSnapshot(
            generatedAt: now.addingTimeInterval(-2 * 3600),
            plants: [makePlant()]
        )

        XCTAssertEqual(
            WatchComplicationCopy.primaryTitle(snapshot: snapshot, dueCount: 0, streak: 8, now: now),
            "All tended"
        )
        XCTAssertEqual(
            WatchComplicationCopy.inlineTitle(snapshot: snapshot, dueCount: 0, streak: 8, now: now),
            "All tended · 8-day streak"
        )
        XCTAssertEqual(
            WatchComplicationCopy.inlineTitle(snapshot: snapshot, dueCount: 0, streak: 0, now: now),
            "All tended"
        )
    }

    func testDueWorkKeepsTheCountAndTheStaleSuffix() {
        let fresh = makeSnapshot(
            generatedAt: now.addingTimeInterval(-2 * 3600),
            plants: [makePlant()]
        )
        let stale = makeSnapshot(
            generatedAt: now.addingTimeInterval(-30 * 3600),
            plants: [makePlant()]
        )

        XCTAssertEqual(
            WatchComplicationCopy.primaryTitle(snapshot: fresh, dueCount: 3, streak: 4, now: now),
            "3 care tasks due"
        )
        XCTAssertEqual(
            WatchComplicationCopy.inlineTitle(snapshot: fresh, dueCount: 1, streak: 4, now: now),
            "1 care task due"
        )
        XCTAssertEqual(
            WatchComplicationCopy.inlineTitle(snapshot: stale, dueCount: 3, streak: 4, now: now),
            "3 care tasks due · sync needed"
        )
    }

    func testStaleThresholdMatchesTheWatchEmptyState() {
        let onThreshold = makeSnapshot(
            generatedAt: now.addingTimeInterval(-WatchTodayEmptyState.staleAfter),
            plants: [makePlant()]
        )
        let pastThreshold = makeSnapshot(
            generatedAt: now.addingTimeInterval(-WatchTodayEmptyState.staleAfter - 1),
            plants: [makePlant()]
        )

        XCTAssertFalse(
            WatchComplicationCopy.isStale(snapshot: onThreshold, now: now),
            "Exactly staleAfter is still fresh, matching WatchTodayEmptyState.resolve"
        )
        XCTAssertTrue(
            WatchComplicationCopy.isStale(snapshot: pastThreshold, now: now)
        )
    }
}
