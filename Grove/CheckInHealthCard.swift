import SwiftUI

/// One day in the weekly check-in chart.
struct CheckInDay: Identifiable {
    /// 0–6 from the start of the locale's week. Doubles as the day's column
    /// index in the chart, which is how the line and the markers stay aligned.
    let id: Int
    let date: Date
    /// Localized abbreviated weekday symbol (e.g. "Mon"), set in caps by the
    /// day row. This replaced the single-letter symbol: seven bare initials
    /// read as a code to be decoded — "M T W T F S S" has two Ts and two Ss —
    /// where three letters are simply the day.
    let shortName: String
    /// How many health readings were taken that day — check-ins and scans of
    /// plants in the grove alike, across every plant.
    let readingCount: Int
    /// How many distinct plants were looked at. This, not `readingCount`, is
    /// what the day's average is weighted by.
    let plantsSeen: Int
    /// Mean health across the plants looked at that day, or `nil` on a day
    /// nobody looked — and on a day whose only readings were saved offline
    /// without an assessment. See `GroveStore.dayScore(from:)`.
    let averageScore: Int?
    let isToday: Bool
    let isFuture: Bool

    var didCheckIn: Bool { readingCount > 0 }
    /// Someone looked, and nothing came back scored. The axis marks the look;
    /// the line steps over it rather than inventing a height for it.
    var isUnscored: Bool { didCheckIn && averageScore == nil }
    var band: HealthBand? { averageScore.map(HealthBand.init(score:)) }
}

/// A week of looking in, charted: what the grove's health averaged on each day
/// something was read, over a strip showing which days you looked.
///
/// "Looking" here means every way Grove actually reads a plant — a check-in, a
/// diagnosis, the scan that adopted it — because those all set the same health
/// score off the same kind of photograph. See `GroveStore.healthReadings`.
///
/// The card is built in three bands — masthead, the week's two numbers, then
/// the chart over its own day axis — so it reads top to bottom as *what this
/// is*, *how it went*, *how it moved and when you were there*. Each band
/// answers one question and stops.
///
/// The two measures share an x axis and never a y axis. Health is a 0–100
/// score and check-ins are a count of two or three, so plotting both as lines
/// against two different scales — the obvious way to draw this — would let the
/// arbitrary alignment of those scales invent a correlation the data doesn't
/// contain. The score is the chart; whether you turned up at all is the row of
/// markers on its axis.
struct CheckInHealthCard: View {
    @Environment(GroveStore.self) private var store

    private let goal = 7
    private static let plotHeight: CGFloat = 146
    /// Air reserved at the top of the plot for the latest reading's callout, so
    /// the number sits above its own dot without escaping the chart's band.
    /// The score domain maps into what is left underneath it.
    private static let calloutInset: CGFloat = 42
    private static let dotRadius: CGFloat = 5

    private var days: [CheckInDay] { store.currentWeekCheckIns }
    private var logged: Int { days.filter(\.didCheckIn).count }
    /// Only the days that actually carry a health reading, oldest first.
    private var scored: [CheckInDay] { days.filter { $0.averageScore != nil } }
    private var latest: CheckInDay? { scored.last }
    private var lowest: CheckInDay? { scored.min { ($0.averageScore ?? 0) < ($1.averageScore ?? 0) } }

    /// The week's health in one number: the mean of the days that carry a
    /// reading. Deliberately *not* the same number as the chart's callout —
    /// that one is the latest day. A card that prints one figure twice is a
    /// card with one fact on it.
    private var average: Int? {
        let scores = scored.compactMap(\.averageScore)
        guard !scores.isEmpty else { return nil }
        return Int((Double(scores.reduce(0, +)) / Double(scores.count)).rounded())
    }

    /// How far the week has moved: the newest reading against the first one.
    private var delta: Int? {
        guard scored.count > 1,
              let first = scored.first?.averageScore,
              let last = latest?.averageScore else { return nil }
        return last - first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            masthead
            numbers
            // The plot and its axis are one object, so they sit inside the
            // card's rhythm rather than on it — 8 points apart, not 20.
            VStack(spacing: 8) {
                if !scored.isEmpty { plot }
                weekAxis
            }
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.subtleInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .background(GroveTheme.surface)
        .groveHeroShape()
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.heroRadius, style: .continuous)
                .stroke(GroveTheme.separator, lineWidth: 1)
        }
    }

    // MARK: - Masthead

    /// Artwork, name, one line of what it is — and the week's direction anchored
    /// to the far edge. The eyebrow that used to sit here was a tracked-out
    /// caps label doing a heading's job at a caption's size; the card now says
    /// its own name in the display voice, like every other section in Grove.
    private var masthead: some View {
        HStack(alignment: .top, spacing: 14) {
            GroveArtworkTile(asset: "WeeklyHealthBespoke", size: 46)

            VStack(alignment: .leading, spacing: 3) {
                GroveDisplayHeading(text: "Your week", style: .heading)
                Text("Health, day by day")
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)
            deltaPill
        }
    }

    @ViewBuilder
    private var deltaPill: some View {
        if let delta, delta != 0 {
            // Arrow as well as colour: the direction has to survive being read
            // in greyscale, or by someone who can't separate the two greens.
            Label("\(abs(delta))", systemImage: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(delta > 0 ? GroveTheme.accentStrong : GroveTheme.warning)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    (delta > 0 ? GroveTheme.accent : GroveTheme.warning).opacity(0.12),
                    in: Capsule()
                )
                .accessibilityLabel(
                    delta > 0
                        ? "up \(delta) since the start of the week"
                        : "down \(abs(delta)) since the start of the week"
                )
                .padding(.top, 4)
        }
    }

    // MARK: - The week's two numbers

    /// Both figures in one recessed panel rather than floating in the card.
    /// A number set straight onto the card surface is a sentence; a number set
    /// into a well is a *reading* — the well is what tells you the two of them
    /// are the same kind of thing, measured over the same week.
    private var numbers: some View {
        HStack(alignment: .top, spacing: 16) {
            statColumn(
                label: "Average health",
                value: average,
                suffix: average.map { HealthBand(score: $0).shortTitle.lowercased() },
                empty: "No scores"
            )
            statColumn(
                label: "Days checked in",
                value: logged,
                suffix: "of \(goal)",
                empty: ""
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GroveTheme.secondarySurface,
            in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
        )
    }

    @ViewBuilder
    private func statColumn(label: String, value: Int?, suffix: String?, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GroveTheme.mutedInk)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            if let value {
                GroveRollingNumber(
                    value: value,
                    font: GroveTheme.display(32),
                    color: GroveTheme.ink,
                    suffix: suffix
                )
            } else {
                Text(empty)
                    .font(GroveTheme.display(22))
                    .foregroundStyle(GroveTheme.subtleInk)
                    .frame(height: 38, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenStat(label: label, value: value, suffix: suffix, empty: empty))
    }

    private func spokenStat(label: String, value: Int?, suffix: String?, empty: String) -> String {
        guard let value else { return "\(label): \(empty)" }
        return "\(label): \(value) \(suffix ?? "")"
    }

    // MARK: - Chart

    /// The health window the plot draws. A week of scores usually sits inside a
    /// few points, and a fixed 0–100 axis would flatten that into a straight
    /// line — so the window follows the data. It never narrows past 40 points
    /// and never leaves the real 0–100 scale, so a two-point wobble can't be
    /// staged as a collapse either.
    private var domain: (low: Int, high: Int) {
        let scores = scored.compactMap(\.averageScore)
        guard let smallest = scores.min(), let largest = scores.max() else { return (0, 100) }
        let span = min(100, max(40, largest - smallest + 12))
        var low = (largest + smallest) / 2 - span / 2
        low = max(0, min(low, 100 - span))
        return (low, low + span)
    }

    private func y(for score: Int) -> CGFloat {
        let window = domain
        let fraction = Double(score - window.low) / Double(window.high - window.low)
        let usable = Self.plotHeight - Self.calloutInset
        return Self.plotHeight - CGFloat(min(1, max(0, fraction))) * usable
    }

    private func x(forColumn index: Int, width: CGFloat) -> CGFloat {
        (CGFloat(index) + 0.5) * width / 7
    }

    /// One plotted reading: which column of the week it belongs to, and where
    /// that lands in the plot. The column travels with the point because the
    /// chart has to know which neighbours are *adjacent* days and which are
    /// separated by days nobody looked at.
    private struct Reading {
        let column: Int
        let point: CGPoint
    }

    private func readings(width: CGFloat) -> [Reading] {
        scored.compactMap { day in
            guard let score = day.averageScore else { return nil }
            return Reading(
                column: day.id,
                point: CGPoint(x: x(forColumn: day.id, width: width), y: y(for: score))
            )
        }
    }

    private var plot: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                gridlines
                curveCanvas
                latestCallout(width: width)
                lowLabel(width: width)
            }
            .frame(width: width, height: Self.plotHeight)
        }
        .frame(height: Self.plotHeight)
    }

    /// Two hairlines, at the top and bottom of the window the line is drawn in.
    /// They are the only chart furniture left: a ruled y axis with tick numbers
    /// was 22 points of column spent telling you what the callout already says
    /// out loud, and the footnote states the scale for anyone reading closely.
    private var gridlines: some View {
        VStack(spacing: 0) {
            Rectangle().fill(GroveTheme.separator).frame(height: 1)
            Spacer(minLength: 0)
            Rectangle().fill(GroveTheme.separator).frame(height: 1)
        }
        .padding(.top, Self.calloutInset)
        .frame(height: Self.plotHeight)
        .accessibilityHidden(true)
    }

    /// Area under the line, then the line itself.
    ///
    /// Both are drawn per *run* of consecutive days. A stretch of the week
    /// nobody looked at gets a faint straight bridge and no fill at all: the
    /// filled area means "this is what the grove was measuring", and there is
    /// nothing to measure across a hole in the record. Solid fill under a
    /// guess is the single most common way a chart lies.
    private var curveCanvas: some View {
        Canvas { context, size in
            let all = readings(width: size.width)
            guard !all.isEmpty else { return }

            var runs: [[CGPoint]] = []
            var current: [Reading] = []
            for entry in all {
                if let previous = current.last, entry.column - previous.column != 1 {
                    runs.append(current.map(\.point))
                    current = []
                }
                current.append(entry)
            }
            runs.append(current.map(\.point))

            // The bridges first, so the solid runs sit over their ends.
            for (before, after) in zip(runs, runs.dropFirst()) {
                guard let start = before.last, let end = after.first else { continue }
                var bridge = Path()
                bridge.move(to: start)
                bridge.addLine(to: end)
                context.stroke(
                    bridge,
                    with: .color(GroveTheme.accent.opacity(0.28)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 5])
                )
            }

            for run in runs where run.count > 1 {
                let line = curve(through: run)
                var area = line
                area.addLine(to: CGPoint(x: run[run.count - 1].x, y: size.height))
                area.addLine(to: CGPoint(x: run[0].x, y: size.height))
                area.closeSubpath()

                context.fill(
                    area,
                    with: .linearGradient(
                        Gradient(colors: [
                            GroveTheme.accent.opacity(0.30),
                            GroveTheme.accent.opacity(0.02)
                        ]),
                        startPoint: CGPoint(x: 0, y: Self.calloutInset),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
                context.stroke(
                    line,
                    with: .color(GroveTheme.accent),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
            }

            // Every reading keeps a dot, so the line is visibly built from days
            // rather than drawn through them. A calm week stays in one colour —
            // only a day that slipped out of healthy paints itself its own band,
            // so the exception catches the eye instead of every point competing.
            for reading in all {
                let band = scored.first { $0.id == reading.column }?.band
                let colour = band.map { $0.needsAttention ? $0.color : GroveTheme.accent }
                    ?? GroveTheme.accent
                let radius = reading.column == latest?.id ? Self.dotRadius + 1.5 : Self.dotRadius
                // The surface-coloured collar is what separates the dot from the
                // line running under it without drawing a second shape.
                context.fill(
                    disc(at: reading.point, radius: radius + 2.5),
                    with: .color(GroveTheme.surface)
                )
                context.fill(disc(at: reading.point, radius: radius), with: .color(colour))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func disc(at centre: CGPoint, radius: CGFloat) -> Path {
        Path(
            ellipseIn: CGRect(
                x: centre.x - radius,
                y: centre.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
    }

    /// Catmull-Rom through the readings, with every control point's *height*
    /// clamped to the two days it sits between.
    ///
    /// Smoothing a chart is normally how a chart starts lying: a curve that
    /// overshoots a peak draws a score nobody recorded. Clamping the vertical
    /// component means each drawn pixel stays inside the range of the two
    /// readings it joins, so the line can flow without ever claiming more than
    /// the record holds.
    private func curve(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }

        for index in 0..<(points.count - 1) {
            let before = points[max(0, index - 1)]
            let start = points[index]
            let end = points[index + 1]
            let after = points[min(points.count - 1, index + 2)]
            let lower = min(start.y, end.y)
            let upper = max(start.y, end.y)
            let control1 = CGPoint(
                x: start.x + (end.x - before.x) / 6,
                y: min(upper, max(lower, start.y + (end.y - before.y) / 6))
            )
            let control2 = CGPoint(
                x: end.x - (after.x - start.x) / 6,
                y: min(upper, max(lower, end.y - (after.y - start.y) / 6))
            )
            path.addCurve(to: end, control1: control1, control2: control2)
        }
        return path
    }

    /// The newest reading, called out where it happened: a thread dropped to
    /// the floor of the chart and the number set above the dot. Direct labelling
    /// beats a legend — the eye never has to leave the point to read its value.
    @ViewBuilder
    private func latestCallout(width: CGFloat) -> some View {
        if let latest, let score = latest.averageScore {
            let centre = CGPoint(x: x(forColumn: latest.id, width: width), y: y(for: score))
            let band = HealthBand(score: score)
            let colour = band.needsAttention ? band.color : GroveTheme.accent

            Path { path in
                path.move(to: CGPoint(x: centre.x, y: centre.y + Self.dotRadius + 4))
                path.addLine(to: CGPoint(x: centre.x, y: Self.plotHeight))
            }
            .stroke(colour.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .accessibilityHidden(true)

            Text("\(score)")
                .font(GroveTheme.display(24))
                .monospacedDigit()
                .foregroundStyle(GroveTheme.ink)
                .fixedSize()
                .position(x: calloutX(for: centre.x, width: width), y: centre.y - 26)
                .accessibilityLabel("Latest score \(score), \(band.title)")
        }
    }

    /// Keeps the callout inside the card when the newest reading lands in the
    /// first or last column — which, for the latest day of a week, is where it
    /// usually lands.
    private func calloutX(for pointX: CGFloat, width: CGFloat) -> CGFloat {
        let half = width / 7
        return min(max(pointX, half), width - half)
    }

    /// The week's low, labelled only when it is somewhere else and genuinely
    /// worth the ink. Two labels is a chart with a story; five is a table.
    @ViewBuilder
    private func lowLabel(width: CGFloat) -> some View {
        if let lowest, let low = lowest.averageScore, lowest.id != latest?.id,
           let last = latest?.averageScore,
           last - low >= 5 || HealthBand(score: low).needsAttention {
            Text("\(low)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize()
                .position(
                    x: calloutX(for: x(forColumn: lowest.id, width: width), width: width),
                    y: y(for: low) + Self.dotRadius + 13
                )
                .accessibilityHidden(true)
        }
    }

    // MARK: - Week axis

    /// The seven days as the chart's x axis: a marker on the plot's own column
    /// grid, the day's name underneath it.
    ///
    /// This used to be a row of filled and outlined capsules, and the capsules
    /// were the problem twice over. A pill is the shape Grove uses for things
    /// you tap, so a row of seven of them read as a segmented picker sitting
    /// under a chart rather than as part of it — and being its own component,
    /// it laid itself out on its own grid. The plot centres a column at
    /// `(i + 0.5) · width / 7`; the strip's inter-pill gaps pushed its cells
    /// off that by a few points each, so the labels were never quite under the
    /// readings they named. Zero spacing and equal widths put the two grids
    /// back on top of each other, and now `x(forColumn:)` addresses both.
    ///
    /// State moved off the label and onto the marker, which is the part that
    /// is actually data: a filled dot is a day you looked, a ring is today, a
    /// hairline dot is a day that passed or hasn't come. The names stay one
    /// quiet weight throughout, because axis furniture should not compete with
    /// the line it measures.
    ///
    /// The per-day reading *count* is deliberately not drawn. It is the one
    /// number here nobody acts on — "you looked twice on Tuesday" — and it
    /// survives in full in the day's accessibility label.
    private var weekAxis: some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                VStack(spacing: 8) {
                    marker(for: day)
                    Text(day.shortName)
                        .font(.caption2.weight(day.isToday ? .heavy : .semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(day.isToday ? GroveTheme.ink : GroveTheme.subtleInk)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(for: day))
            }
        }
    }

    /// One day's mark. Sized so a looked-in day reads as the same object as the
    /// dots on the line above it — the axis and the plot are drawing the same
    /// days, and should say so in the same vocabulary.
    @ViewBuilder
    private func marker(for day: CheckInDay) -> some View {
        ZStack {
            if day.isToday {
                Circle()
                    .stroke(GroveTheme.accent, lineWidth: 2)
                    .frame(width: 18, height: 18)
            }
            if day.isUnscored {
                // A look Grove could not score is drawn as the outline of the
                // day it would have been: same size, same colour, middle left
                // empty — because the middle is exactly what is missing.
                Circle()
                    .strokeBorder(GroveTheme.accent, lineWidth: 2)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(markerFill(for: day))
                    .frame(width: day.didCheckIn ? 9 : 5, height: day.didCheckIn ? 9 : 5)
            }
        }
        .frame(height: 18)
        .groveAnimation(GroveMotion.pop, value: day.didCheckIn)
    }

    private func markerFill(for day: CheckInDay) -> Color {
        if day.didCheckIn {
            // A day that slipped out of healthy paints itself its own band,
            // matching the plot's dots exactly; a calm week stays one colour.
            if let band = day.band, band.needsAttention { return band.color }
            return GroveTheme.accent
        }
        if day.isFuture { return GroveTheme.separator }
        return GroveTheme.subtleInk.opacity(0.45)
    }

    // MARK: - Footnote

    /// What the numbers above are made of, and what window the line is drawn
    /// in. The chart's window follows its data, so leaving the scale unsaid
    /// would let a four-point week look like a cliff.
    private var footnote: String? {
        guard !scored.isEmpty else {
            guard unscored == 0 else { return unscoredNote }
            return "Nothing scored yet this week. Check in on a plant to start the line."
        }
        let dayWord = scored.count == 1 ? "day" : "days"
        let range = domain
        let base = "Averaged across the \(scored.count) \(dayWord) with a scored check-in. Scale \(range.low)–\(range.high)."
        return unscored == 0 ? base : "\(base) \(unscoredNote)"
    }

    /// Days someone looked and Grove could not score. Named on the card rather
    /// than quietly dropped: a gardener who checked in every day this week and
    /// sees four points on the line deserves to know the other three are
    /// waiting on photo analysis, not missing because they didn't turn up.
    private var unscored: Int { days.filter(\.isUnscored).count }

    private var unscoredNote: String {
        unscored == 1
            ? "One check-in was saved without photo analysis and isn't scored yet."
            : "\(unscored) check-ins were saved without photo analysis and aren't scored yet."
    }

    // MARK: - Accessibility

    /// Every value the chart encodes visually is also spoken here, so the week
    /// axis doubles as the chart's table view.
    private func accessibilityLabel(for day: CheckInDay) -> String {
        let name = day.date.formatted(.dateTime.weekday(.wide))
        if day.isFuture { return "\(name), still to come" }
        guard day.didCheckIn else { return "\(name), no check-in" }
        let seen = day.plantsSeen == 1 ? "1 plant" : "\(day.plantsSeen) plants"
        guard let score = day.averageScore else { return "\(name), checked in on \(seen), not scored yet" }
        return "\(name), checked in on \(seen), average health \(score), \(HealthBand(score: score).title)"
    }
}

#Preview {
    ScrollView {
        CheckInHealthCard()
            .padding()
    }
    .groveBackground()
    .environment(GroveStore())
}
