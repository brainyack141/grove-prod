import XCTest
@testable import Grove

/// Pins the retirement of the recurring soil check.
///
/// "Feel the dirt" used to be a care ritual with its own cadence, reminders and
/// reading. It was retired in db7c561: a photo check-in already carries a soil
/// observation, so adoption now schedules the first photo check-in instead and
/// `GroveStore.rescheduleSoilCheck` only clears open soil checks. These tests
/// exist so the retired task cannot quietly start being scheduled again, and so
/// a soil check already in someone's grove still decodes, completes and counts.
@MainActor
final class SoilCheckCadenceTests: XCTestCase {

    // MARK: - Helpers

    private func openSoilChecks(_ store: GroveStore, for plantID: UUID) -> [CareTask] {
        store.tasks.filter { $0.plantID == plantID && $0.kind == .inspectSoil && !$0.isCompleted }
    }

    /// An open soil check of the kind a grove might still hold from before the
    /// retirement.
    private func legacySoilCheck(for plantID: UUID, sitter: String? = nil) -> CareTask {
        CareTask(
            id: UUID(),
            plantID: plantID,
            kind: .inspectSoil,
            dueDate: .now,
            detail: GroveStore.soilCheckDetail,
            isCompleted: false,
            isSittingTask: sitter != nil,
            ownerName: sitter
        )
    }

    // MARK: - Adoption

    func testAddingAPlantSchedulesNoSoilCheck() {
        let store = GroveStore(plants: [], persistenceEnabled: false)

        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        XCTAssertTrue(
            openSoilChecks(store, for: plant.id).isEmpty,
            "The recurring soil check is retired; adoption must not schedule one"
        )
    }

    func testAdoptionSchedulesAPhotoCheckInInstead() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        let checkIn = try XCTUnwrap(
            store.tasks.first { $0.plantID == plant.id && $0.kind == .checkIn && !$0.isCompleted },
            "Adoption must still leave the plant something in the care queue"
        )
        XCTAssertGreaterThanOrEqual(checkIn.dueDate, Calendar.current.startOfDay(for: .now))
    }

    // MARK: - Care no longer schedules one

    func testCareSchedulesNoSoilCheck() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        store.logCare(plantID: plant.id, kind: .inspectSoil)
        store.logCare(plantID: plant.id, kind: .water, force: true)
        store.applyCheckIn(plantID: plant.id, score: 84, band: .healthy, note: "Looking well.")

        XCTAssertTrue(
            openSoilChecks(store, for: plant.id).isEmpty,
            "Logging care or checking in must never schedule the retired soil check"
        )
    }

    // MARK: - Legacy soil checks

    func testWateringClearsALegacyOpenSoilCheck() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.tasks.append(legacySoilCheck(for: plant.id))

        store.logCare(plantID: plant.id, kind: .water, force: true)

        XCTAssertTrue(openSoilChecks(store, for: plant.id).isEmpty)
    }

    func testCheckingInClearsALegacyOpenSoilCheck() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.tasks.append(legacySoilCheck(for: plant.id))

        store.applyCheckIn(plantID: plant.id, score: 84, band: .healthy, note: "Looking well.")

        XCTAssertTrue(openSoilChecks(store, for: plant.id).isEmpty)
    }

    func testALegacySoilCheckCanStillBeCompletedAndSchedulesNoSuccessor() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let legacy = legacySoilCheck(for: plant.id)
        store.tasks.append(legacy)

        let completed = try XCTUnwrap(store.complete(taskID: legacy.id))

        XCTAssertTrue(completed.isCompleted)
        XCTAssertTrue(openSoilChecks(store, for: plant.id).isEmpty, "Completing one must not schedule the next")
    }

    func testCompletingALegacySoilCheckStillCountsTowardTheStreak() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let legacy = legacySoilCheck(for: plant.id)
        store.tasks.append(legacy)

        store.complete(taskID: legacy.id)

        XCTAssertTrue(
            store.streakCountedToday,
            "Inspection still tends the streak, so a legacy soil check completed today counts"
        )
    }

    func testASittersSoilCheckIsLeftForTheSitter() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let sittersCheck = legacySoilCheck(for: plant.id, sitter: "Maya")
        store.tasks.append(sittersCheck)

        store.logCare(plantID: plant.id, kind: .water, force: true)

        let remaining = try XCTUnwrap(openSoilChecks(store, for: plant.id).first)
        XCTAssertEqual(remaining.id, sittersCheck.id, "A sitter's week must not be rewritten by the owner's care")
    }
}
