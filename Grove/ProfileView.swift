import SwiftUI

struct ProfileView: View {
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine: SyncEngine?
    @Environment(ConnectivityMonitor.self) private var connectivity: ConnectivityMonitor?
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    @State private var searchText = ""
    @State private var filter: PlantFilter = .all
    @State private var selectedRoom: String?
    @State private var selectedCollection: UUID?
    @State private var sortOrder: PlantSortOrder = .attention
    @State private var showCreateCollection = false
    @FocusState private var searchFocused: Bool

    /// How many plants the attention shelf shows before deferring to the library.
    /// Three fits the whole shelf on screen under the hero, so the answer to
    /// "what needs me?" is never a scroll.
    private static let attentionShelfLimit = 3

    private static let libraryColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Rooms with names, sorted for the browse rail.
    private var rooms: [String] {
        Array(Set(store.plants.map { roomName(for: $0) }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// True when at least one plant has never been given a location, which is
    /// the only case where a "No room" lens means anything.
    private var hasUnplacedPlants: Bool {
        store.plants.contains { roomName(for: $0).isEmpty }
    }

    /// The room a plant lives in, or nothing.
    ///
    /// `"Unassigned"` is the placeholder the scan flow writes when nobody has
    /// said where a plant lives. It was reaching the interface as a fact: a
    /// chip in the browse rail named "Unassigned", and every un-placed plant
    /// printed it as a subtitle under its name. A missing value is not a room
    /// and not a caption — it is silence, and the "No room" chip already exists
    /// for finding these plants on purpose.
    private func roomName(for plant: Plant) -> String {
        let trimmed = plant.location.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.caseInsensitiveCompare("Unassigned") == .orderedSame ? "" : trimmed
    }

    /// The collection the library is scoped to, if it still exists.
    private var activeCollection: PlantCollection? {
        guard let selectedCollection else { return nil }
        return store.collections.first { $0.id == selectedCollection }
    }

    private var scopedPlants: [Plant] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let collectionMembers: Set<UUID>? = activeCollection.map { Set($0.plantIDs) }
        return store.plants.filter { plant in
            let matchesSearch = query.isEmpty
                || plant.nickname.localizedCaseInsensitiveContains(query)
                || plant.species.localizedCaseInsensitiveContains(query)
                || plant.scientificName.localizedCaseInsensitiveContains(query)
                || plant.location.localizedCaseInsensitiveContains(query)
            let matchesRoom = selectedRoom == nil || roomName(for: plant) == selectedRoom
            let matchesCollection = collectionMembers?.contains(plant.id) ?? true
            return matchesSearch && matchesRoom && matchesCollection
        }
    }

    private func care(for plant: Plant) -> GrovePlantCareSummary {
        GrovePlantCareSummary(plant: plant, nextTask: store.nextPendingTask(for: plant.id))
    }

    private var filteredPlants: [Plant] {
        let plants = scopedPlants.filter { filter.matches($0, needsCare: care(for: $0).needsCare) }
        // The first scan records when a plant joined Grove. Acquisition dates
        // are the fallback for older records without a saved scan.
        let firstScans = Dictionary(grouping: store.scanHistory.compactMap { scan -> (UUID, Date)? in
            guard let id = scan.plantID else { return nil }
            return (id, scan.createdAt)
        }, by: { $0.0 }).mapValues { $0.map(\.1).min()! }
        let summaries = Dictionary(uniqueKeysWithValues: plants.map { ($0.id, care(for: $0)) })
        return plants.sorted { lhs, rhs in
            switch sortOrder {
            case .attention:
                let left = summaries[lhs.id]!
                let right = summaries[rhs.id]!
                if left.priority != right.priority { return left.priority < right.priority }
                if left.needsCare, left.dueDate != right.dueDate { return left.dueDate < right.dueDate }
            case .recent:
                let left = firstScans[lhs.id] ?? lhs.acquiredAt ?? .distantPast
                let right = firstScans[rhs.id] ?? rhs.acquiredAt ?? .distantPast
                if left != right { return left > right }
            case .name: break
            }
            let comparison = lhs.nickname.localizedStandardCompare(rhs.nickname)
            return comparison == .orderedSame
                ? lhs.id.uuidString < rhs.id.uuidString
                : comparison == .orderedAscending
        }
    }

    /// Every plant the grove owes something, worst first — the same order the
    /// library defaults to, read out as a short list.
    private var attentionPlants: [Plant] {
        let needsCare = store.plants.filter { care(for: $0).needsCare }
        let summaries = Dictionary(uniqueKeysWithValues: needsCare.map { ($0.id, care(for: $0)) })
        return needsCare.sorted { lhs, rhs in
            let left = summaries[lhs.id]!
            let right = summaries[rhs.id]!
            if left.priority != right.priority { return left.priority < right.priority }
            if left.dueDate != right.dueDate { return left.dueDate < right.dueDate }
            return lhs.nickname.localizedStandardCompare(rhs.nickname) == .orderedAscending
        }
    }

    /// True when the scoped collection exists but has no members at all — a
    /// different nothing from a search that came back empty.
    private var activeCollectionIsEmpty: Bool {
        activeCollection.map(\.plantIDs.isEmpty) ?? false
    }

    private func count(for filter: PlantFilter) -> Int {
        scopedPlants.count { filter.matches($0, needsCare: care(for: $0).needsCare) }
    }

    private var needsCareCount: Int { store.plants.count { care(for: $0).needsCare } }

    /// Whether the action shelf earns its place above the library.
    ///
    /// The shelf and the library are two registers of the same plants — a
    /// shortlist you can act on, and a grid you can browse — which is why the
    /// library is now photographs rather than rows: two registers only work
    /// when they look like two different things. On a grove of one plant there
    /// is no shortlist to draw, and showing the same single plant twice on one
    /// screen is a page arguing with itself.
    private var showsAttentionShelf: Bool {
        !isSearching && !attentionPlants.isEmpty && store.plants.count > 1
    }

    /// Every plant on the board's anatomy, keyed for the room grid.
    private var boardEntries: [UUID: TodayBoardEntry] {
        var entries: [UUID: TodayBoardEntry] = [:]
        for plant in store.plants {
            entries[plant.id] = TodayBoardEntry(
                plant: plant,
                nextTask: store.nextPendingTask(for: plant.id),
                tasks: store.tasks,
                siblings: store.plants
            )
        }
        return entries
    }

    var body: some View {
        let entries = boardEntries
        return ScrollViewReader { proxy in
            GroveBoardPage {
                groveHero
            } sheet: {
                    pageTitle

                    if store.plants.isEmpty {
                        emptyGrove
                        JourneyProgressRail()
                    } else {
                        overview(entries: entries)

                        libraryControls.id("grove.library")

                        plantsSection(filteredPlants, entries: entries)

                        // The shortlist you act on sits under the grove you
                        // look at. Today leads with the same plants, so here
                        // it is the follow-through rather than the headline.
                        if showsAttentionShelf {
                            attentionSection { showAllAttention(scrolling: proxy) }
                        }

                        if !isSearching, selectedRoom == nil, activeCollection == nil, filter == .all {
                            steadyRunsSection
                        }
                    }
                            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: searchFocused) { _, focused in
                if focused { proxy.scrollTo("grove.library", anchor: .top) }
            }
        }
        .refreshable { await refresh() }
        .sheet(isPresented: $showCreateCollection) { CreateCollectionView() }
        .navigationTitle("My Grove")
        .toolbar {
            if store.displayStreak > 0 {
                ToolbarItem(placement: .topBarLeading) { GroveHeaderStreak().groveHeaderChip() }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink(value: AppRoute.liveScan(.add, nil)) {
                    GroveHeaderIcon(symbol: "plus")
                }
                .groveHeaderChip()
                .accessibilityLabel("Add a plant")
                NavigationLink(value: AppRoute.settings) {
                    GroveHeaderIcon(symbol: "gearshape")
                }
                .groveHeaderChip()
                .accessibilityLabel("Settings and privacy")
            }
        }
        .groveRootHeaderBar(title: "My Grove")
    }

    private var libraryControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                GroveSearchBar(text: $searchText, prompt: "Search plants or rooms", isFocused: $searchFocused)
                sortMenu
            }

            BrowseRail(
                filter: $filter,
                selectedRoom: $selectedRoom,
                selectedCollection: $selectedCollection,
                rooms: rooms,
                hasUnplacedPlants: hasUnplacedPlants,
                collections: store.collections,
                statusCount: count(for:),
                onNewCollection: { showCreateCollection = true }
            )

            collectionBanner
        }
        .padding(.vertical, 4)
    }

    /// Ordering is a property of the list, not a lens on it, so it stays a menu
    /// beside the search field rather than taking a chip in the rail.
    private var sortMenu: some View {
        Menu {
            Picker("Sort plants", selection: $sortOrder) {
                ForEach(PlantSortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(GroveTheme.accentStrong)
                .frame(width: 44, height: 44)
                .background(GroveTheme.secondarySurface, in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius))
        }
        .accessibilityLabel("Sort plants")
        .accessibilityValue(sortOrder.rawValue)
    }

    /// The scoped collection as a door rather than a filter readout: the chips
    /// scope the library, this is how you walk into the collection itself.
    @ViewBuilder
    private var collectionBanner: some View {
        if let collection = activeCollection {
            let members = store.plants(in: collection.id)
            NavigationLink(value: AppRoute.collection(collection.id)) {
                HStack(spacing: 12) {
                    collectionCover(collection, members: members)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GroveTheme.ink)
                            .lineLimit(1)
                        Text("\(members.count) \(members.count == 1 ? "plant" : "plants")")
                            .font(.caption)
                            .foregroundStyle(GroveTheme.mutedInk)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GroveTheme.subtleInk)
                }
                .padding(10)
                .background(GroveTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                .groveEdgeLight(radius: GroveTheme.compactRadius)
                .contentShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
            }
            .buttonStyle(GroveCardPressStyle())
            .collectionQuickActions(for: collection)
            .accessibilityLabel("\(collection.name), \(members.count) \(members.count == 1 ? "plant" : "plants"). Opens the collection.")
        }
    }

    @ViewBuilder
    private func collectionCover(_ collection: PlantCollection, members: [Plant]) -> some View {
        if let first = members.first {
            PlantThumbnail(plant: first, height: 40, maxDimension: 160)
        } else {
            GroveCollectionIcon(symbol: collection.symbol, size: 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(GroveTheme.secondarySurface)
        }
    }

    private func refresh() async {
        guard let syncEngine else { return }
        await syncEngine.synchronize(store: store, isConnected: connectivity?.isConnected ?? false)
    }

    /// "See all" on the shelf is a promise about the library: drop every lens so
    /// the due plants are all there to be worked through.
    private func showAllAttention(scrolling proxy: ScrollViewProxy) {
        searchText = ""
        searchFocused = false
        selectedRoom = nil
        selectedCollection = nil
        filter = needsCareCount > 0 ? .needsCare : .all
        proxy.scrollTo("grove.library", anchor: .top)
    }

    /// One tap per plant: log what is due, or open the guided check-in when the
    /// plant itself is the reason.
    private func callToAction(for plant: Plant) -> PlantCallToAction {
        if plant.healthBand.needsAttention { return .checkIn }
        if let task = store.nextPendingTask(for: plant.id), task.dueDate <= plant.nextCheckIn {
            switch task.kind {
            case .checkIn, .inspectSoil: return .checkIn
            default: return .log(task.kind)
            }
        }
        return .checkIn
    }

    private func logCare(_ kind: CareKind, for plant: Plant) {
        let store = self.store
        // Same refusal as the plant page, explained rather than buzzed away:
        // a second watering is the mistake this app exists to prevent.
        if kind == .water, let last = store.lastWatering(for: plant.id) {
            Haptics.warning()
            toasts?.show(
                RecentWateringGuard.message(lastWateredAt: last.performedAt),
                symbol: "drop.triangle"
            )
            return
        }
        var outcome: CareTask?
        withAnimation(GroveMotion.settle) {
            outcome = store.logCare(plantID: plant.id, kind: kind)
        }
        guard let logged = outcome else {
            Haptics.error()
            return
        }
        Haptics.complete()
        toasts?.show(
            "Recorded \(kind.loggedTitle) for \(plant.nickname)",
            symbol: kind.icon,
            actionTitle: "Undo"
        ) {
            store.undoCompletion(taskID: logged.id)
        }
    }

    /// How long each plant has been holding its own.
    ///
    /// The row a social app would fill with friends and their flames. Here the
    /// streak belongs to the thing actually being kept alive: a run is the days
    /// since a plant last came out of a check-in worse than it went in, so it is
    /// earned from the record rather than from opening the app. Two is the
    /// minimum worth a section — one plant with a number under it is a stat, not
    /// a shelf.
    @ViewBuilder
    private var steadyRunsSection: some View {
        let runs = plantRuns
        if runs.count >= 2 {
            VStack(alignment: .leading, spacing: 14) {
                MyGroveSectionTitle(
                    title: "Steady days",
                    subtitle: "Days since each plant last lost ground"
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(runs.prefix(8)) { run in
                            NavigationLink(value: AppRoute.plant(run.plant.id)) {
                                PlantRunTile(run: run)
                            }
                            .buttonStyle(GroveCardPressStyle())
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 3)
                }
                .scrollClipDisabled()
            }
        }
    }

    /// Every plant with a run of at least a day, longest first.
    ///
    /// A plant with no check-ins has no record to read a run from and is left
    /// out rather than given a zero — Grove learns a plant's health when someone
    /// looks at it, so silence is not a slipped day.
    private var plantRuns: [PlantRun] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let history = Dictionary(grouping: store.observations, by: \.plantID)
        return store.plants.compactMap { plant -> PlantRun? in
            guard let entries = history[plant.id], !entries.isEmpty else { return nil }
            let ordered = entries.sorted { $0.createdAt < $1.createdAt }
            // The run starts at the last check-in that found the plant worse
            // than the one before it — or, for a plant that has never gone
            // backwards, at the first time anyone looked.
            let start = ordered.last { $0.score < $0.previousScore } ?? ordered[0]
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: start.createdAt),
                to: today
            ).day ?? 0
            guard days >= 1 else { return nil }
            return PlantRun(plant: plant, days: days)
        }
        .sorted { $0.days > $1.days }
    }

    /// The grove, room by room: a heading with its count, then a two-up grid of
    /// photographs. The rooms follow the lenses above them, so a search or a
    /// filter narrows the rooms rather than flattening them, and the sort order
    /// holds inside each room.
    ///
    /// Photographs rather than rows, because the attention shelf further down
    /// is the shortlist you act on and this is the grove you look at. They are
    /// also the only place in the app the user's own pictures get to be more
    /// than a thumbnail.
    private func plantsSection(_ filteredPlants: [Plant], entries: [UUID: TodayBoardEntry]) -> some View {
        let ordered: [TodayBoardEntry] = filteredPlants.compactMap { entries[$0.id] }
        let rooms = MyGroveRoom.group(ordered)
        return VStack(alignment: .leading, spacing: 30) {
            if filteredPlants.isEmpty {
                emptyLibraryState
            } else {
                ForEach(rooms) { room in
                    roomSection(room, isOnlyRoom: rooms.count == 1)
                }
            }
        }
    }

    private func roomSection(_ room: MyGroveRoom, isOnlyRoom: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                if room.name != "Elsewhere" {
                    GroveRoomBadge(name: room.name, size: 34)
                }
                MyGroveSectionTitle(
                    // One unnamed room is the whole grove, not a place.
                    title: isOnlyRoom && room.name == "Elsewhere" ? "All plants" : room.name,
                    subtitle: room.subtitle
                )
            }

            LazyVGrid(columns: Self.libraryColumns, alignment: .leading, spacing: 20) {
                ForEach(room.entries) { entry in
                    plantTile(entry)
                }
            }
        }
    }

    private func plantTile(_ entry: TodayBoardEntry) -> some View {
        let plant = entry.plant
        return NavigationLink(value: AppRoute.plant(plant.id)) {
            MyGroveTile(entry: entry)
        }
        .buttonStyle(GroveCardPressStyle())
        .plantQuickActions(for: plant)
        .groveHeroSource(.plant(plant.id))
        .groveRowTransition()
        .accessibilityIdentifier("plantCard.\(plant.nickname)")
    }

    /// The feature and the three numbers under it. Both describe the whole
    /// grove, so they ignore the lenses below them.
    private func overview(entries: [UUID: TodayBoardEntry]) -> some View {
        let average = MyGroveHealthAverage.measure(
            plants: store.plants,
            observations: store.observations
        )
        let needYou = entries.values.filter(\.needsYou).count

        // The Journey rail carries its own 44pt tap height, so the gap above
        // it is tighter than the summary's hairline would otherwise want.
        return VStack(alignment: .leading, spacing: 8) {
            MyGroveSummaryRow(
                plantCount: store.plants.count,
                needYouCount: needYou,
                average: average
            )

            JourneyProgressRail()
        }
    }

    /// Two different nothings, and they want different pictures: a collection
    /// with no members is a folder waiting to be filled, while a search that
    /// came back empty is the filters' fault. A filtered-to-nothing list used
    /// to be a dead end — the thing hiding the plants was the filter chip or the
    /// search field the user had already scrolled past — so the search failure
    /// carries the way back out.
    @ViewBuilder
    private var emptyLibraryState: some View {
        if activeCollectionIsEmpty, let collection = activeCollection {
            GroveEmptyState(
                scene: .noMatches,
                title: "Nothing in \(collection.name) yet",
                message: "Open any plant and use Add to collection to file it here."
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: 240)
        } else if filter == .needsCare, !scopedPlants.isEmpty {
            // Finishing the last due plant under the "Needs care" lens is a win,
            // not a search failure, and the page should say so instead of asking
            // the user to clear a filter they chose on purpose.
            GroveEmptyState(
                scene: .allClear,
                title: "Nothing needs you",
                message: "Everything here is happy right now."
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: 240)
        } else {
            GroveEmptyState(
                scene: .noMatches,
                title: "Nothing matches",
                message: "Try another word, or clear a filter."
            ) {
                Button {
                    Haptics.selection()
                    withAnimation(GroveMotion.snap) {
                        searchText = ""
                        filter = .all
                        selectedRoom = nil
                        selectedCollection = nil
                    }
                } label: {
                    GroveOutlineLabel(
                        title: "Show all \(store.plants.count) \(store.plants.count == 1 ? "plant" : "plants")",
                        systemImage: "arrow.counterclockwise",
                        size: .compact
                    )
                }
                .buttonStyle(GrovePressStyle())
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 240)
        }
    }

    /// The tab's own name in the system large title, the way Today opens, with
    /// the avatar as the door to the profile. The "Your grove is happy" line
    /// that used to sit under it is now the "Need you 0" figure in the summary
    /// row, which says the same thing as a number.
    /// My Grove's hero: the plant doing best this month, in its own photo.
    /// With nothing improved, the healthiest plant stands in; with nothing
    /// planted, the night-green hero says where the grove will appear.
    @ViewBuilder
    private var groveHero: some View {
        let active = store.plants.filter {
            $0.effectiveLifecycleState == .active && $0.hasHealthReading
        }
        if let improvement = MyGroveImprovement.mostImproved(plants: store.plants, observations: store.observations) {
            NavigationLink(value: AppRoute.plant(improvement.plant.id)) {
                GrovePhotoHero(
                    plant: improvement.plant,
                    eyebrow: "Most improved this month",
                    title: "\(improvement.plant.nickname), up \(improvement.gain)",
                    value: "\(improvement.plant.healthScore)"
                )
            }
            .buttonStyle(.plain)
        } else if let best = active.max(by: { $0.healthScore < $1.healthScore }) {
            NavigationLink(value: AppRoute.plant(best.id)) {
                GrovePhotoHero(
                    plant: best,
                    eyebrow: "Healthiest right now",
                    title: best.nickname,
                    value: "\(best.healthScore)"
                )
            }
            .buttonStyle(.plain)
        } else {
            GroveNightHero {
                GroveEyebrow(text: "My Grove", color: GroveTheme.mapLabel)
                Text("Every plant you add lives here.")
                    .font(GroveTheme.display(GroveDisplayStyle.heading.points))
                    .foregroundStyle(GroveTheme.ink)
            }
        }
    }

    private var pageTitle: some View {
        let plants = store.plants.count
        // The stats row below counts the plants; the header says how long
        // this grove has been growing.
        let since = store.plants.compactMap(\.acquiredAt).min()
        let line: String = {
            guard plants > 0 else { return "Every plant you add lives here" }
            guard let since else { return "Your plants, by room" }
            return "Growing since \(since.formatted(.dateTime.day().month(.wide).year()))"
        }()
        return GroveTabHeader(title: "My Grove", subtitle: line)
    }

    /// First-run hero: one unmissable path into the core loop. The same
    /// `GroveEmptyState` the filtered library uses, with the copy a brand-new
    /// grove wants.
    private var emptyGrove: some View {
        GroveEmptyState(
            scene: .firstPlant,
            customArt: AnyView(WindowsillScene().frame(maxWidth: 220)),
            title: "Nothing planted yet",
            message: "Scan a plant you own and it starts here."
        ) {
            NavigationLink(value: AppRoute.liveScan(.add, nil)) {
                GroveScanCTALabel()
            }
            .buttonStyle(GroveScanCTAStyle())
            .accessibilityLabel("Scan your first plant")
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 240)
    }

    /// The action block: the plants the grove owes something, each with the one
    /// tap that settles it.
    private func attentionSection(scrollToLibrary: @escaping () -> Void) -> some View {
        let plants = attentionPlants
        let shown = Array(plants.prefix(Self.attentionShelfLimit))
        let hasMore = plants.count > shown.count
        return VStack(alignment: .leading, spacing: 14) {
            MyGroveSectionTitle(
                // One term for one concept: the filter chip and the sort
                // below say "Needs care" too.
                title: "Needs care",
                subtitle: plants.count == 1
                    ? "1 plant needs you"
                    : "\(plants.count) plants need you",
                actionTitle: hasMore ? "See all" : nil,
                action: hasMore ? scrollToLibrary : nil
            )

            GroveRowGroup {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, plant in
                    if index > 0 { GroveRowDivider() }
                    AttentionRow(
                        plant: plant,
                        care: care(for: plant),
                        action: callToAction(for: plant),
                        onLog: { logCare($0, for: plant) }
                    )
                }
            }
        }
    }
}

#Preview {
    AppDestinationsPreviewHost { ProfileView() }
        .environment(GroveStore())
        .environment(IntentRouter.shared)
}

/// What one tap on an attention row does. A task that can be honestly recorded
/// from a list becomes a log; a plant whose health is the question keeps the
/// camera flow, because a check-in without the guided photo is a row pretending
/// to know something it does not.
private enum PlantCallToAction {
    case checkIn
    case log(CareKind)
}

/// One plant that needs something, and the tap that gives it.
///
/// Wears `PlantRow` — the app's one plant anatomy — rather than its own. The
/// shelf used to draw a 52pt circle ringed in the health-band colour while the
/// library beneath it drew a 112pt photo panel and the care rows one tab over
/// drew a 56pt rounded square, so the same plant changed shape three times on
/// two screens. The ring is gone with it: a coloured circle around a photograph
/// said the band a second time, in a place where the status line was already
/// saying it in words.
private struct AttentionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let plant: Plant
    let care: GrovePlantCareSummary
    let action: PlantCallToAction
    let onLog: (CareKind) -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    plantLink
                    actionControl
                }
            } else {
                ZStack(alignment: .trailing) {
                    plantLink
                    actionControl
                }
            }
        }
        .plantQuickActions(for: plant)
    }

    /// The pill is a real control sitting over the row, so the row itself can
    /// stay one tap target that opens the plant.
    private var plantLink: some View {
        NavigationLink(value: AppRoute.plant(plant.id)) {
            PlantRow(plant: plant, status: care.status) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Color.clear.frame(width: actionSlotWidth, height: 1)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(GroveCardPressStyle())
        .accessibilityHint("Opens \(plant.nickname)")
    }

    /// Wide enough for the longest verb the shelf can show ("Fertilised"), so
    /// the status line underneath never runs beneath the pill.
    private var actionSlotWidth: CGFloat { 104 }

    @ViewBuilder
    private var actionControl: some View {
        switch action {
        case .checkIn:
            NavigationLink(value: AppRoute.checkIn(plant.id)) {
                GroveInkLabel(title: "Check in", size: .compact)
            }
            .buttonStyle(GrovePressStyle())
            .accessibilityLabel("Check in \(plant.nickname)")
        case .log(let kind):
            Button {
                onLog(kind)
            } label: {
                GroveInkLabel(title: kind.shelfActionTitle, size: .compact)
            }
            .buttonStyle(GrovePressStyle())
            .accessibilityLabel("\(kind.shelfActionTitle) \(plant.nickname)")
        }
    }
}

/// The short verb the attention shelf's action button shows. The log menu
/// phrases these as whole past-tense sentences ("Cleaned leaves"); a row button
/// shares its line with a plant name, so it keeps the verb and drops the rest.
private extension CareKind {
    var shelfActionTitle: String {
        switch self {
        case .checkIn, .inspectSoil: "Check in"
        case .water: "Watered"
        case .fertilise: "Fertilised"
        case .rotate: "Turned"
        case .cleanLeaves: "Cleaned"
        case .treat: "Treated"
        case .prune: "Pruned"
        case .repot: "Repotted"
        case .relocate: "Moved"
        case .monitor: "Checked"
        }
    }
}

/// One plant and the length of its current good run.
private struct PlantRun: Identifiable {
    let plant: Plant
    let days: Int

    var id: UUID { plant.id }
}

private struct PlantRunTile: View {
    let run: PlantRun

    @ScaledMetric(relativeTo: .caption) private var tileWidth: CGFloat = 80
    @ScaledMetric(relativeTo: .caption) private var thumbSize: CGFloat = 66

    private var band: HealthBand { run.plant.healthBand }

    var body: some View {
        VStack(spacing: 8) {
            // A rounded square at the app's thumbnail radius, like every other
            // plant in Grove. This shelf was the last place a plant was drawn as
            // a circle, which made a run tile read as an avatar — a person —
            // rather than as the same object the rows above it show.
            PlantThumbnail(plant: run.plant, height: thumbSize, maxDimension: 200)
                .frame(width: thumbSize, height: thumbSize)
                .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                        .strokeBorder(band.color, lineWidth: 2.5)
                }

            Text(run.plant.nickname)
                .font(.caption.weight(.bold))
                .foregroundStyle(GroveTheme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)

            HStack(spacing: 4) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 10, weight: .black))
                Text("\(run.days)d")
                    .font(.caption2.weight(.black))
                    .monospacedDigit()
            }
            .foregroundStyle(band.color)
        }
        .frame(width: tileWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(run.plant.nickname), steady for \(run.days == 1 ? "1 day" : "\(run.days) days")")
    }
}

// MARK: - Browsing

/// The one place the library is shaped.
///
/// Rooms used to hide in the sort menu and collections in a shelf above the
/// list — two taxonomies, one of them invisible. They answer different
/// questions ("where does it live?" and "which group is it in?"), but both are
/// answers to "what am I looking at?", so both are chips, and they compose with
/// the care filter: "Bathroom" and "Needs care" can be lit at once. Counts
/// follow the search and the other lenses, so a chip never promises a plant the
/// list will not show.
///
/// A rail rather than a segmented control: this many labels never fit one track
/// without shrinking the words that name the filter, and the rail scrolls
/// instead of re-flowing into a grid at accessibility sizes.
private struct BrowseRail: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var filter: PlantFilter
    @Binding var selectedRoom: String?
    @Binding var selectedCollection: UUID?
    /// Named rooms only; plants that have never been placed are offered as the
    /// "No room" chip when there is anywhere else for them to be.
    let rooms: [String]
    let hasUnplacedPlants: Bool
    let collections: [PlantCollection]
    let statusCount: (PlantFilter) -> Int
    let onNewCollection: () -> Void

    private var showsScopeGroup: Bool { !rooms.isEmpty || !collections.isEmpty }

    /// The status lenses worth offering.
    ///
    /// A chip reading "Healthy 0" is not a filter, it is inventory: it promises
    /// a list it cannot produce, and tapping it lands the reader on an empty
    /// state they were told about a half-second earlier. A grove of two plants
    /// that both need care was showing three chips, two of them dead. A lens
    /// with nothing behind it steps out of the rail — unless it is the one
    /// currently applied, which has to stay visible so it can be turned off.
    private var statusLenses: [PlantFilter] {
        PlantFilter.allCases.filter { $0 != .all && (statusCount($0) > 0 || filter == $0) }
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(statusLenses) { item in
                    chip(
                        title: item.title,
                        dot: item.statusColor,
                        count: statusCount(item),
                        isSelected: filter == item
                    ) {
                        filter = filter == item ? .all : item
                    }
                }

                if showsScopeGroup {
                    if !statusLenses.isEmpty { divider }
                    chip(title: "All", isSelected: selectedRoom == nil && selectedCollection == nil) {
                        select(room: nil, collection: nil)
                    }
                }

                ForEach(rooms, id: \.self) { room in
                    chip(title: room, glyph: .room(room), isSelected: selectedRoom == room) {
                        select(room: selectedRoom == room ? nil : room, collection: nil)
                    }
                }

                if hasUnplacedPlants && !rooms.isEmpty {
                    chip(title: "No room", isSelected: selectedRoom == "") {
                        select(room: selectedRoom == "" ? nil : "", collection: nil)
                    }
                }

                ForEach(collections) { collection in
                    chip(
                        title: collection.name,
                        glyph: .collection(collection.symbol),
                        isSelected: selectedCollection == collection.id
                    ) {
                        select(
                            room: nil,
                            collection: selectedCollection == collection.id ? nil : collection.id
                        )
                    }
                    .collectionQuickActions(for: collection)
                }

                chip(title: "New collection", glyph: .symbol("plus"), isSelected: false) {
                    onNewCollection()
                }
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        // Bleed to the screen edges so the rail reads as travelling off the
        // page, while the first chip still lines up with the search field above.
        .padding(.horizontal, -GroveTheme.pagePadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter and group plants")
    }

    private enum ChipGlyph {
        case none
        case symbol(String)
        case collection(String)
        case room(String)
    }

    private func select(room: String?, collection: UUID?) {
        selectedRoom = room
        selectedCollection = collection
    }

    private var divider: some View {
        Rectangle()
            .fill(GroveTheme.separator)
            .frame(width: 1, height: 22)
            .accessibilityHidden(true)
    }

    private func chip(
        title: String,
        dot: Color? = nil,
        count: Int? = nil,
        glyph: ChipGlyph = .none,
        isSelected: Bool,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.selection()
            withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : GroveMotion.snap) {
                action()
            }
        } label: {
            HStack(spacing: 7) {
                if let dot {
                    Circle()
                        .fill(isSelected ? GroveTheme.background : dot)
                        .frame(width: 8, height: 8)
                }
                switch glyph {
                case .none:
                    EmptyView()
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.caption.weight(.bold))
                        .accessibilityHidden(true)
                case .collection(let name):
                    GroveCollectionIcon(symbol: name, size: 16)
                        .accessibilityHidden(true)
                case .room(let name):
                    GroveRoomBadge(name: name, size: 20)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(isSelected ? GroveTheme.background.opacity(0.7) : GroveTheme.mutedInk)
                }
            }
            // One chip, two states: white with a hairline, or ink when
            // selected. The rail used to mix grey fills with a green outline.
            .foregroundStyle(tint ?? (isSelected ? GroveTheme.background : GroveTheme.ink))
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(Capsule().fill(isSelected ? GroveTheme.ink : GroveTheme.surface))
            .overlay {
                if !isSelected {
                    Capsule().strokeBorder(GroveTheme.separator, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            // Carry the chip on a 44pt hit target without inflating it.
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(GrovePressStyle())
        .accessibilityLabel(spoken(title, count: count))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func spoken(_ title: String, count: Int?) -> String {
        guard let count else { return title }
        return "\(title), \(count) \(count == 1 ? "plant" : "plants")"
    }
}

// MARK: - Collections

private enum PlantSortOrder: String, CaseIterable, Identifiable {
    case attention = "Needs care"
    case name = "Name"
    case recent = "Recently added"
    var id: Self { self }
}

private enum PlantFilter: String, CaseIterable, Identifiable {
    case all, needsCare, healthy, inactive
    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .needsCare: "Needs care"
        case .healthy: "Healthy"
        case .inactive: "Paused"
        }
    }

    func matches(_ plant: Plant, needsCare: Bool) -> Bool {
        switch self {
        case .all: true
        case .needsCare: needsCare
        case .healthy: plant.effectiveLifecycleState == .active && !needsCare
        case .inactive: plant.effectiveLifecycleState != .active
        }
    }

    /// The dot every chip carries, borrowing the same care colours the rows
    /// below already speak. "All" is not a status, so it carries none. On the
    /// selected chip the dot goes monochrome — the whole chip is committed, and
    /// an olive dot on deep forest would be a smudge.
    var statusColor: Color? {
        switch self {
        case .all: nil
        case .needsCare: GroveTheme.warning
        case .healthy: GroveTheme.healthHealthy
        case .inactive: GroveTheme.mutedInk
        }
    }
}
