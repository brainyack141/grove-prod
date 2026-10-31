import XCTest
@testable import Grove

/// The watch bridge, tested from the phone's side: what goes onto the wire,
/// and what an action coming back does to the store.
@MainActor
final class WatchSyncTests: XCTestCase {
    private var scratchDefaults: UserDefaults!
    private var scratchSuiteName: String!

    override func setUp() {
        super.setUp()
        scratchSuiteName = "watch-sync-tests-\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: scratchSuiteName)
    }

    override func tearDown() {
        scratchDefaults.removePersistentDomain(forName: scratchSuiteName)
        super.tearDown()
    }

    private func makeService(store: GroveStore) -> WatchSyncService {
        let service = WatchSyncService(defaults: scratchDefaults)
        service.configure(store: store, syncEngine: nil, connectivity: nil)
        return service
    }

    // MARK: - Snapshot building

    func testSnapshotCarriesPlantsAndAllPendingTasks() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let overdue = CareTask(
            id: UUID(), plantID: plant.id, kind: .water,
            dueDate: .now.addingTimeInterval(-24 * 3600),
            detail: "Soil was dry two days running.",
            isCompleted: false, isSittingTask: false, ownerName: nil
        )
        let future = CareTask(
            id: UUID(), plantID: plant.id, kind: .rotate,
            dueDate: .now.addingTimeInterval(7 * 24 * 3600),
            detail: "", isCompleted: false, isSittingTask: false, ownerName: nil
        )
        store.tasks.append(contentsOf: [overdue, future])

        let snapshot = WatchSyncService.snapshot(from: store)

        XCTAssertEqual(snapshot.plants.map(\.id), store.plants.map(\.id))
        XCTAssertEqual(snapshot.plants.first?.nickname, "Pesto")
        XCTAssertEqual(
            snapshot.plants.first?.band,
            WatchHealthBand(rawValue: HealthBand(score: Plant.unassessedPlaceholderScore).rawValue)
        )
        XCTAssertTrue(snapshot.tasks.contains { $0.id == overdue.id })
        XCTAssertTrue(
            snapshot.tasks.contains { $0.id == future.id },
            "The Watch needs upcoming work so cached state can roll over at midnight"
        )
        XCTAssertFalse(snapshot.dueTasks().contains { $0.id == future.id })
        XCTAssertEqual(
            snapshot.tasks.first { $0.id == overdue.id }?.kind, .water
        )
    }

    func testSnapshotCarriesTheLastWatering() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let watered = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let neverWatered = store.addPlant(nickname: "Fern", location: "Hall")
        XCTAssertNotNil(store.logCare(plantID: watered.id, kind: .water))

        let snapshot = WatchSyncService.snapshot(from: store)

        XCTAssertNotNil(snapshot.plants.first { $0.id == watered.id }?.lastWateredAt)
        XCTAssertNil(snapshot.plants.first { $0.id == neverWatered.id }?.lastWateredAt)
    }

    func testSnapshotWithoutLastWateringStillDecodes() throws {
        let summary = WatchPlantSummary(
            id: UUID(), nickname: "Pesto", species: "Monstera", location: "Kitchen",
            healthScore: 72, band: .healthy, trend: .stable, nextCheckIn: .now,
            lastWateredAt: .now
        )
        let encoded = try JSONEncoder().encode(summary)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "lastWateredAt")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(WatchPlantSummary.self, from: stripped)

        XCTAssertNil(decoded.lastWateredAt)
        XCTAssertEqual(decoded.id, summary.id)
    }

    func testSnapshotDropsTasksForMissingPlants() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let orphan = CareTask(
            id: UUID(), plantID: UUID(), kind: .water,
            dueDate: .now.addingTimeInterval(-3600),
            detail: "", isCompleted: false, isSittingTask: false, ownerName: nil
        )
        store.tasks.append(orphan)

        let snapshot = WatchSyncService.snapshot(from: store)

        XCTAssertFalse(snapshot.tasks.contains { $0.id == orphan.id })
        XCTAssertEqual(snapshot.plants.map(\.id), [plant.id])
    }

    func testSnapshotOmitsPlantsThatAreNotActive() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let active = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let dormant = store.addPlant(nickname: "Fern", location: "Hall")
        let deceased = store.addPlant(nickname: "Basil", location: "Sill")
        // `lifecycleState` is a plain optional on `Plant`; there is no store
        // setter, so the test looks the plants up by id and mutates the
        // records directly.
        let dormantIndex = try XCTUnwrap(store.plants.firstIndex { $0.id == dormant.id })
        store.plants[dormantIndex].lifecycleState = .dormant
        let deceasedIndex = try XCTUnwrap(store.plants.firstIndex { $0.id == deceased.id })
        store.plants[deceasedIndex].lifecycleState = .deceased
        let dormantTask = CareTask(
            id: UUID(), plantID: dormant.id, kind: .water,
            dueDate: .now.addingTimeInterval(-24 * 3600),
            detail: "", isCompleted: false, isSittingTask: false, ownerName: nil
        )
        let activeTask = CareTask(
            id: UUID(), plantID: active.id, kind: .water,
            dueDate: .now.addingTimeInterval(-24 * 3600),
            detail: "", isCompleted: false, isSittingTask: false, ownerName: nil
        )
        store.tasks.append(contentsOf: [dormantTask, activeTask])

        let snapshot = WatchSyncService.snapshot(from: store)

        XCTAssertEqual(snapshot.plants.map(\.id), [active.id])
        XCTAssertFalse(
            snapshot.plants.contains { $0.id == dormant.id || $0.id == deceased.id },
            "A plant that no longer receives care reminders must not appear on the wrist"
        )
        XCTAssertEqual(
            Set(snapshot.tasks.map(\.plantID)), [active.id],
            "Open tasks for a non-active plant are dropped exactly like tasks for a deleted plant"
        )
        XCTAssertTrue(snapshot.tasks.contains { $0.id == activeTask.id })
        XCTAssertFalse(snapshot.tasks.contains { $0.id == dormantTask.id })
    }

    func testSnapshotSurvivesTheWire() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        _ = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let sent = WatchSyncService.snapshot(from: store)

        let context = try sent.applicationContext()
        let received = WatchSnapshot(applicationContext: context)

        XCTAssertEqual(received, sent)
    }

    func testWireRejectsAnIncompatibleSchema() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let sent = WatchSyncService.snapshot(from: store)
        var context = try sent.applicationContext()
        context[WatchSyncSchema.versionKey] = WatchSyncSchema.version - 1

        XCTAssertNil(WatchSnapshot(applicationContext: context))
    }

    func testWatchCareKindsStayInLockstepWithPhoneKinds() {
        XCTAssertEqual(
            Set(WatchCareKind.allCases.map(\.rawValue)),
            Set(CareKind.allCases.map(\.rawValue))
        )
        XCTAssertEqual(
            WatchCareKind.loggable.map(\.rawValue),
            CareKind.loggable.map(\.rawValue)
        )
    }

    // MARK: - Actions from the watch

    func testCompleteTaskActionCompletesTheTask() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let task = CareTask(
            id: UUID(), plantID: plant.id, kind: .inspectSoil,
            dueDate: .now, detail: "",
            isCompleted: false, isSittingTask: false, ownerName: nil
        )
        store.tasks.append(task)
        let service = makeService(store: store)
        let summary = WatchTaskSummary(
            id: task.id, plantID: plant.id, kind: .inspectSoil,
            dueDate: task.dueDate, detail: task.detail, isSittingTask: false
        )

        XCTAssertTrue(service.apply(.completeTask(summary)))

        XCTAssertEqual(store.task(id: task.id)?.isCompleted, true)
    }

    func testWatchCannotCompleteAPhotoCheckInTask() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let task = CareTask(
            id: UUID(), plantID: plant.id, kind: .checkIn,
            dueDate: .now, detail: "Take a photo",
            isCompleted: false, isSittingTask: false, ownerName: nil
        )
        store.tasks.append(task)
        let service = makeService(store: store)
        let summary = WatchTaskSummary(
            id: task.id, plantID: plant.id, kind: .checkIn,
            dueDate: task.dueDate, detail: task.detail, isSittingTask: false
        )

        XCTAssertFalse(service.apply(.completeTask(summary)))
        XCTAssertEqual(store.task(id: task.id)?.isCompleted, false)
        XCTAssertTrue(store.observations(for: plant.id).isEmpty)
    }

    func testWatchCompletionKeepsThePerformedTime() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let task = CareTask(
            id: UUID(), plantID: plant.id, kind: .rotate,
            dueDate: .now.addingTimeInterval(-86_400), detail: "",
            isCompleted: false, isSittingTask: false, ownerName: nil
        )
        store.tasks.append(task)
        let service = makeService(store: store)
        let performedAt = Date.now.addingTimeInterval(-3_600)
        let summary = WatchTaskSummary(
            id: task.id, plantID: plant.id, kind: .rotate,
            dueDate: task.dueDate, detail: task.detail, isSittingTask: false
        )

        XCTAssertTrue(service.apply(.completeTask(summary, at: performedAt)))

        XCTAssertEqual(try XCTUnwrap(store.task(id: task.id)?.completedAt).timeIntervalSince1970,
                       performedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testReplayedActionIsDroppedNotAppliedTwice() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let service = makeService(store: store)
        let action = WatchCareAction.logCare(plantID: plant.id, careKind: .water)
        let baseline = store.tasks.count

        XCTAssertTrue(service.apply(action))
        XCTAssertFalse(service.apply(action), "The same transfer redelivered must be recognised")

        XCTAssertEqual(
            store.tasks.count, baseline + 1,
            "A replayed watering must not water the record twice"
        )
    }

    func testLogCareActionWritesACompletedLog() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let service = makeService(store: store)

        XCTAssertTrue(service.apply(.logCare(plantID: plant.id, careKind: .prune)))

        let logged = store.tasks.first { $0.kind == .prune && $0.plantID == plant.id }
        XCTAssertEqual(logged?.isCompleted, true)
        XCTAssertTrue(
            store.activity.contains { $0.plantID == plant.id && $0.message.contains("pruning") },
            "Wrist care earns the same attributed history as phone care"
        )
    }

    func testWatchLogKeepsThePerformedTime() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let service = makeService(store: store)
        let performedAt = Date.now.addingTimeInterval(-7_200)

        XCTAssertTrue(service.apply(.logCare(plantID: plant.id, careKind: .repot, at: performedAt)))

        let logged = try XCTUnwrap(store.tasks.first { $0.kind == .repot && $0.plantID == plant.id })
        XCTAssertEqual(logged.performedAt.timeIntervalSince1970, performedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRecentWateringIsRejectedInsteadOfSilentlyDuplicated() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let service = makeService(store: store)
        XCTAssertNotNil(store.logCare(plantID: plant.id, kind: .water))
        let baseline = store.tasks.count

        XCTAssertFalse(service.apply(.logCare(plantID: plant.id, careKind: .water)))
        XCTAssertEqual(store.tasks.count, baseline)
    }

    func testWatchCompletingAWateringRightAfterOneIsRejected() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        XCTAssertNotNil(store.logCare(plantID: plant.id, kind: .water))
        let task = CareTask(
            id: UUID(), plantID: plant.id, kind: .water,
            dueDate: .now, detail: "Water it.",
            isCompleted: false, isSittingTask: false, ownerName: nil
        )
        store.tasks.append(task)
        let service = makeService(store: store)
        let summary = WatchTaskSummary(
            id: task.id, plantID: plant.id, kind: .water,
            dueDate: task.dueDate, detail: task.detail, isSittingTask: false
        )

        XCTAssertFalse(service.apply(.completeTask(summary)))
        XCTAssertEqual(store.task(id: task.id)?.isCompleted, false)
    }

    func testCheckInCanNeverBeLoggedFromTheWrist() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let service = makeService(store: store)

        XCTAssertFalse(
            service.apply(.logCare(plantID: plant.id, careKind: .checkIn)),
            "A check-in needs the guided photo flow; the watch may not fake one"
        )
    }

    func testActionForUnknownPlantIsRejected() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        _ = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let service = makeService(store: store)

        XCTAssertFalse(service.apply(.logCare(plantID: UUID(), careKind: .water)))
    }
}
