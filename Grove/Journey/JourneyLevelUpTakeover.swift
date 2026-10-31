import SwiftUI

// MARK: - Takeover

/// The level promotion.
///
/// One of the Journey's family of celebrations, so a new level happens in the
/// same room as a finished step, a badge and a chest: `JourneyTakeover`'s night
/// green with gold as the only light, one reveal, one light pill. The level's
/// own artwork is the object on the table, sitting in the pith the way the
/// XP total does on the Journey's rings, so the promotion reads as the tree
/// growing rather than as a trophy arriving from nowhere.
///
/// It used to be a three and a half second sequence: a climbing canopy, a bar
/// paying out, a medal lifting into the mascot and a flood of light. A level is
/// rare and stands between someone and the plant they opened the app for, so
/// it now says what happened and what is next, and gets out of the way.
///
/// Presented from the app shell by ``GroveCelebrationLayer``.
struct GroveLevelUpOverlay: View {
    let level: GardenerLevel
    /// The XP total when the level landed. `nil` falls back to the level's own
    /// threshold, which is what a total just past it rounds down to.
    var xp: Int?
    let onDismiss: () -> Void

    /// The art slot is 188pt tall. The level artwork is drawn small, so it
    /// sits in a pith disc that gives it a medal's presence without a glow.
    private static let pithSize: CGFloat = 148
    private static let artworkSize: CGFloat = 88

    var body: some View {
        JourneyTakeover(
            eyebrow: "New level",
            title: level.title,
            message: level.promotionBlurb,
            primaryTitle: "Done",
            onPrimary: onDismiss
        ) {
            ZStack {
                Circle()
                    .fill(JourneyWorld.ringPith)
                Circle()
                    .strokeBorder(JourneyWorld.ringLine, lineWidth: 1)
                GardenerLevelIcon(level: level, size: Self.artworkSize)
            }
            .frame(width: Self.pithSize, height: Self.pithSize)
        } details: {
            JourneyFactRow(facts: facts)
        }
        // Two levels in a row get two reveals, not a swap in place.
        .id(level)
    }

    private var total: Int {
        max(xp ?? level.xpThreshold, level.xpThreshold)
    }

    private var facts: [JourneyFactRow.Fact] {
        var facts: [JourneyFactRow.Fact] = [
            .init(label: "Total", value: "\(total.formatted()) XP")
        ]
        if let next = level.next {
            facts.append(.init(label: "Next level", value: next.title))
            facts.append(.init(label: "To go", value: "\(max(0, next.xpThreshold - total).formatted()) XP"))
        } else {
            // The top of the ladder: there is no next level to point at, so
            // say where they stand instead of inventing a goal.
            facts.append(.init(label: "Level", value: "\(level.rawValue + 1) of \(GardenerLevel.allCases.count)"))
        }
        return facts
    }
}

#Preview("Level up") {
    GroveLevelUpOverlay(level: .gardener, xp: 655, onDismiss: {})
}

#Preview("Level up, top level") {
    GroveLevelUpOverlay(level: .oldGrowth, onDismiss: {})
}
