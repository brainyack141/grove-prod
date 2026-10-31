import SwiftUI
import UIKit

struct RootView: View {
    @Environment(SessionService.self) private var session
    @Environment(GrovePremiumStore.self) private var premium
    @Environment(AskSession.self) private var ask
    @State private var hasCompletedLaunchReveal = false
    let pendingFirstPlantStore: PendingFirstPlantStore

    init(pendingFirstPlantStore: PendingFirstPlantStore = .shared) {
        self.pendingFirstPlantStore = pendingFirstPlantStore
    }

    var body: some View {
        ZStack {
            switch session.state {
            case .signedOut:
                OnboardingContainerView()
            case .signedIn(let userSession):
                SignedInRootView(
                    userSession: userSession,
                    pendingFirstPlantStore: pendingFirstPlantStore
                )
                    .id(userSession.accountID)
                    .environment(\.isGroveLaunchRevealed, hasCompletedLaunchReveal)
            }

            if !hasCompletedLaunchReveal {
                GroveLaunchView {
                    hasCompletedLaunchReveal = true
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.28), value: hasCompletedLaunchReveal)
        .task(id: session.state) {
            // A signed-out paywall may still restore or purchase. It must use a
            // fresh anonymous RevenueCat identity, never the account that just
            // signed out on this phone.
            guard case .signedOut = session.state else { return }
            ask.deactivate()
            await premium.deactivate()
        }
    }
}

private struct SignedInRootView: View {
    @Environment(GroveStore.self) private var store
    @Environment(ScanSession.self) private var scanSession
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(SessionService.self) private var session
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(AskSession.self) private var ask
    /// Identified here rather than in `RootView` because this is the view that
    /// knows which account signed in. Without it the entitlement stays attached
    /// to RevenueCat's device-local anonymous purchaser and the gateway cannot
    /// tell which Grove account paid.
    @Environment(GrovePremiumStore.self) private var premium
    @Environment(NotificationService.self) private var notifications
    @Environment(\.scenePhase) private var scenePhase
    @State private var preparedAccountID: String?
    @State private var firstPlantHandoffError: String?
    @State private var isRetryingFirstPlantHandoff = false
    @State private var unclaimedFirstPlantID: UUID?
    @State private var unclaimedFirstPlantError: String?
    @AppStorage(GroveDefaults.firstPlantNotificationPrimerPlantID)
    private var firstPlantNotificationPrimerPlantID = ""
    @AppStorage(GroveDefaults.reminderHour)
    private var reminderHour = NotificationService.reminderHour
    let userSession: UserSession
    let pendingFirstPlantStore: PendingFirstPlantStore

    var body: some View {
        // The launch state carries the static launch screen's mark forward and
        // cross-fades into the app, so a cold start reads as one continuous
        // opening rather than three screens in a row.
        ZStack {
            if let firstPlantHandoffError {
                FirstPlantHandoffRecoveryView(
                    message: firstPlantHandoffError,
                    isRetrying: isRetryingFirstPlantHandoff,
                    onRetry: retryPendingFirstPlant,
                    onContinueWithoutPlant: continueWithoutPendingFirstPlant
                )
                .transition(.opacity)
            } else if unclaimedFirstPlantID != nil {
                UnclaimedFirstPlantRecoveryView(
                    message: unclaimedFirstPlantError,
                    isWorking: isRetryingFirstPlantHandoff,
                    onKeep: keepUnclaimedFirstPlant,
                    onDiscard: discardUnclaimedFirstPlant
                )
                .transition(.opacity)
            } else if isReady {
                PostSignupSetupGate(accountID: userSession.accountID) {
                    AppShellView()
                }
                    .transition(.opacity)
            } else {
                // The app-wide launch reveal is already playing above this
                // view. If bootstrap outlasts it, retain the resolved mark as a
                // still loading state rather than replaying the animation.
                GroveLaunchView(playsReveal: false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isReady)
        .preferredColorScheme(.light)
        .task(id: userSession.accountID) {
            preparedAccountID = nil
            store.activate(session: userSession)
            // Conversations and the free-question meter are per account, like the
            // grove itself — a second account must never inherit either.
            ask.activate(accountID: userSession.accountID)
            await syncEngine.activate(accountID: userSession.accountID)
            // Journey progress used to live only in this iPhone's account
            // snapshot. Hand any migrated local copy to the durable queue
            // before bootstrap so a reinstall or second phone can restore it.
            await enqueuePendingGardenerProgress()
            // A just-created Supabase account pushes its onboarding profile
            // before the first bootstrap. Queue it durably without making the
            // first frame wait for a network delivery; the post-launch sync
            // below drains it once the provider bearer has been restored.
            if let initialProfile = session.pendingInitialProfileSync(accountID: userSession.accountID),
               await syncEngine.enqueue(.updateProfile(initialProfile), isConnected: false) {
                session.markInitialProfileSyncEnqueued(accountID: userSession.accountID)
            }
            // The shell starts a server bootstrap as soon as it appears. Import
            // the local-first handoff and durably queue it before allowing that
            // bootstrap to run, so Today never flashes empty and no remote
            // snapshot can get ahead of the user's first plant.
            let handoffIsReady = await importPendingFirstPlant(processQueueImmediately: false)
            guard !Task.isCancelled else { return }
            guard handoffIsReady else { return }
            guard await recoverStrandedFirstPlantIfNeeded() else { return }
            await finishAccountPreparation()
        }
        // A launch with no signal, or one that met a busy auth server, leaves a
        // provider account with no bearer — sync silently does nothing until
        // something asks again. These are the two moments when the answer may
        // have changed. Both are free when a bearer is already in hand.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await session.restoreProviderSession()
                await notifications.retryRemotePushRegistration()
                guard unclaimedFirstPlantID == nil else { return }
                if await importPendingFirstPlant() {
                    await finishAccountPreparation()
                }
                // In that order: a queued change waiting on an expired bearer
                // is exactly what the line above just fixed. Foregrounding must
                // also pull a snapshot, not merely drain this phone's queue:
                // friend requests, answers and removals can all have happened
                // on another device while Grove was asleep.
                await syncEngine.synchronize(store: store, isConnected: connectivity.isConnected)
            }
        }
        .onChange(of: connectivity.isConnected) { _, isConnected in
            guard isConnected else { return }
            Task {
                await session.restoreProviderSession()
                await notifications.retryRemotePushRegistration()
                guard unclaimedFirstPlantID == nil else { return }
                if await importPendingFirstPlant() {
                    await finishAccountPreparation()
                }
                // Reconnection is a two-way reconciliation. Only draining the
                // local queue leaves incoming friend changes stale until an
                // unrelated manual refresh.
                await syncEngine.synchronize(store: store, isConnected: true)
            }
        }
        .onChange(of: store.gardenerUpdatedAt) { _, _ in
            Task { await enqueuePendingGardenerProgress() }
        }
    }

    private var isReady: Bool {
        store.activeAccountID == userSession.accountID
            && syncEngine.activeAccountID == userSession.accountID
            && preparedAccountID == userSession.accountID
    }

    private func enqueuePendingGardenerProgress() async {
        guard store.activeAccountID == userSession.accountID,
              syncEngine.activeAccountID == userSession.accountID,
              let request = store.pendingGardenerProgressSyncRequest()
        else { return }
        if await syncEngine.enqueue(
            .updateGardenerProgress(request),
            isConnected: connectivity.isConnected
        ) {
            store.markGardenerProgressEnqueued(updatedAt: request.updatedAt)
        }
    }

    /// Repairs the legacy state that produced an empty Today screen after a
    /// successful onboarding scan. An account-owned claim can resume silently;
    /// a neutral scan may have been made by somebody else before this returning
    /// sign-in, so it is never auto-attached and instead gets one explicit ask.
    private func recoverStrandedFirstPlantIfNeeded() async -> Bool {
        guard session.currentSession?.pendingFirstPlantID == nil else { return true }
        do {
            guard let candidate = try await pendingFirstPlantStore.recoveryCandidate(
                for: userSession.accountID
            ) else { return true }
            switch candidate {
            case .unclaimed(let plantID):
                unclaimedFirstPlantError = nil
                unclaimedFirstPlantID = plantID
                return false
            case .claimedByAccount(let plantID):
                guard session.authorizePendingFirstPlantImport(
                    accountID: userSession.accountID,
                    plantID: plantID
                ) else { return false }
                return await importPendingFirstPlant(processQueueImmediately: false)
            }
        } catch PendingFirstPlantError.claimedByAnotherAccount {
            // The manifest is protected for its recorded owner. This account
            // neither sees it nor waits on it.
            return true
        } catch {
            // A damaged, unowned legacy receipt must not lock an unrelated
            // signed-in account out of Grove. The original marker path still
            // blocks and presents the detailed recovery UI when ownership is
            // known.
            return true
        }
    }

    private func finishAccountPreparation() async {
        guard preparedAccountID != userSession.accountID else { return }
        if let primerID = UUID(uuidString: firstPlantNotificationPrimerPlantID),
           store.plant(id: primerID) == nil {
            // A primer belongs to the account snapshot that contains its
            // plant. Never carry one across a later account switch.
            firstPlantNotificationPrimerPlantID = ""
        }
        // Keep the reminder marker until the account-scoped sheet is dismissed.
        if UUID(uuidString: firstPlantNotificationPrimerPlantID) != nil {
            OnboardingAnalytics.completed(route: .newAccount, notificationOutcome: nil)
            GrovePremiumOffer.arm()
        }
        preparedAccountID = userSession.accountID

        // Everything below can suspend on network or media cleanup. The local
        // account and first-plant handoff are already durable, so let the shell
        // render while these independent services finish.
        async let premiumActivation: Void = premium.activate(accountID: userSession.accountID)
        async let scanActivation: Void = scanSession.activate(accountID: userSession.accountID)
        await session.restoreProviderSession()
        await notifications.retryRemotePushRegistration()
        await syncEngine.synchronize(store: store, isConnected: connectivity.isConnected)
        _ = await (premiumActivation, scanActivation)
    }

    private func keepUnclaimedFirstPlant() {
        guard let plantID = unclaimedFirstPlantID, !isRetryingFirstPlantHandoff else { return }
        isRetryingFirstPlantHandoff = true
        unclaimedFirstPlantError = nil
        Task {
            guard session.authorizePendingFirstPlantImport(
                accountID: userSession.accountID,
                plantID: plantID
            ) else {
                unclaimedFirstPlantError = "Grove couldn't attach this scan to the current account."
                isRetryingFirstPlantHandoff = false
                return
            }
            if await importPendingFirstPlant(processQueueImmediately: false) {
                unclaimedFirstPlantID = nil
                await finishAccountPreparation()
            }
            isRetryingFirstPlantHandoff = false
        }
    }

    private func discardUnclaimedFirstPlant() {
        guard unclaimedFirstPlantID != nil, !isRetryingFirstPlantHandoff else { return }
        isRetryingFirstPlantHandoff = true
        unclaimedFirstPlantError = nil
        Task {
            do {
                try await pendingFirstPlantStore.discardUnclaimed()
                session.clearOnboardingGuestCredential()
                OnboardingAnalytics.firstPlantImportAbandoned()
                unclaimedFirstPlantID = nil
                await finishAccountPreparation()
            } catch {
                unclaimedFirstPlantError = "Grove couldn't remove the saved scan yet. Try again."
            }
            isRetryingFirstPlantHandoff = false
        }
    }

    @discardableResult
    private func importPendingFirstPlant(processQueueImmediately: Bool = true) async -> Bool {
        guard let importingSession = session.currentSession,
              importingSession.accountID == userSession.accountID else {
            return false
        }
        guard let expectedPlantID = importingSession.pendingFirstPlantID else {
            firstPlantHandoffError = nil
            return true
        }
        let outcome = await PendingFirstPlantImporter(pendingStore: pendingFirstPlantStore)
            .importIfNeeded(
                session: importingSession,
                expectedPlantID: expectedPlantID,
                store: store,
                syncEngine: syncEngine,
                isConnected: processQueueImmediately && connectivity.isConnected
            )

        // Scene activation, connectivity and the initial bootstrap can all
        // replay this import. A later result must not overwrite a winner that
        // already consumed the marker, and a task from an old account must not
        // mutate the newly signed-in account's root state.
        guard let current = session.currentSession,
              current.accountID == importingSession.accountID else {
            return false
        }
        guard current.pendingFirstPlantID == expectedPlantID else {
            if current.pendingFirstPlantID == nil {
                firstPlantHandoffError = nil
                return true
            }
            firstPlantHandoffError = "Grove found a different protected first plant than this sign-in expected."
            return false
        }

        switch outcome {
        case .imported(let plantID),
             .importedLocally(let plantID),
             .alreadyImported(let plantID):
            // The analysis identity is useful only until the value it produced
            // has a durable owner. Clearing it sooner loses resumability;
            // retaining it longer keeps an unnecessary credential on device.
            // Persist the primer before consuming the one-shot marker. Clearing
            // the guest credential comes between them so every possible kill
            // can safely replay without leaving an orphan Keychain identity.
            firstPlantNotificationPrimerPlantID = plantID.uuidString
            session.clearOnboardingGuestCredential()
            session.markPendingFirstPlantImported(
                accountID: importingSession.accountID,
                plantID: plantID
            )
            OnboardingAnalytics.firstPlantImported()
            OnboardingAnalytics.firstPlantBaselineSaved()
            firstPlantHandoffError = nil
            return true
        case .deferred(_, let localCopyIsDurable):
            // Retain the one-shot marker and the recovery screen for every
            // deferred result. In particular, an in-memory plant is not proof
            // that the account snapshot survived, and a claimed neutral
            // manifest cannot be left behind after the shell permits sign-out.
            if localCopyIsDurable {
                firstPlantHandoffError = "Your first plant is saved on this iPhone. Grove still needs to finish its account handoff before Today can open."
            } else {
                firstPlantHandoffError = "Grove couldn't verify that your first plant was saved to this account yet. Its protected handoff is still intact."
            }
            return false
        case .noPendingDraft:
            firstPlantHandoffError = "Grove couldn't find the protected first-plant photo this account was meant to receive."
            return false
        case .claimedByAnotherAccount:
            firstPlantHandoffError = "This saved first plant is already attached to a different Grove on this iPhone."
            return false
        case .failed:
            firstPlantHandoffError = "Grove couldn't safely read your saved first plant. Your account is intact."
            return false
        }
    }

    private func retryPendingFirstPlant() {
        guard !isRetryingFirstPlantHandoff else { return }
        isRetryingFirstPlantHandoff = true
        Task {
            await session.restoreProviderSession()
            if await importPendingFirstPlant() {
                await finishAccountPreparation()
            }
            isRetryingFirstPlantHandoff = false
        }
    }

    private func continueWithoutPendingFirstPlant() {
        guard !isRetryingFirstPlantHandoff else { return }
        guard let current = session.currentSession,
              current.accountID == userSession.accountID else {
            return
        }
        guard let plantID = current.pendingFirstPlantID else {
            firstPlantHandoffError = nil
            unclaimedFirstPlantID = nil
            unclaimedFirstPlantError = nil
            Task { await finishAccountPreparation() }
            return
        }
        isRetryingFirstPlantHandoff = true
        Task {
            defer { isRetryingFirstPlantHandoff = false }
            // This is the only lossy escape, and it is an explicit user choice.
            // Remove the exact recoverable manifest for its owner before consuming
            // the session marker. If deletion cannot be acknowledged, recovery
            // must remain visible or a later sign-out could wedge that claim.
            do {
                // `false` means an earlier attempt already removed the
                // manifest. That is the required cleanup postcondition too,
                // and makes this escape safe to replay after a process kill.
                _ = try await pendingFirstPlantStore.discardRecoverable(
                    for: current.accountID,
                    expectedPlantID: plantID
                )
            } catch {
                guard session.currentSession?.accountID == current.accountID else { return }
                firstPlantHandoffError = "Grove couldn't remove the protected handoff yet. Try again before continuing."
                return
            }

            guard let liveSession = session.currentSession,
                  liveSession.accountID == current.accountID else {
                return
            }
            guard liveSession.pendingFirstPlantID == plantID else {
                if liveSession.pendingFirstPlantID == nil {
                    firstPlantHandoffError = nil
                    await finishAccountPreparation()
                }
                return
            }

            firstPlantNotificationPrimerPlantID = ""
            session.clearOnboardingGuestCredential()
            session.abandonPendingFirstPlantImport(
                accountID: current.accountID,
                plantID: plantID
            )
            OnboardingAnalytics.firstPlantImportAbandoned()
            OnboardingAnalytics.completed(route: .newAccount, notificationOutcome: nil)
            GrovePremiumOffer.arm()
            firstPlantHandoffError = nil
            unclaimedFirstPlantID = nil
            unclaimedFirstPlantError = nil
            await finishAccountPreparation()
        }
    }


}

private struct UnclaimedFirstPlantRecoveryView: View {
    let message: String?
    let isWorking: Bool
    let onKeep: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        ZStack {
            OnboardingBackground()
            VStack(spacing: 18) {
                Image(systemName: "leaf.circle.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.accentStrong)
                    .accessibilityHidden(true)
                GroveDisplayHeading(
                    text: "Keep the plant you scanned?",
                    style: .heading
                )
                .multilineTextAlignment(.center)
                Text("A plant scan from before you signed in isn't saved to an account yet. Add it to your grove?")
                    .font(.subheadline)
                    .foregroundStyle(OnboardingTheme.mutedInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GroveTheme.danger)
                        .multilineTextAlignment(.center)
                }
                OnboardingPrimaryButton(
                    title: isWorking ? "Saving…" : "Add to my grove",
                    isEnabled: !isWorking,
                    action: onKeep
                )
                .accessibilityIdentifier("recoverUnclaimedFirstPlant")
                Button("This isn't my scan", action: onDiscard)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OnboardingTheme.mutedInk)
                    .frame(minHeight: 44)
                    .disabled(isWorking)
                    .accessibilityIdentifier("discardUnclaimedFirstPlant")
            }
            .padding(28)
            .frame(maxWidth: 430)
        }
        .accessibilityIdentifier("unclaimedFirstPlantRecovery")
    }
}

private struct FirstPlantHandoffRecoveryView: View {
    let message: String
    let isRetrying: Bool
    let onRetry: () -> Void
    let onContinueWithoutPlant: () -> Void

    var body: some View {
        ZStack {
            OnboardingBackground()
            VStack(spacing: 18) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.accentStrong)
                    .frame(width: 68, height: 68)
                    .background(OnboardingTheme.accentSoft, in: Circle())
                GroveDisplayHeading(
                    text: "Your first plant needs another moment.",
                    style: .heading
                )
                .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(OnboardingTheme.mutedInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                OnboardingPrimaryButton(
                    title: isRetrying ? "Trying again…" : "Try again",
                    isEnabled: !isRetrying,
                    action: onRetry
                )
                .accessibilityIdentifier("retryFirstPlantImport")
                Button("Continue without this plant", action: onContinueWithoutPlant)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OnboardingTheme.mutedInk)
                    .frame(minHeight: 44)
                    .disabled(isRetrying)
                    .accessibilityIdentifier("abandonFirstPlantImport")
            }
            .padding(28)
            .frame(maxWidth: 430)
        }
        .accessibilityIdentifier("firstPlantImportRecovery")
    }
}

/// The bar stays put. iOS 26 can shrink it into a pill as the page scrolls
/// down, and Grove used to opt into that, but Grove's bar carries a raised
/// centre action that the system knows nothing about: when the bar collapsed,
/// the Scan disc stayed where it was and was left hovering over the page on
/// its own, and on Ask it landed on the composer's send button. A five-column
/// bar with a primary action in it is navigation the user should be able to
/// reach without first scrolling up, so it is pinned. The glass still reads as
/// glass — the scroll-edge effect under it does that work, not the collapse.
///
/// Nothing to fall back to on 18–25; the bar there is simply the classic
/// opaque one, which never minimized either.
private struct GroveTabBarBehaviour: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.never)
        } else {
            content
        }
    }
}

/// The five visual positions in the tab bar. Scan reserves the centre position
/// but remains an action: selecting it presents the camera while preserving the
/// destination the person was already using.
private enum AppShellTab: Hashable {
    case today
    case ask
    case scan
    case friends
    case profile

    init(_ destination: AppTab) {
        switch destination {
        case .today: self = .today
        case .ask: self = .ask
        case .friends: self = .friends
        case .profile: self = .profile
        }
    }

    var destination: AppTab? {
        switch self {
        case .today: .today
        case .ask: .ask
        case .scan: nil
        case .friends: .friends
        case .profile: .profile
        }
    }
}

enum AppShellChromePolicy {
    /// The raised centre action — and with it the system bar it sits in — belongs
    /// to the tab roots. Every drill-in takes the full height and draws its own
    /// bottom chrome.
    ///
    /// An active plant page used to keep the bar and turn the centre action into
    /// a scoped check-in camera. The page then grew a docked action bar of its
    /// own in the same place, so the disc rose straight through the "Check in"
    /// pill beneath it while repeating the same action. Two surfaces cannot share
    /// one bottom edge: the page's bar wins, and the shell steps aside.
    static func showsPrimaryAction(
        isKeyboardVisible: Bool,
        isAtTabRoot: Bool
    ) -> Bool {
        !isKeyboardVisible && isAtTabRoot
    }
}

private struct AppShellView: View {
    @Environment(IntentRouter.self) private var intentRouter
    @Environment(ScanSession.self) private var scanSession
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(NotificationService.self) private var notifications
    @Environment(GroveStore.self) private var store
    @Environment(WeatherService.self) private var weather
    @Environment(GrovePremiumStore.self) private var premium
    @Environment(\.scenePhase) private var scenePhase
    @State private var toasts = GroveToastCenter()
    @State private var selectedTab = AppTab.today
    @State private var todayPath: [AppRoute] = []
    @State private var scanPath: [AppRoute] = []
    @State private var askPath: [AppRoute] = []
    @State private var friendsPath: [AppRoute] = []
    @State private var profilePath: [AppRoute] = []
    @State private var scanIntentPicker: ScanIntentPickerPresentation?
    @State private var selectedScanIntent: ScanMode?
    /// Non-nil while the camera is covering the app. See `ScanLaunch`.
    @State private var scanLaunch: ScanLaunch?
    /// Identifies the one launch whose reticle should grow out of the raised
    /// centre action. Shortcut and in-content launches have no visible source.
    @State private var scanReticleHandoffID: UUID?
    @State private var isKeyboardVisible = false
    @State private var handledFirstPlantActivation = false
    /// Non-nil while the Premium offer is covering the app. Resolved before it
    /// is raised, so the offer never appears above an empty frame while a photo
    /// loads off disk.
    @State private var premiumOffer: GrovePremiumOfferSubject?
    @AppStorage(GroveDefaults.careReminders) private var careReminders = true
    @AppStorage(GroveDefaults.sittingUpdates) private var sittingUpdates = true
    @AppStorage(GroveDefaults.reminderHour) private var reminderHour = NotificationService.reminderHour
    @AppStorage(GroveDefaults.firstPlantActivationPending) private var firstPlantActivationPending = false
    @AppStorage(GroveDefaults.firstPlantAutoScanPresented) private var firstPlantAutoScanPresented = false
    @AppStorage(GroveDefaults.premiumOfferMeaningfulUseCount) private var premiumMeaningfulUseCount = 0

    var body: some View {
        // The tab bar is the system's. Grove used to hide it and draw its own,
        // which is why it never looked like iOS 26 no matter how the glass was
        // tuned: `glassEffect()` on a hand-built capsule is not the material the
        // system bar uses, and it cannot carry the scroll-edge or minimize
        // behaviours that make the material read as glass in motion. Compiled
        // against the iOS 26 SDK, the stock bar is Liquid Glass for free — along
        // with native badges, Dynamic Type and 44pt targets.
        ZStack(alignment: .bottom) {
            TabView(selection: shellTabSelection) {
                Tab(value: AppShellTab.today) {
                    NavigationStack(path: $todayPath) {
                        TodayView().withAppDestinations(path: $todayPath)
                    }
                    // Tab bar visibility has to be set on the tab's own
                    // content: on iOS 26 the TabView-level modifier hid the
                    // scan disc but left the bar under every drill-in.
                    .toolbar(isBarVisible ? .visible : .hidden, for: .tabBar)
                } label: {
                    AppTab.today.tabLabel
                }
                .badge(tabBadges[.today] ?? 0)

                Tab(value: AppShellTab.ask) {
                    NavigationStack(path: $askPath) {
                        AskView().withAppDestinations(path: $askPath)
                    }
                    // Tab bar visibility has to be set on the tab's own
                    // content: on iOS 26 the TabView-level modifier hid the
                    // scan disc but left the bar under every drill-in.
                    .toolbar(isBarVisible ? .visible : .hidden, for: .tabBar)
                } label: {
                    AppTab.ask.tabLabel
                }

                // The visible primary control is overlaid below. This empty item
                // reserves the centre column without turning Scan into a
                // destination of its own.
                Tab(value: AppShellTab.scan) {
                    Color.clear
                } label: {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }

                Tab(value: AppShellTab.friends) {
                    NavigationStack(path: $friendsPath) {
                        FriendsView().withAppDestinations(path: $friendsPath)
                    }
                    // Tab bar visibility has to be set on the tab's own
                    // content: on iOS 26 the TabView-level modifier hid the
                    // scan disc but left the bar under every drill-in.
                    .toolbar(isBarVisible ? .visible : .hidden, for: .tabBar)
                } label: {
                    AppTab.friends.tabLabel
                }
                .badge(tabBadges[.friends] ?? 0)

                Tab(value: AppShellTab.profile) {
                    NavigationStack(path: $profilePath) {
                        ProfileView().withAppDestinations(path: $profilePath)
                    }
                    // Tab bar visibility has to be set on the tab's own
                    // content: on iOS 26 the TabView-level modifier hid the
                    // scan disc but left the bar under every drill-in.
                    .toolbar(isBarVisible ? .visible : .hidden, for: .tabBar)
                } label: {
                    AppTab.profile.tabLabel
                }
            }
            // Selection finally speaks in the app's own colour. The bar used to
            // signal it with ink-versus-muted — a lightness step on the one
            // component every user sees on every screen, with the leaf green
            // nowhere in it.
            .tint(GroveTheme.accentStrong)
            // The header consumes a plain presentation value instead of the
            // RevenueCat store itself, so previews remain lightweight and the
            // brand mark updates immediately when an entitlement arrives.
            .environment(\.grovePremiumActive, premium.hasPremium)
            .environment(\.grovePremiumAvatarsUnlocked, premium.isUnmetered)
            .modifier(GroveTabBarBehaviour())
            // The native bar and the raised primary action consume the exact
            // same root/keyboard policy. Destination-level toolbar overrides
            // used to race this state during pushes and interactive pops.
            .toolbar(isBarVisible ? .visible : .hidden, for: .tabBar)
            // The layer belongs to the pages, not to the whole window, so a
            // confirmation lands just above the tab bar instead of on top of
            // it — the undo and the navigation stay reachable at once.
            .groveToastLayer(bottomInset: isBarVisible ? GrovePrimaryActionButton.toastClearance : 10)

            // Tab roots own Scan; drill-ins own their contextual actions.
            primaryActionOverlay
        }
        .sheet(item: $scanIntentPicker, onDismiss: launchSelectedScanIntent) { _ in
            ScanIntentPickerView(selection: $selectedScanIntent)
        }
        // The camera is a task you finish and leave, so it covers the app
        // instead of living in a tab. Its own stack is thrown away on the way
        // out, so the next scan always starts at the viewfinder.
        .fullScreenCover(item: $scanLaunch) { launch in
            NavigationStack(path: $scanPath) {
                ScanView(
                    path: $scanPath,
                    isActive: true,
                    presetMode: launch.mode,
                    plantID: launch.plantID,
                    isModalRoot: true,
                    animatesReticleEntry: scanReticleHandoffID == launch.id
                )
                .withAppDestinations(path: $scanPath)
            }
            .onDisappear {
                scanPath = []
                if scanReticleHandoffID == launch.id {
                    scanReticleHandoffID = nil
                }
            }
        }
        // Premium is offered here rather than inside onboarding, after a real
        // care-loop action. See `GrovePremiumOffer`.
        .fullScreenCover(item: $premiumOffer) { subject in
            GrovePremiumOfferView(subject: subject) {
                GrovePremiumOffer.complete()
                premiumOffer = nil
            }
        }
        // One toast centre for the whole app: a confirmation raised from a row,
        // a menu or a sheet outlives the thing that raised it and always lands
        // in the same place.
        .environment(toasts)
        // Badge and level-up takeovers, mounted above every tab. The work that
        // earns them happens on Today, in a check-in, or in Ask — so the
        // celebration has to be able to reach the person there.
        .groveCelebrationLayer()
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .tint(GroveTheme.ink)
        .buttonBorderShape(.roundedRectangle(radius: GroveTheme.compactRadius))
        .onChange(of: intentRouter.requestedTab, initial: true) { _, requestedTab in
            guard let requestedTab else { return }
            show(requestedTab)
            if requestedTab == .friends { friendsPath = [] }
            intentRouter.requestedTab = nil
        }
        .onChange(of: intentRouter.requestedPlantID, initial: true) { _, plantID in
            guard let plantID else { return }
            show(.today)
            todayPath = [.plant(plantID)]
            intentRouter.requestedPlantID = nil
        }
        .onChange(of: intentRouter.requestedCheckInPlantID, initial: true) { _, plantID in
            guard let plantID else { return }
            show(.today)
            todayPath = [.checkIn(plantID)]
            intentRouter.requestedCheckInPlantID = nil
        }
        .onChange(of: intentRouter.requestedScan, initial: true) { _, launch in
            guard let launch else { return }
            scanReticleHandoffID = nil
            scanLaunch = launch
            intentRouter.requestedScan = nil
        }
        // Quick actions raised inside the app push onto the stack the user is
        // already standing in, rather than jumping them to another tab. The
        // camera is a cover with a stack of its own, so while it is up it is the
        // stack the user is standing in.
        .onChange(of: intentRouter.pushedRoute) { _, route in
            guard let route else { return }
            if scanLaunch != nil {
                scanPath.append(route)
            } else {
                switch selectedTab {
                case .today: todayPath.append(route)
                case .ask: askPath.append(route)
                case .friends: friendsPath.append(route)
                case .profile: profilePath.append(route)
                }
            }
            intentRouter.pushedRoute = nil
        }
        .onChange(of: intentRouter.requestedRoute, initial: true) { _, route in
            guard let route else { return }
            let tab = intentRouter.requestedRouteTab ?? .today
            show(tab)
            switch tab {
            case .today: todayPath = [route]
            case .ask: askPath = [route]
            case .friends: friendsPath = [route]
            case .profile: profilePath = [route]
            }
            intentRouter.requestedRoute = nil
            intentRouter.requestedRouteTab = nil
        }
        // Notification permission is the one piece of app state a user can
        // change without the app running: they leave for iOS Settings, flip it,
        // and come back. Nothing re-read it on return, so a freshly granted
        // permission stayed invisible — the checklist row stayed unticked and
        // `reminderFingerprint` never changed, meaning the reminders they had
        // just allowed were still not scheduled.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                store.flushPersistence()
                return
            }
            Task { await notifications.refreshAuthorization() }
        }
        .task(id: connectivity.isConnected) {
            await syncEngine.start()
            await syncEngine.synchronize(store: store, isConnected: connectivity.isConnected)
        }
        .task(id: "\(scenePhase == .active)-\(connectivity.isConnected)-\(selectedTab.rawValue)") {
            guard scenePhase == .active, connectivity.isConnected else { return }
            // Tab entry fetches immediately; bounded foreground polling also
            // finds requests when push permission is off or a push is missed.
            while !Task.isCancelled {
                await syncEngine.synchronize(store: store, isConnected: true)
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
        // Fills in canonical taxon ids for plants identified from a photo.
        //
        // A scan returns a species name and no taxonomy key, so every plant
        // whose owner accepted the top answer — most of them — matched its
        // safety record and its care profile on display text alone. Driven from
        // the shell rather than the scan because it also has a backlog to
        // clear: every plant already in the grove is in the same state.
        //
        // Best-effort by design. It runs after the sync it depends on for the
        // plant list, takes a few names at a time, and a pass that resolves
        // nothing costs the user nothing.
        .task(id: taxonBackfillID) {
            guard connectivity.isConnected, !store.plants.isEmpty else { return }
            let names = store.scientificNamesAwaitingTaxonID
            guard !names.isEmpty else { return }
            let resolved = await scanSession.resolveCanonicalTaxonIDs(
                for: names,
                regionCode: store.profile.regionCode
            )
            guard !Task.isCancelled else { return }
            store.applyCanonicalTaxonIDs(resolved)
        }
        // Loaded by the shell, not by Today. A user who opens straight into a
        // plant page or into Ask still gets an answer grounded in their sky,
        // rather than one that depends on which tab they happened to visit.
        .task(id: weatherTaskID) {
            guard let location = store.profile.location else { return }
            await weather.load(for: location.coordinate)
        }
        .task(id: reminderScheduleID) {
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
        // Care logged from the lock screen. The action can wake the app into the
        // background before the store has an account, so `NotificationService`
        // only writes the intent down — this is where it becomes a real
        // completion, through the same calls the Today row makes.
        .onChange(of: intentRouter.pendingCareAction, initial: true) { _, action in
            guard let action else { return }
            intentRouter.pendingCareAction = nil
            apply(action)
        }
        // Onboarding only arms the offer. A real care-loop action makes it due,
        // and it can rise only while Today is idle at its root — never over the
        // camera, a check-in, or the destination that produced that value.
        .task(id: premiumOfferGateID) {
            guard premiumOffer == nil,
                  scanLaunch == nil,
                  selectedTab == .today,
                  isAtTabRoot,
                  premium.didLoadCatalogue,
                  !premium.hasPremium,
                  GrovePremiumOffer.isDue(),
                  let plant = store.plants.first else { return }
            // Let Today settle first. An offer that animates up during the
            // launch reveal reads as a launch screen with a price on it.
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled,
                  !premium.hasPremium,
                  scanLaunch == nil,
                  selectedTab == .today,
                  isAtTabRoot else { return }
            var image: UIImage?
            if let url = store.latestPhotoURL(for: plant.id) {
                image = await GroveImageLoader.downsampledImage(at: url)
            }
            guard !Task.isCancelled else { return }
            premiumOffer = GrovePremiumOfferSubject(
                plant: plant,
                plantCount: store.plants.count,
                image: image
            )
        }
        .task(id: firstPlantActivationPending) {
            guard firstPlantActivationPending, !handledFirstPlantActivation else { return }
            if !store.plants.isEmpty {
                // A crash after saving the baseline but before clearing the
                // handoff must not reopen the camera over an existing grove.
                firstPlantActivationPending = false
                return
            }
            // The handoff camera rises once per activation — the launch the
            // plan reveal's "Scan my first plant" promised. Someone who closed
            // it wasn't ready; re-raising it on every cold launch until they
            // gave in was a nag, and Today's empty state already carries the
            // same invitation.
            guard !firstPlantAutoScanPresented else { return }
            handledFirstPlantActivation = true
            firstPlantAutoScanPresented = true
            // Let the launch mark resolve into the shell before the camera
            // rises, so the handoff feels intentional rather than like a
            // permission dialog appearing during launch.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, firstPlantActivationPending else { return }
            scanReticleHandoffID = nil
            scanLaunch = ScanLaunch(mode: .add)
        }
    }

    /// Applies care logged from a notification action.
    ///
    /// Deliberately the same two store calls and the same mutation the Today
    /// row makes, so the activity entry, the sitting-assignment counter and the
    /// synced outcome cannot differ by where the tap happened. The one
    /// difference is timing: the row holds its completion back for five seconds
    /// to leave room for undo, and a lock screen has no undo to leave room for.
    ///
    /// A check-in is the exception: it needs a photo and observations, so a
    /// "Logged it" that reaches here for one (an old banner delivered under the
    /// care category) opens the check-in rather than completing it.
    private func apply(_ action: PendingCareAction) {
        switch action.outcome {
        case .logged:
            if let task = store.task(id: action.taskID), task.kind == .checkIn {
                intentRouter.startCheckIn(task.plantID)
                return
            }
            // The user tapped "done" on a reminder Grove itself sent and there
            // is no screen to ask the soil question on; refusing would silently
            // drop care that happened.
            guard let completed = store.complete(taskID: action.taskID, force: true) else { return }
            enqueueCare(
                CareTaskMutationRequest(
                    taskID: completed.id,
                    outcome: .completed,
                    occurredAt: .now,
                    rescheduledFor: nil,
                    reason: nil,
                    clientRequestID: UUID()
                )
            )
        case .snoozed:
            // From an overdue task, "tomorrow" means tomorrow — not the day
            // after the date it was already missed. Same rule as the row.
            let base = max(store.task(id: action.taskID)?.dueDate ?? .now, .now)
            guard let date = Calendar.current.date(byAdding: .day, value: 1, to: base),
                  let snoozed = store.snooze(taskID: action.taskID, until: date, reason: "Remind me tomorrow")
            else { return }
            enqueueCare(
                CareTaskMutationRequest(
                    taskID: snoozed.id,
                    outcome: .snoozed,
                    occurredAt: .now,
                    rescheduledFor: date,
                    reason: "Remind me tomorrow",
                    clientRequestID: UUID()
                )
            )
        }
    }

    private func enqueueCare(_ request: CareTaskMutationRequest) {
        let isConnected = connectivity.isConnected
        Task { await syncEngine.enqueue(.updateCareTask(request), isConnected: isConnected) }
    }

    /// Routing to a destination always means leaving the camera. Anything that
    /// selects a tab has to take the cover down with it, or the app navigates
    /// underneath a viewfinder the user can still see.
    private func show(_ tab: AppTab) {
        scanReticleHandoffID = nil
        scanLaunch = nil
        selectedTab = tab
    }

    /// Marks only tab-bar launches for the focus-bloom handoff. The launch id is
    /// more reliable than a boolean: an overlapping shortcut cannot inherit an
    /// animation intended for a cover it replaced.
    private func presentScanFromTabBar() {
        selectedScanIntent = nil
        scanIntentPicker = ScanIntentPickerPresentation()
    }

    /// The intent sheet disappears before the full-screen camera rises, so two
    /// presentations never fight for the same frame. The selected job then
    /// follows every other mode-specific scan entry point.
    private func launchSelectedScanIntent() {
        guard let mode = selectedScanIntent else { return }
        selectedScanIntent = nil
        let launch = ScanLaunch(mode: mode)
        scanReticleHandoffID = launch.id
        scanLaunch = launch
    }

    private var shellTabSelection: Binding<AppShellTab> {
        Binding(
            get: { AppShellTab(selectedTab) },
            set: { newTab in
                if let destination = newTab.destination {
                    selectedTab = destination
                } else {
                    // The reserved centre column is an action, not a
                    // destination: selecting it opens the camera and leaves the
                    // current stack where it was.
                    presentScanFromTabBar()
                }
            }
        )
    }

    /// What the bar has to tell the user about places they are not looking at.
    private var tabBadges: [AppTab: Int] {
        var badges: [AppTab: Int] = [:]
        // Counted in plants, the same unit as the rooms map caption ("4 need
        // you today") and the app icon, so the three can never disagree.
        let due = store.plantsNeedingCareCount
        if due > 0 { badges[.today] = due }
        let requests = store.friendsTabBadgeCount()
        if requests > 0 { badges[.friends] = requests }
        return badges
    }

    /// Whether the native bar, centre action and toast clearance are all on
    /// screen. One value owns all three so pushes and keyboard transitions
    /// cannot leave a half-visible navigation surface behind.
    private var isBarVisible: Bool {
        AppShellChromePolicy.showsPrimaryAction(
            isKeyboardVisible: isKeyboardVisible,
            isAtTabRoot: isAtTabRoot
        )
    }

    @ViewBuilder
    private var primaryActionOverlay: some View {
        if isBarVisible {
            GrovePrimaryActionButton(action: presentScanFromTabBar)
                .padding(.bottom, GrovePrimaryActionButton.barBottomPadding)
        }
    }

    /// The bar and its centre action belong to the tab roots. Every drill-in —
    /// a plant page included — takes the full height.
    private var isAtTabRoot: Bool {
        switch selectedTab {
        case .today: todayPath.isEmpty
        case .ask: askPath.isEmpty
        case .friends: friendsPath.isEmpty
        case .profile: profilePath.isEmpty
        }
    }

    /// Re-runs the offer gate whenever eligibility or presentation context can
    /// change. `@AppStorage` observes the care-loop counter written by the store.
    private var premiumOfferGateID: String {
        "\(store.plants.count)-\(premiumMeaningfulUseCount)-\(selectedTab.rawValue)-\(isAtTabRoot)-\(scanLaunch != nil)-\(premium.hasPremium)-\(premium.didLoadCatalogue)"
    }

    /// The only thing one forecast is pinned to: where the grove is.
    ///
    /// The measurement preference used to be part of this, because the request
    /// asked the API for the user's unit. It now always asks for Celsius and
    /// converts at the point of display, so toggling °F no longer throws away a
    /// good forecast and fetches an identical one back.
    private var weatherTaskID: String {
        guard let location = store.profile.location else { return "none" }
        return "\(location.latitude),\(location.longitude)"
    }

    /// Re-runs the taxon backfill when the size of the backlog changes — a new
    /// scan adds to it, a resolved pass shrinks it — and when connectivity
    /// returns. Keyed on the count rather than on the names so a pass that
    /// resolves nothing does not immediately restart itself.
    private var taxonBackfillID: String {
        "\(connectivity.isConnected)-\(store.plants.count)-\(store.plants.count { $0.canonicalTaxonID == nil })"
    }

    private var reminderScheduleID: ReminderScheduleID {
        ReminderScheduleID(
            storeRevision: store.revision,
            authorization: notifications.authorization.rawValue,
            careEnabled: careReminders,
            sittingEnabled: sittingUpdates,
            hour: reminderHour,
            trialEndsAt: premium.trialEndsAt,
            calendarDay: store.calendarDay
        )
    }

}

private struct ScanIntentPickerPresentation: Identifiable {
    let id = "scan-intent"
}

/// The camera opens with one job. Asking before capture keeps the viewfinder
/// instructions honest and removes the post-photo "What next?" decision that
/// made a finished photo feel unfinished.
private struct ScanIntentPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: ScanMode?
    @State private var contentHeight: CGFloat = 314
    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 24

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Scan")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(GroveTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 12)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(GroveTheme.mutedInk)
                            .frame(width: 32, height: 32)
                            .background(GroveTheme.secondarySurface, in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(GroveTilePressStyle(haptics: false))
                    .accessibilityLabel("Cancel")
                    .accessibilityIdentifier("scanIntent.cancel")
                }
                .padding(.leading, 12)

                VStack(spacing: 0) {
                    intentRow(
                        mode: .add,
                        title: "Add a plant",
                        detail: "Save it to your grove",
                        symbol: "plus"
                    )
                    rowDivider
                    intentRow(
                        mode: .identify,
                        title: "Identify a plant",
                        detail: "Find its name, without adding it",
                        symbol: "camera.viewfinder"
                    )
                    rowDivider
                    intentRow(
                        mode: .diagnose,
                        title: "Diagnose a problem",
                        detail: "Find out what’s wrong",
                        symbol: "stethoscope"
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 20)
            .padding(.bottom, 12)
            // Measure the intrinsic content inside the scroll view. The sheet
            // grows with larger text, and can still scroll at the screen limit.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height.rounded(.up)
            } action: { height in
                guard height > 0, contentHeight != height else { return }
                contentHeight = height
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .background(GroveTheme.surface)
        .presentationBackground(GroveTheme.surface)
        .presentationDetents([.height(contentHeight)])
        .presentationCornerRadius(GroveTheme.heroRadius)
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("scanIntentPicker")
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(GroveTheme.separator)
            .frame(height: 0.5)
            .padding(.leading, iconSize + 36)
            .padding(.trailing, 12)
            .accessibilityHidden(true)
    }

    private func intentRow(
        mode: ScanMode,
        title: String,
        detail: String,
        symbol: String
    ) -> some View {
        Button {
            selection = mode
            dismiss()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(GroveTheme.accentStrong)
                    .frame(width: iconSize + 8, height: iconSize + 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(GroveTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroveTheme.subtleInk)
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(IntentRowPressStyle())
        .accessibilityHint("Opens the plant camera")
        .accessibilityIdentifier("scanIntent.\(mode.rawValue)")
    }

    private struct IntentRowPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                        .fill(GroveTheme.softAccent.opacity(configuration.isPressed ? 1 : 0))
                }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, isPressed in
                    guard isPressed else { return }
                    Haptics.press()
                }
        }
    }
}

/// Small, typed task identity in place of concatenating every plant, task and
/// assignment into one large string during each shell body evaluation.
private struct ReminderScheduleID: Hashable {
    let storeRevision: UInt64
    let authorization: String
    let careEnabled: Bool
    let sittingEnabled: Bool
    let hour: Int
    let trialEndsAt: Date?
    /// Moves at midnight, so the app-icon badge is recounted when tomorrow's
    /// work becomes today's rather than at the next unrelated change.
    let calendarDay: Date
}

#Preview {
    RootView()
        .environment(IntentRouter.shared)
        .environment(GroveStore())
        .environment(ScanSession())
        .environment(SessionService(storage: UserDefaults(suiteName: "RootPreview")!))
        .environment(SyncEngine(queueStore: MutationQueueStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("RootPreviewQueue.json"))))
        .environment(ConnectivityMonitor())
        .environment(NotificationService())
        .environment(AskSession())
        .environment(WeatherService())
        .environment(GrovePremiumStore())
}
