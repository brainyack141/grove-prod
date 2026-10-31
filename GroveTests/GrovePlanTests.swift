import XCTest
@testable import Grove

/// Covers the path the onboarding quiz answers take from signup to the profile.
@MainActor
final class GrovePlanTests: XCTestCase {
    private func makeLocation() -> GroveLocation {
        GroveLocation(
            latitude: 51.4545,
            longitude: -2.5879,
            label: "Bristol, United Kingdom",
            countryCode: "GB",
            timeZoneIdentifier: "Europe/London"
        )
    }

    private func makePlan() -> GrovePlan {
        GrovePlan(
            experience: "new",
            collectionSize: "4-10",
            environment: "outdoor",
            focuses: ["watering", "pests", "away"],
            challenge: "watering"
        )
    }

    /// A private defaults suite per test, so nothing leaks between accounts or
    /// between runs. Callers `defer` the cleanup, matching the other suites.
    private func makeStorage(_ name: String) -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "\(name)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    // MARK: - Model

    func testFocusesAreStoredSortedRegardlessOfTapOrder() {
        let plan = GrovePlan(focuses: ["watering", "away", "pests"])
        XCTAssertEqual(plan.focuses, ["away", "pests", "watering"])
        XCTAssertEqual(plan, GrovePlan(focuses: ["pests", "watering", "away"]))
    }

    func testTogglingFocusesRespectsThePickLimit() {
        var plan = GrovePlan()
        for focus in GrovePlanCatalog.focuses.prefix(GrovePlanCatalog.focusPickLimit + 2) {
            plan.toggleFocus(focus.id)
        }
        XCTAssertEqual(plan.focuses.count, GrovePlanCatalog.focusPickLimit)

        let kept = plan.focuses[0]
        plan.toggleFocus(kept)
        XCTAssertFalse(plan.focuses.contains(kept), "Toggling a chosen focus must remove it")
        XCTAssertEqual(plan.focuses.count, GrovePlanCatalog.focusPickLimit - 1)
    }

    func testEveryCatalogueIDResolvesToALabel() {
        // A stored plan holds IDs, so an ID that no catalogue can resolve would
        // render as a silently missing answer.
        let all = GrovePlanCatalog.experience + GrovePlanCatalog.collectionSize
            + GrovePlanCatalog.environment + GrovePlanCatalog.challenge
        for choice in all {
            XCTAssertFalse(choice.title.isEmpty)
        }
        for focus in GrovePlanCatalog.focuses {
            XCTAssertNotNil(GrovePlanCatalog.focus(focus.id))
            XCTAssertFalse(focus.planLabel.isEmpty)
        }
        let plan = makePlan()
        XCTAssertEqual(plan.focusChips.count, 3)
        XCTAssertTrue(plan.summaryLine.contains("Total beginner"))
    }

    func testAnUnansweredPlanIsEmptyAndFallsBackToDefaultCopy() {
        let plan = GrovePlan()
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.focusChips, ["🌱 Building the habit"])
        XCTAssertEqual(plan.cadenceText, "One check-in per plant, every couple of weeks.")
        XCTAssertFalse(plan.summaryLine.isEmpty)
    }

    // MARK: - Onboarding hand-off

    func testOnboardingModelBuildsThePlanFromItsAnswers() {
        let (storage, suiteName) = makeStorage("OnboardingPlanDraft")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)
        model.experience = "new"
        model.environment = "outdoor"
        model.challenge = "watering"

        XCTAssertEqual(
            model.plan,
            GrovePlan(
                experience: "new",
                collectionSize: nil,
                environment: "outdoor",
                focuses: ["watering"],
                challenge: "watering"
            )
        )
    }

    func testManualFallbackOffersExplorationWithoutQuestions() {
        let (storage, suiteName) = makeStorage("OnboardingShortFlow")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)
        model.beginQuiz()

        XCTAssertEqual(
            model.orderedSteps,
            [.welcome, .explore, .signIn]
        )
        XCTAssertFalse(model.orderedSteps.contains(.collectionSize))
        XCTAssertFalse(model.orderedSteps.contains(.overcome))
        XCTAssertFalse(model.orderedSteps.contains(.buildingPlan))
        XCTAssertFalse(model.orderedSteps.contains(.notifications))
        XCTAssertFalse(
            model.orderedSteps.contains(.paywall),
            "Premium is offered after the account exists, not on the way to it"
        )

        model.authMethod = .email
        XCTAssertEqual(
            model.orderedSteps,
            [.welcome, .explore, .signIn, .emailEntry, .emailVerification]
        )
        XCTAssertFalse(model.orderedSteps.contains(.planReveal))
    }

    func testDefaultOnboardingDeliversARealPlantResultBeforeSignIn() {
        let (storage, suiteName) = makeStorage("OnboardingFirstPlantFlow")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)

        model.beginFirstPlant()

        XCTAssertEqual(
            model.orderedSteps,
            [.welcome, .firstPlantScan, .firstPlantDetails, .firstPlantRoom, .location, .signIn]
        )
        XCTAssertEqual(model.step, .firstPlantScan)
        XCTAssertFalse(
            model.orderedSteps.contains(.paywall),
            "A price must never stand between the scanned plant and the account that saves it"
        )
        XCTAssertFalse(model.orderedSteps.contains(.name))
        XCTAssertFalse(model.orderedSteps.contains(.experience))
        XCTAssertFalse(model.orderedSteps.contains(.environment))
        XCTAssertFalse(model.orderedSteps.contains(.challenge))

        model.authMethod = .email
        XCTAssertEqual(
            model.orderedSteps,
            [.welcome, .firstPlantScan, .firstPlantDetails, .firstPlantRoom, .location, .signIn, .emailEntry, .emailVerification]
        )
    }

    func testBackingOutOfAccountWalksBackThroughTheQuestions() {
        let (storage, suiteName) = makeStorage("OnboardingAccountReview")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)
        model.beginFirstPlant()
        model.step = .signIn

        model.backFromAccountGate()
        XCTAssertEqual(model.step, .location)
        model.back()
        XCTAssertEqual(model.step, .firstPlantRoom)
        model.back()
        XCTAssertEqual(model.step, .firstPlantDetails)

        model.returnToAccountGate()
        XCTAssertEqual(model.step, .signIn)
    }

    func testNotificationAnalyticsDistinguishesSkipFromSystemDenial() {
        let skipped = OnboardingAnalytics.NotificationOutcome.primerSkipped
        let denied = OnboardingAnalytics.NotificationOutcome.systemDenied

        XCTAssertFalse(skipped.prompted)
        XCTAssertNil(skipped.granted)
        XCTAssertTrue(denied.prompted)
        XCTAssertEqual(denied.granted, false)
        XCTAssertNotEqual(skipped.rawValue, denied.rawValue)
    }

    func testKnownFirstPlantCopyNamesThePlantAndUsesItsActualCheckInCadence() {
        let presentation = OnboardingFirstPlantPresentation(
            nickname: "Monty",
            commonName: "Swiss cheese plant",
            scientificName: "Monstera deliciosa",
            identificationIsUnknown: false,
            followUpDays: 14,
            capturedAt: .now,
            photoData: nil
        )

        XCTAssertEqual(presentation.displayName, "Monty")
        XCTAssertEqual(presentation.identityLine, "Monty · Swiss cheese plant")
        XCTAssertEqual(presentation.carePlanDescription, "Care guide ready")
        XCTAssertEqual(presentation.firstCheckInDescription, "First check-in in 14 days")
        XCTAssertEqual(presentation.authTitle, "Save Monty.")
    }

    func testProvisionalFirstPlantDoesNotPromiseAConfirmedCarePlan() {
        let presentation = OnboardingFirstPlantPresentation(
            nickname: "Monstera", commonName: "Monstera", scientificName: "Monstera deliciosa",
            identificationIsUnknown: false, identificationIsProvisional: true,
            followUpDays: 14, capturedAt: .now, photoData: nil
        )
        XCTAssertEqual(presentation.carePlanDescription, "You can confirm the species later")
        XCTAssertTrue(presentation.identityLine.contains("Possible"))
    }

    func testCareBasicsUseTheCheckedProfileForAConfirmedSpecies() {
        let presentation = OnboardingFirstPlantPresentation(
            nickname: "Monty",
            commonName: "Swiss cheese plant",
            scientificName: "Monstera deliciosa",
            identificationIsUnknown: false,
            followUpDays: 3,
            capturedAt: .now,
            photoData: nil
        )

        let lines = OnboardingCareBasics.make(for: presentation).lines
        XCTAssertTrue(lines.contains(.init(label: "Water", text: "Almost dry, then soak")))
        XCTAssertTrue(lines.contains(.init(label: "Light", text: "Near a bright window, out of direct sun")))
        XCTAssertEqual(lines.last?.label, "Check-in")
        XCTAssertEqual(lines.last?.text, "Grove asks for a new photo in 3 days")
    }

    func testCareBasicsFallBackToHonestWateringForAnUnknownPlant() {
        let presentation = OnboardingFirstPlantPresentation(
            nickname: "Unknown plant",
            commonName: "Unknown plant",
            scientificName: "Identity uncertain",
            identificationIsUnknown: true,
            followUpDays: 3,
            capturedAt: .now,
            photoData: nil
        )

        let lines = OnboardingCareBasics.make(for: presentation).lines
        XCTAssertEqual(lines.first?.label, "Water")
        XCTAssertEqual(
            lines.first?.text,
            "Only when the top 2–3 cm of soil feels dry. Not on a fixed schedule."
        )
        XCTAssertFalse(lines.contains(where: { $0.label == "Light" }))
    }

    func testCareBasicsListTheScanFirstActions() {
        let presentation = OnboardingFirstPlantPresentation(
            nickname: "Monty",
            commonName: "Swiss cheese plant",
            scientificName: "Monstera deliciosa",
            identificationIsUnknown: false,
            followUpDays: 3,
            capturedAt: .now,
            photoData: nil,
            firstActions: ["Move it out of direct sun", "Check for pests under leaves"]
        )

        let lines = OnboardingCareBasics.make(for: presentation).lines
        XCTAssertTrue(lines.contains(.init(label: "First", text: "Move it out of direct sun")))
        XCTAssertTrue(lines.contains(.init(label: "Then", text: "Check for pests under leaves")))
    }

    func testProvisionalSpeciesGetsNoSpeciesCareClaims() {
        let presentation = OnboardingFirstPlantPresentation(
            nickname: "Monstera",
            commonName: "Monstera",
            scientificName: "Monstera deliciosa",
            identificationIsUnknown: false,
            identificationIsProvisional: true,
            followUpDays: 3,
            capturedAt: .now,
            photoData: nil
        )

        let lines = OnboardingCareBasics.make(for: presentation).lines
        XCTAssertFalse(lines.contains(where: { $0.label == "Light" }))
        XCTAssertTrue(lines.contains(where: {
            $0.label == "Water" &&
                $0.text == "Only when the top 2–3 cm of soil feels dry. Not on a fixed schedule."
        }))
    }

    func testFollowUpTomorrowPhrase() {
        let presentation = OnboardingFirstPlantPresentation(
            nickname: "Monty",
            commonName: "Swiss cheese plant",
            scientificName: "Monstera deliciosa",
            identificationIsUnknown: false,
            followUpDays: 1,
            capturedAt: .now,
            photoData: nil
        )

        let lines = OnboardingCareBasics.make(for: presentation).lines
        XCTAssertEqual(lines.last?.text, "Grove asks for a new photo tomorrow")
    }

    func testExplorationResumesWithoutQuestionsOrCredentials() {
        let (storage, suiteName) = makeStorage("ExploreResume")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)
        model.beginManualSetup()
        let restored = OnboardingModel(storage: storage)
        XCTAssertEqual(restored.step, .explore)
        XCTAssertNil(restored.authMethod)
        restored.advance()
        XCTAssertEqual(restored.step, .signIn)
        restored.backFromAccountGate()
        XCTAssertEqual(restored.step, .explore)
    }

    func testUnknownFirstPlantCopyKeepsTheResultWithoutMakingFailureTheHeadline() {
        let presentation = OnboardingFirstPlantPresentation(
            nickname: "Unknown plant",
            commonName: "Unknown plant",
            scientificName: "Identity uncertain",
            identificationIsUnknown: true,
            followUpDays: 1,
            capturedAt: .now,
            photoData: nil
        )

        XCTAssertEqual(presentation.displayName, "your plant")
        XCTAssertEqual(presentation.identityLine, "Your first plant")
        XCTAssertEqual(presentation.carePlanDescription, "You can confirm the species later")
        XCTAssertEqual(presentation.firstCheckInDescription, "First check-in tomorrow")
        XCTAssertEqual(presentation.authTitle, "Save your plant.")
        XCTAssertFalse(presentation.accessibilityDescription.contains("Unknown"))
        XCTAssertFalse(presentation.accessibilityDescription.contains("Identity uncertain"))
    }

    func testStartingTheScanFirstRouteDropsAnswersFromAnAbandonedManualAttempt() {
        let (storage, suiteName) = makeStorage("OnboardingFirstPlantIsolation")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)
        model.beginManualSetup()
        model.firstName = "Previous person"
        model.experience = "experienced"
        model.environment = "outdoor"
        model.challenge = "watering"
        model.email = "previous@example.com"
        model.verificationCode = "123456"
        model.back()

        model.beginFirstPlant()

        XCTAssertEqual(model.route, .newAccount)
        XCTAssertTrue(model.firstName.isEmpty)
        XCTAssertNil(model.experience)
        XCTAssertNil(model.environment)
        XCTAssertNil(model.challenge)
        XCTAssertTrue(model.email.isEmpty)
        XCTAssertTrue(model.verificationCode.isEmpty)
        XCTAssertTrue(model.plan.isEmpty)
    }

    /// The account is not the price of admission. Nothing about a person's
    /// identity is asked until they have answered the quiz, so the manual door
    /// leads straight into three questions and sign-in is the final step.
    func testSignInComesAfterExplorationWithoutRequiredQuestions() {
        let (storage, suiteName) = makeStorage("OnboardingDeferredAuth")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)
        model.beginQuiz()

        let steps = model.orderedSteps
        guard let signIn = steps.firstIndex(of: .signIn),
              let explore = steps.firstIndex(of: .explore) else {
            return XCTFail("The manual funnel must allow exploration before sign-in")
        }
        XCTAssertTrue(explore < signIn)
        XCTAssertFalse(steps.contains(.name))
        XCTAssertFalse(steps.contains(.location))
        XCTAssertEqual(steps.last, .signIn, "Successful signup should hand directly to Today")
        XCTAssertFalse(steps.contains(.planReveal), "The retired reveal page must not be in the live funnel")
        XCTAssertEqual(model.step, .explore)
    }

    func testBackUsesThePreviousStepAndAReversedTransition() {
        let (storage, suiteName) = makeStorage("OnboardingBackDirection")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)

        model.beginQuiz()
        model.advance()
        XCTAssertEqual(model.step, .signIn)
        XCTAssertEqual(model.navigationDirection, .forward)

        model.back()
        XCTAssertEqual(model.step, .explore)
        XCTAssertEqual(model.navigationDirection, .backward)

        model.advance()
        XCTAssertEqual(model.step, .signIn)
        XCTAssertEqual(
            model.navigationDirection,
            .forward,
            "Moving forward again must restore the normal transition direction"
        )
    }

    /// Someone who already has a Grove is never made to answer questions they
    /// answered the first time.
    func testTheReturningRouteSkipsTheQuizEntirely() {
        let (storage, suiteName) = makeStorage("OnboardingReturning")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)
        model.signInToExistingAccount()

        XCTAssertEqual(model.step, .signIn)
        XCTAssertEqual(model.orderedSteps, [.welcome, .signIn])

        model.authMethod = .email
        XCTAssertEqual(model.orderedSteps, [.welcome, .signIn, .emailEntry, .emailVerification])

        // Backing out of the returning door drops the route with it, so the
        // welcome screen can't be left half-committed to the other path.
        model.step = .signIn
        model.back()
        XCTAssertEqual(model.step, .welcome)
        XCTAssertEqual(model.route, .newAccount)
        XCTAssertNil(model.authMethod)
    }

    // MARK: - Resuming an interrupted draft

    func testLegacyQuizDraftWithoutAFlowVersionResumesOnManualRoute() throws {
        let (storage, suiteName) = makeStorage("OnboardingLegacyDraft")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let legacy = """
        {
          "step": "challenge",
          "route": "newAccount",
          "firstName": "Priya",
          "experience": "new",
          "environment": "indoor",
          "overcome": [],
          "challenge": "watering"
        }
        """
        storage.set(try XCTUnwrap(legacy.data(using: .utf8)), forKey: "grove.onboarding.draft.v1")

        let resumed = OnboardingModel(storage: storage)

        XCTAssertEqual(resumed.route, .manual)
        XCTAssertEqual(resumed.step, .signIn)
        XCTAssertFalse(resumed.orderedSteps.contains(.name))
        XCTAssertFalse(resumed.orderedSteps.contains(.firstPlantScan))
    }

    func testPreNameValueFirstDraftResumesAtAccountGateWithoutLosingItsRoute() throws {
        let (storage, suiteName) = makeStorage("OnboardingResumeRequiredName")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let legacy = """
        {
          "flowVersion": 3,
          "step": "location",
          "route": "newAccount",
          "firstName": "",
          "overcome": []
        }
        """
        storage.set(try XCTUnwrap(legacy.data(using: .utf8)), forKey: "grove.onboarding.draft.v1")

        let resumed = OnboardingModel(storage: storage)

        XCTAssertEqual(resumed.route, .newAccount)
        XCTAssertEqual(resumed.step, .location, "The home question is live again, so a draft resumes on it")
        XCTAssertTrue(resumed.orderedSteps.contains(.firstPlantScan))
        XCTAssertTrue(resumed.orderedSteps.contains(.firstPlantDetails))
    }

    /// Every provider credential dies with the process, so no draft may resume
    /// still holding a spent method. Completion now refuses a missing
    /// credential; routing back through sign-in lets the person recover.
    ///
    /// A draft interrupted *mid-quiz* resumes on the question it stopped on.
    /// The gate is after the quiz now, so the user reaches it with every answer
    /// given rather than being thrown to a provider list holding half a plan.
    /// (Such a draft can only come from the old auth-first build, which stamped
    /// a method before the questions.)
    func testAnInterruptedQuizDraftResumesOnItsQuestionWithoutASpentCredential() {
        for method in [OnboardingAuthMethod.apple, .google, .email] {
            let (storage, suiteName) = makeStorage("OnboardingResumeQuiz-\(method.rawValue)")
            defer { storage.removePersistentDomain(forName: suiteName) }

            let interrupted = OnboardingModel(storage: storage)
            interrupted.authMethod = method
            interrupted.firstName = "Priya"
            interrupted.experience = "new"
            interrupted.step = .challenge
            interrupted.persistDraft()

            let resumed = OnboardingModel(storage: storage)
            XCTAssertEqual(resumed.step, .signIn, "\(method) keeps answers without repeating retired questions")
            XCTAssertNil(resumed.authMethod, "\(method) must not resume holding a spent method")
            XCTAssertEqual(resumed.trimmedFirstName, "Priya")
            XCTAssertEqual(resumed.experience, "new")
            XCTAssertTrue(
                resumed.orderedSteps.contains(.signIn),
                "\(method) must still be made to sign in before Today"
            )
        }
    }

    /// A draft interrupted at or past the gate has spent its credential, so it
    /// reopens on sign-in — with the answers intact, because they were collected
    /// before it.
    func testADraftInterruptedAtTheGateResumesAtSignIn() {
        for step in [OnboardingModel.Step.signIn, .accountNotFound, .emailEntry, .emailVerification, .planReveal] {
            let (storage, suiteName) = makeStorage("OnboardingResumeGate-\(step.rawValue)")
            defer { storage.removePersistentDomain(forName: suiteName) }

            let interrupted = OnboardingModel(storage: storage)
            interrupted.authMethod = .email
            interrupted.firstName = "Priya"
            interrupted.experience = "new"
            interrupted.environment = "indoor"
            interrupted.challenge = "watering"
            interrupted.location = makeLocation()
            interrupted.step = step
            interrupted.persistDraft()

            let resumed = OnboardingModel(storage: storage)
            XCTAssertEqual(resumed.step, .signIn, "\(step) must re-authenticate on resume")
            XCTAssertNil(resumed.authMethod, "\(step) must not resume holding a spent method")
            // The point of sending them back is the credential, not the quiz.
            XCTAssertEqual(resumed.trimmedFirstName, "Priya")
            XCTAssertEqual(resumed.experience, "new")
            XCTAssertEqual(resumed.challenge, "watering")
            XCTAssertEqual(resumed.location, makeLocation())
        }
    }

    func testPreLocationDraftAtTheAccountGateResumesAtSignIn() throws {
        let (storage, suiteName) = makeStorage("OnboardingResumeOptionalLocation")
        defer { storage.removePersistentDomain(forName: suiteName) }

        let legacy = """
        {
          "flowVersion": 2,
          "step": "signIn",
          "route": "manual",
          "authMethod": "google",
          "firstName": "Priya",
          "experience": "new",
          "environment": "indoor",
          "overcome": [],
          "challenge": "watering"
        }
        """
        storage.set(
            try XCTUnwrap(legacy.data(using: .utf8)),
            forKey: "grove.onboarding.draft.v1"
        )

        let resumed = OnboardingModel(storage: storage)

        XCTAssertEqual(resumed.step, .signIn)
        XCTAssertNil(resumed.location)
        XCTAssertNil(resumed.authMethod)
    }

    func testManualOnboardingCanCompleteWithoutLocation() async {
        let (storage, suiteName) = makeStorage("OnboardingOptionalLocation")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)
        let service = SessionService(storage: storage)
        model.beginManualSetup()
        model.firstName = "Ari"
        model.step = .signIn

        let completed = await model.completeSignup(using: service, method: .device)

        XCTAssertTrue(completed)
        XCTAssertNil(service.currentSession?.location)
        XCTAssertEqual(service.state, .signedIn(service.currentSession!))
    }

    func testManualOnboardingCanCompleteWithNeutralNameFallback() async {
        let (storage, suiteName) = makeStorage("OnboardingOptionalName")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)
        let service = SessionService(storage: storage)
        model.beginManualSetup()
        model.location = makeLocation()
        model.step = .signIn

        let completed = await model.completeSignup(using: service, method: .device)

        XCTAssertTrue(completed)
        XCTAssertEqual(service.currentSession?.displayName, "Gardener")
    }

    /// The returning door holds no state worth resuming, so a killed app reopens
    /// on the welcome screen rather than a provider list with no way back.
    func testAnInterruptedReturningDraftReopensAtTheWelcomeScreen() {
        let (storage, suiteName) = makeStorage("OnboardingResumeReturning")
        defer { storage.removePersistentDomain(forName: suiteName) }

        let interrupted = OnboardingModel(storage: storage)
        interrupted.signInToExistingAccount()
        interrupted.authMethod = .email
        interrupted.step = .emailVerification
        interrupted.persistDraft()

        let resumed = OnboardingModel(storage: storage)
        XCTAssertEqual(resumed.step, .welcome)
        XCTAssertEqual(resumed.route, .newAccount)
        XCTAssertNil(resumed.authMethod)
    }

    /// Every remaining method carries a credential, so there is no longer a
    /// resume-in-place case: `testAnInterruptedProviderDraftResumesAtSignIn`
    /// above now covers the whole enum. The guest path that used to resume
    /// where it stopped has been removed from the product.
    func testEveryAuthMethodMustReauthenticateOnResume() {
        for method in [OnboardingAuthMethod.apple, .google, .email] {
            XCTAssertTrue(
                method.needsReauthenticationOnResume,
                "\(method) must reauthenticate because its credential is process-local"
            )
        }
        XCTAssertFalse(OnboardingAuthMethod.device.needsReauthenticationOnResume)
    }

    func testEachPrimaryChallengeProducesOneTruthfulPlanFocus() {
        let expected = [
            "watering": "watering",
            "light": "light",
            "pests": "pests",
            "id": "unknown-needs",
        ]

        for (challenge, focus) in expected {
            let (storage, suiteName) = makeStorage("OnboardingFocus-\(challenge)")
            defer { storage.removePersistentDomain(forName: suiteName) }
            let model = OnboardingModel(storage: storage)
            model.challenge = challenge
            XCTAssertEqual(model.plan.focuses, [focus])
        }
    }

    func testCompletingOnboardingCarriesThePlanOntoTheEstablishedSession() async {
        let (storage, suiteName) = makeStorage("SessionPlanHandoff")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage)
        let plan = makePlan()

        await service.completeOnboarding(method: .device, displayName: "Ari", plan: plan)

        XCTAssertEqual(service.currentSession?.plan, plan)
        // The session is persisted at establish time, so a relaunch between
        // finishing onboarding and opening the grove cannot lose the answers.
        XCTAssertEqual(SessionService(storage: storage).currentSession?.plan, plan)
    }

    func testCompletingOnboardingCarriesLocationAcrossTheAccountBoundary() async {
        let (storage, suiteName) = makeStorage("SessionLocationHandoff")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage)
        let location = makeLocation()

        await service.completeOnboarding(
            method: .device,
            displayName: "Ari",
            location: location
        )

        XCTAssertEqual(service.currentSession?.location, location)
        XCTAssertEqual(SessionService(storage: storage).currentSession?.location, location)
    }

    func testAnUnansweredPlanIsNotCarriedOntoTheSession() async {
        let (storage, suiteName) = makeStorage("SessionEmptyPlan")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage)

        await service.completeOnboarding(method: .device, displayName: "Ari", plan: GrovePlan())

        XCTAssertNil(service.currentSession?.plan)
    }

    // MARK: - Store

    func testActivatingAFreshAccountWritesThePlanOntoTheProfile() {
        let (storage, suiteName) = makeStorage("StoreFreshPlan")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let store = GroveStore(persistenceEnabled: false, storage: storage)
        let plan = makePlan()

        store.activate(
            session: UserSession(accountID: "acct-fresh", mode: .local, displayName: "Ari", plan: plan)
        )

        XCTAssertEqual(store.profile.plan, plan)
    }

    func testActivatingAFreshAccountWritesOnboardingLocationOntoTheProfile() {
        let (storage, suiteName) = makeStorage("StoreFreshLocation")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let store = GroveStore(persistenceEnabled: false, storage: storage)
        let location = makeLocation()

        store.activate(
            session: UserSession(
                accountID: "acct-location",
                mode: .local,
                displayName: "Ari",
                location: location
            )
        )

        XCTAssertEqual(store.profile.location, location)
    }

    func testAPlanPersistsAcrossRelaunchAndSurvivesASessionCarryingNone() {
        let (storage, suiteName) = makeStorage("StorePlanPersistence")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let plan = makePlan()

        let first = GroveStore(persistenceEnabled: true, storage: storage)
        first.activate(
            session: UserSession(accountID: "acct-persist", mode: .local, displayName: "Ari", plan: plan)
        )
        XCTAssertEqual(first.profile.plan, plan)

        // A relaunch establishes the stored session, which no longer carries a
        // plan; the snapshot's plan must survive that.
        let second = GroveStore(persistenceEnabled: true, storage: storage)
        second.activate(
            session: UserSession(accountID: "acct-persist", mode: .local, displayName: "Ari")
        )
        XCTAssertEqual(second.profile.plan, plan)
    }

    func testOnboardingLocationFillsAnExistingSnapshotThatHasNoLocation() {
        let (storage, suiteName) = makeStorage("StoreExistingSnapshotLocation")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let accountID = "acct-existing-location"

        let first = GroveStore(persistenceEnabled: true, storage: storage)
        first.activate(
            session: UserSession(accountID: accountID, mode: .apple, displayName: "Ari")
        )
        XCTAssertNil(first.profile.location)

        let location = makeLocation()
        let second = GroveStore(persistenceEnabled: true, storage: storage)
        second.activate(
            session: UserSession(
                accountID: accountID,
                mode: .apple,
                displayName: "Ari",
                location: location
            )
        )

        XCTAssertEqual(second.profile.location, location)
    }

    func testAFreshlyBuiltPlanWinsOverTheStoredOne() {
        let (storage, suiteName) = makeStorage("StorePlanRebuild")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let first = GroveStore(persistenceEnabled: true, storage: storage)
        first.activate(
            session: UserSession(accountID: "acct-rebuild", mode: .local, displayName: "Ari", plan: makePlan())
        )

        let rebuilt = GrovePlan(experience: "experienced", environment: "indoor", challenge: "light")
        let second = GroveStore(persistenceEnabled: true, storage: storage)
        second.activate(
            session: UserSession(accountID: "acct-rebuild", mode: .local, displayName: "Ari", plan: rebuilt)
        )

        XCTAssertEqual(second.profile.plan, rebuilt, "Answers given seconds ago beat the stored copy")
    }

    func testUpdatingThePlanStoresItAndClearingItRemovesIt() {
        let (storage, suiteName) = makeStorage("StoreUpdatePlan")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let store = GroveStore(persistenceEnabled: false, storage: storage)
        let plan = makePlan()

        store.updatePlan(plan)
        XCTAssertEqual(store.profile.plan, plan)

        // An entirely unanswered plan is stored as nil so My Grove offers to
        // build one instead of rendering a blank card.
        store.updatePlan(GrovePlan())
        XCTAssertNil(store.profile.plan)
    }

    func testBootstrapReplacementKeepsAPlanTheServerDoesNotYetStore() {
        let (storage, suiteName) = makeStorage("StoreBootstrapPlan")
        defer { storage.removePersistentDomain(forName: suiteName) }
        let store = GroveStore(plants: [], persistenceEnabled: false, storage: storage)
        let plan = makePlan()
        store.updatePlan(plan)

        let remoteProfile = UserProfile(
            name: "Ari",
            username: "ari",
            initials: "A",
            friendCount: 0
        )
        XCTAssertNil(remoteProfile.plan, "The API contract does not carry the plan yet")

        let applied = store.replace(
            with: GroveBootstrapResponse(
                profile: remoteProfile,
                plants: [],
                tasks: [],
                activity: [],
                assignments: [],
                observations: [],
                friends: nil,
                friendInvitations: nil,
                serverTime: Date()
            )
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(store.profile.plan, plan, "A sync must not delete the plan the user just built")
    }
}
