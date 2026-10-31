import SwiftUI

/// Two weeks of sun over the grove, drawn as a bar per day.
///
/// The weather strip answers "what is the sky doing this week". This answers a
/// different question, and the one a plant actually cares about: *how much sun
/// has there been lately*. A fortnight of grey is invisible day to day — each
/// morning just looks like weather — but it is the reason the fiddle-leaf
/// stopped pushing leaves and the soil is still wet four days after watering.
///
/// Each day is drawn twice: a faint track for the daylight the day had to give
/// (sunrise to sunset), and a solid bar for the sun that actually got through
/// the cloud. A short bar inside a tall track means an overcast day; on the
/// shortest days of the year both are short, and the plant is short of light
/// either way.
struct SunlightCard: View {
    let locationLabel: String
    let days: [GroveSunlightDay]
    /// Rendered inside `SkyCard`'s expansion rather than standing on its own.
    /// Drops the card chrome and the header — the host already says where this
    /// is and how far back it reaches, and two nested cards saying "sun on your
    /// grove" would be the redundancy this merge exists to remove.
    var embedded: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDate: Date?
    @State private var barsGrown = false

    /// Room on the right for the axis labels, kept out of the plot so bars and
    /// the day letters underneath share one set of column centres.
    private let axisGutter: CGFloat = 30
    private let plotHeight: CGFloat = 152
    /// The readout pill is fixed-width so it can be kept inside the plot
    /// without measuring itself first. "12h 45m" is the longest it ever holds.
    private let tooltipWidth: CGFloat = 86

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded { header }
            stats
            chart
            axis
            reading
        }
        .modifier(GroveConditionalCard(enabled: !embedded))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Full sun on your grove, last \(days.count) days")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Swipe up or down to hear each day")
        .accessibilityAdjustableAction(step)
    }

    // MARK: - Derived numbers

    private var selected: GroveSunlightDay? {
        guard let selectedDate else { return nil }
        return days.first { $0.date == selectedDate }
    }

    private var totalHours: Double {
        days.reduce(0) { $0 + $1.fullSunHours }
    }

    private var averageHours: Double {
        days.isEmpty ? 0 : totalHours / Double(days.count)
    }

    /// Mean cloud cover across the fortnight, 0–100, or nil if the forecast
    /// carried none.
    ///
    /// This is what separates "dull fortnight" from "short days", and it has to
    /// be measured rather than inferred from the bars: even a cloudless
    /// midwinter day is a small fraction of its own length, because the sun
    /// never climbs high enough to reach full strength. Dividing sun by
    /// daylight — which this card did until the metric changed — would call
    /// every clear January "overcast".
    private var cloudiness: Double? {
        let readings = days.compactMap(\.cloudCover)
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0, +) / Double(readings.count)
    }

    /// Top of the scale. Anchored to the longest day's *daylight*, so the tracks
    /// always fit and two fortnights of the same season stay comparable.
    private var scaleMax: Double {
        let peak = days.map { max($0.daylightHours, $0.fullSunHours) }.max() ?? 1
        return max(2, (peak / 2).rounded(.up) * 2)
    }

    private var tickStep: Double {
        for candidate in [1.0, 2, 3, 4, 5, 6, 8, 10, 12] where scaleMax / candidate <= 3.5 {
            return candidate
        }
        return scaleMax / 3
    }

    private var ticks: [Double] {
        guard tickStep > 0 else { return [] }
        return stride(from: tickStep, through: scaleMax, by: tickStep).map { $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                GroveEyebrow(text: "Last \(days.count) days")
                Text("Full sun on your grove")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(GroveTheme.ink)
            }
            Spacer(minLength: 8)
            Image(systemName: "sun.max.fill")
                .font(.title3)
                .foregroundStyle(GroveTheme.gold)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Stats

    private var stats: some View {
        HStack(alignment: .top, spacing: 24) {
            stat(title: "Full sun, total", value: totalHours, unit: "hours")
            stat(title: "Daily average", value: averageHours, unit: "hours")
            Spacer(minLength: 0)
        }
    }

    private func stat(title: String, value: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GroveTheme.mutedInk)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Self.decimal(value))
                    .font(GroveTheme.display(34))
                    .foregroundStyle(GroveTheme.ink)
                Text(unit)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.mutedInk)
            }
        }
    }

    // MARK: - Chart

    private var chart: some View {
        GeometryReader { geo in
            let plotWidth = max(1, geo.size.width - axisGutter)
            let slot = plotWidth / CGFloat(max(days.count, 1))
            let barWidth = min(12, max(5, slot * 0.5))
            let height = geo.size.height

            ZStack(alignment: .topLeading) {
                gridlines(plotWidth: plotWidth, height: height)

                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    bar(
                        day,
                        index: index,
                        centerX: slot * (CGFloat(index) + 0.5),
                        width: barWidth,
                        height: height
                    )
                }

                averageLine(plotWidth: plotWidth, height: height)

                if let selected, let index = days.firstIndex(of: selected) {
                    tooltip(
                        for: selected,
                        centerX: slot * (CGFloat(index) + 0.5),
                        plotWidth: plotWidth,
                        height: height
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in select(atX: value.location.x, slot: slot) }
            )
        }
        .frame(height: plotHeight)
        // Bars grow out of the baseline in order, so a fortnight reads as
        // something that accumulated rather than a slab that was always there.
        .onAppear {
            barsGrown = true
            // Today starts selected, because "how much sun did my plants get
            // today" is the question someone opened the card with.
            if selectedDate == nil { selectedDate = days.last?.date }
        }
    }

    private func gridlines(plotWidth: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { tick in
                let y = self.y(for: tick, in: height)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: plotWidth, y: y))
                }
                .stroke(GroveTheme.separator, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))

                Text("\(Self.trimmed(tick))h")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroveTheme.subtleInk)
                    .position(x: plotWidth + axisGutter / 2, y: y)
            }

            // Baseline, plus the unit it is a baseline of — the axis never has
            // to be guessed at.
            Path { path in
                path.move(to: CGPoint(x: 0, y: height))
                path.addLine(to: CGPoint(x: plotWidth, y: height))
            }
            .stroke(GroveTheme.separator, lineWidth: 1)

            Text("sun")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GroveTheme.subtleInk)
                .position(x: plotWidth + axisGutter / 2, y: height - 6)
        }
        .accessibilityHidden(true)
    }

    private func bar(_ day: GroveSunlightDay, index: Int, centerX: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        let trackHeight = max(2, CGFloat(day.daylightHours / scaleMax) * height)
        // A sliver of sun still gets a visible sliver of bar; rounding it to
        // nothing would say the day had none.
        let barHeight = day.fullSunHours > 0
            ? max(3, CGFloat(day.fullSunHours / scaleMax) * height)
            : 0
        let isSelected = selected?.id == day.id

        return ZStack {
            Capsule()
                .fill(GroveTheme.separator.opacity(isSelected ? 0.95 : 0.55))
                .frame(width: width, height: trackHeight)
                .position(x: centerX, y: height - trackHeight / 2)

            if barHeight > 0 {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [GroveTheme.gold, GroveTheme.goldDeep],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(day.isForecast ? 0.5 : 1)
                    .overlay {
                        // Today's figure is the whole day's forecast, not a
                        // tally of what has already fallen on the leaves. The
                        // dashed edge is that caveat, drawn.
                        if day.isForecast {
                            Capsule().strokeBorder(GroveTheme.goldDeep, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        }
                    }
                    .frame(width: width, height: barHeight)
                    .scaleEffect(y: barsGrown || reduceMotion ? 1 : 0, anchor: .bottom)
                    .animation(
                        reduceMotion ? nil : GroveMotion.settle.delay(Double(index) * 0.022),
                        value: barsGrown
                    )
                    .position(x: centerX, y: height - barHeight / 2)
            }
        }
    }

    private func averageLine(plotWidth: CGFloat, height: CGFloat) -> some View {
        let y = self.y(for: averageHours, in: height)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: plotWidth, y: y))
            }
            .stroke(GroveTheme.ink.opacity(0.45), lineWidth: 1)

            Text(Self.decimal(averageHours))
                .font(.caption2.weight(.bold))
                .foregroundStyle(GroveTheme.ink)
                .position(x: plotWidth + axisGutter / 2, y: y - 9)
        }
        .accessibilityHidden(true)
    }

    private func tooltip(for day: GroveSunlightDay, centerX: CGFloat, plotWidth: CGFloat, height: CGFloat) -> some View {
        let barTop = height - max(3, CGFloat(day.fullSunHours / scaleMax) * height)
        let half = tooltipWidth / 2
        let clampedX = min(max(centerX, half), max(half, plotWidth - half))

        return Text(Self.duration(day.fullSunHours))
            .font(.caption.weight(.bold))
            .foregroundStyle(GroveTheme.onCanvasButtonLabel)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: tooltipWidth)
            .padding(.vertical, 5)
            .background(GroveTheme.onCanvasButton, in: Capsule())
            .position(x: clampedX, y: max(10, barTop - 16))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func y(for value: Double, in height: CGFloat) -> CGFloat {
        height - CGFloat(min(value, scaleMax) / scaleMax) * height
    }

    // MARK: - Axis

    private var axis: some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                let isSelected = selected?.id == day.id
                VStack(spacing: 2) {
                    Text(day.weekdayLetter)
                    Text(day.dayOfMonth)
                }
                .font(.caption2.weight(day.isToday ? .bold : .semibold))
                .foregroundStyle(labelColor(for: day, selected: isSelected))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected {
                        Capsule().fill(GroveTheme.onCanvasButton)
                    }
                }
            }
        }
        .padding(.trailing, axisGutter)
        .accessibilityHidden(true)
    }

    private func labelColor(for day: GroveSunlightDay, selected: Bool) -> Color {
        if selected { return GroveTheme.onCanvasButtonLabel }
        return day.isToday ? GroveTheme.ink : GroveTheme.mutedInk
    }

    // MARK: - What it means

    private var reading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(footnote)
                .font(.caption)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The caveat that lets the chart sit next to a health score honestly, and
    /// the translation that makes it useful: outdoor light is abundant nearly
    /// everywhere, and the number that decides whether a plant grows is what is
    /// left of it after a window and three metres of room.
    private var footnote: String {
        var text = "Measured outdoors at \(locationLabel). A windowsill sees roughly half of this; the far side of the room a twentieth."
        if days.last?.isForecast == true {
            text += " Today's bar is the forecast for the whole day."
        }
        return text
    }

    /// One sentence of what the fortnight means for the plants, tied to the
    /// number above it. Dull weather is not a scolding — it changes what good
    /// care looks like, and that is the useful part.
    ///
    /// Keyed to measured cloud cover rather than to the bars' own height. The
    /// bars are hours of *full-strength* sun, and in midwinter those are short
    /// however clear the sky is: reading the chart's own shape as cloudiness
    /// would announce a grey fortnight every December.
    private var headline: String {
        guard let cloudiness else {
            return "\(Self.duration(averageHours)) of full sun a day. On a sill that is about half; further into the room, very little."
        }
        switch cloudiness {
        case 70...:
            return "A grey fortnight: \(Int(cloudiness.rounded()))% cloud, and only \(Self.duration(averageHours)) of full sun a day. Pots stay wet far longer in this, so feel the soil before you water anything."
        case 45..<70:
            return "More cloud than clear lately, \(Self.duration(averageHours)) of full sun a day. Growth slows to match, so stretch the gap between waterings rather than shortening it."
        case 25..<45:
            return "A fair run of sun, \(Self.duration(averageHours)) a day. Enough for anything on a bright sill to keep pushing leaves."
        default:
            return "A bright fortnight, \(Self.duration(averageHours)) of full sun a day. Watch the shade-lovers on sills for bleached, papery patches."
        }
    }

    // MARK: - Selection

    private func select(atX x: CGFloat, slot: CGFloat) {
        guard slot > 0, !days.isEmpty else { return }
        let index = min(days.count - 1, max(0, Int(x / slot)))
        guard days[index].date != selectedDate else { return }
        Haptics.selection()
        withAnimation(GroveMotion.snap) { selectedDate = days[index].date }
    }

    private func step(_ direction: AccessibilityAdjustmentDirection) {
        guard !days.isEmpty else { return }
        let current = selected.flatMap { days.firstIndex(of: $0) } ?? days.count - 1
        let next = direction == .increment ? current + 1 : current - 1
        guard days.indices.contains(next) else { return }
        selectedDate = days[next].date
    }

    private var accessibilityValue: String {
        if let selected {
            let day = selected.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
            return "\(day), \(Self.duration(selected.fullSunHours)) of full sun in \(Self.duration(selected.daylightHours)) of daylight"
        }
        return "\(Self.decimal(totalHours)) hours in total, \(Self.decimal(averageHours)) hours a day on average"
    }

    // MARK: - Formatting

    /// One decimal place, and none at all when it would be a trailing zero.
    private static func decimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }

    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// "6h 24m" — the shape a person reads a duration in.
    private static func duration(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}

// MARK: - Placeholder

/// The card's shape while the forecast is in flight, so the page does not jump
/// by 300 points when the sun data lands.
struct SunlightCardPlaceholder: View {
    private let heights: [CGFloat] = [0.5, 0.7, 0.35, 0.9, 0.6, 0.25, 0.8, 0.55, 0.7, 0.4, 0.85, 0.6, 0.45, 0.75]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                GroveEyebrow(text: "Last 14 days")
                Text("Full sun on your grove")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(GroveTheme.ink)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(heights.enumerated()), id: \.offset) { _, fraction in
                    Capsule()
                        .fill(GroveTheme.separator)
                        .frame(height: 152 * fraction)
                        .frame(maxWidth: 12)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 152, alignment: .bottom)
        }
        .groveCard()
        .redacted(reason: .placeholder)
        .groveShimmer()
        .accessibilityLabel("Loading sunlight for your grove")
    }
}

#Preview {
    let calendar = Calendar.current
    let days: [GroveSunlightDay] = (0..<14).reversed().map { offset in
        let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: .now))!
        let daylight = 14.5 + Double(offset % 3) * 0.2
        let fullSun = [1.2, 5.4, 0.4, 6.9, 3.1, 0.2, 6.2, 4.5, 2.3, 7.1, 4.8, 1.1, 5.9, 6.6][offset % 14]
        let cloud = [88.0, 22, 95, 8, 61, 97, 15, 34, 74, 5, 30, 90, 18, 12][offset % 14]
        return GroveSunlightDay(date: date, fullSunHours: fullSun, daylightHours: daylight, cloudCover: cloud)
    }
    return ScrollView {
        VStack(spacing: 20) {
            SunlightCard(locationLabel: "Hackney", days: days)
            SunlightCardPlaceholder()
        }
        .padding()
    }
    .groveBackground()
}
