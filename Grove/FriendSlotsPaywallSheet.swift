import SwiftUI

/// The Premium ask for a third friend, as a half sheet over Friends.
///
/// Someone who tapped "Add friend" hit a limit; they did not ask to read about
/// Premium. So this is the smallest interruption that can sell honestly: who
/// already holds the free spots, one sentence of price, one pill, and the way
/// back to Friends is the swipe they already know.
///
/// An unreachable App Store is not this sheet's headline. It used to replace
/// the pitch with "couldn't reach the App Store" and a "Try again" pill, which
/// made the only primary button on the screen an error recovery. Now the price
/// line reports the retry while the sheet retries on its own, and the pill
/// keeps meaning the same thing: it retries first if it has to, then buys.
struct FriendSlotsPaywallSheet: View {
    @Environment(GroveStore.self) private var store
    @Environment(GrovePremiumStore.self) private var premium
    @Environment(\.dismiss) private var dismiss

    @State private var plan: GrovePremiumStore.Plan = .yearly
    @State private var isWorking = false
    @State private var isRetrying = false
    @State private var failure: String?
    /// A neutral outcome, such as a purchase waiting on Ask to Buy.
    @State private var notice: String?
    @State private var contentHeight: CGFloat = 360

    private let limit = GroveFriendAccess.freeFriendLimit

    private var isPurchasable: Bool {
        premium.displayPrice(for: .yearly) != nil || premium.displayPrice(for: .monthly) != nil
    }

    /// The store never answered. Not the same as "nothing on sale": being
    /// offline must never be the free way past the friend limit.
    private var isStoreUnreachable: Bool {
        !premium.didLoadCatalogue
    }

    /// The store answered with nothing to sell, so the limit is lifted rather
    /// than walling someone in behind a product that does not exist.
    private var isUnsold: Bool {
        !isStoreUnreachable && !isPurchasable
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                seats
                    .padding(.bottom, 16)

                Text(heading)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 12)

                if !isUnsold {
                    // The same three lines every Grove paywall lists, so a
                    // friend-limit sheet sells exactly what the others do.
                    benefits
                        .padding(.bottom, 14)
                }

                Text(priceLine)
                    .font(.subheadline)
                    .foregroundStyle(failure == nil ? GroveTheme.mutedInk : GroveTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(GroveMotion.settle, value: priceLine)
                    .padding(.bottom, 20)

                GroveCTAButton(title: ctaTitle) {
                    Task { await primaryAction() }
                }
                .disabled(isWorking)

                if isPurchasable {
                    if let renewal = PremiumTerms.renewalNote(premium, plan: plan) {
                        Text(renewal)
                            .font(.caption)
                            .foregroundStyle(GroveTheme.subtleInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                    }
                    footer
                        .padding(.top, 6)
                    OnboardingLegalFooter(tint: GroveTheme.subtleInk)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                }
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, 28)
            .padding(.bottom, 16)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height.rounded(.up)
            } action: { height in
                guard height > 0, contentHeight != height else { return }
                contentHeight = height
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .background(GroveTheme.background)
        .presentationBackground(GroveTheme.background)
        .presentationDetents([.height(contentHeight)])
        .presentationCornerRadius(GroveTheme.heroRadius)
        .presentationDragIndicator(.visible)
        .task { await retryUntilReachable() }
    }

    // MARK: - Seats

    /// Who holds the free spots, then the one Premium opens. A request still
    /// waiting on a reply holds its spot, so it is drawn faded, the same way
    /// the Friends page draws it.
    private var seats: some View {
        let friends = Array(store.friends.prefix(limit))
        let invitations = Array(
            store.friendInvitations
                .filter { $0.direction == .outgoing }
                .prefix(max(0, limit - friends.count))
        )
        let open = max(0, limit - friends.count - invitations.count)
        return HStack(spacing: -8) {
            ForEach(friends) { friend in
                AvatarView(initials: friend.initials, seed: friend.id, size: 36)
                    .overlay(Circle().strokeBorder(GroveTheme.background, lineWidth: 2))
            }
            ForEach(invitations) { invitation in
                AvatarView(
                    initials: invitation.initials,
                    seed: invitation.accountID ?? invitation.username,
                    size: 36
                )
                .opacity(0.45)
                .overlay(Circle().strokeBorder(GroveTheme.background, lineWidth: 2))
            }
            ForEach(0..<open, id: \.self) { _ in
                emptySeat(symbol: nil)
            }
            emptySeat(symbol: "plus")
                .padding(.leading, 4)
        }
        .accessibilityHidden(true)
    }

    private func emptySeat(symbol: String?) -> some View {
        Circle()
            .strokeBorder(GroveTheme.subtleInk, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
            .background(Circle().fill(GroveTheme.background))
            .frame(width: 36, height: 36)
            .overlay {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GroveTheme.subtleInk)
                }
            }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(PremiumBenefit.all(leading: .friends)) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: item.symbol)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GroveTheme.accent)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text(item.text)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Copy

    private var heading: String {
        isUnsold ? "Invite as many as you like" : "Friend \(limit + 1) needs Premium"
    }

    private var priceLine: String {
        if let failure { return failure }
        if let notice { return notice }
        if isUnsold {
            return "Premium isn't on sale yet, so extra friends are on us for now."
        }
        guard let price = premium.displayPrice(for: plan) else {
            if premium.didLoadCatalogue { return "This plan isn't available right now." }
            return isRetrying
                ? "Checking the App Store for prices…"
                : "Prices didn't load. Trying again shortly."
        }
        // How cancelling works is the renewal note's job, under the pill.
        if let trial = PremiumTerms.trialLine(premium, plan: plan) {
            return "\(trial)."
        }
        return "\(price) \(PremiumTerms.periodWord(plan))."
    }

    private var ctaTitle: String {
        if isUnsold { return "Carry on inviting" }
        if isWorking { return "One moment…" }
        if let trial = PremiumTerms.trialButtonTitle(premium, plan: plan) { return trial }
        return "Get Premium"
    }

    // MARK: - Footer

    /// Monthly stays one tap away and unshamed; the yearly plan is simply the
    /// one the sentence above describes first.
    private var footer: some View {
        let other: GrovePremiumStore.Plan = plan == .yearly ? .monthly : .yearly
        return HStack {
            if let price = premium.displayPrice(for: other) {
                Button {
                    Haptics.selection()
                    failure = nil
                    notice = nil
                    withAnimation(GroveMotion.settle) { plan = other }
                } label: {
                    Text(other == .monthly ? "Or \(price) a month" : "Or \(price) a year")
                        .frame(minHeight: 44)
                }
            }
            Spacer(minLength: 12)
            Button("Restore") {
                Task { await restore() }
            }
            .frame(minHeight: 44)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(GroveTheme.mutedInk)
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    /// Quietly retries the catalogue while the sheet is open, so a dropped
    /// connection heals itself instead of asking the user to press a button.
    private func retryUntilReachable() async {
        var delay: Duration = .seconds(2)
        while isStoreUnreachable, !Task.isCancelled {
            isRetrying = true
            await premium.load()
            isRetrying = false
            guard isStoreUnreachable else { break }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(30))
        }
        selectAvailablePlan()
    }

    /// The sentence and the pill describe one plan. If the store answered
    /// without that one, the sheet moves to the plan it can actually sell.
    private func selectAvailablePlan() {
        let other: GrovePremiumStore.Plan = plan == .yearly ? .monthly : .yearly
        if premium.displayPrice(for: plan) == nil, premium.displayPrice(for: other) != nil {
            plan = other
        }
    }

    private func primaryAction() async {
        failure = nil
        notice = nil
        if isUnsold {
            premium.grantUnsoldPremium()
            dismiss()
            return
        }
        isWorking = true
        defer { isWorking = false }
        if !isPurchasable {
            await premium.load()
            guard isPurchasable else {
                if isUnsold {
                    premium.grantUnsoldPremium()
                    dismiss()
                } else {
                    failure = "Still can't reach the App Store. Check your connection and tap again."
                }
                return
            }
            selectAvailablePlan()
        }
        switch await premium.purchase(plan) {
        case .unlocked:
            Haptics.celebrate()
            dismiss()
        case .pending:
            // Ask to Buy: nothing is charged or unlocked yet, so the sheet
            // stays and says which of those it is.
            notice = PremiumTerms.pendingMessage
        case .cancelled:
            break
        case .unavailable:
            // Lifts the limit only when the whole catalogue is empty; a single
            // missing plan is said out loud instead of a silent close.
            premium.grantUnsoldPremium()
            if premium.hasPremium {
                dismiss()
            } else {
                failure = PremiumTerms.unavailableMessage
            }
        case .failed(let message):
            failure = message
        }
    }

    private func restore() async {
        failure = nil
        notice = nil
        isWorking = true
        defer { isWorking = false }
        switch await premium.restorePurchases() {
        case .restored:
            Haptics.celebrate()
            dismiss()
        case .notFound:
            failure = PremiumTerms.restoreNotFoundMessage
        case .failed(let message):
            failure = message
        }
    }
}
