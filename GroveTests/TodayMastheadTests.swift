import XCTest
@testable import Grove

/// `TodayMasthead` is pure — state in, sentences out — so these tests pin
/// every branch of the greeting and the subtitle cascade without a store.
@MainActor
final class TodayMastheadTests: XCTestCase {

    /// A seeded plant to mutate, the same fixture BotanistAskTests uses.
    private func plant(
        named nickname: String,
        band: HealthBand,
        fixtureIndex: Int = 0
    ) throws -> Plant {
        let fixtures = GroveStore(persistenceEnabled: false).plants
        var plant = try XCTUnwrap(fixtures.indices.contains(fixtureIndex) ? fixtures[fixtureIndex] : nil)
        plant.nickname = nickname
        plant.healthBand = band
        return plant
    }

    // MARK: - Greeting

    func testFreshGroveIsWelcomedAtEveryHour() {
        for atmosphere in GroveAtmosphere.allCases {
            XCTAssertEqual(
                TodayMasthead.greeting(name: "Ari Waititi", hasPlants: false, atmosphere: atmosphere),
                "Welcome, Ari.",
                "A grove with nothing in it is a welcome, not a status report"
            )
        }
    }

    func testEstablishedGroveGreetsByTimeOfDay() {
        let expected: [GroveAtmosphere: String] = [
            .midnight: "Hey, Ari.",
            .preDawn: "Morning, Ari.",
            .dawn: "Morning, Ari.",
            .morning: "Morning, Ari.",
            .day: "Hey, Ari.",
            .afternoon: "Hey, Ari.",
            .goldenHour: "Evening, Ari.",
            .dusk: "Evening, Ari.",
            .night: "Hey, Ari."
        ]
        for (atmosphere, greeting) in expected {
            XCTAssertEqual(
                TodayMasthead.greeting(name: "Ari", hasPlants: true, atmosphere: atmosphere),
                greeting
            )
        }
    }

    func testAtmosphereMovesThroughTheFullLocalDay() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let expected: [Int: GroveAtmosphere] = [
            0: .midnight,
            4: .preDawn,
            6: .dawn,
            8: .morning,
            11: .day,
            15: .afternoon,
            17: .goldenHour,
            18: .dusk,
            20: .night
        ]

        for (hour, atmosphere) in expected {
            let date = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: hour))
            )
            XCTAssertEqual(GroveAtmosphere.at(date, timeZone: timeZone), atmosphere)
        }
    }

    func testAtmosphereUsesTheGrovesTimezone() throws {
        let moment = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-01T13:00:00Z")
        )
        let auckland = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))

        XCTAssertEqual(GroveAtmosphere.at(moment, timeZone: auckland), .midnight)
        XCTAssertEqual(GroveAtmosphere.at(moment, timeZone: losAngeles), .dawn)
    }

    func testMissingNameUsesNeutralGreeting() {
        XCTAssertEqual(
            TodayMasthead.greeting(name: "", hasPlants: true, atmosphere: .day),
            "Your grove today"
        )
        XCTAssertEqual(
            TodayMasthead.greeting(name: "", hasPlants: false, atmosphere: .dawn),
            "Welcome to your grove"
        )
    }

    // MARK: - Local date

    func testHeroDateUsesTheGrovesTimezoneAndTheReadersLocale() throws {
        let moment = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-01T13:00:00Z")
        )

        XCTAssertEqual(
            TodayMasthead.dateLine(
                for: moment,
                timeZone: try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland")),
                locale: Locale(identifier: "en_NZ")
            ),
            "Sunday, 2 August"
        )
        XCTAssertEqual(
            TodayMasthead.dateLine(
                for: moment,
                timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")),
                locale: Locale(identifier: "en_US")
            ),
            "Saturday, August 1"
        )
    }

    func testWeekStartsTodayAndRollsOverdueCheckInsIntoToday() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T13:00:00Z"))
        let overdue = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-31T23:00:00Z"))
        let dueToday = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T23:00:00Z"))
        let dueTomorrow = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-02T23:00:00Z"))
        let outsideTheStrip = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-08T13:00:00Z"))

        let week = TodayMasthead.week(
            checkInDates: [overdue, dueToday, dueTomorrow, outsideTheStrip],
            from: now,
            timeZone: timeZone
        )

        XCTAssertEqual(week.count, 7)
        XCTAssertTrue(week[0].isToday)
        XCTAssertEqual(week[0].checkInCount, 2)
        XCTAssertEqual(week[1].checkInCount, 1)
        XCTAssertEqual(week.dropFirst(2).map(\.checkInCount), [0, 0, 0, 0, 0])
    }

    // MARK: - Subtitle: the empty grove

    func testEmptyGroveWhosePlanClaimsPlantsPointsAtTheMissedOne() {
        for size in ["1-3", "4-10", "10+"] {
            XCTAssertEqual(
                TodayMasthead.subtitle(
                    heroPlant: nil, plantCount: 0, dueTaskCount: 0,
                    plan: GrovePlan(collectionSize: size), streak: 0
                ),
                "Your plants aren't in Grove yet. Start with the one you'd miss most."
            )
        }
    }

    func testEmptyGroveWithoutPlantsGetsTheGentleStart() {
        for plan in [nil, GrovePlan(collectionSize: "0"), GrovePlan()] {
            XCTAssertEqual(
                TodayMasthead.subtitle(
                    heroPlant: nil, plantCount: 0, dueTaskCount: 0,
                    plan: plan, streak: 0
                ),
                "Add your first plant. A scan takes about a minute."
            )
        }
    }

    // MARK: - Subtitle: plants in trouble win

    func testUrgentPlantBeatsTasksAndStreak() throws {
        let subtitle = TodayMasthead.subtitle(
            heroPlant: try plant(named: "Pesto", band: .urgent),
            plantCount: 4, dueTaskCount: 3,
            plan: nil, streak: 9
        )
        XCTAssertEqual(subtitle, "Pesto is in trouble. Check in on it today.")
    }

    func testAttentionPlantIsNamed() throws {
        let subtitle = TodayMasthead.subtitle(
            heroPlant: try plant(named: "Fig", band: .attention),
            plantCount: 2, dueTaskCount: 1,
            plan: nil, streak: 0
        )
        XCTAssertEqual(subtitle, "Fig isn't itself. Check in on it when you have a minute.")
    }

    // MARK: - Subtitle: the day's work

    func testDueTasksAreCounted() throws {
        let healthy = try plant(named: "Monty", band: .healthy)
        XCTAssertEqual(
            TodayMasthead.subtitle(heroPlant: healthy, plantCount: 3, dueTaskCount: 1, plan: nil, streak: 0),
            "One thing due today."
        )
        XCTAssertEqual(
            TodayMasthead.subtitle(heroPlant: healthy, plantCount: 3, dueTaskCount: 4, plan: nil, streak: 0),
            "4 things due today."
        )
    }

    // MARK: - Subtitle: all clear

    func testOnlyPlantSettledInIsNamed() throws {
        let subtitle = TodayMasthead.subtitle(
            heroPlant: try plant(named: "Pesto", band: .healthy),
            plantCount: 1, dueTaskCount: 0,
            plan: nil, streak: 5
        )
        XCTAssertEqual(subtitle, "Pesto is settled in. Nothing needs you today.")
    }

    func testStreakGetsTheCreditWhenAllIsClear() throws {
        let subtitle = TodayMasthead.subtitle(
            heroPlant: try plant(named: "Monty", band: .thriving),
            plantCount: 3, dueTaskCount: 0,
            plan: nil, streak: 6
        )
        XCTAssertEqual(subtitle, "All good today. Your streak is at 6 days.")
    }

    func testAllClearFallbackIsUnchanged() throws {
        for streak in [0, 1] {
            let subtitle = TodayMasthead.subtitle(
                heroPlant: try plant(named: "Monty", band: .healthy),
                plantCount: 3, dueTaskCount: 0,
                plan: nil, streak: streak
            )
            XCTAssertEqual(subtitle, "All good. Nothing due today.")
        }
    }

    // MARK: - Hero plant

    func testHeroShowsNewestPhotoInsteadOfRotatingOnACalmDay() throws {
        let older = try plant(named: "Older", band: .thriving)
        let recent = try plant(named: "Recent", band: .healthy, fixtureIndex: 1)
        let now = Date()

        let selected = TodayHeroPolicy.plant(
            from: [older, recent],
            latestPhotoDates: [
                older.id: now.addingTimeInterval(-86_400),
                recent.id: now
            ]
        )

        XCTAssertEqual(selected?.id, recent.id)
    }

    func testHeroConcernBeatsANewerHealthyPhoto() throws {
        let concern = try plant(named: "Concern", band: .attention)
        let recent = try plant(named: "Recent", band: .thriving, fixtureIndex: 1)
        let now = Date()

        let selected = TodayHeroPolicy.plant(
            from: [recent, concern],
            latestPhotoDates: [
                concern.id: now.addingTimeInterval(-86_400),
                recent.id: now
            ]
        )

        XCTAssertEqual(selected?.id, concern.id)
    }

    func testHeroUrgentPlantBeatsAttentionPlant() throws {
        var urgent = try plant(named: "Urgent", band: .urgent)
        var attention = try plant(named: "Attention", band: .attention, fixtureIndex: 1)
        urgent.healthScore = 55
        attention.healthScore = 40

        let selected = TodayHeroPolicy.plant(
            from: [attention, urgent],
            latestPhotoDates: [:]
        )

        XCTAssertEqual(selected?.id, urgent.id)
    }

    func testHeroUsesNewestAssessmentWhenNoPhotoExists() throws {
        var older = try plant(named: "Older", band: .healthy)
        var recent = try plant(named: "Recent", band: .thriving, fixtureIndex: 1)
        let now = Date()
        older.assessmentDate = now.addingTimeInterval(-86_400)
        recent.assessmentDate = now

        let selected = TodayHeroPolicy.plant(
            from: [older, recent],
            latestPhotoDates: [:]
        )

        XCTAssertEqual(selected?.id, recent.id)
    }

    // MARK: - First comparison

    func testDueOwnerCheckInWithoutAnObservationGetsFirstComparison() throws {
        let context = try firstComparisonContext()

        XCTAssertTrue(
            TodayTaskPresentation.isFirstComparison(
                task: context.task,
                hasPriorObservation: false,
                now: context.now,
                calendar: context.calendar
            )
        )
    }

    func testFirstComparisonWaitsUntilTheCheckInIsDue() throws {
        let context = try firstComparisonContext()
        var future = context.task
        future.dueDate = try XCTUnwrap(
            context.calendar.date(byAdding: .day, value: 1, to: context.now)
        )

        XCTAssertFalse(
            TodayTaskPresentation.isFirstComparison(
                task: future,
                hasPriorObservation: false,
                now: context.now,
                calendar: context.calendar
            )
        )
    }

    func testSavedObservationRetiresFirstComparison() throws {
        let context = try firstComparisonContext()

        XCTAssertFalse(
            TodayTaskPresentation.isFirstComparison(
                task: context.task,
                hasPriorObservation: true,
                now: context.now,
                calendar: context.calendar
            )
        )
    }

    func testSitterCompletedAndNonCheckInTasksStayGeneric() throws {
        let context = try firstComparisonContext()
        var sitter = context.task
        sitter.isSittingTask = true
        var completed = context.task
        completed.isCompleted = true
        var soilCheck = context.task
        soilCheck.kind = .inspectSoil

        for task in [sitter, completed, soilCheck] {
            XCTAssertFalse(
                TodayTaskPresentation.isFirstComparison(
                    task: task,
                    hasPriorObservation: false,
                    now: context.now,
                    calendar: context.calendar
                )
            )
        }
    }

    private func firstComparisonContext() throws -> (
        task: CareTask,
        now: Date,
        calendar: Calendar
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 10))
        )
        let task = CareTask(
            id: UUID(),
            plantID: UUID(),
            kind: .checkIn,
            dueDate: now,
            detail: "First check-in",
            isCompleted: false,
            isSittingTask: false,
            ownerName: nil
        )
        return (task, now, calendar)
    }

    // MARK: - Room map overflow title

    func testSevenRoomsWithoutUnplacedPlantsFoldIntoTwoMoreRooms() {
        XCTAssertEqual(
            TodayRoomMap.overflowTitle(foldedRooms: 2, hasUnplaced: false),
            "2 more rooms"
        )
    }

    func testOverflowTitleNamesUnplacedPlantsAndFoldedRooms() {
        XCTAssertEqual(
            TodayRoomMap.overflowTitle(foldedRooms: 0, hasUnplaced: true),
            "No room yet"
        )
        XCTAssertEqual(
            TodayRoomMap.overflowTitle(foldedRooms: 1, hasUnplaced: false),
            "1 more room"
        )
        XCTAssertEqual(
            TodayRoomMap.overflowTitle(foldedRooms: 2, hasUnplaced: true),
            "More rooms and unplaced"
        )
    }

    // MARK: - Spoken row

    func testTodayRowAnnouncesHealthWithItsBand() throws {
        var healthy = try plant(named: "Monty", band: .healthy)
        healthy.healthScore = 78
        healthy.assessmentSource = .baselinePhoto
        let entry = TodayBoardEntry(plant: healthy, nextTask: nil, tasks: [])

        let label = TodayBoardRow.accessibilityLabel(for: entry)

        XCTAssertTrue(label.hasSuffix("health 78 out of 100, Healthy"))
    }

    func testTodayRowWithoutAReadingNeverReadsThePlaceholder() throws {
        var unassessed = try plant(named: "Fig", band: .healthy)
        unassessed.healthScore = Plant.unassessedPlaceholderScore
        unassessed.assessmentSource = .offlineEstimate
        let entry = TodayBoardEntry(plant: unassessed, nextTask: nil, tasks: [])

        let label = TodayBoardRow.accessibilityLabel(for: entry)

        XCTAssertTrue(label.hasSuffix("no health reading yet"))
        XCTAssertFalse(label.contains("health \(Plant.unassessedPlaceholderScore)"))
    }
}
