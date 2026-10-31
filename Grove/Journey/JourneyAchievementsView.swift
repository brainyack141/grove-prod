import SwiftUI

/// The Badges page: what the Journey has given you to show for your care.
/// Badges first, grouped by the kind of work behind them, then the keepsakes
/// kept with them. Chapters are drawn on the Journey's rings, not repeated
/// here.
///
/// Called "Badges", never "Collection": collections are groups of plants.
struct JourneyAchievementsView: View {
    @Environment(GroveStore.self) private var store
    @State private var selectedBadge: JourneyBadgePresentation?

    var body: some View {
        let badges = JourneyBadgePresentationResolver.presentations(store: store)

        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                summary(badges)

                ForEach(BadgeGroup.groups(from: badges)) { group in
                    badgeSection(group)
                }

                keepsakeSection
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, GroveTheme.pageTopPadding + 8)
            .padding(.bottom, GroveTheme.pageBottomPadding)
        }
        .groveBackground()
        .groveEditorialPage("Badges")
        .sheet(item: $selectedBadge) { item in
            JourneyBadgeDetailSheet(item: item)
        }
    }

    // MARK: - Summary

    private func summary(_ badges: [JourneyBadgePresentation]) -> some View {
        let progress = store.gardener
        let earned = badges.filter(\.state.isEarned).count

        return VStack(alignment: .leading, spacing: 16) {
            Text("Every badge stands for something you did: a plant added, a check-in saved, a lesson finished.")
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            JourneyFactRow(facts: [
                .init(label: "Level", value: progress.level.title),
                .init(label: "XP", value: progress.xp.formatted()),
                .init(label: "Badges", value: "\(earned) of \(badges.count)"),
                .init(label: "Shields", value: "\(progress.streakShields)")
            ])
        }
    }

    // MARK: - Badges

    private func badgeSection(_ group: BadgeGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            JourneySectionHeader(title: group.category.title, subtitle: group.countLine)

            JourneyTileRows(items: group.badges) { item in
                // The card press already answers the finger, so the tap adds
                // no haptic of its own.
                Button { selectedBadge = item } label: {
                    BadgeTile(item: item)
                }
                .buttonStyle(GroveCardPressStyle())
                .accessibilityHint(item.state.isEarned ? "Shows the badge" : "Shows how to earn it")
            }
        }
    }

    // MARK: - Keepsakes

    private var keepsakeSection: some View {
        let kept = store.gardener.keepsakeIDs
        let keptCount = KeepsakeLibrary.all.filter { kept.contains($0.id) }.count

        return VStack(alignment: .leading, spacing: 12) {
            JourneySectionHeader(
                title: "Keepsakes",
                subtitle: "\(keptCount) of \(KeepsakeLibrary.all.count) kept. Each one marks something you did for a real plant."
            )

            JourneyTileRows(items: KeepsakeLibrary.all) { keepsake in
                KeepsakeTile(keepsake: keepsake, kept: kept.contains(keepsake.id))
            }
        }
    }
}

// MARK: - Groups

private struct BadgeGroup: Identifiable {
    let category: BadgeCategory
    let badges: [JourneyBadgePresentation]
    var id: BadgeCategory { category }

    /// The section's one fact.
    var countLine: String {
        let earned = badges.filter(\.state.isEarned).count
        if earned == badges.count { return "All \(badges.count) earned" }
        if earned == 0 { return "\(badges.count) to earn" }
        return "\(earned) of \(badges.count) earned"
    }

    static func groups(from badges: [JourneyBadgePresentation]) -> [BadgeGroup] {
        BadgeCategory.allCases.compactMap { category in
            let members = badges.filter { $0.badge.category == category }
            return members.isEmpty ? nil : BadgeGroup(category: category, badges: members)
        }
    }
}

// MARK: - Tiles

/// Two tiles across (one at accessibility sizes), each pair as tall as its
/// taller tile, so a grid of uneven titles still reads as rows.
private struct JourneyTileRows<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    @ViewBuilder let tile: (Item) -> Tile

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let perRow = dynamicTypeSize.isAccessibilitySize ? 1 : 2

        VStack(spacing: 12) {
            ForEach(Array(stride(from: 0, to: items.count, by: perRow)), id: \.self) { start in
                let row = items[start..<min(start + perRow, items.count)]
                HStack(alignment: .top, spacing: 12) {
                    ForEach(row) { item in
                        tile(item)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if row.count < perRow {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: 0)
                            .accessibilityHidden(true)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The flat tile every badge and keepsake sits on: surface, one hairline,
/// no shadow.
private struct JourneyTileChrome: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
        content
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(GroveTheme.surface, in: shape)
            .overlay { shape.strokeBorder(GroveTheme.separator, lineWidth: 1) }
            .contentShape(shape)
    }
}

private struct BadgeTile: View {
    let item: JourneyBadgePresentation

    /// Earned: when. Not yet: what it takes, in one short line.
    private var line: String {
        guard item.state.isEarned else { return item.guidance.goal }
        return item.earnedDateText.map { "Earned \($0)" } ?? "Earned"
    }

    private var spokenLabel: String {
        if item.state.isEarned {
            return "\(item.badge.title). \(line). \(item.badge.blurb)"
        }
        return "\(item.badge.title). Not earned yet. \(item.guidance.goal). \(item.state.detail)."
    }

    var body: some View {
        VStack(spacing: 10) {
            JourneyBadgeMedallion(badge: item.badge, state: item.state, size: 64)

            VStack(spacing: 3) {
                Text(item.badge.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                Text(line)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(JourneyTileChrome())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }
}

/// Keepsakes stay as collectible art beside the badges. One not kept yet is
/// drawn in grey with the step that earns it, the same way a locked badge is.
private struct KeepsakeTile: View {
    let keepsake: Keepsake
    let kept: Bool

    private var line: String {
        kept ? keepsake.blurb : (JourneyBadgeGuidanceResolver.goal(forKeepsake: keepsake.id) ?? "Not kept yet")
    }

    var body: some View {
        VStack(spacing: 10) {
            KeepsakeSpriteView(sprite: keepsake.sprite, unit: 40)
                .saturation(kept ? 1 : 0)
                .opacity(kept ? 1 : 0.4)

            VStack(spacing: 3) {
                Text(keepsake.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                Text(line)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(JourneyTileChrome())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            kept
                ? "\(keepsake.name). Kept. \(keepsake.blurb)"
                : "\(keepsake.name). Not kept yet. \(line)."
        )
    }
}
