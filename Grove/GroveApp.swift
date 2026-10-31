import SwiftUI
import UIKit

/// The one thing SwiftUI's `App` cannot express.
///
/// APNs hands its device token to `UIApplicationDelegate` and nowhere else, so
/// remote push needs a delegate however the rest of the app is built. It is
/// deliberately the whole of this class: everything the token then does lives in
/// `NotificationService`, reached through a reference `GroveApp` assigns during
/// `init` — before UIKit can possibly deliver one.
final class GroveAppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static weak var notifications: NotificationService?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        MainActor.assumeIsolated { Self.notifications?.acceptDeviceToken(deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        MainActor.assumeIsolated { Self.notifications?.rejectDeviceToken(error) }
    }
}

@main
struct GroveApp: App {
    @UIApplicationDelegateAdaptor(GroveAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var intentRouter = IntentRouter.shared
    @State private var store = GroveStore()
    @State private var scanSession: ScanSession
    @State private var session: SessionService
    @State private var syncEngine: SyncEngine
    @State private var connectivity = ConnectivityMonitor()
    @State private var notifications: NotificationService
    @State private var ask: AskSession
    @State private var premium = GrovePremiumStore()
    /// App-level rather than owned by Today. The sky is context for the whole
    /// grove — the plant page reads it, and the botanist is grounded in it — so
    /// it cannot live in the one tab that happens to draw a forecast strip.
    @State private var weather = WeatherService()
    /// Mirrors the store to the paired Apple Watch and applies care logged
    /// from the wrist. Owned here because it outlives every screen.
    @State private var watchSync = WatchSyncService()
    /// One neutral, protected handoff shared by signed-out onboarding and the
    /// signed-in bootstrap that claims it.
    private let pendingFirstPlantStore: PendingFirstPlantStore

    init() {
        // Before anything can reach `Purchases.shared`, which traps when the
        // SDK has not been configured. Nothing else in the app touches
        // RevenueCat during launch, so this is the only ordering that matters.
        GrovePremiumStore.bootstrap()
        GroveSearchField.installAppearance()
        pendingFirstPlantStore = .shared
        let session = SessionService()
        _session = State(initialValue: session)
        _syncEngine = State(initialValue: GroveServiceFactory.makeSyncEngine(session: session))
        _scanSession = State(
            initialValue: ScanSession(
                analysisClient: GroveServiceFactory.makePlantAnalysisClient(session: session),
                speciesSearchClient: GroveServiceFactory.makeSpeciesSearchClient(session: session)
            )
        )
        _ask = State(initialValue: AskSession(client: GroveServiceFactory.makeBotanistClient(session: session)))

        // Push is wired here, during launch, for the same reason the delegate
        // exists at all: iOS can hand back a device token — or deliver a tap on
        // a notification that launched the app — before any view has appeared.
        let notifications = NotificationService()
        notifications.registerForRemotePush = {
            UIApplication.shared.registerForRemoteNotifications()
        }
        GroveServiceFactory.attachPushRegistration(to: notifications, session: session)
        GroveAppDelegate.notifications = notifications
        _notifications = State(initialValue: notifications)
    }

    var body: some Scene {
        WindowGroup {
            RootView(pendingFirstPlantStore: pendingFirstPlantStore)
                .task { GroveDiag.log("=== app launched, plants=\(store.plants.count) ===") }
                .task { watchSync.attach(store: store, syncEngine: syncEngine, connectivity: connectivity) }
                .task { await GroveLiveActivityController.shared.run(store: store) }
                .environment(intentRouter)
                .environment(store)
                .environment(scanSession)
                .environment(session)
                .environment(syncEngine)
                .environment(connectivity)
                .environment(notifications)
                .environment(ask)
                .environment(premium)
                .environment(\.grovePremiumActive, premium.hasPremium)
                .environment(\.grovePremiumAvatarsUnlocked, premium.isUnmetered)
                .environment(weather)
                .onOpenURL { url in
                    if !intentRouter.handleIncomingURL(url) {
                        GoogleAuthenticator.handle(url)
                    }
                }
                // Someone who abandons onboarding does it by leaving the app,
                // which is exactly the event the funnel most needs to see.
                .onChange(of: scenePhase) { _, phase in
                    guard phase != .active else {
                        // The other half of the day-rollover fix: a phone
                        // picked up the next morning was never told the day
                        // had changed, so the streak stayed on yesterday's
                        // number until something else wrote to the store.
                        store.refreshCalendarDay()
                        // A subscription can change while Grove is in the
                        // background: managed in Settings, refunded, lapsed, or
                        // an offer code redeemed in the App Store. The stream
                        // catches most of it; this covers the case where the
                        // process was suspended through the change.
                        Task { await premium.load() }
                        return
                    }
                    Task { await GroveAnalytics.shared.flush() }
                }
                // Midnight with the app still open, a flight across a zone, a
                // clock nudged by the network — all of them change what "today"
                // means, and the streak is measured in days. Both notifications
                // are posted off the main thread, so they are hopped back onto
                // it before they touch observable state.
                .onReceive(
                    NotificationCenter.default
                        .publisher(for: .NSCalendarDayChanged)
                        .receive(on: RunLoop.main)
                ) { _ in
                    store.refreshCalendarDay()
                }
                .onReceive(
                    NotificationCenter.default
                        .publisher(for: .NSSystemTimeZoneDidChange)
                        .receive(on: RunLoop.main)
                ) { _ in
                    store.refreshCalendarDay()
                }
        }
    }
}
