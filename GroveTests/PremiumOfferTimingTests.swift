import XCTest
@testable import Grove

/// Covers when Grove is allowed to ask for money.
///
/// The offer used to be a step in onboarding, then waited only for another app
/// launch. It is now due at the end of onboarding, once the first plant's
/// first-week care plan has been seen, with two care-loop actions (two guided
/// check-ins, or a check-in and a second plant) as the fallback for the manual
/// route. Reopening the app alone is still not value. These tests cover that
/// one-shot state machine independently of UI timing.
@MainActor
final class PremiumOfferTimingTests: XCTestCase {
    private func makeStorage(_ name: String) -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "\(name)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    func testNothingIsOfferedBeforeOnboardingArmsIt() {
        let (storage, suiteName) = makeStorage("PremiumOfferUnarmed")
        defer { storage.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(
            GrovePremiumOffer.isDue(in: storage),
            "A fresh install has nothing to offer against"
        )

        GrovePremiumOffer.recordMeaningfulUse(in: storage)
        XCTAssertFalse(
            GrovePremiumOffer.isDue(in: storage),
            "Useful work before onboarding arms the offer must not leak forward"
        )
    }

    /// The session that sets Grove up never sees a price merely because setup
    /// finished. It has not exercised the care loop yet.
    func testTheOfferNeverAppearsInTheSessionThatFinishedOnboarding() {
        let (storage, suiteName) = makeStorage("PremiumOfferSameSession")
        defer { storage.removePersistentDomain(forName: suiteName) }

        GrovePremiumOffer.arm(in: storage)

        XCTAssertFalse(
            GrovePremiumOffer.isDue(in: storage),
            "Finishing account setup is not a meaningful-use event"
        )
    }

    func testTheOfferBecomesDueAfterTwoMeaningfulUses() {
        let (storage, suiteName) = makeStorage("PremiumOfferMeaningfulUse")
        defer { storage.removePersistentDomain(forName: suiteName) }

        GrovePremiumOffer.arm(in: storage)
        GrovePremiumOffer.recordMeaningfulUse(in: storage)

        XCTAssertFalse(
            GrovePremiumOffer.isDue(in: storage),
            "One care-loop action is not yet a routine"
        )

        GrovePremiumOffer.recordMeaningfulUse(in: storage)

        XCTAssertTrue(
            GrovePremiumOffer.isDue(in: storage),
            "Two real care-loop actions earn the contextual offer"
        )
    }

    func testOneAdditionalPlantIsNotEnoughButTwoAdditionalPlantsAre() {
        let (storage, suiteName) = makeStorage("PremiumOfferSecondPlant")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let store = GroveStore(plants: [], persistenceEnabled: false, storage: storage)
        GrovePremiumOffer.arm(in: storage)

        _ = store.addPlant(nickname: "Fern", location: "Desk")
        XCTAssertFalse(
            GrovePremiumOffer.isDue(in: storage),
            "The first plant is onboarding's promised outcome, not a monetization trigger"
        )

        _ = store.addPlant(nickname: "Pothos", location: "Kitchen")
        XCTAssertFalse(
            GrovePremiumOffer.isDue(in: storage),
            "One additional plant is a single use; the offer waits for a second"
        )

        _ = store.addPlant(nickname: "Pilea", location: "Bathroom")
        XCTAssertTrue(GrovePremiumOffer.isDue(in: storage))
    }

    func testTwoGuidedCheckInsEarnTheOffer() throws {
        let (storage, suiteName) = makeStorage("PremiumOfferCheckIn")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let store = GroveStore(persistenceEnabled: false, storage: storage)
        let plant = try XCTUnwrap(store.plants.first)
        GrovePremiumOffer.arm(in: storage)

        _ = store.applyCheckIn(
            plantID: plant.id,
            score: plant.healthScore,
            band: plant.healthBand,
            note: "A fresh guided check-in"
        )
        _ = store.applyCheckIn(
            plantID: plant.id,
            score: plant.healthScore,
            band: plant.healthBand,
            note: "A second guided check-in"
        )

        XCTAssertTrue(GrovePremiumOffer.isDue(in: storage))
    }

    /// A one-plant beginner must not meet a price after their first check-in.
    /// The second guided check-in is the earliest the offer can be due.
    func testOneCheckInIsNotEnough() throws {
        let (storage, suiteName) = makeStorage("PremiumOfferOneCheckIn")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let store = GroveStore(persistenceEnabled: false, storage: storage)
        let plant = try XCTUnwrap(store.plants.first)
        GrovePremiumOffer.arm(in: storage)

        _ = store.applyCheckIn(
            plantID: plant.id,
            score: plant.healthScore,
            band: plant.healthBand,
            note: "The first guided check-in"
        )
        XCTAssertFalse(
            GrovePremiumOffer.isDue(in: storage),
            "One check-in is not a routine; the offer must wait for the second"
        )

        _ = store.applyCheckIn(
            plantID: plant.id,
            score: plant.healthScore,
            band: plant.healthBand,
            note: "A second guided check-in"
        )
        XCTAssertTrue(
            GrovePremiumOffer.isDue(in: storage),
            "The second check-in is the earliest a one-plant owner should be asked"
        )
    }

    func testAnsweringTheOfferRetiresItForGood() {
        let (storage, suiteName) = makeStorage("PremiumOfferAnswered")
        defer { storage.removePersistentDomain(forName: suiteName) }

        GrovePremiumOffer.arm(in: storage)
        GrovePremiumOffer.recordMeaningfulUse(in: storage)
        GrovePremiumOffer.recordMeaningfulUse(in: storage)
        GrovePremiumOffer.complete(in: storage)

        XCTAssertFalse(GrovePremiumOffer.isDue(in: storage))

        GrovePremiumOffer.recordMeaningfulUse(in: storage)
        XCTAssertFalse(
            GrovePremiumOffer.isDue(in: storage),
            "The one-time offer must not come back after later care"
        )
    }

    /// A second account onboarded on the same phone must not re-arm an offer
    /// that is already waiting, which would erase an action it has already
    /// earned every time someone signs up again.
    func testArmingTwiceDoesNotEraseMeaningfulUse() {
        let (storage, suiteName) = makeStorage("PremiumOfferRearmed")
        defer { storage.removePersistentDomain(forName: suiteName) }

        GrovePremiumOffer.arm(in: storage)
        GrovePremiumOffer.recordMeaningfulUse(in: storage)
        GrovePremiumOffer.recordMeaningfulUse(in: storage)
        GrovePremiumOffer.arm(in: storage)

        XCTAssertTrue(GrovePremiumOffer.isDue(in: storage))
    }

    /// The care plan dismissal is the moment the offer is about: the first
    /// plant is saved and its first week is understood, so no additional
    /// care-loop action is needed to make it due.
    func testSeeingTheFirstCarePlanMakesTheOfferDueImmediately() {
        let (storage, suiteName) = makeStorage("PremiumOfferOnboardingFinished")
        defer { storage.removePersistentDomain(forName: suiteName) }

        GrovePremiumOffer.markOnboardingFinished(in: storage)

        XCTAssertEqual(storage.integer(forKey: GroveDefaults.premiumOfferMeaningfulUseCount), 0)
        XCTAssertTrue(
            GrovePremiumOffer.isDue(in: storage),
            "The end of onboarding is itself the trigger"
        )
    }

    func testMarkingOnboardingFinishedAfterAnsweringDoesNotReArmTheOffer() {
        let (storage, suiteName) = makeStorage("PremiumOfferAnsweredThenFinished")
        defer { storage.removePersistentDomain(forName: suiteName) }

        GrovePremiumOffer.markOnboardingFinished(in: storage)
        GrovePremiumOffer.complete(in: storage)
        GrovePremiumOffer.markOnboardingFinished(in: storage)

        XCTAssertFalse(
            GrovePremiumOffer.isDue(in: storage),
            "A one-time offer must stay answered for good"
        )
    }

    func testMarkingOnboardingFinishedKeepsAnExistingMeaningfulUseCount() {
        let (storage, suiteName) = makeStorage("PremiumOfferFinishedKeepsCount")
        defer { storage.removePersistentDomain(forName: suiteName) }

        GrovePremiumOffer.arm(in: storage)
        GrovePremiumOffer.recordMeaningfulUse(in: storage)
        GrovePremiumOffer.recordMeaningfulUse(in: storage)
        GrovePremiumOffer.markOnboardingFinished(in: storage)

        XCTAssertEqual(
            storage.integer(forKey: GroveDefaults.premiumOfferMeaningfulUseCount),
            2,
            "Finishing onboarding must not erase work already earned"
        )
        XCTAssertTrue(GrovePremiumOffer.isDue(in: storage))
    }

    /// The manual route creates no first plant, so its care plan never ends
    /// onboarding; the count trigger has to keep working on its own.
    func testTheCountPathStillWorksWithoutOnboardingFinished() {
        let (storage, suiteName) = makeStorage("PremiumOfferCountOnly")
        defer { storage.removePersistentDomain(forName: suiteName) }

        GrovePremiumOffer.arm(in: storage)
        GrovePremiumOffer.recordMeaningfulUse(in: storage)
        GrovePremiumOffer.recordMeaningfulUse(in: storage)

        XCTAssertFalse(storage.bool(forKey: GroveDefaults.premiumOfferOnboardingFinished))
        XCTAssertTrue(GrovePremiumOffer.isDue(in: storage))
    }

    /// Deleting local data has to take the offer's bookkeeping with it, like
    /// every other device-level flag in `GroveDefaults`.
    func testDeletingLocalDataClearsTheOfferState() {
        let (storage, suiteName) = makeStorage("PremiumOfferReset")
        defer { storage.removePersistentDomain(forName: suiteName) }

        GrovePremiumOffer.arm(in: storage)
        GrovePremiumOffer.recordMeaningfulUse(in: storage)
        GrovePremiumOffer.recordMeaningfulUse(in: storage)
        XCTAssertTrue(GrovePremiumOffer.isDue(in: storage))

        GroveDefaults.reset(in: storage)

        XCTAssertFalse(GrovePremiumOffer.isDue(in: storage))
        XCTAssertEqual(storage.integer(forKey: GroveDefaults.premiumOfferMeaningfulUseCount), 0)
    }

    // MARK: - Subject copy

    func testTheOfferNamesThePlantAndItsRealNextCheckIn() {
        let plant = Plant.offerFixture(nickname: "Monty", species: "Swiss cheese plant", daysUntilCheckIn: 6)
        let subject = GrovePremiumOfferSubject(plant: plant, plantCount: 3, image: nil)

        XCTAssertEqual(subject.displayName, "Monty")
        XCTAssertEqual(subject.identityLine, "Monty · Swiss cheese plant")
        XCTAssertEqual(subject.supportingLine, "Next check-in in 6 days")
        XCTAssertEqual(subject.eyebrowLine, "3 plants in your grove.")
    }

    func testASingleUnnamedPlantStillReadsAsEnglish() {
        let plant = Plant.offerFixture(nickname: "Fern", species: "Fern", daysUntilCheckIn: 1)
        let subject = GrovePremiumOfferSubject(plant: plant, plantCount: 1, image: nil)

        XCTAssertEqual(
            subject.identityLine,
            "Fern",
            "A nickname that matches the species must not be printed twice"
        )
        XCTAssertEqual(subject.supportingLine, "Next check-in tomorrow")
        XCTAssertEqual(subject.eyebrowLine, "1 plant in your grove.")
    }

    func testAnOverdueCheckInIsNotSoldAsAFutureOne() {
        let plant = Plant.offerFixture(nickname: "Monty", species: "Swiss cheese plant", daysUntilCheckIn: -2)
        let subject = GrovePremiumOfferSubject(plant: plant, plantCount: 2, image: nil)

        XCTAssertEqual(subject.supportingLine, "Check-in overdue")
    }
}

private extension Plant {
    static func offerFixture(nickname: String, species: String, daysUntilCheckIn: Int) -> Plant {
        let day = Calendar.current.startOfDay(for: .now)
        let checkIn = Calendar.current.date(byAdding: .day, value: daysUntilCheckIn, to: day) ?? day
        return Plant(
            id: UUID(),
            nickname: nickname,
            species: species,
            scientificName: "Monstera deliciosa",
            location: "Living room",
            healthScore: 88,
            healthBand: .thriving,
            trend: .baseline,
            confidence: 90,
            nextCheckIn: checkIn,
            symbol: "leaf.fill",
            palette: .fern,
            summary: "A healthy baseline.",
            positiveSigns: [],
            concerns: [],
            nextActions: []
        )
    }
}
