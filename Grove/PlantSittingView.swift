import SwiftUI

struct PlantSittingView: View {
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                boardTop

                if !incomingInvitations.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        FriendsSectionTitle(
                            title: "Waiting for your answer",
                            subtitle: "Nothing is shared until you accept"
                        )
                        ForEach(incomingInvitations) { assignment in
                            IncomingAssignmentCard(assignment: assignment)
                        }
                    }
                }

                if !acceptedIncoming.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        FriendsSectionTitle(
                            title: "You're plant sitting",
                            subtitle: "Only the plants and dates they handed over"
                        )
                        ForEach(acceptedIncoming) { assignment in
                            SitterAssignmentCard(assignment: assignment)
                        }
                        ForEach(openSittingTasks) { task in
                            SitterTaskCard(
                                task: task,
                                plant: store.sittingPlants.first { $0.id == task.plantID }
                            )
                        }
                    }
                }

                // The link comes first because it is the one that works for the
                // person most people actually ask: a neighbour who does not
                // have Grove and is not going to install it to water a fern.
                NavigationLink(value: AppRoute.sittingLink) {
                    GroveCTALabel(title: "Send a sitting link", systemImage: "link")
                }
                .buttonStyle(GrovePressStyle())
                .accessibilityIdentifier("sendSittingLink")

                // Pushes into the same composer rather than raising a second
                // one in a sheet. Both handovers ask the identical questions,
                // and keeping them on one page is what lets someone who
                // started down either route change their mind without losing
                // the dates and plants they already picked.
                NavigationLink(value: AppRoute.sittingFriend) {
                    Text("Or make one for a Grove friend")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(GroveTheme.accentStrong)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .background(GroveTheme.softAccent, in: Capsule())
                }
                .buttonStyle(GrovePressStyle())
                .accessibilityIdentifier("arrangePlantSitting")

                if !liveInvites.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        FriendsSectionTitle(title: "Links you've sent", subtitle: "Each one stops working on its end date")
                        ForEach(liveInvites) { invite in
                            SittingInviteCard(invite: invite)
                        }
                    }
                }

                if !recentEndedInvites.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        FriendsSectionTitle(
                            title: "Past handovers",
                            subtitle: "A receipt of what happened while you were away"
                        )
                        ForEach(recentEndedInvites) { invite in
                            SittingInviteReceiptCard(invite: invite)
                        }
                    }
                }

                // Heading and content are one group: loose in the page's section
                // stack, the title floated as far from its own list as it did
                // from the section above it.
                // Suppressed entirely when links are covering the grove: "Nobody's
                // sitting" printed under a live handover is simply false.
                if !outgoingAssignments.isEmpty || (liveInvites.isEmpty && acceptedIncoming.isEmpty) {
                    VStack(alignment: .leading, spacing: 14) {
                        FriendsSectionTitle(title: "Assignments", subtitle: "Access ends by itself when the trip does")
                        if outgoingAssignments.isEmpty {
                            // A bare heading over nothing reads as a screen that failed
                            // to load rather than one with nothing in it yet.
                            GroveEmptyState(
                                scene: .company,
                                title: "Nobody's sitting",
                                message: "Going away? Send a scoped link for the plants you choose. Links you make show above."
                            )
                            .frame(maxWidth: .infinity, minHeight: 220)
                            .groveCard()
                        } else {
                            // Live trips first: a finished assignment is a receipt,
                            // and it used to sit above the one actually happening
                            // simply because it was arranged more recently.
                            ForEach(sortedAssignments) { assignment in
                                AssignmentCard(assignment: assignment)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label("How access works", systemImage: "lock.shield.fill")
                        .font(.headline)
                    Text("Anyone with a link can open it until the trip ends. A Grove friend has to accept an invitation first. Either way, they see only the plants you choose.")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                .groveCard()
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, GroveTheme.pageTopPadding)
            .padding(.bottom, GroveTheme.pageBottomPadding)
        }
        .refreshable {
            await syncEngine.synchronize(store: store, isConnected: connectivity.isConnected)
        }
        .groveBackground()
        .friendsBoardPage("Plant sitting")
    }

    /// The handover happening now, read like a flight: who has the plants,
    /// the plan day by day, and when access stops. With nothing out, the page
    /// simply names itself.
    @ViewBuilder
    private var boardTop: some View {
        if let focus = FriendsHandover.focus(in: store) {
            let plan = focus.plan(in: store)
            SittingBoardHeader(handover: focus, plan: plan)
            SittingPlanCard(handover: focus, plan: plan)
            SittingAccessCard(handover: focus)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                FriendsPageTitle(title: "Plant sitting")
                Text("Choose which plants a friend can see and care for while you're away.")
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Live assignments first, each group soonest-starting first.
    private var sortedAssignments: [SittingAssignment] {
        outgoingAssignments.sorted { left, right in
            let leftEnded = left.hasEnded()
            let rightEnded = right.hasEnded()
            if leftEnded != rightEnded { return !leftEnded }
            return leftEnded ? left.endDate > right.endDate : left.startDate < right.startDate
        }
    }

    private var outgoingAssignments: [SittingAssignment] {
        store.assignments.filter { !$0.isIncoming }
    }

    private var incomingInvitations: [SittingAssignment] {
        store.pendingIncomingSittingInvitations()
    }

    private var acceptedIncoming: [SittingAssignment] {
        store.assignments
            .filter {
                $0.isIncoming && [.upcoming, .active].contains($0.currentStatus())
            }
            .sorted { $0.startDate < $1.startDate }
    }

    private var openSittingTasks: [CareTask] {
        store.sittingTasks
            .filter { !$0.isCompleted }
            .sorted { $0.dueDate < $1.dueDate }
    }

    /// Links still worth showing: the ones not pulled, whose trip has not
    /// passed. A finished link is history, and this page is about who is
    /// looking after the grove, not who once did.
    ///
    /// Deliberately `isOutstanding` rather than `isLive`: an attempt whose
    /// response never arrived has no URL but may still exist on the server, and
    /// this row is the only place the owner can pull it.
    private var liveInvites: [SittingInvite] {
        store.sittingInvites.filter { $0.isOutstanding() }
    }

    private var recentEndedInvites: [SittingInvite] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .distantPast
        return store.sittingInvites
            .filter { !$0.isOutstanding() && $0.endDate >= cutoff }
            .sorted { $0.endDate > $1.endDate }
    }
}

struct IncomingAssignmentCard: View {
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity

    let assignment: SittingAssignment
    @State private var isResponding = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AvatarView(
                    initials: initials,
                    seed: assignment.ownerName ?? assignment.id.uuidString,
                    size: 42
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(assignment.ownerName ?? "A Grove friend")
                        .font(.headline)
                    Text("Asked you to care for \(plantCount)")
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                Spacer(minLength: 0)
            }
            Label(dateRange, systemImage: "calendar")
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mutedInk)
            if let notes = assignment.ownerNotes, !notes.isEmpty {
                Text(notes)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.ink)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GroveTheme.softAccent, in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius))
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.warning)
            }
            HStack(spacing: 12) {
                Button(role: .destructive) { respond(accept: false) } label: {
                    GroveOutlineLabel(title: "Decline")
                }
                .buttonStyle(GrovePressStyle())

                Button { respond(accept: true) } label: {
                    GroveInkLabel(
                        title: isResponding ? "Saving…" : "Accept",
                        systemImage: "checkmark"
                    )
                }
                .buttonStyle(GrovePressStyle())
            }
            .disabled(isResponding || !connectivity.isConnected)
            if !connectivity.isConnected {
                Text("Reconnect to answer. Grove confirms the handover before changing access.")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.warning)
            }
        }
        .groveCard()
    }

    private func respond(accept: Bool) {
        guard !isResponding, connectivity.isConnected else { return }
        isResponding = true
        failure = nil
        let request = RespondToSittingAssignmentRequest(
            assignmentID: assignment.id,
            accept: accept,
            clientRequestID: UUID()
        )
        Task {
            defer { isResponding = false }
            do {
                let updated = try await syncEngine.respondToSittingAssignment(request)
                store.updateSittingAssignment(updated)
                if accept {
                    await syncEngine.synchronize(store: store, isConnected: connectivity.isConnected)
                }
                Haptics.commit()
            } catch is CancellationError {
                return
            } catch {
                Haptics.error()
                failure = (error as? LocalizedError)?.errorDescription
                    ?? "That invitation couldn't be answered. Try again."
            }
        }
    }

    private var initials: String {
        (assignment.ownerName ?? "Grove friend")
            .split(separator: " ").prefix(2).compactMap(\.first)
            .map(String.init).joined().uppercased()
    }

    private var plantCount: String {
        let count = assignment.plantIDs.count
        return "\(count) \(count == 1 ? "plant" : "plants")"
    }

    private var dateRange: String {
        "\(assignment.startDate.formatted(date: .abbreviated, time: .omitted)) – \(assignment.endDate.formatted(date: .abbreviated, time: .omitted))"
    }
}

private struct SitterAssignmentCard: View {
    let assignment: SittingAssignment

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(assignment.ownerName ?? "A Grove friend")
                        .font(.headline)
                    Text(dateRange)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                Spacer()
                Text(assignment.currentStatus().title)
                    .font(.caption.bold())
                    .foregroundStyle(GroveTheme.accentStrong)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(GroveTheme.softAccent, in: Capsule())
            }
            if assignment.currentStatus() == .upcoming {
                Label("Plant details become available when the handover starts", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            if let notes = assignment.ownerNotes, !notes.isEmpty {
                Divider()
                Text(notes)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.ink)
            }
            Label(
                assignment.canLogCare ? "You can complete assigned care" : "Read-only handover",
                systemImage: assignment.canLogCare ? "checkmark.shield.fill" : "eye.fill"
            )
            .font(.caption)
            .foregroundStyle(GroveTheme.mutedInk)
        }
        .groveCard()
    }

    private var dateRange: String {
        "\(assignment.startDate.formatted(date: .abbreviated, time: .omitted)) – \(assignment.endDate.formatted(date: .abbreviated, time: .omitted))"
    }
}

private struct SitterTaskCard: View {
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity

    let task: CareTask
    let plant: FriendPlant?
    @State private var isCompleting = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                GroveSymbolTile(symbol: task.kind.icon, tint: GroveTheme.accentStrong, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.kind.title).font(.headline)
                    Text(plant?.nickname ?? "Assigned plant")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                    Text(task.detail)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.warning)
            }
            Button(action: complete) {
                GroveInkLabel(
                    title: isCompleting ? "Saving…" : "Mark done",
                    systemImage: "checkmark.circle.fill"
                )
            }
            .buttonStyle(GrovePressStyle())
            .disabled(isCompleting || !connectivity.isConnected)
        }
        .groveCard()
    }

    private func complete() {
        guard !isCompleting, connectivity.isConnected else { return }
        isCompleting = true
        failure = nil
        let request = CareTaskMutationRequest(
            taskID: task.id,
            outcome: .completed,
            occurredAt: .now,
            rescheduledFor: nil,
            reason: nil,
            clientRequestID: UUID()
        )
        Task {
            defer { isCompleting = false }
            do {
                let completed = try await syncEngine.completeSittingTask(request)
                store.completeSittingTask(completed)
                Haptics.complete()
            } catch is CancellationError {
                return
            } catch {
                Haptics.error()
                failure = (error as? LocalizedError)?.errorDescription
                    ?? "That care couldn't be saved. Try again."
            }
        }
    }
}

/// One link handover. The device that minted it can send it again; every signed
/// in device can kill it without ever syncing the bearer URL.
private struct SittingInviteCard: View {
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    let invite: SittingInvite

    @State private var isConfirmingRevoke = false
    @State private var isRevoking = false
    @State private var revokeFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                GroveArtworkTile(asset: "GroveSittingLink", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(invite.sitterLabel).font(.headline)
                    Text(dateRangeText)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                Spacer()
                Text(invite.canLogCare ? "Can record care" : "Read only")
                    .font(.caption.bold())
                    .foregroundStyle(GroveTheme.accentStrong)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(GroveTheme.softAccent, in: Capsule())
            }
            if invite.isRevocationPending {
                Label(
                    "Revocation is saved on this phone and will finish when Grove reaches the server. Until then, the link may still open.",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(GroveTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
            } else if invite.hasBeenOpened {
                Label(
                    openedStatusText,
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(GroveTheme.accentStrong)
            } else if invite.isMinted {
                Label("Waiting for the sitter to open it", systemImage: "envelope.badge")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            if !invite.isRevocationPending, invite.shareURL == nil, invite.isMinted {
                Label(
                    "This link exists on the server, but its private URL belongs to another device and can't be recovered here. You can still revoke it.",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.caption)
                .foregroundStyle(GroveTheme.accentStrong)
                .fixedSize(horizontal: false, vertical: true)
            } else if !invite.isRevocationPending, invite.shareURL == nil {
                Label(
                    "This link never finished sending, so nobody can open it. Make a new one.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(GroveTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(spacing: 16) {
                Label(invite.plantIDs.count == 1 ? "1 plant" : "\(invite.plantIDs.count) plants", systemImage: "leaf.fill")
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                if (invite.completedCareCount ?? 0) > 0 {
                    Label("\(invite.completedCareCount ?? 0) done", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.accentStrong)
                }
                Spacer()
                if !invite.isRevocationPending, let url = invite.shareURL {
                    ShareLink(item: url) {
                        Label("Send again", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
                Button(role: .destructive) {
                    isConfirmingRevoke = true
                } label: {
                    Text(isRevoking ? "Revoking…" : "Revoke")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .font(.subheadline.weight(.semibold))
                .disabled(isRevoking || invite.isRevocationPending)
            }
            if let revokeFailure {
                Text(revokeFailure)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .groveCard()
        .confirmationDialog(
            "Stop this link working?",
            isPresented: $isConfirmingRevoke,
            titleVisibility: .visible
        ) {
            Button("Revoke the link", role: .destructive, action: revoke)
        } message: {
            Text("You'll see confirmation when access has stopped. If you're offline, this card stays pending until the server is reached.")
        }
    }

    private func revoke() {
        guard !isRevoking, !invite.isRevocationPending else { return }
        isRevoking = true
        revokeFailure = nil
        let request = RevokeSittingInviteRequest(inviteID: invite.id, clientRequestID: UUID())
        Task {
            if connectivity.isConnected {
                do {
                    try await syncEngine.revokeSittingInvite(request)
                    store.revokeSittingInvite(id: invite.id)
                    Haptics.commit()
                    isRevoking = false
                    return
                } catch is CancellationError {
                    isRevoking = false
                    return
                } catch {
                    // A transient online failure still gets a durable revoke
                    // request; permanent refusals stay visible for correction.
                    if let apiError = error as? APIError,
                       ![.offline, .timedOut].contains(apiError) {
                        switch apiError {
                        case .transport, .server, .invalidResponse, .invalidURL, .rateLimited:
                            break
                        default:
                            revokeFailure = apiError.errorDescription
                            Haptics.error()
                            isRevoking = false
                            return
                        }
                    }
                }
            }

            let queued = await syncEngine.enqueue(
                .revokeSittingInvite(request),
                isConnected: false
            )
            if queued {
                store.requestSittingInviteRevocation(id: invite.id)
                Haptics.commit()
            } else {
                revokeFailure = "Grove couldn't save the revocation request. Keep this screen open and try again."
                Haptics.error()
            }
            isRevoking = false
        }
    }

    private var dateRangeText: String {
        "\(formattedDate(invite.startDate)) – \(formattedDate(invite.endDate))"
    }

    private var openedStatusText: String {
        guard let date = invite.lastOpenedAt else { return "Opened by a sitter" }
        return "Opened by a sitter · " + openedText(date)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = invite.effectiveTimeZone
        return formatter.string(from: date)
    }

    private func openedText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

private struct SittingInviteReceiptCard: View {
    let invite: SittingInvite

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(invite.sitterLabel).font(.headline)
                Spacer()
                Text(invite.isRevoked ? "Revoked" : "Finished")
                    .font(.caption.bold())
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            Text(dateRangeText)
                .font(.caption)
                .foregroundStyle(GroveTheme.mutedInk)
            HStack(spacing: 16) {
                Label(invite.plantIDs.count == 1 ? "1 plant" : "\(invite.plantIDs.count) plants", systemImage: "leaf.fill")
                Label("\(invite.completedCareCount ?? 0) care tasks", systemImage: "checkmark.circle.fill")
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .foregroundStyle(GroveTheme.mutedInk)
            Text(invite.hasBeenOpened ? "The care sheet was opened." : "The care sheet was never opened.")
                .font(.caption)
                .foregroundStyle(invite.hasBeenOpened ? GroveTheme.accentStrong : GroveTheme.warning)
        }
        .groveCard()
    }

    private var dateRangeText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = invite.effectiveTimeZone
        return formatter.string(from: invite.startDate) + " – " + formatter.string(from: invite.endDate)
    }
}

private struct AssignmentCard: View {
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity

    let assignment: SittingAssignment
    @State private var isRevoking = false
    @State private var isConfirmingRevoke = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                AvatarView(initials: assignment.sitterInitials, seed: assignment.sitterName)
                VStack(alignment: .leading) {
                    Text(assignment.sitterName).font(.headline)
                    Text("\(assignment.startDate.formatted(date: .abbreviated, time: .omitted)) – \(assignment.endDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                Spacer()
                Text(status.title)
                    .font(.caption.bold())
                    .foregroundStyle(hasEnded ? GroveTheme.mutedInk : GroveTheme.accentStrong)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        hasEnded ? GroveTheme.separator.opacity(0.5) : GroveTheme.softAccent,
                        in: Capsule()
                    )
            }
            Divider()
            HStack {
                Label(plantCount, systemImage: "leaf.fill")
                Spacer()
                Label(taskCount, systemImage: "checklist")
            }
            .font(.subheadline)
            .foregroundStyle(GroveTheme.mutedInk)
            if !assignment.canCheckIn, !hasEnded {
                Label("Care only: they cannot complete check-ins", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            if status == .invited {
                Label(
                    "Waiting for \(assignment.sitterName) to accept in Grove.",
                    systemImage: "envelope.badge"
                )
                .font(.caption)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.warning)
            }
            if [.invited, .upcoming, .active].contains(status) {
                Button(role: .destructive) {
                    isConfirmingRevoke = true
                } label: {
                    Text(isRevoking ? "Withdrawing…" : "Withdraw handover")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .font(.subheadline.weight(.semibold))
                .disabled(isRevoking || !connectivity.isConnected)
            }
        }
        .groveCard()
        .confirmationDialog(
            "Withdraw this handover?",
            isPresented: $isConfirmingRevoke,
            titleVisibility: .visible
        ) {
            Button("Withdraw handover", role: .destructive, action: revoke)
        } message: {
            Text("Their account will immediately lose access to these plants and tasks.")
        }
    }

    private var status: SittingStatus { assignment.currentStatus() }
    private var hasEnded: Bool { assignment.hasEnded() }

    private var plantCount: String {
        let count = assignment.plantIDs.count
        return "\(count) \(count == 1 ? "plant" : "plants")"
    }

    private var taskCount: String {
        let count = assignment.totalTasks
        return "\(count) expected \(count == 1 ? "task" : "tasks")"
    }

    private func revoke() {
        guard !isRevoking, connectivity.isConnected else { return }
        isRevoking = true
        failure = nil
        Task {
            defer { isRevoking = false }
            do {
                let updated = try await syncEngine.revokeSittingAssignment(
                    RevokeSittingAssignmentRequest(
                        assignmentID: assignment.id,
                        clientRequestID: UUID()
                    )
                )
                store.updateSittingAssignment(updated)
                Haptics.commit()
            } catch is CancellationError {
                return
            } catch {
                Haptics.error()
                failure = (error as? LocalizedError)?.errorDescription
                    ?? "That handover couldn't be withdrawn. Try again."
            }
        }
    }
}
