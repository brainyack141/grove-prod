import SwiftUI

struct ActivityView: View {
    @Environment(GroveStore.self) private var store
    @State private var filter = ActivityFilter.all

    private func events(for filter: ActivityFilter) -> [ActivityEvent] {
        switch filter {
        case .all: store.activity
        case .care: store.activity.filter { $0.kind == .sitterCare || $0.kind == .improvement || $0.kind == .milestone }
        case .friends: store.activity.filter { $0.kind == .friendQuestion || $0.kind == .assignment || $0.kind == .friendship }
        }
    }

    var body: some View {
        // Three short titles with no width pressure between them, so they all
        // stay set and the swipe is what the strip gained: the slice under the
        // rule is now a place you can move sideways through, not a filter you
        // have to reach back up to the top of the feed to change.
        VStack(alignment: .leading, spacing: 14) {
            FriendsPageTitle(title: "Updates")
                .padding(.horizontal, GroveTheme.pagePadding)
            GroveSwipeTabs(
                items: ActivityFilter.allCases,
                title: { $0.title },
                selection: $filter
            ) { filter in
                feed(for: filter)
            }
        }
        .padding(.top, GroveTheme.pageTopPadding)
        .groveBackground()
        .friendsBoardPage("Updates")
        // Reading the feed is what clears the bell. Stamped on every appearance
        // rather than once, so an update that lands while the screen is open is
        // still marked read when the user comes back to it.
        .onAppear { store.markActivitySeen() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AppRoute.sitting) {
                    GroveHeaderIcon(symbol: "person.2.badge.gearshape")
                }
                .accessibilityLabel("Plant sitting")
            }
        }
    }

    /// One slice of the feed. Each page scrolls on its own, so a swipe back to
    /// a slice you were reading returns you to where you had got to in it.
    private func feed(for filter: ActivityFilter) -> some View {
        let groups = UpdatesDayGroup.grouped(events(for: filter))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if groups.isEmpty {
                    GroveEmptyState(
                        scene: filter.emptyScene,
                        title: filter.emptyTitle,
                        message: filter.emptyMessage
                    )
                    .frame(minHeight: 360)
                } else {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            FriendsSectionTitle(title: group.title)
                            ForEach(group.events.indices, id: \.self) { index in
                                ActivityRow(
                                    event: group.events[index],
                                    showsDate: group.showsDate,
                                    isLast: index == group.events.count - 1
                                )
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, 16)
            .padding(.bottom, GroveTheme.pageBottomPadding)
        }
    }
}

/// Today, Yesterday, Earlier: the feed read the way a day is remembered.
private struct UpdatesDayGroup: Identifiable {
    let title: String
    let events: [ActivityEvent]
    /// Older rows name the day; today's and yesterday's name the time.
    let showsDate: Bool
    var id: String { title }

    static func grouped(_ events: [ActivityEvent]) -> [UpdatesDayGroup] {
        let calendar = Calendar.current
        let ordered = events.sorted { (lhs: ActivityEvent, rhs: ActivityEvent) -> Bool in
            lhs.timestamp > rhs.timestamp
        }
        var today: [ActivityEvent] = []
        var yesterday: [ActivityEvent] = []
        var earlier: [ActivityEvent] = []
        for event in ordered {
            if calendar.isDateInToday(event.timestamp) {
                today.append(event)
            } else if calendar.isDateInYesterday(event.timestamp) {
                yesterday.append(event)
            } else {
                earlier.append(event)
            }
        }
        var groups: [UpdatesDayGroup] = []
        if !today.isEmpty { groups.append(UpdatesDayGroup(title: "Today", events: today, showsDate: false)) }
        if !yesterday.isEmpty { groups.append(UpdatesDayGroup(title: "Yesterday", events: yesterday, showsDate: false)) }
        if !earlier.isEmpty { groups.append(UpdatesDayGroup(title: "Earlier", events: earlier, showsDate: true)) }
        return groups
    }
}

#Preview {
    AppDestinationsPreviewHost { ActivityView() }
        .environment(GroveStore())
}

private enum ActivityFilter: CaseIterable, Identifiable, Hashable {
    case all
    case care
    case friends
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All"
        case .care: "Care"
        case .friends: "Friends"
        }
    }

    var emptyScene: GroveEmptyScene {
        switch self {
        case .all: .activityAll
        case .care: .activityCare
        case .friends: .activityFriends
        }
    }

    /// Empty copy that names what *this* filter holds.
    ///
    /// One message used to serve all three, and it promised something the app
    /// could not deliver — "when a friend cares for your plants or answers a
    /// question" — under a feed that is mostly a record of the reader's own
    /// care. Worse, it appeared verbatim when a filter simply had no matches, so
    /// a grove with a week of watering in it still read as though nothing had
    /// ever happened.
    var emptyTitle: String {
        switch self {
        case .all: "Nothing here yet"
        case .care: "No care recorded yet"
        case .friends: "Nothing from friends yet"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all:
            "Care you record, check-ins you finish, and anything a plant sitter does for you shows up here."
        case .care:
            "Water something, finish a check-in, or hand your plants to a sitter, and it appears here."
        case .friends:
            "Connection invitations and the trips you hand over land here."
        }
    }
}

private struct ActivityRow: View {
    @Environment(GroveStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let event: ActivityEvent
    var showsDate = false
    var isLast = false

    private var timeLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
    }

    private var plant: Plant? {
        event.plantID.flatMap { store.plant(id: $0) }
    }

    var body: some View {
        Group {
            // Only linked when the plant is still there to open. The row used to
            // link on `plantID` alone, so an entry about a plant the user has
            // since deleted (and the feed keeps those, deliberately) was a tap
            // into an empty detail screen.
            if let plantID = event.plantID, store.plant(id: plantID) != nil {
                NavigationLink(value: AppRoute.plant(plantID)) { rowContent }
                    .buttonStyle(.plain)
            } else if event.kind == .friendship {
                NavigationLink(value: AppRoute.friendInvitations) { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 14) {
            leading
                .padding(.top, 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                timeLayout {
                    Text(sentence)
                        .font(.body)
                        .foregroundStyle(GroveTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(timeText)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(GroveTheme.subtleInk)
                        .lineLimit(1)
                        .fixedSize()
                }
                if let plant, showsPlantThumbnail == false {
                    Text(plant.nickname)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GroveTheme.accentStrong)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle().fill(GroveTheme.separator).frame(height: 1)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Leading picture

    /// A plant's own news wears the plant; a person's news wears the person.
    private var showsPlantThumbnail: Bool {
        guard plant != nil else { return false }
        return isSelf || event.kind == .improvement || event.kind == .milestone
    }

    @ViewBuilder
    private var leading: some View {
        if showsPlantThumbnail, let plant {
            PlantThumbnail(plant: plant, height: 44, maxDimension: 180)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(statusTint(for: plant))
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(GroveTheme.background, lineWidth: 3))
                        .offset(x: 3, y: 3)
                }
        } else {
            // Your own entries wear the portrait you chose, the same one the
            // header pill shows. Passing only the seed left them with a
            // hash-derived stand-in, so "You" had two faces.
            AvatarView(
                initials: event.actorInitials,
                seed: actorAvatarSeed,
                size: 44,
                assetName: isSelf ? store.profile.avatarAssetName : nil,
                photoURL: isSelf ? store.profile.avatarPhotoURL : nil
            )
        }
    }

    private func statusTint(for plant: Plant) -> Color {
        let summary = GrovePlantCareSummary(plant: plant, nextTask: store.nextPendingTask(for: plant.id))
        return summary.status.tone.tint
    }

    // MARK: Text

    /// The actor in bold, then what they did, as one sentence.
    private var sentence: AttributedString {
        var actor = AttributedString(event.actorName)
        actor.inlinePresentationIntent = .stronglyEmphasized
        let rest = AttributedString(" " + event.message)
        return actor + rest
    }

    /// Today and yesterday say the time; anything older says the day.
    private var timeText: String {
        if showsDate {
            return FriendsDateText.recency(event.timestamp)
        }
        return event.timestamp.formatted(.dateTime.hour().minute())
    }

    private var accessibilityText: String {
        var parts: [String] = ["\(event.actorName) \(event.message)"]
        if let plant { parts.append(plant.nickname) }
        parts.append(event.timestamp.formatted(.relative(presentation: .named)))
        return parts.joined(separator: ", ")
    }

    private var isSelf: Bool { event.isSelfAuthored }

    private var actorAvatarSeed: String {
        if isSelf {
            return store.activeAccountID ?? store.profile.username
        }
        return store.friends.first(where: { $0.name == event.actorName })?.id
            ?? event.actorName
    }
}
