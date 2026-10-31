import SwiftUI

// The pieces of the Grove Premium screen. The screen itself, with its purchase
// and restore logic, is `GrovePremiumOfferView`; everything here is drawn from
// values that view hands in, so no price or limit is invented on this side.
//
// The paywall forces the dark colour scheme, so adaptive GroveTheme tokens
// resolve to their dark values here: `GroveTheme.ink` is the light type on the
// night-green ground, and the selected plan card switches itself back to light
// so its own ink reads dark on white.

/// One line of the Free and Premium comparison.
struct PaywallComparison: Identifiable {
    let label: String
    let free: String
    let premium: String
    var id: String { label }

    /// Every row is read from the constant that enforces it, so the table
    /// cannot promise a limit the app does not apply.
    @MainActor
    static var rows: [PaywallComparison] {
        [
            PaywallComparison(
                label: "Questions to Ari",
                free: "\(AskSession.freeAsksPerDay) a day",
                premium: "Unlimited"
            ),
            PaywallComparison(
                label: "Friends",
                free: "\(GroveFriendAccess.freeFriendLimit)",
                premium: "Unlimited"
            ),
            PaywallComparison(
                label: "Profile mascots",
                free: "Standard",
                premium: "+\(AvatarView.premiumImageNames.count)"
            )
        ]
    }
}

/// One thing Premium adds, as a paywall lists it.
///
/// Every paywall and the Settings card read from this one list, so no surface
/// can sell something the others do not, or something free users already
/// have. Each line is read from the constant that enforces the limit.
struct PremiumBenefit: Identifiable {
    enum Kind {
        case questions
        case friends
        case mascots
    }

    let kind: Kind
    let text: String
    let symbol: String
    var id: Kind { kind }

    /// The three gated features, with the one that brought the user here
    /// first.
    @MainActor
    static func all(leading: Kind = .questions) -> [PremiumBenefit] {
        let benefits = [
            PremiumBenefit(
                kind: .questions,
                text: "Unlimited questions to Ari, instead of \(AskSession.freeAsksPerDay) a day",
                symbol: "bubble.left.and.text.bubble.right.fill"
            ),
            PremiumBenefit(
                kind: .friends,
                text: "Unlimited friends, instead of \(GroveFriendAccess.freeFriendLimit)",
                symbol: "person.2.fill"
            ),
            PremiumBenefit(
                kind: .mascots,
                text: "\(AvatarView.premiumImageNames.count) premium plant mascots",
                symbol: "sparkles"
            )
        ]
        return benefits.filter { $0.kind == leading } + benefits.filter { $0.kind != leading }
    }
}

/// The purchase terms every paywall states, built from the live product.
///
/// StoreKit applies an eligible introductory offer whatever the screen says,
/// so any button that can start a trial has to say so, with the price that
/// follows it and how renewal works. One place writes those sentences so the
/// paywalls cannot drift apart.
@MainActor
enum PremiumTerms {
    static let pendingMessage = "Waiting for approval. Premium turns on as soon as it's approved."
    static let unavailableMessage = "That plan isn't available. Choose the other plan or try again later."
    static let restoreNotFoundMessage = "No Premium purchase found for this Apple Account."

    static func periodWord(_ plan: GrovePremiumStore.Plan) -> String {
        plan == .yearly ? "a year" : "a month"
    }

    /// "7 days free, then $34.99 a year", or nil when this Apple account has
    /// no trial to redeem on this plan.
    static func trialLine(_ premium: GrovePremiumStore, plan: GrovePremiumStore.Plan) -> String? {
        guard !premium.hasPremium,
              let days = premium.freeTrialDays(for: plan),
              let price = premium.displayPrice(for: plan) else { return nil }
        return "\(days) \(days == 1 ? "day" : "days") free, then \(price) \(periodWord(plan))"
    }

    /// "Start 7-day free trial", or nil when the purchase starts no trial.
    static func trialButtonTitle(_ premium: GrovePremiumStore, plan: GrovePremiumStore.Plan) -> String? {
        guard !premium.hasPremium, let label = premium.freeTrialLabel(for: plan) else { return nil }
        return "Start \(label)"
    }

    /// How the selected plan bills and renews. Nil until there is a price.
    static func renewalNote(_ premium: GrovePremiumStore, plan: GrovePremiumStore.Plan) -> String? {
        guard !premium.hasPremium, let price = premium.displayPrice(for: plan) else { return nil }
        if premium.freeTrialDays(for: plan) != nil {
            return "After the free trial, \(price) \(periodWord(plan)), renewing automatically. Cancel any time in Settings at least a day before the trial ends and you won't be charged."
        }
        return "\(price) \(periodWord(plan)), renewing automatically until you cancel. Cancel any time in Settings."
    }
}

/// Free against Premium, three columns, on a faint plate over the night green.
struct PaywallComparisonTable: View {
    let rows: [PaywallComparison]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The two value columns hold short figures, so they get a fixed width
    /// that grows with Dynamic Type, and the label takes what is left.
    @ScaledMetric(relativeTo: .body) private var valueColumn: CGFloat = 88

    private var columnWidth: CGFloat { min(valueColumn, 112) }

    var body: some View {
        VStack(spacing: 0) {
            if !dynamicTypeSize.isAccessibilitySize {
                header
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowView(row)
                if index < rows.count - 1 {
                    Rectangle()
                        .fill(GroveTheme.ink.opacity(0.1))
                        .frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(
            GroveTheme.ink.opacity(0.06),
            in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            columnTitle("Free", colour: GroveTheme.ink.opacity(0.5))
            columnTitle("Premium", colour: GroveTheme.mapThriving)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityHidden(true)
    }

    private func columnTitle(_ text: String, colour: Color) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(colour)
            .frame(width: columnWidth, alignment: .leading)
    }

    @ViewBuilder
    private func rowView(_ row: PaywallComparison) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            // Three columns cannot hold accessibility sizes on a phone; the
            // row stacks and names each side instead.
            VStack(alignment: .leading, spacing: 4) {
                Text(row.label)
                    .font(.body)
                    .foregroundStyle(GroveTheme.ink)
                Text("Free: \(row.free)")
                    .font(.body.weight(.medium))
                    .foregroundStyle(GroveTheme.ink.opacity(0.6))
                Text("Premium: \(row.premium)")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(GroveTheme.mapThriving)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 10) {
                Text(row.label)
                    .font(.body)
                    .foregroundStyle(GroveTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.free)
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(GroveTheme.ink.opacity(0.6))
                    .frame(width: columnWidth, alignment: .leading)
                Text(row.premium)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(GroveTheme.mapThriving)
                    .frame(width: columnWidth, alignment: .leading)
            }
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .padding(.vertical, 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(row.label). Free, \(row.free). Premium, \(row.premium).")
        }
    }
}

/// Three of the Premium mascots, overlapping, with the rest counted.
struct PaywallMascotRow: View {
    private struct Mascot: Identifiable {
        let asset: String
        let name: String
        var id: String { asset }
    }

    private static let featured: [Mascot] = [
        Mascot(asset: "GroveAvatarPremiumMoonlitMonstera", name: "Moonlit monstera"),
        Mascot(asset: "GroveAvatarPremiumGildedGinkgo", name: "gilded ginkgo"),
        Mascot(asset: "GroveAvatarPremiumEmberBegonia", name: "ember begonia")
    ]

    private var caption: String {
        let names = Self.featured.map { $0.name }
        let remaining = AvatarView.premiumImageNames.count - names.count
        let listed = names.joined(separator: ", ")
        return remaining > 0 ? "\(listed) and \(remaining) more" : listed
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: -12) {
                ForEach(Self.featured) { mascot in
                    Image(mascot.asset)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                        .overlay { Circle().stroke(GroveTheme.mapGround, lineWidth: 3) }
                }
            }
            .accessibilityHidden(true)

            Text(caption)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.ink.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Premium mascots: \(caption)")
    }
}

/// A plan option. The selected plan is a white card; the other is an outline
/// on the night green. Every figure comes from the live StoreKit product.
struct PaywallPlanCard: View {
    let title: String
    /// The total price for the plan's period, or nil until the catalogue has
    /// answered.
    let price: String?
    /// Below the title: what it works out to a month, or the trial.
    let detail: String?
    /// The savings proven by live prices, if any.
    let badge: String?
    let isSelected: Bool
    /// True once the store has answered with no price for this plan.
    let isUnavailable: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
    }

    var body: some View {
        Group {
            if isSelected {
                card
                    .background(GroveTheme.surface, in: shape)
                    // Light inside the card, so ink reads dark on white.
                    .environment(\.colorScheme, .light)
            } else {
                card
                    .overlay { shape.stroke(GroveTheme.ink.opacity(0.25), lineWidth: 1.5) }
            }
        }
        .contentShape(shape)
    }

    private var card: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                priceText
                if let badge {
                    Text(badge)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GroveTheme.healthThriving)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var priceText: some View {
        if let price {
            Text(price)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(GroveTheme.ink)
        } else if isUnavailable {
            Text("Unavailable")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GroveTheme.mutedInk)
        } else {
            // Still loading: a shape where the price will be, never a guess.
            Text("$00.00")
                .font(.title3.weight(.bold))
                .foregroundStyle(GroveTheme.ink)
                .redacted(reason: .placeholder)
                .accessibilityLabel("Loading price")
        }
    }
}
