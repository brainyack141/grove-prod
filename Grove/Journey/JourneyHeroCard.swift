import SwiftUI

/// Everything a Journey entry point needs to say, resolved in one pass.
///
/// Reading `store` from four separate computed properties would re-run the
/// whole campaign evaluation four times per render. Shared by the Today card
/// and the My Grove header rail so the two can never disagree about whether
/// something is waiting.
struct JourneyGlance {
    let chapter: ResolvedChapter?
    let chests: Int
    let claimableQuests: Int
    /// Today's three, in board order: `true` for each one already done.
    let todaysThree: [Bool]
    /// The current step's title, or nil once every chapter is finished.
    let nextTitle: String?

    /// The small caps over the level: which chapter is being played.
    var eyebrow: String {
        chapter.map { "Chapter \($0.chapter.number) · \($0.chapter.title)" } ?? "Journey"
    }

    /// The one gold line, when something is waiting to be collected. Gold is the
    /// colour of a reward and nothing else, so this is the only place either
    /// entry point spends it.
    var reward: String? {
        if chests > 0 {
            return chests == 1 ? "A chest is waiting" : "\(chests) chests waiting"
        }
        if claimableQuests > 0 {
            return claimableQuests == 1 ? "1 reward to collect" : "\(claimableQuests) rewards to collect"
        }
        return nil
    }

    /// Today's three while any of them are still open; nil once all are done.
    var openTodaysThree: (done: Int, total: Int)? {
        let done = todaysThree.filter { $0 }.count
        guard !todaysThree.isEmpty, done < todaysThree.count else { return nil }
        return (done, todaysThree.count)
    }

    @MainActor
    static func resolve(store: GroveStore) -> JourneyGlance {
        let campaign = store.resolvedCampaign()
        let open = campaign.filter(\.isUnlocked)
        let quests = store.dailyQuests
        return JourneyGlance(
            chapter: open.first { !$0.isComplete } ?? campaign.last,
            chests: open.flatMap(\.readyChests).count,
            claimableQuests: JourneyQuestBoard.summary(quests).claimable,
            todaysThree: quests.filter { $0.objective != .sweep }.map(\.isComplete),
            nextTitle: open.flatMap(\.milestones).first { $0.status == .current }?.milestone.title
        )
    }
}

/// The distance to the next level, phrased as something you can close.
///
/// `190 XP to Sapling` is a thing you can do today; `10 / 200 XP` is a fact
/// about the past.
private func levelRemainderText(_ progress: GardenerProgress) -> String {
    let (earned, needed) = progress.levelProgress
    guard needed > 0, let next = progress.level.next else { return "Top level, \(progress.xp) XP" }
    return "\(max(0, needed - earned)) XP to \(next.title)"
}

// MARK: - Shared pieces

/// The XP bar. One colour on every surface: green, the colour of things going
/// well. It used to be green on Today and gold on My Grove, which spent the
/// reward colour on a number that is never itself a reward.
private struct JourneyXPBar: View {
    let progress: GardenerProgress

    var body: some View {
        GroveProgressBar(
            fraction: progress.fractionToNextLevel,
            tint: GroveTheme.accent,
            height: 6,
            minimumFill: 5
        )
        .frame(minWidth: 44)
    }
}

/// `190 XP to Sapling`, set the same way on both entry points.
private struct JourneyRemainder: View {
    let progress: GardenerProgress

    var body: some View {
        Text(levelRemainderText(progress))
            .font(.footnote.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(GroveTheme.mutedInk)
            .contentTransition(.numericText())
            .groveAnimation(GroveMotion.settle, value: progress.xp)
    }
}

/// A gold mark, then the sentence. The board's status anatomy (dot, then
/// words) with the chest's own square from the rings page as the mark, so a
/// waiting reward never reads as one of the plant status dots beside it. The
/// words stay in ink: a gold that still reads as gold is too light to carry
/// type.
private struct JourneyRewardLine: View {
    let text: String
    @ScaledMetric(relativeTo: .footnote) private var mark: CGFloat = 8

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(GroveTheme.gold)
                .frame(width: mark, height: mark)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Today's three as the rings page draws steps: filled green for done, a
/// hollow ring for not yet. Every quest wears the same green, because "done"
/// is the only thing the mark says.
private struct JourneyTodaysThreeLine: View {
    let marks: [Bool]
    let done: Int
    let total: Int
    @ScaledMetric(relativeTo: .footnote) private var dot: CGFloat = 7

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            HStack(spacing: 4) {
                ForEach(marks.indices, id: \.self) { index in
                    Circle()
                        .fill(marks[index] ? GroveTheme.accent : Color.clear)
                        .overlay {
                            if !marks[index] {
                                Circle().strokeBorder(GroveTheme.subtleInk.opacity(0.6), lineWidth: 1.5)
                            }
                        }
                        .frame(width: dot, height: dot)
                        .groveAnimation(GroveMotion.settle, value: marks[index])
                }
            }
            .accessibilityHidden(true)
            Text("Today's three, \(done) of \(total) done")
                .font(.footnote.weight(.medium))
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - My Grove

/// The Journey worn in the My Grove header rather than parked in a card at the
/// foot of the page.
///
/// Everything it says that the header does not already carry is a level, a bar
/// and a number, set with the same pieces as the Today card so the two entry
/// points read as one object. The gold line is the exception, because a chest
/// waiting to be opened is worth its own row anywhere in the app. It is a
/// static line: a reward that shines forever stops being news by the second
/// visit.
struct JourneyProgressRail: View {
    @Environment(GroveStore.self) private var store

    private var progress: GardenerProgress { store.gardener }

    var body: some View {
        let glance = JourneyGlance.resolve(store: store)
        NavigationLink(value: AppRoute.journey) {
            VStack(alignment: .leading, spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        identity
                        JourneyXPBar(progress: progress)
                        JourneyRemainder(progress: progress)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        GroveRowChevron()
                    }
                    // At accessibility sizes the sentence takes the row and a
                    // stub of bar beside it is worse than no bar, so the fill
                    // gets its full width back underneath.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            identity
                            Spacer(minLength: 0)
                            GroveRowChevron()
                        }
                        JourneyXPBar(progress: progress)
                        JourneyRemainder(progress: progress)
                    }
                    .padding(.vertical, 8)
                }
                // The rail sits on the sheet rather than in a card, so the line
                // itself has to be a full-height target.
                .frame(minHeight: 44)

                if let reward = glance.reward {
                    JourneyRewardLine(text: reward)
                        .padding(.bottom, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(GroveCardPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(glance))
        .accessibilityHint("Opens your Journey")
    }

    /// Who the bar belongs to. A bare track and a number say "there is progress";
    /// they never say progress at what, so the level leads the row.
    private var identity: some View {
        HStack(spacing: 7) {
            GardenerLevelIcon(level: progress.level, size: 24)
            Text(progress.level.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func accessibilityText(_ glance: JourneyGlance) -> String {
        // Starts with "Your journey": the Journey UI tour finds the rail by it.
        var parts = ["Your journey.", "\(progress.level.title).", "\(levelRemainderText(progress))."]
        if let chapter = glance.chapter {
            parts.append("Chapter \(chapter.chapter.number), \(chapter.chapter.title).")
        }
        if let reward = glance.reward {
            parts.append("\(reward).")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Today

/// The entry point into the Journey from Today, drawn as a board row in a card:
/// the level's artwork where a plant row has its photo, the chapter in small
/// caps over the level, the distance to the next level, and a chevron because
/// the row goes somewhere.
///
/// Under that sits at most one line, the most actionable thing in there: a
/// chest or reward to collect (the only gold on the card), then Today's three
/// while any are open.
struct JourneyHeroCard: View {
    /// How much of the page the Journey is allowed to ask for.
    enum Presentation {
        /// The row and always a line under it, falling back to the next step.
        /// For a surface where the Journey is the point of the section.
        case full
        /// The line only when something is waiting or still open today. On
        /// Today the Journey competes with the user's real plants for one
        /// screen of attention, and "next: water something" does not earn a
        /// line of it. A chest does.
        case adaptive
    }

    var presentation: Presentation = .full

    @Environment(GroveStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var progress: GardenerProgress { store.gardener }
    private var level: GardenerLevel { progress.level }

    var body: some View {
        let glance = JourneyGlance.resolve(store: store)
        NavigationLink(value: AppRoute.journey) {
            row(glance)
                .groveCard(padding: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(GroveCardPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(glance))
        .accessibilityHint("Opens your Journey")
    }

    private func row(_ glance: JourneyGlance) -> some View {
        HStack(alignment: .center, spacing: 14) {
            // At accessibility sizes the words need the width more than the
            // picture does; the level's name already says what the art shows.
            if !dynamicTypeSize.isAccessibilitySize {
                levelTile
            }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    GroveEyebrow(text: glance.eyebrow)
                    Text(level.title)
                        .font(GroveTheme.display(GroveDisplayStyle.card.points, weight: .semibold))
                        .foregroundStyle(GroveTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }

                meter

                statusLine(glance)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroveRowChevron()
        }
    }

    /// The level's artwork on the same neutral tile, size and radius as a plant
    /// row's photo, drawn flat.
    private var levelTile: some View {
        GardenerLevelIcon(level: level, size: 42)
            .frame(width: 56, height: 56)
            .background(
                GroveTheme.secondarySurface,
                in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    /// Bar and distance on one line; stacked when the distance needs the row.
    private var meter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                JourneyXPBar(progress: progress)
                JourneyRemainder(progress: progress)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 6) {
                JourneyXPBar(progress: progress)
                JourneyRemainder(progress: progress)
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ glance: JourneyGlance) -> some View {
        if let reward = glance.reward {
            JourneyRewardLine(text: reward)
        } else if let today = glance.openTodaysThree {
            JourneyTodaysThreeLine(marks: glance.todaysThree, done: today.done, total: today.total)
        } else if presentation == .full, let next = glance.nextTitle {
            Text("Next: \(next)")
                .font(.footnote.weight(.medium))
                .foregroundStyle(GroveTheme.mutedInk)
                .lineLimit(2)
        }
    }

    private func accessibilityText(_ glance: JourneyGlance) -> String {
        // Starts with "Your journey", like the rail, so both entry points are
        // found and announced the same way.
        var parts = ["Your journey."]
        if let chapter = glance.chapter {
            parts.append("Chapter \(chapter.chapter.number), \(chapter.chapter.title).")
        }
        parts.append("\(level.title).")
        parts.append("\(levelRemainderText(progress)).")
        if let reward = glance.reward {
            parts.append("\(reward).")
        } else if let today = glance.openTodaysThree {
            parts.append("Today's three, \(today.done) of \(today.total) done.")
        } else if presentation == .full, let next = glance.nextTitle {
            parts.append("Next: \(next).")
        }
        return parts.joined(separator: " ")
    }
}
