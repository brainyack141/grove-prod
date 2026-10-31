import SwiftUI

// MARK: - The moment

/// What one qualifying look did to the streak.
///
/// Built by `GroveStore.recordTend` on the paths that actually move the number,
/// and kept as a value type so the copy that congratulates a gardener can be
/// tested without a view. `StreakSummary` describes where the run *stands*;
/// this describes what just *happened* to it, which is a different sentence.
struct StreakMoment: Equatable {
    /// The run length after this look.
    let day: Int
    /// The longest run before it. What makes "your best yet" a true claim.
    let previousBest: Int
    /// A banked shield covered yesterday to get here.
    let shieldSpent: Bool
    /// Shields this look actually banked — zero on every day but the seventh,
    /// and zero on a seventh day that finds the bank already full.
    let shieldsBanked: Int

    /// No run of this gardener's has ever gone further. True on a first-ever
    /// day one, which is the point: a first day is a record.
    var isPersonalBest: Bool { day > previousBest }

    /// Whether the day gets the full ray burst.
    ///
    /// Escalation is what keeps a celebration meaningful — if every day is
    /// confetti, none of it is. A record and a banked shield earn the light;
    /// an ordinary Tuesday gets the flame and nothing more.
    var isMilestone: Bool { shieldsBanked > 0 || isPersonalBest }

    /// The line under the flame. Names what happened, never the number — the
    /// number is already the largest thing on the screen.
    var headline: String {
        if shieldSpent { return "Streak saved" }
        if day == 1 { return previousBest == 0 ? "Your first day" : "Starting again" }
        if shieldsBanked > 0 { return "Shield earned" }
        if isPersonalBest { return "Your best streak yet" }
        return "Kept it going"
    }

    /// One sentence that ends on tomorrow. Every branch names the next move,
    /// because a streak screen that only reports a number leaves the reader to
    /// guess what keeps it — and Grove's answer (look at something, never
    /// water something) is not the one people assume.
    var note: String {
        if shieldSpent {
            return "A shield saved your streak yesterday. It's at \(day) days."
        }
        if shieldsBanked > 0 {
            return "Seven days in a row earns a shield. It saves your streak if you miss a day."
        }
        if day == 1 {
            return previousBest == 0
                ? "Checking in is what counts, not watering. Come back tomorrow to make it two."
                : "Your best streak was \(previousBest == 1 ? "1 day" : "\(previousBest) days"). Come back tomorrow to make this two."
        }
        if isPersonalBest {
            return "This is your longest streak yet. Come back tomorrow for \(day + 1)."
        }
        return "Come back tomorrow to make it \(day + 1)."
    }

    var accessibilityLabel: String {
        "\(headline). \(day) \(day == 1 ? "day" : "days"). \(note)"
    }
}

// MARK: - The flame

/// The shape every streak flame in Grove is cut from.
///
/// Drawn rather than shipped as an asset, and deliberately not `flame.fill`:
/// the system symbol is a glyph sized for a row, and this has to hold at 180 pt
/// as the only object on a takeover. The silhouette leans — the tip is pulled
/// left of centre and the left shoulder pinches in under it — so the flame has
/// a direction rather than being a symmetrical teardrop.
struct StreakFlameShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        // The tip sits left of centre, and both edges leave it curving. A tip
        // on the centre line with straight edges under it is a water drop; the
        // offset and the two curves are the whole difference.
        path.move(to: point(0.385, 0))
        // Right edge: rises close to the tip, then flares late and wide, which
        // is what makes the body read as heat climbing rather than a balloon.
        path.addCurve(to: point(0.965, 0.60), control1: point(0.455, 0.10), control2: point(0.985, 0.345))
        path.addCurve(to: point(0.50, 1), control1: point(0.955, 0.865), control2: point(0.775, 1))
        path.addCurve(to: point(0.035, 0.60), control1: point(0.225, 1), control2: point(0.045, 0.865))
        // Left edge: concave the whole way up. This is the lick.
        path.addCurve(to: point(0.385, 0), control1: point(0.055, 0.40), control2: point(0.145, 0.195))
        path.closeSubpath()
        return path
    }
}

/// The run length, burning.
///
/// Three layers make it: an outer body in the streak orange, a gold heart
/// mirrored inside it so the two tips lick in opposite directions, and the
/// numeral scorched into the heart. Each layer breathes on its own period —
/// 1.9 s, 1.35 s and 2.7 s — so the flicker never lands back on itself and
/// never reads as a loop.
struct StreakFlame: View {
    let day: Int
    var size: CGFloat = 178
    /// The full ray burst behind the body. Reserved for records and banked
    /// shields; an ordinary day gets the flame alone.
    var isMilestone: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0 → no flame at all, 1 → full body. Springs from the base, so the flame
    /// grows out of the ground instead of inflating in mid-air.
    @State private var lit: CGFloat = 0
    /// Where the numeral starts. Held at 2.3 rather than higher: the glyph is
    /// not clipped on the way in, so a larger multiple simply runs off both
    /// edges of the narrowest phone before it lands.
    @State private var numeralScale: CGFloat = 2.3
    @State private var numeralOpacity: Double = 0
    @State private var isHot = false
    @State private var burst: Double = 0
    @State private var breathA: CGFloat = 0
    @State private var breathB: CGFloat = 0
    @State private var sway: CGFloat = 0
    /// When the flame caught, which is the clock the embers run on.
    @State private var ignitedAt: Date?

    private var height: CGFloat { size * 1.16 }
    /// Room around the body for the embers and the burst to live in. Held under
    /// two full widths so the frame still fits inside a page's own margins on
    /// the narrowest phone.
    private var canvasSize: CGFloat { size * 1.9 }

    var body: some View {
        ZStack {
            if isMilestone {
                BadgeRayBurst(tint: GroveTheme.gold, diameter: canvasSize * 0.95, progress: burst)
                    .opacity(burst * 0.9)
            }

            if let ignitedAt {
                StreakEmbers(ignitedAt: ignitedAt, extent: canvasSize / 2, isMilestone: isMilestone)
                    .frame(width: canvasSize, height: canvasSize)
            }

            ZStack {
                outerBody
                innerHeart
            }
            .frame(width: size, height: height)
            // The flame alone grows out of the ground; the numeral has already
            // landed and must not be dragged up with it.
            .scaleEffect(x: 1, y: lit, anchor: .bottom)
            .opacity(lit > 0.02 ? 1 : 0)

            numeral
        }
        .frame(width: canvasSize, height: canvasSize)
        .task { await light() }
        .accessibilityHidden(true)
    }

    // MARK: Layers

    private var outerBody: some View {
        // Typed locals keep the modifier chain cheap to type-check; inline,
        // Xcode 26's solver times out on this expression (CI, Oct 2026).
        let scaleX: CGFloat = 1 + breathA * 0.024
        let scaleY: CGFloat = 1 - breathA * 0.02
        let tilt: Double = Double(sway) * 1.7
        let glowRadius: CGFloat = size * 0.16
        let glowY: CGFloat = size * 0.05
        return StreakFlameShape()
            .fill(
                LinearGradient(
                    colors: [GroveTheme.streak, GroveTheme.ember],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size, height: height)
            .scaleEffect(x: scaleX, y: scaleY, anchor: .bottom)
            .rotationEffect(.degrees(tilt), anchor: .bottom)
            .shadow(color: GroveTheme.ember.opacity(0.28), radius: glowRadius, y: glowY)
    }

    /// Mirrored, so its tip licks against the body's lean instead of tracing
    /// it. Anchored to the base and squatter than the shell, because the hot
    /// part of a flame sits low.
    private var innerHeart: some View {
        let heartWidth: CGFloat = size * 0.58
        let heartHeight: CGFloat = height * 0.60
        let heartX: CGFloat = 1 - breathB * 0.03
        let heartY: CGFloat = 1 + breathB * 0.045
        let heartOffset: CGFloat = height * 0.145
        return StreakFlameShape()
            .fill(
                LinearGradient(
                    colors: [GroveTheme.gold, GroveTheme.goldDeep],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: heartWidth, height: heartHeight)
            .scaleEffect(x: -1)
            .scaleEffect(x: heartX, y: heartY, anchor: .bottom)
            // Held clear of the shell's base: flush, the heart's rounder bottom
            // pokes straight through the body it is supposed to sit inside.
            .offset(y: heartOffset)
    }

    /// Shrinks a step per digit, so a hundred-day run still sits inside the
    /// gold heart. Left at one size, "128" spills onto the orange shell and the
    /// milestone anyone would most want to screenshot is the one that looks
    /// broken.
    private var numeralSize: CGFloat {
        switch day {
        case ..<10: size * 0.44
        case ..<100: size * 0.38
        default: size * 0.30
        }
    }

    private var numeral: some View {
        Text("\(day)")
            .font(GroveTheme.display(numeralSize, weight: .heavy))
            .monospacedDigit()
            .foregroundStyle(isHot ? GroveTheme.emberInk : GroveTheme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.45)
            .frame(width: size * 0.78)
            .scaleEffect(numeralScale)
            .opacity(numeralOpacity)
            .offset(y: height * 0.13)
    }

    // MARK: Motion

    /// The whole moment, in three beats: the numeral lands, the flame catches
    /// around it, then the flicker takes over and never stops.
    private func light() async {
        guard !reduceMotion else {
            lit = 1
            numeralScale = 1
            numeralOpacity = 1
            isHot = true
            burst = 1
            Haptics.celebrate()
            return
        }

        // Near-linear, then a hard brake. An ease-out spends its speed
        // immediately and reads as a number that was dropped rather than
        // one that was thrown.
        withAnimation(.timingCurve(0.18, 0.42, 0.12, 1, duration: 0.6)) {
            numeralScale = 1
            numeralOpacity = 1
        }
        Haptics.climb(steps: min(day, 4))

        try? await Task.sleep(for: .seconds(0.36))
        guard !Task.isCancelled else { return }

        Haptics.streak()
        ignitedAt = .now
        withAnimation(.spring(response: 0.52, dampingFraction: 0.58)) { lit = 1 }
        withAnimation(.easeOut(duration: 0.3)) { isHot = true }
        withAnimation(.easeOut(duration: 0.7)) { burst = 1 }

        // Mutually indivisible periods: the three layers drift apart and never
        // come back into phase, so the flame stays alive on a screen someone
        // might sit on for a while.
        withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) { breathA = 1 }
        withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) { breathB = 1 }
        withAnimation(.easeInOut(duration: 2.7).repeatForever(autoreverses: true)) { sway = 1 }
    }
}

// MARK: - Embers

/// The sparks the flame throws.
///
/// One `Canvas` on one clock does both jobs: a ring that bursts outward at the
/// instant of ignition and dies, and a handful that keep rising off the
/// shoulders for as long as anyone is watching. Deriving both from elapsed time
/// rather than from animated state means the two are locked to the same moment
/// and neither can drift out of step with the flame.
private struct StreakEmbers: View {
    let ignitedAt: Date
    let extent: CGFloat
    let isMilestone: Bool

    private var burstCount: Int { isMilestone ? 18 : 12 }
    private let riseCount = 5
    /// How long one ember takes to rise and go out.
    private let risePeriod: Double = 2.9

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(ignitedAt)
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                drawBurst(in: context, centre: centre, elapsed: elapsed)
                drawRising(in: context, centre: centre, elapsed: elapsed)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawBurst(in context: GraphicsContext, centre: CGPoint, elapsed: Double) {
        let progress = min(1, max(0, elapsed / 0.78))
        guard progress < 1 else { return }
        // Cubic ease-out: embers leave fast and coast, the way thrown sparks do.
        let eased = 1 - pow(1 - progress, 3)

        for index in 0..<burstCount {
            let jitter = Self.noise(index)
            let heading = (Double(index) / Double(burstCount)) * 2 * .pi + jitter * 0.35
            // Starts inside the body and has to end well outside it. The flame
            // fills a little over half this frame, so a burst that peaked at
            // half the extent would spend its whole life behind the thing it
            // was supposed to be thrown from.
            let reach = extent * (0.55 + jitter * 0.30) * (0.35 + 0.65 * eased)
            // A short bright rise, then a long fade — an ember is at its
            // brightest the moment it leaves.
            let alpha = progress < 0.12 ? progress / 0.12 : 1 - (progress - 0.12) / 0.88
            let radius = extent * (0.030 - 0.014 * progress) * (0.7 + jitter * 0.6)

            let dot = Path(
                ellipseIn: CGRect(
                    x: centre.x + cos(heading) * reach - radius,
                    // Sparks are lifted as they travel; a flat ring reads as a
                    // firework rather than as fire.
                    y: centre.y + sin(heading) * reach - radius - extent * 0.14 * eased,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            // Two temperatures, so the ring is not one colour of confetti.
            let tint = index.isMultiple(of: 2) ? GroveTheme.streak : GroveTheme.gold
            context.fill(dot, with: .color(tint.opacity(alpha * 0.95)))
        }
    }

    private func drawRising(in context: GraphicsContext, centre: CGPoint, elapsed: Double) {
        guard elapsed > 0.5 else { return }
        // Held back until the burst has cleared, then faded in over a second,
        // so the two never overlap into a haze.
        let settle = min(1, (elapsed - 0.5) / 1.0)

        for index in 0..<riseCount {
            let jitter = Self.noise(index + 41)
            let phase = ((elapsed / risePeriod) + jitter).truncatingRemainder(dividingBy: 1)
            // Off the shoulders, not out of the middle: an ember rising up the
            // centre line is behind the flame for four fifths of its life and
            // only appears at the top, which reads as a glitch rather than as
            // fire. These start outside the silhouette and stay outside it.
            let side: CGFloat = index.isMultiple(of: 2) ? -1 : 1
            let lift = extent * (0.20 - 1.05 * phase)
            let drift = sin(phase * 3.4 + Double(index)) * extent * 0.05
            let radius = extent * (0.016 + jitter * 0.012) * (1 - phase * 0.5)
            // In and out on a sine, so nothing pops on or cuts off.
            let alpha = sin(phase * .pi) * 0.8 * settle

            let dot = Path(
                ellipseIn: CGRect(
                    x: centre.x + side * extent * (0.56 + jitter * 0.16) + drift - radius,
                    y: centre.y + lift - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            context.fill(dot, with: .color(GroveTheme.gold.opacity(alpha)))
        }
    }

    /// A stable 0…1 per index. Hand-rolled rather than `random`, because the
    /// canvas redraws every frame and a fresh roll each time would make the
    /// embers boil in place instead of travelling.
    private static func noise(_ index: Int) -> Double {
        let value = sin(Double(index) * 12.9898) * 43758.5453
        return value - value.rounded(.down)
    }
}

// MARK: - The week

/// Seven days as a shape rather than a number — which is the difference
/// between "6" and seeing the gap you left on Thursday.
///
/// Shared by the streak sheet and the celebration so the row a gardener sees
/// the moment they earn a day is the same row they find when they go looking
/// for it later.
struct StreakWeekRow: View {
    let week: [StreakSummary.DayMark]
    /// Plays today's pip in — the fill, then the tick — a beat after the row
    /// lands. Only the celebration asks for it.
    var celebratesToday: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fill: CGFloat = 0
    @State private var tick: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(week) { day in
                VStack(spacing: 8) {
                    dot(day)
                    Text(day.initial)
                        .font(.caption2.weight(day.isToday ? .heavy : .semibold))
                        .foregroundStyle(day.isToday ? GroveTheme.ink : GroveTheme.subtleInk)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .task { await landToday() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func dot(_ day: StreakSummary.DayMark) -> some View {
        let isCelebrated = celebratesToday && day.isToday

        ZStack {
            switch day.state {
            case .kept:
                Circle()
                    .fill(GroveTheme.streak)
                    .scaleEffect(isCelebrated ? fill : 1)
                if isCelebrated {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(GroveTheme.onAccent)
                        .scaleEffect(tick)
                        .opacity(tick)
                }
            case .shielded:
                Circle().fill(GroveTheme.goldDeep)
                Image(systemName: "shield.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GroveTheme.onAccent)
            case .pending:
                Circle()
                    .strokeBorder(
                        GroveTheme.streak.opacity(0.55),
                        style: StrokeStyle(lineWidth: 2, dash: [3, 3])
                    )
            case .missed:
                Circle().fill(GroveTheme.separator)
            }
        }
        .frame(width: 30, height: 30)
        // The empty ring today's fill grows inside, so the pip has a place to
        // land rather than appearing out of nothing.
        .background {
            if isCelebrated {
                Circle().strokeBorder(GroveTheme.separator, lineWidth: 2)
            }
        }
    }

    private func landToday() async {
        guard celebratesToday else { return }
        guard !reduceMotion else {
            fill = 1
            tick = 1
            return
        }
        try? await Task.sleep(for: .seconds(0.62))
        guard !Task.isCancelled else { return }
        withAnimation(GroveMotion.pop) { fill = 1 }
        try? await Task.sleep(for: .seconds(0.13))
        guard !Task.isCancelled else { return }
        Haptics.tap()
        withAnimation(GroveMotion.pop) { tick = 1 }
    }

    private var accessibilityLabel: String {
        let kept = week.filter { $0.state == .kept }.count
        let today = week.last?.state
        let todayLine = switch today {
        case .kept: "Today's done."
        case .shielded: "A shield saved today."
        default: "Today isn't done yet."
        }
        return "Last seven days: \(kept) kept. \(todayLine)"
    }
}

// MARK: - The takeover

/// The moment the streak moves.
///
/// Before this, advancing the streak did nothing anyone could see or feel —
/// `Haptics.streak()` had been written and never called, and the number simply
/// differed the next time you happened to look at Today. The daily loop Grove
/// asks for had no payoff at the end of it.
///
/// It deliberately looks like neither of the other two takeovers. A badge is an
/// object handed over in a dark room; a level-up is a promotion on full green.
/// This one stays on Grove's own cream ground, because the flame has to be the
/// only source of light on the screen for the warmth to read at all.
struct StreakCelebrationOverlay: View {
    let moment: StreakMoment
    let week: [StreakSummary.DayMark]
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        ZStack {
            // The app's own ground, atmosphere and all, so the takeover reads
            // as Grove at this hour rather than as a screen borrowed from
            // somewhere else.
            Color.clear.groveBackground().ignoresSafeArea()

            // The light the flame is casting, not decoration: it is centred on
            // the body, warm, and weak enough that the copy under it keeps its
            // contrast on the canvas.
            RadialGradient(
                colors: [GroveTheme.streak.opacity(0.20), GroveTheme.gold.opacity(0.07), .clear],
                center: UnitPoint(x: 0.5, y: 0.34),
                startRadius: 8,
                endRadius: 400
            )
            .ignoresSafeArea()
            .opacity(revealed ? 1 : 0)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                StreakFlame(day: moment.day, isMilestone: moment.isMilestone)
                    // The flame is drawn into a frame nearly twice its own
                    // width so the embers have room. Pulling the vertical
                    // surplus back out keeps the copy where the layout put it.
                    .padding(.vertical, -64)

                GroveDisplayHeading(text: moment.headline, style: .heading)
                    .multilineTextAlignment(.center)
                    .padding(.top, 30)
                    .modifier(Rise(revealed: revealed))

                StreakWeekRow(week: week, celebratesToday: true)
                    .padding(.top, 22)
                    .padding(.horizontal, 6)
                    .modifier(Rise(revealed: revealed, delay: GroveFeel.stagger))

                Text(moment.note)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
                    .padding(.top, 20)
                    .modifier(Rise(revealed: revealed, delay: GroveFeel.stagger * 2))

                // Capped, where the spacer above it is not: split evenly, a
                // tall phone puts a hand's width of empty canvas between the
                // last line of copy and the button, and the screen reads as two
                // unrelated halves. The flame group falls where the eye lands.
                Spacer(minLength: 24).frame(maxHeight: 96)

                Button(action: onDismiss) {
                    GroveCTALabel(title: "Back to my grove")
                }
                .buttonStyle(GrovePressStyle())
                .padding(.horizontal, 32)
                .padding(.bottom, 10)
                .modifier(Rise(revealed: revealed, delay: GroveFeel.stagger * 3))
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.vertical, 24)
        }
        .onAppear {
            guard !reduceMotion else {
                revealed = true
                return
            }
            // Held until the flame has caught: the supporting copy arriving
            // during the ignition would split the eye at the one instant the
            // screen is asking for it.
            withAnimation(GroveMotion.reveal.delay(0.46)) { revealed = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(moment.accessibilityLabel)
    }

    /// The house entrance, with a per-element delay: fades up 16 pt into place.
    private struct Rise: ViewModifier {
        let revealed: Bool
        var delay: Double = 0

        func body(content: Content) -> some View {
            content
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : GroveFeel.revealOffset)
                .animation(GroveMotion.reveal.delay(0.46 + delay), value: revealed)
        }
    }
}

// MARK: - Previews

private func previewWeek(kept: Int) -> [StreakSummary.DayMark] {
    let calendar = Calendar.current
    return (0..<7).compactMap { offset in
        guard let date = calendar.date(byAdding: .day, value: offset - 6, to: .now) else { return nil }
        return StreakSummary.DayMark(
            id: offset,
            date: date,
            initial: String(calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: date) - 1]),
            state: offset >= 7 - kept ? .kept : .missed,
            isToday: offset == 6
        )
    }
}

#Preview("Ordinary day") {
    StreakCelebrationOverlay(
        moment: StreakMoment(day: 6, previousBest: 21, shieldSpent: false, shieldsBanked: 0),
        week: previewWeek(kept: 6),
        onDismiss: {}
    )
}

#Preview("Shield earned") {
    StreakCelebrationOverlay(
        moment: StreakMoment(day: 7, previousBest: 21, shieldSpent: false, shieldsBanked: 1),
        week: previewWeek(kept: 7),
        onDismiss: {}
    )
}

#Preview("First day") {
    StreakCelebrationOverlay(
        moment: StreakMoment(day: 1, previousBest: 0, shieldSpent: false, shieldsBanked: 0),
        week: previewWeek(kept: 1),
        onDismiss: {}
    )
}

#Preview("Streak saved") {
    StreakCelebrationOverlay(
        moment: StreakMoment(day: 12, previousBest: 30, shieldSpent: true, shieldsBanked: 0),
        week: previewWeek(kept: 3),
        onDismiss: {}
    )
}
