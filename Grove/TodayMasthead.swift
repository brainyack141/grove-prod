import Foundation

/// The hero card's words.
///
/// Pure and deterministic, in the shape of `AskPrompts`: the view hands in
/// state, this hands back sentences, and every branch is testable without a
/// store. Priority-ordered so a plant in trouble always beats pleasantries —
/// and the empty grove beats everything, because before this existed a person
/// with no plants at all was reading "Everything's where it should be."
enum TodayMasthead {

    // MARK: - Local date

    /// One of the seven local calendar days shown at the top of Today.
    /// `checkInCount` stays numeric even though the visual treatment is a dot,
    /// so VoiceOver can say how much is waiting behind that small signal.
    struct WeekDay: Identifiable, Equatable {
        let date: Date
        let checkInCount: Int
        let isToday: Bool

        var id: Date { date }
    }

    /// Today plus the next six days in the Grove's timezone.
    ///
    /// An overdue check-in cannot have its own visible date in a forward-looking
    /// strip, so it rolls into Today: it still needs attention now. Future dates
    /// use half-open day ranges so a task exactly at midnight appears once.
    static func week(
        checkInDates: [Date],
        from date: Date = .now,
        timeZone: TimeZone
    ) -> [WeekDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: date)

        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                return nil
            }

            let checkInCount = checkInDates.count { dueDate in
                if offset == 0 {
                    return dueDate < nextDay
                }
                return dueDate >= day && dueDate < nextDay
            }

            return WeekDay(date: day, checkInCount: checkInCount, isToday: offset == 0)
        }
    }

    /// The date in the Grove's timezone, ordered and punctuated for the
    /// reader's locale. A person checking their plants while travelling should
    /// see the day at home, not the day on the phone in their hand.
    static func dateLine(
        for date: Date = .now,
        timeZone: TimeZone,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter.string(from: date)
    }

    // MARK: - Greeting

    /// The big line over the hero photo. An empty grove gets a welcome; an
    /// established one gets the time of day — the "morning hello" the name
    /// step of onboarding promises. The middle of the day stays neutral, and
    /// late night does too: no salutation reads right at both 9.30pm and 3am.
    static func greeting(name: String, hasPlants: Bool, atmosphere: GroveAtmosphere) -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized.caseInsensitiveCompare("Gardener") == .orderedSame {
            return hasPlants ? "Your grove today" : "Welcome to your grove"
        }
        let name = firstName(from: normalized)
        guard hasPlants else { return "Welcome, \(name)." }
        switch atmosphere {
        case .preDawn, .dawn, .morning: return "Morning, \(name)."
        case .goldenHour, .dusk: return "Evening, \(name)."
        case .midnight, .day, .afternoon, .night: return "Hey, \(name)."
        }
    }

    /// Never let the greeting collapse to "Hey, ." — an account can reach the
    /// app without a display name (a provider that withheld the name, or a
    /// snapshot saved before the name step existed).
    static func firstName(from name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? "gardener"
    }

    // MARK: - Subtitle

    /// The supporting sentence. `heroPlant` is whichever plant the hero card
    /// chose to show — a struggling one when any exists — so naming it here
    /// always names the plant the person is already looking at.
    static func subtitle(
        heroPlant: Plant?,
        plantCount: Int,
        dueTaskCount: Int,
        plan: GrovePlan?,
        streak: Int
    ) -> String {
        if plantCount == 0 {
            // The onboarding plan already said whether plants exist outside
            // the app; "the one you'd miss most" echoes the answer they chose.
            if let size = plan?.collectionSize, size != "0" {
                return "Your plants aren't in Grove yet. Start with the one you'd miss most."
            }
            return "Add your first plant. A scan takes about a minute."
        }
        if let heroPlant, heroPlant.healthBand == .urgent || heroPlant.healthBand == .attention {
            return heroPlant.healthBand == .urgent
                ? "\(heroPlant.nickname) is in trouble. Check in on it today."
                : "\(heroPlant.nickname) isn't itself. Check in on it when you have a minute."
        }
        if dueTaskCount > 0 {
            return dueTaskCount == 1
                ? "One thing due today."
                : "\(dueTaskCount) things due today."
        }
        if plantCount == 1, let heroPlant {
            return "\(heroPlant.nickname) is settled in. Nothing needs you today."
        }
        if streak >= 2 {
            return "All good today. Your streak is at \(streak) days."
        }
        return "All good. Nothing due today."
    }
}

/// Chooses the plant shown in Today's living window.
///
/// The hero is context, not a carousel: it changes when the grove changes.
/// A plant that needs help is the most relevant context; on a calm day, the
/// freshest real photograph is the most honest account of what just happened.
/// Stable fallbacks keep older photo-less groves useful without inventing a
/// daily rotation that could make stale evidence look current.
enum TodayHeroPolicy {
    static func plant(
        from plants: [Plant],
        latestPhotoDates: [UUID: Date]
    ) -> Plant? {
        guard !plants.isEmpty else { return nil }

        if let concern = (plants
            .filter { concernPriority(for: $0) != nil }
            .reduce(nil as Plant?, { current, candidate in
                guard let current else { return candidate }
                return concernComesBefore(
                    candidate,
                    current,
                    latestPhotoDates: latestPhotoDates
                ) ? candidate : current
            })) {
            return concern
        }

        if let photographed = newest(
            plants,
            date: { latestPhotoDates[$0.id] }
        ) {
            return photographed
        }

        if let assessed = newest(plants, date: \.assessmentDate) {
            return assessed
        }

        return plants.first
    }

    private static func concernComesBefore(
        _ lhs: Plant,
        _ rhs: Plant,
        latestPhotoDates: [UUID: Date]
    ) -> Bool {
        let lhsPriority = concernPriority(for: lhs) ?? .max
        let rhsPriority = concernPriority(for: rhs) ?? .max
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        if lhs.healthScore != rhs.healthScore { return lhs.healthScore < rhs.healthScore }

        let lhsDate = latestPhotoDates[lhs.id] ?? lhs.assessmentDate ?? .distantPast
        let rhsDate = latestPhotoDates[rhs.id] ?? rhs.assessmentDate ?? .distantPast
        return lhsDate > rhsDate
    }

    private static func concernPriority(for plant: Plant) -> Int? {
        switch plant.healthBand {
        case .urgent: 0
        case .attention: 1
        case .monitor, .healthy, .thriving: nil
        }
    }

    /// Returns nil when every candidate lacks a date, preserving the distinct
    /// fallback below rather than pretending the first item is "recent".
    private static func newest(
        _ plants: [Plant],
        date: (Plant) -> Date?
    ) -> Plant? {
        var result: (plant: Plant, date: Date)?
        for plant in plants {
            guard let candidateDate = date(plant) else { continue }
            if result == nil || candidateDate > result!.date {
                result = (plant, candidateDate)
            }
        }
        return result?.plant
    }
}

/// Decides whether Today's lead care task is the one-off activation moment
/// between saving a plant's baseline and building its living record.
///
/// `TodayView` already resolves due-ness before this is called, but the date
/// guard lives here too so the one-off presentation cannot leak onto a future
/// task if this policy is reused elsewhere. The first saved observation is the
/// durable completion signal, so the card works across relaunches and devices
/// without another preference flag.
enum TodayTaskPresentation {
    static func isFirstComparison(
        task: CareTask,
        hasPriorObservation: Bool,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        guard let endOfToday = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        ) else { return false }

        return task.kind == .checkIn
            && !task.isCompleted
            && !task.isSittingTask
            && !hasPriorObservation
            && task.dueDate < endOfToday
    }
}
