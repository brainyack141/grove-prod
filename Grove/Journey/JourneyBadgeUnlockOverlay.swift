import SwiftUI

// MARK: - Badge unlock takeover

/// The moment a badge is earned.
///
/// Until this existed a badge was recorded and nothing else happened: someone
/// could nurse a plant from Needs attention back to Healthy over three weeks,
/// earn The Save, and only find out by wandering into their profile.
///
/// One of the Journey's family of celebrations, so it happens in the same room
/// as a finished step, a chest and a new level: `JourneyTakeover`'s night green
/// with gold as the only light. The badge's artwork is the object on the table,
/// drawn flat. Its own palette stays on the medal and never lights the room,
/// because gold is the one colour that means a reward.
struct BadgeUnlockOverlay: View {
    let badge: Badge
    /// Badges still waiting behind this one. Only used to label the screen
    /// honestly when a single action earned several at once.
    var remaining: Int = 0
    /// When the store dated the badge. `nil` reads as today, which is when a
    /// badge being celebrated was earned.
    var earnedAt: Date?
    let onDismiss: () -> Void

    var body: some View {
        JourneyTakeover(
            eyebrow: remaining > 0 ? "Badge earned · \(remaining) more" : "Badge earned",
            title: badge.title,
            // The blurb names what the person did for a living thing, which is
            // the only congratulation Grove ever offers.
            message: badge.blurb,
            // With more badges queued, "Done" would be a lie about what the
            // next tap does.
            primaryTitle: remaining > 0 ? "Next badge" : "Done",
            onPrimary: onDismiss
        ) {
            Image(badge.artworkAsset)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 168, height: 168)
        } details: {
            JourneyFactRow(facts: [
                .init(label: "Category", value: badge.category.title),
                .init(label: "Earned", value: earnedLine)
            ])
        }
        // A new badge is a new object on the table, so the next one in the
        // queue gets its own reveal rather than a swap in place.
        .id(badge.id)
    }

    private var earnedLine: String {
        let date = earnedAt ?? .now
        if Calendar.current.isDateInToday(date) { return "Today" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - Celebration layer

/// Drains the store's celebration queues wherever the person happens to be
/// standing.
///
/// This lives at the app shell rather than inside the Journey because the work
/// that earns a badge is done on Today, in a check-in, or in Ask — almost never
/// on the Journey map. The level-up takeover used to be mounted on the map
/// alone, so levelling up during a check-in showed nothing at all until you
/// later navigated to the one screen holding the overlay.
///
/// The three moments are ordered smallest first: the streak, then badges one at
/// a time oldest first, then the level-up. A session that earns all three ends
/// on the biggest of them rather than burying it under three badges — and the
/// streak, which happens most days, is over before the rare things start.
struct GroveCelebrationLayer: ViewModifier {
    @Environment(GroveStore.self) private var store

    @State private var streak: StreakMoment?
    @State private var badge: Badge?
    @State private var levelUp: GardenerLevel?

    func body(content: Content) -> some View {
        content
            .overlay {
                if let streak {
                    StreakCelebrationOverlay(
                        moment: streak,
                        week: store.streakSummary.week
                    ) {
                        self.streak = nil
                    }
                    .transition(.opacity)
                }
            }
            .overlay {
                if streak == nil, let badge {
                    BadgeUnlockOverlay(
                        badge: badge,
                        remaining: store.pendingBadges.count,
                        earnedAt: store.gardener.unlockedBadgeDates[badge.id],
                        onDismiss: advance
                    )
                    .transition(.opacity)
                }
            }
            .overlay {
                if streak == nil, badge == nil, let levelUp {
                    GroveLevelUpOverlay(level: levelUp, xp: store.gardener.xp) {
                        self.levelUp = nil
                        advance()
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: streak)
            .animation(.easeInOut(duration: 0.25), value: badge)
            .animation(.easeInOut(duration: 0.25), value: levelUp)
            // `initial: true` covers awards banked while this layer was being
            // built — a refresh during launch would otherwise queue a badge
            // nobody is watching for yet.
            .onChange(of: store.pendingBadges.isEmpty, initial: true) { _, isEmpty in
                if !isEmpty, badge == nil { advance() }
            }
            .onChange(of: store.pendingLevelUp, initial: true) { _, pending in
                if pending != nil { levelUp = store.takePendingLevelUp() }
            }
            .onChange(of: store.pendingStreakMoment, initial: true) { _, pending in
                if pending != nil { streak = store.takePendingStreakMoment() }
            }
    }

    /// Pulls the next badge forward, or clears the layer once the queue is dry
    /// and lets any held level-up through.
    private func advance() {
        badge = store.takePendingBadge()
    }
}

extension View {
    /// Mounts the badge and level-up takeovers above the whole app.
    func groveCelebrationLayer() -> some View {
        modifier(GroveCelebrationLayer())
    }
}

#Preview("Badge unlock") {
    BadgeUnlockOverlay(
        badge: JourneyLibrary.badge(id: "the-save") ?? JourneyLibrary.badges[0],
        remaining: 1,
        onDismiss: {}
    )
}
