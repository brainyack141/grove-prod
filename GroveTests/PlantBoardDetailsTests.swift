import XCTest
@testable import Grove

/// The plant board's steps, usual range and review line.
///
/// Each test names the promise the board makes to the owner, because that is
/// what breaks for them if one of these fails.
@MainActor
final class PlantBoardDetailsTests: XCTestCase {

    // MARK: Steps

    func testStepsReadTheStructuredPlanAndKeepWhatWasDone() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        var plant = store.addPlant(nickname: "Monty", location: "Living room")
        plant.carePlan = Self.plan([
            ("Tip out the saucer", .completed),
            ("Skip water until the top 5 cm is dry", .due),
            ("Cut the two yellow leaves", .due)
        ])

        let steps = PlantPlanSteps.make(plant: plant)

        XCTAssertEqual(steps.steps.map(\.instruction), [
            "Tip out the saucer",
            "Skip water until the top 5 cm is dry",
            "Cut the two yellow leaves"
        ])
        XCTAssertEqual(steps.doneCount, 1)
        XCTAssertTrue(steps.isTrackable)
    }

    func testSkippedStepsLeaveTheList() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        var plant = store.addPlant(nickname: "Monty", location: "Living room")
        plant.carePlan = Self.plan([("Move it a metre back", .skipped), ("Cut the yellow leaf", .due)])

        XCTAssertEqual(PlantPlanSteps.make(plant: plant).steps.map(\.instruction), ["Cut the yellow leaf"])
    }

    /// A plant saved before care plans existed still shows its advice, but
    /// offers no Done button: there is nowhere to keep the tick.
    func testLegacyNextActionsShowButCannotBeTicked() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        var plant = store.addPlant(nickname: "Monty", location: "Living room")
        plant.carePlan = nil
        plant.nextActions = ["Feel the top 3 cm before you water", "  "]

        let steps = PlantPlanSteps.make(plant: plant)

        XCTAssertEqual(steps.steps.map(\.instruction), ["Feel the top 3 cm before you water"])
        XCTAssertFalse(steps.isTrackable)
        XCTAssertNil(steps.steps.first?.actionID)
    }

    /// Ticking "Skip watering" must never be recorded as a watering. The step
    /// is marked on the plan; no care event is logged.
    func testTickingAStepMarksThePlanWithoutLoggingCare() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Monty", location: "Living room")
        let plan = Self.plan([("Skip water until the top 5 cm is dry", .due)])
        store.updatePlantRecord(
            id: plant.id,
            lifecycleState: .active,
            acquiredAt: nil,
            notes: "",
            environmentReadings: [],
            carePlan: plan
        )
        let waterLogsBefore = store.tasks.filter { $0.plantID == plant.id && $0.kind == .water && $0.isCompleted }.count

        let updated = try XCTUnwrap(
            store.updateCarePlanAction(plantID: plant.id, actionID: plan.actions[0].id, state: .completed)
        )

        XCTAssertEqual(PlantPlanSteps.make(plant: updated).doneCount, 1)
        XCTAssertEqual(
            store.tasks.filter { $0.plantID == plant.id && $0.kind == .water && $0.isCompleted }.count,
            waterLogsBefore
        )
    }

    // MARK: Findings

    /// A finished check leaves the owner holding an answer. The board must
    /// hand it to Ari, one blank per check, without Ari's reasoning in the way.
    func testFinishedChecksBecomeAFindingsDraftForAri() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        var plant = store.addPlant(nickname: "Wild Orange", location: "Deck")
        plant.carePlan = Self.plan([
            ("Perform a gentle scratch test with a fingernail on the lower main trunk to check for green cambium beneath the bark", .completed),
            ("Gently bend a small outer twig to check if it snaps dryly or remains supple", .completed),
            ("Check the moisture level deep within the rootball using a thin wooden skewer", .due)
        ])

        let steps = PlantPlanSteps.make(plant: plant)
        let draft = try XCTUnwrap(steps.findingsDraft(nickname: "Wild Orange"))

        XCTAssertEqual(steps.finishedChecks.count, 2)
        XCTAssertEqual(
            draft,
            "I did the checks on Wild Orange. Here's what I found:\n\n"
                + "Perform a gentle scratch test with a fingernail on the lower main trunk: \n"
                + "Gently bend a small outer twig: "
        )
    }

    /// Treatment steps have nothing to report: the next photo is still the
    /// judge, so the board keeps plain Ask Ari and the photo line.
    func testTreatmentStepsOfferNoFindingsDraft() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        var plant = store.addPlant(nickname: "Monty", location: "Living room")
        plant.carePlan = Self.plan([("Tip out the saucer", .completed), ("Cut the two yellow leaves", .completed)])

        XCTAssertNil(PlantPlanSteps.make(plant: plant).findingsDraft(nickname: "Monty"))
    }

    // MARK: Answered checks

    private static let scratchOutcomes = [
        PlantCheckOutcome(id: "green", title: "Green under the bark", meaning: "The trunk is alive.", nextStep: "Water deeply once"),
        PlantCheckOutcome(id: "brown", title: "Brown and dry", meaning: "This branch has died.", nextStep: "")
    ]

    /// The diagnosis names each check's results; the plan must keep them on
    /// the matching step, forgiving only case and punctuation.
    func testCarePlanAttachesResultsToTheMatchingCheck() throws {
        let plan = try XCTUnwrap(GroveStore.makeCarePlan(
            goal: "Find out if it is alive",
            actions: ["Scratch the lower trunk with a fingernail", "Move it out of the wind"],
            checks: [PlantCheck(action: "scratch the lower trunk with a fingernail.", outcomes: Self.scratchOutcomes)],
            reviewAt: nil,
            at: .now
        ))

        XCTAssertEqual(plan.actions[0].outcomes, Self.scratchOutcomes)
        XCTAssertNil(plan.actions[1].outcomes)
    }

    /// Tapping a result finishes the check, keeps the result, and puts the
    /// step it leads to straight after it, ready to tick.
    func testTappingAResultAddsTheStepItLeadsTo() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Wild Orange", location: "Deck")
        var plan = Self.plan([("Scratch the lower trunk with a fingernail", .due), ("Move it out of the wind", .due)])
        plan.actions[0].outcomes = Self.scratchOutcomes
        store.updatePlantRecord(
            id: plant.id, lifecycleState: .active, acquiredAt: nil, notes: "", environmentReadings: [], carePlan: plan
        )

        XCTAssertTrue(PlantPlanSteps.make(plant: try XCTUnwrap(store.plants.first)).steps[0].isAnswerable)

        let updated = try XCTUnwrap(
            store.recordCheckFinding(plantID: plant.id, actionID: plan.actions[0].id, outcomeID: "green")
        )
        let steps = PlantPlanSteps.make(plant: updated)

        XCTAssertEqual(steps.steps.map(\.instruction), [
            "Scratch the lower trunk with a fingernail", "Water deeply once", "Move it out of the wind"
        ])
        XCTAssertEqual(steps.steps[0].finding?.title, "Green under the bark")
        XCTAssertTrue(steps.steps[0].isDone)
        XCTAssertFalse(steps.steps[1].isDone)
        XCTAssertNotNil(steps.steps[1].actionID)
        // Answered by a tap, so there is nothing left to tell Ari.
        XCTAssertNil(steps.findingsDraft(nickname: "Wild Orange"))
        XCTAssertEqual(updated.nextActions, ["Water deeply once", "Move it out of the wind"])

        let restored = try XCTUnwrap(store.restoreCarePlan(plantID: plant.id, to: plan))
        XCTAssertEqual(restored.carePlan, plan)
    }

    /// "Wait for the next photo" adds nothing to do.
    func testAResultWithNoNextStepOnlyFinishesTheCheck() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Wild Orange", location: "Deck")
        var plan = Self.plan([("Scratch the lower trunk with a fingernail", .due)])
        plan.actions[0].outcomes = Self.scratchOutcomes
        store.updatePlantRecord(
            id: plant.id, lifecycleState: .active, acquiredAt: nil, notes: "", environmentReadings: [], carePlan: plan
        )

        let updated = try XCTUnwrap(
            store.recordCheckFinding(plantID: plant.id, actionID: plan.actions[0].id, outcomeID: "brown")
        )

        XCTAssertEqual(updated.carePlan?.actions.count, 1)
        XCTAssertEqual(updated.carePlan?.actions[0].findingID, "brown")
    }

    /// Plans saved before checks carried results still decode, and a gateway
    /// result with checks decodes them.
    func testChecksDecodeAndOldPlansStillLoad() throws {
        let old = #"{"id":"6E1D1C9A-4D2E-4F8B-9C1A-2B3C4D5E6F70","kind":"monitor","instruction":"Look","rationale":"","expectedResponse":"","state":"due"}"#
        let action = try JSONDecoder().decode(PlantCarePlanAction.self, from: Data(old.utf8))
        XCTAssertNil(action.outcomes)

        let condition = #"{"healthScore":40,"healthBand":"attention","confidence":60,"summary":"s","positiveSigns":[],"concerns":[],"possibleCauses":[],"nextActions":["Bend a twig"],"checks":[{"action":"Bend a twig","outcomes":[{"id":"a","title":"Bends","meaning":"Alive.","nextStep":""},{"id":"b","title":"Snaps","meaning":"Dead.","nextStep":"Cut it back"}]}]}"#
        let decoded = try JSONDecoder().decode(PlantConditionResult.self, from: Data(condition.utf8))
        XCTAssertEqual(decoded.checks?.first?.outcomes.map(\.title), ["Bends", "Snaps"])
    }

    // MARK: Review line

    func testReviewLineNamesTheDayOfTheNextPhoto() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 10)))
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }

        XCTAssertEqual(PlantPlanSteps.reviewLine(for: day(0), now: now), "Today's photo will show if it worked.")
        XCTAssertEqual(PlantPlanSteps.reviewLine(for: day(-2), now: now), "Today's photo will show if it worked.")
        XCTAssertEqual(PlantPlanSteps.reviewLine(for: day(1), now: now), "Tomorrow's photo will show if it worked.")
        XCTAssertTrue(PlantPlanSteps.reviewLine(for: day(3), now: now).hasSuffix("'s photo will show if it worked."))
        XCTAssertTrue(PlantPlanSteps.reviewLine(for: day(10), now: now).hasPrefix("The photo on "))
    }

    // MARK: Usual range

    func testUsualRangeWaitsForThreeEarlierReadings() {
        XCTAssertNil(PlantUsualRange.make(scores: []))
        XCTAssertNil(PlantUsualRange.make(scores: [82, 84, 70]))
        XCTAssertEqual(PlantUsualRange.make(scores: [80, 82, 84, 70]), PlantUsualRange(low: 80, high: 84))
    }

    /// The question is whether the latest reading is unusual, so it never
    /// widens the range it is being judged against.
    func testUsualRangeLeavesOutTheLatestReading() throws {
        let range = try XCTUnwrap(PlantUsualRange.make(scores: [80, 82, 84, 40]))
        XCTAssertEqual(range.position(of: 40), .below)
        XCTAssertEqual(range.position(of: 83), .within)
        XCTAssertEqual(range.position(of: 90), .above)
    }

    /// One bad week in spring should not make every later dip look usual.
    func testUsualRangeTrimsTheOutliers() {
        XCTAssertEqual(
            PlantUsualRange.make(scores: [40, 80, 84, 86, 88, 90, 92, 95, 70]),
            PlantUsualRange(low: 84, high: 90)
        )
    }

    /// Under four points wide, the range is widened around its middle so a
    /// one-point wobble does not read as leaving "usual".
    func testANarrowRangeIsWidenedAroundItsMiddle() {
        XCTAssertEqual(
            PlantUsualRange.make(scores: [40, 85, 86, 87, 88, 89, 90, 91, 70]),
            PlantUsualRange(low: 85, high: 89)
        )
    }

    func testAPlantThatHeldOneScoreStillHasARange() {
        XCTAssertEqual(PlantUsualRange.make(scores: [80, 80, 80, 80]), PlantUsualRange(low: 78, high: 82))
    }

    // MARK: Care row

    func testLightHeadlineSpellsOutBrightIndirect() {
        let profile = PlantCareProfile(commonName: "Swiss cheese plant", scientificName: "Monstera deliciosa")

        XCTAssertEqual(profile.lightHeadline, "Near a bright window, out of direct sun")
    }

    // MARK: Helpers

    private static func plan(_ steps: [(String, PlantCarePlanActionState)]) -> PlantCarePlan {
        PlantCarePlan(
            id: UUID(),
            goal: "Let the roots dry out",
            actions: steps.map { instruction, state in
                PlantCarePlanAction(
                    id: UUID(),
                    kind: .monitor,
                    instruction: instruction,
                    rationale: "From the latest assessment.",
                    dueFrom: nil,
                    dueUntil: nil,
                    expectedResponse: "Firmer leaves at the next check-in.",
                    state: state,
                    completedAt: state == .completed ? .now : nil
                )
            },
            startedAt: .now,
            reviewAt: nil,
            status: .active,
            outcome: nil
        )
    }
}
