import SwiftUI

/// The Journey's illustration palette — the one place the world's scenery
/// colours live. These are storybook art, not UI chrome: UI on top of the world
/// (HUD, buttons, cards, node states) always uses `GroveTheme` tokens; the
/// landscape underneath draws from here.
enum JourneyWorld {

    // MARK: Biome scenery

    /// The ground colour at the top of a biome's band.
    static func groundTop(_ biome: JourneyBiome, dark: Bool) -> Color {
        switch biome {
        case .meadow: dark ? rgb(0.10, 0.24, 0.16) : rgb(0.70, 0.86, 0.62)
        case .woodland: dark ? rgb(0.08, 0.20, 0.15) : rgb(0.58, 0.79, 0.55)
        case .orchard: dark ? rgb(0.12, 0.20, 0.13) : rgb(0.79, 0.85, 0.56)
        case .highland: dark ? rgb(0.09, 0.17, 0.19) : rgb(0.66, 0.82, 0.72)
        case .canopy: dark ? rgb(0.06, 0.16, 0.13) : rgb(0.48, 0.73, 0.52)
        }
    }

    /// The ground colour at the bottom of a biome's band. Each biome's bottom
    /// is close to the next biome's top, so the world reads as one continuous
    /// landscape rather than five stacked cards.
    static func groundBottom(_ biome: JourneyBiome, dark: Bool) -> Color {
        switch biome {
        case .meadow: dark ? rgb(0.07, 0.19, 0.14) : rgb(0.58, 0.79, 0.55)
        case .woodland: dark ? rgb(0.09, 0.18, 0.13) : rgb(0.72, 0.82, 0.54)
        case .orchard: dark ? rgb(0.09, 0.17, 0.16) : rgb(0.68, 0.83, 0.70)
        case .highland: dark ? rgb(0.06, 0.15, 0.14) : rgb(0.52, 0.75, 0.55)
        case .canopy: dark ? rgb(0.04, 0.12, 0.10) : rgb(0.36, 0.62, 0.42)
        }
    }

    static func floraPrimary(_ biome: JourneyBiome, dark: Bool) -> Color {
        switch biome {
        case .meadow: dark ? rgb(0.18, 0.38, 0.24) : rgb(0.30, 0.55, 0.30)
        case .woodland: dark ? rgb(0.14, 0.33, 0.21) : rgb(0.21, 0.44, 0.24)
        case .orchard: dark ? rgb(0.20, 0.34, 0.18) : rgb(0.38, 0.52, 0.24)
        case .highland: dark ? rgb(0.15, 0.30, 0.28) : rgb(0.28, 0.48, 0.42)
        case .canopy: dark ? rgb(0.10, 0.28, 0.19) : rgb(0.16, 0.38, 0.22)
        }
    }

    static func floraSecondary(_ biome: JourneyBiome, dark: Bool) -> Color {
        floraPrimary(biome, dark: dark).opacity(dark ? 0.78 : 0.82)
    }

    // MARK: Shared world colours

    static func base(dark: Bool) -> Color {
        dark ? rgb(0.06, 0.15, 0.11) : rgb(0.58, 0.79, 0.57)
    }
    static func road(dark: Bool) -> Color {
        dark ? rgb(0.24, 0.28, 0.24) : rgb(0.95, 0.92, 0.80)
    }
    static func rock(dark: Bool) -> Color {
        dark ? rgb(0.22, 0.26, 0.24) : rgb(0.62, 0.64, 0.58)
    }
    /// The mist over a region that hasn't opened yet.
    static func fog(dark: Bool) -> Color {
        dark ? rgb(0.04, 0.07, 0.09).opacity(0.70) : rgb(0.76, 0.84, 0.77).opacity(0.62)
    }

    // MARK: Object colours (keepsakes, chests, props)

    static let timber = rgb(0.45, 0.32, 0.22)
    static let timberLight = rgb(0.62, 0.45, 0.30)
    static let iron = rgb(0.26, 0.25, 0.24)
    static let roofTile = rgb(0.56, 0.28, 0.24)
    static let lanternGlow = rgb(1.0, 0.85, 0.48)
    static let hive = rgb(0.90, 0.72, 0.32)
    static let hiveDark = rgb(0.78, 0.58, 0.24)
    static let mushroomCap = rgb(0.86, 0.34, 0.32)
    static let mushroomStem = rgb(0.95, 0.92, 0.84)
    static let petalGold = rgb(0.98, 0.78, 0.26)
    static let sunflowerHeart = rgb(0.44, 0.29, 0.14)
    static let wisteria = rgb(0.72, 0.60, 0.92)
    static let foxCoat = rgb(0.88, 0.50, 0.22)
    static let owlFeather = rgb(0.60, 0.48, 0.36)
    static let owlWing = rgb(0.46, 0.36, 0.27)
    static let berry = rgb(0.88, 0.30, 0.32)
    static let stem = rgb(0.30, 0.50, 0.28)
    static let flowerCenter = rgb(0.98, 0.83, 0.30)

    static func pondWater(dark: Bool) -> Color {
        dark ? rgb(0.16, 0.30, 0.44) : rgb(0.42, 0.70, 0.86)
    }
    static func pondEdge(dark: Bool) -> Color {
        dark ? rgb(0.12, 0.22, 0.18) : rgb(0.72, 0.68, 0.48)
    }
    static func glass(dark: Bool) -> Color {
        dark ? rgb(0.42, 0.60, 0.66).opacity(0.55) : rgb(0.78, 0.92, 0.95).opacity(0.9)
    }

    static let petals: [Color] = [
        rgb(0.95, 0.55, 0.65),
        rgb(0.80, 0.60, 0.95),
        rgb(1.00, 0.98, 0.92),
        rgb(0.98, 0.75, 0.35)
    ]

    /// Sprout's face ink: a deep leaf tone that reads on the mascot's green head
    /// in either appearance.
    static let sproutFace = rgb(0.10, 0.18, 0.10)
    /// Night fireflies, daytime drifting leaves, and sunlit pollen motes.
    static let firefly = rgb(0.78, 0.95, 0.55)
    static let driftingLeaf = rgb(0.36, 0.60, 0.33)
    static let pollenMote = rgb(1.0, 0.96, 0.78)

    // Kept for the older single-biome call sites.
    static func floraPrimary(dark: Bool) -> Color { floraPrimary(.meadow, dark: dark) }
    static func floraSecondary(dark: Bool) -> Color { floraSecondary(.meadow, dark: dark) }

    // MARK: Growth rings

    // The Journey is drawn as a tree's cross-section on the map's night
    // ground. Fixed in both appearances, like the rooms map, because the hero
    // sets its own lighting.

    /// Fine grain between the chapter rings: what makes the drawing read as
    /// wood rather than a target.
    static let ringGrain = hex(0x132219)
    /// A chapter ring that has not grown yet.
    static let ringLine = hex(0x24372A)
    /// The heart of the tree, where the XP total sits.
    static let ringPith = hex(0x102018)
    /// Chapter names, set along their own rings.
    static let ringLabel = hex(0x8FA894)
    /// A step not reached yet: hollow, the colour of a path not walked.
    static let ringUntravelled = hex(0x58705E)
    /// A chest still sealed behind the step before it.
    static let ringSealedChest = hex(0x8A6A1E)

    private static func hex(_ value: UInt32) -> Color {
        rgb(
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r, green: g, blue: b)
    }
}

// MARK: - Journey

/// The Journey as a tree's cross-section.
///
/// Every chapter is a growth ring. The ring you are on carries its milestones
/// as dots, the rings you have finished are packed into the heart of the tree,
/// and the ones still to come are drawn faintly outside with their names set
/// along them. It sits in Grove's board frame like every other page: night
/// green up top, and a white sheet that rises over it with the ranked list of
/// what to do next.
struct JourneyMapView: View {
    @Environment(GroveStore.self) private var store

    /// A focused entry point can open the Journey and immediately explain the
    /// step it promised. Ordinary Journey links leave this nil.
    let initialMilestoneID: String?

    @State private var selected: JourneyMilestone?
    @State private var didPresentInitialMilestone = false
    @State private var celebration: [JourneyMilestone] = []
    // The level-up takeover is mounted on the app shell, not here: see
    // `GroveCelebrationLayer`. Most levels are crossed during a check-in or in
    // Ask, and an overlay that only existed on this screen missed all of them.
    @State private var chestReward: ChestReward?
    @State private var showingQuests = false
    /// The "how do I get this?" peek for a step the player can't do yet.
    @State private var lockedPreview: JourneyLockedPreview?

    init(initialMilestoneID: String? = nil) {
        self.initialMilestoneID = initialMilestoneID
    }

    private var chapters: [ResolvedChapter] { store.resolvedCampaign() }

    private var quests: [DailyQuest] {
        JourneyQuestBoard.quests(progress: store.gardener, plantsOwned: store.plants.count)
    }

    var body: some View {
        let campaign = chapters
        let activeIndex = JourneyRings.activeIndex(in: campaign)
        let active = campaign[activeIndex]
        let steps = JourneyNextSteps.fastest(in: campaign, plants: store.plants)

        GroveBoardPage {
            JourneyRingsHero(
                campaign: campaign,
                activeIndex: activeIndex,
                xp: store.gardener.xp,
                onTap: tap
            )
        } sheet: {
            GroveTabHeader(title: "Journey", subtitle: levelLine)
            statsRow(active: active)
            if !steps.isEmpty {
                fastestSection(steps)
            }
            ringSection(active)
            questsSection
        }
        .navigationTitle("Journey")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AppRoute.achievements) {
                    GroveHeaderIcon(symbol: "rosette")
                }
                .groveHeaderChip()
                .accessibilityLabel("Badges")
            }
        }
        .groveRootHeaderBar(title: "Journey")
        .task {
            guard !didPresentInitialMilestone,
                  let initialMilestoneID,
                  let initial = store.resolvedMilestone(id: initialMilestoneID),
                  initial.status != .locked,
                  !initial.milestone.isChest
            else { return }

            didPresentInitialMilestone = true
            // Let the page finish entering the navigation stack before asking
            // it to present a sheet, so the push and the sheet don't compete in
            // the same update transaction.
            await Task.yield()
            selected = initial.milestone
        }
        .sheet(item: $selected) { milestone in
            NavigationStack {
                JourneyMilestoneDetailView(milestone: milestone) { awarded in
                    if !awarded.isEmpty { celebration = awarded }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $lockedPreview) { preview in
            NavigationStack {
                JourneyLockedMilestoneSheet(preview: preview) { target in
                    lockedPreview = nil
                    // Let the sheet finish leaving before the next one arrives:
                    // two sheets in the same frame cancel each other out.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        selected = target
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingQuests) {
            NavigationStack { QuestBoardView() }
                .presentationDetents([.large])
        }
        .overlay {
            if let chestReward {
                ChestOpeningView(reward: chestReward) { self.chestReward = nil }
                    .transition(.opacity)
            }
        }
        .overlay {
            if !celebration.isEmpty {
                JourneyStepCelebration(milestones: celebration, progress: store.gardener) { celebration = [] }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: celebration)
        .animation(.easeInOut(duration: 0.25), value: chestReward)
    }

    // MARK: Sheet

    private var levelLine: String {
        let progress = store.gardener
        guard let next = progress.level.next else {
            return "\(progress.level.title) · the top level"
        }
        return "\(progress.level.title) · \(next.xpThreshold - progress.xp) XP to \(next.title)"
    }

    private func statsRow(active: ResolvedChapter) -> some View {
        let unlocked = store.gardener.unlockedBadgeIDs
        let badges = JourneyLibrary.badges.filter { unlocked.contains($0.id) }.count
        let streak = store.displayStreak
        return JourneyStatsRow(cells: [
            .init(label: "Level", value: store.gardener.level.title),
            .init(label: "Steps", value: "\(active.completedCount) of \(active.totalCount)"),
            .init(
                label: "Streak",
                value: streak == 1 ? "1 day" : "\(streak) days",
                tint: streak > 0 ? GroveTheme.streak : GroveTheme.ink
            ),
            .init(label: "Badges", value: "\(badges) of \(JourneyLibrary.badges.count)")
        ])
    }

    private func fastestSection(_ steps: [ResolvedMilestone]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            JourneySectionHeader(
                title: "Fastest way up",
                subtitle: JourneyNextSteps.summary(for: steps, progress: store.gardener)
            )
            VStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, item in
                    Button { tap(item) } label: {
                        JourneyStepRow(
                            item: item,
                            plants: store.plants,
                            emphasised: index == 0
                        )
                    }
                    .buttonStyle(GroveTilePressStyle(haptics: false))
                    if index < steps.count - 1 {
                        GroveRowDivider(inset: JourneyStepRow.tileSize + 14)
                    }
                }
            }
        }
    }

    private func ringSection(_ chapter: ResolvedChapter) -> some View {
        // Chests never gate a chapter, so the count is the steps that do.
        let isLast = chapter.chapter.number == JourneyLibrary.chapters.count
        let subtitle: String
        if chapter.isComplete {
            subtitle = "\(chapter.chapter.title), every step done"
        } else if isLast {
            subtitle = "\(chapter.chapter.title) · \(chapter.completedCount) of \(chapter.totalCount) steps done"
        } else {
            subtitle = "\(chapter.chapter.title) · finish \(JourneyNumber.word(chapter.totalCount)) steps to open the next chapter"
        }
        return VStack(alignment: .leading, spacing: 4) {
            JourneySectionHeader(title: "This chapter", subtitle: subtitle)
            VStack(spacing: 0) {
                ForEach(Array(chapter.milestones.enumerated()), id: \.element.id) { index, item in
                    Button { tap(item) } label: {
                        JourneyRingRow(item: item)
                    }
                    .buttonStyle(GroveTilePressStyle(haptics: false))
                    if index < chapter.milestones.count - 1 {
                        GroveRowDivider(inset: JourneyRingRow.markWidth + 12)
                    }
                }
            }
        }
    }

    private var questsSection: some View {
        let all = quests
        let daily = all.filter { $0.objective != .sweep }
        let done = daily.filter(\.isComplete).count
        return VStack(alignment: .leading, spacing: 4) {
            JourneySectionHeader(
                title: "Today's three",
                subtitle: "\(done) of \(daily.count) done · resets at midnight"
            )
            VStack(spacing: 0) {
                ForEach(Array(all.enumerated()), id: \.element.id) { index, quest in
                    Button {
                        Haptics.tap()
                        showingQuests = true
                    } label: {
                        JourneyQuestRow(quest: quest)
                    }
                    .buttonStyle(GroveTilePressStyle(haptics: false))
                    if index < all.count - 1 {
                        GroveRowDivider(inset: JourneyRingRow.markWidth + 12)
                    }
                }
            }
        }
    }

    // MARK: Taps

    private func tap(_ item: ResolvedMilestone) {
        if item.milestone.isChest {
            switch item.status {
            case .ready:
                Haptics.tap()
                chestReward = store.openChest(item.milestone)
            case .locked:
                Haptics.bump()
                lockedPreview = JourneyLockedPreview.make(for: item, campaign: chapters)
            case .completed, .current:
                break
            }
            return
        }
        // A step behind the current one still completes on its own the moment
        // its real requirement is met, so it opens its own page (which says so
        // and links to the place to do it) rather than a "finish this first".
        // Only a lesson or quiz is truly sequential.
        if item.status == .locked, !JourneyNextSteps.completesOutOfOrder(item, in: chapters) {
            Haptics.bump()
            lockedPreview = JourneyLockedPreview.make(for: item, campaign: chapters)
            return
        }
        Haptics.tap()
        selected = item.milestone
    }
}

// MARK: - Next steps

/// What the player can do about the Journey today, ranked by how far it moves
/// them.
enum JourneyNextSteps {
    /// The shortlist. Chests waiting in any open chapter come first: once a
    /// chapter is finished its ring stops being drawn, and this list is the
    /// only place its last chest can still be opened. Then the steps a single
    /// real action could finish today, biggest reward first. The current step
    /// only makes the list when it is one of those (or a lesson or quiz), so a
    /// thirty-day streak never sits at the top as the "fastest" thing to do.
    static func fastest(in campaign: [ResolvedChapter], plants: [Plant], now: Date = .now, limit: Int = 4) -> [ResolvedMilestone] {
        let open = campaign.filter(\.isUnlocked).flatMap(\.milestones)
        let chests = open.filter { $0.milestone.isChest && $0.status == .ready }
        let doable = open
            .enumerated()
            .filter { _, item in
                guard !item.milestone.isChest, item.status != .completed else { return false }
                if item.status == .current, case .interactive = item.milestone.requirement { return true }
                return isDoableToday(item, plants: plants, now: now)
            }
            .sorted { lhs, rhs in
                lhs.element.milestone.xpReward == rhs.element.milestone.xpReward
                    ? lhs.offset < rhs.offset
                    : lhs.element.milestone.xpReward > rhs.element.milestone.xpReward
            }
            .map { $0.element }
        return chests + doable.prefix(max(0, limit - chests.count))
    }

    /// Whether a locked step finishes the moment its requirement is met, with
    /// no need to wait its turn.
    static func completesOutOfOrder(_ item: ResolvedMilestone, in campaign: [ResolvedChapter]) -> Bool {
        guard campaign.contains(where: { chapter in
            chapter.isUnlocked && chapter.milestones.contains { $0.id == item.id }
        }) else { return false }
        switch item.milestone.requirement {
        case .interactive, .chest: return false
        default: return true
        }
    }

    /// Real actions a person can take today, and only when they are a few
    /// actions away. "Twenty check-ins" is not a fast way up on day one, and a
    /// check-in only counts as doable when a plant is actually due one: Grove
    /// never nudges anyone to photograph a plant early for points.
    private static func isDoableToday(_ item: ResolvedMilestone, plants: [Plant], now: Date) -> Bool {
        let remaining = item.target - item.current
        guard remaining > 0, remaining <= 3 else { return false }
        switch item.milestone.requirement {
        case .checkInsCompleted:
            return !dueForCheckIn(plants, now: now).isEmpty
        case .careLogged, .plantsOwned, .lessonsLearned,
             .distinctLocations, .collectionsCreated, .sitterInvited:
            return true
        case .interactive:
            return item.status == .current
        default:
            return false
        }
    }

    /// Plants whose check-in is due by the end of today, most overdue first.
    static func dueForCheckIn(_ plants: [Plant], now: Date = .now) -> [Plant] {
        let endOfToday = Calendar.current.date(
            byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)
        ) ?? now
        return plants
            .filter { $0.effectiveLifecycleState == .active && $0.nextCheckIn < endOfToday }
            .sorted { $0.nextCheckIn < $1.nextCheckIn }
    }

    /// The line under "Fastest way up": what the list is worth against the
    /// next level.
    static func summary(for steps: [ResolvedMilestone], progress: GardenerProgress) -> String {
        let total = steps.reduce(0) { $0 + $1.milestone.xpReward }
        guard let next = progress.level.next else {
            return "You're at the top level. These still finish the chapter."
        }
        let need = next.xpThreshold - progress.xp
        let these = steps.count == 1 ? "This one" : "These \(JourneyNumber.word(steps.count))"
        if total >= need {
            return "\(these) would take you to \(next.title)"
        }
        return "\(these) \(steps.count == 1 ? "gets" : "get") you \(total) of the \(need) XP you need"
    }

    /// One line of context under a step, in terms of the player's own grove.
    static func detail(for item: ResolvedMilestone, plants: [Plant], now: Date = .now) -> String {
        let remaining = max(0, item.target - item.current)
        switch item.milestone.requirement {
        case .chest:
            return item.status == .ready ? "Ready to open" : item.milestone.blurb
        case .interactive:
            if item.milestone.kind == .quiz { return "One question, under a minute" }
            if let minutes = item.milestone.lessonTopicID.flatMap(LearnLibrary.topic(id:))?.readMinutes {
                return "A \(minutes)-minute read"
            }
            return "A short lesson"
        case .checkInsCompleted:
            // Names, not board codes: "NIG and PEA are due a check-in" is a
            // departures board, not a sentence.
            let due = dueForCheckIn(plants, now: now).map(\.nickname)
            if remaining == 1 {
                if due.count >= 2 { return "\(due[0]) and \(due[1]) are due a check-in" }
                if let first = due.first { return "\(first) is due a check-in" }
                if let next = plants.filter({ $0.effectiveLifecycleState == .active })
                    .min(by: { $0.nextCheckIn < $1.nextCheckIn }) {
                    return "\(next.nickname)'s check-in is due \(next.nextCheckIn.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))"
                }
                return "Add a plant first"
            }
            return "\(item.current) of \(item.target) check-ins"
        case .careLogged:
            return remaining == 1 ? "A trim, a turn or a repot counts" : "\(item.current) of \(item.target) logged"
        case .plantsOwned:
            return "\(item.current) of \(item.target) plants in your grove"
        case .lessonsLearned:
            return "\(item.current) of \(item.target) lessons"
        case .distinctLocations:
            return "Plants in \(item.current) of \(item.target) rooms"
        case .collectionsCreated:
            return "\(item.current) of \(item.target) collections"
        case .sitterInvited:
            return "Hand a plant to someone you trust"
        default:
            return item.showsProgress ? "\(item.current) of \(item.target)" : item.milestone.blurb
        }
    }

    /// The short verb a step's tile carries, in the board's code style.
    static func tileCode(for milestone: JourneyMilestone) -> String {
        switch milestone.requirement {
        case .interactive: return milestone.kind == .quiz ? "QUIZ" : "READ"
        case .careLogged: return "LOG"
        case .checkInsCompleted, .deepestTimeline: return "CHECK"
        case .plantsOwned: return "ADD"
        case .distinctLocations: return "ROOM"
        case .collectionsCreated: return "SET"
        case .sitterInvited, .sitterCareCompleted: return "SIT"
        case .lessonsLearned: return "READ"
        case .streakReached: return "DAYS"
        case .chest: return "CHEST"
        default: return "GOAL"
        }
    }
}

enum JourneyNumber {
    /// Small counts read as words in a sentence, the way a person writes them.
    static func word(_ value: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        return words.indices.contains(value) ? words[value] : "\(value)"
    }
}

// MARK: - Sheet rows

/// A board section heading: the title, and the one fact that explains it.
struct JourneySectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Small caps over values, four across, with the board's hairline beneath.
private struct JourneyStatsRow: View {
    struct Cell: Identifiable {
        let label: String
        let value: String
        var tint: Color = GroveTheme.ink
        var id: String { label }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let cells: [Cell]

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) { cellViews(cells) }
            } else if dynamicTypeSize >= .xLarge {
                // Four across stops fitting "Grove Keeper" before text gets
                // large enough to stack, so two rows of two bridge the gap.
                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 14) {
                    ForEach(Array(stride(from: 0, to: cells.count, by: 2)), id: \.self) { start in
                        GridRow { cellViews(Array(cells[start..<min(start + 2, cells.count)])) }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 10) { cellViews(cells) }
            }
        }
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) {
            Rectangle().fill(GroveTheme.separator).frame(height: 1)
        }
    }

    private func cellViews(_ cells: [Cell]) -> some View {
        ForEach(cells) { cell in
            GroveStatCell(label: cell.label, value: cell.value, tint: cell.tint)
        }
    }
}

/// One step in "Fastest way up": its tile, what it is, why now, and its worth.
private struct JourneyStepRow: View {
    static let tileSize: CGFloat = 48

    let item: ResolvedMilestone
    let plants: [Plant]
    /// The top of the list: its reward is set in ink rather than muted.
    var emphasised = false

    private var isReadyChest: Bool { item.milestone.isChest && item.status == .ready }

    private var lookPlant: Plant? {
        guard case .checkInsCompleted = item.milestone.requirement else { return nil }
        return JourneyNextSteps.dueForCheckIn(plants).first
            ?? plants.min { $0.nextCheckIn < $1.nextCheckIn }
    }

    var body: some View {
        HStack(spacing: 14) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                Text(isReadyChest ? "Open your chest" : item.milestone.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .lineLimit(2)
                Text(JourneyNextSteps.detail(for: item, plants: plants))
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isReadyChest {
                GroveInkLabel(title: "Open", size: .compact)
            } else {
                Text("+\(item.milestone.xpReward) XP")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(emphasised ? GroveTheme.ink : GroveTheme.mutedInk)
                GroveRowChevron()
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var tile: some View {
        if let lookPlant {
            PlantThumbnail(plant: lookPlant, height: Self.tileSize, maxDimension: 200)
                .frame(width: Self.tileSize, height: Self.tileSize)
                .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                .accessibilityHidden(true)
        } else {
            JourneyMilestoneTile(milestone: item.milestone, size: Self.tileSize)
        }
    }

    private var accessibilityText: String {
        let detail = JourneyNextSteps.detail(for: item, plants: plants)
        if isReadyChest { return "Open your chest. \(detail)" }
        return "\(item.milestone.title). \(detail). \(item.milestone.xpReward) XP"
    }
}

/// One step of the current ring, as a list: the same states the dots draw.
private struct JourneyRingRow: View {
    static let markWidth: CGFloat = 22

    let item: ResolvedMilestone

    private var isDone: Bool { item.status == .completed }
    private var isReadyChest: Bool { item.milestone.isChest && item.status == .ready }

    private var title: String {
        guard item.milestone.isChest else { return item.milestone.title }
        switch item.status {
        case .ready: return "A chest is waiting"
        case .completed: return "Chest opened"
        default: return "A chest"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            mark.frame(width: Self.markWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(item.status == .current ? .body.weight(.semibold) : .body)
                    .foregroundStyle(isDone ? GroveTheme.mutedInk : GroveTheme.ink)
                    .lineLimit(2)
                if item.status == .current {
                    Text(item.milestone.blurb)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = ["\(title), \(JourneyRingDot.statusWord(item))"]
        if item.status == .current { parts.append(item.milestone.blurb) }
        if !isDone, !item.milestone.isChest { parts.append("\(item.milestone.xpReward) XP") }
        return parts.joined(separator: ". ")
    }

    @ViewBuilder
    private var mark: some View {
        if item.milestone.isChest {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isDone ? GroveTheme.accent : (isReadyChest ? GroveTheme.gold : Color.clear))
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(isReadyChest || isDone ? Color.clear : GroveTheme.goldDeep.opacity(0.5), lineWidth: 1.5)
                }
                .frame(width: 11, height: 11)
                .background {
                    if isReadyChest {
                        Circle().fill(GroveTheme.gold.opacity(0.25)).frame(width: 22, height: 22)
                    }
                }
        } else {
            switch item.status {
            case .completed:
                Circle().fill(GroveTheme.accent).frame(width: 9, height: 9)
            case .current:
                Circle().stroke(GroveTheme.ink, lineWidth: 2.5).frame(width: 11, height: 11)
            default:
                Circle().stroke(GroveTheme.subtleInk.opacity(0.55), lineWidth: 1.5).frame(width: 8, height: 8)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isReadyChest {
            GroveInkLabel(title: "Open", size: .compact)
        } else if isDone {
            Text("Done")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GroveTheme.accent)
            if !item.milestone.isChest { GroveRowChevron() }
        } else {
            Text("+\(item.milestone.xpReward) XP")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(item.status == .current ? GroveTheme.ink : GroveTheme.mutedInk)
            GroveRowChevron()
        }
    }
}

private struct JourneyQuestRow: View {
    let quest: DailyQuest

    var body: some View {
        HStack(spacing: 12) {
            mark.frame(width: JourneyRingRow.markWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(quest.title)
                    .font(.body)
                    .foregroundStyle(quest.isClaimed ? GroveTheme.mutedInk : GroveTheme.ink)
                    .lineLimit(2)
                if quest.objective == .sweep {
                    Text(quest.detail)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if quest.isClaimable {
                GroveInkLabel(title: "Collect", size: .compact)
            } else {
                Text("+\(quest.xp) XP")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(quest.objective == .sweep ? GroveTheme.goldDeep : GroveTheme.mutedInk)
                GroveRowChevron()
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var mark: some View {
        if quest.isClaimed {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(GroveTheme.accent)
        } else {
            Circle()
                .stroke(
                    quest.isComplete ? GroveTheme.gold : GroveTheme.subtleInk.opacity(0.45),
                    lineWidth: 1.5
                )
                .overlay {
                    if !quest.isComplete, quest.fraction > 0 {
                        Circle()
                            .trim(from: 0, to: quest.fraction)
                            .stroke(GroveTheme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }
                .frame(width: 20, height: 20)
        }
    }

    private var accessibilityText: String {
        if quest.isClaimed { return "\(quest.title), collected" }
        if quest.isClaimable { return "\(quest.title), done. Collect \(quest.xp) XP" }
        return "\(quest.title), \(quest.xp) XP"
    }
}

// MARK: - Rings hero

/// Which ring is growing and where everything on it sits.
enum JourneyRings {
    /// The chapter being played: the first open, unfinished one. Once every
    /// chapter is done the last ring stays the subject, fully drawn.
    static func activeIndex(in campaign: [ResolvedChapter]) -> Int {
        campaign.firstIndex { $0.isUnlocked && !$0.isComplete } ?? max(0, campaign.count - 1)
    }
}

/// The night-green hero: the tree's cross-section, the current ring's steps as
/// tappable dots, and the chapter's name low and left.
private struct JourneyRingsHero: View {
    let campaign: [ResolvedChapter]
    let activeIndex: Int
    let xp: Int
    let onTap: (ResolvedMilestone) -> Void

    static let height: CGFloat = 404
    /// The ring being played is always drawn at the same size, so its steps
    /// never crowd: finished chapters pack inward towards the heart, the way a
    /// tree's oldest wood does, and future chapters sit outside it.
    static let activeRadius: CGFloat = 64
    static let pithRadius: CGFloat = 32
    /// The top of the band chapter names may sit in: below the status bar and
    /// the bar's chips on every phone.
    static let labelBandTop: CGFloat = 112

    private var active: ResolvedChapter { campaign[activeIndex] }

    private func center(in width: CGFloat) -> CGPoint {
        CGPoint(x: width * 0.62, y: 196)
    }

    /// Distance between chapter rings. Narrower phones pack them closer so
    /// the outermost ring's name still lands on screen.
    private func ringSpacing(in width: CGFloat) -> CGFloat {
        min(38, max(28, (width * 0.62 - Self.activeRadius - 40) / 4))
    }

    /// Where a chapter's name sits on its ring. One shared angle would put
    /// the outer names under the clock, so each one is placed by height: the
    /// further out the ring, the lower and further left its name, which
    /// reads as a diagonal of labels running out from the heart.
    private func labelAngle(radius: CGFloat, center c: CGPoint) -> Double {
        let targetY = Self.labelBandTop + (radius - Self.activeRadius) * 0.3
        let lift = min(0.95, max(0, (c.y - targetY) / radius))
        return -.pi + asin(Double(lift))
    }

    /// Angle of step `index` on the active ring, from twelve o'clock clockwise.
    private func angle(_ index: Int) -> Double {
        let count = max(1, active.milestones.count)
        return (-90 + 360 * Double(index) / Double(count)) * .pi / 180
    }

    private func point(_ index: Int, center: CGPoint) -> CGPoint {
        let theta = angle(index)
        return CGPoint(
            x: center.x + Self.activeRadius * cos(theta),
            y: center.y + Self.activeRadius * sin(theta)
        )
    }

    /// How many steps from the start are behind the player, counting a chest
    /// waiting to be opened as reached.
    private var reachedCount: Int {
        var count = 0
        for item in active.milestones {
            guard item.status == .completed || item.status == .ready else { break }
            count += 1
        }
        return count
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let c = center(in: width)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawRings(in: &context, center: c, spacing: ringSpacing(in: width))
                }
                .accessibilityHidden(true)

                // A scrim under the caption, so the outer rings fade out behind
                // the words instead of running through them.
                LinearGradient(
                    stops: [
                        .init(color: GroveTheme.mapGround.opacity(0), location: 0),
                        .init(color: GroveTheme.mapGround, location: 0.55)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.7),
                            .init(color: .black.opacity(0), location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .frame(width: width * 0.62, height: 160)
                .position(x: width * 0.31, y: proxy.size.height - 80)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                VStack(spacing: 0) {
                    Text("\(xp)")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(value: Double(xp)))
                        .minimumScaleFactor(0.6)
                    Text("XP")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(GroveTheme.mapLabel)
                }
                // The pith is a fixed 56pt drawing, so its type is held at the
                // size the drawing was made for.
                .frame(width: (Self.pithRadius - 6) * 2)
                .dynamicTypeSize(...DynamicTypeSize.large)
                .position(c)
                .accessibilityHidden(true)

                // The dots are the picture's way in for a finger. VoiceOver
                // gets the same steps in reading order from the chapter list
                // on the sheet, rather than a zigzag round a circle.
                ForEach(Array(active.milestones.enumerated()), id: \.element.id) { index, item in
                    Button { onTap(item) } label: {
                        JourneyRingDot(item: item)
                    }
                    .buttonStyle(GroveTilePressStyle(haptics: false))
                    .position(point(index, center: c))
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(height: Self.height)
        .overlay(alignment: .bottomLeading) {
            caption
                .allowsHitTesting(false)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heroSummary)
    }

    private var heroSummary: String {
        let done = active.completedCount
        return "Chapter \(active.chapter.number) of \(campaign.count), \(active.chapter.title). \(done) of \(active.totalCount) steps done. \(xp) XP."
    }

    private var caption: some View {
        let allDone = campaign.allSatisfy(\.isComplete)
        return VStack(alignment: .leading, spacing: 5) {
            Text((allDone ? "All \(campaign.count) chapters" : "Chapter \(active.chapter.number) of \(campaign.count)").uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(GroveTheme.mapCaption)
            Text(active.chapter.title)
                .font(GroveTheme.display(GroveDisplayStyle.heading.points))
                .tracking(-0.4)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text(active.chapter.theme)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mapCaption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, GroveTheme.pagePadding)
        .padding(.trailing, 40)
        .padding(.bottom, GroveBoardPage<EmptyView, EmptyView>.overlap + 18)
        .accessibilityElement(children: .combine)
    }

    // MARK: Drawing

    private func drawRings(in context: inout GraphicsContext, center c: CGPoint, spacing: CGFloat) {
        let grown = Array(campaign.prefix(activeIndex))
        let future = Array(campaign.dropFirst(activeIndex + 1))

        // Radii, inside out.
        let grownRadii: [CGFloat] = grown.indices.map { index in
            Self.pithRadius + (Self.activeRadius - Self.pithRadius) * CGFloat(index + 1) / CGFloat(grown.count + 1)
        }
        let futureRadii: [CGFloat] = future.indices.map { Self.activeRadius + spacing * CGFloat($0 + 1) }
        // Two rings of bark beyond the last chapter so the tree runs off the
        // edges of the screen instead of ending in a neat circle.
        let outermost = futureRadii.last ?? Self.activeRadius
        let bark = [outermost + spacing, outermost + spacing * 2]

        // Grain: two faint rings between every pair of rings outside the
        // active one.
        let outer = [Self.activeRadius] + futureRadii + bark
        for (inner, next) in zip(outer, outer.dropFirst()) {
            for step in [1.0 / 3.0, 2.0 / 3.0] {
                let radius = inner + (next - inner) * step
                context.stroke(ring(radius, center: c), with: .color(JourneyWorld.ringGrain), lineWidth: 1)
            }
        }
        for radius in futureRadii + bark {
            context.stroke(
                ring(radius, center: c),
                with: .color(bark.contains(radius) ? JourneyWorld.ringGrain : JourneyWorld.ringLine),
                lineWidth: 1
            )
        }

        // Finished chapters: earned wood, in the green of a plant doing well.
        for radius in grownRadii {
            context.stroke(
                Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(GroveTheme.mapThriving.opacity(0.45)),
                lineWidth: 1.5
            )
        }

        // The ring being played: a track, and the distance travelled round it.
        let activeRect = CGRect(
            x: c.x - Self.activeRadius,
            y: c.y - Self.activeRadius,
            width: Self.activeRadius * 2,
            height: Self.activeRadius * 2
        )
        context.stroke(Path(ellipseIn: activeRect), with: .color(GroveTheme.mapRoom), lineWidth: 2)
        let count = max(1, active.milestones.count)
        if reachedCount >= count {
            context.stroke(Path(ellipseIn: activeRect), with: .color(GroveTheme.mapThriving), lineWidth: 2.8)
        } else if reachedCount > 1 {
            var arc = Path()
            arc.addArc(
                center: c,
                radius: Self.activeRadius,
                startAngle: .radians(angle(0)),
                endAngle: .radians(angle(reachedCount - 1)),
                clockwise: false
            )
            context.stroke(arc, with: .color(GroveTheme.mapThriving), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
        }

        // The heart of the tree.
        context.fill(
            Path(ellipseIn: CGRect(
                x: c.x - Self.pithRadius + 4,
                y: c.y - Self.pithRadius + 4,
                width: (Self.pithRadius - 4) * 2,
                height: (Self.pithRadius - 4) * 2
            )),
            with: .color(JourneyWorld.ringPith)
        )

        for (chapter, radius) in zip(future, futureRadii) {
            drawLabel(chapter.chapter.title, radius: radius + 3, center: c, in: &context)
        }
    }

    /// A ring a little off-centre and a little oval, more so the further out
    /// it grows: real trees don't put on wood evenly.
    private func ring(_ radius: CGFloat, center c: CGPoint) -> Path {
        let drift = max(0, radius - Self.activeRadius)
        let origin = CGPoint(x: c.x + drift * 0.04, y: c.y - drift * 0.027)
        let squash = radius * (drift > 0 ? 0.975 : 1)
        return Path(ellipseIn: CGRect(x: origin.x - radius, y: origin.y - squash, width: radius * 2, height: squash * 2))
    }

    /// Sets a chapter's name along its ring, one letter at a time.
    private func drawLabel(_ title: String, radius: CGFloat, center c: CGPoint, in context: inout GraphicsContext) {
        let tracking: CGFloat = 1.6
        let letters = title.uppercased().map { letter in
            context.resolve(
                Text(String(letter))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(JourneyWorld.ringLabel)
            )
        }
        let widths = letters.map { $0.measure(in: CGSize(width: 40, height: 40)).width }
        let length = widths.reduce(0, +) + tracking * CGFloat(max(0, widths.count - 1))
        var theta = labelAngle(radius: radius, center: c) - Double(length / radius) / 2
        for (letter, width) in zip(letters, widths) {
            let half = Double(width / 2 / radius)
            theta += half
            var copy = context
            copy.translateBy(x: c.x + radius * cos(theta), y: c.y + radius * sin(theta))
            copy.rotate(by: .radians(theta + .pi / 2))
            copy.draw(letter, at: .zero, anchor: .bottom)
            theta += half + Double(tracking / radius)
        }
    }
}

/// One step on the ring. The drawing is small; the target is not.
private struct JourneyRingDot: View {
    let item: ResolvedMilestone

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    static func statusWord(_ item: ResolvedMilestone) -> String {
        switch item.status {
        case .completed: item.milestone.isChest ? "opened" : "done"
        case .ready: "ready to open"
        case .current: "next step"
        case .locked: "not yet"
        }
    }

    private var breathes: Bool {
        !reduceMotion && (item.status == .current || item.status == .ready)
    }

    var body: some View {
        ZStack {
            if breathes {
                RoundedRectangle(cornerRadius: item.status == .ready ? 4 : 7, style: .continuous)
                    .fill(item.status == .ready ? GroveTheme.gold : Color.white)
                    .frame(width: 14, height: 14)
                    .scaleEffect(breathing ? 2.2 : 1)
                    .opacity(breathing ? 0 : 0.35)
            }
            mark
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        // Keyed on the state rather than on appear, so a step that becomes
        // current while the page is open starts breathing straight away.
        .onChange(of: breathes, initial: true) { _, shouldBreathe in
            breathing = false
            guard shouldBreathe else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                breathing = true
            }
        }
    }

    @ViewBuilder
    private var mark: some View {
        let ground = GroveTheme.mapGround
        if item.milestone.isChest {
            switch item.status {
            case .ready:
                // A chest is always square, so it never depends on gold versus
                // green alone to read differently from a finished step.
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(GroveTheme.gold)
                    .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).stroke(ground, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(GroveTheme.gold.opacity(0.18))
                            .frame(width: 28, height: 28)
                    )
            case .completed:
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(GroveTheme.mapThriving)
                    .frame(width: 11, height: 11)
            default:
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(ground)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(JourneyWorld.ringSealedChest, lineWidth: 1.5))
                    .frame(width: 11, height: 11)
            }
        } else {
            switch item.status {
            case .completed:
                Circle()
                    .fill(GroveTheme.mapThriving)
                    .overlay(Circle().stroke(ground, lineWidth: 2))
                    .frame(width: 12, height: 12)
            case .current:
                Circle()
                    .fill(ground)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
                    .frame(width: 14, height: 14)
            default:
                Circle()
                    .fill(ground)
                    .overlay(Circle().stroke(JourneyWorld.ringUntravelled, lineWidth: 1.5))
                    .frame(width: 8, height: 8)
            }
        }
    }
}

// MARK: - Celebration

/// A finished step, in the Journey's one celebration frame: the ring drawn
/// complete, and the facts of what changed.
private struct JourneyStepCelebration: View {
    let milestones: [JourneyMilestone]
    let progress: GardenerProgress
    let onDismiss: () -> Void

    private var totalXP: Int { milestones.reduce(0) { $0 + $1.xpReward } }
    private var headline: JourneyMilestone? { milestones.max { $0.xpReward < $1.xpReward } }
    private var badge: Badge? {
        milestones.compactMap(\.badgeID).compactMap(JourneyLibrary.badge(id:)).first
    }

    var body: some View {
        JourneyTakeover(
            eyebrow: milestones.count > 1 ? "\(JourneyNumber.word(milestones.count).capitalized) steps done" : "Step done",
            title: headline?.title ?? "Step done",
            message: badge.map { "You earned the \($0.title) badge." },
            primaryTitle: "Done",
            onPrimary: onDismiss
        ) {
            JourneyRingMark()
        } details: {
            JourneyFactRow(facts: facts)
        }
    }

    private var facts: [JourneyFactRow.Fact] {
        var facts: [JourneyFactRow.Fact] = [
            .init(label: "XP earned", value: "+\(totalXP)", tint: GroveTheme.gold),
            .init(label: "Level", value: progress.level.title)
        ]
        if let next = progress.level.next {
            facts.append(.init(label: "To \(next.title)", value: "\(next.xpThreshold - progress.xp) XP"))
        }
        return facts
    }
}

// The level-up takeover lives in `JourneyLevelUpTakeover.swift` and is shown
// by `GroveCelebrationLayer` from the app shell.
