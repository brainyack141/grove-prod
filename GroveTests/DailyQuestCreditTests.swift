import XCTest
@testable import Grove

/// Pins which action pays out which daily quest.
///
/// The board used to ask for a completed photo check-in every day while the
/// plant's own care plan said not to look again for a fortnight, and a soil
/// check paid out "tend" rather than "look". Whichever the player obeyed, the
/// other one marked them down. The split now mirrors the streak's own rule:
/// inspection is looking, everything else is tending.
@MainActor
final class DailyQuestCreditTests: XCTestCase {

    // MARK: - Helpers

    private func quest(_ store: GroveStore, _ id: String) -> DailyQuest? {
        store.dailyQuests.first { $0.id == id }
    }

    private func look(_ store: GroveStore) -> Int { quest(store, "q-look")?.current ?? -1 }
    private func tend(_ store: GroveStore) -> Int { quest(store, "q-tend")?.current ?? -1 }

    private func openSoilCheck(_ store: GroveStore, for plantID: UUID) -> CareTask? {
        store.tasks.first { $0.plantID == plantID && $0.kind == .inspectSoil && !$0.isCompleted }
    }

    /// A grove that already exists, so the board starts the day at zero rather
    /// than carrying the credit adoption grants.
    private func establishedGrove() -> (GroveStore, Plant, CareTask) {
        let plant = Plant(
            id: UUID(),
            nickname: "Pesto",
            species: "Swiss cheese plant",
            scientificName: "Monstera deliciosa",
            location: "Kitchen",
            lightPlacement: .bright,
            growingConditions: nil,
            healthScore: 80,
            healthBand: .healthy,
            trend: .stable,
            confidence: 85,
            nextCheckIn: Date.now.addingTimeInterval(9 * 24 * 60 * 60),
            symbol: "leaf.fill",
            palette: .fern,
            summary: "",
            positiveSigns: [],
            concerns: [],
            nextActions: []
        )
        let store = GroveStore(plants: [plant], persistenceEnabled: false)
        let check = CareTask(
            id: UUID(),
            plantID: plant.id,
            kind: .inspectSoil,
            dueDate: .now,
            detail: GroveStore.soilCheckDetail,
            isCompleted: false,
            isSittingTask: false,
            ownerName: nil
        )
        store.tasks.append(check)
        return (store, plant, check)
    }

    // MARK: - Looking

    func testCompletingASoilCheckCountsAsLookingNotTending() {
        let (store, _, check) = establishedGrove()
        let lookBefore = look(store)
        let tendBefore = tend(store)

        store.complete(taskID: check.id)

        XCTAssertEqual(look(store), lookBefore + 1, "Feeling the soil is the daily-scale look")
        XCTAssertEqual(tend(store), tendBefore, "It must not also pay out the tend quest")
    }

    func testHandLoggingASoilCheckAlsoCountsAsLooking() {
        let (store, plant, _) = establishedGrove()
        let lookBefore = look(store)

        store.logCare(plantID: plant.id, kind: .inspectSoil)

        XCTAssertEqual(
            look(store),
            lookBefore + 1,
            "The ticked task and the hand-logged one are the same act"
        )
    }

    /// The regression: yesterday this needed a full photo check-in, which the
    /// plant's own care plan said was nine days away.
    func testTheLookQuestIsFinishableWithASoilCheckAlone() throws {
        let (store, _, check) = establishedGrove()
        XCTAssertFalse(try XCTUnwrap(quest(store, "q-look")).isComplete, "The day starts unfinished")

        store.complete(taskID: check.id)

        XCTAssertTrue(
            try XCTUnwrap(quest(store, "q-look")).isComplete,
            "A soil check alone must be able to finish the day's look"
        )
    }

    // MARK: - Tending

    /// COPY.md: never a streak, badge, XP payout or celebration attached to
    /// watering, feeding or treating. The tend quest pays XP, so watering
    /// earns none of it.
    func testWateringCountsAsNeitherTendingNorLooking() {
        let (store, plant, _) = establishedGrove()
        let lookBefore = look(store)
        let tendBefore = tend(store)

        store.logCare(plantID: plant.id, kind: .water)

        XCTAssertEqual(tend(store), tendBefore, "Watering must never pay quest XP")
        XCTAssertEqual(
            look(store),
            lookBefore,
            "Watering must never count as looking, or the board rewards drowning plants"
        )
    }

    func testPruningCountsAsTending() {
        let (store, plant, _) = establishedGrove()
        let tendBefore = tend(store)

        store.logCare(plantID: plant.id, kind: .prune)

        XCTAssertEqual(tend(store), tendBefore + 1)
    }

    // MARK: - Check-ins

    func testACheckInCreditsTheLookQuestExactlyOnce() {
        let (store, plant, _) = establishedGrove()
        let lookBefore = look(store)

        store.applyCheckIn(plantID: plant.id, score: 84, band: .healthy, note: "Looking well.")

        XCTAssertEqual(
            look(store),
            lookBefore + 1,
            "`applyCheckIn` owns the credit; completing the task must not pay a second time"
        )
    }

    func testAddingAPlantStillCountsAsLooking() {
        let store = GroveStore(plants: [], persistenceEnabled: false)

        store.addPlant(nickname: "Pesto", location: "Kitchen")

        XCTAssertGreaterThanOrEqual(
            look(store),
            1,
            "Adopting a plant is a photo and a recorded baseline, which is a look"
        )
    }
}
