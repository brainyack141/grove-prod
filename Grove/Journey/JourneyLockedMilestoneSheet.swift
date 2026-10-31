import SwiftUI

// MARK: - Model

/// Everything a locked node needs in order to explain itself: the node, the
/// region it sits in, and whatever is genuinely standing in the way.
///
/// A locked node used to be a dead end — greyed out, unreachable, silent about
/// why. That hides the best part of a progression map: the thing you can't have
/// yet is what pulls you forward. Tapping one now shows the contract, the way a
/// locked item in a progression-based game does: what it is, exactly what opens
/// it, how far along you already are, and what you get.
struct JourneyLockedPreview: Identifiable, Hashable {
    let item: ResolvedMilestone
    let chapter: ResolvedChapter
    /// The open step the player has to finish before this one comes within
    /// reach. Nil only in the edge case where nothing is currently available.
    let blocker: ResolvedMilestone?
    /// The region that has to be finished before this node's region unseals.
    /// Nil when the node's own chapter is already open.
    let gatingChapter: ResolvedChapter?

    var id: String { item.id }

    /// Build the explanation for a locked node from the resolved campaign.
    static func make(for item: ResolvedMilestone, campaign: [ResolvedChapter]) -> JourneyLockedPreview? {
        guard let chapter = campaign.first(where: { chapter in
            chapter.milestones.contains { $0.id == item.id }
        }) else { return nil }

        // The one step the whole campaign is waiting on. For a locked node in an
        // open region that is the node just ahead of it; for a node behind a
        // sealed region it is the step that region is waiting on. Same answer,
        // and it is always the honest "do this next".
        let blocker = campaign
            .filter(\.isUnlocked)
            .flatMap(\.milestones)
            .first { $0.status == .current }

        let gating = chapter.isUnlocked
            ? nil
            : campaign.first { $0.chapter.number == chapter.chapter.number - 1 }

        return JourneyLockedPreview(
            item: item,
            chapter: chapter,
            blocker: blocker,
            gatingChapter: gating
        )
    }
}

// MARK: - Requirement language

extension MilestoneRequirement {
    /// The plain-language contract for a node: what has to actually happen in
    /// the Grove, written as the thing you'd say out loud.
    var unlockSummary: String {
        switch self {
        case .interactive:
            "A short read and one tap"
        case .chest:
            "Opens the moment the step before it is done"
        case .careLogged(let min):
            "Log \(Self.counted(min, "care task"))"
        case .checkInsCompleted(let min):
            "Finish \(Self.counted(min, "check-in"))"
        case .plantsOwned(let min):
            "Keep \(Self.counted(min, "plant")) in your grove"
        case .plantReachedBand(let band):
            "Get any plant to \(band.title)"
        case .plantsHealthy(let min):
            "Have \(Self.counted(min, "plant")) at Healthy or better"
        case .plantsThriving(let min):
            "Have \(Self.counted(min, "plant")) Thriving"
        case .streakReached(let days):
            "Reach a \(days)-day streak"
        case .lessonsLearned(let min):
            "Finish \(Self.counted(min, "lesson"))"
        case .deepestTimeline(let min):
            "Build one plant's history to \(Self.counted(min, "check-in"))"
        case .distinctLocations(let min):
            "Keep plants in \(Self.counted(min, "room"))"
        case .collectionsCreated(let min):
            "Create \(Self.counted(min, "collection"))"
        case .recoveredPlant:
            "Bring a struggling plant back to Healthy"
        case .sitterInvited:
            "Invite someone to sit for your grove"
        case .newGrowthObserved(let min):
            "Spot new growth in \(Self.counted(min, "check-in"))"
        case .healthyCheckInRun(let min):
            "Log \(Self.counted(min, "healthy check-in")) in a row on one plant"
        case .recoveredPlants(let min):
            "Bring \(Self.counted(min, "plant")) back from trouble"
        case .sitterCareCompleted(let min):
            "Have your sitter finish \(Self.counted(min, "task"))"
        }
    }

    private static func counted(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}

// MARK: - Sheet

/// The peek at a node you haven't reached yet.
struct JourneyLockedMilestoneSheet: View {
    @Environment(GroveStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let preview: JourneyLockedPreview
    /// Take me to the step that actually opens this.
    let onFollow: (JourneyMilestone) -> Void

    private var milestone: JourneyMilestone { preview.item.milestone }

    private var badge: Badge? {
        milestone.badgeID.flatMap(JourneyLibrary.badge(id:))
    }

    private var keepsake: Keepsake? {
        milestone.keepsakeID.flatMap(KeepsakeLibrary.keepsake(id:))
    }

    /// The step to send the player to. A chest is never the thing in the way.
    private var followTarget: JourneyMilestone? {
        guard let blocker = preview.blocker, !blocker.milestone.isChest else { return nil }
        return blocker.milestone
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    JourneyStepSheetHeader(
                        milestone: milestone,
                        eyebrow: "\(milestone.kind.label) · Chapter \(preview.chapter.chapter.number)",
                        isLocked: true
                    )
                    JourneyFactRow(facts: facts)
                }
                unlockLadder
                if badge != nil || keepsake != nil {
                    rewards
                }
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, GroveTheme.pageTopPadding)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let followTarget {
                // The press style already answers the finger, so no second
                // haptic here.
                GroveCTAButton(title: "Go to “\(followTarget.title)”") {
                    onFollow(followTarget)
                }
                .groveActionBar()
            }
        }
        .groveBackground()
        .groveEditorialPage("Locked")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }

    // MARK: Facts

    /// What the step pays, as small caps over values.
    private var facts: [JourneyFactRow.Fact] {
        var facts: [JourneyFactRow.Fact] = [
            .init(label: "XP", value: "+\(milestone.xpReward)")
        ]
        if milestone.shieldReward > 0 {
            facts.append(.init(
                label: milestone.shieldReward == 1 ? "Shield" : "Shields",
                value: "+\(milestone.shieldReward)"
            ))
        }
        return facts
    }

    // MARK: The ladder

    /// The steps between here and there, in order. Reading it top to bottom is
    /// the whole answer to "how do I unlock this?".
    private var unlockLadder: some View {
        let rungs = steps
        return VStack(alignment: .leading, spacing: 4) {
            JourneySectionHeader(
                title: "To unlock",
                subtitle: rungs.count == 1 ? "One thing left to do" : "In order, top to bottom"
            )

            VStack(spacing: 0) {
                ForEach(Array(rungs.enumerated()), id: \.element.id) { index, step in
                    JourneyUnlockStepRow(
                        number: index + 1,
                        total: rungs.count,
                        step: step,
                        isFirst: index == 0,
                        isLast: index == rungs.count - 1
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .groveCard()
        }
    }

    private var steps: [JourneyUnlockStep] {
        var steps: [JourneyUnlockStep] = []

        if let gating = preview.gatingChapter {
            steps.append(
                JourneyUnlockStep(
                    id: "chapter-\(gating.chapter.id)",
                    title: "Finish Chapter \(gating.chapter.number), \(gating.chapter.title)",
                    detail: "\(gating.completedCount) of \(gating.totalCount) steps done",
                    fraction: gating.fraction
                )
            )
        }

        if let blocker = preview.blocker, blocker.id != preview.item.id {
            steps.append(
                JourneyUnlockStep(
                    id: "blocker-\(blocker.id)",
                    title: "Finish “\(blocker.milestone.title)”",
                    detail: blocker.target > 1
                        ? "\(min(blocker.current, blocker.target)) of \(blocker.target) · \(blocker.milestone.requirement.unlockSummary)"
                        : blocker.milestone.requirement.unlockSummary,
                    fraction: blocker.target > 1 ? blocker.fraction : nil
                )
            )
        }

        // The node's own ask, with live progress: care you've already given
        // counts towards it even while it's sealed, and seeing that is the
        // difference between a wall and a target.
        steps.append(
            JourneyUnlockStep(
                id: "self-\(preview.item.id)",
                title: milestone.requirement.unlockSummary,
                detail: preview.item.target > 1
                    ? "\(min(preview.item.current, preview.item.target)) of \(preview.item.target) already"
                    : nil,
                fraction: preview.item.target > 1 ? preview.item.fraction : nil
            )
        )

        return steps
    }

    // MARK: Rewards

    private var rewards: some View {
        VStack(alignment: .leading, spacing: 4) {
            JourneySectionHeader(
                title: milestone.isChest ? "What's in it" : "What you get",
                subtitle: "Yours when this step is done"
            )
            JourneyStepRewardList(
                badge: badge,
                badgeEarned: badge.map { store.gardener.unlockedBadgeIDs.contains($0.id) } ?? false,
                keepsake: keepsake,
                keepsakeEarned: keepsake.map { store.gardener.keepsakeIDs.contains($0.id) } ?? false
            )
        }
    }
}

// MARK: - Shared sheet parts

/// The top of a step's sheet: the same tile the step wears in the Journey's
/// lists, so the sheet is clearly about the row that was tapped, then its kind
/// and chapter, its name, and its one-line promise.
struct JourneyStepSheetHeader: View {
    let milestone: JourneyMilestone
    let eyebrow: String
    var isLocked = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout: AnyLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))

        VStack(alignment: .leading, spacing: 12) {
            layout {
                tile
                VStack(alignment: .leading, spacing: 4) {
                    GroveEyebrow(text: eyebrow)
                    GroveDisplayHeading(text: milestone.title, style: .section)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(milestone.blurb)
                .font(.body)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tile: some View {
        JourneyMilestoneTile(milestone: milestone, size: 52)
            .overlay(alignment: .bottomTrailing) {
                if isLocked {
                    // Sized by the type, not a fixed point size, so it grows
                    // with the rest of the sheet.
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(GroveTheme.mutedInk)
                        .padding(5)
                        .background(GroveTheme.surface, in: Circle())
                        .overlay { Circle().strokeBorder(GroveTheme.separator, lineWidth: 1) }
                        .offset(x: 6, y: 6)
                        .accessibilityLabel("Locked")
                }
            }
    }
}

/// The badge and keepsake a step pays out, as hairline rows in one card. XP
/// and shields are numbers, so they live in the sheet's fact row instead.
struct JourneyStepRewardList: View {
    var badge: Badge?
    var badgeEarned = false
    var keepsake: Keepsake?
    var keepsakeEarned = false

    private static let artSize: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            if let badge {
                row(
                    kind: "Badge",
                    title: badge.title,
                    detail: badgeEarned ? "Earned" : badge.blurb
                ) {
                    JourneyBadgeMedallion(
                        badge: badge,
                        state: badgeEarned ? .earned : .locked(detail: "", fraction: nil),
                        size: 44
                    )
                }
            }
            if badge != nil, keepsake != nil {
                GroveRowDivider(inset: Self.artSize + 14)
            }
            if let keepsake {
                row(
                    kind: "Keepsake",
                    title: keepsake.name,
                    detail: keepsakeEarned ? "Earned. Kept with your badges." : "Kept with your badges."
                ) {
                    KeepsakeSpriteView(sprite: keepsake.sprite, unit: 28)
                        .saturation(keepsakeEarned ? 1 : 0)
                        .opacity(keepsakeEarned ? 1 : 0.5)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groveCard(padding: 0)
    }

    private func row<Art: View>(
        kind: String,
        title: String,
        detail: String,
        @ViewBuilder art: () -> Art
    ) -> some View {
        HStack(spacing: 14) {
            art()
                .frame(width: Self.artSize, height: Self.artSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                GroveEyebrow(text: kind)
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Ladder row

/// One rung of the unlock ladder.
struct JourneyUnlockStep: Identifiable, Hashable {
    let id: String
    let title: String
    var detail: String?
    var fraction: Double?
}

private struct JourneyUnlockStepRow: View {
    let number: Int
    let total: Int
    let step: JourneyUnlockStep
    let isFirst: Bool
    let isLast: Bool

    /// Grows with the type so the numeral never outgrows its disc.
    @ScaledMetric(relativeTo: .caption) private var disc: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                // The first rung is the one the player can act on today, so it
                // is the one in ink; everything below it is deliberately quieter.
                Text("\(number)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isFirst ? GroveTheme.background : GroveTheme.mutedInk)
                    .frame(width: disc, height: disc)
                    .background(isFirst ? GroveTheme.ink : GroveTheme.secondarySurface, in: Circle())
                if !isLast {
                    Rectangle()
                        .fill(GroveTheme.separator)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 6) {
                Text(step.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = step.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fraction = step.fraction {
                    GroveProgressBar(
                        fraction: fraction,
                        tint: isFirst ? GroveTheme.accent : GroveTheme.subtleInk,
                        height: 6,
                        minimumFill: 4
                    )
                    .padding(.top, 2)
                }
            }
            .padding(.top, 2)
            .padding(.bottom, isLast ? 0 : 18)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: String {
        var parts = ["Step \(number) of \(total)", step.title]
        if let detail = step.detail {
            parts.append(detail.replacingOccurrences(of: " · ", with: ", "))
        }
        return parts.joined(separator: ". ")
    }
}
