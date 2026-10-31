import XCTest

/// A read-only walk through the production app that saves a screenshot at
/// every stop, for visual review without anyone driving the phone.
///
/// It runs against whatever account is signed in on the device, so it only
/// looks: it opens tabs, pushes and pops screens, and scrolls. It never taps a
/// control that records care, accepts or sends anything, or changes settings.
@MainActor
final class GroveVisualTourTests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    func testVisualTour() {
        guard app.tabBars.buttons["Today"].waitForExistence(timeout: 20) else {
            shot("launch-no-tab-bar")
            return
        }
        sleep(2)

        // Today
        tour("today")
        if tap(app.buttons["Updates"]) {
            shot("today-updates")
            scrollShots("today-updates", times: 2)
            back()
        }
        if tap(firstPlantCard(in: "today")) {
            shot("plant-top")
            scrollShots("plant", times: 6)
            back()
        }

        // Ask
        if tapTab("Ask") {
            tour("ask")
        }

        // Friends
        if tapTab("Friends") {
            tour("friends")
            if tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Invitations'")).firstMatch) {
                shot("friends-invitations")
                back()
            }
        }

        // My Grove
        if tapTab("My Grove") {
            tour("mygrove", times: 5)
            scrollToTop()
            if tap(app.buttons["Settings and privacy"]) {
                shot("settings-top")
                scrollShots("settings", times: 4)
                back()
            }
            if tap(firstPlantCard(in: "mygrove")) {
                shot("mygrove-plant-top")
                scrollShots("mygrove-plant", times: 3)
                back()
            }
        }

        // Scan
        if tapTab("Today") {
            let scan = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'scan'")).firstMatch
            if tap(scan) {
                sleep(2)
                shot("scan-camera")
                // Dismiss without capturing anything.
                let close = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'close' OR label CONTAINS[c] 'cancel'")).firstMatch
                if close.waitForExistence(timeout: 3) { close.tap() }
            }
        }
    }

    // MARK: - Helpers

    private func tour(_ name: String, times: Int = 4) {
        shot("\(name)-top")
        scrollShots(name, times: times)
        scrollToTop()
    }

    private func scrollShots(_ name: String, times: Int) {
        for index in 1...times {
            app.swipeUp(velocity: .slow)
            sleep(1)
            shot("\(name)-scroll\(index)")
        }
    }

    private func scrollToTop() {
        for _ in 0..<6 { app.swipeDown(velocity: .fast) }
        sleep(1)
    }

    @discardableResult
    private func tapTab(_ label: String) -> Bool {
        let button = app.tabBars.buttons[label]
        guard button.waitForExistence(timeout: 5) else { return false }
        button.tap()
        sleep(2)
        return true
    }

    @discardableResult
    private func tap(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 4), element.isHittable else { return false }
        element.tap()
        sleep(2)
        return true
    }

    private func firstPlantCard(in screen: String) -> XCUIElement {
        let prefix = screen == "today" ? "todayRow." : "plantCard."
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        if card.exists { return card }
        // Today's rows are plain links labelled with the plant's name and status.
        return app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'overdue' OR label CONTAINS[c] 'urgent' OR label CONTAINS[c] 'today' OR label CONTAINS[c] 'late'")).firstMatch
    }

    private func back() {
        // Plant pages draw their own chrome, with a plain "Back" button.
        let custom = app.buttons["Back"]
        if custom.exists, custom.isHittable {
            custom.tap()
            sleep(2)
            return
        }
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists, backButton.isHittable {
            backButton.tap()
        } else {
            app.swipeRight()
        }
        sleep(2)
    }

    private func shot(_ name: String) {
        step += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%02d-%@", step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
