import XCTest
@testable import Grove

/// The plant page's "What changed" card makes the only causal-sounding claim in
/// Grove — "what helped" — off two dates and two numbers. These tests guard the
/// three refusals that keep that claim honest, and the reading of the record it
/// rests on.
final class PlantChangeStoryTests: XCTestCase {
    private let plantID = UUID()

    // MARK: - Timeline

    func testTimelineMergesCheckInsAndCareIntoOneChronology() {
        let story = PlantChangeStory.make(
            observations: [
                checkIn(daysAgo: 1, from: 70, to: 78),
                checkIn(daysAgo: 9, from: 66, to: 70)
            ],
            care: [
                care(.water, daysAgo: 4),
                care(.rotate, daysAgo: 6)
            ]
        )

        XCTAssertEqual(story.moments.count, 4)
        XCTAssertEqual(
            story.moments.map(\.headline),
            ["Holding steady", "Watered", "Turned the pot", "Holding steady"],
            "The card is a chronology: check-ins and care interleave, newest first."
        )
    }

    func testTimelineIgnoresOpenTasksAndTheCheckInErrandItself() {
        var open = care(.water, daysAgo: 2)
        open.isCompleted = false

        let story = PlantChangeStory.make(
            observations: [checkIn(daysAgo: 1, from: 70, to: 78), checkIn(daysAgo: 8, from: 70, to: 70)],
            care: [open, care(.checkIn, daysAgo: 1)]
        )

        XCTAssertEqual(
            story.moments.count,
            2,
            "A check-in arrives as an observation. Counting its task too draws every check-in twice."
        )
    }

    func testAnxiousWateringNeverPushesEveryReadingOffTheTimeline() {
        let readings = [
            checkIn(daysAgo: 10, from: 70, to: 72),
            checkIn(daysAgo: 20, from: 68, to: 70),
            checkIn(daysAgo: 30, from: 66, to: 68)
        ]
        // A week of daily fussing, all of it newer than every check-in.
        let fussing = (1...6).map { care(.water, daysAgo: $0) }

        let story = PlantChangeStory.make(observations: readings, care: fussing)
        let checkInCount = story.moments.filter {
            if case .checkIn = $0.kind { true } else { false }
        }.count

        XCTAssertEqual(story.moments.count, PlantChangeStory.momentLimit)
        XCTAssertEqual(
            checkInCount,
            PlantChangeStory.guaranteedCheckIns,
            "The card's whole subject is the readings. Care must never crowd all of them out."
        )
        XCTAssertEqual(story.moments.first?.headline, "Watered", "Still newest first once seated.")
    }

    func testCareBoilerplateNeverBecomesARowSubtitle() {
        var logged = care(.water, daysAgo: 2)
        logged.detail = GroveStore.selfLoggedCareDetail
        var noted = care(.prune, daysAgo: 3)
        noted.detail = "Took off the two brown tips."

        let story = PlantChangeStory.make(observations: [], care: [logged, noted])

        XCTAssertNil(story.moments.first?.detail)
        XCTAssertEqual(story.moments.last?.detail, "Took off the two brown tips.")
    }

    func testOfflineCheckInSaysSoAndShowsNoMovement() {
        var estimated = checkIn(daysAgo: 1, from: 70, to: 76)
        estimated.isEstimated = true

        let story = PlantChangeStory.make(observations: [estimated, checkIn(daysAgo: 8, from: 70, to: 70)], care: [])

        // An estimated check-in is one saved without photo analysis, which is
        // not always because the phone was offline. 6c785c9 changed the copy to
        // say so, matching the health card's "saved without photo analysis".
        XCTAssertEqual(story.moments.first?.detail, "Soil comfortable · saved without photo analysis")
        guard case .checkIn(_, _, let isEstimated) = story.moments.first?.kind else {
            return XCTFail("Expected a check-in moment.")
        }
        XCTAssertTrue(isEstimated)
    }

    // MARK: - Comparison

    func testComparisonSpansTheWholeVisibleWindowNotTheLastTwoCheckIns() {
        let oldest = checkIn(daysAgo: 20, from: 60, to: 62, photo: "oldest")
        let middle = checkIn(daysAgo: 10, from: 62, to: 70, photo: "middle")
        let newest = checkIn(daysAgo: 1, from: 70, to: 78, photo: "newest")

        let story = PlantChangeStory.make(observations: [newest, middle, oldest], care: [])

        XCTAssertEqual(story.comparison?.beforeURL.lastPathComponent, "grove-oldest.jpg")
        XCTAssertEqual(story.comparison?.nowURL.lastPathComponent, "grove-newest.jpg")
    }

    func testComparisonFallsBackToThePreviousPhotoWhenTheWindowHoldsOnlyOne() {
        // Care and photo-less check-ins fill the timeline, so the window starts
        // after the older photograph. The comparison must still find a pair
        // rather than silently disappearing.
        let older = checkIn(daysAgo: 40, from: 60, to: 62, photo: "older")
        let newest = checkIn(daysAgo: 0, from: 70, to: 78, photo: "newest")
        let bare = [checkIn(daysAgo: 2, from: 70, to: 70), checkIn(daysAgo: 4, from: 70, to: 70)]
        let filler = [care(.water, daysAgo: 1), care(.water, daysAgo: 3), care(.rotate, daysAgo: 5)]

        let story = PlantChangeStory.make(observations: [newest] + bare + [older], care: filler)

        XCTAssertFalse(
            story.moments.contains { $0.date == older.createdAt },
            "Precondition: the older photograph is off the end of the timeline."
        )

        XCTAssertEqual(story.comparison?.beforeURL.lastPathComponent, "grove-older.jpg")
        XCTAssertEqual(story.comparison?.nowURL.lastPathComponent, "grove-newest.jpg")
    }

    func testASingleCheckInIsNotAStoryAboutChange() {
        let story = PlantChangeStory.make(observations: [checkIn(daysAgo: 1, from: 70, to: 78, photo: "only")], care: [])

        XCTAssertNil(story.comparison)
        XCTAssertFalse(story.isWorthShowing)
    }

    // MARK: - What helped

    func testPatternNamesTheCareThatPrecededTheRise() {
        let story = PlantChangeStory.make(
            observations: [checkIn(daysAgo: 1, from: 70, to: 80)],
            care: [care(.water, daysAgo: 4), care(.rotate, daysAgo: 12)]
        )

        XCTAssertEqual(story.pattern?.careKind, .water, "The last action before the reading, not the oldest.")
        XCTAssertEqual(story.pattern?.delta, 10)
        XCTAssertEqual(story.pattern?.gapInDays, 3)
    }

    func testCareLoggedAfterTheReadingIsNotWhatHelped() {
        let story = PlantChangeStory.make(
            observations: [checkIn(daysAgo: 3, from: 70, to: 80)],
            care: [care(.water, daysAgo: 1)]
        )

        XCTAssertNil(story.pattern, "Watering after the check-in cannot be what the check-in measured.")
    }

    func testAnOfflineEstimateNeverCorroboratesAPattern() {
        var estimated = checkIn(daysAgo: 1, from: 70, to: 80)
        estimated.isEstimated = true

        let story = PlantChangeStory.make(observations: [estimated], care: [care(.water, daysAgo: 4)])

        XCTAssertNil(
            story.pattern,
            "The offline score is arithmetic on the owner's own answers. It cannot confirm their care worked."
        )
    }

    func testNoiseSizedMovementIsNotARise() {
        let story = PlantChangeStory.make(
            observations: [checkIn(daysAgo: 1, from: 70, to: 72)],
            care: [care(.water, daysAgo: 3)]
        )

        XCTAssertNil(story.pattern, "Two points is how much the same plant wanders between readings.")
    }

    func testPatternOnlyPointsAtCheckInsTheTimelineIsShowing() {
        // A recovery last season, then six recent events that push it out of
        // view. Claiming "what helped" about a reading the user cannot see is
        // how a card ends up celebrating while the visible history declines.
        let recovered = checkIn(daysAgo: 90, from: 60, to: 75)
        let recent = (1...6).map { checkIn(daysAgo: $0, from: 75, to: 75) }

        let story = PlantChangeStory.make(
            observations: recent + [recovered],
            care: [care(.treat, daysAgo: 95)]
        )

        XCTAssertNil(story.pattern)
    }

    func testPatternSentenceGapReadsAsASentence() {
        typealias Pattern = PlantChangeStory.Pattern
        XCTAssertEqual(Pattern.gapPhrase(days: 0), "the same day")
        XCTAssertEqual(Pattern.gapPhrase(days: 1), "the next day")
        XCTAssertEqual(Pattern.gapPhrase(days: 3), "three days later")
        XCTAssertEqual(Pattern.gapPhrase(days: 8), "a week later")
        XCTAssertEqual(Pattern.gapPhrase(days: 14), "a fortnight later")
        XCTAssertEqual(Pattern.gapPhrase(days: 28), "4 weeks later")
    }

    // MARK: - Finish screen trend

    func testAOnePointMoveOnTheFinishScreenIsSteady() {
        XCTAssertEqual(completion(from: 60, to: 61).trend, .stable)
    }

    func testAThreePointMoveOnTheFinishScreenImproves() {
        XCTAssertEqual(completion(from: 60, to: 63).trend, .improving)
    }

    func testAFallOnTheFinishScreenDeclines() {
        XCTAssertEqual(completion(from: 60, to: 57).trend, .declining)
    }

    func testAFirstReadingOnTheFinishScreenIsBaseline() {
        XCTAssertEqual(completion(from: 60, to: 60, isFirstReading: true).trend, .baseline)
    }

    // MARK: - Fixtures

    private func completion(
        from previous: Int,
        to score: Int,
        isFirstReading: Bool = false
    ) -> CheckInCompletion {
        CheckInCompletion(
            nickname: "Pesto",
            score: score,
            previousScore: previous,
            band: HealthBand(score: score),
            hasNewGrowth: false,
            streak: 0,
            isFirstReading: isFirstReading
        )
    }

    private func date(daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
    }

    private func checkIn(
        daysAgo: Int,
        from previous: Int,
        to score: Int,
        photo: String? = nil
    ) -> PlantObservation {
        PlantObservation(
            id: UUID(),
            plantID: plantID,
            createdAt: date(daysAgo: daysAgo),
            previousScore: previous,
            score: score,
            band: HealthBand(score: score),
            note: "",
            appearance: .same,
            soilMoisture: .comfortable,
            hasNewGrowth: false,
            photoURL: photo.map { URL(fileURLWithPath: "/tmp/grove-\($0).jpg") },
            actorName: "You"
        )
    }

    private func care(_ kind: CareKind, daysAgo: Int) -> CareTask {
        CareTask(
            id: UUID(),
            plantID: plantID,
            kind: kind,
            dueDate: date(daysAgo: daysAgo),
            detail: GroveStore.selfLoggedCareDetail,
            isCompleted: true,
            isSittingTask: false,
            ownerName: nil
        )
    }
}
