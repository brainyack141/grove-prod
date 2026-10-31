import SwiftUI

/// Who the grove is being handed to.
///
/// The two handovers used to be two screens: this one for a link, a sheet next
/// door for a Grove friend. But the only entry points anyone actually uses —
/// the travel banner on Today, and a plant's own page — both push straight
/// here, so the friend option was unreachable from every route that mattered.
/// Someone whose sitter *is* on Grove got silently pushed down the anonymous
/// link path. The decision the owner is making is identical either way — these
/// plants, these dates, this much permission — so the composer is one page and
/// only the recipient and the delivery differ.
enum SittingRecipient: String, Hashable, CaseIterable {
    /// A link anyone can open. A neighbour with a spare key is not going to
    /// install an app to water a fern.
    case link
    /// A Grove friend receives an account-bound invitation and must accept it
    /// before any plant or task becomes visible.
    case friend
}

private enum SittingHandoverResult {
    case link(SittingInvite)
    case assignment(SittingAssignment)
}

/// Hands the grove to whoever the owner already asked, in person, to water it.
///
/// Every handover carries only the plants ticked here and stops working when
/// the trip ends. Choosing a Grove friend preselects who the link is for.
struct SittingLinkView: View {
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Plants the caller already knows should be in scope. The travel banner
    /// sends none and the whole grove is selected instead — someone who has
    /// left the country has left all of it behind.
    let preselectedPlantIDs: Set<UUID>
    /// Which handover the entry point already implies. The sitting overview's
    /// friend row arrives with `.friend`; everything else starts on the link
    /// and can switch in one tap.
    let initialRecipient: SittingRecipient

    @State private var recipient: SittingRecipient
    @State private var sitterLabel = ""
    @State private var selectedFriendID = ""
    @State private var startDate = Date.now
    @State private var endDate = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var selectedPlantIDs = Set<UUID>()
    @State private var canLogCare = true
    @State private var canCheckIn = false
    @State private var ownerNotes = ""
    @State private var isCreating = false
    @State private var failure: String?
    @State private var result: SittingHandoverResult?

    init(
        preselectedPlantIDs: Set<UUID> = [],
        recipient: SittingRecipient = .link,
        friendID: String? = nil
    ) {
        self.preselectedPlantIDs = preselectedPlantIDs
        self.initialRecipient = recipient
        _recipient = State(initialValue: recipient)
        _selectedFriendID = State(initialValue: friendID ?? "")
    }

    var body: some View {
        Group {
            if let result {
                switch result {
                case .link(let invite):
                    SittingLinkResultView(invite: invite) { dismiss() }
                case .assignment(let assignment):
                    SittingAssignmentResultView(assignment: assignment) { dismiss() }
                }
            } else {
                composer
            }
        }
        .groveEditorialPage(result == nil ? pageTitle : resultTitle)
        .onAppear {
            if selectedPlantIDs.isEmpty {
                selectedPlantIDs = preselectedPlantIDs.isEmpty
                    ? Set(store.plants.map(\.id))
                    : preselectedPlantIDs
            }
            if selectedFriendID.isEmpty { selectedFriendID = store.friends.first?.id ?? "" }
        }
        .onChange(of: assignmentDraftKey) { _, _ in
            guard !isCreating else { return }
            failure = nil
        }
    }

    private var pageTitle: String {
        recipient == .link ? "Sitting link" : "Hand it over"
    }

    private var resultTitle: String {
        guard let result else { return pageTitle }
        return switch result {
        case .assignment: "Invitation sent"
        case .link: "Ready to send"
        }
    }

    // MARK: - Composer

    private var composer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                recipientSection
                whoSection
                datesSection
                if !store.plants.isEmpty { plantsSection }
                handoverSection
                permissionSection
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .groveBackground()
        .safeAreaInset(edge: .bottom) { actionBar }
    }

    // MARK: - Who it goes to

    /// The choice that used to be made for the user by whichever button they
    /// happened to tap two screens ago. Two tiles rather than a segmented
    /// control because the words under each title are the actual decision —
    /// most people do not know which one their sitter needs.
    private var recipientSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who's looking after them").font(.headline)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) { recipientTiles }
                } else {
                    HStack(spacing: 12) { recipientTiles }
                }
            }
        }
    }

    @ViewBuilder
    private var recipientTiles: some View {
        recipientTile(
            .link,
            title: "Send a link",
            caption: "They don't need the app",
            symbol: "link"
        )
        recipientTile(
            .friend,
            title: "A Grove friend",
            caption: "They accept in Grove",
            symbol: "person.2.fill"
        )
    }

    private func recipientTile(
        _ value: SittingRecipient,
        title: String,
        caption: String,
        symbol: String
    ) -> some View {
        let isSelected = recipient == value
        return Button {
            guard recipient != value else { return }
            Haptics.selection()
            withAnimation(GroveMotion.snap) {
                recipient = value
                failure = nil
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.headline)
                    .foregroundStyle(isSelected ? GroveTheme.accentStrong : GroveTheme.subtleInk)
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.ink)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                isSelected ? GroveTheme.softAccent : GroveTheme.surface,
                in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                    .stroke(isSelected ? GroveTheme.accent : GroveTheme.separator, lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(GroveTilePressStyle())
        .accessibilityLabel("\(title). \(caption)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(value == .link ? "sittingRecipientLink" : "sittingRecipientFriend")
    }

    @ViewBuilder
    private var whoSection: some View {
        switch recipient {
        case .link:
            VStack(alignment: .leading, spacing: 10) {
                Text("Name the link").font(.headline)
                TextField("Their name", text: $sitterLabel)
                    .textFieldStyle(.plain)
                    .textContentType(.name)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                            .stroke(GroveTheme.separator, lineWidth: 1)
                    }
                    .submitLabel(.done)
                    .accessibilityIdentifier("sitterLabel")
                Text("Just so you can tell your links apart. They never see it.")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
        case .friend:
            VStack(alignment: .leading, spacing: 12) {
                Text("Pick a friend").font(.headline)
                if store.friends.isEmpty {
                    GroveEmptyState(
                        scene: .company,
                        title: "Add a friend first",
                        message: "Add a friend, or choose Send a link and name the sitter yourself.",
                        artSize: 108
                    )
                    .frame(maxWidth: .infinity)
                    .groveCard()
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.friends.enumerated()), id: \.element.id) { index, friend in
                            friendRow(friend)
                            if index < store.friends.count - 1 {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
                    .groveEdgeLight()
                    .groveShadow(.resting)
                    Text("Tied to their Grove account. They must accept before the selected plants and tasks appear.")
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func friendRow(_ friend: PlantFriend) -> some View {
        let isSelected = friend.id == selectedFriendID
        return Button {
            guard !isSelected else { return }
            Haptics.selection()
            withAnimation(GroveMotion.pop) { selectedFriendID = friend.id }
        } label: {
            HStack(spacing: 12) {
                AvatarView(initials: friend.initials, seed: friend.id, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(friend.name).font(.subheadline.weight(.semibold))
                    Text("@\(friend.username)").font(.caption).foregroundStyle(GroveTheme.mutedInk)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? GroveTheme.accent : GroveTheme.subtleInk)
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(isSelected ? 1.1 : 1)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.985, haptics: false))
        .foregroundStyle(GroveTheme.ink)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Dates

    /// Neither picker carries a range. A bounded compact `DatePicker` renders
    /// its date in a different format from an unbounded one, so "From" and
    /// "Until" sat side by side reading `1 Aug 2026` and `08/08/2026` — two
    /// controls that do the same job, disagreeing about what a date looks
    /// like. The ordering is kept honest by clamping in `onChange` instead,
    /// and the night count underneath says out loud what was picked.
    private var datesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("While you're away").font(.headline)
            VStack(spacing: 0) {
                DatePicker("From", selection: $startDate, displayedComponents: .date)
                    .onChange(of: startDate) { _, newStart in
                        if endDate <= newStart {
                            endDate = Calendar.current.date(byAdding: .day, value: 1, to: newStart) ?? newStart
                        }
                    }
                    .padding(.vertical, 10)
                Divider()
                DatePicker("Until", selection: $endDate, displayedComponents: .date)
                    .onChange(of: endDate) { _, newEnd in
                        if newEnd <= startDate {
                            startDate = Calendar.current.date(byAdding: .day, value: -1, to: newEnd) ?? newEnd
                        }
                    }
                    .padding(.vertical, 10)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            .groveEdgeLight()
            .groveShadow(.resting)
            Text(nightCountCaption)
                .font(.caption)
                .foregroundStyle(GroveTheme.mutedInk)
        }
    }

    private var nightCount: Int {
        max(1, Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 1)
    }

    private var nightCountCaption: String {
        "\(nightCount) \(nightCount == 1 ? "night" : "nights") away."
        + " The link dies on its own when you get back."
    }

    // MARK: - Plants

    private var plantsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Plants they'll see").font(.headline)
                Spacer()
                Button(isEverythingSelected ? "Clear all" : "Select all") {
                    let clearing = isEverythingSelected
                    Haptics.toggle(on: !clearing)
                    withAnimation(GroveMotion.snap) {
                        selectedPlantIDs = clearing ? [] : Set(store.plants.map(\.id))
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GroveTheme.accentStrong)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(store.plants.enumerated()), id: \.element.id) { index, plant in
                    plantRow(plant)
                    if index < store.plants.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            .groveEdgeLight()
            .groveShadow(.resting)
            Text("Nothing else in your grove appears on the page.")
                .font(.caption)
                .foregroundStyle(GroveTheme.mutedInk)
        }
    }

    /// The plant's own photo, not a leaf glyph. Three different plants used to
    /// arrive as three identical symbols, which made the one list on this page
    /// where the user has to recognise their own plants the one place they
    /// could not.
    private func plantRow(_ plant: Plant) -> some View {
        let isSelected = selectedPlantIDs.contains(plant.id)
        return Button {
            let adding = !isSelected
            Haptics.toggle(on: adding)
            withAnimation(GroveMotion.pop) {
                if adding { selectedPlantIDs.insert(plant.id) }
                else { selectedPlantIDs.remove(plant.id) }
            }
        } label: {
            HStack(spacing: 12) {
                PlantThumbnail(plant: plant, height: 40, maxDimension: 160)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(plant.nickname).font(.subheadline.weight(.semibold))
                    Text(plant.location).font(.caption).foregroundStyle(GroveTheme.mutedInk)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? GroveTheme.accent : GroveTheme.subtleInk)
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(isSelected ? 1.1 : 1)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.985, haptics: false))
        .foregroundStyle(GroveTheme.ink)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var isEverythingSelected: Bool {
        !store.plants.isEmpty && selectedPlantIDs.count == store.plants.count
    }

    // MARK: - Permission

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "They can tick tasks off",
                isOn: $canLogCare
            )
            .font(.subheadline.weight(.semibold))
            .tint(GroveTheme.accent)
            Text(permissionCaption)
                .font(.caption)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            if recipient == .friend {
                Toggle(
                    "They can do photo check-ins",
                    isOn: $canCheckIn
                )
                .font(.subheadline.weight(.semibold))
                .tint(GroveTheme.accent)
                .disabled(!canLogCare)
                Text(canCheckInCaption)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: canLogCare) { _, on in
            if !on { canCheckIn = false }
        }
        .groveCard()
    }

    private var handoverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plant-care handover").font(.headline)
            TextField(
                "For example: use the rainwater by the sink; the fern's pot stays heavy for days",
                text: $ownerNotes,
                axis: .vertical
            )
            .lineLimit(3...7)
            .onChange(of: ownerNotes) { _, value in
                if value.count > 4_000 {
                    ownerNotes = String(value.prefix(4_000))
                }
            }
            .padding(14)
            .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                    .stroke(GroveTheme.separator, lineWidth: 1)
            }
            Text("\(ownerNotes.count)/4,000 · Shown on the sitter's care sheet. Never put door codes or other access details here.")
                .font(.caption)
                .foregroundStyle(GroveTheme.mutedInk)
        }
    }

    private var permissionCaption: String {
        switch (recipient, canLogCare) {
        case (.friend, true):
            "After they accept, care they complete is tied to their Grove account and appears in your timeline."
        case (.link, true):
            "They can mark what they've done. Anyone with the link can open it until the trip ends, so their care is recorded from the link, not from a named account."
        case (_, false):
            "The handover is read-only. They can see what's due, but only you can mark it done."
        }
    }

    private var canCheckInCaption: String {
        canCheckIn
            ? "They take the check-in photo and answer the questions. The reading is added to your plant's history."
            : "Check-ins stay with you. They only see that one is due."
    }

    // MARK: - The committing action

    /// Docked, like every other committing action in Grove. It used to be a
    /// row in the middle of a form, below the fold, indistinguishable from
    /// "Select all" — and when it was unavailable it went grey without saying
    /// why. The line above the pill is what is about to happen; when the form
    /// isn't ready it is replaced by the one thing still missing.
    private var actionBar: some View {
        VStack(spacing: 10) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroveTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(blockingReason ?? commitSummary)
                .font(.caption.weight(.semibold))
                .foregroundStyle(blockingReason == nil ? GroveTheme.mutedInk : GroveTheme.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
            Button(action: commit) {
                GroveCTALabel(
                    title: isCreating
                        ? (recipient == .friend ? "Sending invitation…" : "Making the link…")
                        : commitTitle,
                    systemImage: recipient == .friend ? "person.crop.circle.badge.checkmark" : "link"
                )
            }
            .buttonStyle(GrovePressStyle())
            .disabled(!canCommit)
            // Dims the button, not the bar: applied after `groveActionBar` the
            // opacity would fade the gradient the bar uses to dissolve into the
            // canvas, and the page would appear to lift off its own background.
            .opacity(canCommit ? 1 : 0.4)
            .animation(GroveMotion.snap, value: canCommit)
            .accessibilityIdentifier("makeSittingLink")
        }
        .animation(GroveMotion.snap, value: blockingReason)
        .groveActionBar()
    }

    private var commitTitle: String {
        guard recipient == .friend else { return "Make the link" }
        let first = store.friends.first { $0.id == selectedFriendID }?.name
            .split(separator: " ").first.map(String.init)
        return first.map { "Invite \($0)" } ?? "Send invitation"
    }

    private var commitSummary: String {
        let count = selectedPlantIDs.count
        let range = "\(startDate.formatted(.dateTime.day().month(.abbreviated)))–\(endDate.formatted(.dateTime.day().month(.abbreviated)))"
        return "\(count) \(count == 1 ? "plant" : "plants") · \(range)"
    }

    /// Says the one thing standing in the way, rather than leaving a grey pill
    /// to be interrogated by trial and error.
    private var blockingReason: String? {
        if syncEngine.state == .localOnly { return "Sign in to make a secure sitting link" }
        if !connectivity.isConnected { return "Reconnect to make the link" }
        if store.plants.isEmpty { return "Add a plant to your grove first" }
        if selectedPlantIDs.isEmpty { return "Pick at least one plant" }
        if selectedPlantIDs.count > 100 { return "Choose no more than 100 plants" }
        if nightCount > 180 { return "Choose a trip of six months or less" }
        if recipient == .friend && store.friends.isEmpty { return "Add a Grove friend, or send a link instead" }
        if recipient == .friend && selectedFriendID.isEmpty { return "Pick who's sitting" }
        return nil
    }

    private var canCommit: Bool { !isCreating && blockingReason == nil }

    private var assignmentDraftKey: String {
        [
            recipient.rawValue,
            selectedFriendID,
            startDate.ISO8601Format(),
            endDate.ISO8601Format(),
            selectedPlantIDs.map(\.uuidString).sorted().joined(separator: ","),
            String(canLogCare),
            String(canCheckIn),
            ownerNotes
        ].joined(separator: "|")
    }

    // MARK: - Creating

    private func commit() {
        guard canCommit else { return }
        switch recipient {
        case .link: createLink()
        case .friend: createAssignment()
        }
    }

    private func createLink() {
        guard !isCreating else { return }
        isCreating = true
        failure = nil

        // Recorded locally first, so a link that was minted but whose response
        // never arrived is still a row the owner can see and revoke.
        let invite = store.createSittingInvite(
            sitterLabel: sitterLabel,
            startDate: startDate,
            endDate: endDate,
            plantIDs: selectedPlantIDs,
            canLogCare: canLogCare,
            ownerNotes: ownerNotes
        )

        Task {
            do {
                let link = try await syncEngine.createSittingInvite(
                    CreateSittingInviteRequest(
                        inviteID: invite.id,
                        label: invite.sitterLabel,
                        // The invite's own dates: the store normalised them to
                        // whole days, and the server decides when the link stops
                        // resolving, so the two ends must agree on the instant.
                        startDate: invite.startDate,
                        endDate: invite.endDate,
                        plantIDs: Array(selectedPlantIDs),
                        canLogCare: canLogCare,
                        ownerNotes: invite.ownerNotes,
                        timeZoneIdentifier: invite.timeZoneIdentifier,
                        recipientAccountID: nil,
                        clientRequestID: invite.id
                    )
                )
                store.attachShareURL(inviteID: invite.id, url: link.url)
                Haptics.commit()
                withAnimation(GroveMotion.snap) {
                    if let created = store.sittingInvites.first(where: { $0.id == invite.id }) {
                        result = .link(created)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // The local row is left in place on purpose: it is the only
                // record that this was attempted, and it is revocable.
                Haptics.error()
                failure = (error as? LocalizedError)?.errorDescription
                    ?? "That link couldn't be made. Check your connection and try again."
            }
            isCreating = false
        }
    }

    private func createAssignment() {
        guard !isCreating else { return }
        guard let friend = store.friends.first(where: { $0.id == selectedFriendID }) else {
            Haptics.error()
            failure = "That friend isn't in your list any more. Pick another."
            return
        }
        isCreating = true
        failure = nil
        let timeZone = store.profile.location?.timeZoneIdentifier
            .flatMap(TimeZone.init(identifier:)) ?? .current
        let window = SittingWindow.normalized(
            start: startDate,
            end: endDate,
            timeZone: timeZone
        )
        let requestID = UUID()
        let request = CreateSittingRequest(
            sitterAccountID: friend.id,
            startDate: window.start,
            endDate: window.end,
            plantIDs: selectedPlantIDs.sorted { $0.uuidString < $1.uuidString },
            canCheckIn: canCheckIn,
            canLogCare: canLogCare,
            ownerNotes: ownerNotes.trimmingCharacters(in: .whitespacesAndNewlines),
            timeZoneIdentifier: timeZone.identifier,
            clientRequestID: requestID,
            activityEventID: requestID
        )

        Task {
            do {
                let assignment = try await syncEngine.createSittingAssignment(request)
                store.recordSittingAssignment(assignment)
                Haptics.commit()
                withAnimation(GroveMotion.snap) {
                    result = .assignment(assignment)
                }
            } catch is CancellationError {
                return
            } catch {
                Haptics.error()
                failure = (error as? LocalizedError)?.errorDescription
                    ?? "That invitation couldn't be sent. Check your connection and try again."
            }
            isCreating = false
        }
    }
}

private struct SittingAssignmentResultView: View {
    let assignment: SittingAssignment
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                HStack(alignment: .top, spacing: 16) {
                    AvatarView(initials: assignment.sitterInitials, seed: assignment.sitterName, size: 48)
                    VStack(alignment: .leading, spacing: 6) {
                        GroveDisplayHeading(text: "Waiting for \(assignment.sitterName)", style: .section)
                        Text("They'll see this invitation in Grove. No plant access starts until they accept it.")
                            .font(.subheadline)
                            .foregroundStyle(GroveTheme.mutedInk)
                    }
                }
                .groveCard()

                VStack(alignment: .leading, spacing: 12) {
                    Label("Account-bound", systemImage: "person.badge.shield.checkmark.fill")
                        .font(.headline)
                    Text("Only \(assignment.sitterName)'s signed-in account can accept. They receive only the \(assignment.plantIDs.count) selected \(assignment.plantIDs.count == 1 ? "plant" : "plants"), for the dates you chose.")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                .groveCard()

                Button(action: onDone) {
                    GroveCTALabel(title: "Done", systemImage: "checkmark")
                }
                .buttonStyle(GrovePressStyle())
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .groveBackground()
    }
}

/// The link, once it exists — the only screen in Grove whose entire job is to
/// get something out of the app and into a text message.
struct SittingLinkResultView: View {
    let invite: SittingInvite
    let onDone: () -> Void

    @State private var didCopy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                HStack(alignment: .top, spacing: 16) {
                    GroveArtworkTile(asset: "GroveSittingLink", size: 54)
                    VStack(alignment: .leading, spacing: 6) {
                        GroveDisplayHeading(text: "Send it to them", style: .section)
                        Text("Anyone with this link can see the \(invite.plantIDs.count) \(invite.plantIDs.count == 1 ? "plant" : "plants") you picked and what they need. Nothing else.")
                            .font(.subheadline)
                            .foregroundStyle(GroveTheme.mutedInk)
                    }
                    Spacer(minLength: 0)
                }
                .groveCard()

                if let url = invite.shareURL {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(url.absoluteString)
                            .font(.footnote.monospaced())
                            .foregroundStyle(GroveTheme.mutedInk)
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        ShareLink(item: url, message: Text(shareMessage)) {
                            GroveCTALabel(title: "Share the link", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(GrovePressStyle())
                        .accessibilityIdentifier("shareSittingLink")

                        Button {
                            UIPasteboard.general.setItems(
                                [["public.utf8-plain-text": url.absoluteString]],
                                options: [
                                    .localOnly: true,
                                    .expirationDate: Date.now.addingTimeInterval(10 * 60)
                                ]
                            )
                            Haptics.selection()
                            didCopy = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                didCopy = false
                            }
                        } label: {
                            Label(
                                didCopy ? "Copied" : "Copy link",
                                systemImage: didCopy ? "checkmark.circle" : "doc.on.doc"
                            )
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(GroveTheme.accentStrong)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                            .background(GroveTheme.softAccent, in: Capsule())
                        }
                        .buttonStyle(GrovePressStyle())
                    }
                    .groveCard()
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label("What they'll see", systemImage: "eye.fill")
                        .font(.headline)
                    Text("A web page with each plant's name, where it lives, and what it needs while you're gone. No photos, no other plants, no way into your account. It stops opening on \(endDateText).")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                .groveCard()

                Label(
                    "This counts as sitting cover once someone opens the link. Until then, your travel reminder stays on.",
                    systemImage: "envelope.open.fill"
                )
                .font(.footnote)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

                Button(action: onDone) {
                    Text("Done")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(GroveTheme.mutedInk)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(GrovePressStyle())
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, GroveTheme.pageTopPadding)
            .padding(.bottom, GroveTheme.pageBottomPadding)
        }
        .groveBackground()
    }

    private var shareMessage: String {
        "Thanks for looking after my plants. Everything they need is here."
    }

    private var endDateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = invite.effectiveTimeZone
        return formatter.string(from: invite.endDate)
    }
}

#Preview {
    NavigationStack {
        SittingLinkView()
    }
    .environment(GroveStore())
    .environment(SyncEngine())
    .environment(ConnectivityMonitor())
}
