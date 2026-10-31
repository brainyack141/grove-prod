import XCTest

/// A read-only look at the plant board's "Water every" cell and the sheet it
/// opens. It opens a plant, taps the cell, and closes the sheet with Done. It
/// never taps the sheet's check-in or edit button.
///
/// Run with `scripts/visual-tour.sh` by swapping `-only-testing` to
/// `GroveUITests/GroveWateringTourTests`.
@MainActor
final class GroveWateringTourTests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    func testWateringSheet() {
        guard app.tabBars.buttons["My Grove"].waitForExistence(timeout: 20) else {
            shot("launch-no-tab-bar")
            return
        }
        app.tabBars.buttons["My Grove"].tap()
        sleep(2)

        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'plantCard.'")).firstMatch
        guard card.waitForExistence(timeout: 6) else {
            shot("no-plant-card")
            return
        }
        card.tap()
        sleep(3)

        let cell = app.buttons["plantWaterEvery"]
        for _ in 0..<4 where !(cell.exists && cell.isHittable) {
            app.swipeUp(velocity: .slow)
            sleep(1)
        }
        shot("board-cell")
        guard cell.exists, cell.isHittable else { return }

        cell.tap()
        sleep(2)
        shot("sheet-medium")

        app.swipeUp(velocity: .slow)
        sleep(1)
        shot("sheet-large")
        app.swipeUp(velocity: .slow)
        sleep(1)
        shot("sheet-large-scrolled")

        let done = app.buttons["Done"]
        if done.exists { done.tap() }
        sleep(1)
    }

    private func shot(_ name: String) {
        step += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%02d-%@", step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
