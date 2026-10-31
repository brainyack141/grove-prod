import Foundation
import CoreLocation

/// A single day in the Grove weather strip.
///
/// Temperatures are held in Celsius whatever the user's measurement preference,
/// and converted at the point of display. Advice thresholds — a cold pane, a
/// scorching sill, a frost — are physical facts about a plant, not about a
/// setting, and a code path that has to ask which unit it is holding before it
/// can compare against one will eventually forget to.
struct GroveWeatherDay: Identifiable, Hashable {
    let date: Date
    let symbol: String
    let highCelsius: Double
    let lowCelsius: Double
    /// Mean dew point. The single most useful number for indoor air: once a
    /// home is heated, indoor humidity is very nearly a function of the outdoor
    /// dew point alone. Nil if the response omitted it.
    let dewPointCelsius: Double?
    /// Mean outdoor relative humidity, 0–100.
    let outdoorHumidity: Double?
    /// Total precipitation in millimetres.
    let precipitationMillimetres: Double?
    /// The grove's timezone as reported by the forecast API. Day boundaries
    /// must be evaluated there — using the device timezone shifts the strip
    /// by a day when the device and the pinned grove straddle midnight.
    var timeZone: TimeZone = .current

    var id: Date { date }

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar
    }

    var isToday: Bool {
        calendar.isDate(date, inSameDayAs: .now)
    }

    /// Single-letter weekday used in the compact strip ("M", "T", …).
    var weekdayLetter: String {
        let symbols = calendar.veryShortWeekdaySymbols
        let index = calendar.component(.weekday, from: date) - 1
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    /// The weekday as someone would say it out loud — "Thursday" — for advice
    /// that has to name the night it is talking about.
    var weekdayName: String {
        let symbols = calendar.weekdaySymbols
        let index = calendar.component(.weekday, from: date) - 1
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    func high(metric: Bool) -> Int { Self.temperature(highCelsius, metric: metric) }
    func low(metric: Bool) -> Int { Self.temperature(lowCelsius, metric: metric) }

    static func temperature(_ celsius: Double, metric: Bool) -> Int {
        Int((metric ? celsius : celsius * 9 / 5 + 32).rounded())
    }
}

/// The outdoor conditions at the Grove's pinned location when the forecast was
/// fetched. This is deliberately separate from the daily strip: a day's high
/// is useful context for the week, but it is not an honest answer to "what is
/// it like there now?"
struct GroveCurrentConditions: Equatable {
    let temperatureCelsius: Double
    /// Outdoor relative humidity, 0–100. This must not be presented as an
    /// indoor sensor reading — the API knows the air around the location, not
    /// the air in the room.
    let outdoorHumidity: Double?
    let symbol: String
    let timeZone: TimeZone

    func temperature(metric: Bool) -> Int {
        GroveWeatherDay.temperature(temperatureCelsius, metric: metric)
    }

    var humidityPercent: Int? {
        outdoorHumidity.map { Int($0.rounded()) }
    }
}

/// One day of light at the grove's location.
///
/// `fullSunHours` is derived from the day's total shortwave radiation rather
/// than from the forecast model's `sunshine_duration`, which was what this held
/// until it was checked against reality: that field reported 6h 24m of sun on a
/// day with 10mm of rain and 72% cloud, and sat within an hour of the day length
/// in nearly all weather. A chart whose whole purpose is to make a grey
/// fortnight visible cannot be built on a number that barely moves when the sky
/// closes.
///
/// Radiation moves. The same two days come out at 0h 44m and 3h 30m. One
/// kilowatt-hour per square metre is the sun at full midday strength for an
/// hour — the solar industry's "peak sun hour" — so dividing the day's megajoules
/// by 3.6 gives hours of full-strength sun, which is both honest and still an
/// amount of afternoon a person can picture.
///
/// `daylightHours` is simply sunrise to sunset: the most the day could ever have
/// offered. Holding both is what lets the chart say "three hours of full sun in
/// a ten-hour day" rather than an unanchored number.
struct GroveSunlightDay: Identifiable, Hashable {
    let date: Date
    /// Hours of full-strength sun: the day's shortwave radiation expressed as
    /// the time it would have taken to arrive at peak midday intensity.
    let fullSunHours: Double
    let daylightHours: Double
    /// Mean cloud cover, 0–100. The plain-language half of the same story, and
    /// what separates "short winter day" from "grey week".
    let cloudCover: Double?
    /// The grove's timezone, for the same reason `GroveWeatherDay` carries one.
    var timeZone: TimeZone = .current

    var id: Date { date }

    /// Megajoules per square metre of shortwave radiation, recovered from the
    /// hours figure. The two are the same measurement in different clothes.
    var radiationMegajoules: Double { fullSunHours * GroveSunlightDay.peakSunMegajoules }

    /// Daily Light Integral outdoors, in mol/m²/day — the unit growers actually
    /// use to decide whether a plant will grow, hold, or decline.
    ///
    /// Roughly 45% of shortwave energy falls in the band plants photosynthesise
    /// in, and that band carries about 4.6 µmol of photons per joule, so a
    /// megajoule of shortwave is about 2.06 mol of usable light.
    var lightIntegral: Double { radiationMegajoules * GroveSunlightDay.molPerMegajoule }

    static let peakSunMegajoules: Double = 3.6
    static let molPerMegajoule: Double = 2.06

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar
    }

    var isToday: Bool {
        calendar.isDate(date, inSameDayAs: .now)
    }

    /// Today's figure is the model's number for the whole day, most of which
    /// has usually not happened yet. The chart marks it so nobody reads a
    /// forecast as a record.
    var isForecast: Bool {
        calendar.startOfDay(for: date) >= calendar.startOfDay(for: .now)
    }

    var weekdayLetter: String {
        let symbols = calendar.veryShortWeekdaySymbols
        let index = calendar.component(.weekday, from: date) - 1
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    var dayOfMonth: String {
        String(calendar.component(.day, from: date))
    }

    /// Share of the day that arrived as full-strength sun, 0…1. Nil on a polar
    /// night, where the ratio has no meaning.
    ///
    /// Note this is not a cloud-cover reading: even a cloudless winter day is a
    /// low fraction of its own length, because the sun never climbs high enough
    /// to reach full strength. Use `cloudCover` for "was it grey", and this for
    /// "how much of the day was worth anything to a plant".
    var fullSunShare: Double? {
        guard daylightHours > 0 else { return nil }
        return min(1, fullSunHours / daylightHours)
    }
}

/// Everything one forecast request yields: the week ahead for the strip, and
/// the fortnight behind for the sunlight chart.
struct GroveForecast: Equatable {
    /// Today forward — what the weather strip shows.
    var days: [GroveWeatherDay]
    /// The trailing two weeks, today last.
    var sunlight: [GroveSunlightDay]
    /// A live reading for the hero. Defaulted so forecasts created by care
    /// rules and test fixtures remain about the daily evidence they need.
    var current: GroveCurrentConditions? = nil
}

/// Loads a short daily forecast for wherever a user's Grove lives, using the
/// free, key-less Open-Meteo API. Weather is tied to the Grove's pinned
/// coordinate rather than the device location, so it matches where the plants
/// actually are.
@MainActor
@Observable
final class WeatherService {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded(GroveForecast)
        case failed
    }

    /// Days of history fetched alongside the forecast. Two weeks is long enough
    /// for a run of dull days to be visible as a run, and short enough that the
    /// bars stay wide enough to touch.
    static let sunlightWindow = 14

    private(set) var phase: Phase = .idle
    private let session: URLSession
    /// The newest request. Loads overlap (the app shell, pull to refresh, a
    /// location change) and can land out of order; only this one may write.
    @ObservationIgnored private var latestRequest = UUID()
    /// Where the forecast on screen is for, so a refresh of the same place
    /// can keep showing it while the new one loads.
    @ObservationIgnored private var loadedCoordinate: CLLocationCoordinate2D?

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetch a 7-day forecast, and the fortnight behind it, for the given
    /// coordinate.
    ///
    /// Always in Celsius: the response feeds care advice with physical
    /// thresholds in it, and the user's unit preference is a display concern.
    /// It is also one fewer reason to refetch — toggling °F used to throw the
    /// whole forecast away and ask for it again.
    func load(for coordinate: CLLocationCoordinate2D) async {
        let request = UUID()
        latestRequest = request
        // A refresh of the same place keeps the forecast it already has: pull
        // to refresh used to swap "18°" for a spinner, and a failed refresh
        // threw a perfectly good forecast away. A new place starts clean.
        let isRefresh: Bool
        if case .loaded = phase, let loadedCoordinate,
           loadedCoordinate.latitude == coordinate.latitude,
           loadedCoordinate.longitude == coordinate.longitude {
            isRefresh = true
        } else {
            isRefresh = false
            loadedCoordinate = nil
            phase = .loading
        }
        func fail() {
            guard latestRequest == request, !isRefresh else { return }
            phase = .failed
        }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(
                name: "current",
                value: [
                    "temperature_2m",
                    "relative_humidity_2m",
                    "weather_code"
                ].joined(separator: ",")
            ),
            URLQueryItem(
                name: "daily",
                value: [
                    "weather_code",
                    "temperature_2m_max",
                    "temperature_2m_min",
                    "shortwave_radiation_sum",
                    "daylight_duration",
                    "cloud_cover_mean",
                    "dew_point_2m_mean",
                    "relative_humidity_2m_mean",
                    "precipitation_sum"
                ].joined(separator: ",")
            ),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7"),
            // The sunlight chart looks backwards, the strip forwards; one
            // request serves both, on one timezone, with one failure to handle.
            URLQueryItem(name: "past_days", value: String(Self.sunlightWindow - 1))
        ]

        guard let url = components?.url else {
            fail()
            return
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                fail()
                return
            }
            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            // A slower, older request must not overwrite a newer place.
            guard latestRequest == request else { return }
            phase = .loaded(decoded.forecast(window: Self.sunlightWindow))
            loadedCoordinate = coordinate
        } catch {
            fail()
        }
    }
}

// MARK: - Open-Meteo decoding

private struct OpenMeteoResponse: Decodable {
    let daily: Daily
    /// Optional so a partial API response can still power the established
    /// seven-day strip instead of turning the whole sky into a failure.
    let current: Current?
    /// IANA timezone of the forecast location, present because the request
    /// uses `timezone=auto`. The `yyyy-MM-dd` day strings are local to it.
    let timezone: String?

    struct Current: Decodable {
        let temperature: Double
        let humidity: Double?
        let weatherCode: Int?

        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case humidity = "relative_humidity_2m"
            case weatherCode = "weather_code"
        }
    }

    struct Daily: Decodable {
        let time: [String]
        let weatherCode: [Int]
        let temperatureMax: [Double]
        let temperatureMin: [Double]
        /// Megajoules per square metre. Optional so a response missing the
        /// radiation fields still yields a working weather strip.
        let radiationSum: [Double?]?
        let daylightDuration: [Double?]?
        let cloudCover: [Double?]?
        let dewPoint: [Double?]?
        let humidity: [Double?]?
        let precipitation: [Double?]?

        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode = "weather_code"
            case temperatureMax = "temperature_2m_max"
            case temperatureMin = "temperature_2m_min"
            case radiationSum = "shortwave_radiation_sum"
            case daylightDuration = "daylight_duration"
            case cloudCover = "cloud_cover_mean"
            case dewPoint = "dew_point_2m_mean"
            case humidity = "relative_humidity_2m_mean"
            case precipitation = "precipitation_sum"
        }
    }

    /// Parses date strings in the API's `yyyy-MM-dd` local format, anchored to
    /// the forecast location's timezone — parsing in the device timezone would
    /// shift every day label when the two differ across midnight.
    private func dateFormatter(in timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        return formatter
    }

    /// Splits one response into the two views of it the Today page needs.
    /// `window` is how many trailing days the sunlight chart wants, counting
    /// today as the last of them.
    func forecast(window: Int) -> GroveForecast {
        let groveTimeZone = timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        let formatter = dateFormatter(in: groveTimeZone)
        var calendar = Calendar.current
        calendar.timeZone = groveTimeZone
        let today = calendar.startOfDay(for: .now)

        let dates = daily.time.map { formatter.date(from: $0) }

        func value(_ series: [Double?]?, _ index: Int) -> Double? {
            guard let series, series.indices.contains(index) else { return nil }
            return series[index]
        }

        var weather: [GroveWeatherDay] = []
        for (index, date) in dates.enumerated() {
            guard let date, date >= today else { continue }
            guard index < daily.weatherCode.count,
                  index < daily.temperatureMax.count,
                  index < daily.temperatureMin.count else { continue }
            weather.append(
                GroveWeatherDay(
                    date: date,
                    symbol: WMOWeather.symbol(for: daily.weatherCode[index]),
                    highCelsius: daily.temperatureMax[index],
                    lowCelsius: daily.temperatureMin[index],
                    dewPointCelsius: value(daily.dewPoint, index),
                    outdoorHumidity: value(daily.humidity, index),
                    precipitationMillimetres: value(daily.precipitation, index),
                    timeZone: groveTimeZone
                )
            )
        }

        var sunlight: [GroveSunlightDay] = []
        for (index, date) in dates.enumerated() {
            guard let date, date <= today else { continue }
            // A day the model has no radiation figure for is dropped rather
            // than drawn as an empty bar, which would read as "no sun at all".
            guard let megajoules = value(daily.radiationSum, index),
                  let daylightSeconds = value(daily.daylightDuration, index) else { continue }
            sunlight.append(
                GroveSunlightDay(
                    date: date,
                    fullSunHours: max(0, megajoules / GroveSunlightDay.peakSunMegajoules),
                    daylightHours: max(0, daylightSeconds / 3600),
                    cloudCover: value(daily.cloudCover, index),
                    timeZone: groveTimeZone
                )
            )
        }

        let currentConditions = current.map {
            GroveCurrentConditions(
                temperatureCelsius: $0.temperature,
                outdoorHumidity: $0.humidity,
                symbol: $0.weatherCode.map { WMOWeather.symbol(for: $0) } ?? "thermometer.medium",
                timeZone: groveTimeZone
            )
        }

        return GroveForecast(
            days: Array(weather.prefix(7)),
            sunlight: Array(sunlight.suffix(window)),
            current: currentConditions
        )
    }
}

/// Maps WMO weather interpretation codes to SF Symbols.
/// Reference: https://open-meteo.com/en/docs (WMO Weather interpretation codes)
enum WMOWeather {
    static func symbol(for code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"                       // Clear sky
        case 1: return "sun.max.fill"                       // Mainly clear
        case 2: return "cloud.sun.fill"                     // Partly cloudy
        case 3: return "cloud.fill"                         // Overcast
        case 45, 48: return "cloud.fog.fill"                // Fog
        case 51, 53, 55: return "cloud.drizzle.fill"        // Drizzle
        case 56, 57: return "cloud.sleet.fill"              // Freezing drizzle
        case 61, 63, 65: return "cloud.rain.fill"           // Rain
        case 66, 67: return "cloud.sleet.fill"              // Freezing rain
        case 71, 73, 75, 77: return "cloud.snow.fill"       // Snow
        case 80, 81, 82: return "cloud.heavyrain.fill"      // Rain showers
        case 85, 86: return "cloud.snow.fill"               // Snow showers
        case 95: return "cloud.bolt.rain.fill"              // Thunderstorm
        case 96, 99: return "cloud.bolt.rain.fill"          // Thunderstorm with hail
        default: return "cloud.fill"
        }
    }
}
