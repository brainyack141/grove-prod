import XCTest
@testable import Grove

/// The rules that turn a forecast into something about someone's actual plants.
///
/// These are the load-bearing tests for the whole feature: the card, the
/// botanist's evidence pack and anything that later notifies all read the same
/// derivation, so a rule that fires wrongly here fires wrongly in three places.
@MainActor
final class SkyAdvisoryTests: XCTestCase {

    // MARK: - The metric itself

    /// The bug this feature was built on top of. Open-Meteo's
    /// `sunshine_duration` reported 6h 24m of sun on a day with 10.3mm of rain
    /// and 72% cloud, and sat within an hour of the day length in nearly all
    /// weather — so the chart could not tell a downpour from a clear sky. The
    /// radiation figure for those two real Drury days differs by a factor of
    /// five, which is what the whole card depends on.
    func testFullSunHoursSeparateAWetDayFromAClearOne() {
        // 2.6 MJ/m² on the wet day, 12.0 MJ/m² on the clear one.
        let wet = day(fullSunHours: 2.6 / GroveSunlightDay.peakSunMegajoules)
        let clear = day(fullSunHours: 12.0 / GroveSunlightDay.peakSunMegajoules)

        XCTAssertLessThan(wet.fullSunHours, 1, "A 10mm day cannot read as most of a day's sun")
        XCTAssertGreaterThan(clear.fullSunHours, 3)
        XCTAssertGreaterThan(clear.fullSunHours / wet.fullSunHours, 4, "The metric has to move with the sky")
    }

    /// The horticultural unit, derived from the same radiation. A clear winter
    /// day in Auckland is around 25 mol/m²/day outdoors.
    func testLightIntegralConvertsRadiationToMolesOfUsableLight() {
        let clear = day(fullSunHours: 12.0 / GroveSunlightDay.peakSunMegajoules)
        XCTAssertEqual(clear.lightIntegral, 24.7, accuracy: 0.5)
    }

    // MARK: - Cold

    /// The one way the strip's own temperatures reach a plant that never goes
    /// outside — and only for the plants actually touching the glass.
    func testColdNightWarnsOnlyAboutPlantsOnTheSill() throws {
        let sill = plant(nickname: "Monty", placement: .sill)
        let backOfRoom = plant(nickname: "Fern", placement: .shaded)
        let sky = forecast(nightLows: [9, 2, 6, 8])

        let named = GroveSky.advisories(forecast: sky, plants: [sill, backOfRoom], profile: profile())
        let cold = try XCTUnwrap(named.first { $0.kind == .coldGlass })
        XCTAssertEqual(cold.plantNames, ["Monty"], "Only the plant on the glass feels the glass")
        XCTAssertTrue(cold.headline.contains("Monty"))
        XCTAssertFalse(cold.headline.contains("Fern"))

        let unnamed = GroveSky.advisories(forecast: sky, plants: [backOfRoom], profile: profile())
        XCTAssertNil(unnamed.first { $0.kind == .coldGlass }, "Nothing is against the glass, so there is nothing to say")
    }

    /// A daily minimum lands at dawn, so the night about to happen is carried by
    /// *tomorrow's* figure. Reading today's would tell people to move a plant
    /// for a frost that happened while they were asleep.
    func testTonightMeansTomorrowsMinimumNotTodays() {
        // Today already had its cold dawn; the coming nights are mild.
        let sky = forecast(todayLow: -4, nightLows: [11, 12, 12, 11])
        let advisories = GroveSky.advisories(
            forecast: sky,
            plants: [plant(nickname: "Monty", placement: .sill)],
            profile: profile()
        )
        XCTAssertNil(advisories.first { $0.kind == .coldGlass }, "This morning's frost is not tonight's")
        XCTAssertNil(advisories.first { $0.kind == .frost })
    }

    /// A partial provider response can omit today's row. "Tonight" still means
    /// the next local calendar day's dawn, not whichever element happened to be
    /// second in an array.
    func testTonightSurvivesAForecastWithNoTodayRow() throws {
        var sky = forecast(nightLows: [0, 5, 6, 7])
        sky.days.removeFirst()

        let frost = try XCTUnwrap(
            GroveSky.advisories(
                forecast: sky,
                plants: [plant(nickname: "Rosemary", placement: .outdoors)],
                profile: profile(environment: "outdoor")
            ).first { $0.kind == .frost }
        )
        XCTAssertTrue(frost.headline.contains("tonight"))
    }

    func testFrostOnlyReachesGrovesThatGrowOutside() {
        let sky = forecast(nightLows: [0, 2, 3, 4])

        let outdoor = GroveSky.advisories(
            forecast: sky,
            plants: [plant(nickname: "Rosemary", placement: .outdoors)],
            profile: profile(environment: "outdoor")
        )
        let frost = outdoor.first { $0.kind == .frost }
        XCTAssertNotNil(frost)
        XCTAssertEqual(frost?.tone, .caution)
        XCTAssertTrue(frost?.headline.contains("Rosemary") ?? false)

        let indoorOnly = GroveSky.advisories(
            forecast: sky,
            plants: [plant(nickname: "Monty", placement: .bright)],
            profile: profile(environment: "indoor")
        )
        XCTAssertNil(indoorOnly.first { $0.kind == .frost }, "A frost is not news to a plant in a heated flat")
    }

    /// The seasonal banner has no separate unit header, so every measurement it
    /// carries must follow the profile and name its unit explicitly.
    func testSeasonalAdviceUsesTheProfilesTemperatureUnits() throws {
        let sky = forecast(nightLows: [0, 2, 3, 4])
        let advisory = try XCTUnwrap(
            GroveSky.advisories(
                forecast: sky,
                plants: [],
                profile: profile(environment: "outdoor", usesMetric: false)
            ).first { $0.kind == .frost }
        )
        XCTAssertTrue(advisory.headline.contains("32°F"))
    }

    // MARK: - Indoor air

    /// Once a home is heated, indoor humidity is very nearly a function of the
    /// outdoor dew point. A 2° dew point outside is around 30% inside — the
    /// winter tip-browning everyone blames on underwatering.
    func testHeatedRoomsAreDrierThanTheAirOutside() throws {
        let winter = GroveWeatherDay(
            date: .now,
            symbol: "cloud.fill",
            highCelsius: 6,
            lowCelsius: 1,
            dewPointCelsius: 2,
            outdoorHumidity: 88,
            precipitationMillimetres: 0
        )
        let indoor = try XCTUnwrap(GroveSky.indoorHumidity(for: winter))
        XCTAssertEqual(indoor, 30, accuracy: 4, "Warming saturated 2° air to 20° drops it to about a third")
        XCTAssertLessThan(indoor, winter.outdoorHumidity ?? 100)
    }

    /// When it is warmer outside than in, the heating is off and the model has
    /// nothing to add — the outdoor reading stands rather than inventing a
    /// number.
    func testSummerAirIsNotRunThroughTheHeatingModel() throws {
        let summer = GroveWeatherDay(
            date: .now,
            symbol: "sun.max.fill",
            highCelsius: 28,
            lowCelsius: 19,
            dewPointCelsius: 16,
            outdoorHumidity: 64,
            precipitationMillimetres: 0
        )
        XCTAssertEqual(GroveSky.indoorHumidity(for: summer), 64)
    }

    func testDryAirAdvisoryFiresForAHeatedWinterWeek() {
        let sky = forecast(highs: 6, nightLows: [1, 1, 2, 1, 0, 1, 2], dewPoint: 0)
        let advisories = GroveSky.advisories(
            forecast: sky,
            plants: [plant(nickname: "Calathea", placement: .bright)],
            profile: profile(environment: "indoor")
        )
        let dry = advisories.first { $0.kind == .dryAir }
        XCTAssertNotNil(dry, "A dew point at freezing is a dry house, and that is the whole finding")
        XCTAssertTrue(dry?.detail?.contains("away from heaters") ?? false, "The advisory has to say what to do about it")
    }

    // MARK: - Rain

    /// Forecast rain is not proof that water reached a pot under an eave. The
    /// seasonal card must prompt a soil check rather than cancel watering for
    /// every outdoor plant wholesale.
    func testWetWeekChecksOutdoorPotsWithoutAssumingRainReachedThem() throws {
        let rainyDays = mildWeek().map { day in
            GroveWeatherDay(
                date: day.date,
                symbol: "cloud.rain.fill",
                highCelsius: day.highCelsius,
                lowCelsius: day.lowCelsius,
                dewPointCelsius: day.dewPointCelsius,
                outdoorHumidity: day.outdoorHumidity,
                precipitationMillimetres: 5,
                timeZone: day.timeZone
            )
        }
        let sky = GroveForecast(days: rainyDays, sunlight: sunlight(hours: 2, count: 14))

        let outdoor = GroveSky.advisories(
            forecast: sky,
            plants: [plant(nickname: "Rosemary", placement: .outdoors)],
            profile: profile(environment: "outdoor")
        )
        let wet = try XCTUnwrap(outdoor.first { $0.kind == .wetSpell })
        XCTAssertTrue(wet.headline.contains("Check outdoor pots before watering"))
        XCTAssertTrue(wet.detail?.contains("under eaves") ?? false)
        XCTAssertEqual(wet.plantNames, ["Rosemary"])

        let indoor = GroveSky.advisories(
            forecast: sky,
            plants: [plant(nickname: "Monty", placement: .bright)],
            profile: profile(environment: "indoor")
        )
        XCTAssertNil(indoor.first { $0.kind == .wetSpell }, "Rain is not a watering event for an indoor pot")
    }

    // MARK: - Light

    /// The finding a person cannot make for themselves: each morning just looks
    /// like weather, and the run only exists in aggregate.
    func testAGreyRunIsReportedAndSaysWhyItMatters() throws {
        let sky = GroveForecast(
            days: mildWeek(),
            sunlight: sunlight(hours: 6, count: 7, endingDaysAgo: 7) + sunlight(hours: 2, count: 7)
        )
        let advisories = GroveSky.advisories(forecast: sky, plants: [], profile: profile())
        let grey = try XCTUnwrap(advisories.first { $0.kind == .greyRun })
        XCTAssertTrue(grey.headline.contains("darker"))
        XCTAssertTrue(grey.detail?.contains("root rot") ?? false, "Overwatering in a grey run is the point of the rule")
    }

    /// Weather is noisy. A card that narrates noise as a trend teaches people
    /// to ignore all of it.
    func testASteadyFortnightIsNotNarratedAsAShift() {
        let sky = GroveForecast(days: mildWeek(), sunlight: sunlight(hours: 5, count: 14))
        let advisories = GroveSky.advisories(forecast: sky, plants: [], profile: profile())
        XCTAssertNil(advisories.first { $0.kind == .greyRun })
        XCTAssertNil(advisories.first { $0.kind == .brightRun })
    }

    /// There is always something honest to say about the light, so the card
    /// never falls back to being a weather widget.
    func testThereIsAlwaysALightBudgetToFallBackOn() throws {
        let sky = GroveForecast(days: mildWeek(), sunlight: sunlight(hours: 5, count: 14))
        let advisories = GroveSky.advisories(forecast: sky, plants: [], profile: profile())
        let budget = try XCTUnwrap(advisories.first { $0.kind == .lightBudget })
        XCTAssertTrue(budget.headline.contains("windowsill"), "The indoor fraction is the reason this line exists")
    }

    /// Two and a half hours of full sun outside is a starvation diet on a sill,
    /// and the advice for that is the opposite of the advice for a bright week.
    func testAThinWinterBudgetTellsPeopleToWaterLessNotMore() throws {
        let sky = GroveForecast(days: mildWeek(), sunlight: sunlight(hours: 2, count: 14))
        let advisories = GroveSky.advisories(forecast: sky, plants: [], profile: profile())
        let budget = try XCTUnwrap(advisories.first { $0.kind == .lightBudget })
        XCTAssertTrue(budget.detail?.contains("Water less") ?? false)
    }

    // MARK: - Ordering

    /// The card shows one line. A frost has to beat a remark about day length.
    func testHazardsOutrankTheSeasonalCommentary() throws {
        let sky = forecast(nightLows: [-1, 2, 3, 4])
        let headline = try XCTUnwrap(
            GroveSky.headlineAdvisory(
                forecast: sky,
                plants: [plant(nickname: "Rosemary", placement: .outdoors)],
                profile: profile(environment: "both")
            )
        )
        XCTAssertEqual(headline.kind, .frost)
    }

    /// Ranking chooses the collapsed headline; it must not discard another
    /// simultaneous case that the expanded Today card needs to show.
    func testAllSimultaneousHazardsRemainAvailableInPriorityOrder() {
        let sky = forecast(nightLows: [-1, 2, 3, 4])
        let advisories = GroveSky.advisories(
            forecast: sky,
            plants: [
                plant(nickname: "Rosemary", placement: .outdoors),
                plant(nickname: "Monty", placement: .sill)
            ],
            profile: profile(environment: "both")
        )

        XCTAssertEqual(Array(advisories.map(\.kind).prefix(2)), [.frost, .coldGlass])
    }

    // MARK: - Naming

    func testPlantNamesReadAsASentence() {
        XCTAssertEqual(GroveSky.list(["Monty"]), "Monty")
        XCTAssertEqual(GroveSky.list(["Monty", "Fern"]), "Monty and Fern")
        XCTAssertEqual(GroveSky.list(["Monty", "Fern", "Basil"]), "Monty, Fern and one other")
        XCTAssertEqual(GroveSky.list(["Monty", "Fern", "Basil", "Sage"]), "Monty, Fern and two others")
    }

    /// A room name is not a light position, but "Balcony" is not ambiguous.
    func testOutdoorRoomNamesAreInferredWithoutAsking() {
        XCTAssertEqual(PlantLightPlacement.inferred(fromLocation: "Balcony"), .outdoors)
        XCTAssertEqual(PlantLightPlacement.inferred(fromLocation: "Back garden"), .outdoors)
        XCTAssertNil(PlantLightPlacement.inferred(fromLocation: "Bedroom"), "A bedroom could be a sill or a dark corner")
    }

    /// An outdoor gardener names the ground, not the house.
    func testOutdoorInferenceRecognisesAllotmentWords() {
        XCTAssertEqual(PlantLightPlacement.inferred(fromLocation: "Allotment"), .outdoors)
        XCTAssertEqual(PlantLightPlacement.inferred(fromLocation: "Plot 12"), .outdoors)
        XCTAssertEqual(PlantLightPlacement.inferred(fromLocation: "Bed 3"), .outdoors)
        XCTAssertEqual(PlantLightPlacement.inferred(fromLocation: "Raised bed"), .outdoors)
        XCTAssertEqual(PlantLightPlacement.inferred(fromLocation: "Veg patch"), .outdoors)
        XCTAssertEqual(PlantLightPlacement.inferred(fromLocation: "Window box"), .outdoors)
        XCTAssertNil(PlantLightPlacement.inferred(fromLocation: "Bedroom"))
        XCTAssertNil(PlantLightPlacement.inferred(fromLocation: "Bedside table"))
        XCTAssertNil(PlantLightPlacement.inferred(fromLocation: "Living room"))
    }

    // MARK: - Fixtures

    private func profile(environment: String? = nil, usesMetric: Bool? = nil) -> UserProfile {
        var profile = GroveStore(plants: [], persistenceEnabled: false).profile
        if let environment {
            profile.plan = GrovePlan(environment: environment)
        }
        profile.usesMetricSystem = usesMetric
        return profile
    }

    private func plant(nickname: String, placement: PlantLightPlacement) -> Plant {
        var plant = GroveStore(persistenceEnabled: false).plants[0]
        plant.nickname = nickname
        plant.lightPlacement = placement
        return plant
    }

    private func day(fullSunHours: Double) -> GroveSunlightDay {
        GroveSunlightDay(date: .now, fullSunHours: fullSunHours, daylightHours: 10, cloudCover: 50)
    }

    private func sunlight(hours: Double, count: Int, endingDaysAgo: Int = 0) -> [GroveSunlightDay] {
        (0..<count).reversed().map { offset in
            GroveSunlightDay(
                date: Calendar.current.date(byAdding: .day, value: -(offset + endingDaysAgo), to: .now) ?? .now,
                fullSunHours: hours,
                daylightHours: 12,
                cloudCover: 40
            )
        }
    }

    /// A week ahead with nothing in it: mild, dry, partly cloudy. Any hazard a
    /// test sees came from that test.
    private func mildWeek() -> [GroveWeatherDay] {
        (0..<7).map { offset in
            GroveWeatherDay(
                date: Calendar.current.date(byAdding: .day, value: offset, to: .now) ?? .now,
                symbol: "cloud.sun.fill",
                highCelsius: 21,
                lowCelsius: 13,
                dewPointCelsius: 11,
                outdoorHumidity: 60,
                precipitationMillimetres: 0
            )
        }
    }

    /// `nightLows[0]` is tomorrow's minimum — the night about to happen.
    private func forecast(
        todayLow: Double = 12,
        highs: Double = 20,
        nightLows: [Double],
        dewPoint: Double = 10
    ) -> GroveForecast {
        var days: [GroveWeatherDay] = [
            GroveWeatherDay(
                date: Calendar.current.startOfDay(for: .now),
                symbol: "cloud.sun.fill",
                highCelsius: highs,
                lowCelsius: todayLow,
                dewPointCelsius: dewPoint,
                outdoorHumidity: 70,
                precipitationMillimetres: 0
            )
        ]
        for (offset, low) in nightLows.enumerated() {
            days.append(
                GroveWeatherDay(
                    date: Calendar.current.date(byAdding: .day, value: offset + 1, to: Calendar.current.startOfDay(for: .now)) ?? .now,
                    symbol: "cloud.sun.fill",
                    highCelsius: highs,
                    lowCelsius: low,
                    dewPointCelsius: dewPoint,
                    outdoorHumidity: 70,
                    precipitationMillimetres: 0
                )
            )
        }
        return GroveForecast(days: days, sunlight: sunlight(hours: 4, count: 14))
    }
}
