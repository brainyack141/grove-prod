import XCTest
@testable import Grove

@MainActor
final class GroveStoreTests: XCTestCase {
    func testAddingPlantCreatesOwnedPlantAndFollowUpTask() {
        let store = GroveStore(plants: [], persistenceEnabled: false)

        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        XCTAssertEqual(store.plants.count, 1)
        XCTAssertEqual(plant.nickname, "Pesto")
        XCTAssertEqual(plant.location, "Kitchen")
        XCTAssertFalse(plant.hasHealthReading)
        XCTAssertEqual(plant.confidence, 0)
        XCTAssertNil(plant.assessmentDate)
        XCTAssertTrue(plant.concerns.isEmpty)
        XCTAssertTrue(store.tasks.contains { $0.plantID == plant.id && $0.kind == .checkIn })
    }

    func testAddingPlantWithoutAnalysisDoesNotInventAHealthReading() {
        let store = GroveStore(plants: [], persistenceEnabled: false)

        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        XCTAssertFalse(plant.hasHealthReading)
        XCTAssertEqual(plant.confidence, 0)
        XCTAssertNil(plant.assessmentDate)
        XCTAssertEqual(plant.assessmentSource, .offlineEstimate)
        XCTAssertTrue(plant.concerns.isEmpty)
        XCTAssertTrue(plant.positiveSigns.isEmpty)
        XCTAssertFalse(plant.summary.contains("yellowing"))
        XCTAssertNotEqual(plant.healthScore, 78)
        XCTAssertTrue(store.tasks.contains {
            $0.plantID == plant.id && $0.kind == .checkIn && !$0.isCompleted
        })
    }

    func testUnavailableAssessmentIsSavedUnassessed() async throws {
        var result = try await LocalPlantAnalysisClient(simulatedDelay: .zero)
            .analyse(imageData: Data([0x01]), mode: .diagnose)
        result.condition.assessmentAvailable = false
        let store = GroveStore(plants: [], persistenceEnabled: false)

        let plant = store.addPlant(nickname: "Fern", location: "Office", analysis: result)

        XCTAssertFalse(plant.hasHealthReading)
        XCTAssertEqual(plant.confidence, 0)
        XCTAssertNil(plant.assessmentDate)
    }

    func testAssessedAnalysisStillWritesItsReading() async throws {
        let result = try await LocalPlantAnalysisClient(simulatedDelay: .zero)
            .analyse(imageData: Data([0x01]), mode: .diagnose)
        let store = GroveStore(plants: [], persistenceEnabled: false)

        let plant = store.addPlant(nickname: "Fern", location: "Office", analysis: result)

        XCTAssertTrue(plant.hasHealthReading)
        XCTAssertEqual(plant.healthScore, result.condition.healthScore)
        XCTAssertEqual(plant.assessmentSource, .baselinePhoto)
    }

    func testCheckInGivesAnUnassessedPlantItsFirstReading() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        store.applyCheckIn(plantID: plant.id, score: 82, band: .healthy, note: "Clear photo")

        let updated = store.plant(id: plant.id)
        XCTAssertEqual(updated?.hasHealthReading, true)
        XCTAssertEqual(updated?.healthScore, 82)
    }

    func testOverallHealthIgnoresUnassessedPlants() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let assessed = store.addPlant(nickname: "Pesto", location: "Kitchen")
        _ = store.addPlant(nickname: "Fern", location: "Bedroom")

        store.applyCheckIn(plantID: assessed.id, score: 90, band: .thriving, note: "Thriving")

        XCTAssertEqual(store.overallHealth, 90)
    }

    func testUnassessedPlantCopyAsksForAPhoto() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        let copy = PlantAriReadCopy.make(
            plant: plant,
            read: .unassessed,
            hasCurrentEvidence: false,
            takeaway: nil
        )

        XCTAssertEqual(copy.headline, "Couldn't assess yet")
        XCTAssertFalse(PlantDetailView.hasCurrentEvidence(plant: plant, observations: []))
    }

    func testCheckInUpdatesHealthCompletesDueCheckInAndCreatesActivity() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let initialActivityCount = store.activity.count

        store.applyCheckIn(
            plantID: plant.id,
            score: 86,
            band: .healthy,
            note: "New growth is visible."
        )

        let updated = store.plant(id: plant.id)
        XCTAssertEqual(updated?.healthScore, 86)
        XCTAssertEqual(updated?.trend, .baseline)
        XCTAssertEqual(updated?.summary, "New growth is visible.")
        let checkInTasks = store.tasks.filter { $0.plantID == plant.id && $0.kind == .checkIn }
        XCTAssertTrue(checkInTasks.contains(where: \.isCompleted), "The due check-in must be completed")
        let rescheduled = checkInTasks.filter { !$0.isCompleted }
        XCTAssertEqual(rescheduled.count, 1, "Check-ins recur: exactly one follow-up must be scheduled")
        XCTAssertEqual(rescheduled.first?.dueDate, updated?.nextCheckIn)
        XCTAssertEqual(store.activity.count, initialActivityCount + 1)
        XCTAssertEqual(store.observations(for: plant.id).count, 1)
        XCTAssertEqual(store.observations(for: plant.id).first?.previousScore, 86)
        XCTAssertEqual(store.observations(for: plant.id).first?.score, 86)
    }

    func testFirstReadingOfAnUnassessedPlantHasNoInventedTrend() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        store.applyCheckIn(plantID: plant.id, score: 90, band: .thriving, note: "First clear photo")

        XCTAssertEqual(store.plant(id: plant.id)?.trend, .baseline)
        XCTAssertEqual(store.observations(for: plant.id).first?.previousScore, 90)
    }

    func testSecondReadingStillComputesTheTrend() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        store.applyCheckIn(plantID: plant.id, score: 60, band: .monitor, note: "First reading")
        store.applyCheckIn(plantID: plant.id, score: 85, band: .healthy, note: "Second reading")

        XCTAssertEqual(store.plant(id: plant.id)?.trend, GroveStore.trend(from: 60, to: 85))
        XCTAssertEqual(store.observations(for: plant.id).first?.previousScore, 60)
    }

    func testAssessedPlantFirstCheckInKeepsItsDelta() async throws {
        let result = try await LocalPlantAnalysisClient(simulatedDelay: .zero)
            .analyse(imageData: Data([0x01]), mode: .add)
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Fern", location: "Office", analysis: result)

        store.applyCheckIn(plantID: plant.id, score: 90, band: .thriving, note: "Clear photo")

        XCTAssertEqual(
            store.observations(for: plant.id).first?.previousScore,
            result.condition.healthScore
        )
    }

    func testCarePlanStepsHaveARealLifecycleAndStayInSyncWithNextActions() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let first = PlantCarePlanAction(
            id: UUID(),
            kind: .relocate,
            instruction: "Move closer to the window",
            rationale: "Light is low.",
            dueFrom: .now,
            dueUntil: nil,
            expectedResponse: "Firmer new growth.",
            state: .due,
            completedAt: nil
        )
        let second = PlantCarePlanAction(
            id: UUID(),
            kind: .monitor,
            instruction: "Watch the newest leaf",
            rationale: "It is the clearest response.",
            dueFrom: .now,
            dueUntil: nil,
            expectedResponse: "No further browning.",
            state: .proposed,
            completedAt: nil
        )
        let plan = PlantCarePlan(
            id: UUID(),
            goal: "Improve the light response",
            actions: [first, second],
            startedAt: .now,
            reviewAt: nil,
            status: .active,
            outcome: nil
        )
        XCTAssertNotNil(
            store.updatePlantRecord(
                id: plant.id,
                lifecycleState: .active,
                acquiredAt: nil,
                notes: "",
                environmentReadings: [],
                carePlan: plan
            )
        )

        let completed = try XCTUnwrap(
            store.updateCarePlanAction(plantID: plant.id, actionID: first.id, state: .completed)
        )
        XCTAssertEqual(completed.carePlan?.actions.first?.state, .completed)
        XCTAssertNotNil(completed.carePlan?.actions.first?.completedAt)
        XCTAssertEqual(completed.nextActions, [second.instruction])

        let skipped = try XCTUnwrap(
            store.updateCarePlanAction(plantID: plant.id, actionID: second.id, state: .skipped)
        )
        XCTAssertTrue(skipped.nextActions.isEmpty)

        store.applyCheckIn(plantID: plant.id, score: 80, band: .healthy, note: "Responding well")
        XCTAssertNil(store.plant(id: plant.id)?.carePlan)
        XCTAssertEqual(store.plant(id: plant.id)?.carePlanHistory?.first?.status, .completed)
    }

    func testDisablingPlanClearsSuggestionsAndArchivesItAsAbandoned() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let action = PlantCarePlanAction(
            id: UUID(), kind: .monitor, instruction: "Watch the leaf", rationale: "",
            dueFrom: .now, dueUntil: nil, expectedResponse: "", state: .due, completedAt: nil
        )
        let plan = PlantCarePlan(
            id: UUID(), goal: "Watch recovery", actions: [action], startedAt: .now,
            reviewAt: nil, status: .active, outcome: nil
        )
        _ = store.updatePlantRecord(
            id: plant.id, lifecycleState: .active, acquiredAt: nil, notes: "",
            environmentReadings: [], carePlan: plan
        )

        let updated = try XCTUnwrap(
            store.updatePlantRecord(
                id: plant.id, lifecycleState: .active, acquiredAt: nil, notes: "",
                environmentReadings: [], carePlan: nil
            )
        )

        XCTAssertNil(updated.carePlan)
        XCTAssertTrue(updated.nextActions.isEmpty)
        XCTAssertEqual(updated.carePlanHistory?.first?.status, .abandoned)
    }

    func testUnresolvedPlanIsNotFalselyCompletedByCheckIn() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let action = PlantCarePlanAction(
            id: UUID(), kind: .monitor, instruction: "Watch the leaf", rationale: "",
            dueFrom: .now, dueUntil: nil, expectedResponse: "", state: .due, completedAt: nil
        )
        let plan = PlantCarePlan(
            id: UUID(), goal: "Watch recovery", actions: [action], startedAt: .now,
            reviewAt: nil, status: .active, outcome: nil
        )
        _ = store.updatePlantRecord(
            id: plant.id, lifecycleState: .active, acquiredAt: nil, notes: "",
            environmentReadings: [], carePlan: plan
        )

        store.applyCheckIn(plantID: plant.id, score: 80, band: .healthy, note: "Looked again")

        let archived = try XCTUnwrap(store.plant(id: plant.id)?.carePlanHistory?.first)
        XCTAssertEqual(archived.status, .abandoned)
        XCTAssertTrue(archived.outcome?.contains("before 1 plan step was resolved") == true)
    }

    func testDiagnosisAgesOutOfCurrentStateWithoutBeingDeletedFromHistory() throws {
        let seed = GroveStore(plants: [], persistenceEnabled: false)
        let plant = seed.addPlant(nickname: "Pesto", location: "Kitchen")
        let oldDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -31, to: .now))
        let diagnosis = PlantDiagnosis(
            id: UUID(),
            plantID: plant.id,
            createdAt: oldDate,
            summary: "An old concern.",
            healthBand: .attention,
            confidence: 80,
            possibleConditions: [],
            actionsToTake: [],
            actionsToAvoid: [],
            providerName: nil,
            identificationConfidence: nil,
            identificationRequiresConfirmation: nil,
            visiblePositiveSigns: nil,
            visibleConcerns: nil,
            clarifyingQuestions: nil,
            limitations: nil,
            photoURL: nil
        )
        let store = GroveStore(
            plants: [plant], tasks: [], observations: [], diagnoses: [diagnosis],
            persistenceEnabled: false
        )

        XCTAssertNil(store.currentDiagnosis(for: plant.id))
        XCTAssertEqual(store.diagnoses(for: plant.id), [diagnosis])
    }

    func testCreatingSittingAssignmentScopesSelectedPlantsAndCreatesActivity() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let first = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let second = store.addPlant(nickname: "Fern", location: "Bedroom")
        let initialActivityCount = store.activity.count

        store.createSittingAssignment(
            sitterName: "Maya Kapoor",
            startDate: .now,
            endDate: Calendar.current.date(byAdding: .day, value: 7, to: .now)!,
            plantIDs: [first.id]
        )

        let assignment = store.assignments.first
        XCTAssertEqual(assignment?.sitterName, "Maya Kapoor")
        XCTAssertEqual(assignment?.plantIDs, [first.id])
        XCTAssertFalse(assignment?.plantIDs.contains(second.id) ?? true)
        XCTAssertEqual(assignment?.status, .invited)
        XCTAssertEqual(store.activity.count, initialActivityCount + 1)
    }

    func testRemoteBootstrapReplacesAccountSnapshotAtomically() throws {
        let store = GroveStore(persistenceEnabled: false)
        let remotePlant = try XCTUnwrap(store.plants.last)
        let remoteProfile = UserProfile(name: "Remote Gardener", username: "remote", initials: "RG", friendCount: 3)
        // A grove the server has already vouched for in full. Without this the
        // starting plants read as never-uploaded work, which `replace(with:)`
        // deliberately refuses to delete — see the carry-across there. What is
        // under test here is the replacement itself, not that guard.
        store.replace(with: bootstrapResponse(profile: remoteProfile, plants: store.plants))
        let response = bootstrapResponse(profile: remoteProfile, plants: [remotePlant])

        store.replace(with: response)

        XCTAssertEqual(store.plants, [remotePlant])
        XCTAssertEqual(store.profile.name, remoteProfile.name)
        XCTAssertEqual(store.profile.username, remoteProfile.username)
        XCTAssertEqual(store.profile.friendCount, 0)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertTrue(store.observations.isEmpty)
        XCTAssertTrue(store.friends.isEmpty)
    }

    private func bootstrapResponse(profile: UserProfile, plants: [Plant]) -> GroveBootstrapResponse {
        GroveBootstrapResponse(
            profile: profile,
            plants: plants,
            tasks: [],
            activity: [],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now
        )
    }

    // MARK: - Bootstrap history windows

    private static let historyBase = Date(timeIntervalSince1970: 1_700_000_000)

    private func historyObservation(plantID: UUID, index: Int) -> PlantObservation {
        PlantObservation(
            id: UUID(),
            plantID: plantID,
            createdAt: Self.historyBase.addingTimeInterval(Double(index) * 3600),
            previousScore: 80,
            score: 82,
            band: .healthy,
            note: "",
            appearance: .same,
            soilMoisture: .comfortable,
            hasNewGrowth: false,
            photoURL: nil,
            actorName: "You"
        )
    }

    private func historyTask(plantID: UUID, index: Int) -> CareTask {
        let performed = Self.historyBase.addingTimeInterval(Double(index) * 3600)
        return CareTask(
            id: UUID(),
            plantID: plantID,
            kind: .water,
            dueDate: performed,
            detail: "",
            isCompleted: true,
            isSittingTask: false,
            ownerName: nil,
            completedAt: performed
        )
    }

    /// A legacy server caps observations at 500 and sends no completeness flag.
    /// Replacing the local list with that window deleted the 500 older check-ins
    /// on the phone — the Living Record, trends and export all lost history.
    func testTruncatedBootstrapKeepsOlderLocalCheckIns() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let local = (0..<1000).map { historyObservation(plantID: plant.id, index: $0) }
        store.observations = local

        let response = GroveBootstrapResponse(
            profile: store.profile,
            plants: [plant],
            tasks: [],
            activity: [],
            assignments: [],
            observations: Array(local.suffix(500)),
            friends: [],
            friendInvitations: [],
            serverTime: .now,
            observationsComplete: nil
        )

        XCTAssertTrue(store.replace(with: response))

        let forPlant = store.observations.filter { $0.plantID == plant.id }
        XCTAssertEqual(forPlant.count, 1000)
        XCTAssertEqual(Set(forPlant.map(\.id)).count, 1000, "Each check-in must survive exactly once")
    }

    /// A new server sends its newest window and says so. It is authoritative
    /// inside that window, so a check-in deleted elsewhere is not resurrected;
    /// everything strictly older than the window is kept.
    func testWindowedBootstrapKeepsOnlyOlderLocalCheckIns() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let local = (0..<1000).map { historyObservation(plantID: plant.id, index: $0) }
        let deletedElsewhere = historyObservation(plantID: plant.id, index: 1000)
        store.observations = local + [deletedElsewhere]

        let response = GroveBootstrapResponse(
            profile: store.profile,
            plants: [plant],
            tasks: [],
            activity: [],
            assignments: [],
            observations: Array(local.suffix(500)),
            friends: [],
            friendInvitations: [],
            serverTime: .now,
            observationsComplete: false
        )

        XCTAssertTrue(store.replace(with: response))

        let forPlant = store.observations.filter { $0.plantID == plant.id }
        let ids = Set(forPlant.map(\.id))
        XCTAssertEqual(forPlant.count, 1000)
        XCTAssertEqual(ids.count, 1000)
        XCTAssertFalse(ids.contains(deletedElsewhere.id), "Inside the window the server wins")
    }

    /// When the server says the history is complete, an absent local check-in
    /// was deleted elsewhere and must be dropped — today's behaviour.
    func testCompleteBootstrapStillReplacesCheckIns() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let local = (0..<1000).map { historyObservation(plantID: plant.id, index: $0) }
        store.observations = local

        let response = GroveBootstrapResponse(
            profile: store.profile,
            plants: [plant],
            tasks: [],
            activity: [],
            assignments: [],
            observations: Array(local.suffix(500)),
            friends: [],
            friendInvitations: [],
            serverTime: .now,
            observationsComplete: true
        )

        XCTAssertTrue(store.replace(with: response))

        let forPlant = store.observations.filter { $0.plantID == plant.id }
        XCTAssertEqual(forPlant.count, 500)
        XCTAssertEqual(Set(forPlant.map(\.id)), Set(local.suffix(500).map(\.id)))
    }

    /// Completed care is history too. A capped newest-first window must not
    /// delete the older completions the Living Record and watering rhythm use,
    /// while open tasks still come only from the server.
    func testTruncatedBootstrapKeepsOlderCompletedCare() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let local = (0..<6).map { historyTask(plantID: plant.id, index: $0) }
        let deletedElsewhere = historyTask(plantID: plant.id, index: 6)
        store.tasks = local + [deletedElsewhere]

        let response = GroveBootstrapResponse(
            profile: store.profile,
            plants: [plant],
            tasks: Array(local.suffix(3)),
            activity: [],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now,
            tasksComplete: false
        )

        XCTAssertTrue(store.replace(with: response))

        let completed = store.tasks.filter { $0.plantID == plant.id && $0.isCompleted }
        let ids = Set(completed.map(\.id))
        XCTAssertEqual(completed.count, 6)
        XCTAssertEqual(ids.count, 6)
        XCTAssertFalse(ids.contains(deletedElsewhere.id), "Newer-than-window care was deleted elsewhere")
        XCTAssertTrue(ids.isSuperset(of: local.prefix(3).map(\.id)), "Older completions must survive")
    }

    func testRemoteBootstrapKeepsActivityTheServerHasNoColumnFor() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.complete(taskID: try XCTUnwrap(store.tasks.first { $0.plantID == plant.id && $0.kind == .checkIn }).id)
        let completedTask = try XCTUnwrap(store.tasks.first { $0.plantID == plant.id && $0.isCompleted })
        let localEntry = try XCTUnwrap(store.activity.first)

        // The server mirrors check-ins and sitting invitations and nothing else,
        // so its copy of the feed arrives without the completion that was just
        // recorded. Replacing wholesale deleted it — along with every other
        // locally produced entry — on the first successful sync.
        let remoteEntry = ActivityEvent(
            id: UUID(),
            kind: .sitterCare,
            actorName: "Maya Kapoor",
            actorInitials: "MK",
            message: "watered Pesto",
            plantID: plant.id,
            timestamp: .now.addingTimeInterval(-60)
        )
        let response = GroveBootstrapResponse(
            profile: store.profile,
            plants: [plant],
            // The task itself *is* in the API contract, so it comes back — which
            // is what makes the stranding real: the task survived the sync while
            // the entry recording its completion did not.
            tasks: [completedTask],
            activity: [remoteEntry],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now
        )

        XCTAssertTrue(store.replace(with: response))
        XCTAssertTrue(store.activity.contains { $0.id == localEntry.id }, "Local-only activity must survive a sync")
        XCTAssertTrue(store.activity.contains { $0.id == remoteEntry.id }, "Remote activity must land")
        // Newest first, whichever side it came from.
        XCTAssertEqual(store.activity.map(\.id).first, localEntry.id)
        // And undo can still retract exactly the entry it recorded, rather than
        // pointing into a feed the sync had emptied.
        XCTAssertNotNil(store.undoCompletion(taskID: completedTask.id))
        XCTAssertFalse(store.activity.contains { $0.id == localEntry.id })
    }

    /// The watering card reasons from two facts the API has no endpoint for: the
    /// watering someone logged from the plant page, and the soil reading they
    /// felt on the spot. Both live only on this device, so both came back
    /// missing from every bootstrap — and a wholesale task replacement deleted
    /// them on the first successful sync, dropping the card back to arithmetic
    /// as if the user had never touched the plant.
    func testSelfLoggedCareSurvivesABootstrapThatCannotCarryIt() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let watered = try XCTUnwrap(store.logCare(plantID: plant.id, kind: .water))
        let felt = try XCTUnwrap(
            store.logCare(plantID: plant.id, kind: .inspectSoil, soilMoisture: .dry)
        )

        // What the API actually returns: the scheduled work, and nothing the
        // user logged here.
        XCTAssertTrue(store.replace(with: GroveBootstrapResponse(
            profile: store.profile,
            plants: [plant],
            tasks: [],
            activity: [],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now
        )))

        XCTAssertTrue(store.tasks.contains { $0.id == watered.id }, "A watering logged on this device must survive a sync")
        XCTAssertEqual(
            store.tasks.first(where: { $0.id == felt.id })?.soilMoisture,
            .dry,
            "The felt reading is the evidence the watering card rests on"
        )
    }

    /// Carrying local rows across must not resurrect work the server has
    /// deliberately dropped — only rows it was never told about.
    func testABootstrapCanStillDeleteATaskTheServerActuallyHad() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let serverTask = try XCTUnwrap(store.tasks.first(where: { $0.plantID == plant.id }))

        XCTAssertTrue(store.replace(with: GroveBootstrapResponse(
            profile: store.profile,
            plants: [plant],
            tasks: [],
            activity: [],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now
        )))

        XCTAssertFalse(store.tasks.contains { $0.id == serverTask.id })
    }

    func testActivityMergeDeduplicatesTheEntriesBothSidesWrite() {
        let sharedID = UUID()
        let local = ActivityEvent(
            id: sharedID,
            kind: .improvement,
            actorName: ActivityEvent.selfActorName,
            actorInitials: "AR",
            message: "checked in, now healthy at 86%",
            plantID: nil,
            timestamp: .now
        )
        let remote = ActivityEvent(
            id: sharedID,
            kind: .improvement,
            actorName: ActivityEvent.selfActorName,
            actorInitials: "AR",
            message: "checked in, now healthy at 86%",
            plantID: nil,
            timestamp: .now
        )

        // A check-in is written twice — once locally, once by the server — under
        // one id, so the feed reports it once.
        let merged = GroveStore.mergedActivity(local: [local], remote: [remote])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, sharedID)
    }

    func testActivityFeedStaysOrderedAndBounded() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let remote = (0..<(GroveStore.activityLimit + 30)).map { offset in
            ActivityEvent(
                id: UUID(),
                kind: .sitterCare,
                actorName: "Maya Kapoor",
                actorInitials: "MK",
                message: "watered something",
                plantID: nil,
                timestamp: .now.addingTimeInterval(-Double(offset) * 60)
            )
        }

        let merged = GroveStore.mergedActivity(local: store.activity, remote: remote)
        XCTAssertEqual(merged.count, GroveStore.activityLimit, "The feed has to stop somewhere")
        XCTAssertEqual(merged, merged.sorted { $0.timestamp > $1.timestamp })
    }

    func testUpdatesBadgeTracksOtherPeoplesActivityOnly() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        XCTAssertFalse(store.hasUnseenActivity, "A grove with nothing but your own actions in it has no news")

        store.logCare(plantID: plant.id, kind: .water)
        // Watering your own plant is not a notification. The bell used to badge
        // on due tasks, so it lit for work rather than news and could never be
        // cleared by reading anything.
        XCTAssertFalse(store.hasUnseenActivity)

        let response = GroveBootstrapResponse(
            profile: store.profile,
            plants: [plant],
            tasks: [],
            activity: [
                ActivityEvent(
                    id: UUID(),
                    kind: .sitterCare,
                    actorName: "Maya Kapoor",
                    actorInitials: "MK",
                    message: "watered Pesto",
                    plantID: plant.id,
                    timestamp: .now
                )
            ],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now
        )
        XCTAssertTrue(store.replace(with: response))
        XCTAssertTrue(store.hasUnseenActivity, "Someone else caring for your plant is news")

        // Opening Updates is what clears it, and it stays clear.
        store.markActivitySeen()
        XCTAssertFalse(store.hasUnseenActivity)
        store.logCare(plantID: plant.id, kind: .rotate)
        XCTAssertFalse(store.hasUnseenActivity, "Your own care must not relight the dot")
    }

    func testRemoteBootstrapWithNoPlantsCannotWipeALocalGrove() throws {
        let store = GroveStore(persistenceEnabled: false)
        let localPlants = store.plants
        XCTAssertFalse(localPlants.isEmpty)
        let amnesiacResponse = GroveBootstrapResponse(
            profile: UserProfile(name: "Remote Gardener", username: "remote", initials: "RG", friendCount: 0),
            plants: [],
            tasks: [],
            activity: [],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now
        )

        // The sync service holds account data in process memory, so any restart
        // hands back an empty account. Applying it would delete the user's
        // entire Grove.
        XCTAssertFalse(store.replace(with: amnesiacResponse))
        XCTAssertEqual(store.plants, localPlants)
        XCTAssertNotEqual(store.profile.name, "Remote Gardener")
    }

    func testRemoteBootstrapWithNoPlantsAppliesToAnEmptyLocalGrove() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let remoteProfile = UserProfile(name: "Remote Gardener", username: "remote", initials: "RG", friendCount: 0)
        let response = GroveBootstrapResponse(
            profile: remoteProfile,
            plants: [],
            tasks: [],
            activity: [],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now
        )

        // Nothing to lose here, so a genuinely empty account applies normally.
        XCTAssertTrue(store.replace(with: response))
        XCTAssertEqual(store.profile.name, "Remote Gardener")
    }

    func testRemoteBootstrapKeepsAJustChosenLocationOnlyWhenTheAccountHasNone() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let localLocation = GroveLocation(
            latitude: 51.4545,
            longitude: -2.5879,
            label: "Bristol, United Kingdom",
            countryCode: "GB",
            timeZoneIdentifier: "Europe/London"
        )
        store.updateGroveLocation(localLocation)
        let remoteWithoutLocation = UserProfile(
            name: "Remote Gardener",
            username: "remote",
            initials: "RG",
            friendCount: 0
        )

        XCTAssertTrue(store.replace(with: bootstrapResponse(profile: remoteWithoutLocation, plants: [])))
        XCTAssertEqual(store.profile.location, localLocation)

        let remoteLocation = GroveLocation(
            latitude: 47.6062,
            longitude: -122.3321,
            label: "Seattle, United States",
            countryCode: "US",
            timeZoneIdentifier: "America/Los_Angeles"
        )
        var remoteWithLocation = remoteWithoutLocation
        remoteWithLocation.location = remoteLocation

        XCTAssertTrue(store.replace(with: bootstrapResponse(profile: remoteWithLocation, plants: [])))
        XCTAssertEqual(store.profile.location, remoteLocation)
    }

    func testFriendInvitationCanBeSentAndIncomingRequestAccepted() throws {
        let store = GroveStore(persistenceEnabled: false)
        let initialFriendCount = store.friends.count
        let incoming = try XCTUnwrap(store.friendInvitations.first(where: { $0.direction == .incoming }))

        let outgoing = store.inviteFriend(username: "@newgrower")
        let duplicate = store.inviteFriend(username: "newgrower")
        store.acceptFriendInvitation(id: incoming.id)

        XCTAssertEqual(outgoing?.username, "newgrower")
        XCTAssertNil(duplicate)
        XCTAssertEqual(store.friends.count, initialFriendCount + 1)
        XCTAssertTrue(store.friends.contains { $0.username == incoming.username })
        XCTAssertFalse(store.friendInvitations.contains { $0.id == incoming.id })
    }

    func testFreeFriendAllowanceIncludesTwoSpotsAndPendingRequestsReserveOne() {
        XCTAssertTrue(
            GroveFriendAccess.hasAvailableSlot(
                friendCount: 1,
                reservedSlotCount: 0,
                hasPremiumAccess: false
            )
        )
        XCTAssertFalse(
            GroveFriendAccess.hasAvailableSlot(
                friendCount: 1,
                reservedSlotCount: 1,
                hasPremiumAccess: false
            )
        )
        XCTAssertFalse(
            GroveFriendAccess.hasAvailableSlot(
                friendCount: GroveFriendAccess.freeFriendLimit,
                reservedSlotCount: 0,
                hasPremiumAccess: false
            )
        )
        XCTAssertTrue(
            GroveFriendAccess.hasAvailableSlot(
                friendCount: GroveFriendAccess.freeFriendLimit,
                reservedSlotCount: 4,
                hasPremiumAccess: true
            )
        )
    }

    func testDemoFriendsMatchThePrivateProductionContract() {
        let store = GroveStore(persistenceEnabled: false)

        XCTAssertEqual(store.profile.friendCount, store.friends.count)
        XCTAssertTrue(store.friends.allSatisfy { $0.sharedPlantCount == 0 })
        XCTAssertTrue(store.friends.allSatisfy { $0.sharedPlants.isEmpty })
    }

    /// Accepting used to change local state only, which left the other gardener
    /// waiting forever on a request this device had already agreed to. The
    /// returned request is what the caller queues for the server, so a nil here
    /// means the friendship silently never becomes real.
    func testAnsweringAnInvitationReturnsTheMutationToSync() throws {
        let store = GroveStore(persistenceEnabled: false)
        let incoming = try XCTUnwrap(store.friendInvitations.first(where: { $0.direction == .incoming }))

        let accept = try XCTUnwrap(store.acceptFriendInvitation(id: incoming.id))
        XCTAssertEqual(accept.invitationID, incoming.id)
        XCTAssertTrue(accept.accept)

        // Already answered — nothing left to tell the server about.
        XCTAssertNil(store.acceptFriendInvitation(id: incoming.id))
    }

    func testAcceptingAStaleInvitationDoesNotDuplicateAnExistingFriend() throws {
        let store = GroveStore(persistenceEnabled: false)
        let incoming = try XCTUnwrap(store.friendInvitations.first(where: { $0.direction == .incoming }))
        store.friends.append(
            PlantFriend(
                id: incoming.accountID ?? "existing-account",
                name: incoming.name,
                username: incoming.username,
                initials: incoming.initials,
                sharedPlantCount: 0,
                lastActiveAt: .now
            )
        )
        let initialCount = store.friends.count

        let request = store.acceptFriendInvitation(id: incoming.id)

        XCTAssertNotNil(request, "the stale server row still needs an answer")
        XCTAssertEqual(store.friends.count, initialCount)
        XCTAssertFalse(store.friendInvitations.contains { $0.id == incoming.id })
    }

    func testDecliningRemovesTheInvitationWithoutAddingAFriend() throws {
        let store = GroveStore(persistenceEnabled: false)
        let incoming = try XCTUnwrap(store.friendInvitations.first(where: { $0.direction == .incoming }))
        let initialFriendCount = store.friends.count

        let decline = try XCTUnwrap(store.declineFriendInvitation(id: incoming.id))

        XCTAssertEqual(decline.invitationID, incoming.id)
        XCTAssertFalse(decline.accept)
        XCTAssertEqual(store.friends.count, initialFriendCount)
        XCTAssertFalse(store.friendInvitations.contains { $0.id == incoming.id })
    }

    /// The screen no longer records an invitation until the server has found
    /// the account, so everything this device *can* rule out has to come back
    /// as a problem rather than as a silent nil the sheet has to guess at.
    func testInviteProblemsCoverTheCasesThisDeviceCanSee() throws {
        let store = GroveStore(persistenceEnabled: false)
        let friend = try XCTUnwrap(store.friends.first)

        XCTAssertEqual(store.friendInviteProblem(for: "  @  "), .emptyUsername)
        XCTAssertEqual(store.friendInviteProblem(for: "@\(store.profile.username)"), .yourself)
        XCTAssertEqual(store.friendInviteProblem(for: friend.username.uppercased()), .alreadyFriends)
        XCTAssertNil(store.friendInviteProblem(for: "@somebodynew"))

        store.inviteFriend(username: "somebodynew")
        XCTAssertEqual(store.friendInviteProblem(for: "SomebodyNew"), .alreadyInvited)
    }

    /// A request you sent is yours to take back, and the other gardener has to
    /// stop seeing it — so a nil here means the invitation lives on for them
    /// after this device says it is gone.
    func testWithdrawingAnOutgoingInvitationReturnsTheMutationToSync() throws {
        let store = GroveStore(persistenceEnabled: false)
        let outgoing = try XCTUnwrap(store.inviteFriend(username: "faraway"))

        let withdraw = try XCTUnwrap(store.withdrawFriendInvitation(id: outgoing.id))

        XCTAssertEqual(withdraw.invitationID, outgoing.id)
        XCTAssertFalse(store.friendInvitations.contains { $0.id == outgoing.id })
        // The handle is free again the moment the row goes.
        XCTAssertNil(store.friendInviteProblem(for: "faraway"))
        // Already withdrawn — nothing left to tell the server about.
        XCTAssertNil(store.withdrawFriendInvitation(id: outgoing.id))
    }

    /// Withdrawing is the sender's move. An incoming request is declined, which
    /// is a different call and a different row change on the server.
    func testIncomingInvitationsCannotBeWithdrawn() throws {
        let store = GroveStore(persistenceEnabled: false)
        let incoming = try XCTUnwrap(store.friendInvitations.first(where: { $0.direction == .incoming }))

        XCTAssertNil(store.withdrawFriendInvitation(id: incoming.id))
        XCTAssertTrue(store.friendInvitations.contains { $0.id == incoming.id })
    }

    /// An outgoing invitation is the other gardener's to answer. Accepting your
    /// own request would manufacture a friendship the server would refuse.
    func testOutgoingInvitationsCannotBeAnswered() throws {
        let store = GroveStore(persistenceEnabled: false)
        let outgoing = try XCTUnwrap(store.inviteFriend(username: "faraway"))

        XCTAssertNil(store.acceptFriendInvitation(id: outgoing.id))
        XCTAssertNil(store.declineFriendInvitation(id: outgoing.id))
        XCTAssertTrue(store.friendInvitations.contains { $0.id == outgoing.id })
    }

    /// Ending a friendship updates the local count only after the server has
    /// confirmed the revocation. A sitting link is a separate bearer grant,
    /// so silently deleting it here would hide a still-working URL from the
    /// only screen that can revoke it.
    func testRemovingFriendUpdatesCountButLeavesSittingLinkForExplicitRevocation() throws {
        let store = GroveStore(persistenceEnabled: false)
        let friend = try XCTUnwrap(store.friends.first)
        let plant = try XCTUnwrap(store.plants.first)
        let link = store.createSittingInvite(
            sitterLabel: friend.name,
            startDate: .now,
            endDate: Calendar.current.date(byAdding: .day, value: 7, to: .now)!,
            plantIDs: [plant.id],
            canLogCare: true
        )
        store.attachShareURL(
            inviteID: link.id,
            url: URL(string: "https://grove.example/sit/friend-token")!
        )
        store.friendInvitations.append(
            FriendInvitation(
                id: UUID(),
                accountID: friend.id,
                name: friend.name,
                username: friend.username,
                initials: friend.initials,
                direction: .incoming,
                createdAt: .now
            )
        )
        let initialCount = store.friends.count

        let removed = try XCTUnwrap(store.removeFriend(id: friend.id))

        XCTAssertEqual(removed.id, friend.id)
        XCTAssertEqual(store.friends.count, initialCount - 1)
        XCTAssertEqual(store.profile.friendCount, store.friends.count)
        XCTAssertFalse(store.friendInvitations.contains { $0.accountID == friend.id })
        XCTAssertNotNil(store.sittingInvites.first { $0.id == link.id })
        XCTAssertTrue(store.sittingInvites.first { $0.id == link.id }?.isLive() == true)
        XCTAssertNil(store.removeFriend(id: friend.id), "a replay must not decrement the count twice")
    }

    func testEditingPlantAndRecordingScanPersistDomainChanges() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let result = PlantAnalysisResult(
            identification: PlantIdentificationResult(
                commonName: "Swiss cheese plant",
                scientificName: "Monstera deliciosa",
                confidence: 94,
                alternatives: [],
                distinguishingTraits: []
            ),
            condition: PlantConditionResult(
                healthScore: 83,
                healthBand: .healthy,
                confidence: 85,
                summary: "Healthy",
                positiveSigns: [],
                concerns: [],
                possibleCauses: [],
                nextActions: []
            ),
            providerName: "Test",
            limitations: []
        )
        let scanID = UUID()

        store.updatePlant(id: plant.id, nickname: "  Big Monty  ", location: "Garden", lightPlacement: .outdoors)
        store.recordScan(id: scanID, mode: .identify, result: result, photoURL: nil)
        store.recordScan(id: scanID, mode: .identify, result: result, photoURL: nil)

        XCTAssertEqual(store.plant(id: plant.id)?.nickname, "Big Monty")
        XCTAssertEqual(store.plant(id: plant.id)?.location, "Garden")
        XCTAssertEqual(store.scanHistory.count, 1)
        XCTAssertEqual(store.scanHistory.first?.id, scanID)
    }

    func testIdentityCorrectionDiagnosisTimelineAndHistoryDeletion() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Mystery", location: "Office")
        let candidate = SpeciesCandidate(
            id: "epipremnum-aureum",
            commonName: "Golden pothos",
            scientificName: "Epipremnum aureum",
            confidence: 88,
            distinguishingTraits: ["Trailing vine"],
            regionalFit: "Common indoors"
        )
        store.updatePlantIdentity(id: plant.id, candidate: candidate)
        XCTAssertEqual(store.plant(id: plant.id)?.scientificName, "Epipremnum aureum")

        let condition = PlantConditionCandidate(
            id: "excess-moisture",
            name: "Excess moisture stress",
            confidence: 68,
            explanation: "Lower leaves are yellowing.",
            evidence: ["Wet soil"],
            alternativeExplanation: "Normal ageing"
        )
        let result = PlantAnalysisResult(
            identification: PlantIdentificationResult(commonName: "Golden pothos", scientificName: "Epipremnum aureum", confidence: 88, alternatives: [], distinguishingTraits: []),
            condition: PlantConditionResult(
                healthScore: 64,
                healthBand: .monitor,
                confidence: 72,
                summary: "Check moisture before changing care.",
                positiveSigns: [],
                concerns: ["Yellow lower leaves"],
                possibleCauses: ["Excess moisture"],
                nextActions: ["Check soil"],
                possibleConditions: [condition],
                questions: [],
                actionsToAvoid: ["Do not water yet"]
            ),
            providerName: "Test",
            limitations: ["Visual only"]
        )
        let diagnosisID = UUID()
        let expectedFollowUp = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 7, to: .now))
        XCTAssertNotNil(
            store.addDiagnosis(
                id: diagnosisID,
                plantID: plant.id,
                result: result,
                photoURL: nil
            )
        )
        XCTAssertEqual(store.diagnoses(for: plant.id).first?.possibleConditions.first?.id, "excess-moisture")
        XCTAssertEqual(store.currentDiagnosis(for: plant.id)?.possibleConditions.first?.name, "Excess moisture stress")
        let updatedPlant = try XCTUnwrap(store.plant(id: plant.id))
        XCTAssertEqual(updatedPlant.healthBand, result.condition.healthBand)
        XCTAssertEqual(updatedPlant.summary, result.condition.summary)
        XCTAssertEqual(updatedPlant.concerns, result.condition.concerns)
        XCTAssertEqual(updatedPlant.nextActions, result.condition.nextActions)
        XCTAssertEqual(updatedPlant.nextCheckIn.timeIntervalSince(expectedFollowUp), 0, accuracy: 2)
        let recoveryTask = try XCTUnwrap(
            store.tasks.first(where: {
                $0.plantID == plant.id && $0.kind == .checkIn && !$0.isCompleted
            })
        )
        XCTAssertEqual(recoveryTask.dueDate.timeIntervalSince(expectedFollowUp), 0, accuracy: 2)

        // SwiftUI can recreate the result page, and clarifying answers can
        // refine the same scan. Re-applying its stable scan ID updates the
        // current record instead of duplicating the diagnosis, activity or
        // recovery task.
        var refinedResult = result
        refinedResult.condition.summary = "The soil evidence now strongly points to excess moisture."
        XCTAssertNotNil(
            store.addDiagnosis(
                id: diagnosisID,
                plantID: plant.id,
                result: refinedResult,
                photoURL: nil
            )
        )
        XCTAssertEqual(store.diagnoses(for: plant.id).count, 1)
        XCTAssertEqual(store.currentDiagnosis(for: plant.id)?.summary, refinedResult.condition.summary)
        XCTAssertEqual(
            store.tasks.filter {
                $0.plantID == plant.id && $0.kind == .checkIn && !$0.isCompleted
            }.count,
            1
        )
        XCTAssertEqual(store.activity.filter { $0.id == diagnosisID }.count, 1)

        // The diagnosis stays in history, but a later check-in becomes the
        // plant's live state and retires the old problem from the main page.
        XCTAssertNotNil(
            store.applyCheckIn(
                plantID: plant.id,
                score: 82,
                band: .healthy,
                note: "Recovered",
                observationID: UUID()
            )
        )
        XCTAssertNil(store.currentDiagnosis(for: plant.id))
        XCTAssertEqual(store.diagnoses(for: plant.id).count, 1)

        let scanID = UUID()
        store.recordScan(id: scanID, mode: .diagnose, result: result, photoURL: nil, plantID: plant.id)
        store.deleteScanHistory(ids: [scanID])
        XCTAssertFalse(store.scanHistory.contains { $0.id == scanID })
    }

    func testProvisionalDiagnosisIsSavedWithoutMutatingPlantOrCareQueue() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pip", location: "Desk")
        let before = try XCTUnwrap(store.plant(id: plant.id))
        let openTasksBefore = store.tasks.filter {
            $0.plantID == plant.id && !$0.isCompleted
        }
        let result = PlantAnalysisResult(
            identification: PlantIdentificationResult(
                commonName: "Golden pothos",
                scientificName: "Epipremnum aureum",
                confidence: 71,
                alternatives: [],
                distinguishingTraits: [],
                requiresConfirmation: true
            ),
            condition: PlantConditionResult(
                healthScore: 38,
                healthBand: .attention,
                confidence: 54,
                summary: "This needs another close look.",
                positiveSigns: [],
                concerns: ["A pale area is visible"],
                possibleCauses: ["Several causes remain possible"],
                nextActions: ["Take a symptom close-up"],
                followUpDays: 3,
                actionability: .provisional
            ),
            providerName: "Test",
            limitations: ["Visual only"]
        )

        let saved = try XCTUnwrap(
            store.addDiagnosis(plantID: plant.id, result: result, photoURL: nil)
        )
        let after = try XCTUnwrap(store.plant(id: plant.id))

        XCTAssertEqual(saved.actionability, .provisional)
        XCTAssertEqual(after.healthScore, before.healthScore)
        XCTAssertEqual(after.healthBand, before.healthBand)
        XCTAssertEqual(after.summary, before.summary)
        XCTAssertEqual(after.nextCheckIn, before.nextCheckIn)
        XCTAssertEqual(
            store.tasks.filter { $0.plantID == plant.id && !$0.isCompleted },
            openTasksBefore
        )
    }

    func testCompletingSittingCareUpdatesAssignmentAndAttributedActivity() throws {
        let store = GroveStore(persistenceEnabled: false)
        let task = try XCTUnwrap(store.tasks.first(where: { $0.isSittingTask }))
        let assignment = try XCTUnwrap(store.assignments.first(where: { $0.plantIDs.contains(task.plantID) }))
        let activityCount = store.activity.count

        let completed = store.complete(taskID: task.id)

        XCTAssertEqual(completed?.isCompleted, true)
        XCTAssertEqual(store.assignments.first(where: { $0.id == assignment.id })?.completedTasks, assignment.completedTasks + 1)
        XCTAssertEqual(store.activity.count, activityCount + 1)
        XCTAssertEqual(store.activity.first?.kind, .sitterCare)
        XCTAssertEqual(store.activity.first?.plantID, task.plantID)
        XCTAssertNil(store.complete(taskID: task.id), "Completing the same task twice must be idempotent locally")
    }

    // MARK: - Undoing a one-tap completion

    func testUndoingCompletionRestoresTheTaskAndRetractsItsActivity() throws {
        let store = GroveStore(persistenceEnabled: false)
        let task = try XCTUnwrap(store.tasks.first(where: { !$0.isCompleted && $0.kind != .checkIn }))
        let activityCount = store.activity.count
        XCTAssertNotNil(store.complete(taskID: task.id))
        XCTAssertEqual(store.activity.count, activityCount + 1)

        let restored = try XCTUnwrap(store.undoCompletion(taskID: task.id))

        XCTAssertFalse(restored.isCompleted)
        XCTAssertEqual(store.task(id: task.id)?.isCompleted, false)
        XCTAssertEqual(
            store.activity.count,
            activityCount,
            "A retracted completion must not leave care in the plant's history that never happened"
        )
        XCTAssertTrue(store.pendingTasks.contains { $0.id == task.id })
    }

    func testUndoingCompletionRollsBackSittingProgress() throws {
        let store = GroveStore(persistenceEnabled: false)
        let task = try XCTUnwrap(store.tasks.first(where: { $0.isSittingTask }))
        let assignment = try XCTUnwrap(store.assignments.first(where: { $0.plantIDs.contains(task.plantID) }))
        let completedBefore = assignment.completedTasks
        XCTAssertNotNil(store.complete(taskID: task.id))

        XCTAssertNotNil(store.undoCompletion(taskID: task.id))

        XCTAssertEqual(store.assignments.first(where: { $0.id == assignment.id })?.completedTasks, completedBefore)
    }

    func testUndoingAnIncompleteOrUnknownTaskChangesNothing() throws {
        let store = GroveStore(persistenceEnabled: false)
        let task = try XCTUnwrap(store.tasks.first(where: { !$0.isCompleted }))
        let activityCount = store.activity.count

        XCTAssertNil(store.undoCompletion(taskID: task.id), "An unfinished task has no completion to take back")
        XCTAssertNil(store.undoCompletion(taskID: UUID()))
        XCTAssertEqual(store.activity.count, activityCount)
    }

    // MARK: - Care logged outside a scheduled task

    func testLoggingCareRecordsACompletedActionAndAttributedActivity() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let activityCount = store.activity.count

        let logged = try XCTUnwrap(store.logCare(plantID: plant.id, kind: .water))

        XCTAssertTrue(logged.isCompleted)
        XCTAssertEqual(logged.kind, .water)
        XCTAssertFalse(logged.isSittingTask)
        XCTAssertFalse(
            store.pendingTasks.contains { $0.id == logged.id },
            "Logging care records something already done — it must not add work to the queue"
        )
        XCTAssertEqual(store.activity.count, activityCount + 1)
        XCTAssertEqual(store.activity.first?.plantID, plant.id)
        XCTAssertTrue(store.activity.first?.message.contains("watering") == true)
    }

    func testLoggedCareCanBeTakenBackLikeAnyOtherCompletion() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let activityCount = store.activity.count
        let logged = try XCTUnwrap(store.logCare(plantID: plant.id, kind: .prune, note: "Two brown leaves"))
        XCTAssertTrue(store.activity.first?.message.contains("Two brown leaves") == true)

        XCTAssertNotNil(store.undoCompletion(taskID: logged.id))

        XCTAssertEqual(store.activity.count, activityCount)
    }

    /// Care the user logged themselves has no queue to go back to. Flipping
    /// `isCompleted` left the row pending with a due date of the moment it was
    /// undone, so taking back a mistap put "Check soil" in Today — a chore Grove
    /// invented out of a tap the user had just retracted.
    func testUndoingSelfLoggedCareRemovesTheRowRatherThanQueueingIt() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let logged = try XCTUnwrap(
            store.logCare(plantID: plant.id, kind: .inspectSoil, note: "You felt the soil: damp.", soilMoisture: .comfortable)
        )

        XCTAssertNotNil(store.undoCompletion(taskID: logged.id))

        XCTAssertFalse(store.tasks.contains { $0.id == logged.id })
        XCTAssertFalse(
            store.dueTasks.contains { $0.id == logged.id },
            "Undoing a soil reading must not leave a chore behind in Today"
        )
    }

    /// The one place the streak *is* clawed back. The watering card logs a
    /// reading the instant a word is tapped, so its undo is the correction for a
    /// mistap — and a day cannot stand as tended on a reading that no longer
    /// exists.
    func testUndoingASelfLoggedSoilReadingRetractsTheStreakDayItMinted() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let streakBefore = store.displayStreak

        let logged = try XCTUnwrap(
            store.logCare(plantID: plant.id, kind: .inspectSoil, soilMoisture: .dry)
        )
        XCTAssertEqual(store.displayStreak, streakBefore + 1)

        XCTAssertNotNil(store.undoCompletion(taskID: logged.id))

        XCTAssertEqual(store.displayStreak, streakBefore)
    }

    /// Generosity still wins where the day was genuinely earned: a second
    /// reading that found the streak already tended took nothing, so taking it
    /// back gives nothing away.
    func testUndoingASecondReadingLeavesADayThatWasAlreadyTended() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        XCTAssertNotNil(store.logCare(plantID: plant.id, kind: .inspectSoil, soilMoisture: .dry))
        let tended = store.displayStreak

        let second = try XCTUnwrap(store.logCare(plantID: plant.id, kind: .inspectSoil, soilMoisture: .comfortable))
        XCTAssertNotNil(store.undoCompletion(taskID: second.id))

        XCTAssertEqual(store.displayStreak, tended, "The first reading tended the day and still stands")
    }

    func testLoggingWateringNeverAdvancesThePlantSafeStreak() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        XCTAssertNotNil(store.logCare(plantID: plant.id, kind: .water))

        XCTAssertEqual(
            store.displayStreak,
            0,
            "The streak must never reward watering, or it becomes an overwatering incentive"
        )

        XCTAssertNotNil(store.logCare(plantID: plant.id, kind: .inspectSoil))

        XCTAssertEqual(store.displayStreak, 1, "Inspection is the plant-safe way to tend the streak")
    }

    /// A scheduled WATER task is still a watering. The reminder cannot be
    /// ticked an hour after the plant was watered just because Grove scheduled
    /// it before that happened.
    func testCompletingAScheduledWateringRightAfterLoggingOneIsRefused() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        XCTAssertNotNil(store.logCare(plantID: plant.id, kind: .water))
        let task = CareTask(
            id: UUID(),
            plantID: plant.id,
            kind: .water,
            dueDate: .now,
            detail: "Water it.",
            isCompleted: false,
            isSittingTask: false,
            ownerName: nil
        )
        store.tasks.append(task)

        XCTAssertNil(store.complete(taskID: task.id))
        XCTAssertEqual(store.task(id: task.id)?.isCompleted, false)

        XCTAssertNotNil(store.complete(taskID: task.id, force: true))
    }

    /// A forced completion is still a completion: it has to stamp the tick's
    /// own time, or the plant's history loses the watering it was told about.
    func testForcedCompletionOfARecentWateringRecordsWhenItWasDone() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let wateredAt = Date.now.addingTimeInterval(-3_600)
        XCTAssertNotNil(store.logCare(plantID: plant.id, kind: .water, performedAt: wateredAt))
        let task = CareTask(
            id: UUID(),
            plantID: plant.id,
            kind: .water,
            dueDate: .now,
            detail: "Water it.",
            isCompleted: false,
            isSittingTask: false,
            ownerName: nil
        )
        store.tasks.append(task)

        XCTAssertNil(store.complete(taskID: task.id))
        XCTAssertEqual(store.task(id: task.id)?.isCompleted, false)

        let completed = try XCTUnwrap(store.complete(taskID: task.id, force: true))
        XCTAssertTrue(completed.isCompleted)
        XCTAssertNotNil(completed.completedAt)
    }

    func testCompletingAWateringWithNoRecentWateringSucceeds() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let task = CareTask(
            id: UUID(),
            plantID: plant.id,
            kind: .water,
            dueDate: .now,
            detail: "Water it.",
            isCompleted: false,
            isSittingTask: false,
            ownerName: nil
        )
        store.tasks.append(task)

        XCTAssertNotNil(store.complete(taskID: task.id))
        XCTAssertEqual(store.task(id: task.id)?.isCompleted, true)
    }

    func testCompletingANonWateringTaskIgnoresTheWateringGuard() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        XCTAssertNotNil(store.logCare(plantID: plant.id, kind: .water))
        let task = CareTask(
            id: UUID(),
            plantID: plant.id,
            kind: .fertilise,
            dueDate: .now,
            detail: "Feed it.",
            isCompleted: false,
            isSittingTask: false,
            ownerName: nil
        )
        store.tasks.append(task)

        XCTAssertNotNil(store.complete(taskID: task.id))
        XCTAssertEqual(store.task(id: task.id)?.isCompleted, true)
    }

    func testRecentWateringGuardAgreesWithTheStore() {
        XCTAssertEqual(RecentWateringGuard.window, GroveStore.recentWateringWindow)
        let now = Date.now
        XCTAssertFalse(RecentWateringGuard.isRecent(nil, now: now))
        XCTAssertTrue(RecentWateringGuard.isRecent(now.addingTimeInterval(-86_400), now: now))
        XCTAssertFalse(RecentWateringGuard.isRecent(now.addingTimeInterval(-4 * 86_400), now: now))
        XCTAssertFalse(RecentWateringGuard.isRecent(now.addingTimeInterval(3_600), now: now))
    }

    func testLoggingCareForAnUnknownPlantIsRejected() {
        let store = GroveStore(plants: [], persistenceEnabled: false)

        XCTAssertNil(store.logCare(plantID: UUID(), kind: .water))
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testSnoozingCareTaskReschedulesAndRecordsReason() throws {
        let store = GroveStore(persistenceEnabled: false)
        let task = try XCTUnwrap(store.tasks.first(where: { !$0.isCompleted }))
        let newDate = Date.now.addingTimeInterval(172_800)
        let activityCount = store.activity.count

        let snoozed = try XCTUnwrap(store.snooze(taskID: task.id, until: newDate, reason: "Soil is still moist"))

        XCTAssertEqual(snoozed.dueDate.timeIntervalSince1970, newDate.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(store.activity.count, activityCount + 1)
        XCTAssertTrue(store.activity.first?.message.contains("Soil is still moist") == true)
    }

    func testAccountActivationKeepsDemoAndAppleDataSeparate() throws {
        let suiteName = "GroveAccountTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let store = GroveStore(persistenceEnabled: true, storage: storage)
        let demo = UserSession(accountID: "demo-local-account", mode: .demo, displayName: "Alex")
        let apple = UserSession(accountID: "apple-user-123", mode: .apple, displayName: "Ari Green")

        store.activate(session: demo)
        _ = store.addPlant(nickname: "Demo Only", location: "Kitchen")
        XCTAssertTrue(store.plants.contains { $0.nickname == "Demo Only" })

        store.activate(session: apple)
        XCTAssertTrue(store.plants.isEmpty)
        // A fresh account is seeded with a usable handle instead of an empty
        // one, so My Grove never renders a bare "@".
        XCTAssertFalse(store.profile.username.isEmpty)
        XCTAssertTrue((3...24).contains(store.profile.username.count))
        XCTAssertTrue(store.profile.username.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        store.updateProfile(name: "Ari Green", username: "arigrows", regionCode: "GB", usesMetricSystem: true, isPrivate: true)
        _ = store.addPlant(nickname: "Apple Only", location: "Office")

        store.activate(session: demo)
        XCTAssertTrue(store.plants.contains { $0.nickname == "Demo Only" })
        XCTAssertFalse(store.plants.contains { $0.nickname == "Apple Only" })

        store.activate(session: apple)
        XCTAssertTrue(store.plants.contains { $0.nickname == "Apple Only" })
        XCTAssertFalse(store.plants.contains { $0.nickname == "Demo Only" })
        XCTAssertEqual(store.profile.username, "arigrows")
    }

    /// A sitting link is a working URL into someone's plants. It was the one
    /// collection `activate`, `installDemoFixtures` and `deleteAllLocalData` all
    /// forgot to clear, so it followed the previous account into the next one —
    /// leaking their plant list, and telling the new account its grove was
    /// already covered when nobody was watching it.
    func testSittingLinksNeverSurviveAnAccountChangeOrAWipe() throws {
        let suiteName = "GroveSittingLinkScope-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let store = GroveStore(persistenceEnabled: true, storage: storage)
        let first = UserSession(accountID: "link-owner-\(UUID().uuidString)", mode: .apple, displayName: "Ari")
        let second = UserSession(accountID: "link-stranger-\(UUID().uuidString)", mode: .apple, displayName: "Sam")

        store.activate(session: first)
        let plant = store.addPlant(nickname: "Fern", location: "Hall")
        let invite = store.createSittingInvite(
            sitterLabel: "Neighbour",
            startDate: .now,
            endDate: Calendar.current.date(byAdding: .day, value: 7, to: .now)!,
            plantIDs: [plant.id],
            canLogCare: true
        )
        store.attachShareURL(inviteID: invite.id, url: URL(string: "https://grove.example/sit/token")!)
        store.flushPersistence()
        let persisted = try XCTUnwrap(
            storage.data(forKey: AccountStorage.snapshotKey(for: first.accountID))
        )
        XCTAssertFalse(
            String(decoding: persisted, as: UTF8.self).contains("https://grove.example/sit/token"),
            "bearer URLs must never be written to UserDefaults"
        )
        XCTAssertFalse(store.hasSittingCover(), "Sending is not proof that a sitter accepted the handover")
        store.sittingInvites[0].lastOpenedAt = .now
        store.sittingInvites[0].openCount = 1
        XCTAssertTrue(store.hasSittingCover())

        store.activate(session: second)
        XCTAssertTrue(store.sittingInvites.isEmpty, "A link must not follow its owner into another account")
        XCTAssertFalse(store.hasSittingCover(), "A stranger's grove is not covered")

        store.activate(session: first)
        XCTAssertEqual(store.sittingInvites.count, 1, "The owner keeps their own link")

        store.deleteAllLocalData()
        XCTAssertTrue(store.sittingInvites.isEmpty, "\"Delete everything\" must retract the link too")
    }

    /// The composer records the row before the server answers, so a failed
    /// attempt is still visible and revocable. It must not count as cover: an
    /// account that cannot sync fails that call every time, and counting it told
    /// those users their plants were looked after when no link ever existed.
    func testALinkThatWasNeverMintedIsVisibleButIsNotCover() throws {
        let suiteName = "GroveSittingLinkUnminted-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let store = GroveStore(persistenceEnabled: true, storage: storage)
        store.activate(session: UserSession(accountID: "unminted-\(UUID().uuidString)", mode: .apple, displayName: "Ari"))
        let plant = store.addPlant(nickname: "Fern", location: "Hall")

        let invite = store.createSittingInvite(
            sitterLabel: "Neighbour",
            startDate: .now,
            endDate: Calendar.current.date(byAdding: .day, value: 7, to: .now)!,
            plantIDs: [plant.id],
            canLogCare: true
        )

        XCTAssertNil(invite.shareURL)
        XCTAssertFalse(invite.isLive(), "No URL means nobody was ever sent anything")
        XCTAssertTrue(invite.isOutstanding(), "The owner still needs the row to pull a possibly-minted link")
        XCTAssertFalse(store.hasSittingCover(), "A failed link must never silence the travel banner")

        store.attachShareURL(inviteID: invite.id, url: URL(string: "https://grove.example/sit/token")!)
        XCTAssertFalse(store.hasSittingCover(), "A URL nobody opened is still only an invitation")
        let index = try XCTUnwrap(store.sittingInvites.firstIndex { $0.id == invite.id })
        store.sittingInvites[index].lastOpenedAt = .now
        store.sittingInvites[index].openCount = 1
        XCTAssertTrue(store.hasSittingCover(), "A server-confirmed open establishes cover")

        store.requestSittingInviteRevocation(id: invite.id)
        let pending = try XCTUnwrap(store.sittingInvites.first { $0.id == invite.id })
        XCTAssertTrue(pending.isRevocationPending)
        XCTAssertFalse(pending.isRevoked)
        XCTAssertFalse(pending.providesCover(), "pending revocation cannot continue silencing the banner")
        XCTAssertNil(pending.shareURL, "revocation intent removes the local bearer immediately")
    }

    func testTokenFreeBootstrapMakesLinksRevocableAcrossDevicesWithoutSyncingTheBearer() throws {
        let owner = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(owner.plants.first)
        let local = owner.createSittingInvite(
            sitterLabel: "Maya",
            startDate: .now,
            endDate: Calendar.current.date(byAdding: .day, value: 7, to: .now)!,
            plantIDs: [plant.id],
            canLogCare: true
        )
        let privateURL = URL(string: "https://grove.example/sit/only-on-this-device")!
        owner.attachShareURL(inviteID: local.id, url: privateURL)
        var remote = local
        remote.shareURL = nil
        remote.wasMinted = true
        let response = GroveBootstrapResponse(
            profile: owner.profile,
            plants: owner.plants,
            tasks: owner.tasks,
            activity: owner.activity,
            assignments: owner.assignments,
            observations: owner.observations,
            friends: owner.friends,
            friendInvitations: owner.friendInvitations,
            serverTime: .now,
            sittingInvites: [remote]
        )

        XCTAssertTrue(owner.replace(with: response))
        XCTAssertEqual(owner.sittingInvites.first?.shareURL, privateURL, "the minting device keeps its URL")

        let secondDevice = GroveStore(
            plants: owner.plants,
            tasks: owner.tasks,
            activity: owner.activity,
            assignments: owner.assignments,
            sittingInvites: [],
            observations: owner.observations,
            friends: owner.friends,
            friendInvitations: owner.friendInvitations,
            profile: owner.profile,
            persistenceEnabled: false
        )
        XCTAssertTrue(secondDevice.replace(with: response))
        let synced = try XCTUnwrap(secondDevice.sittingInvites.first)
        XCTAssertNil(synced.shareURL, "the bearer must never cross devices")
        XCTAssertTrue(synced.isMinted)
        XCTAssertTrue(synced.isLive(), "the server row confirms that the capability itself is live")
        XCTAssertFalse(synced.providesCover(), "without an acknowledged open, it is not yet sitting cover")

        remote.revokedAt = .now
        let revokedResponse = GroveBootstrapResponse(
            profile: owner.profile,
            plants: owner.plants,
            tasks: owner.tasks,
            activity: owner.activity,
            assignments: owner.assignments,
            observations: owner.observations,
            friends: owner.friends,
            friendInvitations: owner.friendInvitations,
            serverTime: .now,
            sittingInvites: [remote]
        )
        XCTAssertTrue(owner.replace(with: revokedResponse))
        XCTAssertTrue(owner.sittingInvites.first?.isRevoked == true)
        XCTAssertNil(owner.sittingInvites.first?.shareURL, "revocation clears the locally retained bearer")

        let unconfirmed = owner.createSittingInvite(
            sitterLabel: "Unsent attempt",
            startDate: .now,
            endDate: Calendar.current.date(byAdding: .day, value: 2, to: .now)!,
            plantIDs: [plant.id],
            canLogCare: false
        )
        let authoritativeEmpty = GroveBootstrapResponse(
            profile: owner.profile,
            plants: owner.plants,
            tasks: owner.tasks,
            activity: owner.activity,
            assignments: owner.assignments,
            observations: owner.observations,
            friends: owner.friends,
            friendInvitations: owner.friendInvitations,
            serverTime: .now,
            sittingInvites: []
        )
        XCTAssertTrue(owner.replace(with: authoritativeEmpty))
        XCTAssertEqual(owner.sittingInvites.map(\.id), [unconfirmed.id])
        XCTAssertFalse(owner.sittingInvites[0].isMinted)
    }

    func testDeletingScopedDemoDataDoesNotResurrectLegacySnapshot() throws {
        let suiteName = "GroveDeletionTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let store = GroveStore(persistenceEnabled: true, storage: storage)
        let demo = UserSession(accountID: "deletion-demo-\(UUID().uuidString)", mode: .demo, displayName: "Alex")

        store.activate(session: demo)
        _ = store.addPlant(nickname: "Temporary", location: "Kitchen")
        XCTAssertEqual(store.plants.count, 5)

        store.deleteAllLocalData()
        XCTAssertNil(store.activeAccountID)
        store.activate(session: demo)

        XCTAssertEqual(store.plants.count, 4)
        XCTAssertFalse(store.plants.contains { $0.nickname == "Temporary" })
    }

    func testDeletingLocalDataClearsTheProfileIdentity() throws {
        let suiteName = "GroveProfileDeletionTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let store = GroveStore(persistenceEnabled: true, storage: storage)
        let account = UserSession(accountID: "deletion-apple-\(UUID().uuidString)", mode: .apple, displayName: "Ari Green")

        store.activate(session: account)
        store.updateProfile(name: "Ari Green", username: "arigrows", regionCode: "GB", usesMetricSystem: true, isPrivate: true)
        store.updateGroveLocation(GroveLocation(latitude: 51.5, longitude: -0.12, label: "London, United Kingdom"))

        store.deleteAllLocalData()

        XCTAssertTrue(store.profile.name.isEmpty)
        XCTAssertTrue(store.profile.username.isEmpty)
        XCTAssertNil(store.profile.location)
    }

    func testProfileAvatarPersistsAndReplacingCustomPhotoRemovesItsFile() throws {
        let suiteName = "GroveProfileAvatarTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let account = UserSession(
            accountID: "profile-avatar-\(UUID().uuidString)",
            mode: .apple,
            displayName: "Ari Green"
        )
        defer {
            storage.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: AccountStorage.mediaRootURL(for: account.accountID))
        }

        let store = GroveStore(persistenceEnabled: true, storage: storage)
        store.activate(session: account)
        try store.updateProfileAvatar(
            assetName: "GroveAvatarFern",
            existingPhotoURL: nil,
            customImageData: nil
        )

        let reloaded = GroveStore(persistenceEnabled: true, storage: storage)
        reloaded.activate(session: account)
        XCTAssertEqual(reloaded.profile.avatarAssetName, "GroveAvatarFern")
        XCTAssertNil(reloaded.profile.avatarPhotoURL)

        try reloaded.updateProfileAvatar(
            assetName: nil,
            existingPhotoURL: nil,
            customImageData: Data("profile-photo".utf8)
        )
        let customURL = try XCTUnwrap(reloaded.profile.avatarPhotoURL)
        XCTAssertNil(reloaded.profile.avatarAssetName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: customURL.path))

        try reloaded.updateProfileAvatar(
            assetName: "GroveAvatarMonstera",
            existingPhotoURL: nil,
            customImageData: nil
        )
        XCTAssertEqual(reloaded.profile.avatarAssetName, "GroveAvatarMonstera")
        XCTAssertNil(reloaded.profile.avatarPhotoURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: customURL.path))
    }

    // MARK: - Check-in cadence and guidance

    func testCheckInProgressFillsAcrossTheRecordedInterval() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        var plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let start = Date(timeIntervalSince1970: 1_000)
        plant.nextCheckIn = start.addingTimeInterval(1_000)

        XCTAssertEqual(plant.checkInProgress(since: start, at: start), 0, accuracy: 0.001)
        XCTAssertEqual(
            plant.checkInProgress(since: start, at: start.addingTimeInterval(250)),
            0.25,
            accuracy: 0.001
        )
        XCTAssertEqual(plant.checkInProgress(since: start, at: plant.nextCheckIn), 1, accuracy: 0.001)
        XCTAssertEqual(
            plant.checkInProgress(since: start, at: plant.nextCheckIn.addingTimeInterval(500)),
            1,
            accuracy: 0.001
        )
    }

    func testCheckInProgressDoesNotInventAMissingScheduleStart() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        var plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let now = Date(timeIntervalSince1970: 1_000)
        plant.nextCheckIn = now.addingTimeInterval(1_000)

        XCTAssertEqual(plant.checkInProgress(since: nil, at: now), 0)
        XCTAssertEqual(plant.checkInProgress(since: nil, at: plant.nextCheckIn), 1)
    }

    func testCheckInUsesTheFollowUpWindowTheAnalysisReturned() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        store.applyCheckIn(plantID: plant.id, score: 62, band: .monitor, note: "Watch the soil.", followUpDays: 5)

        XCTAssertEqual(store.plant(id: plant.id)?.daysUntilCheckIn, 5)
        let rescheduled = try XCTUnwrap(store.tasks.first { $0.plantID == plant.id && $0.kind == .checkIn && !$0.isCompleted })
        XCTAssertEqual(rescheduled.dueDate, store.plant(id: plant.id)?.nextCheckIn)
    }

    func testCheckInFollowUpIsShorterForAStrugglingPlantWhenTheAnalysisDidNotSay() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        // A plant in trouble must not wait a flat fortnight for its next look.
        store.applyCheckIn(plantID: plant.id, score: 25, band: .urgent, note: "Struggling.")

        XCTAssertEqual(store.plant(id: plant.id)?.daysUntilCheckIn, GroveStore.defaultFollowUpDays(for: .urgent))
        XCTAssertLessThan(GroveStore.defaultFollowUpDays(for: .urgent), GroveStore.defaultFollowUpDays(for: .healthy))
        XCTAssertLessThan(GroveStore.defaultFollowUpDays(for: .attention), GroveStore.defaultFollowUpDays(for: .healthy))
    }

    func testProvisionalCheckInLogsEvidenceWithoutOverwritingCanonicalHealth() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let before = try XCTUnwrap(store.plant(id: plant.id))
        let measuredAt = Date()
        let readings = PlantHealthIndicatorKind.allCases.map { kind in
            PlantHealthIndicatorReading(
                kind: kind,
                value: "unavailable",
                score: nil,
                status: "Not read",
                detail: "The photo did not support this reading.",
                evidenceLevel: .unavailable,
                source: .none,
                confidence: nil,
                evidence: [],
                measuredAt: measuredAt,
                validUntil: nil,
                algorithmVersion: "test.v1"
            )
        }

        let saved = try XCTUnwrap(store.applyCheckIn(
            plantID: plant.id,
            score: 31,
            band: .attention,
            note: "A clearer photograph is needed.",
            confidence: 42,
            actionability: .provisional,
            assessmentAvailable: true,
            analysisVersion: "test.v1",
            providerName: "Test provider",
            limitations: ["Leaf detail was blurred"],
            indicatorReadings: readings
        ))
        let after = try XCTUnwrap(store.plant(id: plant.id))

        XCTAssertEqual(after.healthScore, before.healthScore)
        XCTAssertEqual(after.healthBand, before.healthBand)
        XCTAssertEqual(after.summary, before.summary)
        XCTAssertEqual(after.healthIndicatorReadings, readings)
        XCTAssertEqual(saved.actionability, .provisional)
        XCTAssertEqual(saved.assessmentAvailable, true)
        XCTAssertEqual(saved.providerName, "Test provider")
        XCTAssertEqual(saved.limitations, ["Leaf detail was blurred"])
        XCTAssertEqual(saved.indicatorReadings, readings)
        XCTAssertTrue(store.activity.first?.message.contains("health score unchanged") == true)
    }

    func testCheckInFollowUpStaysWithinTheSupportedRange() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        store.applyCheckIn(plantID: plant.id, score: 80, band: .healthy, note: "Fine.", followUpDays: 900)

        XCTAssertEqual(store.plant(id: plant.id)?.daysUntilCheckIn, 30)
    }

    func testFirstCheckInDaysHelper() {
        XCTAssertEqual(GroveStore.firstCheckInDays(analysisDays: 14, band: .healthy), 3)
        XCTAssertEqual(GroveStore.firstCheckInDays(analysisDays: nil, band: .thriving), 3)
        XCTAssertEqual(GroveStore.firstCheckInDays(analysisDays: 2, band: .healthy), 2)
        XCTAssertEqual(GroveStore.firstCheckInDays(analysisDays: 0, band: .urgent), 1)
    }

    func testCheckInFollowUpHonoursPreference() {
        XCTAssertEqual(
            GroveStore.checkInFollowUpDays(
                analysisDays: nil,
                band: .healthy,
                preferredDays: 30,
                latitude: nil
            ),
            30
        )
        XCTAssertEqual(
            GroveStore.checkInFollowUpDays(
                analysisDays: nil,
                band: .healthy,
                preferredDays: nil,
                latitude: nil
            ),
            GroveStore.followUpDays(for: .healthy, latitude: nil)
        )
        XCTAssertEqual(
            GroveStore.checkInFollowUpDays(
                analysisDays: nil,
                band: .urgent,
                preferredDays: 30,
                latitude: nil
            ),
            3
        )
        XCTAssertEqual(
            GroveStore.checkInFollowUpDays(
                analysisDays: 5,
                band: .urgent,
                preferredDays: 3,
                latitude: nil
            ),
            3
        )
    }

    func testSettingCheckInFrequencyMovesTheOpenCheckIn() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let expected = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 30, to: .now))

        let moved = try XCTUnwrap(store.setCheckInFrequency(plantID: plant.id, days: 30))

        let updated = try XCTUnwrap(store.plant(id: plant.id))
        XCTAssertEqual(updated.checkInFrequencyDays, 30)
        XCTAssertEqual(updated.nextCheckIn.timeIntervalSince(expected), 0, accuracy: 2)
        XCTAssertEqual(moved.dueDate, updated.nextCheckIn)
        XCTAssertEqual(
            store.tasks.filter {
                $0.plantID == plant.id && $0.kind == .checkIn && !$0.isCompleted
            }.count,
            1
        )
    }

    func testAutomaticFrequencyLeavesTheScheduleAlone() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.setCheckInFrequency(plantID: plant.id, days: 30)
        let scheduled = try XCTUnwrap(store.plant(id: plant.id)?.nextCheckIn)

        XCTAssertNil(store.setCheckInFrequency(plantID: plant.id, days: nil))

        let updated = try XCTUnwrap(store.plant(id: plant.id))
        XCTAssertNil(updated.checkInFrequencyDays)
        XCTAssertEqual(updated.nextCheckIn, scheduled)
    }

    func testUnsupportedFrequencyIsIgnored() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let before = try XCTUnwrap(store.plant(id: plant.id))

        XCTAssertNil(store.setCheckInFrequency(plantID: plant.id, days: 0))
        XCTAssertNil(store.setCheckInFrequency(plantID: plant.id, days: 45))

        let after = try XCTUnwrap(store.plant(id: plant.id))
        XCTAssertNil(after.checkInFrequencyDays)
        XCTAssertEqual(after.nextCheckIn, before.nextCheckIn)
    }

    func testCheckInUsesTheOwnersFrequency() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.setCheckInFrequency(plantID: plant.id, days: 30)
        let expected = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 30, to: .now))

        store.applyCheckIn(plantID: plant.id, score: 86, band: .healthy, note: "Looking well.")

        let updated = try XCTUnwrap(store.plant(id: plant.id))
        XCTAssertEqual(updated.nextCheckIn.timeIntervalSince(expected), 0, accuracy: 2)
        let checkIn = try XCTUnwrap(
            store.tasks.first { $0.plantID == plant.id && $0.kind == .checkIn && !$0.isCompleted }
        )
        XCTAssertEqual(checkIn.dueDate, updated.nextCheckIn)
    }

    func testStrugglingPlantIsCheckedSoonerThanItsFrequency() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.setCheckInFrequency(plantID: plant.id, days: 30)
        let expected = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 3, to: .now))

        store.applyCheckIn(plantID: plant.id, score: 20, band: .urgent, note: "Struggling.")

        let updated = try XCTUnwrap(store.plant(id: plant.id))
        XCTAssertEqual(updated.nextCheckIn.timeIntervalSince(expected), 0, accuracy: 2)
        let checkIn = try XCTUnwrap(
            store.tasks.first { $0.plantID == plant.id && $0.kind == .checkIn && !$0.isCompleted }
        )
        XCTAssertEqual(checkIn.dueDate, updated.nextCheckIn)
    }

    func testBootstrapKeepsTheLocalCheckInFrequency() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.setCheckInFrequency(plantID: plant.id, days: 14)
        var remotePlant = try XCTUnwrap(store.plant(id: plant.id))
        remotePlant.checkInFrequencyDays = nil

        let response = GroveBootstrapResponse(
            profile: store.profile,
            plants: [remotePlant],
            tasks: [],
            activity: [],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now
        )

        XCTAssertTrue(store.replace(with: response))
        XCTAssertEqual(store.plant(id: plant.id)?.checkInFrequencyDays, 14)
    }

    func testPlantDecodesWithoutCheckInFrequency() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let data = try JSONEncoder().encode(plant)

        let decoded = try JSONDecoder().decode(Plant.self, from: data)

        XCTAssertNil(decoded.checkInFrequencyDays)
    }

    func testCheckInAppliesTheCareGuidanceTheAnalysisReturned() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        store.applyCheckIn(
            plantID: plant.id,
            score: 64,
            band: .monitor,
            note: "Lower leaves are yellowing.",
            nextActions: ["Check soil 5 cm deep", "Move away from the radiator"],
            concerns: ["Yellowing lower leaves"],
            positiveSigns: ["Firm stems"]
        )

        let updated = store.plant(id: plant.id)
        XCTAssertEqual(updated?.nextActions, ["Check soil 5 cm deep", "Move away from the radiator"])
        XCTAssertEqual(updated?.concerns, ["Yellowing lower leaves"])
        XCTAssertEqual(updated?.positiveSigns, ["Firm stems"])
        XCTAssertEqual(updated?.summary, "Lower leaves are yellowing.")
    }

    // MARK: - Removing a plant

    func testDeletingPlantRemovesItsCareTasksHistoryAndActivity() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let doomed = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let survivor = store.addPlant(nickname: "Fern", location: "Bedroom")
        store.applyCheckIn(plantID: doomed.id, score: 84, band: .healthy, note: "Looking up.")
        store.applyCheckIn(plantID: survivor.id, score: 88, band: .healthy, note: "Steady.")

        XCTAssertTrue(store.deletePlant(id: doomed.id))

        XCTAssertNil(store.plant(id: doomed.id))
        XCTAssertNotNil(store.plant(id: survivor.id))
        XCTAssertTrue(store.tasks.allSatisfy { $0.plantID != doomed.id })
        XCTAssertTrue(store.observations.allSatisfy { $0.plantID != doomed.id })
        XCTAssertTrue(store.activity.allSatisfy { $0.plantID != doomed.id })
        XCTAssertTrue(store.scanHistory.allSatisfy { $0.plantID != doomed.id })
        // The survivor keeps everything of its own.
        XCTAssertEqual(store.observations(for: survivor.id).count, 1)
        XCTAssertTrue(store.tasks.contains { $0.plantID == survivor.id })
    }

    func testDeletingPlantNarrowsSittingAssignmentsAndDropsEmptyOnes() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let first = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let second = store.addPlant(nickname: "Fern", location: "Bedroom")
        let endDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 7, to: .now))
        store.createSittingAssignment(sitterName: "Maya Kapoor", startDate: .now, endDate: endDate, plantIDs: [first.id, second.id])
        store.createSittingAssignment(sitterName: "Omar Lewis", startDate: .now, endDate: endDate, plantIDs: [first.id])

        store.deletePlant(id: first.id)

        XCTAssertEqual(store.assignments.count, 1, "An assignment left with no plants must not survive")
        XCTAssertEqual(store.assignments.first?.plantIDs, [second.id])
    }

    func testDeletingPlantRemovesItFromCollections() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let first = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let second = store.addPlant(nickname: "Fern", location: "Bedroom")
        let collection = try XCTUnwrap(
            store.createCollection(name: "Kitchen crew", symbol: "leaf.fill", palette: .fern, plantIDs: [first.id, second.id])
        )

        store.deletePlant(id: first.id)

        XCTAssertEqual(store.collection(id: collection.id)?.plantIDs, [second.id])
        XCTAssertEqual(store.plants(in: collection.id).map(\.id), [second.id])
    }

    func testDeletingUnknownPlantChangesNothing() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        _ = store.addPlant(nickname: "Pesto", location: "Kitchen")

        XCTAssertFalse(store.deletePlant(id: UUID()))
        XCTAssertEqual(store.plants.count, 1)
    }

    // MARK: - Plant sitting lifecycle

    func testSittingAssignmentStatusFollowsTheTripRatherThanFreezingAtInvited() throws {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func assignment(
            status: SittingStatus,
            startOffset: Int,
            endOffset: Int
        ) throws -> SittingAssignment {
            SittingAssignment(
                id: UUID(),
                sitterName: "Maya Kapoor",
                sitterInitials: "MK",
                startDate: try XCTUnwrap(calendar.date(byAdding: .day, value: startOffset, to: now)),
                endDate: try XCTUnwrap(calendar.date(byAdding: .day, value: endOffset, to: now)),
                plantIDs: [UUID()],
                status: status,
                completedTasks: 0,
                totalTasks: 2
            )
        }

        let accepted = try assignment(status: .upcoming, startOffset: -1, endOffset: 6)
        XCTAssertEqual(accepted.currentStatus(now: now), .active, "An accepted trip that has started is under way")

        let notYet = try assignment(status: .upcoming, startOffset: 3, endOffset: 10)
        XCTAssertEqual(notYet.currentStatus(now: now), .upcoming)

        let stillWaiting = try assignment(status: .invited, startOffset: -1, endOffset: 6)
        XCTAssertEqual(
            stillWaiting.currentStatus(now: now),
            .invited,
            "An invitation nobody accepted cannot become active — the plants were never handed over"
        )

        let finished = try assignment(status: .invited, startOffset: -20, endOffset: -6)
        XCTAssertEqual(finished.currentStatus(now: now), .completed, "The trip is over, whatever the invitation did")
        XCTAssertTrue(finished.hasEnded(now: now))
        XCTAssertFalse(accepted.hasEnded(now: now))
    }

    func testSittingAssignmentStoresTheCheckInPermissionTheOwnerChose() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let endDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 7, to: .now))

        store.createSittingAssignment(
            sitterName: "Maya Kapoor",
            startDate: .now,
            endDate: endDate,
            plantIDs: [plant.id],
            canCheckIn: false
        )

        XCTAssertEqual(store.assignments.first?.canCheckIn, false)
    }

    func testUnacceptedSittingInvitationDoesNotClaimTheGroveIsCovered() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let endDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 7, to: .now))
        _ = store.createSittingAssignment(
            sitterName: "Maya Kapoor",
            startDate: .now,
            endDate: endDate,
            plantIDs: [plant.id]
        )

        XCTAssertFalse(store.hasSittingCover(), "a request nobody accepted is not plant cover")
        store.assignments[0].status = .upcoming
        XCTAssertTrue(store.hasSittingCover(), "an accepted assignment inside its window is cover")
    }

    func testSittingAssignmentDecodesWithoutTheCheckInPermission() throws {
        // Snapshots written before the permission existed granted it, because
        // that is what those assignments were created under.
        let json = Data(#"""
        {
          "id": "70000000-0000-0000-0000-000000000001",
          "sitterName": "Maya Kapoor",
          "sitterInitials": "MK",
          "startDate": 0,
          "endDate": 86400,
          "plantIDs": [],
          "status": "upcoming",
          "completedTasks": 0,
          "totalTasks": 2
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(SittingAssignment.self, from: json)

        XCTAssertTrue(decoded.canCheckIn)
    }

    func testCareCompletedAfterATripEndsDoesNotCreditThatSitter() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let start = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -20, to: .now))
        let end = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -6, to: .now))
        store.createSittingAssignment(
            sitterName: "Maya Kapoor",
            startDate: start,
            endDate: end,
            plantIDs: [plant.id]
        )
        let sittingTask = CareTask(
            id: UUID(),
            plantID: plant.id,
            kind: .water,
            dueDate: .now,
            detail: "Water it.",
            isCompleted: false,
            isSittingTask: true,
            ownerName: "Maya"
        )
        store.tasks.append(sittingTask)

        store.complete(taskID: sittingTask.id)

        XCTAssertEqual(
            store.assignments.first?.completedTasks,
            0,
            "A trip that finished last week must not keep collecting progress"
        )
    }

    // MARK: - Daily quests

    func testAddingAPlantCountsAsTodaysLook() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)

        _ = store.addPlant(nickname: "Pesto", location: "Kitchen")

        let look = try XCTUnwrap(store.dailyQuests.first { $0.objective == .look })
        XCTAssertTrue(
            look.isComplete,
            "The look quest's own copy promises a brand-new plant counts, so it has to"
        )
    }

    // MARK: - Sitting invitations

    func testPendingSittingInvitationsExcludeExpiredDeclinedAndOutgoing() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day: TimeInterval = 86_400
        let pendingID = UUID()

        store.assignments = [
            SittingAssignment(
                id: pendingID,
                sitterName: "Me",
                sitterInitials: "M",
                startDate: now.addingTimeInterval(day),
                endDate: now.addingTimeInterval(day * 2),
                plantIDs: [],
                status: .invited,
                completedTasks: 0,
                totalTasks: 0,
                ownerName: "Ava",
                isIncoming: true
            ),
            // Expired even though nobody ever answered it.
            SittingAssignment(
                id: UUID(),
                sitterName: "Me",
                sitterInitials: "M",
                startDate: now.addingTimeInterval(-day * 3),
                endDate: now.addingTimeInterval(-day),
                plantIDs: [],
                status: .invited,
                completedTasks: 0,
                totalTasks: 0,
                ownerName: "Ben",
                isIncoming: true
            ),
            SittingAssignment(
                id: UUID(),
                sitterName: "Me",
                sitterInitials: "M",
                startDate: now.addingTimeInterval(day),
                endDate: now.addingTimeInterval(day * 2),
                plantIDs: [],
                status: .declined,
                completedTasks: 0,
                totalTasks: 0,
                ownerName: "Cleo",
                isIncoming: true
            ),
            SittingAssignment(
                id: UUID(),
                sitterName: "Dee",
                sitterInitials: "D",
                startDate: now.addingTimeInterval(day),
                endDate: now.addingTimeInterval(day * 2),
                plantIDs: [],
                status: .invited,
                completedTasks: 0,
                totalTasks: 0,
                ownerName: "Me",
                isIncoming: false
            ),
            SittingAssignment(
                id: UUID(),
                sitterName: "Me",
                sitterInitials: "M",
                startDate: now.addingTimeInterval(-day),
                endDate: now.addingTimeInterval(day),
                plantIDs: [],
                status: .active,
                completedTasks: 0,
                totalTasks: 0,
                ownerName: "Eli",
                isIncoming: true
            )
        ]
        store.friendInvitations = [
            FriendInvitation(
                id: UUID(),
                accountID: "incoming-friend",
                name: "Fern",
                username: "fern",
                initials: "F",
                direction: .incoming,
                createdAt: now
            ),
            FriendInvitation(
                id: UUID(),
                accountID: "outgoing-friend",
                name: "Gus",
                username: "gus",
                initials: "G",
                direction: .outgoing,
                createdAt: now
            )
        ]

        XCTAssertEqual(store.pendingIncomingSittingInvitations(now: now).map(\.id), [pendingID])
        XCTAssertEqual(store.friendsTabBadgeCount(now: now), 2)
    }

    // MARK: - Seeded usernames

    func testDefaultUsernameIsValidAndDerivedFromTheDisplayName() {
        let username = GroveStore.defaultUsername(for: "Ari Green", accountID: "apple-user-1a2b")

        XCTAssertTrue(username.hasPrefix("arigreen"))
        XCTAssertTrue((3...24).contains(username.count))
        XCTAssertTrue(username.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
    }

    func testDefaultUsernameFallsBackWhenTheNameHasNoUsableLetters() {
        let username = GroveStore.defaultUsername(for: "🌱", accountID: "guest-local-9zzz")

        XCTAssertTrue(username.hasPrefix("gardener"))
        XCTAssertTrue((3...24).contains(username.count))
    }

    func testDefaultUsernameStaysWithinTheAllowedLength() {
        let username = GroveStore.defaultUsername(
            for: "Bartholomew Fitzgerald Wentworth The Third",
            accountID: "apple-user-abcd"
        )

        XCTAssertTrue((3...24).contains(username.count))
    }
}
