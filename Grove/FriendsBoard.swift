import SwiftUI

// MARK: - Type

/// The page's name, set the way Today sets its own: system bold at the large
/// title size, no display face.
struct FriendsPageTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(GroveTheme.ink)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A board section heading: the name, then the fact that explains it.
/// The same anatomy as `TodayBoardSection`'s heading.
struct FriendsSectionTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Tracked small caps, for labels that sit outside a `GroveStatCell`.
struct FriendsSmallCaps: View {
    let text: String
    var tint: Color = GroveTheme.subtleInk

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

/// A row of stat cells that stacks at accessibility sizes, the same rule
/// `TodayBoardRow` follows.
struct FriendsStatRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        let layout: AnyLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
        layout {
            content
        }
    }
}

/// Holds a stat column open when a row has nothing true to put in it, so the
/// columns of every row on the board line up.
struct FriendsEmptyStatCell: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if !dynamicTypeSize.isAccessibilitySize {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 1)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// A pushed board page: the name stays in the bar for Back and VoiceOver,
    /// but the page draws its own large title, so the bar's centre is empty.
    func friendsBoardPage(_ title: String) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
            }
    }
}

// MARK: - Dates

enum FriendsDateText {
    /// "Sun 5"
    static func shortDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day())
    }

    /// "Sun 5 Oct"
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "7:40 am"
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// When someone was last about: "Today", "Yesterday", "Mon", "5 Oct".
    static func recency(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days >= 0, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - Handover

/// One plant-sitting handover the owner has out, whichever way it travelled:
/// an invitation to a Grove friend, or a link.
struct FriendsHandover: Identifiable {
    enum Source {
        case friend(SittingAssignment)
        case link(SittingInvite)
    }

    enum Phase {
        /// A Grove friend has not accepted yet.
        case waiting
        /// A link is live but nobody has opened it.
        case notOpened
        case upcoming
        case active
    }

    let id: UUID
    let source: Source
    let sitterName: String
    let initials: String
    let seed: String
    let plantIDs: [UUID]
    let startDate: Date
    let endDate: Date
    let phase: Phase
    let reportedDone: Int?
    let reportedTotal: Int?
    let canLogCare: Bool
    /// Links carry no check-in permission, so there is nothing to report.
    let canCheckIn: Bool?

    init?(assignment: SittingAssignment, now: Date = .now) {
        let phase: Phase
        switch assignment.currentStatus(now: now) {
        case .invited: phase = .waiting
        case .upcoming: phase = .upcoming
        case .active: phase = .active
        case .completed, .declined, .revoked: return nil
        }
        self.id = assignment.id
        self.source = .friend(assignment)
        self.sitterName = assignment.sitterName
        self.initials = assignment.sitterInitials
        self.seed = assignment.sitterName
        self.plantIDs = assignment.plantIDs
        self.startDate = assignment.startDate
        self.endDate = assignment.endDate
        self.phase = phase
        self.reportedDone = assignment.completedTasks
        self.reportedTotal = assignment.totalTasks > 0 ? assignment.totalTasks : nil
        self.canLogCare = assignment.canLogCare
        self.canCheckIn = assignment.canCheckIn
    }

    init(invite: SittingInvite, now: Date = .now) {
        let phase: Phase
        if now < invite.startDate {
            phase = .upcoming
        } else if invite.hasBeenOpened {
            phase = .active
        } else {
            phase = .notOpened
        }
        let words = invite.sitterLabel.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined().uppercased()
        self.id = invite.id
        self.source = .link(invite)
        self.sitterName = invite.sitterLabel
        self.initials = letters.isEmpty ? "?" : letters
        self.seed = invite.sitterLabel
        self.plantIDs = invite.plantIDs
        self.startDate = invite.startDate
        self.endDate = invite.endDate
        self.phase = phase
        self.reportedDone = invite.completedCareCount
        self.reportedTotal = nil
        self.canLogCare = invite.canLogCare
        self.canCheckIn = nil
    }

    var isLink: Bool {
        if case .link = source { return true }
        return false
    }

    var plantCountText: String {
        let count = plantIDs.count
        return "\(count) \(count == 1 ? "plant" : "plants")"
    }

    /// How far through the trip today is, 0 to 1.
    func elapsed(now: Date = .now) -> Double {
        let span = endDate.timeIntervalSince(startDate)
        guard span > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(startDate) / span))
    }

    var hasStarted: Bool {
        switch phase {
        case .active, .notOpened: true
        case .waiting, .upcoming: false
        }
    }

    /// What the sitter is allowed to do, short enough for a stat cell.
    var canDoValue: String {
        let checkIns = canCheckIn ?? false
        if canLogCare && checkIns { return "Care, check-ins" }
        if canLogCare { return "Care" }
        if checkIns { return "Check-ins" }
        return "View only"
    }

    /// The headline on the Friends card.
    var cardTitle: String {
        switch phase {
        case .active: "\(sitterName) is sitting"
        case .notOpened: "Link sent to \(sitterName)"
        case .upcoming: "\(sitterName) starts \(FriendsDateText.shortDay(startDate))"
        case .waiting: "Waiting for \(sitterName)"
        }
    }

    var cardContext: String {
        switch phase {
        case .active:
            if let total = reportedTotal {
                return "\(plantCountText), \(reportedDone ?? 0) of \(total) tasks done"
            }
            return "\(plantCountText) until \(FriendsDateText.shortDay(endDate))"
        case .notOpened:
            return "\(plantCountText). Not opened yet"
        case .upcoming:
            return "\(plantCountText) until \(FriendsDateText.shortDay(endDate))"
        case .waiting:
            return "\(plantCountText) from \(FriendsDateText.shortDay(startDate))"
        }
    }

    /// The sitting page's headline.
    var boardTitle: String {
        switch phase {
        case .active:
            let days = Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0
            return days <= 7
                ? "\(sitterName) has \(plantCountText) this week"
                : "\(sitterName) has \(plantCountText)"
        case .notOpened:
            return "\(sitterName) hasn't opened the link"
        case .upcoming:
            return "\(sitterName) takes \(plantCountText) from \(FriendsDateText.shortDay(startDate))"
        case .waiting:
            return "Waiting for \(sitterName) to accept"
        }
    }

    var boardContext: String {
        let route = isLink ? "Sitting link" : "Grove friend"
        let state: String
        switch phase {
        case .active: state = "Active"
        case .notOpened: state = "Not opened"
        case .upcoming: state = "Upcoming"
        case .waiting: state = "Invited"
        }
        return "\(route) · \(state)"
    }

    /// The owner-side handover worth putting first: one happening now, then
    /// the soonest to start. Incoming handovers are someone else's trip.
    @MainActor
    static func focus(in store: GroveStore, now: Date = .now) -> FriendsHandover? {
        var all: [FriendsHandover] = []
        for assignment in store.assignments where !assignment.isIncoming {
            if let handover = FriendsHandover(assignment: assignment, now: now) {
                all.append(handover)
            }
        }
        for invite in store.sittingInvites
        where invite.isOutstanding(on: now) && invite.isMinted && !invite.isRevocationPending {
            all.append(FriendsHandover(invite: invite, now: now))
        }
        return all.min { (lhs: FriendsHandover, rhs: FriendsHandover) -> Bool in
            let lhsActive = lhs.phase == .active
            let rhsActive = rhs.phase == .active
            if lhsActive != rhsActive { return lhsActive }
            return lhs.startDate < rhs.startDate
        }
    }

    /// The live handover a friend is part of, matched on the name the
    /// assignment was made out to.
    @MainActor
    static func forFriend(_ friend: PlantFriend, in store: GroveStore, now: Date = .now) -> FriendsHandover? {
        for assignment in store.assignments where !assignment.isIncoming && assignment.sitterName == friend.name {
            if let handover = FriendsHandover(assignment: assignment, now: now) {
                return handover
            }
        }
        return nil
    }
}

// MARK: - Plan

struct SittingPlanItem: Identifiable {
    enum State {
        case done
        case late
        case due
        case planned
    }

    let task: CareTask
    let plant: Plant?
    let date: Date

    var id: UUID { task.id }

    func state(now: Date = .now) -> State {
        if task.isCompleted { return .done }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        if task.dueDate < today { return .late }
        if calendar.isDate(task.dueDate, inSameDayAs: now) { return .due }
        return .planned
    }
}

struct SittingPlanDay: Identifiable {
    let day: Date
    let items: [SittingPlanItem]
    var id: Date { day }
}

extension FriendsHandover {
    /// The owner's own care schedule for the handed-over plants, inside the
    /// trip's dates, one group per day.
    @MainActor
    func plan(in store: GroveStore) -> [SittingPlanDay] {
        let ids = Set(plantIDs)
        let calendar = Calendar.current
        let first = calendar.startOfDay(for: startDate)
        var items: [SittingPlanItem] = []
        for task in store.tasks where ids.contains(task.plantID) {
            let date = task.isCompleted ? task.performedAt : task.dueDate
            guard date >= first, date <= endDate else { continue }
            items.append(SittingPlanItem(task: task, plant: store.plant(id: task.plantID), date: date))
        }
        let grouped: [Date: [SittingPlanItem]] = Dictionary(grouping: items) { (item: SittingPlanItem) -> Date in
            calendar.startOfDay(for: item.date)
        }
        var days: [SittingPlanDay] = []
        for (day, members) in grouped {
            let ordered = members.sorted { (lhs: SittingPlanItem, rhs: SittingPlanItem) -> Bool in
                lhs.date < rhs.date
            }
            days.append(SittingPlanDay(day: day, items: ordered))
        }
        days.sort { (lhs: SittingPlanDay, rhs: SittingPlanDay) -> Bool in lhs.day < rhs.day }
        return days
    }

    /// "2 of 5". The server's count when it has one, otherwise the plan's.
    func doneValue(plan: [SittingPlanDay]) -> String {
        if let total = reportedTotal {
            return "\(reportedDone ?? 0) of \(total)"
        }
        let items = plan.flatMap(\.items)
        if !items.isEmpty {
            let done = items.filter { $0.task.isCompleted }.count
            return "\(done) of \(items.count)"
        }
        return "\(reportedDone ?? 0)"
    }
}

// MARK: - Friends: the handover card

/// The trip, on the map's night-green ground: who has the plants, and a track
/// from the day they started to the day you are home.
struct FriendsHandoverCard: View {
    @Environment(GroveStore.self) private var store
    let handover: FriendsHandover

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
            track
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GroveTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                .strokeBorder(GroveTheme.separator, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens plant sitting")
    }

    private var leadPlant: Plant? {
        handover.plantIDs.compactMap { store.plant(id: $0) }.first
    }

    @ViewBuilder
    private var top: some View {
        if let plant = leadPlant {
            ZStack(alignment: .bottomLeading) {
                PlantThumbnail(plant: plant, height: 150, maxDimension: 900)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipped()
                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0), location: 0.3),
                        .init(color: Color.black.opacity(0.62), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                identity
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }
            .frame(height: 150)
        } else {
            identity
                .padding(.horizontal, 20)
                .padding(.top, 20)
        }
    }

    private var identity: some View {
        let onPhoto = leadPlant != nil
        return HStack(spacing: 10) {
            AvatarView(initials: handover.initials, seed: handover.seed, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(handover.cardTitle)
                    .font(.headline)
                    .foregroundStyle(onPhoto ? Color.white : GroveTheme.ink)
                    .lineLimit(2)
                Text(handover.cardContext)
                    .font(.footnote)
                    .foregroundStyle(onPhoto ? Color.white.opacity(0.85) : GroveTheme.mutedInk)
                    .lineLimit(1)
            }
        }
    }

    private var track: some View {
        let fraction = handover.elapsed()
        return VStack(alignment: .leading, spacing: 12) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(GroveTheme.separator)
                        .frame(height: 4)
                    Capsule()
                        .fill(GroveTheme.healthThriving)
                        .frame(width: max(4, proxy.size.width * fraction), height: 4)
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(GroveTheme.healthThriving)
                        .frame(width: 32, height: 32)
                        .background(GroveTheme.surface, in: Circle())
                        .groveShadow(.resting)
                        .offset(x: markerOffset(width: proxy.size.width, fraction: fraction))
                }
                .frame(height: 32)
            }
            .frame(height: 32)
            .accessibilityHidden(true)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    FriendsSmallCaps(text: handover.hasStarted ? "Since" : "Starts", tint: GroveTheme.subtleInk)
                    Text(FriendsDateText.shortDay(handover.startDate))
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(GroveTheme.ink)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 5) {
                    FriendsSmallCaps(text: "Home", tint: GroveTheme.subtleInk)
                    Text(FriendsDateText.shortDay(handover.endDate))
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(GroveTheme.ink)
                }
            }
        }
    }

    private func markerOffset(width: CGFloat, fraction: Double) -> CGFloat {
        let centre = width * CGFloat(fraction)
        return min(max(0, centre - 16), max(0, width - 32))
    }

    private var accessibilityText: String {
        "\(handover.cardTitle). \(handover.cardContext). From \(FriendsDateText.day(handover.startDate)) to \(FriendsDateText.day(handover.endDate))."
    }
}

// MARK: - Sitting: board header, plan and access

/// The top of the sitting page: what kind of handover, who has what, and the
/// three numbers that matter.
struct SittingBoardHeader: View {
    let handover: FriendsHandover
    let plan: [SittingPlanDay]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(handover.boardContext.uppercased())
                    .font(.footnote.weight(.medium))
                    .tracking(0.6)
                    .foregroundStyle(GroveTheme.subtleInk)
                Text(handover.boardTitle)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            .accessibilityElement(children: .combine)

            FriendsStatRow {
                GroveStatCell(label: "Starts", value: FriendsDateText.day(handover.startDate))
                GroveStatCell(label: "Ends", value: FriendsDateText.day(handover.endDate))
                GroveStatCell(label: "Done", value: handover.doneValue(plan: plan), tint: doneTint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var doneTint: Color {
        let done = handover.reportedDone ?? plan.flatMap(\.items).filter { $0.task.isCompleted }.count
        return done > 0 ? GroveTheme.healthThriving : GroveTheme.ink
    }
}

/// What the sitter is asked to do, day by day, tinted by how it went.
struct SittingPlanCard: View {
    let handover: FriendsHandover
    let plan: [SittingPlanDay]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FriendsSectionTitle(
                title: "The plan",
                subtitle: handover.isLink
                    ? "What the link shows, nothing more"
                    : "What \(handover.sitterName) sees, nothing more"
            )
            .padding(.bottom, 6)

            if plan.isEmpty {
                Text("No care falls due between these dates.")
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .padding(.vertical, 12)
            } else {
                ForEach(plan.indices, id: \.self) { index in
                    dayGroup(plan[index], isLast: index == plan.count - 1)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .groveCard(padding: 0)
    }

    private func dayGroup(_ day: SittingPlanDay, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(FriendsDateText.day(day.day).uppercased())
                .font(.footnote.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(GroveTheme.mutedInk)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            ForEach(day.items) { item in
                SittingPlanRow(item: item)
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(GroveTheme.separator).frame(height: 1)
            }
        }
    }
}

private struct SittingPlanRow: View {
    let item: SittingPlanItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(item.task.kind.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(statusLine)
                    .font(.footnote)
                    .foregroundStyle(statusTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.task.kind.title), \(plantName). \(statusLine)")
    }

    private var plantName: String {
        item.plant?.nickname ?? "Removed plant"
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let plant = item.plant {
            PlantThumbnail(plant: plant, height: 40, maxDimension: 160)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
        } else {
            Image(systemName: item.task.kind.icon)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mutedInk)
                .frame(width: 40, height: 40)
                .background(GroveTheme.secondarySurface, in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
        }
    }

    private var statusLine: String {
        switch item.state() {
        case .done:
            if let completed = item.task.completedAt {
                return "\(plantName). Done, \(FriendsDateText.time(completed))"
            }
            return "\(plantName). Done"
        case .late:
            return "\(plantName). Late"
        case .due:
            return "\(plantName). Due today"
        case .planned:
            return plantName
        }
    }

    private var statusTint: Color {
        switch item.state() {
        case .done: GroveTheme.healthThriving
        case .late, .due: GroveTheme.warning
        case .planned: GroveTheme.mutedInk
        }
    }
}

/// Access as a timetable: what they can do, and when it stops.
struct SittingAccessCard: View {
    let handover: FriendsHandover

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FriendsSectionTitle(title: "Access")
            row("Can do", isLast: false) {
                GroveStatCell(label: "Care", value: handover.canLogCare ? "Record care" : "Read only")
                if let canCheckIn = handover.canCheckIn {
                    GroveStatCell(
                        label: "Check-ins",
                        value: canCheckIn ? "Yes" : "No",
                        tint: canCheckIn ? GroveTheme.ink : GroveTheme.mutedInk
                    )
                } else {
                    // A link has no check-in permission to report; whether it
                    // has been opened is the fact the owner is waiting on.
                    GroveStatCell(
                        label: "Opened",
                        value: linkOpened ? "Yes" : "Not yet",
                        tint: linkOpened ? GroveTheme.ink : GroveTheme.mutedInk
                    )
                }
            }
            row("Ends", isLast: true) {
                GroveStatCell(label: handover.isLink ? "Link" : "Access", value: FriendsDateText.day(handover.endDate))
                GroveStatCell(label: "Then", value: "Closes itself", tint: GroveTheme.healthThriving)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .groveCard(padding: 0)
    }

    private var linkOpened: Bool {
        if case .link(let invite) = handover.source { return invite.hasBeenOpened }
        return false
    }

    private func row<Cells: View>(
        _ title: String,
        isLast: Bool,
        @ViewBuilder cells: () -> Cells
    ) -> some View {
        FriendsStatRow {
            Text(title)
                .font(.body)
                .foregroundStyle(GroveTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            cells()
        }
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(GroveTheme.separator).frame(height: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
