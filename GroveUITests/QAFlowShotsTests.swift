import XCTest

/// QA-only: drives the demo app through the states that only exist mid-flow
/// (sheets, scan results, banners, an Ask answer) and saves a screenshot at
/// each. Skips unless `GROVE_QA_SHOT_DIR` is set, so ordinary runs stay green.
@MainActor
final class QAFlowShotsTests: XCTestCase {
    private var directory: URL!
    private var prefix = "light"

    private func prepare() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["GROVE_QA_SHOT_DIR"], !raw.isEmpty else {
            throw XCTSkip("Set GROVE_QA_SHOT_DIR to capture flow screenshots")
        }
        directory = URL(fileURLWithPath: raw, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prefix = environment["GROVE_QA_PREFIX"] ?? "light"
        continueAfterFailure = true
    }

    private func demoApp(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-GroveUseFixtureAnalysis",
            "-GroveResetFirstPlantActivation",
            "-GroveUITestDemoAccount",
            UUID().uuidString,
        ] + extra
        app.launch()
        _ = app.tabBars.buttons["Today"].waitForExistence(timeout: 15)
        sleep(2)
        return app
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let entry = "\(prefix)-flow-\(name)"
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(entry).png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = entry
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tapIfPresent(_ element: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        element.tap()
        return true
    }

    func testScanFlows() throws {
        try prepare()
        for mode in ["identify", "add", "diagnose"] {
            let app = demoApp()
            guard tapIfPresent(app.buttons["scanButton"]) else { shot("no-scan-button"); return }
            sleep(1)
            shot("01-scan-intent-picker")
            guard tapIfPresent(app.buttons["scanIntent.\(mode)"]) else { continue }
            // Wait for the tips sheet to finish presenting, not a fixed delay:
            // two seconds caught it mid-slide with its action bar off screen.
            let gotIt = app.buttons["scanTipsGotIt"]
            if gotIt.waitForExistence(timeout: 6) {
                let deadline = Date().addingTimeInterval(6)
                while !gotIt.isHittable, Date() < deadline { usleep(200_000) }
            }
            sleep(1)
            shot("02-scan-\(mode)-first-open")
            _ = tapIfPresent(app.buttons["scanTipsGotIt"], timeout: 2)
            sleep(1)
            shot("03-scan-\(mode)-camera")
            if tapIfPresent(app.buttons["scanUseSample"]) {
                sleep(1)
                if mode == "diagnose" { _ = tapIfPresent(app.buttons["scanUseSample"], timeout: 3) }
                sleep(5)
                shot("04-scan-\(mode)-result")
                app.swipeUp()
                sleep(1)
                shot("05-scan-\(mode)-result-scrolled")
                if mode == "add", tapIfPresent(app.buttons["scanLiveCardContinue"]) {
                    sleep(3)
                    shot("06-scan-add-new-plant-page")
                }
            }
            app.terminate()
        }
    }

    func testAskConversation() throws {
        try prepare()
        let app = demoApp(["-GroveLaunchTab", "ask"])
        _ = tapIfPresent(app.tabBars.buttons["Ask"])
        sleep(2)
        shot("10-ask")
        let suggestion = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ask: ")).firstMatch
        if tapIfPresent(suggestion) {
            _ = app.descendants(matching: .any)["botanistAnswer"].waitForExistence(timeout: 10)
            sleep(2)
            shot("11-ask-answer")
        }
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        if tapIfPresent(field, timeout: 2) {
            sleep(1)
            shot("12-ask-keyboard")
        }
    }

    func testAskMeterAndBanners() throws {
        try prepare()
        var app = demoApp(["-GroveForceAskMeter"])
        _ = tapIfPresent(app.tabBars.buttons["Ask"])
        sleep(2)
        shot("20-ask-meter")
        app.terminate()

        app = demoApp(["-GroveForceTravelBanner"])
        shot("21-today-travel-banner")
        app.terminate()

        app = demoApp(["-GroveForceMoveBanner"])
        // The move banner sits below the fold on Today; scroll until its
        // primary action is on screen rather than shooting the top of the page.
        let stayPut = app.buttons["moveStayPut"]
        var swipes = 0
        while !(stayPut.exists && stayPut.isHittable), swipes < 6 {
            app.swipeUp()
            sleep(1)
            swipes += 1
        }
        shot("22-today-move-banner")
        app.terminate()
    }

    func testTodayInteractions() throws {
        try prepare()
        let app = demoApp()
        shot("30-today")
        let task = app.descendants(matching: .any).matching(identifier: "careTask.Monty").firstMatch
        if tapIfPresent(task) {
            sleep(2)
            shot("31-care-task-detail")
            app.navigationBars.buttons.firstMatch.tap()
        }
        if tapIfPresent(app.buttons["Updates"]) {
            sleep(2)
            shot("32-updates")
            app.navigationBars.buttons.firstMatch.tap()
        }
        app.tabBars.buttons["My Grove"].tap()
        let monty = app.buttons.matching(identifier: "plantCard.Monty").firstMatch
        var attempts = 0
        while !monty.exists && attempts < 6 { app.swipeUp(); attempts += 1 }
        if tapIfPresent(monty) {
            sleep(2)
            shot("33-plant-monty")
            if tapIfPresent(app.buttons["plantDockedCheckIn"]) {
                sleep(2)
                shot("34-checkin-step1")
                if tapIfPresent(app.buttons["checkInNext"]) {
                    sleep(2)
                    shot("35-checkin-step2")
                }
            }
        }
    }

    func testOnboardingFlow() throws {
        try prepare()
        let app = XCUIApplication()
        app.launchArguments = [
            "-GrovePreviewSignedOut",
            "-GroveResetOnboarding",
            "-GroveUITestSkipSignIn",
            "-GroveUseFixtureAnalysis",
            "-GroveUITestOnboardingSample",
        ]
        app.launch()
        sleep(3)
        shot("40-onb-first-camera")
        if tapIfPresent(app.buttons["scanLiveCardContinue"], timeout: 8) {
            sleep(2)
            shot("41-onb-after-result")
        }
        if tapIfPresent(app.buttons["profileSetupSkip"], timeout: 6) { sleep(2) }
        if app.otherElements["firstPlantNotificationPrimer"].waitForExistence(timeout: 8) {
            shot("42-onb-first-week")
            _ = tapIfPresent(app.buttons["onboardingFinishSetup"])
            sleep(2)
            shot("43-onb-reminder-ask")
            _ = tapIfPresent(app.buttons["skipFirstPlantNotifications"], timeout: 3)
        }
        sleep(2)
        shot("44-onb-landed")

        let signIn = XCUIApplication()
        signIn.launchArguments = ["-GrovePreviewSignedOut", "-GroveResetOnboarding", UUID().uuidString]
        signIn.launch()
        sleep(3)
        shot("45-welcome")
        if tapIfPresent(signIn.buttons["onboardingSignIn"]) {
            sleep(2)
            shot("46-sign-in-providers")
            if tapIfPresent(signIn.buttons["continueWithEmail"]) {
                sleep(2)
                shot("47-email-entry")
            }
        }
    }

    func testNewAccountProfileSetup() throws {
        try prepare()
        let app = XCUIApplication()
        app.launchArguments = ["-GroveUseFixtureAnalysis", "-GroveResetFirstPlantActivation", "-GroveUITestAppleAccount", UUID().uuidString]
        app.launch()
        sleep(4)
        shot("50-new-account-setup")
        let username = app.textFields["profileUsername"]
        if tapIfPresent(username) {
            username.typeText("qa")
            sleep(1)
            shot("51-setup-keyboard")
        }
        app.terminate()
        app.launch()
        sleep(3)
        if tapIfPresent(app.buttons["profileSetupSkip"], timeout: 3) { sleep(2) }
        _ = tapIfPresent(app.buttons["saveProfile"], timeout: 2)
        sleep(2)
        shot("52-new-account-after-setup")
        if tapIfPresent(app.tabBars.buttons["My Grove"]) {
            sleep(2)
            shot("53-empty-mygrove")
        }
    }
}
