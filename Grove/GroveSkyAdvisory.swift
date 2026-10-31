import Foundation

/// One thing the sky is about to do to this person's plants.
///
/// The weather strip on Today used to be the only weather in Grove, and it was
/// the least Grove-like surface in the app: seven temperatures nobody's pothos
/// has an opinion about, sitting above the fold in a product whose whole promise
/// is that every recommendation explains why. Outdoor weather matters enormously
/// to indoor plants — but through light, drying rate, indoor humidity and cold
/// glass, none of which is the daily high.
///
/// An advisory is the consequence. The strip stays as the evidence.
struct GroveSkyAdvisory: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case frost
        case coldGlass
        case scorch
        case dryAir
        case wetSpell
        case greyRun
        case brightRun
        case seasonTurn
        case lightBudget

        /// A deliberate, exhaustive display order. Adding a new rule cannot
        /// silently put a pleasant seasonal note ahead of a plant-damaging
        /// hazard just because it was appended in the wrong place below.
        var displayPriority: Int {
            switch self {
            case .frost: 900
            case .coldGlass: 850
            case .scorch: 800
            case .dryAir: 700
            case .wetSpell: 650
            case .greyRun: 550
            case .brightRun: 500
            case .seasonTurn: 400
            case .lightBudget: 100
            }
        }
    }

    /// How loudly the card should carry it. Not a severity score — a plant
    /// dying of cold and a plant merely growing slowly are both worth saying,
    /// and only one of them should look alarming.
    enum Tone: Hashable {
        /// Nothing to do; this is the season, described.
        case calm
        /// Worth changing a habit this week.
        case notable
        /// Something will be damaged if nobody moves.
        case caution
    }

    /// The number behind the sentence, carried structurally so the Today card
    /// can lead with it instead of asking someone to read it out of prose.
    /// The headline stays whole regardless: it is what VoiceOver announces
    /// and what the botanist receives.
    enum Figure: Hashable {
        /// One dominant reading: "37%" over "indoor humidity".
        case reading(value: String, unit: String)
        /// A reading that moved: the value now, its unit, and the signed
        /// change ("+54m").
        case shift(value: String, unit: String, delta: String, rising: Bool)
        /// The light budget: outdoor full-sun hours, thinned by each standing
        /// spot's share on the way into the room.
        case lightLadder(outdoorHours: Double)
    }

    let kind: Kind
    let tone: Tone
    let symbol: String
    /// The consequence, in one sentence. Never a weather report.
    let headline: String
    /// What to do about it, or why it happens. Nil when the headline is whole.
    let detail: String?
    /// Nicknames of the plants this actually touches. Empty when it is about
    /// the grove as a whole rather than particular pots.
    let plantNames: [String]
    /// A few words naming the situation ("Dry air this week"). Rides beside
    /// the figure; nil when the headline carries the row alone.
    let brief: String?
    /// The one thing to do about it, stated short enough to sit under a
    /// number.
    let cue: String?
    let figure: Figure?

    init(
        kind: Kind,
        tone: Tone,
        symbol: String,
        headline: String,
        detail: String?,
        plantNames: [String],
        brief: String? = nil,
        cue: String? = nil,
        figure: Figure? = nil
    ) {
        self.kind = kind
        self.tone = tone
        self.symbol = symbol
        self.headline = headline
        self.detail = detail
        self.plantNames = plantNames
        self.brief = brief
        self.cue = cue
        self.figure = figure
    }

    var id: String { kind.rawValue }
}

/// Turns a forecast into things worth saying about someone's actual plants.
///
/// Every rule here is a pure function of the forecast, the grove and the clock,
/// with no view and no store, so the same derivation can drive the Today card,
/// the botanist's evidence pack and — when it earns its place — a notification,
/// without three of them drifting apart.
enum GroveSky {

    // MARK: - Entry point

    /// Everything worth saying today, most urgent first. The Sky card shows the
    /// first; the botanist gets all of them.
    static func advisories(
        forecast: GroveForecast,
        plants: [Plant],
        profile: UserProfile,
        now: Date = .now
    ) -> [GroveSkyAdvisory] {
        let grove = Grove(plants: plants, profile: profile)
        var found: [GroveSkyAdvisory] = []

        if let advisory = frost(forecast, grove, now: now) { found.append(advisory) }
        if let advisory = coldGlass(forecast, grove, now: now) { found.append(advisory) }
        if let advisory = scorch(forecast, grove, now: now) { found.append(advisory) }
        if let advisory = dryAir(forecast, grove, now: now) { found.append(advisory) }
        if let advisory = wetSpell(forecast, grove, now: now) { found.append(advisory) }
        if let advisory = lightShift(forecast, grove) { found.append(advisory) }
        if let advisory = seasonTurn(forecast) { found.append(advisory) }
        if let advisory = lightBudget(forecast, grove) { found.append(advisory) }

        return found.sorted { lhs, rhs in
            lhs.kind.displayPriority > rhs.kind.displayPriority
        }
    }

    /// The one line the Sky card carries.
    static func headlineAdvisory(
        forecast: GroveForecast,
        plants: [Plant],
        profile: UserProfile,
        now: Date = .now
    ) -> GroveSkyAdvisory? {
        advisories(forecast: forecast, plants: plants, profile: profile, now: now).first
    }

    // MARK: - The grove, as the rules need it

    /// The plants each rule is allowed to name, grouped by the only thing that
    /// decides whether a given piece of weather reaches them.
    struct Grove {
        let plants: [Plant]
        /// What the user told the quiz: "indoor", "outdoor", "both", or nil.
        let environment: String?
        /// Advice carries its own unit label because it is also reused outside
        /// the forecast strip, where no °C/°F header is visible.
        let usesMetric: Bool

        init(plants: [Plant], profile: UserProfile) {
            // Only plants in active care get weather advice. "Move Fern clear
            // of the glass" about an archived or remembered plant is advice
            // for a pot that is not there.
            self.plants = plants.filter { $0.effectiveLifecycleState == .active }
            self.environment = profile.plan?.environment
            self.usesMetric = profile.usesMetricSystem ?? (Locale.current.measurementSystem == .metric)
        }

        /// Spelled out rather than `.map(placements.contains)`.
        ///
        /// That shorthand partially applies `Set.contains` inside a nested
        /// closure, and in optimised builds the captured set arrived with a null
        /// storage pointer — `EXC_BAD_ACCESS` at `0x10`, which is the offset
        /// `contains` reads first. It crashed Today outright as soon as a
        /// forecast existed to run the advisories against, so it never reached
        /// anyone in Debug. An explicit closure captures the set the ordinary
        /// way and reads more plainly besides.
        func named(_ placements: Set<PlantLightPlacement>) -> [String] {
            plants
                .filter { plant in
                    guard let placement = plant.effectiveLightPlacement else { return false }
                    return placements.contains(placement)
                }
                .map(\.nickname)
        }

        var outdoorNames: [String] { named([.outdoors]) }
        var sillNames: [String] { named([.sill]) }
        var indoorNames: [String] { named([.sill, .bright, .shaded]) }

        /// Whether outdoor advice can apply at all. A grove with no plants
        /// tagged outdoors still counts if the user said that is where they
        /// grow — the alternative is silence for everyone who added their
        /// plants before Grove asked where they stand.
        var growsOutdoors: Bool {
            !outdoorNames.isEmpty || environment == "outdoor" || environment == "both"
        }

        var growsIndoors: Bool {
            !indoorNames.isEmpty || environment == "indoor" || environment == "both" || environment == nil
        }

        func temperature(_ celsius: Double) -> String {
            let value = GroveWeatherDay.temperature(celsius, metric: usesMetric)
            return "\(value)°\(usesMetric ? "C" : "F")"
        }

        func precipitation(_ millimetres: Double) -> String {
            if usesMetric {
                return "\(Int(millimetres.rounded())) mm"
            }
            return String(format: "%.1f in", millimetres / 25.4)
        }
    }

    // MARK: - Cold

    /// Frost, for anything living outside.
    ///
    /// Pots are the reason this is worth a notification and a garden bed is not:
    /// a container freezes through from every side, and roots have nowhere to
    /// retreat to.
    static func frost(_ forecast: GroveForecast, _ grove: Grove, now: Date) -> GroveSkyAdvisory? {
        guard grove.growsOutdoors else { return nil }
        guard let night = coldestNight(forecast, within: 4, now: now), night.day.lowCelsius <= 1 else { return nil }

        let names = grove.outdoorNames
        let temperature = grove.temperature(night.day.lowCelsius)
        return GroveSkyAdvisory(
            kind: .frost,
            tone: .caution,
            symbol: "snowflake",
            headline: names.isEmpty
                ? "Frost \(night.phrase), \(temperature). Check tender outdoor pots before dusk."
                : "Frost \(night.phrase). Check \(list(names)) before dusk.",
            detail: "Check tender outdoor pots first. Bring them under cover, or insulate the container and protect the foliage with frost cloth. Established hardy plants can stay where they are.",
            plantNames: names
        )
    }

    /// A cold pane, for the plants leaning on it.
    ///
    /// This is the one place the temperature on the strip genuinely reaches an
    /// indoor plant, and it is the low rather than the high that does it. A
    /// single-glazed window on a 3° night sits far below room temperature, and
    /// only the leaves touching it find that out.
    static func coldGlass(_ forecast: GroveForecast, _ grove: Grove, now: Date) -> GroveSkyAdvisory? {
        let names = grove.sillNames
        guard !names.isEmpty else { return nil }
        guard let night = coldestNight(forecast, within: 3, now: now), night.day.lowCelsius <= 8 else { return nil }

        let temperature = grove.temperature(night.day.lowCelsius)
        return GroveSkyAdvisory(
            kind: .coldGlass,
            tone: night.day.lowCelsius <= 4 ? .caution : .notable,
            symbol: "thermometer.snowflake",
            headline: "\(temperature) outside \(night.phrase). Move \(list(names)) clear of the glass overnight.",
            detail: "The inside of a cold pane can sit far below room temperature. Move the pot a hand's width back overnight so no leaf touches it.",
            plantNames: names
        )
    }

    // MARK: - Heat

    /// A sun-facing sill on a hot clear day is an oven, and a plant that is
    /// perfectly happy there in May is not in January's other hemisphere.
    /// Stated as "sun-facing" rather than south-facing on purpose: half of
    /// Grove's users are on the other side of the equator.
    static func scorch(_ forecast: GroveForecast, _ grove: Grove, now: Date) -> GroveSkyAdvisory? {
        let names = grove.sillNames
        guard !names.isEmpty || grove.growsOutdoors else { return nil }
        let clearAndHot = upcomingDays(forecast, includingToday: true, limit: 5, now: now)
            .filter { $0.highCelsius >= 30 && Self.isClear($0.symbol) }
        guard let day = clearAndHot.max(by: { $0.highCelsius < $1.highCelsius }) else { return nil }

        let temperature = grove.temperature(day.highCelsius)
        let when = dayPhrase(day, in: forecast, now: now)
        return GroveSkyAdvisory(
            kind: .scorch,
            tone: .caution,
            symbol: "sun.max.trianglebadge.exclamationmark.fill",
            headline: names.isEmpty
                ? "\(temperature) and clear \(when). Check outdoor pots and sunny sills by afternoon."
                : "\(temperature) and clear \(when). Check \(list(names)) if direct afternoon sun reaches the sill.",
            detail: "Glass and still air can make a sunny sill much hotter than the room. Pull exposed plants back for the afternoon or draw a sheer curtain; leave shade-grown and acclimatised plants where they are.",
            plantNames: names
        )
    }

    // MARK: - Indoor air

    /// The winter tip-browning that everybody blames on underwatering.
    ///
    /// Once a home is heated, indoor humidity is very nearly a function of the
    /// outdoor dew point alone: the air coming in carries whatever moisture it
    /// had outside, and warming it to room temperature drops its relative
    /// humidity through the floor. This is invisible, it is seasonal, and it is
    /// the single most useful thing outdoor weather has to say about an indoor
    /// plant after light.
    static func dryAir(_ forecast: GroveForecast, _ grove: Grove, now: Date) -> GroveSkyAdvisory? {
        guard grove.growsIndoors else { return nil }
        let week = upcomingDays(forecast, includingToday: true, limit: 5, now: now)
        let estimates = week.compactMap { indoorHumidity(for: $0) }
        guard estimates.count >= 3 else { return nil }

        let mean = estimates.reduce(0, +) / Double(estimates.count)
        guard mean < 38 else { return nil }

        return GroveSkyAdvisory(
            kind: .dryAir,
            tone: mean < 30 ? .notable : .calm,
            symbol: "humidity.fill",
            headline: "Heated rooms may fall near \(Int(mean.rounded()))% humidity this week. Keep sensitive plants away from heaters.",
            detail: "Thin-leaved tropicals can crisp at the edge before they wilt, which is easy to mistake for thirst. Keep sensitive plants away from heaters and group them together. Misting changes the air for only a few minutes.",
            plantNames: [],
            brief: "Dry air this week",
            cue: "Keep sensitive plants away from heaters",
            figure: .reading(value: "\(Int(mean.rounded()))%", unit: "indoor humidity")
        )
    }

    // MARK: - Rain

    /// Outdoor pots only. Rain does not water an indoor plant, and a card that
    /// implies it does teaches people to distrust the rest.
    static func wetSpell(_ forecast: GroveForecast, _ grove: Grove, now: Date) -> GroveSkyAdvisory? {
        guard grove.growsOutdoors else { return nil }
        let total = upcomingDays(forecast, includingToday: true, limit: 7, now: now)
            .compactMap(\.precipitationMillimetres)
            .reduce(0, +)
        guard total >= 20 else { return nil }

        let names = grove.outdoorNames
        let precipitation = grove.precipitation(total)
        return GroveSkyAdvisory(
            kind: .wetSpell,
            tone: .calm,
            symbol: "cloud.rain.fill",
            headline: "Wet week ahead: \(precipitation) forecast. Check outdoor pots before watering.",
            detail: "Rain only counts if it reaches the compost. Check pots under eaves or dense foliage, and empty saucers that stay full; exposed pots with damp soil can wait.",
            plantNames: names,
            brief: "Wet week ahead",
            cue: "Check outdoor pots before watering",
            figure: .reading(value: precipitation, unit: "rain this week")
        )
    }

    // MARK: - Light

    /// The fortnight against the fortnight before it.
    ///
    /// This is the finding a person cannot make themselves: each morning just
    /// looks like weather, and the run only exists in aggregate. It is also the
    /// commonest true answer to "why has it stopped growing" and to "why is the
    /// soil still wet four days later".
    static func lightShift(_ forecast: GroveForecast, _ grove: Grove) -> GroveSkyAdvisory? {
        let days = forecast.sunlight
        guard days.count >= 8 else { return nil }
        let midpoint = days.count / 2
        let earlier = Array(days.prefix(midpoint))
        let recent = Array(days.suffix(days.count - midpoint))
        let earlierMean = mean(earlier.map(\.fullSunHours))
        let recentMean = mean(recent.map(\.fullSunHours))
        guard earlierMean > 0.15 else { return nil }

        let change = (recentMean - earlierMean) / earlierMean
        // A quarter either way. Below that it is weather noise, and advice that
        // narrates noise as a trend teaches people to ignore all of it.
        guard abs(change) >= 0.25 else { return nil }

        if change < 0 {
            return GroveSkyAdvisory(
                kind: .greyRun,
                tone: .notable,
                symbol: "cloud.fill",
                headline: "The last \(recent.count) days ran \(Int((abs(change) * 100).rounded()))% darker than the \(earlier.count) before them. Check soil before watering.",
                detail: "Plants drink in proportion to the light they get, so pots are still wet on the day you would normally water. Feel the soil two knuckles down first. This is the fortnight root rot starts in.",
                plantNames: [],
                brief: "Darker fortnight",
                cue: "Check soil before watering",
                figure: .shift(
                    value: duration(recentMean),
                    unit: "sun a day",
                    delta: "−\(duration(earlierMean - recentMean))",
                    rising: false
                )
            )
        }

        return GroveSkyAdvisory(
            kind: .brightRun,
            tone: .calm,
            symbol: "sun.max.fill",
            headline: "Brighter fortnight: \(duration(recentMean)) of full sun a day, up from \(duration(earlierMean)). Check sill pots earlier.",
            detail: "Pots dry noticeably faster in this. Anything on a sill will want water a day or two before your usual round.",
            plantNames: grove.sillNames,
            brief: "Brighter fortnight",
            cue: "Check sill pots a day or two early",
            figure: .shift(
                value: duration(recentMean),
                unit: "sun a day",
                delta: "+\(duration(recentMean - earlierMean))",
                rising: true
            )
        )
    }

    /// The turn of the year, which arrives as a change in day length weeks
    /// before it arrives as a change in weather — and which is the honest
    /// answer to both "should I feed this" and "why has it stopped".
    static func seasonTurn(_ forecast: GroveForecast) -> GroveSkyAdvisory? {
        let days = forecast.sunlight
        guard let first = days.first, let last = days.last, days.count >= 10 else { return nil }
        guard first.daylightHours > 0, last.daylightHours > 0 else { return nil }

        let change = last.daylightHours - first.daylightHours
        guard abs(change) >= 0.4 else { return nil }
        let minutes = Int((abs(change) * 60).rounded())

        if change > 0 {
            return GroveSkyAdvisory(
                kind: .seasonTurn,
                tone: .calm,
                symbol: "sunrise.fill",
                headline: "Days are \(minutes) minutes longer than a fortnight ago.",
                detail: "Growth follows the light by a few weeks. From here, feeding starts paying for itself and a plant that has sat still all winter is about to want more water.",
                plantNames: [],
                brief: "Days drawing out",
                cue: "Feeding starts paying for itself",
                figure: .shift(
                    value: duration(last.daylightHours),
                    unit: "daylight",
                    delta: "+\(minutes)m",
                    rising: true
                )
            )
        }

        return GroveSkyAdvisory(
            kind: .seasonTurn,
            tone: .calm,
            symbol: "sunset.fill",
            headline: "Days are drawing in: \(minutes) minutes shorter than a fortnight ago.",
            detail: "Most houseplants are heading for a rest, not a decline. Stretch the gaps between waterings and stop feeding until the days turn.",
            plantNames: [],
            brief: "Days drawing in",
            cue: "Stretch waterings and stop feeding",
            figure: .shift(
                value: duration(last.daylightHours),
                unit: "daylight",
                delta: "−\(minutes)m",
                rising: false
            )
        )
    }

    /// The fallback, and the line the card wears most of the year: what the
    /// light out there actually amounts to once it has been through a window.
    ///
    /// The indoor figure is the point. Outdoor light is abundant almost
    /// everywhere; a bright sill delivers roughly half of it and the far side of
    /// the room a twentieth, which is how a room that looks perfectly bright to
    /// a person can be a starvation diet for a plant.
    static func lightBudget(_ forecast: GroveForecast, _ grove: Grove) -> GroveSkyAdvisory? {
        let days = forecast.sunlight
        guard days.count >= 3 else { return nil }
        let outdoor = mean(days.map(\.fullSunHours))
        guard outdoor > 0 else { return nil }

        // What a plant on the sill is actually living on. The sill is the
        // reference because it is the best spot an indoor plant can have — if
        // the sill is thin, everything further in is thinner.
        let sill = outdoor * PlantLightPlacement.sill.outdoorLightShare
        let names = grove.sillNames

        let detail: String
        let cue: String
        if sill < 1.2 {
            detail = "That is under what most foliage needs to put out a new leaf, so nothing much will grow until the light comes back. Water less than you did in summer, hold off feeding, and don't read the pause as a problem."
            cue = "Water less and hold feeding for now"
        } else if sill < 2.5 {
            detail = "Enough to hold condition, not enough for much new growth. Keep feeding light and let pots dry further down than you would in summer."
            cue = "Feed lightly and let pots dry deeper"
        } else {
            detail = "Plenty for anything on a sill. Pots at that window will dry a good deal faster than the ones across the room. They are not on the same schedule."
            cue = "Sill pots dry faster than the rest of the room"
        }

        return GroveSkyAdvisory(
            kind: .lightBudget,
            tone: .calm,
            symbol: "sun.max.fill",
            headline: "\(duration(outdoor)) of full sun a day out there. A windowsill sees about half of it, the far side of the room a twentieth.",
            detail: detail,
            plantNames: names,
            cue: cue,
            figure: .lightLadder(outdoorHours: outdoor)
        )
    }

    // MARK: - Indoor humidity model

    /// Estimated indoor relative humidity, given a day's outdoor conditions.
    ///
    /// Assumes a home that is ventilated rather than humidified and held near
    /// 20°C — the ordinary case, and the one where the effect is largest. When
    /// it is warmer outside than in, the model has nothing to add and the
    /// outdoor reading stands.
    ///
    /// Returns nil when the response carried no dew point.
    static func indoorHumidity(for day: GroveWeatherDay, indoorCelsius: Double = 20) -> Double? {
        guard let dewPoint = day.dewPointCelsius else { return nil }
        let outdoorMean = (day.highCelsius + day.lowCelsius) / 2
        guard outdoorMean < indoorCelsius - 2 else { return day.outdoorHumidity }
        let ratio = saturationVapourPressure(dewPoint) / saturationVapourPressure(indoorCelsius)
        return min(100, max(1, ratio * 100))
    }

    /// Magnus-Tetens saturation vapour pressure in hPa. Accurate to a fraction
    /// of a percent across every temperature a house sees.
    private static func saturationVapourPressure(_ celsius: Double) -> Double {
        6.112 * exp(17.62 * celsius / (243.12 + celsius))
    }

    // MARK: - Helpers

    private struct Night {
        let day: GroveWeatherDay
        /// "tonight", "tomorrow night", "Thursday night".
        let phrase: String
    }

    /// The coldest of the coming nights.
    ///
    /// A daily minimum falls at dawn, so the night that is about to happen is
    /// carried by *tomorrow's* figure, not today's — today's minimum is already
    /// behind us by the time anybody opens the app. Getting this wrong tells
    /// people to move a plant off the glass for a frost that happened while
    /// they were asleep.
    private static func coldestNight(_ forecast: GroveForecast, within count: Int, now: Date) -> Night? {
        let nights = upcomingDays(forecast, includingToday: false, limit: count, now: now)
        guard let coldest = nights.min(by: { $0.lowCelsius < $1.lowCelsius }) else { return nil }

        var calendar = Calendar.current
        calendar.timeZone = coldest.timeZone
        let today = calendar.startOfDay(for: now)
        let offset = calendar.dateComponents(
            [.day],
            from: today,
            to: calendar.startOfDay(for: coldest.date)
        ).day

        switch offset {
        case 1: return Night(day: coldest, phrase: "tonight")
        case 2: return Night(day: coldest, phrase: "tomorrow night")
        default:
            // Name the evening people will be awake for, not the morning the
            // figure is filed under: a low recorded at dawn on Friday is
            // Thursday night to everyone who has to move a plant.
            return Night(day: coldest, phrase: "\(eveningName(before: coldest)) night")
        }
    }

    /// The weekday of the evening preceding a daily minimum, in the grove's
    /// timezone.
    private static func eveningName(before day: GroveWeatherDay) -> String {
        var calendar = Calendar.current
        calendar.timeZone = day.timeZone
        let eve = calendar.date(byAdding: .day, value: -1, to: day.date) ?? day.date
        let index = calendar.component(.weekday, from: eve) - 1
        let symbols = calendar.weekdaySymbols
        return symbols.indices.contains(index) ? symbols[index] : day.weekdayName
    }

    private static func dayPhrase(_ day: GroveWeatherDay, in forecast: GroveForecast, now: Date) -> String {
        guard forecast.days.contains(day) else { return "this week" }
        var calendar = Calendar.current
        calendar.timeZone = day.timeZone
        let offset = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: day.date)
        ).day
        switch offset {
        case 0: return "today"
        case 1: return "tomorrow"
        default: return "on \(day.weekdayName)"
        }
    }

    /// Upcoming local calendar days, independent of whether the response still
    /// contains today's row. Filtering by date rather than dropping an array
    /// index keeps "tonight" correct across partial responses and time zones.
    private static func upcomingDays(
        _ forecast: GroveForecast,
        includingToday: Bool,
        limit: Int,
        now: Date
    ) -> [GroveWeatherDay] {
        guard limit > 0 else { return [] }
        return Array(forecast.days.filter { day in
            var calendar = Calendar.current
            calendar.timeZone = day.timeZone
            let dayStart = calendar.startOfDay(for: day.date)
            let today = calendar.startOfDay(for: now)
            return includingToday ? dayStart >= today : dayStart > today
        }.prefix(limit))
    }

    /// Whether the forecast symbol means the sun is actually reaching the
    /// ground. Only the two clear symbols qualify; anything with cloud in it
    /// takes the edge off a sill.
    private static func isClear(_ symbol: String) -> Bool {
        symbol == "sun.max.fill" || symbol == "cloud.sun.fill"
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// "Monty", "Monty and Fern", "Monty, Fern and two others" — a sentence
    /// someone would say, never a comma-joined array.
    static func list(_ names: [String], limit: Int = 2) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            let shown = names.prefix(limit).joined(separator: ", ")
            let rest = names.count - limit
            return "\(shown) and \(spelled(rest)) other\(rest == 1 ? "" : "s")"
        }
    }

    private static func spelled(_ count: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return words.indices.contains(count) ? words[count] : String(count)
    }

    /// "3h", "3h 20m" — an amount of afternoon, not a decimal measurement.
    static func duration(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        let whole = totalMinutes / 60
        let minutes = totalMinutes % 60
        if whole == 0 { return "\(minutes)m" }
        return minutes == 0 ? "\(whole)h" : "\(whole)h \(minutes)m"
    }
}
