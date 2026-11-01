import SwiftUI
import UIKit

private enum TodaySheet: Identifiable {
    case seasonal(GroveLocation)

    var id: String { "seasonal" }
}

/// Home / Today, as a departures board: the plant that needs you most in its
/// own photograph, then the day's jobs you can tick off where they stand, then
/// every plant on one anatomy, split by whether it needs you.
///
/// The page used to be eleven blocks and three and a half screens tall, with
/// the first genuinely due task about fourteen hundred points down. The order
/// below is the answer to one question: *what do I do now, and is my grove
/// alright?* Anything that does not answer it either scrolls beneath the
/// answer or lives on the tab that owns it.
///
/// Only plants in active care are drawn. Archived, remembered and dormant
/// plants keep their pages in My Grove; on Today they would be counted, mapped
/// and ringed green as though they were thriving.
struct TodayView: View {
    @Environment(GroveStore.self) private var store
    @Environment(IntentRouter.self) private var intentRouter
    @Environment(SyncEngine.self) private var syncEngine: SyncEngine?
    @Environment(ConnectivityMonitor.self) private var connectivity: ConnectivityMonitor?
    /// Owned by the app shell, which also loads it. Today draws the sky; it no
    /// longer decides whether the rest of the app knows anything about it.
    @Environment(WeatherService.self) private var weather
    @State private var travel = TravelWatcher()
    /// Mirrors `travel.promptableTrip(store:)` so dismissing the banner can
    /// animate it away in the same runloop the tap happens in, rather than
    /// waiting on the next refresh to agree.
    @State private var promptedTrip: AwayTrip?
    /// The same trip, once it has gone on long enough to be a move worth asking
    /// about. Mutually exclusive with `promptedTrip`: see `refreshTravel`.
    @State private var movePrompt: AwayTrip?
    /// Today has one local layer. The selected value carries the location the
    /// layer was opened for, so presentation never has to recover it with an
    /// optional check after the tap.
    @State private var presentedSheet: TodaySheet?

    var body: some View {
        let plants = store.activePlants
        let entries = TodayBoardEntry.board(
            plants: plants,
            siblings: store.plants,
            nextTask: { store.nextPendingTask(for: $0) },
            tasks: store.tasks
        )
        let activeIDs = Set(plants.map(\.id))
        let due = store.dueTasks.filter { activeIDs.contains($0.plantID) }

        // The same anatomy as Ask, Friends and My Grove: header, one hero card,
        // then sections. Today's hero is the plant that needs you most.
        return GroveBoardPage {
            mapHero(entries: entries)
        } sheet: {
            boardContent(entries: entries, due: due)
        }
        .refreshable { await refresh() }
        .grovePreparesHaptics()
        .toolbar {
            // No streak yet: leave the slot empty rather than show a "0" flame.
            if store.displayStreak > 0 {
                ToolbarItem(placement: .topBarLeading) {
                    GroveHeaderStreak().groveHeaderChip()
                }
            }
            if let location = store.profile.location {
                ToolbarItem(placement: .topBarTrailing) {
                    SeasonalWeatherButton(
                        phase: weather.phase,
                        usesMetric: usesMetric,
                        primaryAdvisory: seasonalAdvisories.first,
                        bare: true
                    ) {
                        presentedSheet = .seasonal(location)
                    }
                    .groveHeaderChip()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AppRoute.activity) {
                    GroveHeaderIcon(symbol: "bell", showsBadge: store.hasUnseenActivity)
                }
                .groveHeaderChip()
                .accessibilityLabel("Updates")
                // The dot is drawn, so it has to be spoken too.
                .accessibilityValue(store.hasUnseenActivity ? "New updates" : "")
            }
        }
        .groveRootHeaderBar(title: "Today")
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .seasonal(let location):
                SeasonalAdviceSheet(location: location)
            }
        }
        // Re-checked on every appearance rather than once per launch: the phone
        // usually settles into the new time zone minutes after landing, long
        // after Grove was first opened that day.
        .task(id: travelTaskID) { await refreshTravel() }
        // The phone usually only settles into the new zone some minutes after
        // landing, often while Grove is already open in the arrivals queue.
        // Without this the banner would wait for the next cold launch.
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            Task { await refreshTravel() }
        }
    }

    // MARK: - Board

    /// The white sheet over the hero: the page's name, where the grove lives,
    /// the day's jobs, then every plant on one anatomy, split by whether it
    /// needs you.
    private func boardContent(entries: [TodayBoardEntry], due: [CareTask]) -> some View {
        // One order for the hero and the list, so the plant in the photograph
        // is always the first row under "Needs you".
        let needs = entries.filter(\.needsYou).sorted(by: TodayBoardEntry.byUrgency)
        let onTrack = entries.filter { !$0.needsYou }.sorted(by: TodayBoardEntry.byUrgency)

        return VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
            GroveTabHeader(title: "Today") {
                groveLocationLink
            }

            TodayOnboardingChecklist()

            if let movePrompt {
                MovedBanner(trip: movePrompt) {
                    travel.dismissMove(movePrompt)
                    withAnimation(GroveMotion.snap) { self.movePrompt = nil }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let promptedTrip {
                TravelBanner(trip: promptedTrip) {
                    travel.dismiss(promptedTrip)
                    withAnimation(GroveMotion.snap) { self.promptedTrip = nil }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if entries.isEmpty {
                firstPlant.groveReveal(0)
            } else {
                // The work itself, finishable where it stands. The plant
                // sections below say who needs you; this says what to do, with
                // the tick right there.
                if !due.isEmpty {
                    TodayDueSection(tasks: due).groveReveal(1)
                }

                if !needs.isEmpty {
                    TodayBoardSection(
                        title: "Needs you",
                        subtitle: needs.count == 1 ? "1 plant needs you today" : "\(needs.count) plants need you today",
                        entries: needs,
                        showsStatus: true
                    )
                    .groveReveal(2)
                }

                if !onTrack.isEmpty {
                    TodayBoardSection(
                        title: needs.isEmpty ? "All on track" : "On track",
                        subtitle: onTrackSubtitle(onTrack),
                        entries: onTrack
                    )
                    .groveReveal(3)
                }

                // The lists say what to do; the map says where. One plant has
                // no "where" worth drawing, so it waits for the second.
                if entries.count > 1 {
                    TodayRoomMap(entries: entries).groveReveal(4)
                }

                TodayQuickScanActions().groveReveal(5)
                JourneyHeroCard(presentation: .adaptive).groveReveal(6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Today's hero: the plant that needs you most, in its own photograph,
    /// lit by the hour, with one sentence that says what to do. The rooms map
    /// it replaced was a diagram of the home; this is a window into it.
    @ViewBuilder
    private func mapHero(entries: [TodayBoardEntry]) -> some View {
        let ordered = entries.sorted(by: TodayBoardEntry.byUrgency)
        if let lead = ordered.first {
            TodayWindowHero(
                lead: lead,
                others: Array(ordered.dropFirst()),
                atmosphere: GroveAtmosphere.at(.now, timeZone: groveTimeZone)
            )
        } else {
            GroveNightHero {
                GroveEyebrow(text: "Your home", color: GroveTheme.mapLabel)
                Text("Your first plant lights up here.")
                    .font(GroveTheme.display(GroveDisplayStyle.heading.points))
                    .foregroundStyle(GroveTheme.ink)
            }
        }
    }

    private func onTrackSubtitle(_ entries: [TodayBoardEntry]) -> String {
        guard let next = entries.map(\.summary.dueDate).min() else { return "Nothing owed" }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: next)).day ?? 0
        switch days {
        case ...0: return "Nothing else owed today"
        case 1: return "Nothing owed until tomorrow"
        case 2...6: return "Nothing owed until \(next.formatted(.dateTime.weekday(.wide)))"
        default: return "Nothing owed until \(next.formatted(.dateTime.day().month(.wide)))"
        }
    }

    // MARK: - Location line

    /// The date and the grove's place, on one line where they fit and two
    /// where they don't. The whole row is the target; the chevron is the offer.
    private var groveLocationLink: some View {
        let location = store.profile.location

        return NavigationLink(value: AppRoute.groveLocation) {
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        dateLabel
                        Text("·").foregroundStyle(GroveTheme.subtleInk)
                        placeLabel(location)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        dateLabel
                        placeLabel(location)
                    }
                }
                .font(.subheadline.weight(.medium))

                if let caption = locationCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(location == nil ? "Set location" : "Change location")
    }

    /// The phone's own day, not the grove's. Every "Today", "Tomorrow" and
    /// "late" on the board, the badge and the reminders count days on the
    /// phone's calendar; a date line in the grove's zone said Wednesday over
    /// rows still doing Tuesday's work whenever the owner was away across
    /// midnight.
    private var dateLabel: some View {
        Text(TodayMasthead.dateLine(timeZone: .current))
            .foregroundStyle(GroveTheme.mutedInk)
            .lineLimit(1)
    }

    private func placeLabel(_ location: GroveLocation?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: location == nil ? "location" : "location.fill")
                .font(.caption.weight(.semibold))
            Text(location?.label ?? "Set your location")
                .lineLimit(1)
            Image(systemName: location == nil ? "chevron.right" : "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(GroveTheme.subtleInk)
        }
        .foregroundStyle(location == nil ? GroveTheme.accentStrong : GroveTheme.ink)
    }

    /// The hour the grove is living in, for the hero's light. The light is
    /// about the window the plant stands in, so it follows the plant.
    private var groveTimeZone: TimeZone {
        if let identifier = store.profile.location?.timeZoneIdentifier,
           let timeZone = TimeZone(identifier: identifier) {
            return timeZone
        }
        return .current
    }

    /// Why Today is naming a place the reader is not standing in.
    ///
    /// Silent when the phone and the grove agree, which is nearly always: a
    /// caption under every location label would be explaining a thing nobody had
    /// asked about. It appears only in the two cases that actually confused
    /// people: opening Grove from somewhere else, where a fixed home label
    /// looks exactly like an app that failed to notice you moved, and the very
    /// first run, where the reason to answer at all used to live in a card
    /// further down the page.
    private var locationCaption: String? {
        guard store.profile.location != nil else {
            return "Weather for where your plants live, not where you are."
        }
        guard travel.trip != nil else { return nil }
        return "You're away. This is where your plants live."
    }

    private func refreshTravel() async {
        await travel.refresh(store: store)
        let moved = travel.movedPrompt()
        withAnimation(GroveMotion.snap) {
            movePrompt = moved
            // One banner at a time, and after a fortnight the useful question
            // is no longer "shall I find you a sitter?".
            promptedTrip = moved == nil ? travel.promptableTrip(store: store) : nil
        }
    }

    private func refresh() async {
        if let syncEngine {
            await syncEngine.synchronize(store: store, isConnected: connectivity?.isConnected ?? false)
        }
        if let location = store.profile.location {
            await weather.load(for: location.coordinate)
        }
    }

    private var usesMetric: Bool {
        store.profile.usesMetricSystem ?? (Locale.current.measurementSystem == .metric)
    }

    /// Everything the answer depends on: where home is, what zone the phone is
    /// in now, and whether sitting has since been arranged.
    private var travelTaskID: String {
        let home = store.profile.location.map { "\($0.latitude),\($0.longitude)" } ?? "none"
        return "\(home),\(TimeZone.current.identifier),\(store.hasSittingCover())"
    }

    // MARK: - Seasonal

    /// What this week's sky means for these plants. The rules stay outside the
    /// view so Today, Ask and future notifications can share one answer.
    private var seasonalAdvisories: [GroveSkyAdvisory] {
        guard case .loaded(let forecast) = weather.phase else { return [] }
        return GroveSky.advisories(
            forecast: forecast,
            plants: store.activePlants,
            profile: store.profile
        )
    }

    // MARK: - First plant

    /// The single highest-intent state in the app: someone is looking at Grove
    /// with nothing in it. Everything below the hero is one instruction.
    private var firstPlant: some View {
        GroveEmptyState(
            scene: .firstPlant,
            customArt: AnyView(WindowsillScene().frame(maxWidth: 220)),
            title: "Add your first plant",
            message: "Scan a plant to identify it, check its health, and set up its care."
        ) {
            NavigationLink(value: AppRoute.liveScan(.add, nil)) {
                GroveScanCTALabel()
            }
            .buttonStyle(GroveScanCTAStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .groveCard()
    }
}

// MARK: - Due today

/// The day's jobs, each one finishable where it stands.
///
/// For a while the live board listed plants and nothing else: the tick-off
/// rows, the queue and its front door all lived in a feed nothing drew, so the
/// badge counted work the home screen gave no way to see or finish. This
/// brings the rows back, in the board's own anatomy: a heading with the fact
/// that explains it, then bare rows on hairlines rather than another card on
/// the sheet. A few rows, then the rest is one line into the full schedule;
/// the heading's trailing link is the schedule's permanent front door.
private struct TodayDueSection: View {
    let tasks: [CareTask]

    /// Three rows fit above the plant sections without pushing them off the
    /// first screen. Past that the list is a queue, and the queue has a page.
    private static let visibleLimit = 3

    private var plantCount: Int { Set(tasks.map(\.plantID)).count }

    private var subtitle: String {
        if tasks.count == 1 { return "1 job" }
        if plantCount == 1 { return "\(tasks.count) jobs for one plant" }
        return "\(tasks.count) jobs across \(plantCount) plants"
    }

    var body: some View {
        let visible = Array(tasks.prefix(Self.visibleLimit))
        let hidden = tasks.count - visible.count

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Due today")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(GroveTheme.ink)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 8)

                NavigationLink(value: AppRoute.care) {
                    HStack(spacing: 3) {
                        Text("Schedule")
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GroveTheme.accentStrong)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Care schedule")
                .accessibilityHint("Opens everything due and coming up")
                .accessibilityIdentifier("todayQueueLink")
            }

            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { GroveRowDivider() }
                    CareTaskRow(task: task)
                }
                if hidden > 0 {
                    GroveRowDivider()
                    NavigationLink(value: AppRoute.care) {
                        HStack {
                            Text(hidden == 1 ? "1 more due today" : "\(hidden) more due today")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(GroveTheme.ink)
                            Spacer(minLength: 8)
                            GroveRowChevron()
                        }
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens your care schedule")
                }
            }
        }
    }
}

// MARK: - Quick scan

/// The camera's front door on Today: one dark block with a question, one
/// committing button, and the two rarer intents as quiet words beside it.
///
/// Identify is the action the rest of the product is built around, so it gets
/// the page's one dark surface. Everything else on Today is white on bone; a
/// block of deep leaf green is the thing the eye lands on after the plants, and
/// it asks the question a gardener actually has ("what is this?") rather than
/// naming a feature. Diagnose and Add plant are real but rarer, so they sit as
/// text links on the same baseline as the button and never compete with it.
///
/// The block keeps its own lighting in both appearances: deep green with cream
/// type in light, a darker green in dark so it does not glow against the night
/// canvas. The cream button is the one solid control on it.
///
/// At accessibility sizes the links drop below the button, where they would
/// otherwise squeeze the button's label.
private struct TodayQuickScanActions: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let block = GroveTheme.adaptive(light: 0x233F2B, dark: 0x1C2E21)
    private static let cream = GroveTheme.fixed(0xFFFCF5)
    private static let creamMuted = GroveTheme.fixed(0xC9D6CC)
    private static let leaf = GroveTheme.fixed(0x95CA98)
    private static let blockInk = GroveTheme.fixed(0x233F2B)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline
            actions
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.block, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                .strokeBorder(Self.leaf.opacity(0.12), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    /// The question. Tapping it does what the button does, so the large target
    /// is the whole top of the block; VoiceOver meets the button instead.
    private var headline: some View {
        NavigationLink(value: AppRoute.liveScan(.identify, nil)) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Found a plant you can't name?")
                        .font(.title3.weight(.bold))
                        .tracking(-0.3)
                        .foregroundStyle(Self.cream)
                    Text("A photo gets you its name and how to care for it.")
                        .font(.subheadline)
                        .foregroundStyle(Self.creamMuted)
                }
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                Image(systemName: "camera.macro")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Self.leaf)
            }
            .contentShape(.rect)
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.99))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var actions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 14) {
                identifyButton
                HStack(spacing: 18) { quietLinks }
            }
        } else {
            HStack(spacing: 14) {
                identifyButton
                Spacer(minLength: 4)
                quietLinks
            }
        }
    }

    private var identifyButton: some View {
        NavigationLink(value: AppRoute.liveScan(.identify, nil)) {
            Label("Scan a plant", systemImage: "camera.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Self.blockInk)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Self.cream, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.96))
        // Spoken as it is printed, so "Tap Scan a plant" in Voice Control
        // lands on it.
        .accessibilityLabel("Scan a plant")
        .accessibilityHint("Opens the plant camera to identify it")
        .accessibilityIdentifier("todayQuickIdentify")
    }

    @ViewBuilder
    private var quietLinks: some View {
        quietLink(title: "Diagnose", mode: .diagnose, label: "Diagnose a problem",
                  identifier: "todayQuickDiagnose")
        quietLink(title: "Add plant", mode: .add, label: "Add plant",
                  identifier: "todayQuickAdd")
    }

    private func quietLink(title: String, mode: ScanMode, label: String,
                           identifier: String) -> some View {
        NavigationLink(value: AppRoute.liveScan(mode, nil)) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Self.creamMuted)
                .lineLimit(1)
                .padding(.vertical, 11)
                .contentShape(.rect)
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.96))
        .accessibilityLabel(label)
        .accessibilityHint("Opens the plant camera")
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Onboarding checklist

/// A short, state-backed first-run checklist that keeps Today useful while a
/// new gardener is still setting up their Grove. It follows the compact,
/// editorial checklist pattern used by the best mobile products: one progress
/// statement, a few calm rows, and no explanatory copy competing with the
/// action itself.
private struct TodayOnboardingChecklist: View {
    @Environment(GroveStore.self) private var store
    @Environment(NotificationService.self) private var notifications
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(GroveDefaults.todayOnboardingChecklistCollapsed) private var isCollapsed = false

    /// What a row does when it is tapped. Most rows are a place in the app and
    /// stay `NavigationLink`s, which is what gives them their push animation
    /// and their Back button. Turning on reminders is not a place: it is a
    /// permission dialog, or a trip to iOS Settings once that dialog has
    /// already been answered.
    private enum Destination {
        case route(AppRoute)
        case act(() -> Void)
    }

    /// A row's picture. Every checklist row wants the same drawn botanical
    /// icon the rest of the card uses; `symbol` exists only so a row can ship
    /// before its illustration has been drawn, and each use is a temporary one.
    private enum Icon {
        case asset(String)
        case symbol(String)
    }

    private struct Item: Identifiable {
        let id: String
        let title: String
        let icon: Icon
        let destination: Destination
        let isComplete: Bool
        /// Overrides the generic "Opens this setup step" hint for rows that go
        /// somewhere less obvious than a screen in Grove.
        var accessibilityHint: String?
    }

    /// The few things worth doing first.
    ///
    /// The last used to be "Ask the botanist". Ask already owns a permanent tab;
    /// the Journey is the more hidden part of Grove, despite being the feature
    /// that turns real care into visible progress. Its row completes only when
    /// the first lesson is finished, never merely because the map was opened.
    ///
    /// The Journey appears only once there is a plant, which is the first row.
    /// Reminders stay visible from the start. Name and location are optional
    /// follow-through here: provider names complete themselves, while an email
    /// account can reach its useful first screen as "Gardener" and personalize
    /// it when convenient.
    private var items: [Item] {
        var items = [
            Item(
                id: "firstPlant",
                title: "Add your first plant",
                icon: .asset("TodayChecklistPlant"),
                destination: .route(.liveScan(.add, nil)),
                isComplete: !store.plants.isEmpty
            )
        ]
        if needsNameSetup {
            items.append(Item(
                id: "displayName",
                title: "Add your name",
                icon: .symbol("person.crop.circle.badge.plus"),
                destination: .act { openProfileSetup(step: 1) },
                isComplete: false
            ))
        }
        if store.profile.location == nil {
            items.append(Item(
                id: "homeConditions",
                title: "Set location",
                icon: .asset("TodayChecklistConditions"),
                destination: .act { openProfileSetup(step: 2) },
                isComplete: false
            ))
        }
        items.append(remindersItem)
        if !store.plants.isEmpty {
            items.append(
                Item(
                    id: "beginJourney",
                    title: "Begin your Journey",
                    icon: .asset("TodayChecklistGuide"),
                    destination: .route(.journeyMilestone(JourneyLibrary.welcomeMilestoneID)),
                    isComplete: store.gardener.completedMilestoneIDs.contains(
                        JourneyLibrary.welcomeMilestoneID
                    ),
                    accessibilityHint: "Opens the first step in your Journey"
                )
            )
        }
        return items
    }

    private func openProfileSetup(step: Int) {
        guard let accountID = store.activeAccountID else { return }
        UserDefaults.standard.set(step, forKey: PostSignupSetupProgress.key(accountID))
    }

    private var needsNameSetup: Bool {
        let name = store.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.caseInsensitiveCompare("Gardener") == .orderedSame
    }

    /// The row that decides whether Grove is ever able to speak first.
    ///
    /// iOS grants exactly one permission prompt per install, and Grove spends
    /// it inside the first scan. Someone who declines it there, or who never
    /// finishes that scan, had no way back other than a toggle in Settings
    /// three screens deep — so the app that exists to say "your fern is thirsty"
    /// quietly lost the ability to say anything. This is the second chance.
    ///
    /// The row is visible before the first plant so the checklist communicates
    /// the whole initial setup instead of silently growing a missing step later.
    /// Anyone who already allowed notifications during their scan simply finds
    /// it ticked when they return.
    private var remindersItem: Item {
        if store.plants.isEmpty {
            return Item(
                id: "careReminders", title: "Add a plant for care reminders",
                icon: .asset("TodayChecklistReminders"),
                destination: .route(.liveScan(.add, nil)), isComplete: false,
                accessibilityHint: "Add your first plant before setting up care reminders"
            )
        }
        let authorization = notifications.authorization
        // `.denied` is the only state the app cannot resolve by itself, so it
        // is the only one that says where the user is being sent. Promising
        // "turn on" and then handing them off to Settings would be a small lie
        // told at the exact moment they are already annoyed.
        let isDenied = authorization == .denied
        return Item(
            id: "careReminders",
            title: isDenied ? "Turn on reminders in Settings" : "Turn on care reminders",
            icon: .asset("TodayChecklistReminders"),
            destination: .act { openReminderSettings(isDenied: isDenied) },
            isComplete: authorization.canSchedule,
            accessibilityHint: isDenied
                ? "Opens Grove's notification settings in the Settings app"
                : "Asks permission to send care reminders"
        )
    }

    private func openReminderSettings(isDenied: Bool) {
        guard isDenied else {
            Task { await notifications.requestAuthorization() }
            return
        }
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private var completedCount: Int {
        items.filter(\.isComplete).count
    }

    private var progressFraction: CGFloat {
        CGFloat(completedCount) / CGFloat(items.count)
    }

    @ViewBuilder
    var body: some View {
        if completedCount < items.count {
            VStack(spacing: 0) {
                header

                if !isCollapsed {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            rowButton(item)
                                .accessibilityIdentifier("todayOnboarding.\(item.id)")

                            if index < items.count - 1 {
                                Divider()
                                    .padding(.leading, 58)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                    // A short tuck reads as the card folding closed. Moving the
                    // whole list by its own height made it look as though the
                    // rows were being pulled out behind the header.
                    .transition(rowsTransition)
                }
            }
            .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            // Keep the disappearing rows inside the changing card silhouette;
            // otherwise the final few pixels briefly draw above its border.
            .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                    .strokeBorder(GroveTheme.separator, lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("todayOnboardingChecklist")
            .animation(GroveMotion.settle, value: completedCount)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .onDisappear {
                // The card leaves the screen either because the reader left
                // Today or because the list just finished. Only the second is
                // worth a diagnostic, and `reportCompletionOnce` keeps it to
                // one per install.
                if completedCount == items.count {
                    TodayChecklistAnalytics.reportCompletionOnce()
                }
            }
        }
    }

    /// A row is a push or a plain button depending on where it leads, but both
    /// have to feel like the same row: same tap target, same analytics, same
    /// lack of button chrome.
    @ViewBuilder
    private func rowButton(_ item: Item) -> some View {
        switch item.destination {
        case let .route(route):
            NavigationLink(value: route) {
                row(item)
            }
            .buttonStyle(.plain)
            // A `simultaneousGesture` rather than an `onTapGesture`: the link
            // still owns the tap, this only listens in.
            .simultaneousGesture(TapGesture().onEnded {
                TodayChecklistAnalytics.rowTapped(item.id, complete: item.isComplete)
            })
        case let .act(action):
            Button {
                TodayChecklistAnalytics.rowTapped(item.id, complete: item.isComplete)
                action()
            } label: {
                row(item)
            }
            .buttonStyle(.plain)
        }
    }

    private var rowsTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let tucked = AnyTransition.offset(y: -8)
            .combined(with: .scale(scale: 0.985, anchor: .top))
            .combined(with: .opacity)
        return .asymmetric(insertion: tucked, removal: tucked)
    }

    private var header: some View {
        Button {
            Haptics.selection()
            if reduceMotion {
                isCollapsed.toggle()
            } else {
                withAnimation(GroveMotion.snap) {
                    isCollapsed.toggle()
                }
            }
            TodayChecklistAnalytics.toggled(collapsed: isCollapsed)
        } label: {
            HStack(spacing: 14) {
                Image("TodayChecklistGrove")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .background(GroveTheme.softAccent, in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Build your grove")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(GroveTheme.ink)
                    Text("\(completedCount) of \(items.count) complete")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .contentTransition(.numericText())
                    progressTrack
                }

                Spacer(minLength: 8)

                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GroveTheme.subtleInk)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 20, height: 44)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Build your grove, \(completedCount) of \(items.count) complete, \(isCollapsed ? "collapsed" : "expanded")"
        )
        .accessibilityHint("Double tap to \(isCollapsed ? "expand" : "collapse") the checklist")
        .accessibilityIdentifier("todayOnboardingToggle")
    }

    /// Progress as the app's one progress bar.
    ///
    /// The header used to say the same number three ways in one row: a ring, a
    /// percentage inside it, and "2 of 3 complete" beside it. A percentage is
    /// also the wrong unit for three tasks — 67% is a reading of a gauge, and
    /// this is a list you can count. The count keeps the words, and the bar
    /// under them is the shared `GroveProgressBar` every other progress in
    /// Grove already uses, so the checklist stops being the one place with a
    /// bespoke gauge.
    private var progressTrack: some View {
        GroveProgressBar(fraction: Double(progressFraction), tint: GroveTheme.accent, height: 6)
            .frame(maxWidth: 132)
            .accessibilityHidden(true)
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 12) {
            icon(item.icon)

            Text(item.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Image(systemName: item.isComplete ? "checkmark.circle.fill" : "chevron.right")
                .font(.system(size: item.isComplete ? 21 : 15, weight: .semibold))
                .foregroundStyle(item.isComplete ? GroveTheme.accentStrong : GroveTheme.subtleInk)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.isComplete ? "\(item.title), complete" : item.title)
        .accessibilityHint(
            item.isComplete
                ? "Opens this part of Grove"
                : (item.accessibilityHint ?? "Opens this setup step")
        )
    }

    @ViewBuilder
    private func icon(_ icon: Icon) -> some View {
        switch icon {
        case let .asset(name):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .background(GroveTheme.softAccent, in: Circle())
                .accessibilityHidden(true)
        case let .symbol(name):
            // Sized down inside the same 42pt circle the drawn icons fill, so a
            // symbol reads as a mark sitting in the well rather than a glyph
            // straining against its edge.
            Image(systemName: name)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(GroveTheme.accentStrong)
                .frame(width: 42, height: 42)
                .background(GroveTheme.softAccent, in: Circle())
                .accessibilityHidden(true)
        }
    }
}

/// Funnel instrumentation for the Build-your-Grove checklist. It picks up
/// where `OnboardingAnalytics` stops: the signed-out funnel ends at
/// `onboarding_completed`, and these events say whether the sessions after it
/// actually built a grove. Same contract as the onboarding events — anonymous
/// install id, fire-and-forget, dropped before it may ever block a screen.
@MainActor
private enum TodayChecklistAnalytics {
    static func rowTapped(_ row: String, complete: Bool) {
        forward("today_checklist_row_tapped", ["row": row, "complete": String(complete)])
    }

    static func toggled(collapsed: Bool) {
        forward("today_checklist_toggled", ["collapsed": String(collapsed)])
    }

    /// Reports the checklist finishing, at most once per install. The guard is
    /// device-level like the install id itself, so a grove rebuilt after a
    /// deleted plant, or a second account on the same phone, stays silent
    /// rather than reporting a first run it did not have.
    static func reportCompletionOnce(storage: UserDefaults = .standard) {
        guard !storage.bool(forKey: GroveDefaults.todayOnboardingChecklistCompletionReported) else { return }
        storage.set(true, forKey: GroveDefaults.todayOnboardingChecklistCompletionReported)
        forward("today_checklist_completed", [:])
    }

    private static func forward(_ name: String, _ params: [String: String]) {
        Task { await GroveAnalytics.shared.record(name, params) }
    }
}

// MARK: - Window hero

/// Today's hero: one plant's own photograph, edge to edge and washed in the
/// hour, under a sentence that says what it needs.
///
/// The plant is the one that needs you most, so the picture changes when the
/// day's job does. Everything else in the grove sits along the bottom as a row
/// of faces, each ringed in its status, which is the whole rooms map said in a
/// glance: who is fine and who is not.
private struct TodayWindowHero: View {
    let lead: TodayBoardEntry
    let others: [TodayBoardEntry]
    let atmosphere: GroveAtmosphere

    private static let height: CGFloat = 520
    private static let faceLimit = 6

    var body: some View {
        PlantThumbnail(plant: lead.plant, height: Self.height, maxDimension: 1400, breathes: true)
            .overlay { atmosphere.photoWash }
            .overlay {
                // On-photo scrim: the photograph sets the lighting, so this is
                // the sanctioned literal. Deep enough at the foot to hold white
                // display type over a bright windowsill.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0.3),
                        .init(color: .black.opacity(0.35), location: 0.55),
                        .init(color: .black.opacity(0.8), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 16) {
                    caption
                    if !others.isEmpty { faces }
                }
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.bottom, GroveBoardPage<EmptyView, EmptyView>.overlap + 22)
            }
            .environment(\.colorScheme, .dark)
    }

    private var caption: some View {
        NavigationLink(value: AppRoute.plant(lead.plant.id)) {
            VStack(alignment: .leading, spacing: 8) {
                GroveEyebrow(text: eyebrow, color: .white.opacity(0.78))
                Text(headline)
                    .font(GroveTheme.display(GroveDisplayStyle.title.points))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(lead.plant.nickname)")
    }

    private var faces: some View {
        let shown = ([lead] + others).prefix(Self.faceLimit)
        let overflow = others.count + 1 - shown.count
        return HStack(spacing: 10) {
            ForEach(Array(shown)) { entry in
                NavigationLink(value: AppRoute.plant(entry.plant.id)) {
                    PlantThumbnail(plant: entry.plant, height: 34, maxDimension: 120)
                        .frame(width: 34, height: 34)
                        .clipShape(Circle())
                        .padding(3)
                        .overlay(Circle().strokeBorder(entry.mapTint, lineWidth: 2.5))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.plant.nickname), \(entry.status.text)")
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.leading, 2)
            }
        }
    }

    private var eyebrow: String {
        lead.room == "Elsewhere" ? lead.status.text : "\(lead.status.text) · \(lead.room)"
    }

    private var headline: String {
        let name = lead.plant.nickname
        guard lead.needsYou else {
            return others.isEmpty ? "\(name) is doing fine." : "Everything's on track."
        }
        switch lead.status.tone {
        case .urgent, .attention: return "Check in on \(name) today."
        default: break
        }
        // The same rule `GrovePlantCareSummary.status` uses: a task only
        // speaks for the plant when it falls before the next check-in.
        //
        // Never "water": nothing has felt the soil, so the most Today can ask
        // is that you do. The reminders hold the same line.
        let kind = lead.summary.nextTask.flatMap { $0.dueDate <= lead.plant.nextCheckIn ? $0.kind : nil }
        switch kind {
        case .water, .inspectSoil:
            return lead.status.tone == .late ? "\(name)'s soil check is overdue." : "Check \(name)'s soil today."
        case .checkIn, nil: return "Check in on \(name)."
        case .fertilise: return "Feed \(name) today."
        case .rotate: return "Turn \(name) today."
        case .cleanLeaves: return "Wipe \(name)'s leaves."
        case .treat: return "Treat \(name) today."
        case .prune: return "Trim \(name) today."
        case .repot: return "Repot \(name)."
        case .relocate: return "Move \(name) today."
        case .monitor: return "Review \(name)'s progress."
        }
    }

    private var detail: String? {
        guard lead.needsYou else {
            return "Next: \(lead.plant.nickname), \(lead.status.text.lowercased())."
        }
        let waiting = others.filter(\.needsYou)
        if let next = waiting.first {
            return waiting.count == 1 ? "\(next.plant.nickname) needs you too." : "\(waiting.count) more need you below."
        }
        if let next = others.first, let when = Self.when(next.summary.dueDate) {
            return "\(next.plant.nickname) is fine until \(when)."
        }
        return nil
    }

    /// When the next plant's work arrives, or nil when it already has: a
    /// plant whose work is due is not "fine until" anything.
    private static func when(_ date: Date) -> String? {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ...0: return nil
        case 1: return "tomorrow"
        case 2...6: return date.formatted(.dateTime.weekday(.wide))
        default: return date.formatted(.dateTime.day().month(.wide))
        }
    }
}

#Preview {
    AppDestinationsPreviewHost { TodayView() }
        .environment(IntentRouter.shared)
        .environment(GroveStore())
        .environment(WeatherService())
        .environment(NotificationService())
}
