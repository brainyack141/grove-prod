import XCTest

@MainActor
final class GroveUITests: XCTestCase {
    func testOnboardingLandsOnTodayAfterSignup() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-GrovePreviewSignedOut",
            "-GroveResetOnboarding",
            "-GroveUITestSkipSignIn",
            "-GroveUseFixtureAnalysis",
            "-GroveUITestOnboardingSample",
        ]
        app.launch()

        let keepReading = app.buttons["scanLiveCardContinue"]
        XCTAssertTrue(
            keepReading.waitForExistence(timeout: 8),
            "Onboarding should open directly into the guided camera and resolve its result in context."
        )
        XCTAssertFalse(
            app.buttons["scanTipsGotIt"].exists,
            "The welcome demo and viewfinder guidance replace a blocking tips sheet."
        )
        keepReading.tap()

        XCTAssertFalse(
            app.otherElements["onboardingPaywall"].waitForExistence(timeout: 2),
            "Premium must not stand between the scanned plant and the account that saves it."
        )
        XCTAssertFalse(
            app.buttons["onboardingKeepFirstPlant"].exists,
            "The accepted in-context result should not be repeated on a second payoff screen."
        )
        XCTAssertFalse(app.textFields["onboardingNameField"].exists)
        XCTAssertFalse(app.buttons["onboardingSaveLocation"].exists)

        // The account exists now. The name question is optional and asked
        // once, inside the signed-in shell.
        let skipName = app.buttons["profileSetupSkip"]
        if skipName.waitForExistence(timeout: 8) {
            skipName.tap()
        }

        let firstWeek = app.otherElements["firstPlantNotificationPrimer"]
        XCTAssertTrue(
            firstWeek.waitForExistence(timeout: 8),
            "The first baseline should import before Grove shows the first week's plan."
        )
        app.buttons["onboardingFinishSetup"].tap()
        // The reminder ask only rises while iOS has not been asked yet.
        let skipReminders = app.buttons["skipFirstPlantNotifications"]
        if skipReminders.waitForExistence(timeout: 3) {
            skipReminders.tap()
        }

        XCTAssertTrue(
            app.tabBars.buttons["Today"].waitForExistence(timeout: 8),
            "Successful signup should open the Today tab."
        )
        app.tabBars.buttons["My Grove"].tap()
        XCTAssertTrue(
            app.buttons["plantCard.Swiss cheese plant"].waitForExistence(timeout: 8),
            "The scan-first handoff should create exactly the plant whose baseline was shown."
        )
    }

    func testConfiguredAccountSignInShowsProviderButtons() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-GrovePreviewSignedOut",
            "-GroveResetOnboarding",
            UUID().uuidString,
        ]
        app.launch()

        let signIn = app.buttons["onboardingSignIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 8))
        signIn.tap()

        XCTAssertTrue(app.buttons["signInWithApple"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["continueWithGoogle"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["continueWithEmail"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Account sign-in isn't configured in this development build."].exists)
    }

    func testCoreNavigationAndSocialEntryPoint() {
        continueAfterFailure = false
        let app = XCUIApplication()
        configureFixtureDemo(app)
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 8))

        // The fixture's only due soil check belongs to Monty, so Today's
        // "Due today" section should list it by name and open his care task.
        let montyTask = app.descendants(matching: .any).matching(identifier: "careTask.Monty").firstMatch
        XCTAssertTrue(
            montyTask.waitForExistence(timeout: 3),
            "A due soil check should appear under Due today."
        )
        montyTask.tap()
        XCTAssertTrue(app.buttons["completeCareTask"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["snoozeCareTask"].exists)
        app.navigationBars.buttons["Back"].tap()

        app.tabBars.buttons["My Grove"].tap()
        XCTAssertTrue(app.navigationBars["My Grove"].waitForExistence(timeout: 3))
        let montyCard = app.buttons.matching(identifier: "plantCard.Monty").firstMatch
        var montyAttempts = 0
        while !montyCard.exists && montyAttempts < 6 {
            app.swipeUp()
            montyAttempts += 1
        }
        XCTAssertTrue(montyCard.waitForExistence(timeout: 3))

        app.buttons["scanButton"].tap()
        XCTAssertTrue(app.otherElements["scanIntentPicker"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["scanIntent.add"].exists)
        XCTAssertTrue(app.buttons["scanIntent.identify"].exists)
        XCTAssertTrue(app.buttons["scanIntent.diagnose"].exists)
        app.buttons["scanIntent.identify"].tap()
        dismissScanTipsIfNeeded(app)
        let sample = app.buttons["scanUseSample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 3))
        sample.tap()
        XCTAssertTrue(app.buttons["scanLiveCardContinue"].waitForExistence(timeout: 8))
        app.buttons["scanRetake"].tap()
        // Scan covers the app rather than living in a tab, so the bar is only
        // reachable again once the cover is down.
        app.buttons["scanBack"].tap()

        app.tabBars.buttons["Today"].tap()
        app.buttons["Updates"].tap()
        XCTAssertTrue(app.navigationBars["Updates"].waitForExistence(timeout: 3))
        app.navigationBars.buttons["Back"].tap()

        app.tabBars.buttons["My Grove"].tap()
        XCTAssertTrue(app.navigationBars["My Grove"].waitForExistence(timeout: 3))
        let friendsHeader = app.staticTexts["Friends"]
        var friendsAttempts = 0
        while !friendsHeader.exists && friendsAttempts < 8 {
            app.swipeUp()
            friendsAttempts += 1
        }
        XCTAssertTrue(friendsHeader.waitForExistence(timeout: 3))
    }

    func testBotanistQuestionCompletesAndRendersAnAnswer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        configureFixtureDemo(app)
        app.launch()

        let botanistTab = app.tabBars.buttons["Ask"]
        XCTAssertTrue(botanistTab.waitForExistence(timeout: 8))
        botanistTab.tap()

        XCTAssertFalse(
            app.buttons["askDailyQuestion"].exists,
            "The Ask tab should not show a separate daily question card."
        )

        let firstSuggestion = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Ask: ")
        ).firstMatch
        XCTAssertTrue(
            firstSuggestion.waitForExistence(timeout: 5),
            "The Ask tab should expose a grounded suggestion after the daily card is removed."
        )
        firstSuggestion.tap()

        let userMessage = app.descendants(matching: .any)["botanistUserMessage"]
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5))

        let answer = app.descendants(matching: .any)["botanistAnswer"]
        XCTAssertTrue(
            answer.waitForExistence(timeout: 8),
            "The queued question should reach the botanist client and render its answer."
        )
        XCTAssertTrue(answer.label.contains("While Ari is offline"))
        XCTAssertFalse(answer.label.contains("**"), "Markdown markers must not reach the rendered answer.")
        XCTAssertFalse(app.descendants(matching: .any)["botanistFailure"].exists)
    }

    func testPlantPageHidesTheAppBarAndDocksItsOwnActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        configureFixtureDemo(app)
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["My Grove"].waitForExistence(timeout: 8))
        app.tabBars.buttons["My Grove"].tap()

        let plantCard = app.buttons.matching(identifier: "plantCard.Monty").firstMatch
        var attempts = 0
        while !plantCard.exists && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(plantCard.waitForExistence(timeout: 3))
        plantCard.tap()

        // The fixture gives Monty a due check-in, so the page docks its own
        // check-in and defer actions. The shell's raised centre action was
        // scoped to the plant here too and rose straight through that bar, so a
        // drill-in now takes the full height and the page owns the bottom edge.
        let checkIn = app.buttons["plantDockedCheckIn"]
        XCTAssertTrue(
            checkIn.waitForExistence(timeout: 5),
            "An active plant page should dock its own check-in action."
        )
        XCTAssertFalse(app.buttons["plantCheckInButton"].exists)
        XCTAssertFalse(app.buttons["scanButton"].exists)

        checkIn.tap()
        XCTAssertTrue(app.buttons["checkInNext"].waitForExistence(timeout: 5))
    }

    func testNewAppleAccountCompletesSetupWithoutDemoPlants() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-GroveUseFixtureAnalysis",
            "-GroveResetFirstPlantActivation",
            "-GroveUITestAppleAccount",
            UUID().uuidString,
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Set up profile"].waitForExistence(timeout: 8))
        let username = app.textFields["profileUsername"]
        XCTAssertTrue(username.waitForExistence(timeout: 3))
        username.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            username.tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        username.typeText("aritest")
        dismissKeyboard(app)
        app.swipeUp()

        let saveButton = app.buttons["saveProfile"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3))
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()

        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 5))
        app.tabBars.buttons["My Grove"].tap()
        XCTAssertTrue(app.staticTexts["@aritest"].waitForExistence(timeout: 3))
        let emptyState = app.staticTexts["No plants yet"]
        var emptyAttempts = 0
        while !emptyState.exists && emptyAttempts < 6 {
            app.swipeUp()
            emptyAttempts += 1
        }
        XCTAssertTrue(emptyState.waitForExistence(timeout: 3))
    }

    func testIdentifiedPlantOffersIdentityCorrectionWithoutShowingAlternativesInline() {
        continueAfterFailure = false
        let app = XCUIApplication()
        configureFixtureDemo(app)
        app.launch()

        app.buttons["scanButton"].tap()
        XCTAssertTrue(app.buttons["scanIntent.identify"].waitForExistence(timeout: 3))
        app.buttons["scanIntent.identify"].tap()
        dismissScanTipsIfNeeded(app)
        let sample = app.buttons["scanUseSample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 8))
        sample.tap()

        // Grove states the identity without presenting alternate candidates.
        XCTAssertTrue(app.staticTexts["Swiss cheese plant"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["changeIdentity"].exists)
        XCTAssertFalse(app.staticTexts["Split-leaf philodendron"].exists)
        XCTAssertFalse(app.buttons["Search names"].exists)
    }

    func testCameraAnalysisAddsConfirmedPlantToGrove() {
        continueAfterFailure = false
        let app = XCUIApplication()
        configureFixtureDemo(app)
        app.launch()

        app.buttons["scanButton"].tap()
        XCTAssertTrue(app.buttons["scanIntent.add"].waitForExistence(timeout: 3))
        app.buttons["scanIntent.add"].tap()
        dismissScanTipsIfNeeded(app)
        let sample = app.buttons["scanUseSample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 3))
        sample.tap()

        // A decisive match is adopted from the result card in one tap. Naming,
        // room and light remain optional on the plant page.
        let addButton = app.buttons["scanLiveCardContinue"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 8))
        XCTAssertTrue(addButton.label.contains("Swiss cheese plant"))
        addButton.tap()

        let plantPage = app.buttons["Diagnose Swiss cheese plant"]
        XCTAssertTrue(plantPage.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Swiss cheese plant"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["finishPlantSetup"].exists)
    }

    func testDiagnosisScanCompletesWithoutAnalysisPaused() {
        continueAfterFailure = false
        let app = XCUIApplication()
        configureFixtureDemo(app)
        app.launch()

        app.buttons["scanButton"].tap()
        XCTAssertTrue(app.buttons["scanIntent.diagnose"].waitForExistence(timeout: 3))
        app.buttons["scanIntent.diagnose"].tap()
        dismissScanTipsIfNeeded(app)
        let sample = app.buttons["scanUseSample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 8))
        sample.tap()
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()

        XCTAssertTrue(app.staticTexts["What the scan found"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Leaf yellowing is visible, but a photo alone cannot confirm the cause."].exists)
        XCTAssertFalse(app.staticTexts["Can't analyse right now"].exists)
    }

    private func configureFixtureDemo(_ app: XCUIApplication) {
        app.launchArguments = [
            "-GroveUseFixtureAnalysis",
            "-GroveResetFirstPlantActivation",
            "-GroveUITestDemoAccount",
            UUID().uuidString,
        ]
    }

    /// Walks whatever remains of the first-run scan intro on the physical test
    /// device. The tips sheet is once per install, so a reset run sees it and a
    /// reused installation may not.
    private func dismissScanTipsIfNeeded(_ app: XCUIApplication) {
        let gotIt = app.buttons["scanTipsGotIt"]
        if gotIt.waitForExistence(timeout: 2) {
            gotIt.tap()
        }
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        for label in ["Done", "Return", "continue"] {
            let key = app.keyboards.buttons[label]
            if key.exists {
                key.tap()
                return
            }
        }
        XCTFail("Expected a keyboard dismissal key")
    }
}
