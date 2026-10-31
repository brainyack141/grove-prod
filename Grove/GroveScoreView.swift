import SwiftUI

/// The Grove Score page: the laurel in Today's header opens this.
///
/// One number, then everything a person needs to trust it — where it comes
/// from, what would lift it, and the rules that keep it honest. The layout is
/// the argument in order: the reading, the evidence, the levers, the law.
struct GroveScoreView: View {
    @Environment(GroveStore.self) private var store

    private var score: GroveScore? {
        store.currentGroveScore()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                if let score {
                    headline(score).groveReveal(0)
                    pillarsCard(score).groveReveal(1)
                    rulesCard.groveReveal(2)
                } else {
                    firstPlant
                }
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, GroveTheme.pageTopPadding)
            .padding(.bottom, GroveTheme.pageBottomPadding)
        }
        .groveBackground()
        .groveEditorialPage("Grove Score")
        .accessibilityIdentifier("groveScoreView")
        .safeAreaInset(edge: .bottom) {
            if let score, let title = score.advice.actionTitle, let route = score.advice.route {
                NavigationLink(value: route) {
                    GroveCTALabel(title: title)
                }
                .buttonStyle(GrovePressStyle())
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(.bar)
            }
        }
    }

    // MARK: - Headline

    /// Gold is reserved for the top tier, the same way the app reserves it for
    /// celebration: reaching Master gardener *is* one.
    private func tierColor(_ tier: GroveScore.Tier) -> Color {
        tier == .masterGardener ? GroveTheme.goldDeep : GroveTheme.accentStrong
    }

    private func headline(_ score: GroveScore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GroveEyebrow(text: "How you're caring")

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(score.total)")
                    .font(GroveTheme.display(72))
                    .monospacedDigit()
                    .foregroundStyle(GroveTheme.ink)
                    .contentTransition(.numericText(value: Double(score.total)))

                Text("of 100")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(GroveTheme.mutedInk)
            }

            Label(score.tier.title, systemImage: "laurel.leading")
                .font(.caption.weight(.bold))
                .foregroundStyle(tierColor(score.tier))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(tierColor(score.tier).opacity(0.1), in: Capsule())

            Text(score.tier.line)
                .font(.body.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(score.advice.message)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            if let progress = score.progressToNextTier {
                VStack(alignment: .leading, spacing: 7) {
                    GroveProgressBar(
                        fraction: progress.fraction,
                        tint: tierColor(progress.next),
                        height: 6,
                        minimumFill: 6
                    )
                    Text(progress.pointsShort == 1
                        ? "1 point to \(progress.next.title)"
                        : "\(progress.pointsShort) points to \(progress.next.title)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GroveTheme.subtleInk)
                }
                .padding(.top, 4)
            }

            if score.isSettling {
                Label(settlingLine(score), systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.subtleInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Grove Score \(score.total) of 100, \(score.tier.title). \(score.advice.message)"
        )
    }

    private func settlingLine(_ score: GroveScore) -> String {
        let needed = GroveScore.Rules.fullEvidenceDays
        return "Still settling: \(score.lookDays) of \(needed) recent check-in days. Repeat scans on one day count once."
    }

    // MARK: - Pillars

    private func pillarsCard(_ score: GroveScore) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Where it comes from")

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(score.pillars.enumerated()), id: \.element.id) { index, pillar in
                    pillarRow(pillar)
                    if index < score.pillars.count - 1 {
                        Rectangle()
                            .fill(GroveTheme.separator)
                            .frame(height: 1)
                            .padding(.vertical, 16)
                            .accessibilityHidden(true)
                    }
                }
            }
            .groveCard()
        }
    }

    private func pillarRow(_ pillar: GroveScore.Pillar) -> some View {
        HStack(alignment: .top, spacing: 14) {
            GroveSymbolTile(symbol: pillar.symbol, size: 40)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(pillar.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(GroveTheme.ink)
                    Spacer(minLength: 8)
                    Text("\(pillar.points) of \(pillar.maxPoints)")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(GroveTheme.mutedInk)
                }

                GroveProgressBar(fraction: pillar.fraction, height: 6, minimumFill: 6)

                Text(pillar.detail)
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(pillar.title), \(pillar.points) of \(pillar.maxPoints) points. \(pillar.detail)"
        )
    }

    // MARK: - The rules

    /// Written down in full, like the streak sheet writes down its rules. A
    /// score nobody can audit is a score nobody should trust.
    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How it's scored")
                .font(.headline.weight(.bold))
                .foregroundStyle(GroveTheme.ink)

            VStack(alignment: .leading, spacing: 11) {
                rule("leaf.fill", "Photo-assessed plant wellbeing counts most, 40 of 100.")
                rule("checkmark.circle.fill", "Care done on time, with a recorded completion date, earns 25.")
                rule("eye.fill", "A regular check-in on every plant earns 20.")
                rule("arrow.up.right", "Measured recoveries and sustained healthy scores earn 15.")
            }

            Text("Days count, not taps. Retakes on the same day count once. Estimated scores and inferred completion dates never count; low-confidence scores are tempered, healthy scores fade if a plant goes unseen, and a recovery must hold for at least a week.")
                .font(.footnote)
                .foregroundStyle(GroveTheme.subtleInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groveCard()
    }

    private func rule(_ symbol: String, _ text: String) -> some View {
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

    // MARK: - Empty grove

    private var firstPlant: some View {
        GroveEmptyState(
            scene: .groveScore,
            title: "Your score starts with a plant",
            message: "The Grove Score tracks how your plants do under your care. Add your first plant to start it."
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

#Preview("Established grove") {
    AppDestinationsPreviewHost { GroveScoreView() }
        .environment(GroveStore())
        .environment(IntentRouter.shared)
}

#Preview("Empty grove") {
    AppDestinationsPreviewHost { GroveScoreView() }
        .environment(GroveStore(plants: [], persistenceEnabled: false))
        .environment(IntentRouter.shared)
}
