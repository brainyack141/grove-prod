import AuthenticationServices
import StoreKit
import SwiftUI
import UIKit

/// Settings and privacy.
///
/// A native-context screen per the design system: a grouped `Form` with native
/// controls, Grove's ink page title, and the cream canvas behind it. Every row
/// here either reports a fact the app can actually observe or performs an
/// action — a settings screen that states aspirations it cannot back up is the
/// fastest way to lose a user's trust in everything else the app tells them.
struct SettingsView: View {
    @Environment(GroveStore.self) private var store
    @Environment(SessionService.self) private var session
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(NotificationService.self) private var notifications
    @Environment(AskSession.self) private var ask
    @Environment(ScanSession.self) private var scanSession
    @Environment(GrovePremiumStore.self) private var premium
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(GroveDefaults.careReminders) private var careReminders = true
    @AppStorage(GroveDefaults.sittingUpdates) private var sittingUpdates = true
    @AppStorage(GroveDefaults.reminderHour) private var reminderHour = NotificationService.reminderHour
    /// The key is `Haptics.preferenceKey`, spelled out because `@AppStorage`
    /// needs a literal. The engine reads the same key, so the switch and the
    /// vocabulary cannot disagree.
    @AppStorage("grove.haptics.enabled") private var hapticsEnabled = true

    @State private var showingDeleteConfirmation = false
    @State private var showingSignOutConfirmation = false
    @State private var showingDeleteReauthentication = false
    /// Set by the reauthentication sheet on success, so the deletion the user
    /// already confirmed runs once the sheet has gone.
    @State private var resumesDeletion = false
    @State private var isDeletingAccount = false
    @State private var deletionError: String?
    @State private var signOutError: String?
    @State private var showingPaywall = false
    @State private var showingManageSubscription = false
    @State private var isRestoring = false
    @State private var restoreMessage: String?
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportedFile: ExportedGroveFile?
    @State private var showsBarTitle = false

    /// Captions in these sections are follow-ups to the row above them, so they
    /// start where that row's text starts, not under its glyph.
    @ScaledMetric(relativeTo: .body) private var iconColumn = SettingsRowMetrics.iconColumn
    private var textColumnInset: CGFloat { iconColumn + SettingsRowMetrics.gap }

    var body: some View {
        Form {
            #if targetEnvironment(simulator)
            if session.currentSession?.isSimulatorTroubleshooting == true {
                Section("Troubleshooting") {
                    Text("Simulator only · Local sample data")
                    Text("Scans and Ari use test responses. Account sync and sharing require a real sign-in.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            #endif
            profileSection
            subscriptionSection
            groveSection
            deviceSection
            privacyAndDataSection
            supportSection
            accountSection
        }
        .sheet(isPresented: $showingDeleteReauthentication, onDismiss: resumeDeletionIfReauthenticated) {
            // The user already confirmed the deletion; signing in again was
            // only the server's condition for carrying it out. Making them
            // find Delete and confirm a second time read as if it had failed.
            DeleteAccountReauthenticationSheet { resumesDeletion = true }
        }
        .sheet(item: $exportedFile) { file in
            GroveShareSheet(items: [file.url])
        }
        .formStyle(.grouped)
        .groveGroupedContent()
        // The page names itself in the content, at the display voice's title
        // step, and the bar only takes the name over once that heading has
        // scrolled away. Same face and same ink as `grovePageTitle`, so the
        // hand-off reads as one title moving rather than two.
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                GroveHeaderTitle(text: "Settings")
                    .opacity(showsBarTitle ? 1 : 0)
                    .accessibilityHidden(!showsBarTitle)
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 40
        } action: { _, scrolledPastTitle in
            guard scrolledPastTitle != showsBarTitle else { return }
            withAnimation(.easeInOut(duration: 0.18)) { showsBarTitle = scrolledPastTitle }
        }
        // Settings would otherwise be the one silent surface left after the
        // app learned to tap back: a switch that changes when reminders fire
        // should land like every other switch in Grove.
        .onChange(of: careReminders) { _, enabled in
            Haptics.toggle(on: enabled)
            Task { await synchronizeNotifications() }
        }
        .onChange(of: sittingUpdates) { _, enabled in
            Haptics.toggle(on: enabled)
            Task { await synchronizeNotifications() }
        }
        .onChange(of: reminderHour) { _, _ in
            Haptics.selection()
            Task { await synchronizeNotifications() }
        }
        // `@AppStorage` writes the defaults key directly, so the engine's
        // cached copy has to be told the value moved underneath it.
        .onChange(of: hapticsEnabled) { _, enabled in
            Haptics.refreshPreference()
            // Confirm the switch with the very thing it controls — turning it
            // on should be felt, turning it off should be silent.
            if enabled { Haptics.toggle(on: true) }
        }
        // "Open iPhone Settings" leaves the app to change the very state this
        // section reports; nothing else re-reads it on the way back, so the
        // permission row and the toggles kept reporting the old answer.
        // `synchronize` re-reads the permission first, so this both corrects
        // the row and schedules the reminders that permission just unlocked.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await synchronizeNotifications() }
        }
        .task { await notifications.refreshAuthorization() }
        .alert("Account not deleted", isPresented: deletionErrorBinding) {
            Button("OK", role: .cancel) { deletionError = nil }
        } message: {
            Text(deletionError ?? "Grove couldn't delete the account. Try again.")
        }
        .alert("Couldn't sign out safely", isPresented: signOutErrorBinding) {
            Button("OK", role: .cancel) { signOutError = nil }
        } message: {
            Text(signOutError ?? "Couldn't sign out. Try again.")
        }
    }

    // MARK: - Profile

    /// Who this is, before anything about what they have set. The row opens
    /// the same editor as the avatar on My Grove.
    ///
    /// The page title and the person sit straight on the canvas rather than in
    /// a card: they are the page's identity, not one of its settings, and the
    /// first card below them is then the Premium one.
    private var profileSection: some View {
        Section {
            GroveDisplayHeading(text: "Settings", style: .title)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 10, trailing: 4))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            NavigationLink(value: AppRoute.editProfile) {
                MyGroveProfileHeader()
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 8))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityHint("Edits your profile")
            .accessibilityIdentifier("settingsProfileHeader")
        }
    }

    /// How this account signs in, in the words a person would use, as a
    /// label and value for the Account section.
    private var signInSummary: (label: String, value: String)? {
        switch session.currentSession?.mode {
        case .apple: ("Signed in with", "Apple")
        case .google: ("Signed in with", "Google")
        case .email: ("Signed in with", "Email")
        case .local: ("Account", "This iPhone only")
        case .demo, .none: nil
        }
    }

    // MARK: - Your grove

    private var groveSection: some View {
        Section {
            // No "Edit profile" row. The profile tab wears its own edit button
            // one screen up, so a second row landing there would duplicate it.
            // Weather, watering rhythm and every travel prompt are read off
            // this pin, which made it the most consequential setting in Grove
            // reachable only by scrolling to the bottom of the profile page.
            NavigationLink(value: AppRoute.groveLocation) {
                LabeledContent {
                    Text(groveLocationSummary)
                } label: {
                    SettingsRowLabel("Location", systemImage: "mappin.and.ellipse")
                }
            }
            // These are the care preferences gathered during onboarding —
            // experience, grove size, environment and priorities. The label is
            // stable whether the person has filled them in or not.
            NavigationLink(value: AppRoute.plan) {
                SettingsRowLabel("Care preferences", systemImage: "list.bullet.clipboard")
            }
        } header: {
            Text("Your grove")
        }
    }

    /// Without a pin Grove falls back to generic care. The empty value names
    /// the action that makes weather and daylight advice personal.
    private var groveLocationSummary: String {
        store.profile.location?.shortLabel ?? "Add location"
    }

    // MARK: - Subscription

    /// Grove sells auto-renewing subscriptions, and until now the only way to
    /// restore one was to exhaust the day's free questions and meet the Ask
    /// paywall — which hides its restore button unless products loaded. A user
    /// who had already paid on another iPhone had no way to say so, and App
    /// Review looks for restore here first.
    ///
    /// For someone without Premium this is the one card on the page, and it
    /// says what Premium does before the list begins: a row reading "Free" (or
    /// "Checking…") told a free user nothing about what they were missing.
    /// Subscribers and early-access users get a single quiet row instead,
    /// since there is nothing to sell them.
    ///
    /// It keeps `GrovePremiumStore`'s honesty rule: nothing on this screen
    /// advertises a price the store cannot charge. The price line and the
    /// trial wording appear only once the App Store has answered with them.
    private var subscriptionSection: some View {
        Section {
            if premium.hasPremium {
                Button {
                    showingManageSubscription = true
                } label: {
                    premiumStatusLabel(showsDisclosure: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("manageSubscription")
                // The row flips to "Active" on its own after a restore, so
                // the confirmation is the one thing it cannot say: it worked.
                if let restoreMessage {
                    Text(restoreMessage)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .padding(.leading, textColumnInset)
                }
            } else if premium.isUnmetered {
                premiumStatusLabel(showsDisclosure: false)
                // Shown even in early access. There is nothing to restore
                // then, and it says so — but a restore button that appears
                // only once a catalogue loads is one a reviewer on a bad
                // connection will report as missing.
                Button {
                    Task { await restorePurchases() }
                } label: {
                    rowLabel(
                        "Restore purchases",
                        systemImage: "arrow.clockwise",
                        isBusy: isRestoring
                    )
                }
                .disabled(isRestoring)
                .accessibilityIdentifier("restorePurchases")
                if let restoreMessage {
                    Text(restoreMessage)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .padding(.leading, textColumnInset)
                }
            } else {
                SettingsPremiumCard(
                    actionTitle: premiumActionTitle,
                    priceLine: premiumPriceLine,
                    message: restoreMessage,
                    isRestoring: isRestoring,
                    onUpgrade: { showingPaywall = true },
                    onRestore: { Task { await restorePurchases() } }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .animation(GroveMotion.settle, value: premium.hasPremium)
        .animation(GroveMotion.settle, value: premium.didLoadCatalogue)
        .task { await premium.load() }
        .manageSubscriptionsSheet(isPresented: $showingManageSubscription)
        .sheet(isPresented: $showingPaywall) { AskPaywallSheet(reason: .settings) }
    }

    /// The compact row for anyone with nothing to buy: the value reports the
    /// state, and the disclosure appears only when tapping opens something.
    private func premiumStatusLabel(showsDisclosure: Bool) -> some View {
        HStack(spacing: 8) {
            SettingsRowLabel("Grove Premium", systemImage: "leaf.fill")
            Spacer()
            Text(premiumStatus)
                .foregroundStyle(GroveTheme.mutedInk)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GroveTheme.subtleInk)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private var premiumStatus: String {
        if premium.hasPremium {
            // A trial is the one subscriber state with a date the person needs:
            // it is when the card is first charged.
            if let trialEndsAt = premium.trialEndsAt {
                return "Trial until \(trialEndsAt.formatted(.dateTime.day().month()))"
            }
            return "Active"
        }
        // The catalogue answered and was empty: onboarding promised these users
        // everything while Grove is in early access, and "Free" would read as a
        // limit they do not have.
        return "Early access"
    }

    /// Names the trial only when this Apple account can redeem it. Until the
    /// store answers, or for someone who has already used a trial, the button
    /// opens the plans without promising anything free.
    private var premiumActionTitle: String {
        PremiumTerms.trialButtonTitle(premium, plan: .yearly) ?? "See Premium plans"
    }

    /// What it costs, in the storefront's own currency, or nothing at all
    /// while the App Store has not said.
    private var premiumPriceLine: String? {
        if let trial = PremiumTerms.trialLine(premium, plan: .yearly) {
            return trial
        }
        if let yearly = premium.displayPrice(for: .yearly) {
            return "\(yearly) a year"
        }
        if let monthly = premium.displayPrice(for: .monthly) {
            return "\(monthly) a month"
        }
        return nil
    }

    // MARK: - On this iPhone

    /// Reminders, sitting updates, their hour and haptics. All four are
    /// stored on this device rather than with the account, which is what the
    /// header says, and it saves "Preferences" being a section for one switch.
    private var deviceSection: some View {
        Section {
            // No "Permission: Allowed" row. Granted, it restated what three
            // live controls underneath it already showed; refused, it restated
            // the button sitting next to it.
            if notifications.authorization == .notDetermined {
                Button {
                    Task {
                        await notifications.requestAuthorization()
                        await synchronizeNotifications()
                    }
                } label: {
                    SettingsRowLabel("Turn on notifications", systemImage: "bell.badge")
                }
            } else if notifications.authorization == .denied {
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                } label: {
                    SettingsRowLabel("Open iPhone Settings", systemImage: "arrow.up.forward.app")
                }
            }
            // Nothing can be scheduled without permission, so the toggles would
            // silently do nothing — the buttons above are the real affordance
            // until permission exists.
            Toggle(isOn: $careReminders) {
                SettingsRowLabel("Care reminders", systemImage: "bell")
            }
            .disabled(!notifications.authorization.canSchedule)
            .accessibilityIdentifier("careRemindersToggle")
            Toggle(isOn: $sittingUpdates) {
                SettingsRowLabel("Plant sitting updates", systemImage: "person.2")
            }
            .disabled(!notifications.authorization.canSchedule)
            .accessibilityIdentifier("sittingUpdatesToggle")
            // Due dates come from whenever a plant was added or a check-in
            // finished, so without a chosen slot a plant adopted at 23:40 wakes
            // its owner at 23:40 a fortnight later.
            Picker(selection: $reminderHour) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(hourLabel(hour)).tag(hour)
                }
            } label: {
                // The caption used to be the section footer, which sat so
                // close to the next header that the two read as one block.
                SettingsRowLabel(
                    "Reminder time",
                    systemImage: "clock",
                    subtitle: "On the day something is due"
                )
            }
            .disabled(!notifications.authorization.canSchedule)
            .accessibilityIdentifier("reminderHourPicker")
            if let errorMessage = notifications.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.warning)
                    .padding(.leading, textColumnInset)
            }
            // Haptics are in-app touch feedback, not notifications, and remain
            // available regardless of notification permission.
            Toggle(isOn: $hapticsEnabled) {
                SettingsRowLabel(
                    "Haptic feedback",
                    systemImage: "iphone.radiowaves.left.and.right"
                )
            }
            .accessibilityIdentifier("hapticsToggle")
        } header: {
            Text("On this iPhone")
        }
    }

    /// The reminder hour in the device's own clock format, so a 24-hour locale
    /// never reads "9 AM".
    private func hourLabel(_ hour: Int) -> String {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: .now)
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: startOfDay) ?? startOfDay
        return date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Privacy & data

    private var privacyAndDataSection: some View {
        Section {
            // "Who can see my plants right now" is the privacy question this
            // screen is actually asked, and it is one the app can answer
            // exactly — a sitting assignment names both the sitter and the
            // plants it covers. One row: a second "Plant access · Only by
            // link" row opened the same page with a constant for a value.
            NavigationLink(value: AppRoute.sitting) {
                LabeledContent {
                    Text(sitterAccessSummary)
                } label: {
                    SettingsRowLabel("Plant sitters", systemImage: "key")
                }
            }
            // The privacy policy promises this in writing: a copy of everything
            // Grove holds, as a file the user keeps. The share sheet rather
            // than a Files-only exporter, so AirDrop to a Mac and "Save to
            // Files" are both one tap from here.
            Button {
                Task { await exportData() }
            } label: {
                rowLabel(
                    isExporting ? "Preparing your export…" : "Export my data",
                    systemImage: "square.and.arrow.up",
                    isBusy: isExporting
                )
            }
            .disabled(isExporting)
            .accessibilityIdentifier("exportData")
            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.danger)
                    .padding(.leading, textColumnInset)
            }
        } header: {
            Text("Privacy and data")
        }
    }

    /// Sitters who can currently see and tend plants. `invited` counts: the
    /// invitation is out and the plants named in it are already committed,
    /// which is the part a privacy screen must not round down to zero.
    private var sitterAccessSummary: String {
        // Live means live *today*: an assignment whose dates have passed grants
        // nothing, and counting it here told the user someone still had access
        // to plants they were handed back months ago.
        let live = store.assignments.filter { !$0.hasEnded() }
        // A bearer link is an access grant, not a person: it may be forwarded,
        // and a pending revoke may still open until the server confirms it.
        let links = store.sittingInvites.filter { $0.isMinted && $0.isOutstanding() }
        guard !live.isEmpty || !links.isEmpty else { return "None" }
        let plantCount = Set(live.flatMap(\.plantIDs) + links.flatMap(\.plantIDs)).count
        let grants = live.count + links.count
        let access = grants == 1 ? "1 access grant" : "\(grants) access grants"
        let plants = plantCount == 1 ? "1 plant" : "\(plantCount) plants"
        return "\(access) · \(plants)"
    }

    // MARK: - Support

    private var supportSection: some View {
        Section {
            Link(destination: Self.supportURL) {
                externalLinkLabel("Contact support", systemImage: "envelope")
            }
            .accessibilityIdentifier("contactSupport")
            Link(destination: GroveLegal.privacyURL) {
                externalLinkLabel("Privacy Policy", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("privacyPolicy")
            Link(destination: GroveLegal.termsURL) {
                externalLinkLabel("Apple Standard EULA", systemImage: "doc.text")
            }
            .accessibilityIdentifier("standardEULA")
        } header: {
            Text("Support")
        }
    }

    private static let supportURL = URL(string: "mailto:\(GroveLegal.supportEmail)")!

    /// These three rows leave Grove for Mail or Safari. A chevron would
    /// promise another screen inside the app, so they wear the outward arrow.
    private func externalLinkLabel(_ title: String, systemImage: String) -> some View {
        HStack {
            SettingsRowLabel(title, systemImage: systemImage)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GroveTheme.subtleInk)
                .accessibilityHidden(true)
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            if let signInSummary {
                LabeledContent {
                    Text(signInSummary.value)
                } label: {
                    SettingsRowLabel(signInSummary.label, systemImage: "person.crop.circle")
                }
            }
            Button {
                showingSignOutConfirmation = true
            } label: {
                SettingsRowLabel(
                    "Sign out",
                    systemImage: "rectangle.portrait.and.arrow.right"
                )
            }
            .accessibilityIdentifier("signOut")
            // Both dialogs hang off the row that opens them, not off the Form.
            // The system anchors a confirmation dialog to the view it is
            // attached to, so a Form-level dialog pointed at the middle of the
            // list — the confirmation for "Delete account" appeared over an
            // unrelated row, several sections away from the tap that asked
            // for it.
            .confirmationDialog(
                signOutTitle,
                isPresented: $showingSignOutConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) { Task { await signOut() } }
            } message: {
                Text(signOutMessage)
            }
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                SettingsRowLabel(deleteButtonTitle, systemImage: "trash", tint: GroveTheme.danger)
            }
            .disabled(isDeletingAccount)
            .accessibilityIdentifier("deleteLocalData")
            .confirmationDialog(
                deleteConfirmationTitle,
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button(deleteButtonTitle, role: .destructive) { Task { await deleteData() } }
                if hasBilledSubscription {
                    Button("Manage Subscription") { showingManageSubscription = true }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteConfirmationMessage)
            }
        } header: {
            Text("Account")
        } footer: {
            VStack(alignment: .leading, spacing: 14) {
                Text(accountFooterText)
                Text("Grove \(Self.appVersion)")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// What the two rows above do to the grove, said before either is tapped.
    private var accountFooterText: String {
        if hasServerAccount && session.canRestoreCurrentAccountAfterSignOut {
            return "Signing out keeps your grove in your account. Deleting removes plants, photos and history for good."
        }
        return "Deleting removes plants, photos and history from this iPhone for good."
    }

    private var hasServerAccount: Bool {
        session.currentSession?.mode.isSupabaseBacked == true
    }

    private var deleteButtonTitle: String {
        if isDeletingAccount { return "Deleting…" }
        return hasServerAccount ? "Delete account" : "Delete local data"
    }

    private var deleteConfirmationTitle: String {
        hasServerAccount
            ? "Delete your Grove account?"
            : "Delete local data?"
    }

    private var deleteConfirmationMessage: String {
        let deletion = hasServerAccount
            ? "This permanently deletes your account and all Grove data from Grove's servers and this iPhone. This can't be undone."
            : "This permanently deletes all Grove data from this iPhone. This can't be undone."
        // Deleting the account does not cancel an App Store subscription, and
        // nothing after this point could tell the person they are still paying.
        guard hasBilledSubscription else { return deletion }
        return "\(deletion)\n\nYour Grove Premium subscription is billed by Apple and keeps renewing. Cancel it in Manage Subscription first."
    }

    /// A real App Store subscription, as opposed to the in-memory pass handed
    /// out while nothing is on sale.
    private var hasBilledSubscription: Bool {
        premium.hasPremium && !(premium.didLoadCatalogue
            && premium.displayPrice(for: .yearly) == nil
            && premium.displayPrice(for: .monthly) == nil)
    }

    private var deletionErrorBinding: Binding<Bool> {
        Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )
    }

    private var signOutErrorBinding: Binding<Bool> {
        Binding(
            get: { signOutError != nil },
            set: { if !$0 { signOutError = nil } }
        )
    }

    private var signOutTitle: String {
        if session.currentSession?.mode == .email,
           !SessionService.isEmailSignInAvailable {
            return "Sign out while email sign-in is unavailable?"
        }
        return session.canRestoreCurrentAccountAfterSignOut
            ? "Sign out of Grove?"
            : "Sign out and lose access to this grove?"
    }

    private var signOutMessage: String {
        if session.currentSession?.mode == .email,
           !SessionService.isEmailSignInAvailable {
            return "Your account stays on Grove's servers, but this version cannot sign back in with email. You won't be able to reopen this grove on this iPhone until protected email sign-in is enabled."
        }
        return session.canRestoreCurrentAccountAfterSignOut
            ? "Your grove and Journey progress stay with your account and come back when you sign in again. Reminders stop until then."
            : "This grove isn't linked to an account, so you can't sign back in to it. Its plants, photos and history will become unreachable."
    }

    // MARK: - Actions

    private func signOut() async {
        if let accountID = session.currentSession?.accountID {
            do {
                // A claimed neutral receipt cannot follow this account back to
                // signed-out onboarding: its photo belongs to the account and
                // would otherwise block the next person's first scan.
                try await PendingFirstPlantStore.shared.discardClaimed(for: accountID)
            } catch {
                signOutError = "Couldn't sign out. Try again."
                return
            }
        }
        await notifications.cancelScheduledReminders()
        // Local reminders are only half of it. A registered device token keeps
        // this phone on the server's send list, so without this the next person
        // to sign in here would receive the previous account's friend requests
        // and sitting updates. Revoked before the session goes, while the
        // bearer that authorises the call still exists.
        await notifications.revokeDeviceToken()
        await session.signOutAndRevokeRemoteSession()
    }

    private func deleteLocalData() async {
        // The engine holds the queued mutations in memory; deleting only the
        // on-disk queue would let the "deleted" changes re-persist and sync
        // after the next sign-in.
        await syncEngine.discardQueuedChanges()
        // Signing out tears down the view tree that keeps reminders in step
        // with the data, so they have to go first — an orphaned reminder would
        // name a plant that no longer exists.
        await notifications.cancelScheduledReminders()
        await notifications.revokeDeviceToken()
        store.deleteAllLocalData()
        // The grove snapshot is not the only account data on this device.
        // Botanist conversations and unfinished scan drafts are stored under
        // their own keys, and both survived a "delete everything" — right up
        // to being handed back on the next sign-in to the same account.
        ask.deleteAllLocalData()
        await scanSession.deleteAllLocalData()
        await PendingFirstPlantStore.shared.deleteAllLocalData()
        await GroveAnalytics.shared.deleteAllLocalData()
        // A prepared export is a plaintext copy of the whole account graph,
        // photos included, sitting in the temporary directory. "Delete
        // everything on this iPhone" has to reach it too.
        LocalDataExportService().removePreparedExports()
        // Preferences and recorded consents are stored data too. Left behind,
        // a "deleted" device kept agreeing to photo processing on the user's
        // behalf and kept their reminder schedule for whoever signed in next.
        GroveDefaults.reset()
        // The engine caches the haptics preference, so clearing the key alone
        // would leave the previous owner's choice in force until relaunch.
        Haptics.refreshPreference()
        session.signOut()
    }

    private func resumeDeletionIfReauthenticated() {
        guard resumesDeletion else { return }
        resumesDeletion = false
        Task { await deleteData() }
    }

    private func deleteData() async {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        if hasServerAccount {
            do {
                try await GroveServiceFactory.deleteAccount(session: session)
            } catch GroveServiceFactory.AccountDeletionError.sessionExpired {
                // Deletion is the one action with no local fallback, so this is
                // not an error to dismiss — it goes straight to the repair that
                // unblocks it, with the copy saying why it appeared.
                showingDeleteReauthentication = true
                return
            } catch GroveServiceFactory.AccountDeletionError.noServerAccount {
                // The account only ever existed on this iPhone; the local wipe
                // below is the whole deletion.
            } catch {
                deletionError = (error as? LocalizedError)?.errorDescription
                    ?? "Grove couldn't delete the account. Check your connection and try again."
                return
            }
        }
        await deleteLocalData()
    }

    private func restorePurchases() async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        restoreMessage = nil
        switch await premium.restorePurchases() {
        case .restored:
            // The status row above flips to "Active" on its own, so the
            // confirmation is the thing the row cannot say: it worked.
            restoreMessage = "Grove Premium is restored."
            Haptics.celebrate()
        case .notFound:
            restoreMessage = premium.isUnmetered
                ? "There's nothing to restore during early access."
                : PremiumTerms.restoreNotFoundMessage
            Haptics.error()
        case .failed(let message):
            // A paying user who is offline must not be told they never paid.
            restoreMessage = message
            Haptics.error()
        }
    }

    private func exportData() async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        exportError = nil
        do {
            let url = try await LocalDataExportService().export(store: store)
            exportedFile = ExportedGroveFile(url: url)
            Haptics.success()
        } catch {
            exportError = (error as? LocalizedError)?.errorDescription
                ?? "Grove couldn't prepare your export. Try again."
            Haptics.error()
        }
    }

    private func synchronizeNotifications() async {
        await notifications.synchronize(
            plants: store.plants,
            tasks: store.tasks,
            assignments: store.assignments,
            careEnabled: careReminders,
            sittingEnabled: sittingUpdates,
            hour: reminderHour,
            photoURLs: store.latestPhotoURLs,
            trialEndsAt: premium.trialEndsAt
        )
    }

    /// A form row that keeps its label steady and adds a trailing spinner while
    /// the work runs, instead of swapping the title for a different one and
    /// leaving the user to guess whether the tap registered.
    private func rowLabel(_ title: String, systemImage: String, isBusy: Bool) -> some View {
        HStack {
            SettingsRowLabel(title, systemImage: systemImage)
            if isBusy {
                Spacer()
                ProgressView()
            }
        }
    }
}

// MARK: - Row anatomy

/// The one row shape this screen uses: a fixed glyph column, then the title.
///
/// Settings used to mix rows that carried a leading symbol with rows that did
/// not — inside the same card. The result read as an unfinished screen, and it
/// handed the loudest treatment on the page to whichever two rows happened to
/// have a glyph. Every row wearing the same leading element is what makes a
/// settings list scan as one object rather than a stack of decisions.
///
/// The column is a `@ScaledMetric` so the glyphs and the text edge grow
/// together under Dynamic Type instead of the icons sliding under the titles.
private struct SettingsRowLabel: View {
    private let title: String
    private let systemImage: String
    private let subtitle: String?
    private let tint: Color

    @ScaledMetric(relativeTo: .body) private var column = SettingsRowMetrics.iconColumn

    init(_ title: String, systemImage: String, subtitle: String? = nil, tint: Color = GroveTheme.accent) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: SettingsRowMetrics.gap) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: column, alignment: .leading)
                // The glyph repeats the title it sits beside; VoiceOver should
                // read the row once.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(tint == GroveTheme.accent ? GroveTheme.ink : tint)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
            }
        }
    }
}

// MARK: - Premium card

/// What Premium does, for someone who does not have it, before the list
/// begins.
///
/// It sits on Ari's surface on purpose. Most of what Premium buys is Ari
/// without a limit, and the botanist speaks from that night green everywhere
/// else in the app, so the card reads as Ari's offer rather than an ad that
/// arrived from somewhere else. The benefits are read from the same list the
/// paywalls use, so the two cannot disagree.
private struct SettingsPremiumCard: View {
    let actionTitle: String
    let priceLine: String?
    let message: String?
    let isRestoring: Bool
    let onUpgrade: () -> Void
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroveDisplayHeading(text: "Grove Premium", style: .section)
                .padding(.trailing, 48)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(PremiumBenefit.all()) { item in
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
            .padding(.top, 10)

            Button(action: onUpgrade) {
                GroveCTALabel(title: actionTitle)
                    .contentTransition(.opacity)
            }
            .buttonStyle(GrovePressStyle())
            .accessibilityIdentifier("openPaywall")
            .padding(.top, 18)

            HStack(spacing: 8) {
                if let priceLine {
                    Text(priceLine)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                if isRestoring {
                    ProgressView()
                        .controlSize(.small)
                }
                // Borderless, so a tap here is not also read as a tap on the
                // whole list row and its upgrade button.
                Button("Restore purchases", action: onRestore)
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .foregroundStyle(GroveTheme.ink)
                    .disabled(isRestoring)
                    .accessibilityIdentifier("restorePurchases")
            }
            .font(.footnote)
            .padding(.top, 12)

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topTrailing) {
            Image(systemName: "leaf")
                .font(.system(size: 92, weight: .light))
                .foregroundStyle(GroveTheme.accent.opacity(0.16))
                .rotationEffect(.degrees(-12))
                .offset(x: 14, y: -10)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .groveAriSurface()
    }
}

private enum SettingsRowMetrics {
    static let iconColumn: CGFloat = 26
    static let gap: CGFloat = 12
}

// MARK: - Data export hand-off

/// A prepared export, wrapped so `sheet(item:)` can present the moment the
/// file exists rather than juggling a boolean and a separately stored URL that
/// could disagree.
private struct ExportedGroveFile: Identifiable {
    let url: URL
    var id: URL { url }
}

// MARK: - Delete-account reauthentication

/// Repairs a provider account's lapsed credential without leaving Settings.
///
/// The old recovery was an alert whose only button signed the person out and
/// dropped them at the welcome screen — asking someone to take their entire
/// grove offline, on the promise that the next sign-in would land on the same
/// account id. It never needed to: the grove is keyed by that id, so proving the
/// same identity is the whole repair, and if the identity turns out to be a
/// different one nothing local has been touched.
private struct DeleteAccountReauthenticationSheet: View {
    /// Called once the same account has signed in again, before the sheet
    /// dismisses, so Settings can finish the deletion.
    var onRestored: () -> Void = {}

    @Environment(SessionService.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var isWorking = false
    @State private var failure: String?
    @State private var authTask: Task<Void, Never>?
    @State private var email = ""
    @State private var emailCode = ""
    @State private var emailCodeSent = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(GroveTheme.mutedInk)
                    signInControl
                    if let failure {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(GroveTheme.danger)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(GroveTheme.pagePadding)
            }
            .groveBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                        .disabled(isWorking)
                }
            }
        }
        .onDisappear {
            authTask?.cancel()
            session.cancelPendingAuthentication()
        }
        .interactiveDismissDisabled(isWorking)
    }

    private var title: String {
        "Sign in to delete"
    }

    private var explanation: String {
        "Deleting your account needs a current sign-in. Sign in again with \(providerName) and the deletion finishes straight after."
    }

    private var providerName: String {
        switch session.reauthenticationMethod {
        case .apple: "Apple"
        case .google: "Google"
        case .email: "your email address"
        case .device, .none: "your account"
        }
    }

    @ViewBuilder
    private var signInControl: some View {
        switch session.reauthenticationMethod {
        case .apple:
            SignInWithAppleButton(.signIn) { request in
                isWorking = true
                failure = nil
                session.prepareAppleRequest(request)
            } onCompletion: { result in
                switch session.stashAppleCredential(result) {
                case .accepted:
                    authTask?.cancel()
                    authTask = Task { await reconnect(with: .apple) }
                case .failed:
                    isWorking = false
                case .stale:
                    break
                }
            }
            .signInWithAppleButtonStyle(.black)
            // The same 56 pt as `GroveInkButton`'s regular size, so the two
            // provider paths are the same button in different clothes.
            .frame(height: 56)
            .clipShape(Capsule())
            .disabled(isWorking)
            .accessibilityIdentifier("reconnectWithApple")

        case .google:
            GroveInkButton(
                title: isWorking ? "Signing in…" : "Continue with Google",
                systemImage: "g.circle.fill"
            ) {
                continueWithGoogle()
            }
            .disabled(isWorking || !GoogleAuthenticator.isConfigured)
            .accessibilityIdentifier("reconnectWithGoogle")

            if !GoogleAuthenticator.isConfigured {
                Text("Google sign-in isn't available in this build.")
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
            }

        case .email:
            VStack(alignment: .leading, spacing: 12) {
                TextField("Email address", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking || emailCodeSent)
                    .accessibilityIdentifier("reconnectEmailField")

                if emailCodeSent {
                    TextField("6-digit code", text: $emailCode)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isWorking)
                        .onChange(of: emailCode) { _, value in
                            emailCode = OnboardingModel.sanitizedVerificationCode(value)
                        }
                        .accessibilityIdentifier("reconnectEmailCodeField")

                    Button("Use a different email") {
                        session.cancelPendingAuthentication()
                        emailCodeSent = false
                        emailCode = ""
                        failure = nil
                    }
                    .font(.footnote.weight(.semibold))
                    .disabled(isWorking)
                }

                GroveInkButton(
                    title: isWorking
                        ? (emailCodeSent ? "Verifying…" : "Sending…")
                        : (emailCodeSent ? "Verify code" : "Send verification code"),
                    systemImage: "envelope.fill"
                ) {
                    emailCodeSent ? verifyEmailCode() : sendEmailCode()
                }
                .disabled(
                    isWorking
                        || !isRepairEmailValid
                        || (emailCodeSent && emailCode.count != 6)
                )
                .accessibilityIdentifier("reconnectWithEmail")
            }

        case .device, .none:
            Text("This grove doesn't have a server account to sign in to.")
                .font(.callout)
                .foregroundStyle(GroveTheme.mutedInk)
        }
    }

    private func continueWithGoogle() {
        guard !isWorking else { return }
        isWorking = true
        failure = nil
        authTask?.cancel()
        authTask = Task {
            do {
                let credential = try await GoogleAuthenticator.signIn()
                guard !Task.isCancelled else { return }
                session.stashGoogleCredential(
                    userID: credential.userID,
                    idToken: credential.idToken,
                    displayName: credential.displayName
                )
                await reconnect(with: .google)
            } catch GoogleAuthenticator.GoogleAuthError.cancelled {
                // Backed out on purpose — no error, no noise.
                isWorking = false
            } catch {
                guard !Task.isCancelled else { return }
                failure = "Grove couldn't reach Google. Check your connection and try again."
                Haptics.error()
                isWorking = false
            }
        }
    }

    private var normalizedRepairEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isRepairEmailValid: Bool {
        OnboardingModel.isValidEmailAddress(normalizedRepairEmail)
    }

    private func sendEmailCode() {
        guard !isWorking, isRepairEmailValid else { return }
        isWorking = true
        failure = nil
        session.cancelPendingAuthentication()
        authTask?.cancel()
        authTask = Task {
            let sent = await session.sendEmailCode(
                to: normalizedRepairEmail,
                createAccount: false
            )
            guard !Task.isCancelled else { return }
            isWorking = false
            if sent {
                emailCode = ""
                emailCodeSent = true
            } else {
                failure = session.signInError
                    ?? "Grove couldn't send a verification code. Check your connection and try again."
            }
        }
    }

    private func verifyEmailCode() {
        guard !isWorking, isRepairEmailValid, emailCode.count == 6 else { return }
        isWorking = true
        failure = nil
        authTask?.cancel()
        authTask = Task {
            let verified = await session.verifyEmailCode(
                email: normalizedRepairEmail,
                code: emailCode
            )
            guard !Task.isCancelled else { return }
            guard verified else {
                isWorking = false
                emailCode = ""
                failure = session.signInError ?? "That code didn't work. Check it and try again."
                return
            }
            await reconnect(with: .email)
        }
    }

    @MainActor
    private func reconnect(with method: OnboardingAuthMethod) async {
        let outcome = await session.reauthenticateCurrentAccount(method: method)
        guard !Task.isCancelled else { return }
        isWorking = false
        switch outcome {
        case .restored:
            Haptics.success()
            onRestored()
            dismiss()
        case .wrongAccount:
            Haptics.error()
            failure = "That's a different \(providerName) account. Sign in with the one this grove belongs to."
        case .failed:
            Haptics.error()
            failure = session.signInError ?? "Grove couldn't finish signing you in. Try again."
        }
    }
}

#Preview {
    AppDestinationsPreviewHost { SettingsView() }
        .environment(GroveStore())
        .environment(SessionService(storage: UserDefaults(suiteName: "SettingsPreview")!))
        .environment(SyncEngine(queueStore: MutationQueueStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("SettingsPreviewQueue.json"))))
        .environment(ConnectivityMonitor())
        .environment(NotificationService())
        .environment(AskSession(storage: UserDefaults(suiteName: "SettingsPreview")!))
        .environment(ScanSession())
        .environment(GrovePremiumStore())
        .environment(IntentRouter.shared)
}
