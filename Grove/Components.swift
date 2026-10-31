import SwiftUI

/// Renders Grove's bespoke collection artwork while preserving an SF Symbol
/// fallback for collections saved by an older or future app version.
struct GroveCollectionIcon: View {
    let symbol: String
    var size: CGFloat = 32
    var fallbackWeight: Font.Weight = .semibold

    var body: some View {
        Group {
            if let asset = PlantCollection.iconAsset(for: symbol) {
                Image(asset)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.64, weight: fallbackWeight))
            }
        }
        .frame(width: size, height: size)
    }
}
import UIKit

/// The in-content editorial page header: display title over a muted subtitle.
/// Tab roots use `style: .hero`; sheets and pushed content pages use the
/// default `.title`. The accessory slot holds a trailing element (a streak
/// pill, a count) aligned with the title block.
///
/// There is deliberately no eyebrow here. A tracked-out label above the title
/// ("GROW YOUR CIRCLE" over "Invite a friend") only restates the headline in
/// smaller type, and stacking two headlines makes the page read as a template
/// rather than a screen. Anything genuinely informative — a species, a
/// username, a step count — belongs beside or below the title, not above it.
struct GrovePageHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var style: GroveDisplayStyle = .title
    @ViewBuilder var accessory: Accessory

    init(
        title: String,
        subtitle: String? = nil,
        style: GroveDisplayStyle = .title,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                GroveDisplayHeading(text: title, style: style)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            if !(accessory is EmptyView) {
                Spacer(minLength: 8)
                accessory
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension GrovePageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, style: GroveDisplayStyle = .title) {
        self.init(title: title, subtitle: subtitle, style: style) { EmptyView() }
    }
}

/// A plant as the user last saw it: its newest photograph, falling back to the
/// generated artwork until one exists.
///
/// Every plant enters Grove through a photo and every check-in adds another,
/// yet the only place any of them appeared was the Today hero — the grid, the
/// collections and a plant's own page all drew a gradient over pictures that
/// were sitting on disk. `GroveStore.latestPhotoURL(for:)` decides which photo
/// counts; this decides how it is drawn.
struct PlantThumbnail: View {
    @Environment(GroveStore.self) private var store
    let plant: Plant
    /// A fixed strip height, or `nil` to take the width it is given and stand
    /// `aspectRatio` tall — which is what a photo-first tile wants, since the
    /// picture should set the card's proportions rather than fit a slot.
    var height: CGFloat? = 124
    /// Width ÷ height, used when `height` is `nil`. Portrait by default: a
    /// houseplant is taller than it is wide, and a landscape crop of one is
    /// mostly the wall behind it.
    var aspectRatio: CGFloat = 3.0 / 4.0
    /// Decode budget in pixels. A grid card is about 180pt wide, so 600 covers
    /// a 3x screen with room to spare; heroes ask for more.
    var maxDimension: CGFloat = 600
    /// Passed to the drawn fallback. Worth it where the fallback stands in for
    /// a hero photograph; not worth a timeline per cell in a scrolling grid.
    var breathes: Bool = false

    @State private var image: UIImage?

    private var photoURL: URL? { store.latestPhotoURL(for: plant.id) }

    @ViewBuilder
    private var art: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            PlantPortrait(plant: plant, height: height, breathes: breathes)
        }
    }

    var body: some View {
        Group {
            if let height {
                art
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            } else {
                // The clear rectangle is the one that gets measured; the
                // photograph overflows it and is cropped by `clipped` below.
                Color.clear
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .overlay { art }
            }
        }
        .clipped()
        // `clipped` hides the overflow but leaves it tappable, and
        // `scaledToFill` on a portrait photo overflows a wide tile by more than
        // its own height. Inside a card that is a link, that bled the card's tap
        // target across its neighbours — on Today, the top row of plants reached
        // up over the feed tabs, so aiming at "For you" opened a plant.
        .contentShape(.rect)
        // A crossfade, not a spring: the artwork underneath is a placeholder
        // being replaced, and springing it would draw the eye to the swap.
        .animation(.easeOut(duration: 0.35), value: image)
        .task(id: photoURL) {
            guard let photoURL else {
                image = nil
                return
            }
            // Resolved here rather than in `photoURL` so the container re-rooting
            // a reinstall needs costs a stat off the body's path, not on it.
            guard let resolved = GroveMediaPath.resolved(photoURL) else {
                image = nil
                return
            }
            image = await GroveThumbnailCache.thumbnail(at: resolved, maxDimension: maxDimension)
        }
        .accessibilityHidden(true)
    }
}

/// The 0–100 health reading as a ring around its own number.
///
/// The score has been drawn as a ring in four places (the profile avatar, the
/// Today stats row, the scan result, and now the plant list) and hand-rolled
/// each time. This is the shared spelling for the small, inline case: a track
/// in `separator`, the read in the band's colour, and the number in the middle
/// so the ring is a picture of a figure rather than a decoration beside one.
struct HealthScoreRing: View {
    let score: Int
    let band: HealthBand
    var diameter: CGFloat = 44
    var lineWidth: CGFloat = 3

    private var clamped: Int { min(max(score, 0), 100) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(GroveTheme.separator, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: CGFloat(clamped) / 100)
                .stroke(band.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // Start at twelve o'clock, so the arc reads as a gauge filling
                // rather than as a shape that happens to be open on one side.
                .rotationEffect(.degrees(-90))
                .groveAnimation(GroveMotion.settle, value: clamped)

            Text("\(clamped)")
                .font(.footnote.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(GroveTheme.ink)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel("Health \(clamped) out of 100, \(band.title)")
    }
}

/// One care interpretation shared by library filters, sorting and row labels.
/// Day boundaries match the schedule: a task later today is due today.
struct GrovePlantCareSummary {
    let plant: Plant
    let nextTask: CareTask?
    var now: Date = .now

    private var isActive: Bool { plant.effectiveLifecycleState == .active }

    private func days(until date: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
    }

    var dueDate: Date {
        min(plant.nextCheckIn, nextTask?.dueDate ?? .distantFuture)
    }

    var needsCare: Bool {
        isActive && ((plant.hasHealthReading && plant.healthBand.needsAttention) || days(until: dueDate) <= 0)
    }

    var priority: Int {
        guard isActive else { return 4 }
        if plant.hasHealthReading && plant.healthBand == .urgent { return 0 }
        if plant.hasHealthReading && plant.healthBand.needsAttention { return 1 }
        return needsCare ? 2 : 3
    }

    private var showsHealth: Bool { isActive && plant.hasHealthReading && plant.healthBand.needsAttention }

    private var showsTask: Bool {
        guard let nextTask else { return false }
        return nextTask.dueDate <= plant.nextCheckIn
    }

    /// The one thing this plant is asking for, in the app's one status
    /// vocabulary.
    ///
    /// Health and schedule are deliberately separate tones. "Urgent" is the
    /// plant; "Water overdue" is the calendar. They used to share `danger` red,
    /// which meant a library of two plants — one dying, one merely un-photographed
    /// — showed two identical red lines and told the reader nothing.
    ///
    /// The health case also stops appending an instruction. It used to read
    /// "Urgent · Review plant", which is a status and a command welded together
    /// in a slot that holds one sentence; the row's own trailing control is
    /// where "what to do about it" belongs.
    var status: GroveStatus {
        guard isActive else {
            return GroveStatus(.quiet, plant.effectiveLifecycleState.title)
        }
        if showsHealth {
            return GroveStatus(
                plant.healthBand == .urgent ? .urgent : .attention,
                plant.healthBand.title
            )
        }
        let noun = showsTask ? nextTask!.kind.scheduleNoun : "Check-in"
        switch days(until: dueDate) {
        case ..<0: return GroveStatus(.late, "\(noun) overdue")
        case 0: return GroveStatus(.due, "\(noun) today")
        case 1: return GroveStatus(.quiet, "\(noun) tomorrow")
        case let days: return GroveStatus(.quiet, "\(noun) in \(days) days")
        }
    }

    /// The status as plain text, for spoken labels and analytics.
    var title: String { status.text }

    /// How many plants need you today, counted from raw arrays.
    ///
    /// The one count behind the Today tab badge, the app-icon badge and the
    /// rooms map caption. They used to count different things (due *tasks* on
    /// the badges, *plants* on the map), so one thirsty plant with three jobs
    /// read as 3 on the icon and 1 on the card.
    static func needingCareCount(plants: [Plant], tasks: [CareTask], now: Date = .now) -> Int {
        var nextTasks: [UUID: CareTask] = [:]
        for task in tasks where !task.isCompleted {
            if let current = nextTasks[task.plantID], current.dueDate <= task.dueDate { continue }
            nextTasks[task.plantID] = task
        }
        return plants.filter {
            GrovePlantCareSummary(plant: $0, nextTask: nextTasks[$0.id], now: now).needsCare
        }.count
    }
}

extension GroveStore {
    /// The plants Today draws: only those still in active care. Archived,
    /// remembered and dormant plants keep their pages in My Grove, but a
    /// remembered fern lit up green on the rooms map, or named in the hero as
    /// "doing fine", is a small cruelty.
    var activePlants: [Plant] {
        plants.filter { $0.effectiveLifecycleState == .active }
    }

    /// `GrovePlantCareSummary.needingCareCount` for this grove. Reads the
    /// stored calendar day so a badge drawn from it moves at midnight.
    var plantsNeedingCareCount: Int {
        _ = calendarDay
        return plants.filter {
            GrovePlantCareSummary(plant: $0, nextTask: nextPendingTask(for: $0.id)).needsCare
        }.count
    }
}

/// A plant in a grid: an uncovered photograph with its name on the canvas.
///
/// This used to be a 124pt strip of the user's photo stacked on a white tray
/// carrying the name, the species, the band and the trend — four rows of chrome
/// under a letterbox of the one thing on the screen anybody wants to look at.
/// The picture took the whole tile in reply, and the type moved onto it behind
/// two scrims and a text shadow.
///
/// That trade only works if the photographs are controllable, and Grove's are
/// not: they are shot at night, on a windowsill against a bright window, in a
/// room with a television in it. Type laid over a picture like that is legible
/// only in proportion to how much of the picture you are willing to darken, and
/// the scrims had grown to cover roughly 60% of the frame to hold a name at
/// 0.72 opacity. So the photo keeps the tile — uncovered, at 4:5 — and the name
/// sits under it in ink on bone, where its contrast is a property of the theme
/// rather than of the wall behind the plant. The card is the same height it was;
/// the caption strip is paid for out of the shorter crop.
///
/// The score and the band remain one mark, because 80 and "Healthy" were always
/// the same fact said twice.
struct PlantCard: View {
    @Environment(GroveStore.self) private var store
    let plant: Plant

    private var care: GrovePlantCareSummary {
        GrovePlantCareSummary(plant: plant, nextTask: store.nextPendingTask(for: plant.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            PlantThumbnail(
                plant: plant,
                height: nil,
                aspectRatio: 4.0 / 5.0,
                maxDimension: 800
            )
            .overlay(alignment: .topTrailing) { score }
            .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            .groveEdgeLight()
            .groveShadow(.resting)

            caption
        }
        // The tap target is the photo *and* its caption: the name under a
        // picture is part of the same object, and aiming at it should open the
        // plant rather than fall through to the grid.
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            plant.hasHealthReading
                ? "\(plant.nickname), \(plant.species), score \(plant.healthScore), \(plant.healthBand.title). \(care.status.text)"
                : "\(plant.nickname), \(plant.species), no health reading yet. \(care.status.text)"
        )
    }

    /// Band and score as one mark, now a light pill rather than a dark one. A
    /// near-white capsule reads on every photograph — a black one only reads on
    /// bright ones — and on white the band can use its true on-canvas colour
    /// instead of the dark-appearance twin. The pill is pinned to the light
    /// appearance so that colour resolves the same way in both modes; `white`
    /// and `inkOnLight` do not flip, and neither should the dot between them.
    private var score: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(plant.hasHealthReading ? plant.healthBand.color : GroveTheme.mutedInk)
                .frame(width: 7, height: 7)
            Text(plant.hasHealthReading ? "\(plant.healthScore)" : "New")
                .font(.footnote.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(GroveTheme.inkOnLight)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.white.opacity(0.92), in: Capsule())
        .environment(\.colorScheme, .light)
        .padding(10)
    }

    /// Name, then the one thing this plant is asking for.
    ///
    /// The caption used to carry a species line and a trend arrow underneath the
    /// name — three facts, none of which is why the tab was opened. The species
    /// is already on the plant's own page, the trend is already inside the score
    /// pill's colour, and neither answers "does this one need me?". The status
    /// line does, in the same words and the same colours the care rows one tab
    /// over use, so a plant says the same thing about itself wherever it is
    /// standing.
    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(plant.nickname)
                .font(.headline)
                .foregroundStyle(GroveTheme.ink)
                .lineLimit(1)
            GroveStatusLabel(status: care.status, lineLimit: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

/// Long-press quick actions for an owned plant, wherever its card appears.
///
/// A plant card was a single destination: to water something you had already
/// watered, or to open the camera because a leaf looked wrong, you went in to
/// the profile, found the action, and came back out. These are the four things
/// people actually do to a plant, one press from the grid — and "Log care" is
/// the first way in the app to record care that Grove never scheduled.
///
/// The menu ends where every iOS collection's does: a red row at the bottom,
/// behind a confirmation. Removing a plant was previously only reachable by
/// opening it and finding the overflow menu, which is two screens away from the
/// place people realise a plant is gone — the grid they are looking at.
private struct PlantQuickActionsModifier: ViewModifier {
    @Environment(GroveStore.self) private var store
    @Environment(IntentRouter.self) private var router: IntentRouter?
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    let plant: Plant
    /// Set when the card is being shown *inside* a collection, which adds the
    /// narrower destructive action — leaving the shelf, not the grove. Filing a
    /// plant out of a group and deleting its whole record are a tap apart in the
    /// same menu, so the reversible one is named first and left unstyled.
    let collectionID: UUID?

    @State private var isCreatingCollection = false
    @State private var isConfirmingRemoval = false

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                Haptics.tap()
                router?.push(.checkIn(plant.id))
            } label: {
                Label("Check in", systemImage: "camera.viewfinder")
            }

            Menu {
                ForEach(CareKind.loggable, id: \.self) { kind in
                    Button {
                        log(kind)
                    } label: {
                        Label(kind.logTitle, systemImage: kind.icon)
                    }
                }
            } label: {
                Label("Log care", systemImage: "checkmark.circle")
            }

            Button {
                Haptics.tap()
                router?.push(.liveScan(.diagnose, plant.id))
            } label: {
                Label("Diagnose", systemImage: "stethoscope")
            }

            Menu {
                PlantCollectionMenu(plant: plant) { isCreatingCollection = true }
            } label: {
                Label("Add to collection", systemImage: "folder.badge.plus")
            }

            Divider()

            Button {
                Haptics.tap()
                router?.push(.editPlant(plant.id))
            } label: {
                Label("Edit plant", systemImage: "pencil")
            }

            ShareLink(
                item: plant.hasHealthReading
                    ? "\(plant.nickname) is \(plant.healthBand.title.lowercased()) at \(plant.healthScore)% in Grove."
                    : "\(plant.nickname) just joined my Grove.",
                subject: Text("How \(plant.nickname) is doing")
            ) {
                Label("Share progress", systemImage: "square.and.arrow.up")
            }

            Divider()

            if let collectionID {
                Button {
                    Haptics.toggle(on: false)
                    store.toggleMembership(plantID: plant.id, inCollection: collectionID)
                } label: {
                    Label("Remove from this collection", systemImage: "folder.badge.minus")
                }
            }

            Button(role: .destructive) {
                isConfirmingRemoval = true
            } label: {
                Label("Delete plant", systemImage: "trash")
            }
        }
        .sheet(isPresented: $isCreatingCollection) {
            CreateCollectionView(preselecting: [plant.id])
        }
        .confirmationDialog(
            "Delete \(plant.nickname) from your grove?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Delete plant", role: .destructive) {
                // A deletion that cannot be undone lands as a warning, not as
                // the same tap as everything else.
                Haptics.warning()
                // Animated because the grid closes over the gap. A card that
                // simply stops existing makes its neighbours jump, which reads
                // as a glitch at exactly the moment the user wants to be sure
                // the right plant went.
                withAnimation(GroveMotion.settle) { _ = store.deletePlant(id: plant.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // The delete is synced, so the warning says so: "on this device"
            // understated it at the one moment precision is the kindness.
            Text("Every check-in, photo, care task and note for \(plant.nickname) is deleted on every synced device. There is no undo.")
        }
    }

    private func log(_ kind: CareKind) {
        // Held locally so the undo closure, which outlives this view update,
        // never reaches back through `@Environment` to find it.
        let store = self.store
        // The store refuses a repeat watering; without this the menu answered
        // with an error buzz and no reason, which reads as a broken tap.
        if kind == .water, let last = store.lastWatering(for: plant.id) {
            Haptics.warning()
            toasts?.show(
                RecentWateringGuard.message(lastWateredAt: last.performedAt),
                symbol: "drop.triangle"
            )
            return
        }
        guard let logged = store.logCare(plantID: plant.id, kind: kind) else {
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
}

/// Long-press quick actions for a collection, wherever its card appears.
///
/// The shelf on My Grove was the one card grid in the app you could not act on
/// without opening it first: renaming a collection you had just made, or
/// deleting one you made by accident, meant a push, an overflow menu and a pop.
/// The menu here is the same one the detail screen's ellipsis carries, so the
/// two never drift apart.
private struct CollectionQuickActionsModifier: ViewModifier {
    @Environment(GroveStore.self) private var store
    let collection: PlantCollection

    @State private var isEditing = false
    @State private var isDelegating = false
    @State private var isConfirmingDelete = false

    private var isEmpty: Bool { collection.plantIDs.isEmpty }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    Haptics.tap()
                    isEditing = true
                } label: {
                    Label("Manage plants & details", systemImage: "slider.horizontal.3")
                }

                Button {
                    Haptics.tap()
                    isDelegating = true
                } label: {
                    Label("Assign to a sitter", systemImage: "person.2")
                }
                .disabled(isEmpty)

                Divider()

                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete collection", systemImage: "trash")
                }
            }
            .sheet(isPresented: $isEditing) {
                CreateCollectionView(editing: collection)
            }
            .sheet(isPresented: $isDelegating) {
                NavigationStack {
                    SittingLinkView(preselectedPlantIDs: Set(collection.plantIDs), recipient: .friend)
                }
            }
            .confirmationDialog(
                "Delete “\(collection.name)”?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete collection", role: .destructive) {
                    Haptics.warning()
                    store.deleteCollection(id: collection.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The plants stay exactly where they are. Only the grouping goes.")
            }
    }
}

extension View {
    /// Adds the shared long-press quick actions for an owned plant.
    ///
    /// - Parameter collectionID: the collection the card is being shown inside,
    ///   if any, which adds "Remove from this collection" to the menu.
    func plantQuickActions(for plant: Plant, in collectionID: UUID? = nil) -> some View {
        modifier(PlantQuickActionsModifier(plant: plant, collectionID: collectionID))
    }

    /// Adds the shared long-press quick actions for a collection.
    func collectionQuickActions(for collection: PlantCollection) -> some View {
        modifier(CollectionQuickActionsModifier(collection: collection))
    }
}

// MARK: - Collection membership, from the plant

/// Menu contents for filing one plant into collections: every collection with a
/// tick for the ones it already belongs to, then a way to make a new one.
///
/// Membership used to be authored only from the other end — open a collection,
/// scroll a checklist of every plant you own, tick some. But "this one is a
/// rescue" is a thought that arrives while you are looking at the plant, so the
/// store has always carried `toggleMembership` for exactly this; nothing called
/// it until now.
struct PlantCollectionMenu: View {
    @Environment(GroveStore.self) private var store
    let plant: Plant
    /// Invoked instead of toggling, when the user wants a collection that does
    /// not exist yet. The host owns the sheet, because a context menu cannot.
    let onCreateNew: () -> Void

    var body: some View {
        ForEach(store.collections) { collection in
            let isMember = collection.plantIDs.contains(plant.id)
            Button {
                Haptics.toggle(on: !isMember)
                store.toggleMembership(plantID: plant.id, inCollection: collection.id)
            } label: {
                // A ticked row reads as "already in here"; an unticked one wears
                // the collection's own icon so the list stays scannable.
                HStack {
                    if isMember {
                        Image(systemName: "checkmark")
                    } else {
                        GroveCollectionIcon(symbol: collection.symbol, size: 18)
                    }
                    Text(collection.name)
                }
            }
        }

        if !store.collections.isEmpty { Divider() }

        Button {
            Haptics.tap()
            onCreateNew()
        } label: {
            Label("New collection…", systemImage: "folder.badge.plus")
        }
    }
}

struct FriendPlantCard: View {
    let plant: FriendPlant

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlantPortrait(friendPlant: plant, height: 124)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plant.nickname)
                        .font(.headline)
                        .lineLimit(1)
                    Text(plant.species)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(plant.healthBand.color)
                        .frame(width: 7, height: 7)
                    Text(plant.healthBand.shortTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(GroveTheme.mutedInk)
                    Spacer(minLength: 4)
                }
            }
            .padding(12)
        }
        .background(GroveTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .groveEdgeLight()
        .groveShadow(.resting)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(plant.nickname), \(plant.species), \(plant.healthBand.title)")
    }
}

/// The one section-title treatment: a `.section` display heading, optional
/// muted subtitle, and either a green action button or a custom trailing
/// element (a count, a "New" button) on the title's baseline.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    init(
        title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                GroveDisplayHeading(text: title, style: .section)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.accentStrong)
            }
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, actionTitle: actionTitle, action: action) { EmptyView() }
    }
}

// MARK: - Search

/// Grove's one in-content search field.
///
/// Friends used the system `.searchable` bar — a grey capsule the OS hangs
/// under the navigation bar, above the page — while My Grove drew its own
/// field inside the page. Same job, two controls, two heights, two places on
/// the screen. One field now, on the page, with the sort control or nothing
/// beside it. Compact radius because it is a control, not a card.
struct GroveSearchBar: View {
    @Binding var text: String
    let prompt: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(GroveTheme.mutedInk)
            TextField(prompt, text: $text)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(isFocused)
                .submitLabel(.search)
                .onSubmit { isFocused.wrappedValue = false }
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(GroveTheme.mutedInk)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, text.isEmpty ? 12 : 0)
        .frame(minHeight: 44)
        .background(
            GroveTheme.secondarySurface,
            in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
        )
    }
}

// MARK: - Branded buttons

/// The compact/content variant of Grove's shared primary capsule. It keeps the
/// same green gradient and centred lockup while allowing buttons inside a row
/// to hug their content.
struct GroveInkLabel: View {
    let title: String
    var systemImage: String?
    /// A bundled template mark drawn in the label's own colour — for the one
    /// glyph that is Grove's rather than the system's (the scan mark). Wins
    /// over `systemImage` when both are set.
    var imageAsset: String?
    var size: GroveButtonSize = .regular

    /// The mark matches the subheadline's line height, so a pill carrying it
    /// stands exactly as tall as the text-only form and grows with the type.
    @ScaledMetric(relativeTo: .subheadline) private var markSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 8) {
            if let imageAsset {
                Image(imageAsset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: markSize, height: markSize)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.bold))
            }
            Text(title)
        }
        .grovePrimaryPill(size: size)
    }
}

struct GroveInkButton: View {
    let title: String
    var systemImage: String?
    var imageAsset: String?
    var size: GroveButtonSize = .regular
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GroveInkLabel(title: title, systemImage: systemImage, imageAsset: imageAsset, size: size)
        }
        .buttonStyle(GrovePressStyle())
        .accessibilityLabel(title)
    }
}

// MARK: - The scan call to action

/// The "Scan a plant" pill.
///
/// Every empty grove in the app ends in this button, which makes it the one
/// control a brand-new user is most likely to look at and least likely to have
/// a reason to trust yet. It is a `GroveInkLabel` in every respect but one: its
/// mark behaves like the thing it opens. Every few seconds a bar of light
/// travels down through the viewfinder and the brackets rack focus and lock —
/// the same gesture the camera makes a second later on the scan screen. The
/// button rehearses the camera before the camera arrives.
///
/// The motion is deliberately periodic *and finite*. A control that never stops
/// moving stops meaning anything and starts reading as a spinner. This one looks
/// up three times, spaced further apart each time, and then goes still — the
/// manners of a good attention cue, which asks and then trusts you. It starts
/// over whenever the screen is returned to, because that is a new arrival.
///
/// Deliberately not a flag on `GroveInkLabel`: this is one button in the
/// product, not a treatment other buttons may opt into.
struct GroveScanCTALabel: View {
    var title: String = "Scan a plant"
    var size: GroveButtonSize = .compact

    @Environment(\.groveIsPressed) private var isPressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ScaledMetric(relativeTo: .subheadline) private var markSize: CGFloat = 20

    /// Where the light sits, in mark heights from centre. It rests outside the
    /// glyph, so between passes there is nothing at all to see.
    @State private var scanLine: CGFloat = -0.9
    /// The focus rack: the brackets pull in a hair before they lock back open.
    @State private var markScale: CGFloat = 1

    var body: some View {
        HStack(spacing: 10) {
            mark
            Text(title)
        }
        .grovePrimaryPill(size: size)
        .task { await focusLoop() }
    }

    // MARK: Mark

    private var mark: some View {
        ZStack {
            // Held just under full strength so the pass has somewhere to go.
            // At rest under Reduce Motion there is no pass, so no headroom is
            // needed and the mark sits at its normal weight.
            glyph.opacity(reduceMotion ? 1 : 0.82)
            scanLight
        }
        .frame(width: markSize, height: markSize)
        .scaleEffect(markScale)
        // The mark compresses harder than the pill around it: the difference
        // between a button that moves and a button that has parts.
        .scaleEffect(isPressed && !reduceMotion ? 0.88 : 1)
        .animation(GroveMotion.press, value: isPressed)
        .accessibilityHidden(true)
    }

    private var glyph: some View {
        Image("GroveScanGlyph")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: markSize, height: markSize)
    }

    /// The bar travelling down the viewfinder, clipped to the glyph itself. That
    /// clipping is the whole difference between a scanner passing over a mark
    /// and a sheen passing over a button — the second is a loading skeleton.
    private var scanLight: some View {
        Color.clear
            .frame(width: markSize, height: markSize)
            .overlay {
                LinearGradient(
                    colors: [.clear, GroveTheme.onCanvasButtonLabel, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: markSize * 0.75)
                .offset(y: scanLine * markSize)
            }
            .mask(glyph)
            .allowsHitTesting(false)
    }

    // MARK: Cadence

    /// Waits before each pass, then stops. The gaps widen so the button fades
    /// out of the conversation rather than cutting off mid-thought — and the
    /// first gap is long enough that the screen has finished arriving.
    private static let cadence: [Duration] = [.seconds(1.4), .seconds(4.4), .seconds(6.2)]

    private func focusLoop() async {
        guard !reduceMotion else { return }
        for gap in Self.cadence {
            try? await Task.sleep(for: gap)
            guard !Task.isCancelled else { return }
            await focusPass()
        }
    }

    /// One pass: the light falls through the mark while the brackets close, and
    /// they snap open again as it leaves. `pop` is the app's curve for a mark
    /// that lands, which is exactly what a lock is.
    private func focusPass() async {
        withAnimation(.easeInOut(duration: 0.62)) { scanLine = 0.9 }
        withAnimation(.easeOut(duration: 0.26)) { markScale = 0.92 }
        try? await Task.sleep(for: .seconds(0.34))
        withAnimation(GroveMotion.pop) { markScale = 1 }
        try? await Task.sleep(for: .seconds(0.42))
        scanLine = -0.9
    }
}

/// `GrovePressStyle` with the press published downward, so the scan mark can
/// respond with more than the uniform squeeze the style applies to the pill.
struct GroveScanCTAStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration)
    }

    private struct PressBody: View {
        let configuration: Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .environment(\.groveIsPressed, configuration.isPressed)
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
                .opacity(configuration.isPressed ? 0.92 : 1)
                .animation(GroveMotion.press, value: configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, isPressed in
                    guard isPressed else { return }
                    Haptics.press()
                }
        }
    }
}

private struct GroveIsPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// A button's press state, published to its own label. `ButtonStyle` sees
    /// the press but only wraps the label; this lets the label's insides answer
    /// the touch too.
    var groveIsPressed: Bool {
        get { self[GroveIsPressedKey.self] }
        set { self[GroveIsPressedKey.self] = newValue }
    }
}

/// The stroked capsule: Grove's one secondary action treatment. `onDark` keeps
/// it legible on camera-black and full-colour surfaces without promoting it to
/// the green primary style.
struct GroveOutlineLabel: View {
    let title: String
    var systemImage: String?
    var size: GroveButtonSize = .regular
    var onDark: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).font(.subheadline.weight(.bold))
            }
            Text(title)
        }
        .font(.headline.weight(.semibold))
        .foregroundStyle(onDark ? Color.white : GroveTheme.ink)
        .padding(.horizontal, size.horizontalPadding)
        .padding(.vertical, size.verticalPadding)
        .frame(maxWidth: size.fillsWidth ? CGFloat.infinity : nil, minHeight: size.minimumHeight)
        .background(
            onDark ? AnyShapeStyle(Color.white.opacity(0.10)) : AnyShapeStyle(GroveTheme.surface),
            in: Capsule()
        )
        .overlay {
            Capsule().stroke(
                onDark ? Color.white.opacity(0.45) : GroveTheme.separator,
                lineWidth: 1.5
            )
        }
        .contentShape(Capsule())
    }
}

struct GroveOutlineButton: View {
    let title: String
    var systemImage: String?
    var size: GroveButtonSize = .regular
    var onDark: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GroveOutlineLabel(title: title, systemImage: systemImage, size: size, onDark: onDark)
        }
        .buttonStyle(GrovePressStyle())
        .accessibilityLabel(title)
    }
}

// MARK: - Docked action bar

/// The one docked bottom action bar. Pages used to each invent their own —
/// a hard `surface` band with a divider here, `.bar` material there, a
/// half-opaque canvas elsewhere — so the same moment (the page's committing
/// action) looked different on every screen. Now content always dissolves into
/// the canvas under one gradient.
///
/// Use it inside `.safeAreaInset(edge: .bottom)` so scrolled content ends above
/// the bar instead of behind it.
private struct GroveActionBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background {
                // A solid dock with one hairline. The fade it replaced let the
                // card behind show through the button, which read as a bug.
                GroveTheme.background
                    .overlay(alignment: .top) {
                        Rectangle().fill(GroveTheme.separator).frame(height: 1)
                    }
                    .ignoresSafeArea()
            }
    }
}

extension View {
    /// Docks this view as the page's bottom action bar.
    func groveActionBar() -> some View {
        modifier(GroveActionBarModifier())
    }
}

struct GroveMetric: View {
    let value: String
    let label: String
    var symbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GroveTheme.accent)
                }
                Text(value)
                    .font(.title3.weight(.bold))
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(GroveTheme.mutedInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one capsule progress bar. XP, course progress, sitting tasks, and
/// onboarding all draw progress with this exact track so "how far along"
/// looks identical everywhere.
struct GroveProgressBar: View {
    /// 0…1 fraction of the bar to fill.
    let fraction: Double
    var tint: Color = GroveTheme.accent
    var height: CGFloat = 8
    /// Minimum visible fill so "just started" never reads as empty. Pass 0 to
    /// allow a truly empty bar.
    var minimumFill: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(GroveTheme.secondarySurface)
                Capsule()
                    .fill(
                        // A soft gradient along the fill rather than a flat
                        // block: progress reads as something that travelled to
                        // where it is, not a rectangle that was drawn there.
                        LinearGradient(
                            colors: [tint.opacity(0.75), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(minimumFill, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        // Progress that jumps loses the very thing a progress bar is for. The
        // fill now travels to its new length whenever the fraction changes.
        .groveAnimation(GroveMotion.settle, value: fraction)
        .accessibilityHidden(true)
    }
}

// Grove's empty states live in `GroveEmptyState.swift`. What used to be here —
// `EmptyStateView`, a thin wrapper around `ContentUnavailableView` — put Apple's
// stock component and an SF Symbol on the first screens a new user ever sees.

// MARK: - Share hand-off

/// A prepared file, wrapped so `sheet(item:)` can present the moment it exists
/// rather than juggling a boolean and a separately stored URL that could
/// disagree about which file is being shared.
struct GroveSharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet.
///
/// `ShareLink` needs its item before the tap, and Grove's two shareable files —
/// a data export and a Living Record film — are both built on demand: one is a
/// plaintext copy of the whole account graph, the other takes seconds of image
/// work per check-in. Neither should exist speculatively just so a button can
/// be a `ShareLink`.
struct GroveShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
