import SwiftUI

struct FriendGroveView: View {
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    @Environment(\.dismiss) private var dismiss
    let friendID: String
    @State private var isConfirmingRemoval = false
    @State private var isConfirmingBlock = false
    @State private var isWorking = false
    @State private var reportingFriend: PlantFriend?
    @State private var reportCompleted = false

    private var friend: PlantFriend? {
        store.friends.first { $0.id == friendID }
    }

    var body: some View {
        ScrollView {
            if let friend {
                LazyVStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                    FriendHeaderCard(friend: friend)
                    TrustedPersonAccessCard()

                    NavigationLink {
                        SittingLinkView(recipient: .friend, friendID: friend.id)
                    } label: {
                        GroveCTALabel(
                            title: "Ask \(firstName(of: friend)) to sit",
                            systemImage: "person.badge.clock"
                        )
                    }
                    .buttonStyle(GrovePressStyle())
                }
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.top, GroveTheme.pageTopPadding)
                .padding(.bottom, GroveTheme.pageBottomPadding)
            } else {
                GroveEmptyState(
                    scene: .vanished,
                    title: "They're not here",
                    message: "This connection has ended."
                )
                .frame(minHeight: 260)
            }
        }
        .groveBackground()
        .groveEditorialPage(friend?.name ?? "Friend")
        .toolbar {
            if let friend {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            reportingFriend = friend
                        } label: {
                            Label("Report account", systemImage: "exclamationmark.bubble")
                        }

                        Divider()

                        Button {
                            isConfirmingRemoval = true
                        } label: {
                            Label("Remove connection", systemImage: "person.crop.circle.badge.minus")
                        }

                        Button(role: .destructive) {
                            isConfirmingBlock = true
                        } label: {
                            Label("Block account", systemImage: "hand.raised")
                        }
                    } label: {
                        GroveHeaderIcon(symbol: "ellipsis")
                    }
                    .disabled(isWorking)
                    .accessibilityLabel("Connection options")
                }
            }
        }
        .sheet(item: $reportingFriend, onDismiss: finishReportIfNeeded) { friend in
            NavigationStack {
                ReportFriendView(friend: friend) {
                    reportCompleted = true
                }
            }
        }
        .confirmationDialog(
            "Remove this connection?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove connection", role: .destructive) {
                removeFriend()
            }
        } message: {
            Text("They won't be told. Either of you can send a new invitation later. Sitting links stay until you revoke them.")
        }
        .confirmationDialog(
            "Block this account?",
            isPresented: $isConfirmingBlock,
            titleVisibility: .visible
        ) {
            Button("Block account", role: .destructive) {
                blockFriend()
            }
        } message: {
            Text("The connection ends, they cannot contact you through Grove again, and active sitting access created for them is revoked.")
        }
    }

    private func firstName(of friend: PlantFriend) -> String {
        friend.name.split(separator: " ").first.map(String.init) ?? friend.name
    }

    private func finishReportIfNeeded() {
        guard reportCompleted else { return }
        reportCompleted = false
        dismiss()
    }

    private func removeFriend() {
        guard !isWorking else { return }
        guard connectivity.isConnected else {
            Haptics.error()
            toasts?.show("You're offline. Reconnect to remove this person.", symbol: "exclamationmark.circle.fill")
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await syncEngine.removeFriend(
                    RemoveFriendRequest(friendAccountID: friendID, clientRequestID: UUID())
                )
                guard let removed = store.removeFriend(id: friendID) else { return }
                Haptics.commit()
                toasts?.show("\(removed.name) removed", symbol: "person.crop.circle.badge.minus")
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                showFailure(error, fallback: "That connection couldn't be removed. Try again.")
            }
        }
    }

    private func blockFriend() {
        guard !isWorking else { return }
        guard connectivity.isConnected else {
            Haptics.error()
            toasts?.show("You're offline. Reconnect to block this account.", symbol: "exclamationmark.circle.fill")
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await syncEngine.blockFriend(
                    BlockFriendRequest(friendAccountID: friendID, clientRequestID: UUID())
                )
                let blocked = store.removeFriend(id: friendID)
                Haptics.commit()
                toasts?.show("\(blocked?.name ?? "Account") blocked", symbol: "hand.raised.fill")
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                showFailure(error, fallback: "That account couldn't be blocked. Try again.")
            }
        }
    }

    private func showFailure(_ error: Error, fallback: String) {
        Haptics.error()
        toasts?.show(
            (error as? LocalizedError)?.errorDescription ?? fallback,
            symbol: "exclamationmark.circle.fill"
        )
    }
}

private struct TrustedPersonAccessCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Nothing is shared by connecting", systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(GroveTheme.ink)
            Text("When you need help, ask them to sit for specific plants and dates. It ends automatically and you can stop it at any time.")
                .font(.callout)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            Text("A sitting link is a bearer link. Anyone it is forwarded to can use it until it expires or you revoke it.")
                .font(.caption)
                .foregroundStyle(GroveTheme.subtleInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .groveCard()
    }
}

private struct FriendHeaderCard: View {
    let friend: PlantFriend

    /// "today", "yesterday", "Mon", "5 Oct": the recency the Friends list
    /// shows under "Active", read as part of a sentence.
    private var activeLine: String {
        let recency = FriendsDateText.recency(friend.lastActiveAt)
        return recency == "Today" || recency == "Yesterday" ? recency.lowercased() : recency
    }

    var body: some View {
        HStack(spacing: 14) {
            AvatarView(initials: friend.initials, seed: friend.id, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(friend.name).font(.headline)
                Text("@\(friend.username)").font(.subheadline).foregroundStyle(GroveTheme.mutedInk)
                // The same label and wording as their row in Friends.
                Text("Active \(activeLine)")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            Spacer(minLength: 0)
            GrovePill(text: "Connected", systemImage: "checkmark", style: .outline)
                // One line always: a status pill broken over two lines reads
                // as two words. The name column wraps instead.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .groveCard()
    }
}

private struct ReportFriendView: View {
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    @Environment(\.dismiss) private var dismiss
    let friend: PlantFriend
    let onCompleted: () -> Void
    @State private var reason = FriendReportReason.harassment
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Why are you reporting this account?") {
                Picker("Reason", selection: $reason) {
                    ForEach(FriendReportReason.allCases) { reason in
                        Text(reason.title).tag(reason)
                    }
                }
                .pickerStyle(.inline)
            }

            Section {
                TextEditor(text: $details)
                    .frame(minHeight: 120)
                    .onChange(of: details) { _, value in
                        if value.count > 1_000 { details = String(value.prefix(1_000)) }
                    }
                Text("\(details.count)/1,000")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } header: {
                Text("Details (optional)")
            } footer: {
                Text("Submitting also blocks @\(friend.username), ends the connection, and revokes active sitting access created for them. We keep the report for safety review.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .foregroundStyle(GroveTheme.danger)
                }
            }
        }
        .formStyle(.grouped)
        .groveGroupedContent()
        .navigationTitle("Report @\(friend.username)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isSubmitting)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSubmitting ? "Submitting…" : "Submit") {
                    submit()
                }
                .disabled(isSubmitting)
            }
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        guard connectivity.isConnected else {
            errorMessage = "You're offline. Reconnect to submit this report."
            return
        }
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await syncEngine.reportFriend(
                    ReportFriendRequest(
                        friendAccountID: friend.id,
                        reason: reason,
                        details: details.trimmingCharacters(in: .whitespacesAndNewlines),
                        clientRequestID: UUID()
                    )
                )
                store.removeFriend(id: friend.id)
                Haptics.commit()
                toasts?.show("Report submitted and account blocked", symbol: "checkmark.shield.fill")
                onCompleted()
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                Haptics.error()
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "That report couldn't be submitted. Try again."
            }
        }
    }
}

#Preview {
    AppDestinationsPreviewHost {
        FriendGroveView(friendID: "demo-maya")
    }
    .environment(GroveStore())
}
