import Foundation

/// The gaps between waterings that actually happened.
///
/// Every other number on the plant page is modelled: the health score is a
/// judgement, the dry-down estimate is physics bent by whatever the scan could
/// make out of the pot. This one is arithmetic on dates the owner logged
/// themselves — subtraction, nothing more — which makes it the only reading in
/// the product that cannot be wrong about the plant in front of them.
///
/// It is also the more useful predictor once there is history. `SoilDryDown`
/// reasons forward from pot material and light because it has to guess at the
/// room; a record of real intervals already contains the room, the radiator and
/// the owner's habits without needing to understand any of them.
struct WateringRhythm: Hashable {
    /// One completed watering, oldest first.
    struct Watering: Hashable, Identifiable {
        let id: UUID
        let date: Date
        /// True when `date` came from a reminder rather than a record — a
        /// watering ticked off before Grove started stamping the moment.
        let dateIsInferred: Bool
    }

    /// The gap between two consecutive waterings.
    struct Interval: Hashable, Identifiable {
        let id: UUID
        /// Whole days from the previous watering to this one.
        let days: Int
        /// When the gap ended, which is the watering this interval belongs to.
        let endedAt: Date
        /// True when either end of the gap was dated by a reminder, so the
        /// length is approximate. Drawn hollow rather than filled.
        let isApproximate: Bool
    }

    /// How the recent rhythm compares with the earlier one.
    enum Drift: Hashable {
        /// Not enough intervals to say anything, or the change is inside noise.
        case steady
        /// Waterings have moved further apart — the usual shape of autumn.
        case slowing(from: Int, to: Int)
        /// Waterings have moved closer together — longer days, or a plant that
        /// has grown into its pot.
        case quickening(from: Int, to: Int)
    }

    let waterings: [Watering]
    let intervals: [Interval]

    /// The middle interval, not the mean. One holiday leaves a 40-day gap that
    /// drags an average somewhere no watering ever actually happened; the median
    /// describes the rhythm the owner actually keeps.
    let typicalDays: Int?

    /// Days since the most recent watering, for the "you are here" marker.
    let daysSinceLast: Int?

    let drift: Drift

    /// True when any interval rests on a reminder date, which the caption has to
    /// admit rather than let the chart imply a precision it lacks.
    var hasApproximateIntervals: Bool { intervals.contains { $0.isApproximate } }

    /// Two waterings is one gap, which is an anecdote. Three gaps is the fewest
    /// that can show a rhythm rather than a coincidence, and it is the bar for
    /// putting this on the page at all.
    static let minimumIntervals = 3

    var isReadable: Bool { intervals.count >= Self.minimumIntervals }

    // MARK: - Derivation

    init(plantID: UUID, tasks: [CareTask], now: Date = .now, calendar: Calendar = .current) {
        let dates = tasks
            .filter { $0.plantID == plantID && $0.kind == .water && $0.isCompleted }
            .map { (task: $0, at: $0.performedAt) }
            .filter { $0.at <= now }
            .sorted { $0.at < $1.at }

        waterings = dates.map {
            Watering(id: $0.task.id, date: $0.at, dateIsInferred: $0.task.dateIsInferred)
        }

        intervals = zip(waterings, waterings.dropFirst()).compactMap { previous, current in
            let days = Self.wholeDays(from: previous.date, to: current.date, calendar: calendar)
            // Two waterings logged the same day are one watering entered twice,
            // or a top-up. Either way it is not a gap, and a zero-height bar
            // would read as a rhythm collapsing.
            guard days >= 1 else { return nil }
            return Interval(
                id: current.id,
                days: days,
                endedAt: current.date,
                isApproximate: previous.dateIsInferred || current.dateIsInferred
            )
        }

        typicalDays = Self.median(of: intervals.map(\.days))
        daysSinceLast = waterings.last.map { Self.wholeDays(from: $0.date, to: now, calendar: calendar) }
        drift = Self.drift(in: intervals)
    }

    // MARK: - Maths

    private static func wholeDays(from start: Date, to end: Date, calendar: Calendar) -> Int {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: start),
            to: calendar.startOfDay(for: end)
        ).day
        return max(0, days ?? 0)
    }

    private static func median(of values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// Compares the median of the older half against the newer half.
    ///
    /// Halves rather than first-versus-last, and medians rather than means, so a
    /// single missed week cannot be reported to the owner as a season changing.
    /// The threshold is proportional — three days matters on a weekly rhythm and
    /// is noise on a monthly one — with an absolute floor so a plant watered
    /// every three days does not trip on rounding alone.
    private static func drift(in intervals: [Interval]) -> Drift {
        guard intervals.count >= 4 else { return .steady }
        let split = intervals.count / 2
        guard let older = median(of: intervals.prefix(split).map(\.days)),
              let newer = median(of: intervals.suffix(from: split).map(\.days)),
              older > 0 else { return .steady }

        let change = abs(newer - older)
        guard change >= 2, Double(change) / Double(older) >= 0.3 else { return .steady }
        return newer > older ? .slowing(from: older, to: newer) : .quickening(from: older, to: newer)
    }
}
