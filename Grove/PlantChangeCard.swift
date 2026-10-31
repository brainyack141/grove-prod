import SwiftUI
import UIKit

// MARK: - Model

/// What changed for one plant, read straight out of its own record.
///
/// The plant page used to answer this in three places that never spoke to each
/// other: "Then and now" showed two photographs and said nothing about why they
/// differed, "Check-in history" listed scores with no pictures and no care, and
/// "Care you've logged" listed care with no outcome. So the one question a
/// returning owner actually has — *is what I'm doing working?* — was the one
/// question the page had no block for, even though it held every fact needed to
/// answer it.
///
/// This is that answer as a single chronology: the photographic change, every
/// event that sits inside it, and — only when the record genuinely shows one —
/// a care action a better reading followed. Deliberately a *pattern*: Grove has
/// two dates and two numbers, which is not proof of a cause, and the card says
/// so in the same breath it makes the claim.
struct PlantChangeStory: Equatable {
    /// The two photographs the card wipes between.
    struct Comparison: Equatable {
        let beforeURL: URL
        let beforeDate: Date
        let nowURL: URL
        let nowDate: Date
    }

    /// One thing that happened, whether Grove read it or the owner did it.
    struct Moment: Identifiable, Equatable {
        enum Kind: Equatable {
            case checkIn(delta: Int, band: HealthBand, isEstimated: Bool)
            case care(CareKind)
        }

        let id: UUID
        let date: Date
        let kind: Kind
        let headline: String
        let detail: String?
        /// The check-in photograph, when there is one. Care has no photo and
        /// draws its own artwork instead.
        let photoURL: URL?
        let hasNewGrowth: Bool
    }

    /// A care action that a better reading followed. Never a cause — see the
    /// type's own note, and the qualifying line the card prints underneath it.
    struct Pattern: Equatable {
        let careKind: CareKind
        let careDate: Date
        let checkInDate: Date
        /// How many points the reading rose. Always positive.
        let delta: Int
        let broughtNewGrowth: Bool

        var gapInDays: Int {
            let calendar = Calendar.current
            return calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: careDate),
                to: calendar.startOfDay(for: checkInDate)
            ).day ?? 0
        }

        var gapPhrase: String { Self.gapPhrase(days: gapInDays) }

        /// Spelled out to about a week, because "2 days later" in the middle of
        /// a sentence reads as data and this is meant to read as a sentence.
        static func gapPhrase(days: Int) -> String {
            switch days {
            case ..<1: "the same day"
            case 1: "the next day"
            case 2: "two days later"
            case 3: "three days later"
            case 4: "four days later"
            case 5: "five days later"
            case 6: "six days later"
            case 7...10: "a week later"
            case 11...17: "a fortnight later"
            default: "\(days / 7) weeks later"
            }
        }
    }

    let comparison: Comparison?
    let moments: [Moment]
    let pattern: Pattern?

    /// One event and no photographs to compare is not a story about change, and
    /// a card that says so anyway is a card the user learns to scroll past.
    var isWorthShowing: Bool { comparison != nil || moments.count >= 2 }

    // MARK: Derivation

    /// How far back the timeline reaches. Six covers roughly three weeks of a
    /// weekly check-in with watering in between, which is the span over which a
    /// houseplant visibly answers back.
    static let momentLimit = 6

    /// How many check-ins keep their seat however much care is logged around
    /// them. An anxious week — five waterings and a soil check — is exactly the
    /// week that would otherwise fill the timeline with errands and push every
    /// reading off the card whose entire subject is the readings.
    static let guaranteedCheckIns = 3

    /// How long after a care action a check-in can still be read as following
    /// it. Three weeks is generous for watering and about right for a
    /// treatment; past that the two facts are simply both true.
    static let patternWindowDays = 21

    /// The smallest rise worth calling a rise. Assessments of the same plant a
    /// week apart wander by a point or two, and a card that celebrates +1 is a
    /// card that celebrates noise.
    static let meaningfulRise = 3

    /// - Parameters:
    ///   - observations: the plant's check-ins, any order.
    ///   - care: the plant's care tasks, any order. Anything incomplete, or a
    ///     check-in task, is ignored — the check-in itself already arrives as an
    ///     observation, and counting it twice would draw every check-in on the
    ///     timeline as both a reading and an errand.
    static func make(observations: [PlantObservation], care: [CareTask]) -> PlantChangeStory {
        let checkIns = observations.sorted { $0.createdAt > $1.createdAt }
        let actions = care
            .filter { $0.isCompleted && $0.kind != .checkIn }
            .sorted { $0.dueDate > $1.dueDate }

        let moments = merged(
            checkIns: checkIns.map(Moment.init(checkIn:)),
            care: actions.map(Moment.init(care:))
        )
        let windowStart = moments.last?.date ?? .distantPast

        return PlantChangeStory(
            comparison: comparison(from: checkIns, since: windowStart),
            moments: moments,
            pattern: pattern(checkIns: checkIns, actions: actions, since: windowStart)
        )
    }

    /// The newest `momentLimit` events, except that the newest
    /// `guaranteedCheckIns` readings are seated before care competes for what's
    /// left.
    private static func merged(checkIns: [Moment], care: [Moment]) -> [Moment] {
        let newestFirst = { (lhs: Moment, rhs: Moment) in lhs.date > rhs.date }
        let anchored = Array(checkIns.prefix(guaranteedCheckIns))
        let rest = (Array(checkIns.dropFirst(guaranteedCheckIns)) + care).sorted(by: newestFirst)
        let filled = anchored + rest.prefix(max(0, momentLimit - anchored.count))
        return filled.sorted(by: newestFirst)
    }

    /// The widest honest pair on screen: today's photograph against the oldest
    /// one the timeline still reaches.
    ///
    /// Comparing the newest two check-ins — which is what "Then and now" did —
    /// puts a week between the halves, and a week is nothing to a plant. The
    /// wipe only earns its place when there is something to see, and both dates
    /// are printed on the frame so a wide span can never read as a recent one.
    private static func comparison(from checkIns: [PlantObservation], since windowStart: Date) -> Comparison? {
        let photos = checkIns.filter { $0.photoURL != nil }
        guard photos.count >= 2,
              let newest = photos.first,
              let nowURL = newest.photoURL
        else { return nil }

        // `photos` runs newest → oldest, so the last one still inside the
        // window is the oldest one the timeline shows. If the window holds only
        // today's photo, fall back to the one immediately before it rather than
        // dropping the comparison.
        let earlier = photos.dropFirst().last { $0.createdAt >= windowStart } ?? photos[1]
        guard let beforeURL = earlier.photoURL else { return nil }

        return Comparison(
            beforeURL: beforeURL,
            beforeDate: earlier.createdAt,
            nowURL: nowURL,
            nowDate: newest.createdAt
        )
    }

    /// The newest real rise on the timeline that has a care action behind it.
    ///
    /// Three refusals are load-bearing. An estimated check-in is arithmetic on
    /// the owner's own three answers and cannot corroborate anything, so it is
    /// never the evidence. The check-in has to be one the timeline is already
    /// showing, so the card can never point at a recovery from last spring
    /// while the visible history declines. And the action has to precede the
    /// reading, which sounds obvious and is exactly what a naïve "latest care +
    /// latest score" pairing gets wrong.
    private static func pattern(
        checkIns: [PlantObservation],
        actions: [CareTask],
        since windowStart: Date
    ) -> Pattern? {
        for observation in checkIns where observation.createdAt >= windowStart {
            guard !observation.isEstimated else { continue }
            let delta = observation.score - observation.previousScore
            guard delta >= meaningfulRise else { continue }
            guard let earliest = Calendar.current.date(
                byAdding: .day,
                value: -patternWindowDays,
                to: observation.createdAt
            ) else { continue }
            // `actions` runs newest first, so this is the last thing done
            // before the reading.
            guard let action = actions.first(where: {
                $0.dueDate <= observation.createdAt && $0.dueDate >= earliest
            }) else { continue }

            return Pattern(
                careKind: action.kind,
                careDate: action.dueDate,
                checkInDate: observation.createdAt,
                delta: delta,
                broughtNewGrowth: observation.hasNewGrowth
            )
        }
        return nil
    }
}

// MARK: - Moment copy

extension PlantChangeStory.Moment {
    init(checkIn observation: PlantObservation) {
        let growth = observation.hasNewGrowth
        let headline: String = switch (growth, observation.appearance) {
        case (true, .better): "New growth, and looking better"
        case (true, _): "New growth"
        case (false, .better): "Looking better"
        case (false, .worse): "Looking worse"
        case (false, .same): "Holding steady"
        }

        var detail = "Soil \(observation.soilMoisture.title.lowercased())"
        if observation.actorName != "You", !observation.actorName.isEmpty {
            detail += " · \(observation.actorName)"
        }
        // An estimated check-in never looked at the photograph. It belongs in the
        // record, but it must not sit here wearing the same clothes as a
        // reading that did.
        if observation.isEstimated { detail += " · saved without photo analysis" }
        let note = observation.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { detail += " · \(note)" }

        self.init(
            id: observation.id,
            date: observation.createdAt,
            kind: .checkIn(
                delta: observation.score - observation.previousScore,
                band: observation.band,
                isEstimated: observation.isEstimated
            ),
            headline: headline,
            detail: detail,
            photoURL: observation.photoURL,
            hasNewGrowth: growth
        )
    }

    init(care task: CareTask) {
        let note = task.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            id: task.id,
            date: task.dueDate,
            kind: .care(task.kind),
            headline: task.kind.timelineTitle,
            // The boilerplate that stands in for an empty note says nothing a
            // dated row hasn't already said.
            detail: note.isEmpty || note == GroveStore.selfLoggedCareDetail ? nil : note,
            photoURL: nil,
            hasNewGrowth: false
        )
    }
}

extension CareKind {
    /// The action named as a thing that happened on a date.
    ///
    /// `logTitle` is written for a picker the user is about to tap ("Rotated"),
    /// which is thin as a line of history — it never says what was rotated or
    /// why anyone would.
    var timelineTitle: String {
        switch self {
        case .checkIn: "Checked in"
        case .inspectSoil: "Felt the soil"
        case .water: "Watered"
        case .fertilise: "Fertilised"
        case .rotate: "Turned the pot"
        case .cleanLeaves: "Cleaned the leaves"
        case .treat: "Treated"
        case .prune: "Trimmed what was damaged"
        case .repot: "Repotted"
        case .relocate: "Moved to a new spot"
        case .monitor: "Checked for change"
        }
    }

    /// The same action inside a sentence: "You turned the pot on 12 May."
    var pastPhrase: String {
        switch self {
        case .checkIn: "checked in"
        case .inspectSoil: "felt the soil"
        case .water: "watered it"
        case .fertilise: "fertilised it"
        case .rotate: "turned the pot"
        case .cleanLeaves: "cleaned the leaves"
        case .treat: "treated it"
        case .prune: "trimmed it back"
        case .repot: "repotted it"
        case .relocate: "moved it"
        case .monitor: "checked its progress"
        }
    }

    /// Artwork names live in the presentation layer so `CareKind` stays a plain
    /// domain model and the icon family can evolve without touching stored data.
    var loggedCareArtworkName: String {
        switch self {
        case .checkIn: "ProfileCareHistory"
        case .inspectSoil: "CareIconSoil"
        case .water: "CareIconWater"
        case .fertilise: "ProfileCareHistory"
        case .rotate: "CareIconRotate"
        case .cleanLeaves: "ProfileCareHistory"
        case .treat: "CareIconTreat"
        case .prune: "CareIconPrune"
        case .repot, .relocate, .monitor: "ProfileCareHistory"
        }
    }
}

// MARK: - Card

/// The plant page's record of change: a wipe between two dated photographs, the
/// chronology underneath it, and what the record shows moved it.
struct PlantChangeCard: View {
    let plant: Plant
    let story: PlantChangeStory

    var body: some View {
        PlantSection(title: "What changed", icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 20) {
                if let comparison = story.comparison {
                    ObservationPhotoComparison(comparison: comparison)
                }

                if !story.moments.isEmpty {
                    PlantChangeTimeline(moments: story.moments)
                }

                if let pattern = story.pattern {
                    PlantChangePattern(pattern: pattern, nickname: plant.nickname)
                }
            }
        }
    }
}

// MARK: - Timeline

private struct PlantChangeTimeline: View {
    let moments: [PlantChangeStory.Moment]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(moments.enumerated()), id: \.element.id) { index, moment in
                row(moment, isFirst: index == 0, isLast: index == moments.count - 1)
            }
        }
    }

    private func row(_ moment: PlantChangeStory.Moment, isFirst: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rail(tint: tint(for: moment), isFirst: isFirst, isLast: isLast)

            marker(moment)

            VStack(alignment: .leading, spacing: 3) {
                Text(dateLabel(moment.date))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(GroveTheme.subtleInk)
                    .monospacedDigit()

                Text(moment.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = moment.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 1)

            Spacer(minLength: 6)

            // Movement, not the absolute score: the number itself is already
            // the largest thing on this page, forty lines up.
            if case .checkIn(let delta, _, let isEstimated) = moment.kind,
               delta != 0,
               !isEstimated,
               dynamicTypeSize < .accessibility1 {
                Text(delta > 0 ? "+\(delta)" : "\(delta)")
                    .font(.caption.weight(.heavy))
                    .monospacedDigit()
                    .foregroundStyle(delta > 0 ? GroveTheme.accentStrong : GroveTheme.warning)
                    .padding(.top, 14)
            }
        }
        .padding(.bottom, isLast ? 0 : 14)
        .accessibilityElement(children: .ignore)
        // Spoken rather than combined, because the delta chip is dropped at
        // accessibility text sizes to keep the row readable — and a sighted
        // reader losing a decoration is very different from a VoiceOver reader
        // losing the only statement of which way the plant moved.
        .accessibilityLabel(accessibilityLabel(for: moment))
    }

    private func accessibilityLabel(for moment: PlantChangeStory.Moment) -> String {
        var parts = [dateLabel(moment.date), moment.headline]
        if let detail = moment.detail { parts.append(detail) }
        if case .checkIn(let delta, _, let isEstimated) = moment.kind, delta != 0, !isEstimated {
            parts.append("Health \(delta > 0 ? "up" : "down") \(abs(delta)) points")
        }
        return parts.joined(separator: ". ")
    }

    /// The chronological spine. The stub above the first dot is clear, so the
    /// line starts at the first event rather than running out of the header.
    private func rail(tint: Color, isFirst: Bool, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isFirst ? Color.clear : GroveTheme.separator)
                .frame(width: 1, height: 16)

            ZStack {
                Circle()
                    .stroke(tint.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 15, height: 15)
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
            }

            Rectangle()
                .fill(isLast ? Color.clear : GroveTheme.separator)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 15)
        .frame(maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func marker(_ moment: PlantChangeStory.Moment) -> some View {
        switch moment.kind {
        case .checkIn:
            ObservationThumbnail(url: moment.photoURL)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if moment.hasNewGrowth {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(GroveTheme.onAccent)
                            .padding(3)
                            .background(GroveTheme.accent, in: Circle())
                            .overlay(Circle().stroke(GroveTheme.surface, lineWidth: 1.5))
                            .offset(x: 4, y: 4)
                    }
                }
                .accessibilityHidden(true)
        case .care(let kind):
            Image(kind.loggedCareArtworkName)
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)
                .accessibilityHidden(true)
        }
    }

    private func tint(for moment: PlantChangeStory.Moment) -> Color {
        switch moment.kind {
        case .checkIn(_, let band, let isEstimated):
            isEstimated ? GroveTheme.subtleInk : band.color
        case .care(let kind):
            kind == .water || kind == .inspectSoil ? GroveTheme.hydration : GroveTheme.accent
        }
    }

    private func dateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - What helped

/// The one sentence this card exists for, and the limit printed under it.
///
/// Grove has two dates and two numbers here. That is enough to say what
/// happened in what order and nothing like enough to say one caused the other,
/// so the qualifier is not a disclaimer bolted on afterwards — it is the second
/// half of the claim, and it goes in the same block at the same weight as the
/// first.
private struct PlantChangePattern: View {
    let pattern: PlantChangeStory.Pattern
    let nickname: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "leaf.fill")
                .font(.footnote.weight(.black))
                .foregroundStyle(GroveTheme.accent)
                .frame(width: 34, height: 34)
                .background(GroveTheme.surface, in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text("What helped")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.ink)

                Text(sentence)
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text("That's the order it happened in, from your own check-ins. It doesn't prove one caused the other.")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GroveTheme.softAccent, in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var sentence: String {
        let date = pattern.careDate.formatted(.dateTime.day().month(.abbreviated))
        let rise = "read \(pattern.delta) points higher"
        let growth = pattern.broughtNewGrowth ? ", with new growth" : ""
        return "You \(pattern.careKind.pastPhrase) on \(date). \(nickname)'s next check-in, \(pattern.gapPhrase), \(rise)\(growth)."
    }
}

// MARK: - Photo comparison

/// A wipe between two dated photographs of the same plant.
///
/// The dates ride on the frame rather than under it: a label parked below a
/// before/after belongs to neither half, and the moment you drag the edge you
/// are looking at a photograph whose caption is somewhere else. Each chip
/// stands over the half it names and fades out when the wipe swallows it.
struct ObservationPhotoComparison: View {
    let comparison: PlantChangeStory.Comparison

    @State private var reveal = 0.5
    /// Where the wipe sat when the current drag began, so the handle moves with
    /// the finger instead of jumping to it.
    @State private var dragAnchor: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                ObservationThumbnail(url: comparison.nowURL)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                ObservationThumbnail(url: comparison.beforeURL)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: proxy.size.width * reveal)
                    }

                stamp(eyebrow: "Before", date: comparison.beforeDate)
                    .opacity(min(1, max(0, (reveal - 0.12) / 0.14)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)

                stamp(eyebrow: "Now", date: comparison.nowDate)
                    .opacity(min(1, max(0, (0.88 - reveal) / 0.14)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)

                // The wipe used to be driven by a slider parked underneath the
                // frame, which is one indirection away from the thing it moves.
                // Now the edge itself is the control, and it carries a grabber
                // so it reads as one.
                handle(height: proxy.size.height)
                    .offset(x: proxy.size.width * reveal - 17)
            }
            .clipShape(RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                // A minimum distance, and a translation rather than an absolute
                // position. With `minimumDistance: 0` the first change event
                // arrived on touch-down before any movement and slammed the wipe
                // to wherever the finger happened to land, firing the haptic —
                // so flicking past this block on a moving train reset a
                // before/after the user never meant to touch. The hero's
                // scrubber already gates itself behind a long press for the same
                // reason.
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        let width = max(1, proxy.size.width)
                        let anchor = dragAnchor ?? reveal
                        if dragAnchor == nil { dragAnchor = reveal }
                        reveal = min(1, max(0, anchor + value.translation.width / width))
                    }
                    .onEnded { _ in dragAnchor = nil }
            )
        }
        .frame(height: 240)
        // Detented feedback as the wipe crosses the frame, so a before/after
        // comparison feels like moving a physical edge.
        .sensoryFeedback(.selection, trigger: Int(reveal * 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Compare \(dateLabel(comparison.beforeDate)) with \(dateLabel(comparison.nowDate))"
        )
        .accessibilityValue("\(Int((1 - reveal) * 100)) percent the newer photo")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: reveal = min(1, reveal + 0.1)
            case .decrement: reveal = max(0, reveal - 0.1)
            @unknown default: break
            }
        }
    }

    private func stamp(eyebrow: String, date: Date) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(eyebrow.uppercased())
                .font(.caption2.weight(.heavy))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.92))
            Text(dateLabel(date))
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .allowsHitTesting(false)
    }

    private func handle(height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(.white)
                .frame(width: 3, height: height)
            Circle()
                .fill(.white)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "chevron.left.chevron.right")
                        .font(.caption.weight(.black))
                        .foregroundStyle(GroveTheme.inkOnLight)
                }
                .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
        }
        .frame(width: 34)
        .allowsHitTesting(false)
    }

    private func dateLabel(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? "Today"
            : date.formatted(.dateTime.day().month(.abbreviated))
    }
}

struct ObservationThumbnail: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    GroveTheme.softAccent
                    Image(systemName: "leaf.fill")
                        .foregroundStyle(GroveTheme.accent)
                }
            }
        }
        .clipped()
        // Photos restored from the server arrive as signed remote URLs, so
        // loading goes through the shared local-or-remote loader.
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = await GroveImageLoader.downsampledImage(at: url)
        }
    }
}
