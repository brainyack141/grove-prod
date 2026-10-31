import SwiftUI

/// The streak, unpacked far enough to explain itself.
///
/// Built by `GroveStore.streakSummary`. Kept as a value type so the copy that
/// tells a gardener where they stand can be tested without a view.
struct StreakSummary: Equatable {
    enum DayState: Equatable {
        /// A day inside the current run.
        case kept
        /// A missed day a banked shield is standing in for.
        case shielded
        /// Today, still waiting on a qualifying look.
        case pending
        /// A day outside the run.
        case missed
    }

    struct DayMark: Identifiable, Equatable {
        let id: Int
        let date: Date
        /// The single-letter weekday, in the reader's locale.
        let initial: String
        let state: DayState
        let isToday: Bool
    }

    var current: Int
    var longest: Int
    var countedToday: Bool
    var isShielded: Bool
    var shields: Int
    var daysUntilNextShield: Int
    /// The last seven days, oldest first, ending on today.
    var week: [DayMark]

    /// The run length the next shield lands on.
    var nextShieldDay: Int { current + daysUntilNextShield }

    /// Where the gardener stands, in one sentence.
    ///
    /// Every branch names the next concrete action, because a streak readout
    /// that only reports a number leaves the reader to guess what keeps it —
    /// and Grove's answer ("look at something") is not the one people assume.
    var status: String {
        if isShielded {
            return "A shield saved your streak yesterday. Check in on a plant, finish a lesson or ask Ari today to keep it going."
        }
        if countedToday {
            return current == 1
                ? "Today's done. Come back tomorrow to make it two."
                : "Today's done. Come back tomorrow to make it \(current + 1)."
        }
        if current > 0 {
            return "Check in on a plant, finish a lesson or ask Ari today to make it \(current + 1)."
        }
        if longest > 0 {
            let best = longest == 1 ? "1 day" : "\(longest) days"
            return "Your best streak was \(best). Check in on a plant, finish a lesson or ask Ari to start a new one."
        }
        return "Check in on any plant, finish a lesson or ask Ari to start a streak."
    }

    /// The short state chip beside the number, when there is state worth
    /// naming. Nil on an ordinary day — a chip reading "streak" beside a
    /// streak is decoration.
    var badge: (text: String, symbol: String)? {
        if isShielded { return ("Shield in use", "shield.fill") }
        if countedToday { return ("Done today", "checkmark.circle.fill") }
        return nil
    }
}

// MARK: - Sheet

/// What every flame in Grove opens.
///
/// The streak's rules are genuinely non-obvious — it counts looking and never
/// watering, and a banked shield quietly covers one missed day — and none of
/// that was written down anywhere in the app. This is where a gardener finds
/// out what they are keeping, how close the next shield is, and what to do
/// about today.
struct StreakDetailSheet: View {
    @Environment(GroveStore.self) private var store
    @Environment(IntentRouter.self) private var intentRouter
    @Environment(\.dismiss) private var dismiss

    /// Held until the sheet has actually gone, then pushed. Navigating out from
    /// under a sheet that is still animating away lands the new screen behind
    /// it, and the user watches their own destination get covered up.
    @State private var routeOnExit: AppRoute?

    private var summary: StreakSummary { store.streakSummary }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    headline
                    weekRow
                    shieldCard
                    whatCounts
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .groveBackground()
            .safeAreaInset(edge: .bottom) { callToAction }
            .navigationTitle("Streak")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.bold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear {
            guard let routeOnExit else { return }
            intentRouter.pushedRoute = routeOnExit
        }
    }

    // MARK: Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroveEyebrow(text: "Daily streak")

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: summary.current > 0 ? "flame.fill" : "flame")
                    .font(GroveTheme.display(34))
                    .foregroundStyle(summary.current > 0 ? GroveTheme.streak : GroveTheme.subtleInk)

                Text("\(summary.current)")
                    .font(GroveTheme.display(58))
                    .monospacedDigit()
                    .foregroundStyle(GroveTheme.ink)
                    .contentTransition(.numericText(value: Double(summary.current)))

                Text(summary.current == 1 ? "day" : "days")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(GroveTheme.mutedInk)
            }

            if let badge = summary.badge {
                Label(badge.text, systemImage: badge.symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(summary.isShielded ? GroveTheme.goldDeep : GroveTheme.accentStrong)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        (summary.isShielded ? GroveTheme.goldDeep : GroveTheme.accentStrong).opacity(0.1),
                        in: Capsule()
                    )
            }

            Text(summary.status)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            if summary.current > 0, summary.longest > summary.current {
                Text("Best streak: \(summary.longest) days.")
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.subtleInk)
            } else if summary.current > 0, summary.current >= summary.longest {
                // "Longest so far", not "best yet": the summary cannot tell a
                // new record from a tie with an old one, and the celebration
                // only calls a strictly longer run a best.
                Text("Your longest streak so far.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GroveTheme.accentStrong)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: The week behind it

    /// Seven days makes the run a shape rather than a number. Drawn by the same
    /// row the celebration lights, so the thing you see the moment you earn a
    /// day is the thing you find when you come back looking for it.
    private var weekRow: some View {
        StreakWeekRow(week: summary.week)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .groveCard(padding: 8)
    }

    // MARK: Shields

    private var shieldCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: summary.shields > 0 ? "shield.fill" : "shield")
                .font(.title3.weight(.bold))
                .foregroundStyle(summary.shields > 0 ? GroveTheme.goldDeep : GroveTheme.subtleInk)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text(shieldTitle)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(GroveTheme.ink)

                Text(shieldDetail)
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groveCard()
        .accessibilityElement(children: .combine)
    }

    private var shieldTitle: String {
        switch summary.shields {
        case 0: "No shields yet"
        case 1: "1 shield"
        default: "\(summary.shields) shields"
        }
    }

    private var shieldDetail: String {
        let saves = "If you miss a day, a shield saves your streak automatically."
        // The bank is capped, so at the cap no shield is on its way and the
        // sheet must not promise one.
        guard summary.shields < GroveStore.maxStreakShields else {
            return "\(saves) You're holding the most you can, \(GroveStore.maxStreakShields)."
        }
        return "\(saves) You earn one every seventh day of a streak. The next arrives at day \(summary.nextShieldDay)."
    }

    // MARK: What counts

    private var whatCounts: some View {
        StreakQualifyingActionsCard()
    }
}

/// One shared statement of the streak rules. Badge details reuse the same card
/// as the flame sheet so the two explanations cannot drift apart.
struct StreakQualifyingActionsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What counts")
                .font(.headline.weight(.bold))
                .foregroundStyle(GroveTheme.ink)

            VStack(alignment: .leading, spacing: 11) {
                qualifier("eye.fill", "A check-in on any plant")
                qualifier("camera.viewfinder", "A diagnosis for one of your plants")
                qualifier("book.fill", "A lesson or a quiz")
                qualifier("text.bubble.fill", "A question Ari answers")
            }

            Text("Watering doesn't count towards your streak. That way it never pushes you to water a plant that doesn't need it.")
                .font(.footnote)
                .foregroundStyle(GroveTheme.subtleInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groveCard()
    }

    private func qualifier(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(GroveTheme.accent)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension StreakDetailSheet {

    // MARK: Today's move

    /// Only when today is still open. A sheet that offers an action after the
    /// day is already counted is inventing work to look busy.
    @ViewBuilder
    private var callToAction: some View {
        if !summary.countedToday, let action = todaysAction {
            Button {
                routeOnExit = action.route
                dismiss()
            } label: {
                GroveCTALabel(title: action.title)
            }
            .buttonStyle(GrovePressStyle())
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.bar)
        }
    }

    /// The plant most worth looking at — lowest health first, since the streak
    /// and the grove want the same thing from this tap.
    private var todaysAction: (title: String, route: AppRoute)? {
        // Active plants only: a remembered fern is often the lowest score in
        // the grove, and "Check in on Fern" for a plant marked gone is cruel.
        if let plant = store.activePlants.min(by: { $0.healthScore < $1.healthScore }) {
            return ("Check in on \(plant.nickname)", .checkIn(plant.id))
        }
        guard summary.current == 0, store.plants.isEmpty else { return nil }
        return ("Add your first plant", .addPlant)
    }
}

// MARK: - Trigger

/// Wraps a streak indicator in the tap that opens the shared sheet.
///
/// Grove shows the flame in three places — the root tabs' header, the Journey
/// HUD and the celebration — and they all mean the same number, so they all
/// open the same explanation. Each keeps its own look and hands it to this.
struct StreakSheetTrigger<Label: View>: View {
    @ViewBuilder var label: () -> Label

    @State private var isShowingSheet = false

    var body: some View {
        Button { isShowingSheet = true } label: { label() }
            .buttonStyle(GrovePressStyle())
            .accessibilityHint("Shows how your streak works")
            .sheet(isPresented: $isShowingSheet) { StreakDetailSheet() }
    }
}

// MARK: - Header pill

/// The run, in the top bar of every root tab.
///
/// A streak only changes behaviour if it is in front of the person on the day
/// they are deciding whether to open the app at all. Each root tab places this
/// in its leading toolbar slot, so the shared masthead stays consistent while
/// Today can group it beside the Grove score.
struct GroveHeaderStreak: View {
    @Environment(GroveStore.self) private var store

    var body: some View {
        StreakSheetTrigger {
            StreakHeaderPill(
                days: store.displayStreak,
                isShielded: store.streakIsShielded
            )
        }
        .accessibilityIdentifier("headerStreak")
    }
}

/// Deliberately the same chrome as the header's other chips: on iOS 26 the bar
/// wraps its own items in Liquid Glass, so the pill is bare content and lets the
/// system draw the capsule; earlier releases get Grove's warm-white surface.
///
/// A streak standing on a shield swaps the flame for the shield rather than
/// adding one beside it. At bar size a second glyph is noise, and the swap is
/// how the rest of the app already draws that state.
private struct StreakHeaderPill: View {
    let days: Int
    var isShielded = false
    @Environment(\.groveHeaderClustered) private var isClustered
    /// The bar's scheme, handed down by `groveHeaderChip()`: dark over the
    /// hero, the page's own once the sheet is under the bar.
    @Environment(\.colorScheme) private var colorScheme

    private var usesBareChrome: Bool {
        if #available(iOS 26.0, *) { return true }
        return isClustered
    }

    private var active: Bool { days > 0 }

    /// Light content over the hero. Over a light page the bar's glass turns
    /// white, and white type on it vanishes, so the pill switches to ink the
    /// way the header's other chips do.
    private var usesLightContent: Bool { colorScheme == .dark }

    private var foreground: Color { usesLightContent ? .white : GroveTheme.ink }

    /// White on every hero. The pill carries its own dark backing so the
    /// flame reads over pale photographs as well as the night-green cards.
    private var tint: Color {
        guard active else { return usesLightContent ? .white : GroveTheme.mutedInk }
        return isShielded ? GroveTheme.goldDeep : GroveTheme.streak
    }

    private var backing: Color { usesLightContent ? Color.black.opacity(0.28) : .clear }

    private var glyph: some View {
        Image(systemName: isShielded && active ? "shield.fill" : "flame.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
    }

    private var content: some View {
        HStack(spacing: 5) {
            glyph

            Text("\(days)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(foreground)
                .contentTransition(.numericText(value: Double(days)))
        }
    }

    var body: some View {
        Group {
            if usesBareChrome {
                content
                    .frame(minWidth: 34, minHeight: 24)
                    .background(backing, in: Capsule())
            } else {
                content
                    .padding(.horizontal, 11)
                    .frame(height: 38)
                    .background(.ultraThinMaterial, in: Capsule())
                    .background(backing, in: Capsule())
                    .overlay {
                        Capsule().stroke(
                            usesLightContent ? Color.white.opacity(0.55) : GroveTheme.separator,
                            lineWidth: 1
                        )
                    }
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            }
        }
        // A zero streak can sit back, but never so far that it stops reading.
        .opacity(active ? 1 : 0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Keeping the streak means a check-in, a new diagnosis, a lesson or quiz,
    /// or a question Ari answers — never watering. Naming one screen's action
    /// here would teach a rule Grove does not have.
    private var accessibilityText: String {
        guard active else { return "No streak yet. Check in on a plant, finish a lesson or ask Ari to start one." }
        if isShielded {
            return "\(days)-day streak, saved by a shield. Check in on a plant, finish a lesson or ask Ari today to keep it."
        }
        return days == 1 ? "1-day streak" : "\(days)-day streak"
    }
}

// MARK: - Previews

@MainActor
private func streakPreviewStore(streak: Int, shields: Int, lastTendOffset: Int) -> GroveStore {
    let store = GroveStore(persistenceEnabled: false)
    store.gardener.currentStreak = streak
    store.gardener.longestStreak = max(streak, 9)
    store.gardener.streakShields = shields
    store.gardener.lastTendDay = Calendar.current.date(
        byAdding: .day,
        value: -lastTendOffset,
        to: .now
    )
    return store
}

#Preview("Open day") {
    Color.clear
        .sheet(isPresented: .constant(true)) { StreakDetailSheet() }
        .environment(streakPreviewStore(streak: 6, shields: 0, lastTendOffset: 1))
        .environment(IntentRouter.shared)
}

#Preview("Counted today") {
    Color.clear
        .sheet(isPresented: .constant(true)) { StreakDetailSheet() }
        .environment(streakPreviewStore(streak: 12, shields: 1, lastTendOffset: 0))
        .environment(IntentRouter.shared)
}

#Preview("Shield in use") {
    Color.clear
        .sheet(isPresented: .constant(true)) { StreakDetailSheet() }
        .environment(streakPreviewStore(streak: 8, shields: 1, lastTendOffset: 2))
        .environment(IntentRouter.shared)
}
