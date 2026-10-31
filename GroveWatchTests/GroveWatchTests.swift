import XCTest
@testable import GroveWatch

final class GroveWatchTests: XCTestCase {
    func testUpcomingTaskBecomesDueFromCachedSnapshot() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30, hour: 10)))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let task = WatchTaskSummary(
            id: UUID(),
            plantID: UUID(),
            kind: .fertilise,
            dueDate: tomorrow,
            detail: "",
            isSittingTask: false
        )
        let snapshot = WatchSnapshot(
            generatedAt: today,
            streak: 0,
            streakIsShielded: false,
            plants: [],
            tasks: [task]
        )

        XCTAssertTrue(snapshot.dueTasks(at: today, calendar: calendar).isEmpty)
        XCTAssertEqual(snapshot.dueTasks(at: tomorrow, calendar: calendar).map(\.id), [task.id])
    }

    // MARK: - Today's empty state

    private func makeSnapshot(generatedAt: Date, plants: [WatchPlantSummary]) -> WatchSnapshot {
        WatchSnapshot(
            generatedAt: generatedAt,
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
            nextCheckIn: Date(timeIntervalSince1970: 1_800_100_000)
        )
    }

    func testEmptyStateWithNoSnapshotSaysNoPlants() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            WatchTodayEmptyState.resolve(snapshot: nil, now: now),
            .noPlants
        )
    }

    func testEmptyStateWithNoPlantsSaysNoPlantsEvenWhenFresh() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = makeSnapshot(generatedAt: now, plants: [])

        XCTAssertEqual(
            WatchTodayEmptyState.resolve(snapshot: snapshot, now: now),
            .noPlants
        )
    }

    func testEmptyStateWithPlantsAndRecentSnapshotSaysAllTended() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = makeSnapshot(
            generatedAt: now.addingTimeInterval(-2 * 3600),
            plants: [makePlant()]
        )

        XCTAssertEqual(
            WatchTodayEmptyState.resolve(snapshot: snapshot, now: now),
            .allTended
        )
    }

    func testEmptyStateWithStaleSnapshotSaysStale() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let generatedAt = now.addingTimeInterval(-30 * 3600)
        let snapshot = makeSnapshot(generatedAt: generatedAt, plants: [makePlant()])

        XCTAssertEqual(
            WatchTodayEmptyState.resolve(snapshot: snapshot, now: now),
            .stale(since: generatedAt)
        )
    }

    func testSnapshotRejectsAnIncompatibleWireVersion() throws {
        let snapshot = WatchSnapshot(
            generatedAt: .now,
            streak: 0,
            streakIsShielded: false,
            plants: [],
            tasks: []
        )
        var context = try snapshot.applicationContext()
        context[WatchSyncSchema.versionKey] = WatchSyncSchema.version - 1

        XCTAssertNil(WatchSnapshot(applicationContext: context))
    }

    func testReceiptRejectsAnIncompatibleWireVersion() throws {
        let action = WatchCareAction.logCare(plantID: UUID(), careKind: .repot)
        let receipt = WatchActionReceipt(action: action, outcome: .accepted, message: "Logged")
        var userInfo = try receipt.userInfo()
        userInfo[WatchSyncSchema.versionKey] = WatchSyncSchema.version - 1

        XCTAssertNil(WatchActionReceipt(userInfo: userInfo))
    }

    func testActionAndReceiptRoundTripWithoutLosingIdentity() throws {
        let performedAt = Date(timeIntervalSince1970: 1_788_080_400)
        let action = WatchCareAction.logCare(
            plantID: UUID(),
            careKind: .cleanLeaves,
            at: performedAt
        )
        let decodedAction = try XCTUnwrap(WatchCareAction(userInfo: action.userInfo()))
        XCTAssertEqual(decodedAction, action)

        let receipt = WatchActionReceipt(
            action: decodedAction,
            outcome: .rejected,
            message: "Try again"
        )
        let decodedReceipt = try XCTUnwrap(WatchActionReceipt(userInfo: receipt.userInfo()))
        XCTAssertEqual(decodedReceipt.actionID, action.id)
        XCTAssertEqual(decodedReceipt.plantID, action.plantID)
        XCTAssertEqual(decodedReceipt.careKind, .cleanLeaves)
        XCTAssertEqual(decodedReceipt.outcome, .rejected)
    }

    func testPhoneCanAcceptAnActionFromVersionOneDuringRollingUpdate() throws {
        let action = WatchCareAction.logCare(plantID: UUID(), careKind: .water)
        var userInfo = try action.userInfo()
        userInfo[WatchSyncSchema.versionKey] = 1

        XCTAssertEqual(WatchCareAction(userInfo: userInfo), action)

        userInfo[WatchSyncSchema.versionKey] = 0
        XCTAssertNil(WatchCareAction(userInfo: userInfo))
    }
}
