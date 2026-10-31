import SwiftUI

// MARK: - Reward payload

/// What a chest paid out. Built by the store the moment the chest is opened, so
/// the ceremony always shows exactly what was banked.
struct ChestReward: Hashable, Identifiable {
    let milestoneID: String
    let title: String
    let xp: Int
    let keepsake: Keepsake?
    let shields: Int
    var id: String { milestoneID }
}

// MARK: - Chest art

/// The reward chest's place in the campaign. The commissioned artwork moves to
/// a richer material each chapter, while the second chest in each chapter gets
/// an extra flourish so no two consecutive rewards look identical.
///
/// `tier` only picks the artwork. It is never shown: the Journey has levels,
/// and a second ladder of chest grades would be one more thing to explain.
struct JourneyChestStyle {
    let tier: Int
    let name: String
    let isChapterFinale: Bool

    private static let orderedChestIDs = JourneyLibrary.chapters.flatMap { chapter in
        chapter.milestones.filter(\.isChest).map(\.id)
    }

    static func forMilestoneID(_ milestoneID: String) -> JourneyChestStyle {
        let ordinal = orderedChestIDs.firstIndex(of: milestoneID) ?? 0
        let tier = min(5, ordinal / 2 + 1)
        let name: String = switch tier {
        case 1: "Cedar chest"
        case 2: "Woodland chest"
        case 3: "Gilded chest"
        case 4: "Emerald chest"
        default: "Ancient chest"
        }

        return JourneyChestStyle(
            tier: tier,
            name: name,
            isChapterFinale: ordinal.isMultiple(of: 2) == false
        )
    }

    var closedAsset: String { "JourneyChestTier\(tier)Closed" }
    var openAsset: String { "JourneyChestTier\(tier)Open" }
}

/// The authored closed and open chest states, drawn flat. `lidLift` crossfades
/// between them, so the ceremony keeps its timing without constructing the
/// illustration from rectangles and a custom lid path.
///
/// No glow and no shadow: the chest sits on the takeover's night green and on
/// white sheets alike, and the only light in a celebration is the room's gold.
struct ChestArt: View {
    let milestoneID: String
    var unit: CGFloat = 64
    var lidLift: Double = 0

    private var style: JourneyChestStyle {
        JourneyChestStyle.forMilestoneID(milestoneID)
    }

    var body: some View {
        ZStack {
            Image(style.closedAsset)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .opacity(1 - lidLift)

            Image(style.openAsset)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .opacity(lidLift)
                .scaleEffect(CGFloat(0.94 + 0.06 * lidLift))

            if style.isChapterFinale {
                // Sized to the drawing, not to the reader's text size: it is
                // part of the artwork.
                Image(systemName: "sparkles")
                    .font(.system(size: unit * 0.17, weight: .bold))
                    .foregroundStyle(GroveTheme.gold)
                    .offset(x: unit * 0.67, y: -unit * 0.48)
            }
        }
        .frame(width: unit * 1.7, height: unit * 1.3)
        .accessibilityHidden(true)
    }
}

// MARK: - Opening ceremony

/// The full-screen chest opening, in the Journey's celebration room.
///
/// Two beats: the chest arrives closed and waits for a tap, then the lid comes
/// up and what was inside is laid out as facts. The tap is the point. A reward
/// you open yourself is worth more than one that is simply added to a total,
/// so the success haptic answers the tap rather than the screen appearing.
struct ChestOpeningView: View {
    let reward: ChestReward
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isOpen = false
    /// When the lid came up. "Done" sits where "Open it" was, so a quick double
    /// tap would otherwise close the chest before anyone saw inside.
    @State private var openedAt: Date?

    private var style: JourneyChestStyle {
        JourneyChestStyle.forMilestoneID(reward.milestoneID)
    }

    private var eyebrow: String {
        let chapter = JourneyLibrary.chapters.first { chapter in
            chapter.milestones.contains { $0.id == reward.milestoneID }
        }
        return chapter.map { "Chapter \($0.number) chest" } ?? "Chest"
    }

    var body: some View {
        JourneyTakeover(
            eyebrow: eyebrow,
            title: isOpen ? "Inside the \(style.name.lowercased())" : style.name,
            message: isOpen ? openedMessage : reward.title,
            primaryTitle: isOpen ? "Done" : "Open it",
            onPrimary: { if isOpen { finish() } else { open() } },
            playsSuccessHaptic: false
        ) {
            ChestArt(milestoneID: reward.milestoneID, unit: 100, lidLift: isOpen ? 1 : 0)
                .contentShape(Rectangle())
                // The chest itself opens too, for anyone who reaches for it
                // rather than the button. The button is the accessible path.
                .onTapGesture { open() }
        } details: {
            if isOpen {
                JourneyFactRow(facts: facts)
            }
        }
    }

    // MARK: Copy

    private var facts: [JourneyFactRow.Fact] {
        var facts: [JourneyFactRow.Fact] = [
            .init(label: "XP", value: "+\(reward.xp)", tint: GroveTheme.gold)
        ]
        // What actually landed in the bank. With the bank already full the
        // chest pays no shields, and a "+0" would describe a gift nobody got.
        if reward.shields > 0 {
            facts.append(.init(label: reward.shields == 1 ? "Shield" : "Shields", value: "+\(reward.shields)"))
        }
        if let keepsake = reward.keepsake {
            facts.append(.init(label: "Keepsake", value: keepsake.name))
        }
        return facts
    }

    /// One plain sentence per thing that needs explaining. XP explains itself.
    private var openedMessage: String {
        var lines: [String] = []
        if reward.shields == 1 {
            lines.append("A shield saves your streak if you miss a day.")
        } else if reward.shields > 1 {
            lines.append("Shields save your streak if you miss a day.")
        }
        if let keepsake = reward.keepsake {
            lines.append("\(keepsake.name) is kept with your badges.")
        }
        return lines.isEmpty ? reward.title : lines.joined(separator: " ")
    }

    private var announcement: String {
        var parts = ["\(reward.xp) XP"]
        if reward.shields > 0 {
            parts.append(reward.shields == 1 ? "1 shield" : "\(reward.shields) shields")
        }
        if let keepsake = reward.keepsake {
            parts.append(keepsake.name)
        }
        return "Chest opened. " + parts.joined(separator: ", ") + "."
    }

    // MARK: Actions

    private func open() {
        guard !isOpen else { return }
        openedAt = .now
        Haptics.success()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : GroveMotion.celebrate) {
            isOpen = true
        }
        AccessibilityNotification.Announcement(announcement).post()
    }

    private func finish() {
        if let openedAt, Date.now.timeIntervalSince(openedAt) < 0.5 { return }
        onDismiss()
    }
}

#Preview("Chest") {
    ChestOpeningView(
        reward: ChestReward(
            milestoneID: "fr-chest-2",
            title: "First roots down. The rest is repetition and more plants.",
            xp: 45,
            keepsake: nil,
            shields: 1
        ),
        onDismiss: {}
    )
}
