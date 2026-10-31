import SwiftUI

// MARK: - Measures

/// The plant that gained the most health over the last thirty days.
///
/// The gain is read from the record, not the trend flag: today's score against
/// the score the plant came into its first check-in of the window with. A
/// plant nobody has looked at this month has nothing to report and is left
/// out, and a grove where nothing went up shows no feature at all rather than
/// celebrating a zero.
struct MyGroveImprovement {
    let plant: Plant
    let gain: Int

    static func mostImproved(
        plants: [Plant],
        observations: [PlantObservation],
        now: Date = .now
    ) -> MyGroveImprovement? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        let recent = observations.filter { $0.createdAt >= cutoff && $0.createdAt <= now }
        let history: [UUID: [PlantObservation]] = Dictionary(grouping: recent) { $0.plantID }

        var best: MyGroveImprovement?
        for plant in plants where plant.effectiveLifecycleState == .active && plant.hasHealthReading {
            guard let entries = history[plant.id], !entries.isEmpty else { continue }
            let first = entries.min { (a: PlantObservation, b: PlantObservation) -> Bool in
                a.createdAt < b.createdAt
            }
            guard let first else { continue }
            let gain = plant.healthScore - first.previousScore
            guard gain > 0 else { continue }
            let candidate = MyGroveImprovement(plant: plant, gain: gain)
            if let current = best {
                if gain > current.gain
                    || (gain == current.gain && plant.healthScore > current.plant.healthScore) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        return best
    }
}

/// The grove's mean health now, and which way it has moved in thirty days.
struct MyGroveHealthAverage {
    let value: Int
    let trend: HealthTrend?

    static func measure(
        plants: [Plant],
        observations: [PlantObservation],
        now: Date = .now
    ) -> MyGroveHealthAverage? {
        let assessed = plants.filter(\.hasHealthReading)
        let active = assessed.filter { $0.effectiveLifecycleState == .active }
        let counted = active.isEmpty ? assessed : active
        guard !counted.isEmpty else { return nil }

        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        let history: [UUID: [PlantObservation]] = Dictionary(grouping: observations) { $0.plantID }

        var nowTotal = 0
        var thenTotal = 0
        for plant in counted {
            nowTotal += plant.healthScore
            let ordered = (history[plant.id] ?? []).sorted { (a: PlantObservation, b: PlantObservation) -> Bool in
                a.createdAt < b.createdAt
            }
            // The score the plant stood at thirty days ago: the last reading
            // before the window, else what the first reading inside it found,
            // else (never looked at) today's score, which moves nothing.
            if let before = ordered.last(where: { $0.createdAt < cutoff }) {
                thenTotal += before.score
            } else if let firstInside = ordered.first(where: { $0.createdAt >= cutoff }) {
                thenTotal += firstInside.previousScore
            } else {
                thenTotal += plant.healthScore
            }
        }

        let count = Double(counted.count)
        let nowAverage = Double(nowTotal) / count
        let thenAverage = Double(thenTotal) / count
        let delta = nowAverage - thenAverage
        let trend: HealthTrend?
        if delta >= 1 {
            trend = .improving
        } else if delta <= -1 {
            trend = .declining
        } else {
            trend = nil
        }
        return MyGroveHealthAverage(value: Int(nowAverage.rounded()), trend: trend)
    }
}

/// One room's worth of plants, in the order the library sorted them.
struct MyGroveRoom: Identifiable {
    let name: String
    let entries: [TodayBoardEntry]

    var id: String { name }

    var subtitle: String {
        let plants = entries.count
        let base = plants == 1 ? "1 plant" : "\(plants) plants"
        let needing = entries.filter(\.needsYou).count
        guard needing > 0 else { return base }
        return "\(base) · \(needing) \(needing == 1 ? "needs" : "need") you"
    }

    /// Rooms with the most plants first, then by name. "Elsewhere" is not a
    /// place, so it always comes last.
    static func group(_ entries: [TodayBoardEntry]) -> [MyGroveRoom] {
        var order: [String] = []
        var members: [String: [TodayBoardEntry]] = [:]
        for entry in entries {
            let room = entry.room
            if members[room] == nil {
                order.append(room)
                members[room] = []
            }
            members[room]?.append(entry)
        }
        var rooms: [MyGroveRoom] = order.map { name in
            MyGroveRoom(name: name, entries: members[name] ?? [])
        }
        rooms.sort { (lhs: MyGroveRoom, rhs: MyGroveRoom) -> Bool in
            let lhsElsewhere = lhs.name == "Elsewhere"
            let rhsElsewhere = rhs.name == "Elsewhere"
            if lhsElsewhere != rhsElsewhere { return rhsElsewhere }
            if lhs.entries.count != rhs.entries.count {
                return lhs.entries.count > rhs.entries.count
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return rooms
    }
}

// MARK: - Section title

/// The board's section heading: a system title with the fact that explains it
/// underneath. Replaces the display-face `SectionHeader` on this screen.
struct MyGroveSectionTitle: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GroveTheme.accentStrong)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Feature

/// Most improved this month: the user's own photograph, edge to edge, with
/// the gain and the score set on a scrim.
struct MyGroveFeatureCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let improvement: MyGroveImprovement

    private var headline: String {
        "\(improvement.plant.nickname), up \(improvement.gain) \(improvement.gain == 1 ? "point" : "points")"
    }

    var body: some View {
        PlantThumbnail(plant: improvement.plant, height: 230, maxDimension: 900)
            .overlay { scrim }
            .overlay(alignment: .bottomLeading) { caption }
            .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Most improved this month. \(headline), health \(improvement.plant.healthScore)")
            .accessibilityHint("Opens \(improvement.plant.nickname)")
    }

    /// On-photo scrims are the design system's sanctioned exception to the
    /// token rule: the photograph sets the lighting in both appearances.
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.4),
                .init(color: .black.opacity(0.72), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var caption: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MOST IMPROVED THIS MONTH")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(headline)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 8)
            Text("\(improvement.plant.healthScore)")
                .font(.largeTitle.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }
}

// MARK: - Summary

/// Three facts under the feature: how many plants, how many need you, and the
/// average health with the way it is moving.
struct MyGroveSummaryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let plantCount: Int
    let needYouCount: Int
    let average: MyGroveHealthAverage?

    var body: some View {
        let layout: AnyLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        layout {
            GroveStatCell(label: "Plants", value: "\(plantCount)", large: true)
            GroveStatCell(
                label: "Need you",
                value: "\(needYouCount)",
                tint: needYouCount > 0 ? GroveTheme.warning : GroveTheme.ink,
                large: true
            )
            GroveStatCell(
                label: "Avg health",
                value: average.map { "\($0.value)" } ?? "–",
                trend: average?.trend,
                large: true
            )
        }
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) {
            Rectangle().fill(GroveTheme.separator).frame(height: 1)
        }
    }
}

// MARK: - Tile

/// One plant in a room: the photograph with its code on a light capsule, the
/// name, and the one line that says how it stands.
struct MyGroveTile: View {
    let entry: TodayBoardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlantThumbnail(plant: entry.plant, height: 200, maxDimension: 600)
                .overlay(alignment: .topLeading) { codeCapsule }
                .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.plant.nickname)
                    .font(.headline)
                    .foregroundStyle(GroveTheme.ink)
                    .lineLimit(1)
                Text(entry.status.text)
                    .font(.subheadline.weight(entry.status.tone.isPressing ? .semibold : .regular))
                    .foregroundStyle(entry.status.tone.tint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        // The name under the photograph is part of the same object, so aiming
        // at it opens the plant too.
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            entry.plant.hasHealthReading
                ? "\(entry.plant.nickname), \(entry.status.text), health \(entry.plant.healthScore)"
                : "\(entry.plant.nickname), \(entry.status.text), no health reading yet"
        )
    }

    /// Pinned to the light appearance so the surface resolves to white and the
    /// status dot to its on-paper colour on every photograph, in both modes.
    private var codeCapsule: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(entry.status.tone.tint)
                .frame(width: 7, height: 7)
            Text(entry.code)
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(GroveTheme.inkOnLight)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(GroveTheme.surface.opacity(0.9), in: Capsule())
        .environment(\.colorScheme, .light)
        .padding(12)
        .accessibilityHidden(true)
    }
}

// MARK: - Settings profile header

/// Who is signed in, at the top of Settings: avatar, name, and handle.
///
/// How the account signs in lives in Settings' Account section, where people
/// look for it. Sharing this line with the handle made it wrap to two lines
/// and put a task ("Choose a username") and a fact side by side.
struct MyGroveProfileHeader: View {
    @Environment(GroveStore.self) private var store

    private enum Handle {
        case prompt
        case username(String)
    }

    private var handle: Handle? {
        let username = store.profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        // A minted handle ("gardene_267998de61e7417e") is not a name; offer to
        // choose one instead of showing it.
        if SessionService.isGeneratedUsername(username) { return .prompt }
        return username.isEmpty ? nil : .username(username)
    }

    private var displayName: String {
        let name = store.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Your profile" : name
    }

    var body: some View {
        HStack(spacing: 14) {
            AvatarView(
                initials: store.profile.initials,
                seed: store.activeAccountID ?? store.profile.username,
                size: 60,
                assetName: store.profile.avatarAssetName,
                photoURL: store.profile.avatarPhotoURL
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .lineLimit(2)
                switch handle {
                case .prompt:
                    // The one thing on this row that asks for something, so it
                    // is the one line in the accent.
                    Text("Choose a username")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(GroveTheme.accent)
                case .username(let username):
                    Text("@\(username)")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .lineLimit(1)
                case nil:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
