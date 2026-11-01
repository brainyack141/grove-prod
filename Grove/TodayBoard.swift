import SwiftUI

// MARK: - The board

/// Today as a departures board.
///
/// Flighty's insight is that a status-heavy list reads fastest when every row
/// has the same anatomy: a lit dot that says how things stand, a short code you
/// learn without trying, and a row of small-caps labels over large values. A
/// grove is exactly that kind of list: six plants, each one either fine, due or
/// in trouble. The map above the list is the board's globe: the home, room by
/// room, with one dot per plant, so the first glance answers "is anything
/// wrong, and where" before a word is read.
struct TodayBoardEntry: Identifiable {
    let plant: Plant
    let summary: GrovePlantCareSummary
    let rhythm: WateringRhythm
    /// Three letters from the nickname, the way an airport is three letters.
    /// "Monty" is MON. Unique within the grove when the entry is built with
    /// its siblings (see `codes(for:)`), so two dots on the map never share a
    /// label; on its own it is the plain prefix.
    let code: String

    var id: UUID { plant.id }

    /// Pass `siblings` (the whole grove, archived plants included, so a
    /// code does not shift when another plant is archived) to get the same
    /// collision-free code every surface prints.
    init(plant: Plant, nextTask: CareTask?, tasks: [CareTask], siblings: [Plant] = [], now: Date = .now) {
        let code = siblings.isEmpty ? nil : Self.codes(for: siblings)[plant.id]
        self.init(plant: plant, nextTask: nextTask, tasks: tasks, code: code, now: now)
    }

    private init(plant: Plant, nextTask: CareTask?, tasks: [CareTask], code: String?, now: Date) {
        self.plant = plant
        self.summary = GrovePlantCareSummary(plant: plant, nextTask: nextTask, now: now)
        self.rhythm = WateringRhythm(plantID: plant.id, tasks: tasks, now: now)
        self.code = code ?? Self.candidates(for: plant.nickname).first ?? "—"
    }

    /// A whole board's entries, with codes allocated once across `siblings`.
    static func board(
        plants: [Plant],
        siblings: [Plant],
        nextTask: (UUID) -> CareTask?,
        tasks: [CareTask],
        now: Date = .now
    ) -> [TodayBoardEntry] {
        let codes = codes(for: siblings)
        return plants.map {
            TodayBoardEntry(plant: $0, nextTask: nextTask($0.id), tasks: tasks, code: codes[$0.id], now: now)
        }
    }

    var status: GroveStatus { summary.status }
    var needsYou: Bool { summary.needsCare }

    /// The board's one order: most pressing first, then soonest due, then by
    /// name so two equal plants never swap places between renders. The hero
    /// and the list share it, so the plant in the photograph is always the
    /// first row beneath it.
    static func byUrgency(_ lhs: TodayBoardEntry, _ rhs: TodayBoardEntry) -> Bool {
        if lhs.summary.priority != rhs.summary.priority { return lhs.summary.priority < rhs.summary.priority }
        if lhs.summary.dueDate != rhs.summary.dueDate { return lhs.summary.dueDate < rhs.summary.dueDate }
        return lhs.plant.nickname.localizedCompare(rhs.plant.nickname) == .orderedAscending
    }

    /// One code per plant, unique across the grove.
    ///
    /// "Nan's fern" and "Nana" both start NAN; "Monty" and "Monstera" both
    /// start MON. Allocated in a fixed order (name, then id) so the same grove
    /// always gets the same codes: the first plant keeps the plain prefix, and
    /// the next falls back to the airline skeleton ("MNT") or, failing that,
    /// two letters and a digit ("NA2").
    static func codes(for plants: [Plant]) -> [UUID: String] {
        let ordered = plants.sorted {
            let order = $0.nickname.localizedCompare($1.nickname)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        var used = Set<String>()
        var result: [UUID: String] = [:]
        for plant in ordered {
            let code = candidates(for: plant.nickname).first { !used.contains($0) } ?? "—"
            used.insert(code)
            result[plant.id] = code
        }
        return result
    }

    /// Every printable code for one name, best first.
    private static func candidates(for nickname: String) -> [String] {
        let letters = Array(nickname.uppercased().filter(\.isLetter))
        guard let first = letters.first else { return ["—"] }
        var options: [String] = []
        func offer(_ code: String) {
            guard !unprintableCodes.contains(code), !options.contains(code) else { return }
            options.append(code)
        }
        if letters.count >= 3 { offer(String(letters.prefix(3))) }
        // Three letters of a real name can spell something nobody wants on
        // their home screen ("Nigella" is NIG). The airline trick: first
        // letter, then the next consonants ("NGL").
        let consonants = letters.dropFirst().filter { !"AEIOUY".contains($0) }
        if consonants.count >= 2 { offer(String([first] + consonants.prefix(2))) }
        if letters.count < 3 { offer(String(letters)) }
        let stem = String(letters.prefix(2))
        for digit in 2...9 { offer("\(stem)\(digit)") }
        return options
    }

    /// Three-letter prefixes that read as slurs or worse when printed alone.
    private static let unprintableCodes: Set<String> = [
        "NIG", "NGR", "FAG", "FGT", "FUK", "FUC", "FCK", "CUM", "CNT", "KKK",
        "NAZ", "SEX", "ASS", "TIT", "DIK", "DIC", "COK", "KUM", "WOP", "SPK",
        "RAP", "PUS", "VAG", "JIZ", "GOK", "CHN", "PAK", "JAP", "KYK", "HOE",
    ]

    var room: String {
        let trimmed = plant.location.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.caseInsensitiveCompare("Unassigned") == .orderedSame
            ? "Elsewhere" : trimmed
    }

    /// The dot's colour on the night-green map.
    var mapTint: Color {
        switch status.tone {
        case .urgent, .attention: GroveTheme.mapTrouble
        case .late, .due: GroveTheme.mapDue
        case .quiet, .steady: GroveTheme.mapThriving
        }
    }

    private var dayOffset: Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: summary.dueDate)
        ).day ?? 0
    }

    /// The first cell: what is next, and when.
    var nextLabel: String {
        if let task = summary.nextTask, task.dueDate <= plant.nextCheckIn {
            return task.kind.boardNoun
        }
        return "Check in"
    }

    var nextValue: String {
        switch dayOffset {
        case ..<(-1): "\(-dayOffset) days late"
        case -1: "1 day late"
        case 0: "Today"
        case 1: "Tomorrow"
        case 2...6: summary.dueDate.formatted(.dateTime.weekday(.abbreviated))
        default: summary.dueDate.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    var nextTint: Color {
        switch status.tone {
        case .late: GroveTheme.warning
        case .due: GroveTheme.accentStrong
        case .urgent, .attention: dayOffset <= 0 ? GroveTheme.warning : GroveTheme.ink
        case .quiet, .steady: GroveTheme.ink
        }
    }

    /// The second cell is the plant's own rhythm, not the schedule's opinion.
    /// Until three intervals exist there is no rhythm to report, so the cell
    /// counts down the waterings still to come rather than inventing one.
    var rhythmValue: String {
        guard rhythm.isReadable, let days = rhythm.typicalDays else {
            let n = wateringsUntilRhythm ?? 1
            return n == 1 ? "1 watering" : "\(n) waterings"
        }
        return days == 1 ? "Daily" : "\(days) days"
    }

    /// Waterings still needed before a rhythm can be read: three gaps take
    /// four waterings. Nil once the rhythm is readable.
    var wateringsUntilRhythm: Int? {
        guard !(rhythm.isReadable && rhythm.typicalDays != nil) else { return nil }
        return max(1, WateringRhythm.minimumIntervals + 1 - rhythm.waterings.count)
    }

    /// The middle cell's label: the rhythm once there is one, otherwise how
    /// far off it is, so the cell never reads as an unexplained state.
    var rhythmLabel: String {
        wateringsUntilRhythm == nil ? "Waters every" : "Rhythm in"
    }
}

extension CareKind {
    /// The one-word verb a board cell has room for.
    var boardNoun: String {
        switch self {
        case .checkIn: "Check in"
        case .inspectSoil: "Soil check"
        // A check, never a bare "Water": nothing has felt the soil, so the
        // board can only ask you to.
        case .water: "Water check"
        case .fertilise: "Feed"
        case .rotate: "Turn"
        case .cleanLeaves: "Clean"
        case .treat: "Treat"
        case .prune: "Trim"
        case .repot: "Repot"
        case .relocate: "Move"
        case .monitor: "Review"
        }
    }
}

// MARK: - Stat cell

/// Small caps over a large value: the board's only typographic idea.
struct GroveStatCell: View {
    let label: String
    let value: String
    var tint: Color = GroveTheme.ink
    var trend: HealthTrend? = nil
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(GroveTheme.subtleInk)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            HStack(spacing: 5) {
                trendMark
                Text(value)
                    .font(large ? .title2.weight(.semibold) : .body.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)\(trendSpoken)")
    }

    @ViewBuilder
    private var trendMark: some View {
        switch trend {
        case .improving:
            Image(systemName: "arrow.up.circle.fill")
                .font(.subheadline)
                .foregroundStyle(GroveTheme.healthThriving)
        case .declining:
            Image(systemName: "arrow.down.circle.fill")
                .font(.subheadline)
                .foregroundStyle(GroveTheme.danger)
        default:
            EmptyView()
        }
    }

    private var trendSpoken: String {
        switch trend {
        case .improving: ", improving"
        case .declining: ", declining"
        default: ""
        }
    }
}

// MARK: - Row

struct TodayBoardRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: TodayBoardEntry
    var showsStatus = false
    var isLast = false

    /// The spoken row: name, status, the next thing due, then health with the
    /// same band word the plant page uses. A plant without a reading says so
    /// instead of reading the stored placeholder score.
    static func accessibilityLabel(for entry: TodayBoardEntry) -> String {
        let health: String
        if entry.plant.hasHealthReading {
            health = "health \(entry.plant.healthScore) out of 100, \(entry.plant.healthBand.title)"
        } else {
            health = "no health reading yet"
        }
        return "\(entry.plant.nickname), \(entry.status.text), \(entry.nextLabel) \(entry.nextValue), \(health)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                PlantThumbnail(plant: entry.plant, height: 56, maxDimension: 220)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(entry.status.tone.tint)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(GroveTheme.background, lineWidth: 3))
                            .offset(x: 4, y: 4)
                    }
                Text(entry.code)
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(GroveTheme.subtleInk)
            }
            .padding(.top, 16)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                Text(entry.plant.nickname)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .lineLimit(1)

                if showsStatus {
                    GroveStatusLabel(status: entry.status)
                }

                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
                layout {
                    GroveStatCell(label: entry.nextLabel, value: entry.nextValue, tint: entry.nextTint)
                    GroveStatCell(label: entry.rhythmLabel, value: entry.rhythmValue)
                    GroveStatCell(label: "Health", value: "\(entry.plant.healthScore)", trend: entry.plant.trend)
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
    }
}

/// A board section: a heading with the fact that explains it, then rows.
struct TodayBoardSection: View {
    let title: String
    let subtitle: String
    let entries: [TodayBoardEntry]
    var showsStatus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ForEach(entries.indices, id: \.self) { index in
                let entry = entries[index]
                NavigationLink(value: AppRoute.plant(entry.plant.id)) {
                    TodayBoardRow(entry: entry, showsStatus: showsStatus, isLast: index == entries.count - 1)
                }
                .buttonStyle(.plain)
                .groveHeroSource(AppRoute.plant(entry.plant.id))
                // One spoken button per plant: name, then what it needs. The
                // combined cells read as a run of disconnected numbers.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(TodayBoardRow.accessibilityLabel(for: entry))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("todayRow.\(entry.plant.nickname)")
            }
        }
    }
}

// MARK: - Rooms map

/// The home, room by room, one lit dot per plant.
///
/// Grove does not know the floor plan, so it does not pretend to: rooms are the
/// places the owner named, drawn as tiles in two columns on the map's night
/// green, the room with trouble in it first. Each room carries its own mark and
/// its name in plain title case, and each plant is lit in its status, the way a
/// departures board lights each airport. The header says the whole-home fact
/// the way "Needs you" says its own: a title, then the number under it.
struct TodayRoomMap: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entries: [TodayBoardEntry]

    private struct Room: Identifiable {
        let name: String
        let entries: [TodayBoardEntry]
        /// How many named rooms folded into this tile, zero when it is not
        /// the overflow tile.
        var foldedRoomCount: Int = 0
        /// Whether plants with no room of their own also wait here, before
        /// any rooms folded in.
        var hasUnplacedPlants: Bool = false
        var id: String { name }
        var isPlaced: Bool { name != TodayRoomMap.elsewhere }
        var hasFoldedRooms: Bool { foldedRoomCount > 0 }
        var trouble: Int { entries.filter(\.needsYou).count }

        /// What the tile calls itself. A folded tile holds real rooms, so it
        /// says so rather than claiming its plants have no room.
        var title: String {
            isPlaced ? name : TodayRoomMap.overflowTitle(foldedRooms: foldedRoomCount, hasUnplaced: hasUnplacedPlants)
        }
    }

    /// The bucket for plants with no room. Not a room: it never counts as
    /// one, always sorts last, and exists at most once.
    private static let elsewhere = "Elsewhere"

    /// The overflow tile's title: unplaced plants alone, folded rooms alone,
    /// or both sharing one tile.
    static func overflowTitle(foldedRooms: Int, hasUnplaced: Bool) -> String {
        guard foldedRooms > 0 else { return "No room yet" }
        guard hasUnplaced else {
            return foldedRooms == 1 ? "1 more room" : "\(foldedRooms) more rooms"
        }
        return "More rooms and unplaced"
    }

    private var rooms: [Room] {
        let grouped: [String: [TodayBoardEntry]] = Dictionary(grouping: entries) { $0.room }
        var named: [Room] = []
        var unplaced: [TodayBoardEntry] = grouped[Self.elsewhere] ?? []
        let hasUnplacedPlants = !unplaced.isEmpty
        for (name, members) in grouped where name != Self.elsewhere {
            named.append(Room(name: name, entries: members.sorted(by: TodayBoardEntry.byUrgency)))
        }
        // The room that needs you sits top left, the way the lists above put
        // the plant that needs you first. Then the fuller rooms, then A to Z.
        named.sort { (lhs: Room, rhs: Room) -> Bool in
            if lhs.trouble != rhs.trouble { return lhs.trouble > rhs.trouble }
            if lhs.entries.count != rhs.entries.count { return lhs.entries.count > rhs.entries.count }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
        // Six tiles at most. Past that the smallest rooms fold into the one
        // unplaced tile rather than a second tile of the same name.
        let roomLimit = unplaced.isEmpty && named.count <= 6 ? 6 : 5
        let foldedRoomCount = max(0, named.count - roomLimit)
        if foldedRoomCount > 0 {
            for room in named[roomLimit...] { unplaced.append(contentsOf: room.entries) }
            named = Array(named.prefix(roomLimit))
        }
        guard !unplaced.isEmpty else { return named }
        return named + [Room(
            name: Self.elsewhere,
            entries: unplaced.sorted(by: TodayBoardEntry.byUrgency),
            foldedRoomCount: foldedRoomCount,
            hasUnplacedPlants: hasUnplacedPlants
        )]
    }

    /// True until the owner has put at least one plant in a named room.
    private var hasNoRooms: Bool {
        entries.allSatisfy { $0.room == Self.elsewhere }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if hasNoRooms {
                unbuiltHome
            } else {
                floorPlan
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The map sets its own lighting: night green in both appearances, so
        // the status rings read the same on a light or a dark sheet.
        .background(GroveTheme.mapGround, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    /// The same heading anatomy as every section on the board, so the map
    /// reads as a section of the day and not as a poster pinned among them.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Your home")
                .font(.title3.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
            Text(caption)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mapCaption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var floorPlan: some View {
        let rooms = rooms
        if rooms.count == 1 || dynamicTypeSize.isAccessibilitySize {
            // One room fills the width; half a map with a hole beside it
            // looks broken rather than small. Large type gets one column too.
            VStack(spacing: 8) {
                ForEach(rooms) { tile($0) }
            }
        } else {
            // A grid rather than two stacks, so the two tiles on a row share a
            // height and the map's edges stay straight instead of ragged.
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Array(stride(from: 0, to: rooms.count, by: 2)), id: \.self) { start in
                    GridRow {
                        if start + 1 < rooms.count {
                            tile(rooms[start])
                            tile(rooms[start + 1])
                        } else {
                            // An odd last room takes the whole row rather
                            // than leaving a hole beside it.
                            tile(rooms[start]).gridCellColumns(2)
                        }
                    }
                }
            }
        }
    }

    /// No rooms named yet. Rather than invent a room called "Your plants",
    /// the plants wait on an outline of a home that has not been drawn, and
    /// the one step that draws it is right there.
    @ViewBuilder
    private var unbuiltHome: some View {
        GroveFlowLayout(spacing: 8) {
            ForEach(entries) { dot($0) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                .strokeBorder(GroveTheme.mapRoom, style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
        }

        VStack(alignment: .leading, spacing: 12) {
            Text("Give each plant a room and your home draws itself here.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(GroveTheme.mapCaption)
                .fixedSize(horizontal: false, vertical: true)
            if let first = entries.first {
                NavigationLink(value: AppRoute.editPlant(first.plant.id)) {
                    Label("Choose a room for \(first.plant.nickname)", systemImage: "square.split.2x2")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GroveTheme.mapCode)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(GroveTheme.mapRoom, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// "5 plants in 2 rooms. 3 need you today." Only named rooms count:
    /// "Elsewhere" is where unplaced plants wait, not a room in the home, so
    /// a grove with some plants unplaced reads "5 plants, 1 room" rather than
    /// claiming all five live in it.
    private var caption: String {
        let plants = entries.count
        let trouble = entries.filter { $0.needsYou }.count
        let named = Set(entries.map(\.room)).subtracting([Self.elsewhere]).count
        let allPlaced = !entries.contains { $0.room == Self.elsewhere }
        let plantWord = "\(plants) \(plants == 1 ? "plant" : "plants")"
        let roomWord = "\(named) \(named == 1 ? "room" : "rooms")"
        let base = named == 0 ? plantWord : allPlaced ? "\(plantWord) in \(roomWord)" : "\(plantWord), \(roomWord)"
        return trouble == 0 ? "\(base). All on track." : "\(base). \(trouble) \(trouble == 1 ? "needs" : "need") you today."
    }

    /// One room: its mark and name across the top, its plants lit beneath.
    /// A named room is a filled tile; the plants still waiting for a room sit
    /// on a dashed outline, the same mark an undrawn home uses, so it never
    /// reads as a room called "Elsewhere".
    private func tile(_ room: Room) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                roomMark(room)
                Text(room.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(room.isPlaced || room.hasFoldedRooms ? GroveTheme.ink : GroveTheme.mapCaption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            GroveFlowLayout(spacing: 8) {
                ForEach(room.entries) { dot($0) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if room.isPlaced {
                RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                    .fill(GroveTheme.mapRoom)
            } else {
                RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                    .strokeBorder(GroveTheme.mapRoom, style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(room.title)
    }

    /// The room's glyph, the same one its badge wears in My Grove and the
    /// room chips, cut into the tile in the map's ground colour. Colour on the
    /// map is spent on status only, so the mark stays in the map's own inks.
    private func roomMark(_ room: Room) -> some View {
        let symbol = room.isPlaced
            ? GroveRoomTheme(name: room.name).symbol
            : room.hasFoldedRooms ? "square.grid.2x2" : "square.dashed"
        return Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(GroveTheme.mapCode)
            .frame(width: 24, height: 24)
            .background(GroveTheme.mapGround, in: Circle())
            .accessibilityHidden(true)
    }

    private func dot(_ entry: TodayBoardEntry) -> some View {
        NavigationLink(value: AppRoute.plant(entry.plant.id)) {
            VStack(spacing: 6) {
                // The plant's own face, ringed in its status, the way a
                // departures board lights each airport. A plant that needs
                // you throws a wider glow, so the lit ones read first.
                PlantThumbnail(plant: entry.plant, height: 44, maxDimension: 180)
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                    .padding(3)
                    .overlay(Circle().strokeBorder(entry.mapTint, lineWidth: 2.5))
                    .background(Circle().fill(entry.mapTint.opacity(0.18)).padding(-4))
                    .background {
                        if entry.needsYou {
                            Circle().fill(entry.mapTint.opacity(0.09)).padding(-8)
                        }
                    }
                Text(entry.code)
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(GroveTheme.mapCode)
            }
            .frame(minWidth: 60, minHeight: 78)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.plant.nickname), \(entry.room), \(entry.status.text)")
    }
}

// MARK: - Plant page: status board and timetable

/// The top of a plant's page, read like a flight's status block: one line that
/// says how things stand, a bar that shows how far through the watering gap the
/// plant is, and a timetable that sets the schedule beside what actually
/// happened.
struct PlantTimetableCard: View {
    @Environment(GroveStore.self) private var store
    let plant: Plant

    var body: some View {
        let entry = TodayBoardEntry(
            plant: plant,
            nextTask: store.nextPendingTask(for: plant.id),
            tasks: store.tasks
        )
        let observations = store.observations(for: plant.id).sorted { $0.createdAt < $1.createdAt }

        let rhythmReadable = entry.rhythm.isReadable && entry.rhythm.typicalDays != nil
        // The board's own bar already prints the last watering whenever the
        // rhythm is readable, and the drying bar this card used to open on was
        // that same bar drawn a second time. Each fact is said once.
        let lastWater = rhythmReadable ? nil : entry.rhythm.waterings.last
        let lastCheckIn = observations.last
        let hasWater = nextWaterDate != nil || lastWater != nil

        // Only facts Grove actually has, and only ones the board above does
        // not already say. A timetable of "Not set", a rhythm still being
        // learned and dashes is a form, not a board; with nothing left to show
        // the card does not appear at all. The running totals moved to the
        // Health sheet.
        if hasWater || lastCheckIn != nil {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Care timetable")
                        .font(.title3.weight(.semibold))
                    Text("Scheduled, typical and actual")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                .padding(.bottom, 4)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                if hasWater {
                    group("Water", isLast: lastCheckIn == nil) {
                        if let next = nextWaterDate {
                            // A soil check, not a watering: the schedule
                            // only knows when to look.
                            timetableRow(
                                "Next soil check",
                                ("Scheduled", Self.day(next)),
                                rhythmReadable ? ("Typical gap", entry.rhythmValue) : nil,
                                secondTint: GroveTheme.ink,
                                isLast: lastWater == nil
                            )
                        }
                        if let lastWater {
                            timetableRow(
                                "Last watered",
                                ("When", Self.day(lastWater.date)),
                                entry.rhythm.daysSinceLast.map { ("Days since", "\($0)") },
                                secondTint: GroveTheme.ink,
                                isLast: true
                            )
                        }
                    }
                }
                // The next check-in has its own card on the page; the
                // timetable only records the last one.
                if let lastCheckIn {
                    group("Check-in", isLast: true) {
                        timetableRow(
                            "Last",
                            ("When", Self.day(lastCheckIn.createdAt)),
                            ("Health then", "\(lastCheckIn.score)"),
                            secondTint: GroveTheme.ink,
                            isLast: true
                        )
                    }
                }
            }
            .padding(20)
            .groveCard(padding: 0)
        }
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private var nextWaterDate: Date? {
        store.tasks
            .filter { $0.plantID == plant.id && $0.kind == .water && !$0.isCompleted }
            .min { $0.dueDate < $1.dueDate }?
            .dueDate
    }

    // MARK: Timetable

    private func group<Content: View>(_ name: String, isLast: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name.uppercased())
                .font(.footnote.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(GroveTheme.mutedInk)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(GroveTheme.separator).frame(height: 1) }
        }
    }

    private func timetableRow(
        _ title: String,
        _ first: (String, String),
        _ second: (String, String)?,
        secondTint: Color,
        isLast: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.body)
                .foregroundStyle(GroveTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            GroveStatCell(label: first.0, value: first.1)
            if let second {
                GroveStatCell(label: second.0, value: second.1, tint: secondTint)
            } else {
                Color.clear.frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tab root anatomy

/// The top of every tab, identical on all four: the tab's own name in the
/// page title step, then one muted line that states the tab's one fact.
///
/// Today, Ask, Friends and My Grove used to each open their own way (a map
/// under the status bar, an avatar beside the title, a bare title, a title
/// with a profile photo), so switching tabs felt like switching apps. The
/// header is now one component, and anything a tab wants beside its title
/// goes in the toolbar or in the hero card underneath instead.
struct GroveTabHeader<Subtitle: View>: View {
    let title: String
    @ViewBuilder var subtitle: Subtitle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(GroveTheme.display(GroveDisplayStyle.hero.points))
                .tracking(-0.4)
                .foregroundStyle(GroveTheme.ink)
                .accessibilityAddTraits(.isHeader)
            subtitle
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension GroveTabHeader where Subtitle == Text {
    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = Text(subtitle)
    }
}

extension View {
    /// The one hero slot under every tab header: full width, `cardRadius`,
    /// never shorter than 200pt, so the first object on each tab is the same
    /// shape in the same place, whatever it shows.
    func groveTabHero() -> some View {
        self
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
    }
}

// MARK: - The board page (every tab root)

/// True once a board page's sheet has risen under the navigation bar.
struct GroveBoardSheetAtTopKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Flighty's frame, used by all four tabs: one full-bleed hero that runs up
/// under the status bar, and a white sheet with a grabber that rises over its
/// bottom edge carrying the tab's title and everything else.
///
/// The hero changes per tab (the rooms map, Ari's question, the sitter, the
/// most improved plant); the frame never does, so switching tabs swaps the
/// picture and keeps the room.
struct GroveBoardPage<Hero: View, Sheet: View>: View {
    var heroGround: Color = GroveTheme.mapGround
    /// Off for sheets that pad their own rows, such as Ask's edge-to-edge
    /// guide carousel.
    var insetsContent: Bool = true
    @ViewBuilder var hero: Hero
    @ViewBuilder var sheet: Sheet

    /// True once the sheet has climbed up under the status bar.
    @State private var sheetAtTop = false
    /// The hero's real height, so the status bar flips when the sheet
    /// actually reaches it, whatever each tab's hero measures.
    @State private var measuredHeroHeight: CGFloat = 320

    /// How far the sheet rides up over the hero.
    static var overlap: CGFloat { GroveTheme.heroRadius + 6 }
    static var heroHeight: CGFloat { 320 }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                    .frame(maxWidth: .infinity, alignment: .bottom)
                    .background(heroGround)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredHeroHeight = $0 }
                    .overlay(alignment: .top) {
                        // Keeps the clock and the bar's chips legible over a
                        // bright photograph. On night green it is invisible.
                        LinearGradient(
                            colors: [.black.opacity(0.42), .black.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 130)
                        .allowsHitTesting(false)
                    }
                    .clipped()
                    // Flighty's globe stays put while the sheet slides over
                    // it: the hero scrolls at a third of the page's speed.
                    .visualEffect { content, proxy in
                        let minY = proxy.frame(in: .scrollView).minY
                        return content.offset(y: minY < 0 ? -minY * 0.66 : 0)
                    }

                VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                    sheet
                }
                .padding(.horizontal, insetsContent ? GroveTheme.pagePadding : 0)
                .padding(.top, 26)
                // Clears the floating tab bar's raised scan disc, which sits
                // over the last rows otherwise.
                .padding(.bottom, GroveTheme.pageBottomPadding + 48)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .top) {
                    Capsule()
                        .fill(GroveTheme.separator)
                        .frame(width: 38, height: 5)
                        .padding(.top, 8)
                        .accessibilityHidden(true)
                }
                .background(
                    GroveTheme.surface,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: GroveTheme.heroRadius + 6,
                        topTrailingRadius: GroveTheme.heroRadius + 6,
                        style: .continuous
                    )
                )
                .padding(.top, -Self.overlap)
                .zIndex(1)
            }
        }
        .ignoresSafeArea(edges: .top)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > measuredHeroHeight - Self.overlap - 70
        } action: { _, atTop in
            sheetAtTop = atTop
        }
        .modifier(GroveHeroEdgeEffect(hidden: true))
        .overlay(alignment: .top) {
            // Once the sheet reaches the top it becomes the page, and the bar
            // above it needs a floor: paper under the clock and the chips that
            // ends exactly where the bar does and feathers out, so rows
            // dissolve into it rather than being cut by a ruled line. The
            // inset already includes the bar, so nothing is added to it.
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    GroveTheme.surface
                        .frame(height: proxy.safeAreaInsets.top)
                    LinearGradient(
                        colors: [GroveTheme.surface, GroveTheme.surface.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 18)
                }
                .ignoresSafeArea(edges: .top)
                .opacity(sheetAtTop ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: sheetAtTop)
            }
            .allowsHitTesting(false)
        }
        // The root header bar reads this to put its chips and title on paper.
        .preference(key: GroveBoardSheetAtTopKey.self, value: sheetAtTop)
        .groveStatusBar(sheetAtTop ? .darkContent : .lightContent)
        .background {
            // Hero colour above, paper below, so an overscroll at either end
            // shows the surface it belongs to.
            VStack(spacing: 0) {
                heroGround.frame(height: 420)
                GroveTheme.surface
            }
            .ignoresSafeArea()
        }
    }
}

/// A hero made of one plant's own photograph, with its caption set on a scrim
/// low enough to clear the sheet.
struct GrovePhotoHero: View {
    let plant: Plant
    let eyebrow: String
    let title: String
    var value: String? = nil

    var body: some View {
        PlantThumbnail(plant: plant, height: 360, maxDimension: 1200)
            .overlay {
                // On-photo scrim: the photograph sets the lighting in both
                // appearances, so this is the sanctioned literal.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.38), location: 0),
                        .init(color: .black.opacity(0), location: 0.3),
                        .init(color: .black.opacity(0), location: 0.5),
                        .init(color: .black.opacity(0.66), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(eyebrow.uppercased())
                            .font(.caption2.weight(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(.white.opacity(0.8))
                        Text(title)
                            .font(GroveTheme.display(GroveDisplayStyle.heading.points))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 12)
                    if let value {
                        Text(value)
                            .font(GroveTheme.display(GroveDisplayStyle.hero.points))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.bottom, GroveBoardPage<EmptyView, EmptyView>.overlap + 18)
            }
            .accessibilityElement(children: .combine)
    }
}

/// The hero when there is no photograph to show: night green, the map's own
/// ground, with the content low and left like every other hero.
struct GroveNightHero<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .padding(.horizontal, GroveTheme.pagePadding)
        // Clears the status bar and the bar's chips, and no more: a fixed
        // minimum height left a band of empty night green above short heroes.
        .padding(.top, 108)
        .padding(.bottom, GroveBoardPage<EmptyView, EmptyView>.overlap + 18)
        .background(GroveTheme.mapGround)
        .environment(\.colorScheme, .dark)
    }
}

private struct GroveHeroBleedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when a card is drawn as a tab's full-bleed hero rather than as a
    /// card inside the page: no corner radius, and room left for the sheet.
    var groveHeroBleed: Bool {
        get { self[GroveHeroBleedKey.self] }
        set { self[GroveHeroBleedKey.self] = newValue }
    }
}


/// iOS 26 blurs content scrolling under the bar. Over a full-bleed hero that
/// reads as a smoky band across the top of the photograph, so the board turns
/// it off; the chips are glass and stay legible on their own.
private struct GroveHeroEdgeEffect: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(hidden, for: .top)
        } else {
            content
        }
    }
}
