import XCTest

/// A read-only walk through the Ask tab's guides that saves a screenshot at
/// every stop. It opens a guide, scrolls it, follows "Next" once, and never
/// answers a lesson's question (that would pay XP and mark it learned).
@MainActor
final class GroveGuidesTourTests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    func testGuidesTour() {
        let ask = app.tabBars.buttons["Ask"]
        guard ask.waitForExistence(timeout: 20) else {
            shot("launch-no-tab-bar")
            return
        }
        ask.tap()
        sleep(2)

        let guide = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'minute read'")).firstMatch
        for _ in 0..<6 where !(guide.exists && guide.isHittable) {
            app.swipeUp(velocity: .slow)
            sleep(1)
        }
        shot("ask-guides")
        guard guide.exists, guide.isHittable else { return }
        guide.tap()
        sleep(2)

        shot("guide-top")
        for index in 1...6 {
            app.swipeUp(velocity: .slow)
            sleep(1)
            shot("guide-scroll\(index)")
        }

        let next = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Next lesson'")).firstMatch
        if next.waitForExistence(timeout: 3), next.isHittable {
            next.tap()
            sleep(2)
            shot("next-guide-top")
            app.swipeUp(velocity: .slow)
            sleep(1)
            shot("next-guide-scroll1")
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
