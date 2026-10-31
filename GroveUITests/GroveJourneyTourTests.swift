import XCTest

/// A read-only look at the Journey that saves a screenshot at every stop. It
/// opens the page from My Grove and scrolls it. It never opens a chest, answers
/// a quiz or collects a quest, because each of those pays XP.
@MainActor
final class GroveJourneyTourTests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    func testJourneyTour() {
        let myGrove = app.tabBars.buttons["My Grove"]
        guard myGrove.waitForExistence(timeout: 20) else {
            shot("launch-no-tab-bar")
            return
        }
        myGrove.tap()
        sleep(2)

        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Your journey'")).firstMatch
        for _ in 0..<4 where !(entry.exists && entry.isHittable) {
            app.swipeUp(velocity: .slow)
            sleep(1)
        }
        guard entry.exists, entry.isHittable else {
            shot("no-journey-entry")
            return
        }
        entry.tap()
        sleep(3)

        shot("journey-top")
        for index in 1...4 {
            app.swipeUp(velocity: .slow)
            sleep(1)
            shot("journey-scroll\(index)")
        }

        // A finished step's page: read-only, it pays nothing.
        let done = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] ', done'")).firstMatch
        if done.waitForExistence(timeout: 3), done.isHittable {
            done.tap()
            sleep(2)
            shot("step-sheet")
            app.swipeDown(velocity: .fast)
            sleep(2)
        }

        // Today's three, opened from a row that is not ready to collect.
        let quest = app.buttons.matching(NSPredicate(format: "label ENDSWITH[c] ' XP' AND NOT (label CONTAINS[c] 'Collect')")).allElementsBoundByIndex.last
        if let quest, quest.exists, quest.isHittable {
            quest.tap()
            sleep(2)
            shot("todays-three")
            app.swipeDown(velocity: .fast)
            sleep(2)
        }

        for _ in 0..<6 { app.swipeDown(velocity: .fast) }
        sleep(1)
        let badges = app.buttons["Badges"]
        if badges.waitForExistence(timeout: 3), badges.isHittable {
            badges.tap()
            sleep(2)
            shot("badges-top")
            for index in 1...2 {
                app.swipeUp(velocity: .slow)
                sleep(1)
                shot("badges-scroll\(index)")
            }
        }
    }

    private func shot(_ name: String) {
        step += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%02d-%@", step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
