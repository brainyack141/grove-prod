import XCTest
import SwiftUI
import UIKit
import RevenueCat
@testable import Grove

/// TEMPORARY (branch icp-fixes): renders real screens from inside the hosted
/// unit-test run so the ICP fixes can be inspected visually before this file is
/// removed again.
///
/// Set `GROVE_SIMSHOT_DIR` to an absolute directory to run it; without that
/// variable the test skips, so the ordinary CI job stays green. Every screen is
/// captured once per appearance variant — light, dark and large text — and
/// written as `<variant>-<name>.png`, with a `manifest.txt` listing every file
/// and any screen that could not be set up.
///
/// Every screen is hosted in a freshly-created `UIHostingController` on one
/// reusable `UIWindow`, with a fresh store and session, so state never leaks
/// from one capture into the next. All screens are non-throwing and independent:
/// one failing to render must not stop the rest.
@MainActor
final class SimScreenshotTests: XCTestCase {
    private static let demoAccountID = "ui-test-demo-simshots"

    private enum Variant: CaseIterable, Equatable {
        case light
        case dark
        case largeText

        var prefix: String {
            switch self {
            case .light: "light"
            case .dark: "dark"
            case .largeText: "ax"
            }
        }

        var style: UIUserInterfaceStyle {
            switch self {
            case .light, .largeText: .light
            case .dark: .dark
            }
        }

        var dynamicType: DynamicTypeSize? {
            switch self {
            case .light, .dark: nil
            case .largeText: .accessibility3
            }
        }
    }

    /// A screenshot render is only meaningful on a real scene.
    private var window: UIWindow?
    private var variant: Variant = .light
    private var screenshotDirectory: URL?
    private var capturedNames: [String] = []
    private var missingLines: [String] = []

    private var router: IntentRouter { IntentRouter.shared }

    func testCaptureScreens() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawDirectory = environment["GROVE_SIMSHOT_DIR"], !rawDirectory.isEmpty else {
            throw XCTSkip("Set GROVE_SIMSHOT_DIR to capture screenshots")
        }
        let directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        screenshotDirectory = directory
        capturedNames = []
        missingLines = ["MISSING watch-* watchOS target not hostable from GroveTests"]

        GrovePremiumStore.bootstrap()
        // The app's DEBUG launch-argument bypass does not apply to a hosted
        // unit test, so grant consent before any scan or Ask screen is shown.
        AIProcessingConsent.grant()
        // Keep the one-time Premium takeover out of the screenshots.
        UserDefaults.standard.removeObject(forKey: GroveDefaults.firstPlantNotificationPrimerPlantID)
        GrovePremiumOffer.complete()
        UserDefaults.standard.set(0, forKey: GroveDefaults.premiumOfferMeaningfulUseCount)

        // QA runs can ask for a subset, e.g. GROVE_SIMSHOT_VARIANTS=light,dark.
        let requested = Set(
            (environment["GROVE_SIMSHOT_VARIANTS"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        )
        for appearance in Variant.allCases where requested.isEmpty || requested.contains(appearance.prefix) {
            variant = appearance
            await captureAllScreens()
        }
    }

    private func captureAllScreens() async {
        // The welcome screen must not resume a draft left by an earlier run.
        UserDefaults.standard.removeObject(forKey: "grove.onboarding.draft.v1")
        // A staged first plant left by an earlier run would block the
        // signed-in shell behind its recovery screen.
        try? await PendingFirstPlantStore.shared.discardUnclaimed()

        // 10 — signed-out welcome.
        resetRouter()
        let (welcomeSession, welcomeStore) = makeSignedOutContext()
        await show(
            hosted(
                RootView(pendingFirstPlantStore: .shared),
                session: welcomeSession,
                store: welcomeStore
            ),
            wait: 7
        )
        capture("10-welcome")

        // 11–16 — onboarding steps. The private `Draft` type cannot be encoded
        // directly, but its Codable key names are stable, so a minimal draft is
        // written as JSON and read back by `OnboardingModel`. Each step is then
        // rendered as its own view (rather than through the container) so the
        // container's pending-plant validation cannot bounce the screen back to
        // the camera.
        await stageDemoFirstPlant()
        let onboardingSteps: [(String, OnboardingModel.Step, OnboardingModel.Route)] = [
            ("11-onb-firstPlantDetails", .firstPlantDetails, .newAccount),
            ("12-onb-firstPlantRoom", .firstPlantRoom, .newAccount),
            ("13-onb-location", .location, .newAccount),
            ("14-onb-signIn", .signIn, .newAccount),
            ("15-onb-emailEntry", .emailEntry, .newAccount),
            ("16-onb-explore", .explore, .manual),
            ("17-onb-welcome", .welcome, .newAccount),
            ("18-onb-accountNotFound", .accountNotFound, .returning),
            ("19-onb-emailVerification", .emailVerification, .newAccount),
            ("19b-onb-name", .name, .manual)
        ]
        for (name, step, route) in onboardingSteps {
            resetRouter()
            writeOnboardingDraft(step: step.rawValue, route: route.rawValue)
            let (session, store) = makeSignedOutContext()
            let model = OnboardingModel()
            model.step = step
            model.route = route
            model.firstName = "Alex"
            await show(hosted(onboardingView(step, model: model), session: session, store: store), wait: 4)
            capture(name)
        }
        UserDefaults.standard.removeObject(forKey: "grove.onboarding.draft.v1")
        try? await PendingFirstPlantStore.shared.discardUnclaimed()

        // 20 — Today.
        resetRouter()
        // The demo root needs the shortest wait that still lets its fixtures
        // settle, because it is shown again for every pushed screen.
        await show(demoRoot(), wait: 5)
        capture("20-today")

        // 21–29 — pushed destinations, each from a fresh root.
        await capturePushed("21-care-queue", route: .care)
        await capturePushed("22-plant-detail", route: .plant(UUID(uuidString: "10000000-0000-0000-0000-000000000004")!))
        // The same page at the bottom of its sheet: the docked Check in bar
        // must leave the last card readable rather than sitting on it.
        await scrollMainScrollView(toBottom: true)
        capture("22-plant-detail-bottom")
        await capturePushed("23-plant-detail-monty", route: .plant(UUID(uuidString: "10000000-0000-0000-0000-000000000001")!))
        await capturePushed("24-add-plant", route: .addPlant)
        if let window {
            func firstResponder(in view: UIView) -> UIView? {
                if view.isFirstResponder { return view }
                for subview in view.subviews { if let found = firstResponder(in: subview) { return found } }
                return nil
            }
            let responder = firstResponder(in: window)
            print("SIMSHOT-DEBUG 24-add-plant firstResponder=\(responder.map { String(describing: type(of: $0)) } ?? "none") id=\(responder?.accessibilityIdentifier ?? "-")")
        }
        await capturePushed("25-settings", route: .settings)
        await capturePushed("26-journey", route: .journey)
        await capturePushed("27-achievements", route: .achievements)
        await capturePushed("28-plan", route: .plan)
        await capturePushed("29-activity", route: .activity)

        // 30–32 — the remaining tabs.
        await captureTab("30-ask", tab: .ask)
        await captureTab("31-friends", tab: .friends)
        await captureTab("32-mygrove", tab: .profile)

        // 33–34 — My Grove scrolled one screen down, then to the bottom.
        await captureTab("33-mygrove-scrolled", tab: .profile) { [self] in
            await scrollMainScrollView(toBottom: false)
        }
        await scrollMainScrollView(toBottom: true)
        capture("34-mygrove-bottom")

        // 35–49 — the remaining pushed destinations. Numbering skips 40–42 and
        // 50–52, which belong to the paywalls, empty Today and the scan error.
        let demoPlantID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        await capturePushed("35-editPlant", route: .editPlant(demoPlantID))
        await capturePushed("36-plantHistory", route: .plantHistory(demoPlantID))
        await capturePushed("37-plantStory", route: .plantStory(demoPlantID))
        await capturePushed("38-plantDiagnosis", route: .plantDiagnosis(demoPlantID))
        await capturePushed("39-checkIn", route: .checkIn(demoPlantID))
        await capturePushed("43-sitting", route: .sitting)
        await capturePushed("44-sittingLink", route: .sittingLink)
        await capturePushed("45-friendInvitations", route: .friendInvitations)
        await capturePushed("46-editProfile", route: .editProfile)
        await capturePushed("47-groveLocation", route: .groveLocation)
        await capturePushed("48-scanHistory", route: .scanHistory)
        await capturePushed("49-groveScore", route: .groveScore)

        // 40–42 — paywalls, hosted directly.
        resetRouter()
        let (paywallSession, paywallStore) = makeDemoContext()
        await show(
            hosted(
                GrovePremiumOfferView(subject: nil, onFinish: {}),
                session: paywallSession,
                store: paywallStore
            ),
            wait: 3
        )
        capture("40-paywall")

        resetRouter()
        let (askSession, askStore) = makeDemoContext()
        await show(
            hosted(AskPaywallSheet(reason: .browsing), session: askSession, store: askStore),
            wait: 3
        )
        capture("41-ask-paywall")

        resetRouter()
        let (slotsSession, slotsStore) = makeDemoContext()
        await show(
            hosted(FriendSlotsPaywallSheet(), session: slotsSession, store: slotsStore),
            wait: 3
        )
        capture("42-friend-slots-paywall")

        // The App Store catalogue does not exist in CI, so these priced states
        // are seeded with the fixture catalogue below instead of waiting for a
        // network offering that never arrives.
        resetRouter()
        let (plantOfferSession, plantOfferStore) = makeDemoContext()
        await show(
            hosted(
                GrovePremiumOfferView(subject: offerSubject(for: plantOfferStore), onFinish: {}),
                session: plantOfferSession,
                store: plantOfferStore,
                premium: seededPremium()
            ),
            wait: 3
        )
        capture("40b-paywall-plant")
        await captureScrolled("40g-paywall-plant-scrolled")

        resetRouter()
        let (monthlySession, monthlyStore) = makeDemoContext()
        await show(
            hosted(
                GrovePremiumOfferView(
                    subject: offerSubject(for: monthlyStore),
                    initialPlan: .monthly,
                    onFinish: {}
                ),
                session: monthlySession,
                store: monthlyStore,
                premium: seededPremium()
            ),
            wait: 3
        )
        capture("40c-paywall-monthly")

        resetRouter()
        let (noTrialSession, noTrialStore) = makeDemoContext()
        await show(
            hosted(
                GrovePremiumOfferView(subject: offerSubject(for: noTrialStore), onFinish: {}),
                session: noTrialSession,
                store: noTrialStore,
                premium: seededPremium(trial: false)
            ),
            wait: 3
        )
        capture("40d-paywall-notrial")

        resetRouter()
        let (emptyOfferSession, emptyOfferStore) = makeDemoContext()
        await show(
            hosted(
                GrovePremiumOfferView(subject: nil, onFinish: {}),
                session: emptyOfferSession,
                store: emptyOfferStore,
                premium: seededPremium(empty: true)
            ),
            wait: 3
        )
        capture("40e-paywall-empty")

        resetRouter()
        let (askPricedSession, askPricedStore) = makeDemoContext()
        await show(
            hosted(
                AskPaywallSheet(reason: .limitReached),
                session: askPricedSession,
                store: askPricedStore,
                premium: seededPremium()
            ),
            wait: 3
        )
        capture("41b-ask-paywall-priced")

        resetRouter()
        let (slotsPricedSession, slotsPricedStore) = makeDemoContext()
        await show(
            hosted(
                FriendSlotsPaywallSheet(),
                session: slotsPricedSession,
                store: slotsPricedStore,
                premium: seededPremium()
            ),
            wait: 3
        )
        capture("42b-friend-slots-priced")

        // The end-of-onboarding offer, through the real gate. Setup already
        // called `complete()`, which sets the shown flag that makes
        // `markOnboardingFinished` refuse, so clear it first. RootView's gate
        // presents this as a fullScreenCover only after its 900 ms settle,
        // which is why this wait is longer than the hosted paywalls'.
        resetRouter()
        UserDefaults.standard.removeObject(forKey: GroveDefaults.premiumOfferShown)
        GrovePremiumOffer.markOnboardingFinished()
        let (offerSession, offerStore) = makeDemoContext()
        await show(
            hosted(
                RootView(pendingFirstPlantStore: .shared),
                session: offerSession,
                store: offerStore,
                premium: seededPremium()
            ),
            wait: 8
        )
        capture("40f-onboarding-end-offer")
        await captureScrolled("40h-onboarding-end-offer-scrolled")
        GrovePremiumOffer.complete()
        UserDefaults.standard.set(0, forKey: GroveDefaults.premiumOfferMeaningfulUseCount)

        // 50 — a signed-in non-demo account with no plants. A fresh defaults
        // suite means no account snapshot and no demo fixtures; activation for
        // a `.local` session clears the store's in-memory fixtures.
        resetRouter()
        let (emptySession, emptyStore) = makeEmptyContext()
        await show(
            hosted(RootView(pendingFirstPlantStore: .shared), session: emptySession, store: emptyStore),
            wait: 8
        )
        capture("50-empty-today")

        // 51 — the scan error surface. `ScanResultView` renders whatever its
        // session's state says, so a session holding an add-mode draft in the
        // failed state shows the error without a camera or a network call.
        // Its `.task` only analyses from `.ready`, so the failure stays put.
        resetRouter()
        let (scanSession, scanStore) = makeDemoContext()
        let failedScan = ScanSession(storage: UserDefaults(suiteName: "sim-shots-scan-\(UUID().uuidString)")!)
        failedScan.draft = ScanMediaDraft(
            id: UUID(),
            mode: .add,
            createdAt: Date(),
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("simshot-scan-error.jpg"),
            pixelWidth: 800,
            pixelHeight: 800
        )
        failedScan.state = .failure(for: PlantAnalysisError.unavailable)
        await show(
            hosted(
                // Applied inside `hosted`, so this session wins over the one
                // `hosted` injects for every other screen. The result is
                // pushed from a root, the way the app reaches it, so the
                // navigation bar's Back control is part of the capture.
                PushedScanResultHost(mode: .add)
                    .environment(failedScan),
                session: scanSession,
                store: scanStore
            ),
            wait: 3
        )
        capture("51-scan-error")

        // 52 — the photo-processing consent sheet, hosted directly.
        resetRouter()
        let (consentSession, consentStore) = makeDemoContext()
        await show(
            hosted(
                AIProcessingConsentView(onAgree: {}, onDecline: {}),
                session: consentSession,
                store: consentStore
            ),
            wait: 3
        )
        capture("52-ai-consent")

        await captureQAExtras()

        window?.isHidden = true
    }

    // MARK: - QA extras (visual-bug sweep)

    /// Every other route the app can push, the long screens scrolled, and the
    /// sheets that can be hosted on their own.
    private func captureQAExtras() async {
        let monty = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let fern = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!

        // Long screens: scrolled one screen, then to the bottom.
        await capturePushedScrolled("60-plant-detail", route: .plant(fern))
        await capturePushedScrolled("61-plant-detail-monty", route: .plant(monty))
        await capturePushedScrolled("62-settings", route: .settings)
        await capturePushedScrolled("63-journey", route: .journey)
        await capturePushedScrolled("64-achievements", route: .achievements)
        await capturePushedScrolled("65-plan", route: .plan)
        await capturePushedScrolled("66-checkIn", route: .checkIn(monty))
        await capturePushedScrolled("67-plantStory", route: .plantStory(fern))
        await captureTab("68-today-scrolled", tab: .today) { [self] in
            await scrollMainScrollView(toBottom: false)
        }
        await scrollMainScrollView(toBottom: true)
        capture("69-today-bottom")
        await captureTab("70-friends-scrolled", tab: .friends) { [self] in
            await scrollMainScrollView(toBottom: true)
        }
        await captureTab("71-ask-bottom", tab: .ask) { [self] in
            await scrollMainScrollView(toBottom: true)
        }

        // Routes not covered above.
        await capturePushed("72-friends-route", route: .friends)
        await capturePushed("73-inviteFriend", route: .inviteFriend(nil))
        await capturePushed("74-friendGrove-maya", route: .friendGrove("demo-maya"))
        await capturePushed("75-sittingFriend", route: .sittingFriend)
        await capturePushed("76-sittingLinkForPlant", route: .sittingLinkForPlant(monty))
        await capturePushed("77-askAbout", route: .askAbout(monty))
        if let topic = LearnLibrary.all.first {
            await capturePushed("78-learnTopic", route: .learnTopic(topic.id))
        } else {
            noteMissing("78-learnTopic", reason: "no learn topic")
        }
        // The live camera is what these two are for, not the once-per-install
        // tips sheet (the UI flow captures that), so mark the tips seen for
        // the pair and put the flag back afterwards.
        let tipsWereSeen = UserDefaults.standard.bool(forKey: GroveDefaults.hasSeenScanTips)
        UserDefaults.standard.set(true, forKey: GroveDefaults.hasSeenScanTips)
        await capturePushed("79-liveScan-identify", route: .liveScan(.identify, nil))
        await capturePushed("80-liveScan-diagnose-plant", route: .liveScan(.diagnose, monty))
        UserDefaults.standard.set(tipsWereSeen, forKey: GroveDefaults.hasSeenScanTips)
        // `.plantDiagnosis` takes a diagnosis id, not a plant id: record one
        // for Monty first so the screen shows a real diagnosis rather than the
        // not-found state (38 already covers that).
        await capturePushedResolved("81-plantDiagnosis-monty") { store in
            let result = PlantAnalysisResult(
                identification: PlantIdentificationResult(
                    commonName: "Swiss cheese plant",
                    scientificName: "Monstera deliciosa",
                    confidence: 91,
                    alternatives: [],
                    distinguishingTraits: ["Split leaves"]
                ),
                condition: PlantConditionResult(
                    healthScore: 58,
                    healthBand: .attention,
                    confidence: 84,
                    summary: "Yellowing on two lower leaves and soil that stays wet.",
                    positiveSigns: ["New leaf unfurling"],
                    concerns: ["Lower leaves yellowing", "Soil stays wet between waterings"],
                    possibleCauses: ["Overwatering", "Low light"],
                    nextActions: ["Let the top 5 cm dry out before watering", "Move nearer a bright window"]
                ),
                providerName: "Grove demo",
                limitations: []
            )
            let diagnosis = store.addDiagnosis(plantID: monty, result: result, photoURL: nil)
            // A new diagnosis counts as today's look, so the store queues the
            // first-day streak flame (and any badge) over the page. Drain them so
            // the shot shows the diagnosis itself.
            store.pendingStreakMoment = nil
            store.pendingBadges = []
            store.pendingLevelUp = nil
            return diagnosis.map { .plantDiagnosis($0.id) }
        }
        await capturePushed("82-plantHistory-monty", route: .plantHistory(monty))
        await capturePushedResolved("83-collection") { store in
            store.collections.first.map { .collection($0.id) }
        }
        await capturePushedResolved("84-careTask") { store in
            store.tasks.first(where: { !$0.isCompleted }).map { .careTask($0.id) }
        }

        // Sheets hosted on their own.
        resetRouter()
        let (sheetSession, sheetStore) = makeDemoContext()
        await show(hosted(StreakDetailSheet(), session: sheetSession, store: sheetStore), wait: 4)
        capture("85-streak-detail-sheet")

        resetRouter()
        let (collectionSession, collectionStore) = makeDemoContext()
        await show(hosted(CreateCollectionView(), session: collectionSession, store: collectionStore), wait: 4)
        capture("86-create-collection-sheet")

        resetRouter()
        let (tipsSession, tipsStore) = makeDemoContext()
        await show(hosted(ScanTipsView(mode: .add, onDismiss: {}), session: tipsSession, store: tipsStore), wait: 3)
        capture("87-scan-tips-add")

        resetRouter()
        let (diagTipsSession, diagTipsStore) = makeDemoContext()
        await show(hosted(ScanTipsView(mode: .diagnose, onDismiss: {}), session: diagTipsSession, store: diagTipsStore), wait: 3)
        capture("88-scan-tips-diagnose")

        resetRouter()
        let (setupSession, setupStore) = makeDemoContext()
        await show(
            hosted(NavigationStack { ProfileSetupView(isOnboarding: true) }, session: setupSession, store: setupStore),
            wait: 4
        )
        capture("89-profile-setup-onboarding")

        resetRouter()
        let (primerSession, primerStore) = makeDemoContext()
        await show(hosted(RootView(pendingFirstPlantStore: .shared), session: primerSession, store: primerStore), wait: 5)
        if let plant = primerStore.plants.first {
            await show(
                hosted(
                    OnboardingNotificationPrimerView(
                        plant: plant,
                        task: primerStore.tasks.first(where: { $0.plantID == plant.id }),
                        reminderHour: .constant(9),
                        isRequesting: false,
                        onEnable: {},
                        onSkip: {}
                    ),
                    session: primerSession,
                    store: primerStore
                ),
                wait: 3
            )
            capture("90-notification-primer")
        } else {
            noteMissing("90-notification-primer", reason: "demo store has no plants")
        }
    }

    private func capturePushedScrolled(_ name: String, route: AppRoute) async {
        resetRouter()
        await show(demoRoot(), wait: 5)
        router.pushedRoute = route
        try? await Task.sleep(for: .seconds(3))
        await scrollMainScrollView(toBottom: false)
        capture("\(name)-scrolled")
        await scrollMainScrollView(toBottom: true)
        capture("\(name)-bottom")
    }

    /// Pushes a route whose id only exists once the demo fixtures are in.
    private func capturePushedResolved(_ name: String, route: (GroveStore) -> AppRoute?) async {
        resetRouter()
        let (session, store) = makeDemoContext()
        await show(hosted(RootView(pendingFirstPlantStore: .shared), session: session, store: store), wait: 5)
        guard let resolved = route(store) else {
            noteMissing(name, reason: "demo store has nothing to open")
            return
        }
        router.pushedRoute = resolved
        try? await Task.sleep(for: .seconds(3))
        capture(name)
    }

    // MARK: - Hosting

    /// Replaces the root with a fresh hosting controller and lets the screen
    /// settle. Non-throwing so one capture cannot abort the rest.
    private func show<V: View>(_ view: V, wait: Double) async {
        guard let window = ensureWindow() else { return }
        window.overrideUserInterfaceStyle = variant.style
        // The large-text variant must be large text to UIKit as well, not
        // only to the SwiftUI environment, or pushed screens start at the
        // default size and change size after they first appear.
        window.traitOverrides.preferredContentSizeCategory = variant.dynamicType == nil ? .large : .accessibilityExtraLarge
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try? await Task.sleep(for: .seconds(wait))
    }

    private func ensureWindow() -> UIWindow? {
        if let window { return window }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else {
            print("SIMSHOT-NOTE no window scene")
            return nil
        }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        self.window = window
        return window
    }

    private func capture(_ name: String) {
        let entry = "\(variant.prefix)-\(name)"
        guard let window else {
            noteMissing(name, reason: "no window scene")
            return
        }
        guard let directory = screenshotDirectory else {
            noteMissing(name, reason: "no screenshot directory")
            return
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else {
            noteMissing(name, reason: "could not encode PNG")
            return
        }
        let url = directory.appendingPathComponent("\(entry).png")
        do {
            try data.write(to: url)
        } catch {
            noteMissing(name, reason: "could not write PNG")
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = entry
        attachment.lifetime = .keepAlways
        add(attachment)
        capturedNames.append(entry)
        print("SIMSHOT saved \(entry)")
        writeManifest()
    }

    private func noteMissing(_ name: String, reason: String) {
        let line = "MISSING \(variant.prefix)-\(name) \(reason)"
        missingLines.append(line)
        print("SIMSHOT-NOTE \(line)")
        writeManifest()
    }

    /// Captures the current screen after scrolling its first overflowing
    /// scroll view to the bottom, without animation, so the capture shows what
    /// sits below the pinned footer at rest.
    private func captureScrolled(_ name: String) async {
        guard let window else {
            noteMissing(name, reason: "no window scene")
            return
        }
        // A full-screen cover is its own presented controller, mounted above
        // the window's root. Searching the window first would find the root's
        // scroll view underneath and capture that instead of the offer.
        let presented = topMostPresentedViewController(from: window.rootViewController)
        let scrollView = presented.map { firstScrollView(in: $0.view) } ?? firstScrollView(in: window)
        guard let scrollView else {
            noteMissing(name, reason: "no scroll view")
            return
        }
        let bottom = max(
            0,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: bottom), animated: false)
        try? await Task.sleep(for: .seconds(1))
        capture(name)
    }

    /// The last controller in the presentation chain, or nil when the root is
    /// showing nothing over itself.
    private func topMostPresentedViewController(from root: UIViewController?) -> UIViewController? {
        var topMost: UIViewController?
        var current = root?.presentedViewController
        while let controller = current {
            topMost = controller
            current = controller.presentedViewController
        }
        return topMost
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView,
           scrollView.contentSize.height > scrollView.bounds.height {
            return scrollView
        }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    private func writeManifest() {
        guard let directory = screenshotDirectory else { return }
        let lines = capturedNames + missingLines
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? text.write(
            to: directory.appendingPathComponent("manifest.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Screens

    private func capturePushed(_ name: String, route: AppRoute) async {
        resetRouter()
        await show(demoRoot(), wait: 5)
        router.pushedRoute = route
        try? await Task.sleep(for: .seconds(3))
        capture(name)
    }

    private func captureTab(
        _ name: String,
        tab: AppTab,
        beforeCapture: (() async -> Void)? = nil
    ) async {
        resetRouter()
        await show(demoRoot(), wait: 5)
        router.requestedTab = tab
        try? await Task.sleep(for: .seconds(3))
        await beforeCapture?()
        capture(name)
    }

    /// Scrolls the screen's main vertical scroll view — the largest one in
    /// the window that can actually scroll vertically — one screen down, or to
    /// the bottom, then lets lazy content settle. Non-throwing: with no such
    /// scroll view the capture simply shows the unscrolled screen.
    private func scrollMainScrollView(toBottom: Bool) async {
        guard let window else { return }
        let candidates = scrollViews(in: window).filter {
            !$0.isHidden && $0.contentSize.height > $0.bounds.height + 1
        }
        guard let scrollView = candidates.max(by: {
            $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
        }) else {
            print("SIMSHOT-NOTE no vertical scroll view to scroll")
            return
        }
        let insets = scrollView.adjustedContentInset
        let minY = -insets.top
        let maxY = max(minY, scrollView.contentSize.height + insets.bottom - scrollView.bounds.height)
        let target = toBottom ? maxY : min(maxY, scrollView.contentOffset.y + scrollView.bounds.height)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: false)
        try? await Task.sleep(for: .seconds(1.5))
        // Lazy stacks can grow the content once they render what scrolled in,
        // so a scroll to the bottom is re-measured and repeated once.
        if toBottom {
            let settledMaxY = max(minY, scrollView.contentSize.height + insets.bottom - scrollView.bounds.height)
            if settledMaxY > scrollView.contentOffset.y + 1 {
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: settledMaxY), animated: false)
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        if let scrollView = view as? UIScrollView { found.append(scrollView) }
        for subview in view.subviews { found += scrollViews(in: subview) }
        return found
    }

    @ViewBuilder
    private func onboardingView(_ step: OnboardingModel.Step, model: OnboardingModel) -> some View {
        switch step {
        case .firstPlantDetails:
            OnboardingFirstPlantResultView(model: model)
        case .firstPlantRoom:
            OnboardingRoomStepView(model: model)
        case .location:
            OnboardingHomeStepView(model: model)
        case .signIn:
            OnboardingSignInView(model: model)
        case .emailEntry:
            OnboardingEmailEntryView(model: model)
        case .explore:
            OnboardingExploreView(model: model)
        case .welcome:
            OnboardingWelcomeView(model: model)
        case .accountNotFound:
            OnboardingAccountNotFoundView(model: model)
        case .emailVerification:
            OnboardingVerificationView(model: model)
        case .name:
            OnboardingNameStepView(model: model)
        default:
            EmptyView()
        }
    }

    private func demoRoot() -> some View {
        let (session, store) = makeDemoContext()
        return hosted(RootView(pendingFirstPlantStore: .shared), session: session, store: store)
    }

    // MARK: - Environment

    private func hosted<V: View>(
        _ view: V,
        session: SessionService,
        store: GroveStore,
        premium: GrovePremiumStore = GrovePremiumStore()
    ) -> some View {
        view
            .environment(router)
            .environment(store)
            .environment(ScanSession(
                analysisClient: GroveServiceFactory.makePlantAnalysisClient(session: session),
                speciesSearchClient: GroveServiceFactory.makeSpeciesSearchClient(session: session)
            ))
            .environment(session)
            .environment(GroveServiceFactory.makeSyncEngine(session: session))
            .environment(ConnectivityMonitor())
            .environment(NotificationService())
            .environment(AskSession(client: GroveServiceFactory.makeBotanistClient(session: session)))
            .environment(premium)
            .environment(WeatherService())
            // `GrovePrimaryActionButton` stays at opacity 0 until the scene is
            // active. A hosted window in the test run reports an inactive
            // scene, which is why the centre scan button was missing from the
            // root captures. The app itself reveals it on a real active scene.
            .environment(\.scenePhase, .active)
            .environment(\.dynamicTypeSize, variant.dynamicType ?? .large)
            .preferredColorScheme(variant == .dark ? .dark : .light)
    }

    /// A catalogue that renders the priced paywall without RevenueCat. Marking
    /// the trial eligible the way `PremiumStoreTests` does means the trial copy
    /// appears only when the fixture product actually carries the offer.
    private func seededPremium(trial: Bool = true, empty: Bool = false) -> GrovePremiumStore {
        let premium = GrovePremiumStore()
        guard !empty else {
            // "The store answered, and there is nothing for sale."
            premium.seedCatalogueForTesting(
                packages: [:],
                eligibleFreeTrials: [:],
                didLoadCatalogue: true
            )
            return premium
        }
        let catalogue = PaywallFixture.catalogue(trial: trial)
        premium.seedCatalogueForTesting(
            packages: catalogue,
            eligibleFreeTrials: PaywallFixture.eligibleFreeTrials(in: catalogue)
        )
        return premium
    }

    /// The demo store starts from `Plant.fixtures`, so its first plant is
    /// available without a network load; nil still renders the general offer.
    private func offerSubject(for store: GroveStore) -> GrovePremiumOfferSubject? {
        guard let plant = store.plants.first else { return nil }
        return GrovePremiumOfferSubject(plant: plant, plantCount: store.plants.count, image: nil)
    }

    private func makeSignedOutContext() -> (SessionService, GroveStore) {
        let defaults = UserDefaults(suiteName: "sim-shots-signed-out-\(UUID().uuidString)")!
        return (
            SessionService(storage: defaults, authClientProvider: { nil }),
            GroveStore(storage: defaults)
        )
    }

    private func makeDemoContext() -> (SessionService, GroveStore) {
        let defaults = UserDefaults(suiteName: "sim-shots-demo-\(UUID().uuidString)")!
        let demo = UserSession(accountID: Self.demoAccountID, mode: .demo, displayName: "Alex")
        defaults.set(try? JSONEncoder().encode(demo), forKey: "grove.user.session.v1")
        // Keep the post-signup name/location gate from covering the shell.
        UserDefaults.standard.set(0, forKey: PostSignupSetupProgress.key(Self.demoAccountID))
        let session = SessionService(storage: defaults, authClientProvider: { nil })
        return (session, GroveStore(storage: defaults))
    }

    private func makeEmptyContext() -> (SessionService, GroveStore) {
        let defaults = UserDefaults(suiteName: "sim-shots-empty-\(UUID().uuidString)")!
        let empty = UserSession(
            accountID: "ui-test-empty-\(UUID().uuidString)",
            mode: .local,
            displayName: "Alex"
        )
        defaults.set(try? JSONEncoder().encode(empty), forKey: "grove.user.session.v1")
        let session = SessionService(storage: defaults, authClientProvider: { nil })
        return (session, GroveStore(storage: defaults))
    }

    private func resetRouter() {
        router.requestedTab = nil
        router.pendingCareAction = nil
        router.requestedPlantID = nil
        router.requestedCheckInPlantID = nil
        router.requestedScan = nil
        router.requestedRoute = nil
        router.requestedRouteTab = nil
        router.pushedRoute = nil
    }

    // MARK: - Onboarding fixtures

    /// Writes a minimal `OnboardingModel.Draft` JSON. `Draft` is private, but
    /// its synthesized Codable keys are the property names below.
    private func writeOnboardingDraft(step: String, route: String) {
        let draft: [String: Any] = [
            "flowVersion": 7,
            "step": step,
            "route": route,
            "firstName": "Alex",
            "overcome": [String]()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: draft) else { return }
        UserDefaults.standard.set(data, forKey: "grove.onboarding.draft.v1")
    }

    private func stageDemoFirstPlant() async {
        let size = CGSize(width: 800, height: 800)
        let image = UIImage(named: "DemoPlantMonstera") ?? UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let photoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("simshot-first-plant-\(UUID().uuidString).jpg")
        guard (try? data.write(to: photoURL)) != nil else { return }

        let analysis = PlantAnalysisResult(
            identification: PlantIdentificationResult(
                commonName: "Swiss cheese plant",
                scientificName: "Monstera deliciosa",
                confidence: 93,
                alternatives: [],
                distinguishingTraits: ["Split leaves"]
            ),
            condition: PlantConditionResult(
                healthScore: 88,
                healthBand: .thriving,
                confidence: 90,
                summary: "Even green growth and strong posture.",
                positiveSigns: ["Even colour"],
                concerns: [],
                possibleCauses: [],
                nextActions: ["Keep in bright, indirect light"]
            ),
            providerName: "Grove demo",
            limitations: []
        )
        let media = ScanMediaDraft(
            id: UUID(),
            mode: .add,
            createdAt: Date(),
            fileURL: photoURL,
            pixelWidth: Int(image.size.width * image.scale),
            pixelHeight: Int(image.size.height * image.scale)
        )
        _ = try? await PendingFirstPlantStore.shared.stage(
            scanID: UUID(),
            mediaDraft: media,
            analysis: analysis,
            nickname: "Fern",
            location: "Living room"
        )
    }
}

/// A scan result pushed onto a real navigation stack.
///
/// `ScanResultView` only has a way out through the bar Back control that the
/// stack supplies. Hosting it as a stack root drew the error state with no exit
/// at all, which was a capture artefact, not the app's presentation.
private struct PushedScanResultHost: View {
    @State private var path: [AppRoute]

    init(mode: ScanMode) {
        _path = State(initialValue: [.scanResult(mode)])
    }

    var body: some View {
        NavigationStack(path: $path) {
            Color.clear
                .navigationTitle("Scan")
                .withAppDestinations(path: $path)
        }
    }
}

/// Test-only stand-in for the launch catalogue: GBP, en_GB, £34.99 a year with
/// a seven-day free trial against £6.99 a month with none. Never app data.
private enum PaywallFixture {
    static func catalogue(trial: Bool) -> [GrovePremiumStore.Plan: Package] {
        [
            .yearly: package(.yearly, product(
                id: GrovePremiumStore.Plan.yearly.defaultProductID,
                price: 34.99,
                display: "£34.99",
                period: SubscriptionPeriod(value: 1, unit: .year),
                trial: trial ? freeTrial(days: 7) : nil
            )),
            .monthly: package(.monthly, product(
                id: GrovePremiumStore.Plan.monthly.defaultProductID,
                price: 6.99,
                display: "£6.99",
                period: SubscriptionPeriod(value: 1, unit: .month)
            ))
        ]
    }

    /// Eligibility mirrors `PremiumStoreTests`: the discount the product
    /// carries is the one this Apple account can redeem.
    static func eligibleFreeTrials(
        in catalogue: [GrovePremiumStore.Plan: Package]
    ) -> [GrovePremiumStore.Plan: StoreProductDiscount] {
        guard let trial = catalogue[.yearly]?.storeProduct.introductoryDiscount else { return [:] }
        return [.yearly: trial]
    }

    private static func product(
        id: String,
        price: Decimal,
        display: String,
        period: SubscriptionPeriod,
        trial: TestStoreProductDiscount? = nil
    ) -> StoreProduct {
        TestStoreProduct(
            localizedTitle: "Grove Premium",
            price: price,
            currencyCode: "GBP",
            localizedPriceString: display,
            productIdentifier: id,
            productType: .autoRenewableSubscription,
            localizedDescription: "Grove Premium",
            subscriptionGroupIdentifier: "grove.premium",
            subscriptionPeriod: period,
            isFamilyShareable: false,
            introductoryDiscount: trial,
            discounts: [],
            locale: Locale(identifier: "en_GB")
        ).toStoreProduct()
    }

    private static func package(
        _ plan: GrovePremiumStore.Plan,
        _ product: StoreProduct
    ) -> Package {
        Package(
            identifier: plan.rawValue,
            packageType: plan.packageType,
            storeProduct: product,
            presentedOfferingContext: PresentedOfferingContext(offeringIdentifier: "default"),
            webCheckoutUrl: nil
        )
    }

    private static func freeTrial(days: Int) -> TestStoreProductDiscount {
        TestStoreProductDiscount(
            identifier: "trial",
            price: 0,
            localizedPriceString: "£0.00",
            paymentMode: .freeTrial,
            subscriptionPeriod: SubscriptionPeriod(value: days, unit: .day),
            numberOfPeriods: 1,
            type: .introductory
        )
    }
}
