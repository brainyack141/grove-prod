import Inject
import SwiftUI

/// The social allowance is expressed as friend *spots*: an outgoing request
/// reserves one until it is accepted or cancelled, so a free account cannot
/// send a stack of requests that later grows past the two-friend limit.
enum GroveFriendAccess {
    static let freeFriendLimit = 2

    static func hasAvailableSlot(
        friendCount: Int,
        reservedSlotCount: Int,
        hasPremiumAccess: Bool
    ) -> Bool {
        hasPremiumAccess || friendCount + reservedSlotCount < freeFriendLimit
    }
}

struct FriendsView: View {
    /// Hot reload's SwiftUI half. Injection swaps the recompiled method bodies
    /// in, but SwiftUI only redraws when something invalidates the view, which
    /// is this pair's whole job: the wrapper observes the injection notice and
    /// `.enableInjection()` at the end of `body` marks the tree to rebuild.
    ///
    /// Both are no-ops in Release (see the packages note in project.yml), so
    /// this is a two-line cost to make Friends reload in place instead of
    /// costing a full rebuild every time a card moves. Worth copying onto any
    /// view being actively designed; worth deleting again once it settles.
    @ObserveInjection var inject
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(GrovePremiumStore.self) private var premium
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var searchText = ""
    @State private var presentedSheet: FriendSheet?
    @State private var pendingFriendActionIDs = Set<UUID>()
    /// Incoming invitations being accepted right now. Only these hold a spot:
    /// `pendingFriendActionIDs` also carries declines and withdrawals, and
    /// counting those briefly turned "Invite a friend" into the paywall.
    @State private var pendingAcceptIDs = Set<UUID>()
    @FocusState private var searchFocused: Bool

    /// A field to find one of two friends is a control with nothing to do.
    /// It appears once the circle is big enough to lose someone in.
    private var showsSearch: Bool { store.friends.count > 5 }

    private var incomingInvitations: [FriendInvitation] {
        store.friendInvitations.filter { $0.direction == .incoming }
    }

    private var outgoingInvitations: [FriendInvitation] {
        store.friendInvitations.filter { $0.direction == .outgoing }
    }

    /// Handovers this account has been asked to take on, read from the same
    /// store list the Plant sitting screen and the tab badge use.
    private var pendingSittingInvitations: [SittingAssignment] {
        store.pendingIncomingSittingInvitations()
    }

    /// Most recently active first, so the page reads as a living circle.
    private var sortedFriends: [PlantFriend] {
        store.friends.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    private var filteredFriends: [PlantFriend] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sortedFriends.filter { friend in
            query.isEmpty
                || friend.name.localizedCaseInsensitiveContains(query)
                || friend.username.localizedCaseInsensitiveContains(query)
        }
    }

    /// The handover worth spotlighting: happening now, then starting soonest.
    ///
    /// Reads the live status rather than the stored one, which nothing in the
    /// app advances, and includes invitations still waiting on a reply and
    /// links out with a sitter, which is exactly what an owner most wants to be
    /// reminded of.
    private var spotlightHandover: FriendsHandover? {
        FriendsHandover.focus(in: store)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var hasAvailableFriendSlot: Bool {
        GroveFriendAccess.hasAvailableSlot(
            friendCount: store.friends.count,
            reservedSlotCount: outgoingInvitations.count + pendingAcceptIDs.count,
            hasPremiumAccess: premium.isUnmetered
        )
    }

    var body: some View {
        GroveBoardPage {
            friendsHero
        } sheet: {
                GroveTabHeader(title: "Friends", subtitle: friendsHeaderLine)

                if !isSearching, !pendingSittingInvitations.isEmpty {
                    sittingInvitationsSection
                }

                if showsSearch {
                    GroveSearchBar(text: $searchText, prompt: "Find a friend", isFocused: $searchFocused)
                }

                friendsSection

                if !incomingInvitations.isEmpty {
                    requestsSection
                }

                if !isSearching, !outgoingInvitations.isEmpty {
                    pendingSection
                }

                if !isSearching {
                    sittingEntry
                }

                if !isSearching, !store.friends.isEmpty {
                    if premium.isUnmetered {
                        inviteFooter
                    } else {
                        freeCircleCard
                    }
                }
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            await syncEngine.synchronize(store: store, isConnected: connectivity.isConnected)
        }
        .task {
            await syncEngine.synchronize(store: store, isConnected: connectivity.isConnected)
        }
        .toolbar {
            if store.displayStreak > 0 {
                ToolbarItem(placement: .topBarLeading) {
                    GroveHeaderStreak().groveHeaderChip()
                }
            }
            // Two trailing chips, like My Grove. Invitations used to be a text
            // link under the title — the only root whose header carried a
            // navigation row — and now sit where every other tab keeps its
            // secondary destinations.
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink(value: AppRoute.friendInvitations) {
                    GroveHeaderIcon(symbol: "envelope", showsBadge: !incomingInvitations.isEmpty)
                }
                .groveHeaderChip()
                .accessibilityLabel(
                    incomingInvitations.isEmpty
                        ? "Invitations"
                        : "Invitations, \(incomingInvitations.count) waiting"
                )
                Button(action: openInvite) {
                    GroveHeaderIcon(symbol: "person.badge.plus")
                }
                .groveHeaderChip()
                .accessibilityLabel(
                    hasAvailableFriendSlot ? "Invite a friend" : "Unlock more friend spots"
                )
            }
        }
        .groveRootHeaderBar(title: "Friends")
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .invite:
                NavigationStack { InviteFriendView() }
            case .premium:
                FriendSlotsPaywallSheet()
            }
        }
        .enableInjection()
    }

    // MARK: - Header

    /// How many people can be handed a watering can. The free-plan arithmetic
    /// lives in its own card further down, at the moment it decides something.
    private var friendCountLine: String {
        // The hero already counts the circle; the section names it.
        "Who can water while you're away"
    }

    // MARK: - Sitting invitations

    /// A friend has asked this account to water their plants. It sits above
    /// everything else because it is the one request here with a deadline:
    /// their trip starts whether or not the sitter ever answers.
    private var sittingInvitationsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FriendsSectionTitle(
                title: "Invited to sit",
                subtitle: "Answer before their trip starts"
            )
            ForEach(pendingSittingInvitations) { assignment in
                IncomingAssignmentCard(assignment: assignment)
            }
        }
    }

    /// A permanent, quiet door to the whole of Plant sitting: a sitter needs it
    /// to find what they have agreed to, and an owner to arrange cover, whatever
    /// the hero above happens to be showing.
    private var sittingEntry: some View {
        NavigationLink(value: AppRoute.sitting) {
            HStack(spacing: 12) {
                GroveSymbolTile(
                    symbol: "person.2.badge.gearshape",
                    tint: GroveTheme.accentStrong,
                    size: 38
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plant sitting")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GroveTheme.ink)
                    Text("Arrange cover or see handovers")
                        .font(.footnote)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroveTheme.subtleInk)
            }
            .groveCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("friendsPlantSitting")
    }

    // MARK: - Requests

    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            FriendsSectionTitle(
                title: "Invitations",
                subtitle: "\(incomingInvitations.count) waiting"
            )
            let invitations = incomingInvitations
            ForEach(Array(invitations.enumerated()), id: \.element.id) { index, invitation in
                FriendInvitationBoardRow(
                    invitation: invitation,
                    onAccept: {
                        respond(to: invitation.id, accept: true)
                    },
                    onDecline: {
                        respond(to: invitation.id, accept: false)
                    },
                    isResponding: pendingFriendActionIDs.contains(invitation.id),
                    isAcceptLocked: !hasAvailableFriendSlot,
                    isLast: index == invitations.count - 1
                )
                // Answering removes the row; it leaves the way it arrived
                // instead of vanishing between frames.
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
    }

    /// Online, the server settles the relationship before the phone renders
    /// the answer. Offline, the durable local-first queue preserves a decision
    /// made without signal and reconciles it when the connection returns.
    private func respond(to invitationID: UUID, accept: Bool) {
        guard store.friendInvitations.contains(where: {
            $0.id == invitationID && $0.direction == .incoming
        }) else { return }
        guard !accept || hasAvailableFriendSlot else {
            Haptics.selection()
            presentedSheet = .premium
            return
        }
        let request = RespondToFriendInvitationRequest(
            invitationID: invitationID,
            accept: accept,
            clientRequestID: UUID()
        )

        guard connectivity.isConnected else {
            guard pendingFriendActionIDs.insert(invitationID).inserted else { return }
            if accept { pendingAcceptIDs.insert(invitationID) }
            Task {
                defer {
                    pendingFriendActionIDs.remove(invitationID)
                    pendingAcceptIDs.remove(invitationID)
                }
                guard await syncEngine.enqueue(.respondToFriendInvitation(request), isConnected: false) else {
                    Haptics.error()
                    toasts?.show(
                        "That response couldn't be saved for later. Try again.",
                        symbol: "exclamationmark.circle.fill"
                    )
                    return
                }
                commitResponseLocally(
                    invitationID: invitationID,
                    accept: accept,
                    activityEventID: request.clientRequestID
                )
            }
            return
        }

        guard pendingFriendActionIDs.insert(invitationID).inserted else { return }
        if accept { pendingAcceptIDs.insert(invitationID) }
        Task {
            defer {
                pendingFriendActionIDs.remove(invitationID)
                pendingAcceptIDs.remove(invitationID)
            }
            do {
                try await syncEngine.respondToFriendInvitation(request)
                commitResponseLocally(
                    invitationID: invitationID,
                    accept: accept,
                    activityEventID: request.clientRequestID
                )
            } catch is CancellationError {
                return
            } catch {
                Haptics.error()
                toasts?.show(
                    (error as? LocalizedError)?.errorDescription
                        ?? "That request couldn't be updated. Try again.",
                    symbol: "exclamationmark.circle.fill"
                )
            }
        }
    }

    private func commitResponseLocally(invitationID: UUID, accept: Bool, activityEventID: UUID) {
        let committed = withAnimation(GroveMotion.settle) {
            accept
                ? store.acceptFriendInvitation(id: invitationID, activityEventID: activityEventID)
                : store.declineFriendInvitation(id: invitationID)
        }
        guard committed != nil else { return }
        accept ? Haptics.celebrate() : Haptics.commit()
    }

    // MARK: - Sitting spotlight

    /// Friends' hero: the live handover, Flighty-style, when someone is
    /// sitting; otherwise the faces in your circle.
    @ViewBuilder
    private var friendsHero: some View {
        if let handover = spotlightHandover {
            NavigationLink(value: AppRoute.sitting) {
                GroveNightHero {
                    GroveEyebrow(text: "Plant sitting", color: GroveTheme.mapLabel)
                    HStack(spacing: 12) {
                        AvatarView(initials: handover.initials, seed: handover.seed, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(handover.cardTitle)
                                .font(GroveTheme.display(GroveDisplayStyle.heading.points))
                                .foregroundStyle(GroveTheme.ink)
                                .lineLimit(2)
                            Text(handover.cardContext)
                                .font(.subheadline)
                                .foregroundStyle(GroveTheme.mapCaption)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        }
                    }
                    FriendsHeroTrack(handover: handover)
                        .padding(.top, 6)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens plant sitting")
        } else {
            GroveNightHero {
                GroveEyebrow(text: "Your circle", color: GroveTheme.mapLabel)
                if store.friends.isEmpty {
                    Text("Bring in someone who can water while you’re away.")
                        .font(GroveTheme.display(GroveDisplayStyle.heading.points))
                        .foregroundStyle(GroveTheme.ink)
                } else {
                    // Faces first, then the board: the same small-caps-over-
                    // value cells the rest of the app reads in.
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(store.friends.prefix(4)) { friend in
                            VStack(spacing: 6) {
                                AvatarView(initials: friend.initials, seed: friend.id, size: 56)
                                    .overlay(Circle().stroke(GroveTheme.mapThriving.opacity(0.6), lineWidth: 2))
                                Text(friend.name.components(separatedBy: " ").first ?? friend.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(GroveTheme.mapCode)
                                    .lineLimit(1)
                            }
                            .frame(width: 64)
                        }
                    }
                    .accessibilityHidden(true)
                }
                HStack(alignment: .top, spacing: 10) {
                    GroveStatCell(label: "In your circle", value: "\(store.friends.count)", large: true)
                    GroveStatCell(label: "Invitations", value: "\(incomingInvitations.count)", large: true)
                    GroveStatCell(
                        label: "Free spots",
                        // Pending invitations hold a spot, the same way the
                        // free-circle card below counts them.
                        value: premium.isUnmetered
                            ? "No limit"
                            : "\(max(0, GroveFriendAccess.freeFriendLimit - usedFreeSpots))",
                        large: true
                    )
                }
                .padding(.top, 6)
            }
        }
    }

    /// The tab's one fact, in the header every tab shares.
    private var friendsHeaderLine: String {
        if let spotlightHandover {
            return "Sitting until \(FriendsDateText.shortDay(spotlightHandover.endDate))"
        }
        return "Plant sitting and shared care"
    }

    private func sittingSpotlight(_ handover: FriendsHandover) -> some View {
        NavigationLink(value: AppRoute.sitting) {
            FriendsHandoverCard(handover: handover)
                .groveTabHero()
        }
        .buttonStyle(GroveCardPressStyle())
    }

    // MARK: - Friends

    @ViewBuilder
    private var friendsSection: some View {
        if store.friends.isEmpty {
            FriendsEmptyPitch(
                hasPremiumAccess: premium.isUnmetered,
                onInvite: openInvite,
                onUnlockPremium: { presentedSheet = .premium }
            )
        } else if filteredFriends.isEmpty {
            GroveEmptyState(
                scene: .noMatches,
                title: "Nobody by that name",
                message: "Try another name or username."
            )
            .frame(minHeight: 200)
        } else {
            let friends = filteredFriends
            VStack(alignment: .leading, spacing: 2) {
                FriendsSectionTitle(
                    title: "Your circle",
                    subtitle: isSearching ? nil : friendCountLine
                )
                ForEach(Array(friends.enumerated()), id: \.element.id) { index, friend in
                    NavigationLink(value: AppRoute.friendGrove(friend.id)) {
                        FriendCircleRow(
                            friend: friend,
                            handover: FriendsHandover.forFriend(friend, in: store),
                            isLast: index == friends.count - 1
                        )
                    }
                    .buttonStyle(.plain)
                    .groveHeroSource(.friendGrove(friend.id))
                }
            }
        }
    }

    // MARK: - Pending

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            FriendsSectionTitle(title: "Invited", subtitle: "Waiting on them to accept")
            ForEach(outgoingInvitations) { invitation in
                // A request you sent is yours to take back. Swiping it away is
                // the gesture people already try on a row like this.
                SwipeActionRow(
                    title: "Cancel",
                    symbol: "xmark",
                    cornerRadius: GroveTheme.cardRadius,
                    accessibilityLabel: "Invitation to @\(invitation.username), pending",
                    onAct: { withdraw(invitation) }
                ) {
                    FriendPersonRow(
                        name: invitation.name,
                        secondary: "@\(invitation.username)",
                        initials: invitation.initials,
                        seed: invitation.accountID ?? invitation.username
                    ) {
                        GrovePill(text: "Pending", systemImage: "clock", style: .outline)
                    }
                    .padding(FriendRowMetrics.padding)
                    .groveCard(padding: 0)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
    }

    /// Takes back an invitation and tells the server, so it leaves the other
    /// gardener's requests too.
    private func withdraw(_ invitation: FriendInvitation) {
        guard !pendingFriendActionIDs.contains(invitation.id) else { return }
        let request = WithdrawFriendInvitationRequest(
            invitationID: invitation.id,
            clientRequestID: UUID()
        )

        guard connectivity.isConnected else {
            pendingFriendActionIDs.insert(invitation.id)
            Task {
                defer { pendingFriendActionIDs.remove(invitation.id) }
                guard await syncEngine.enqueue(.withdrawFriendInvitation(request), isConnected: false) else {
                    Haptics.error()
                    toasts?.show(
                        "That cancellation couldn't be saved for later. Try again.",
                        symbol: "exclamationmark.circle.fill"
                    )
                    return
                }
                commitWithdrawalLocally(invitation)
            }
            return
        }

        pendingFriendActionIDs.insert(invitation.id)
        Task {
            defer { pendingFriendActionIDs.remove(invitation.id) }
            do {
                try await syncEngine.withdrawFriendInvitation(request)
                commitWithdrawalLocally(invitation)
            } catch is CancellationError {
                return
            } catch {
                Haptics.error()
                toasts?.show(
                    (error as? LocalizedError)?.errorDescription
                        ?? "That invitation couldn't be cancelled. Try again.",
                    symbol: "exclamationmark.circle.fill"
                )
            }
        }
    }

    private func commitWithdrawalLocally(_ invitation: FriendInvitation) {
        let committed = withAnimation(GroveMotion.settle) {
            store.withdrawFriendInvitation(id: invitation.id)
        }
        guard committed != nil else { return }
        Haptics.commit()
        toasts?.show("Invitation to @\(invitation.username) cancelled", symbol: "xmark.circle.fill")
    }

    // MARK: - Free spots

    private var usedFreeSpots: Int {
        min(GroveFriendAccess.freeFriendLimit, store.friends.count + outgoingInvitations.count)
    }

    /// The free plan and the invite button as one card. The limit is read at
    /// the moment someone is about to invite, and once the circle is full the
    /// same button becomes the way past it, instead of a limit card and an
    /// invite button arguing about one decision from two places.
    private var freeCircleCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(freeCircleTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(GroveTheme.ink)
                    Text(freeCircleCaption)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                // The faces are the count drawn, so at accessibility sizes the
                // title can have the width; it already says the number.
                if !dynamicTypeSize.isAccessibilitySize {
                    freeCircleSeats
                        .padding(.top, 2)
                }
            }

            if hasAvailableFriendSlot {
                VStack(spacing: 4) {
                    GroveInkButton(title: "Invite a friend", action: openInvite)
                    Button {
                        Haptics.selection()
                        openPremium()
                    } label: {
                        Text("Want room for more? \(Text("See Premium").fontWeight(.semibold).foregroundStyle(GroveTheme.ink))")
                            .font(.subheadline)
                            .foregroundStyle(GroveTheme.mutedInk)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                GroveInkButton(title: "See Premium", action: openPremium)
            }
        }
        .groveCard(padding: 20)
        .animation(GroveMotion.settle, value: usedFreeSpots)
    }

    /// Who holds each free spot, then the spots still open. An invitation
    /// still waiting on a reply holds its spot, so it is drawn faded.
    private var freeCircleSeats: some View {
        let limit = GroveFriendAccess.freeFriendLimit
        let friends = Array(store.friends.prefix(limit))
        let invitations = Array(outgoingInvitations.prefix(max(0, limit - friends.count)))
        let open = max(0, limit - friends.count - invitations.count)
        return HStack(spacing: 4) {
            ForEach(friends) { friend in
                AvatarView(initials: friend.initials, seed: friend.id, size: 24)
            }
            ForEach(invitations) { invitation in
                AvatarView(
                    initials: invitation.initials,
                    seed: invitation.accountID ?? invitation.username,
                    size: 24
                )
                .opacity(0.45)
            }
            ForEach(0..<open, id: \.self) { _ in
                Circle()
                    .strokeBorder(GroveTheme.subtleInk, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
                    .frame(width: 24, height: 24)
            }
        }
        .accessibilityHidden(true)
    }

    private var freeCircleTitle: String {
        if hasAvailableFriendSlot {
            let left = max(1, GroveFriendAccess.freeFriendLimit - usedFreeSpots)
            return "Invite \(left) more for free"
        }
        if let first = incomingInvitations.first {
            return "\(Self.firstName(first.name)) wants to join"
        }
        return "Your free circle is full"
    }

    private var freeCircleCaption: String {
        if hasAvailableFriendSlot {
            return "Someone who can water while you’re away."
        }
        if !incomingInvitations.isEmpty {
            return "Your free spots are taken. Premium has no friend limit."
        }
        if let invitation = outgoingInvitations.first,
           store.friends.count < GroveFriendAccess.freeFriendLimit {
            return "Your invite to \(Self.firstName(invitation.name)) is holding the last free spot."
        }
        return "Premium has no friend limit."
    }

    private static func firstName(_ name: String) -> String {
        name.components(separatedBy: " ").first ?? name
    }

    // MARK: - Invite footer

    /// Premium only: with no limit there is nothing to count, just the invite.
    private var inviteFooter: some View {
        VStack(spacing: 10) {
            GroveCTAButton(title: "Invite a friend", action: openInvite)
            Text("Someone has to water them while you’re away.")
                .font(.caption)
                .foregroundStyle(GroveTheme.mutedInk)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }

    private func openInvite() {
        presentedSheet = hasAvailableFriendSlot ? .invite : .premium
    }

    private func openPremium() {
        presentedSheet = .premium
    }
}

// MARK: - The person row

/// Everything Friends lists is the same object: a picture, a name, a quiet
/// line under it, and one control on the right. The page drew that object four
/// ways — 36 / 44 / 48 / 52pt pictures, `.headline` names beside
/// `.subheadline` ones, `.caption` handles beside `.footnote` ones, two
/// different greys of chevron, and four paddings — so a request, a sitter, a
/// friend and an invitation read as four unrelated things in one scroll and no
/// two faces sat on the same left edge. One metric now. Rows differ only where
/// they actually differ: what sits at the end of them.
private enum FriendRowMetrics {
    static let avatar: CGFloat = 48
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 14
}

private struct FriendPersonRow<Trailing: View>: View {
    let name: String
    var secondary: String?
    let initials: String
    var seed: String?
    var assetName: String?
    /// The one place a row says something about itself rather than about the
    /// person: the Invitations list mixes both directions, so each row has to
    /// say which one it is.
    var note: String?
    /// A sitting headline is a sentence and may take a second line. A name is
    /// a name: it truncates rather than reflowing the row around it.
    var nameLineLimit: Int = 1
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder var trailing: Trailing

    init(
        name: String,
        secondary: String? = nil,
        initials: String,
        seed: String? = nil,
        assetName: String? = nil,
        note: String? = nil,
        nameLineLimit: Int = 1,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.name = name
        self.secondary = secondary
        self.initials = initials
        self.seed = seed
        self.assetName = assetName
        self.note = note
        self.nameLineLimit = nameLineLimit
        self.trailing = trailing()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: FriendRowMetrics.spacing) {
                    avatar
                    identity
                }
                trailing
            }
        } else {
            HStack(spacing: FriendRowMetrics.spacing) {
                avatar
                identity
                trailing
            }
        }
    }

    private var avatar: some View {
        AvatarView(
            initials: initials,
            seed: seed,
            size: FriendRowMetrics.avatar,
            assetName: assetName
        )
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : Optional(nameLineLimit))
                .fixedSize(horizontal: false, vertical: true)
            if let secondary {
                Text(secondary)
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.accentStrong)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The identity column claims the leftover width rather than
        // splitting it with a `Spacer`, which is what left "Noah Williams"
        // truncated to "Noah Willia…" with 40pt of blank card beside it.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Saying no to a request. Not the mirror of accepting, and a second full
/// pill said it was: two equal capsules sharing a row with a picture and a
/// name were squeezed until their labels hyphenated across two lines
/// ("De-cline", "Ac-cept"). It keeps a full 44pt target and the outline
/// button's own material, one value step down from the card it sits on so the
/// shape still reads on white.
private struct FriendDeclineButton: View {
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(GroveTheme.mutedInk)
                .frame(width: 44, height: 44)
                .background(GroveTheme.background, in: Circle())
                .overlay { Circle().strokeBorder(GroveTheme.separator, lineWidth: 1.5) }
                .contentShape(Circle())
        }
        .buttonStyle(GrovePressStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Board rows

/// One friend on the board: who they are, then a row of small-caps facts.
/// The same anatomy as a plant on Today, so the two pages read as one system.
private struct FriendCircleRow: View {
    let friend: PlantFriend
    /// The handover this friend is part of, if any. Only then is there
    /// anything true to say about what they can do.
    let handover: FriendsHandover?
    var isLast = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AvatarView(initials: friend.initials, seed: friend.id, size: 52)
                .padding(.top, 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 11) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(friend.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(GroveTheme.ink)
                        .lineLimit(1)
                    Text(contextLine)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .lineLimit(1)
                }
                FriendsStatRow(spacing: 8) {
                    // A count of zero reads as broken, not as a fact.
                    if friend.sharedPlantCount > 0 {
                        GroveStatCell(label: "Plants", value: "\(friend.sharedPlantCount)")
                    }
                    GroveStatCell(label: "Active", value: FriendsDateText.recency(friend.lastActiveAt))
                    if let handover {
                        GroveStatCell(label: "Can do", value: handover.canDoValue)
                    } else {
                        FriendsEmptyStatCell()
                    }
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
        .accessibilityElement(children: .combine)
    }

    private var contextLine: String {
        let handle = "@\(friend.username)"
        guard let handover else { return handle }
        switch handover.phase {
        case .active, .notOpened:
            return "\(handle) · sitting for you"
        case .upcoming:
            return "\(handle) · sitting from \(FriendsDateText.shortDay(handover.startDate))"
        case .waiting:
            return "\(handle) · asked to sit"
        }
    }
}

/// Someone who wants to connect, answered in place.
private struct FriendInvitationBoardRow: View {
    let invitation: FriendInvitation
    let onAccept: () -> Void
    let onDecline: () -> Void
    let isResponding: Bool
    let isAcceptLocked: Bool
    var isLast = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AvatarView(
                initials: invitation.initials,
                seed: invitation.accountID ?? invitation.username,
                size: 52
            )
            .accessibilityHidden(true)

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(invitation.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(GroveTheme.ink)
                        .lineLimit(1)
                    Text("@\(invitation.username) · wants to connect")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                controls
            }
            .padding(.vertical, 16)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle().fill(GroveTheme.separator).frame(height: 1)
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if isResponding {
            ProgressView()
                .controlSize(.small)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Updating invitation")
        } else {
            HStack(spacing: 8) {
                FriendDeclineButton(
                    accessibilityLabel: "Decline request from \(invitation.name)",
                    action: onDecline
                )
                GroveInkButton(
                    title: isAcceptLocked ? "Unlock" : "Accept",
                    size: .compact,
                    action: onAccept
                )
            }
            // Both controls keep their own width; the name gives way first.
            .fixedSize()
        }
    }
}

// MARK: - Empty state pitch

/// When the circle is empty, four compact examples make the free/Premium
/// boundary visible before somebody discovers it by trying to add person
/// number three. The first two rows are the included friend spots; the next two
/// are genuine upgrade affordances, not disabled controls with nowhere to go.
private struct FriendsEmptyPitch: View {
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    @AppStorage(GroveDefaults.friendsEmptyExampleDismissed) private var exampleDismissed = false
    @AppStorage(GroveDefaults.friendsEmptyExampleNudged) private var exampleNudged = false
    let hasPremiumAccess: Bool
    let onInvite: () -> Void
    let onUnlockPremium: () -> Void

    private static let examples = [
        FriendExample(
            id: "sample-hannah",
            name: "Hannah Brooks",
            username: "hannahgrows",
            initials: "HB",
            avatarAsset: "GroveFriendAvatarHannah",
            premiumOnly: false
        ),
        FriendExample(
            id: "sample-mara",
            name: "Mara Ellison",
            username: "maragrows",
            initials: "ME",
            avatarAsset: nil,
            premiumOnly: false
        ),
        FriendExample(
            id: "sample-tobi",
            name: "Tobi Adeyemi",
            username: "tobi.plants",
            initials: "TA",
            avatarAsset: nil,
            premiumOnly: true
        ),
        FriendExample(
            id: "sample-june",
            name: "June Park",
            username: "junepark",
            initials: "JP",
            avatarAsset: nil,
            premiumOnly: true
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Invite a friend to water your plants while you're away. They see nothing until you send a sitting link for the plants and dates you choose.")
                .font(.callout)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            if !exampleDismissed {
                examplesCard
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            VStack(spacing: 10) {
                GroveCTAButton(title: "Invite a friend", action: onInvite)
                Text("You can revoke a sitting link or remove a friend at any time.")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// How far the tag hangs above the card's top edge.
    private static let tagOverhang: CGFloat = 10

    private var examplesCard: some View {
        SwipeActionRow(
            title: "Hide",
            symbol: "eye.slash.fill",
            accessibilityLabel: "Example friend spots",
            nudgeOnAppear: !exampleNudged,
            onNudge: { exampleNudged = true },
            onAct: hideExample
        ) {
            VStack(spacing: 0) {
                HStack {
                    Label(
                        "\(GroveFriendAccess.freeFriendLimit) friends included",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GroveTheme.accentStrong)
                    Spacer(minLength: 8)
                    Text("More with Premium")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().overlay(GroveTheme.separator)

                ForEach(Array(Self.examples.enumerated()), id: \.element.id) { index, example in
                    FriendExampleRow(
                        example: example,
                        isLocked: example.premiumOnly && !hasPremiumAccess,
                        onUnlockPremium: onUnlockPremium
                    )
                    if index < Self.examples.count - 1 {
                        Divider()
                            .overlay(GroveTheme.separator)
                            .padding(.leading, 72)
                    }
                }
            }
            .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            .overlay { sampleFrame }
            .overlay(alignment: .topLeading) { sampleTag }
        }
        // The tag is offset and does not take part in layout, so reserve the
        // space it needs above the card.
        .padding(.top, Self.tagOverhang)
    }

    private func hideExample() {
        Haptics.commit()
        withAnimation(GroveMotion.settle) { exampleDismissed = true }
        toasts?.show(
            "Example hidden",
            symbol: "eye.slash.fill",
            actionTitle: "Undo"
        ) {
            withAnimation(GroveMotion.settle) { exampleDismissed = false }
        }
    }

    private var sampleFrame: some View {
        RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
            .strokeBorder(
                GroveTheme.accent.opacity(0.55),
                style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
            )
    }

    /// Sits on the frame rather than inside it, carrying the page ground so the
    /// dashed line reads as interrupted — the way a label on a template does.
    private var sampleTag: some View {
        Text("Examples")
            .font(.caption2.weight(.bold))
            .foregroundStyle(GroveTheme.accentStrong)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(GroveTheme.background, in: Capsule())
            .overlay { Capsule().strokeBorder(GroveTheme.accent.opacity(0.55), lineWidth: 1) }
            // Clear of the card's corner radius, so the pill interrupts a
            // straight run of the dashed line rather than its curve.
            .padding(.leading, GroveTheme.cardRadius)
            .offset(y: -Self.tagOverhang)
    }
}

private struct FriendExample: Identifiable {
    let id: String
    let name: String
    let username: String
    let initials: String
    let avatarAsset: String?
    let premiumOnly: Bool
}

private struct FriendExampleRow: View {
    let example: FriendExample
    let isLocked: Bool
    let onUnlockPremium: () -> Void

    var body: some View {
        Group {
            if isLocked {
                Button(action: onUnlockPremium) { row }
                    .buttonStyle(GroveCardPressStyle(scale: 0.99))
            } else {
                row
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isLocked ? "Opens Grove Premium subscription options" : "")
    }

    private var row: some View {
        HStack(spacing: 12) {
            AvatarView(
                initials: example.initials,
                seed: example.id,
                size: 44,
                assetName: example.avatarAsset
            )
            .saturation(isLocked ? 0.25 : 1)
            .opacity(isLocked ? 0.58 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(example.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isLocked ? GroveTheme.mutedInk : GroveTheme.ink)
                Text("@\(example.username)")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            Spacer(minLength: 8)
            status
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var status: some View {
        Label(
            example.premiumOnly ? "Premium" : "Included",
            systemImage: isLocked ? "lock.fill" : (example.premiumOnly ? "sparkles" : "checkmark")
        )
        .font(.caption2.weight(.bold))
        .foregroundStyle(isLocked ? GroveTheme.ink : GroveTheme.accentStrong)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            isLocked ? GroveTheme.secondarySurface : GroveTheme.softAccent,
            in: Capsule()
        )
    }

    private var accessibilityLabel: String {
        let access = isLocked
            ? "Premium friend spot, locked"
            : (example.premiumOnly ? "Premium friend spot" : "Free friend spot")
        return "\(example.name), at \(example.username), \(access)"
    }
}

/// A custom-layout counterpart to `List.swipeActions`: Friends lives inside a
/// ScrollView, so the system modifier cannot reveal an action here. A short
/// left swipe exposes the action; a decisive swipe commits it, matching the
/// familiar iOS row interaction without replacing the page's editorial layout.
///
/// The gesture used to be taught by a caption under the card. Copy explaining
/// the app's own controls is a smell, so the card teaches it the way Mail's
/// first-run inbox does: once, by moving far enough to show the edge of the
/// action and settling back.
private struct SwipeActionRow<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let symbol: String
    let cornerRadius: CGFloat
    let accessibilityLabel: String
    let nudgeOnAppear: Bool
    let onNudge: () -> Void
    let onAct: () -> Void
    let content: Content

    @State private var horizontalOffset: CGFloat = 0
    @State private var isRevealed = false

    private let actionWidth: CGFloat = 84

    init(
        title: String,
        symbol: String,
        cornerRadius: CGFloat = GroveTheme.cardRadius,
        accessibilityLabel: String,
        nudgeOnAppear: Bool = false,
        onNudge: @escaping () -> Void = {},
        onAct: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.cornerRadius = cornerRadius
        self.accessibilityLabel = accessibilityLabel
        self.nudgeOnAppear = nudgeOnAppear
        self.onNudge = onNudge
        self.onAct = onAct
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive, action: onAct) {
                VStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.headline)
                    Text(title)
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .frame(width: actionWidth)
                .frame(maxHeight: .infinity)
                .background(
                    GroveTheme.danger,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .opacity(actionReveal)
            .allowsHitTesting(isRevealed)
            .accessibilityHidden(!isRevealed)

            content
                .offset(x: horizontalOffset)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isRevealed else { return }
                    settle(revealed: false)
                }
                .simultaneousGesture(swipeGesture)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Swipe left to reveal the \(title) action")
        .accessibilityAction(named: title, onAct)
        .task { await playHintIfNeeded() }
    }

    /// Lands after the screen has settled, shows about a third of the Hide
    /// action, and retreats. Skipped under Reduce Motion, where a card that
    /// slides on its own is exactly what the setting asks us not to do —
    /// VoiceOver still gets the gesture through the hint and the custom action.
    private func playHintIfNeeded() async {
        guard nudgeOnAppear, !reduceMotion else { return }
        onNudge()

        try? await Task.sleep(for: .seconds(0.75))
        guard !isRevealed, horizontalOffset == 0 else { return }
        withAnimation(GroveMotion.snap) { horizontalOffset = -actionWidth * 0.36 }

        try? await Task.sleep(for: .seconds(0.6))
        guard !isRevealed else { return }
        withAnimation(GroveMotion.settle) { horizontalOffset = 0 }
    }

    private var actionReveal: Double {
        min(1, max(0, Double(-horizontalOffset / actionWidth)))
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let origin = isRevealed ? -actionWidth : 0
                horizontalOffset = max(
                    -actionWidth * 1.35,
                    min(0, origin + value.translation.width)
                )
            }
            .onEnded { value in
                guard abs(value.predictedEndTranslation.width) > abs(value.predictedEndTranslation.height) else {
                    settle(revealed: isRevealed)
                    return
                }

                let origin = isRevealed ? -actionWidth : 0
                let projected = origin + value.predictedEndTranslation.width
                if projected < -actionWidth * 1.4 {
                    onAct()
                } else {
                    settle(revealed: projected < -actionWidth * 0.55)
                }
            }
    }

    private func settle(revealed: Bool) {
        isRevealed = revealed
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : GroveMotion.snap) {
            horizontalOffset = revealed ? -actionWidth : 0
        }
    }
}
// MARK: - Invite sheet

private enum FriendSheet: String, Identifiable {
    case invite
    case premium
    var id: String { rawValue }
}

struct InviteFriendView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(GrovePremiumStore.self) private var premium
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    @State private var username: String
    @State private var errorMessage: String?
    @State private var isSending = false
    @State private var isShowingPremium = false
    @State private var isRefreshing = true
    @FocusState private var fieldFocused: Bool

    /// False when pushed onto a stack, where Back already closes it: a sheet
    /// needs Cancel, a pushed page offering both reads as two ways out.
    private let showsCancel: Bool

    init(initialUsername: String = "", showsCancel: Bool = true) {
        _username = State(initialValue: initialUsername)
        self.showsCancel = showsCancel
    }

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var outgoingInvitationCount: Int {
        store.friendInvitations.filter { $0.direction == .outgoing }.count
    }

    private var hasAvailableFriendSlot: Bool {
        GroveFriendAccess.hasAvailableSlot(
            friendCount: store.friends.count,
            reservedSlotCount: outgoingInvitationCount,
            hasPremiumAccess: premium.isUnmetered
        )
    }

    private var shareMessage: String {
        // Without a handle the old copy shipped a dangling "@" to the share
        // sheet, which reads as a bug in someone else's messages.
        store.profile.username.isEmpty
            ? "I use Grove for plant care. Add me as a friend for plant sitting."
            : "Add @\(store.profile.username) as a friend for plant sitting in Grove."
    }

    private var inviteURL: URL {
        var components = URLComponents(string: "https://www.downloadgrove.com/friends")!
        if !store.profile.username.isEmpty {
            components.queryItems = [URLQueryItem(name: "username", value: store.profile.username)]
        }
        return components.url!
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                FriendsPageTitle(title: "Invite a friend")

                if store.friendInvitations.contains(where: {
                    $0.direction == .incoming && $0.username == GroveStore.normalizedUsername(username)
                }) {
                    Text("@\(GroveStore.normalizedUsername(username)) has already invited you to connect.")
                        .font(.body)
                        .foregroundStyle(GroveTheme.mutedInk)
                    NavigationLink {
                        FriendInvitationsView()
                    } label: {
                        GroveOutlineLabel(title: "Review connection request", systemImage: "envelope.open")
                    }
                    .buttonStyle(GrovePressStyle())
                } else if hasAvailableFriendSlot {
                    inviteControls
                } else {
                    friendLimitGate
                }
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, GroveTheme.pageTopPadding)
            .padding(.bottom, GroveTheme.pageBottomPadding)
        }
        .groveBackground()
        .groveHeaderBar()
        .toolbar {
            if showsCancel {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .sheet(isPresented: $isShowingPremium) {
            FriendSlotsPaywallSheet()
        }
        .onAppear { fieldFocused = hasAvailableFriendSlot && trimmedUsername.isEmpty }
        .task {
            await syncEngine.synchronize(store: store, isConnected: connectivity.isConnected)
            isRefreshing = false
        }
    }

    private var inviteControls: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("@")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(GroveTheme.mutedInk)
                    TextField("username", text: $username)
                        .font(.headline)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .submitLabel(.send)
                        .disabled(isSending)
                        .onSubmit {
                            guard !trimmedUsername.isEmpty else { return }
                            Task { await send() }
                        }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
                .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                        .stroke(fieldFocused ? GroveTheme.accent.opacity(0.6) : GroveTheme.separator, lineWidth: fieldFocused ? 2 : 1)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GroveTheme.danger)
                }

                Text("A connection shares no plants. You choose plants, dates and permissions separately when you make a sitting link.")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The button waits for the server's answer, so it says so. Anything
            // faster would show a Pending row for a gardener who may not exist.
            GroveCTAButton(title: isSending ? "Sending…" : "Send invitation") {
                Task { await send() }
            }
            .disabled(trimmedUsername.isEmpty || isSending || isRefreshing)
            // Still the ink button, just resting: at 40% it washed out to a
            // grey pill that read as broken rather than "type a name first".
            .opacity(trimmedUsername.isEmpty || isSending || isRefreshing ? 0.6 : 1)

            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    line
                    Text("or")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GroveTheme.subtleInk)
                    line
                }
                ShareLink(
                    item: inviteURL,
                    subject: Text("Join me on Grove"),
                    message: Text(shareMessage)
                ) {
                    GroveOutlineLabel(title: "Share an invite", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(GrovePressStyle())
            }
        }
    }

    private var friendLimitGate: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                GroveSymbolTile(symbol: "person.2.fill", size: 52)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your free friend spots are full")
                        .font(.headline)
                        .foregroundStyle(GroveTheme.ink)
                    Text("Free includes \(GroveFriendAccess.freeFriendLimit) friends. Grove Premium lets you keep growing your circle.")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GroveCTAButton(title: "Unlock more friend spots", systemImage: "lock.open.fill") {
                isShowingPremium = true
            }
        }
        .groveCard()
    }

    private var line: some View {
        Rectangle().fill(GroveTheme.separator).frame(height: 1)
    }

    /// Sends the invitation and waits for the server to say who it reached.
    ///
    /// The screen used to add a Pending row on the spot and queue the request,
    /// so a typo or a friend who had not joined yet sat in the Invited list for
    /// good while the refusal went to the sync issues page. Nothing is recorded
    /// here until an account with that username answers to it.
    private func send() async {
        guard !isSending, !isRefreshing else { return }
        guard hasAvailableFriendSlot else {
            isShowingPremium = true
            return
        }
        if let problem = store.friendInviteProblem(for: username) {
            errorMessage = problem.message
            return
        }
        guard connectivity.isConnected else {
            // Same words the API layer uses for a dropped connection, because
            // it is the same situation: nothing left the phone.
            errorMessage = "You're offline. Reconnect and try again."
            return
        }

        let handle = GroveStore.normalizedUsername(username)
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            let requestID = UUID()
            let sent = try await syncEngine.sendFriendInvitation(
                CreateFriendInvitationRequest(username: handle, clientRequestID: requestID)
            )
            store.inviteFriend(
                username: sent.username,
                accountID: sent.accountID,
                displayName: sent.name,
                id: sent.id,
                activityEventID: requestID
            )
            Haptics.commit()
            toasts?.show("Sent to @\(sent.username). They can accept in Friends → Invitations.", symbol: "paperplane.fill")
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            fieldFocused = true
            errorMessage = (error as? APIError)?.errorDescription
                ?? "That invitation didn't send. Try again in a moment."
        }
    }
}

// MARK: - Invitations route (kept for AppRoute.friendInvitations)

struct FriendInvitationsView: View {
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(GrovePremiumStore.self) private var premium
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    @State private var pendingResponseIDs = Set<UUID>()
    @State private var isShowingPremium = false

    private var hasAvailableFriendSlot: Bool {
        GroveFriendAccess.hasAvailableSlot(
            friendCount: store.friends.count,
            reservedSlotCount: store.friendInvitations.filter { $0.direction == .outgoing }.count
                + pendingResponseIDs.count,
            hasPremiumAccess: premium.isUnmetered
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if store.friendInvitations.isEmpty {
                    GroveEmptyState(
                        scene: .company,
                        title: "No invitations",
                        message: "Friend requests land here."
                    )
                    .frame(minHeight: 260)
                    .frame(maxWidth: .infinity)
                } else {
                    // The same row Friends draws, drawn the same way. This
                    // screen is one tap from that one and had its own metric,
                    // its own type scale and the same pair of squeezed pills.
                    ForEach(store.friendInvitations) { invitation in
                        FriendPersonRow(
                            name: invitation.name,
                            secondary: "@\(invitation.username)",
                            initials: invitation.initials,
                            seed: invitation.accountID ?? invitation.username,
                            note: invitation.direction == .incoming ? "Wants to connect" : "Waiting on them"
                        ) {
                            if invitation.direction == .incoming {
                                if pendingResponseIDs.contains(invitation.id) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 44, height: 44)
                                        .accessibilityLabel("Updating invitation")
                                } else {
                                    HStack(spacing: 8) {
                                        FriendDeclineButton(
                                            accessibilityLabel: "Decline request from \(invitation.name)"
                                        ) {
                                            respond(to: invitation.id, accept: false)
                                        }
                                        GroveInkButton(
                                            title: hasAvailableFriendSlot ? "Accept" : "Unlock",
                                            size: .compact
                                        ) {
                                            respond(to: invitation.id, accept: true)
                                        }
                                    }
                                    .fixedSize()
                                }
                            } else {
                                if pendingResponseIDs.contains(invitation.id) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 44, height: 44)
                                        .accessibilityLabel("Cancelling invitation")
                                } else {
                                    GroveOutlineButton(title: "Cancel", size: .compact) {
                                        withdraw(invitation)
                                    }
                                    .fixedSize()
                                }
                            }
                        }
                        .padding(FriendRowMetrics.padding)
                        .groveCard(padding: 0)
                    }
                }
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, GroveTheme.pageTopPadding)
            .padding(.bottom, GroveTheme.pageBottomPadding)
        }
        .refreshable {
            await syncEngine.synchronize(store: store, isConnected: connectivity.isConnected)
        }
        .groveBackground()
        .groveEditorialPage("Invitations")
        .task {
            await syncEngine.synchronize(store: store, isConnected: connectivity.isConnected)
        }
        .sheet(isPresented: $isShowingPremium) {
            FriendSlotsPaywallSheet()
        }
    }

    private func respond(to invitationID: UUID, accept: Bool) {
        guard store.friendInvitations.contains(where: {
            $0.id == invitationID && $0.direction == .incoming
        }) else { return }
        guard !accept || hasAvailableFriendSlot else {
            Haptics.selection()
            isShowingPremium = true
            return
        }
        let request = RespondToFriendInvitationRequest(
            invitationID: invitationID,
            accept: accept,
            clientRequestID: UUID()
        )

        guard connectivity.isConnected else {
            guard pendingResponseIDs.insert(invitationID).inserted else { return }
            Task {
                defer { pendingResponseIDs.remove(invitationID) }
                guard await syncEngine.enqueue(.respondToFriendInvitation(request), isConnected: false) else {
                    Haptics.error()
                    toasts?.show(
                        "That response couldn't be saved for later. Try again.",
                        symbol: "exclamationmark.circle.fill"
                    )
                    return
                }
                commitResponseLocally(
                    invitationID: invitationID,
                    accept: accept,
                    activityEventID: request.clientRequestID
                )
            }
            return
        }

        guard pendingResponseIDs.insert(invitationID).inserted else { return }
        Task {
            defer { pendingResponseIDs.remove(invitationID) }
            do {
                try await syncEngine.respondToFriendInvitation(request)
                commitResponseLocally(
                    invitationID: invitationID,
                    accept: accept,
                    activityEventID: request.clientRequestID
                )
            } catch is CancellationError {
                return
            } catch {
                Haptics.error()
                toasts?.show(
                    (error as? LocalizedError)?.errorDescription
                        ?? "That request couldn't be updated. Try again.",
                    symbol: "exclamationmark.circle.fill"
                )
            }
        }
    }

    private func withdraw(_ invitation: FriendInvitation) {
        guard invitation.direction == .outgoing,
              pendingResponseIDs.insert(invitation.id).inserted else { return }
        let request = WithdrawFriendInvitationRequest(
            invitationID: invitation.id,
            clientRequestID: UUID()
        )

        guard connectivity.isConnected else {
            Task {
                defer { pendingResponseIDs.remove(invitation.id) }
                guard await syncEngine.enqueue(.withdrawFriendInvitation(request), isConnected: false) else {
                    Haptics.error()
                    toasts?.show(
                        "That cancellation couldn't be saved for later. Try again.",
                        symbol: "exclamationmark.circle.fill"
                    )
                    return
                }
                commitWithdrawalLocally(invitation)
            }
            return
        }

        Task {
            defer { pendingResponseIDs.remove(invitation.id) }
            do {
                try await syncEngine.withdrawFriendInvitation(request)
                commitWithdrawalLocally(invitation)
            } catch is CancellationError {
                return
            } catch {
                Haptics.error()
                toasts?.show(
                    (error as? LocalizedError)?.errorDescription
                        ?? "That invitation couldn't be cancelled. Try again.",
                    symbol: "exclamationmark.circle.fill"
                )
            }
        }
    }

    private func commitWithdrawalLocally(_ invitation: FriendInvitation) {
        guard store.withdrawFriendInvitation(id: invitation.id) != nil else { return }
        Haptics.commit()
        toasts?.show("Invitation to @\(invitation.username) cancelled", symbol: "xmark.circle.fill")
    }

    private func commitResponseLocally(invitationID: UUID, accept: Bool, activityEventID: UUID) {
        let committed = withAnimation(GroveMotion.settle) {
            accept
                ? store.acceptFriendInvitation(id: invitationID, activityEventID: activityEventID)
                : store.declineFriendInvitation(id: invitationID)
        }
        guard committed != nil else { return }
        accept ? Haptics.celebrate() : Haptics.commit()
    }
}

// MARK: - Previews

/// Friends is mostly a page about *other people's* state, so an empty store
/// previews only the pitch. These seed the two versions worth designing
/// against: the day it is empty, and the day it is busy enough that the
/// requests, the spotlight and the circle are all competing for the fold.
@MainActor
private func friendsPreviewStore(populated: Bool) -> GroveStore {
    let store = GroveStore(persistenceEnabled: false)
    guard populated else { return store }

    let now = Date.now
    store.friends = [
        PlantFriend(
            id: "preview-mara",
            name: "Mara Ellison",
            username: "maragrows",
            initials: "ME",
            sharedPlantCount: 3,
            lastActiveAt: now.addingTimeInterval(-60 * 12)
        ),
        PlantFriend(
            id: "preview-tobi",
            name: "Tobi Adeyemi",
            username: "tobi.plants",
            initials: "TA",
            sharedPlantCount: 1,
            lastActiveAt: now.addingTimeInterval(-60 * 60 * 5)
        ),
        PlantFriend(
            id: "preview-june",
            name: "June Park",
            username: "junepark",
            initials: "JP",
            sharedPlantCount: 0,
            lastActiveAt: now.addingTimeInterval(-60 * 60 * 26)
        )
    ]
    store.friendInvitations = [
        FriendInvitation(
            id: UUID(),
            accountID: nil,
            name: "Devi Raman",
            username: "deviraman",
            initials: "DR",
            direction: .incoming,
            createdAt: now.addingTimeInterval(-60 * 60 * 3)
        ),
        FriendInvitation(
            id: UUID(),
            accountID: nil,
            name: "Sam Okafor",
            username: "samokafor",
            initials: "SO",
            direction: .outgoing,
            createdAt: now.addingTimeInterval(-60 * 60 * 48)
        )
    ]
    return store
}

@MainActor
private func friendsPreviewSyncEngine() -> SyncEngine {
    SyncEngine(queueStore: MutationQueueStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("FriendsPreviewQueue.json")
    ))
}

#Preview("Nobody yet") {
    AppDestinationsPreviewHost { FriendsView() }
        .environment(friendsPreviewStore(populated: false))
        .environment(friendsPreviewSyncEngine())
        .environment(ConnectivityMonitor())
        .environment(GrovePremiumStore())
        .environment(AskSession())
}

#Preview("A circle going") {
    AppDestinationsPreviewHost { FriendsView() }
        .environment(friendsPreviewStore(populated: true))
        .environment(friendsPreviewSyncEngine())
        .environment(ConnectivityMonitor())
        .environment(GrovePremiumStore())
        .environment(AskSession())
}


/// The handover's progress, drawn like a flight's: a track from the day it
/// started to the day you are home, with a check where today falls.
private struct FriendsHeroTrack: View {
    let handover: FriendsHandover

    var body: some View {
        let fraction = handover.elapsed()
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(GroveTheme.ink.opacity(0.18)).frame(height: 4)
                    Capsule()
                        .fill(GroveTheme.mapThriving)
                        .frame(width: max(4, proxy.size.width * CGFloat(fraction)), height: 4)
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(GroveTheme.mapThriving)
                        .frame(width: 30, height: 30)
                        .background(GroveTheme.ink, in: Circle())
                        .offset(x: min(max(0, proxy.size.width * CGFloat(fraction) - 15), max(0, proxy.size.width - 30)))
                }
                .frame(height: 30)
            }
            .frame(height: 30)
            .accessibilityHidden(true)

            HStack {
                GroveStatCell(label: handover.hasStarted ? "Since" : "Starts", value: FriendsDateText.shortDay(handover.startDate))
                GroveStatCell(label: "Home", value: FriendsDateText.shortDay(handover.endDate))
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}
