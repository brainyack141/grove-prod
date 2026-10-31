import Foundation
import Observation
import SwiftUI

/// Drives the signed-out personalization flow. Holds the current step, the
/// chosen auth method, and the quiz answers collected along the way. Answers
/// are drafted to `UserDefaults` after every mutation so a killed app resumes
/// where the user left off, and are handed to `SessionService` on completion.
@MainActor
@Observable
final class OnboardingModel {
    /// Steps the funnel can be *at*. Not every case is reachable: the ones
    /// marked retired were cut from the flow but must keep existing, because
    /// `Draft` encodes this enum by name and a draft written by an older build
    /// still names them. Deleting a case makes that draft fail to decode, and
    /// `restoreDraft` would silently discard every answer the user had given.
    ///
    /// `orderedSteps` decides what is live; `restoreDraft` maps each retired
    /// case onto its replacement.
    enum Step: String, Hashable, Codable {
        case welcome
        case explore
        /// The default new-account route proves Grove's value with the user's
        /// own plant before asking for identity or payment.
        case firstPlantScan
        /// The payoff after the scan: Sprout names the plant beside its photo
        /// and the three facts its reading settled.
        case firstPlantDetails
        /// Which room the first plant lives in, written onto the staged plant.
        case firstPlantRoom
        /// Where an account is actually created. It sits after a real plant
        /// result on the default route and after the short quiz on the manual
        /// route, so identity protects work rather than preceding value.
        case signIn
        /// The provider authentication worked, but this identity did not have a
        /// Grove account before the attempt. This explicit handoff keeps sign-in
        /// from silently turning into onboarding.
        case accountNotFound
        case emailEntry
        case emailVerification
        case name
        case experience
        /// Retired — folded into the plan the store derives from real plants.
        case collectionSize
        case environment
        /// Retired — replaced by the single-answer `challenge` step.
        case overcome
        case challenge
        /// The Grove-wide geographic home used for weather, daylight, and
        /// travel-aware care. Unlike `environment` (indoors/outdoors), this is
        /// an exact place, asked in context after the room and skippable.
        case location
        /// Retired — kept so drafts written by older builds still decode.
        case buildingPlan
        /// Retired — signup now opens Today as soon as authentication succeeds.
        case planReveal
        /// Retired — the permission prompt moved to first real use.
        case notifications
        /// Retired — the Premium offer used to stand between the finished setup
        /// and account creation, which asked for money from someone who had
        /// seen one screen and whose plant was not saved yet. It now waits for
        /// a session of real use; see `GrovePremiumOfferPresenter`.
        case paywall
    }

    /// Which of the two doors off the welcome screen the person took. A new
    /// account earns its way to the sign-in step through the quiz; someone who
    /// already has a Grove goes straight there and never sees the questions.
    enum Route: String, Codable {
        case newAccount
        /// The escape hatch for someone without a plant nearby. This preserves
        /// the short setup flow without making it the default first impression.
        case manual
        case returning
    }

    /// The physical direction used when the container transitions between
    /// steps. Keeping it beside `step` means every navigation action updates
    /// the destination and its animation from the same source of truth.
    enum NavigationDirection {
        case forward
        case backward
    }

    var step: Step = .welcome
    var route: Route = .newAccount
    var authMethod: OnboardingAuthMethod?
    private(set) var navigationDirection: NavigationDirection = .forward
    /// Set from the environment by the container. Navigation is owned by this
    /// model, so this is where animated state changes must honour Reduce Motion.
    var prefersReducedMotion = false
    /// True when the person came in through "I already have a Grove", signed in
    /// successfully, learned there was no account, and explicitly accepted the
    /// sign-up offer. `SessionService` is holding the authenticated session, so
    /// the funnel must never ask them to sign in a second time. Deliberately not
    /// persisted: the held session dies with the process, so a relaunch has to
    /// send them back to the gate.
    private(set) var arrivedFromSignIn = false

    // Auth placeholders
    var email: String = ""
    var verificationCode: String = ""
    /// A short, human explanation shown on the capture step when the funnel had
    /// to send someone back there — a staged plant that vanished, or a damaged
    /// handoff. `session.signInError` cannot carry it: the container clears the
    /// account-gate error on the very step change that performs the recovery,
    /// and the scan screen never rendered it anyway. Nil means nothing to say.
    var scanRecoveryNotice: String?

    // Personalization answers
    var firstName: String = ""
    var experience: String?
    var collectionSize: String?
    var environment: String?
    var overcome: Set<String> = []
    var challenge: String?
    var location: GroveLocation?

    private let storage: UserDefaults
    private static let draftKey = "grove.onboarding.draft.v1"

    /// Debug-only: drops the sign-in step out of the funnel so a UI test that
    /// pre-stamps an auth method can walk the quiz through to the signed-in app.
    /// Every provider sheet is out of process, so a test cannot pass that step.
    private var skipsSignInStep = false

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        // A returning sign-in never calls `completed()`, so a step timer left by
        // an earlier signed-out visit would otherwise measure hours or days when
        // the next funnel starts. A fresh model is a fresh funnel.
        OnboardingAnalytics.beginSession()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-GroveResetOnboarding") {
            storage.removeObject(forKey: Self.draftKey)
            storage.removeObject(forKey: GroveDefaults.firstPlantActivationPending)
            storage.removeObject(forKey: GroveDefaults.firstPlantAutoScanPresented)
            // Keep a reset run deterministic. Onboarding now opens the guided
            // camera directly and stamps this flag itself; ordinary scans still
            // use it for their on-demand tips lifecycle.
            storage.removeObject(forKey: GroveDefaults.hasSeenScanTips)
        }
        // Every provider sheet is out of process, so a UI test cannot walk
        // through sign-in. This stamps the method the funnel would have
        // collected, drops that step, and starts on the quiz so the
        // answers → Today handoff stays covered. Debug-only, and
        // never reachable from the UI.
        if ProcessInfo.processInfo.arguments.contains("-GroveUITestSkipSignIn") {
            authMethod = .device
            skipsSignInStep = true
            step = .firstPlantScan
            return
        }
#endif
        restoreDraft()
    }

    /// The ordered sequence of steps for the current route and auth method.
    ///
    /// A new account sees one complete plant result and then creates an account;
    /// optional profile fields move to Today's checklist. The manual fallback
    /// offers a preview before the optional account gate. A returning person skips both routes entirely. The email path
    /// inserts its two screens directly after whichever step offered providers.
    /// Legacy cases stay in `Step` so older drafts still decode.
    var orderedSteps: [Step] {
        var steps: [Step] = [.welcome]
        if route == .returning {
            steps.append(.signIn)
            if authMethod == .email {
                steps += [.emailEntry, .emailVerification]
            }
            return steps
        }
        switch route {
        case .newAccount:
            steps += [.firstPlantScan, .firstPlantDetails, .firstPlantRoom, .location]
        case .manual:
            steps += [.explore]
        case .returning:
            break
        }
        // Two ways to reach the last question already holding a credential: a
        // debug UI test that stamped one (provider sheets are out of process and
        // cannot be automated), and someone who signed in on the returning route
        // and turned out to be new. Both end on the retired `planReveal` value
        // used as an invisible completion sentinel — `OnboardingContainerView`
        // establishes the session the moment it is reached and never renders the
        // former reveal page. Appending `.signIn` here instead would ask a person
        // who has just signed in to do it again.
        if skipsSignInStep || arrivedFromSignIn {
            steps.append(.planReveal)
            return steps
        }
        steps.append(.signIn)
        if authMethod == .email {
            steps += [.emailEntry, .emailVerification]
        }
        return steps
    }

    var isFirstStep: Bool {
        orderedSteps.first == step
    }

    var trimmedFirstName: String {
        SessionService.normalizedDisplayName(firstName)
    }

    /// The collected answers as the durable domain value handed to
    /// `SessionService.completeOnboarding` and stored on `UserProfile`.
    var plan: GrovePlan {
        GrovePlan(
            experience: experience,
            // The exact count becomes known as plants are added. Asking for an
            // estimate before Grove has proved itself made the funnel longer
            // and produced a value the store immediately superseded.
            collectionSize: nil,
            environment: environment,
            focuses: effectiveFocuses,
            challenge: challenge
        )
    }

    /// Older drafts may carry the former pick-three answers. New flows derive a
    /// single honest focus from the one problem the person asked Grove to solve
    /// first, rather than forcing them to claim three pains.
    private var effectiveFocuses: [String] {
        if !overcome.isEmpty { return Array(overcome) }
        switch challenge {
        case "watering": return ["watering"]
        case "light": return ["light"]
        case "pests": return ["pests"]
        case "id": return ["unknown-needs"]
        default: return []
        }
    }

    /// The welcome screen's primary action: photograph one real plant and see
    /// its baseline before Grove asks for an account or presents Premium.
    func beginFirstPlant() {
        // The no-plant route can hand back here through "Use a plant photo".
        // Someone who signed in, learned there was no grove, and accepted
        // sign-up is still holding that session, so it is kept exactly as
        // `beginManualSetup` keeps it; dropping it asked them to sign in twice.
        let keepsHeldSignup = arrivedFromSignIn && authMethod != nil
        route = .newAccount
        if !keepsHeldSignup {
            authMethod = nil
            arrivedFromSignIn = false
        }
        clearManualPersonalization()
        navigationGeneration += 1
        navigationDirection = .forward
        move(to: .firstPlantScan)
        persistDraft()
    }

    /// A plant is not always within reach. This route keeps entry possible
    /// without weakening the scan-first default or pretending a sample result
    /// belongs to the user.
    func beginManualSetup() {
        let keepsHeldSignup = arrivedFromSignIn && authMethod != nil
        route = .manual
        scanRecoveryNotice = nil
        if !keepsHeldSignup {
            authMethod = nil
            arrivedFromSignIn = false
        }
        navigationGeneration += 1
        navigationDirection = .forward
        move(to: .explore)
        persistDraft()
    }

    /// Kept for source compatibility with older tests and call sites. The quiz
    /// is now explicitly the manual fallback, not the welcome screen's default.
    func beginQuiz() {
        beginManualSetup()
    }

    /// The welcome screen's secondary action, for someone who already has a
    /// Grove: straight to the providers, no quiz.
    func signInToExistingAccount() {
        route = .returning
        authMethod = nil
        arrivedFromSignIn = false
        scanRecoveryNotice = nil
        navigationGeneration += 1
        navigationDirection = .forward
        move(to: .signIn)
        persistDraft()
    }

    func startFlow(method: OnboardingAuthMethod) {
        authMethod = method
        advance()
    }

    /// Provider authentication succeeded, but the identity had no Grove account
    /// before this attempt. Pause on a clear handoff instead of silently turning
    /// the sign-in button into onboarding.
    func offerSignup(method: OnboardingAuthMethod) {
        authMethod = method
        arrivedFromSignIn = false
        navigationGeneration += 1
        navigationDirection = .forward
        move(to: .accountNotFound)
    }

    /// The person accepted the handoff. Carry the already-authenticated session
    /// into sign-up, collect the missing profile and plan, and never ask for the
    /// same provider credential twice.
    func acceptSignupOffer() {
        guard step == .accountNotFound, authMethod != nil else { return }
        route = .newAccount
        arrivedFromSignIn = true
        clearManualPersonalization()
        navigationGeneration += 1
        navigationDirection = .forward
        move(to: .firstPlantScan)
        persistDraft()
    }

    /// Keep sign-in as sign-in when the provider identity was not the one the
    /// person expected. `OnboardingContainerView` clears the held session when
    /// this returns to the provider screen.
    func useDifferentSignIn() {
        route = .returning
        authMethod = nil
        arrivedFromSignIn = false
        scanRecoveryNotice = nil
        navigationGeneration += 1
        navigationDirection = .backward
        move(to: .signIn)
        persistDraft()
    }

    /// Incremented on every navigation so a pending `autoAdvance` from an
    /// earlier visit to the same step value cannot fire after the user has
    /// navigated away and back.
    private var navigationGeneration = 0

    func advance() {
        guard let index = orderedSteps.firstIndex(of: step),
              index + 1 < orderedSteps.count else { return }
        navigationGeneration += 1
        navigationDirection = .forward
        move(to: orderedSteps[index + 1])
        persistDraft()
    }

    /// Advances shortly after a single-select choice so the selection state is
    /// visible before the transition. No-ops if the user navigated
    /// (back button, double tap) in the meantime.
    func autoAdvance(after delay: Duration = .milliseconds(300)) {
        let generation = navigationGeneration
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.navigationGeneration == generation else { return }
            self.advance()
        }
    }

    func back() {
        guard let index = orderedSteps.firstIndex(of: step), index > 0 else { return }
        let previous = orderedSteps[index - 1]
        navigationGeneration += 1
        navigationDirection = .backward
        move(to: previous)
        // Returning to the front door drops the choice made there, so the two
        // routes can't be half-entered at once — including a sign-in that had
        // already succeeded, since walking back to the welcome screen is the one
        // way to say "not that account".
        if previous == .welcome {
            route = .newAccount
            authMethod = nil
            arrivedFromSignIn = false
        }
        persistDraft()
    }

    /// The normal step array intentionally has no duplicate result page. Back
    /// from the account gate is the one time a person reasonably wants that
    /// review, so it is an explicit destination rather than a funnel step.
    func backFromAccountGate() {
        guard step == .signIn else { return }
        back()
    }

    /// Leaves the optional review and returns to the account gate without
    /// depending on `orderedSteps`, where that review deliberately does not
    /// appear.
    func returnToAccountGate() {
        guard route == .newAccount else { return }
        navigationGeneration += 1
        navigationDirection = .forward
        move(to: .signIn)
        persistDraft()
    }

    /// Abandons the staged baseline so the review screen can take a new photo.
    func restartFirstPlantScan() {
        guard route == .newAccount else { return }
        scanRecoveryNotice = nil
        navigationGeneration += 1
        navigationDirection = .backward
        move(to: .firstPlantScan)
        persistDraft()
    }

    /// Whether the current step's primary button should be enabled.
    var canAdvanceFromCurrentStep: Bool {
        switch step {
        case .welcome, .explore, .firstPlantScan, .firstPlantDetails, .firstPlantRoom, .signIn, .accountNotFound, .buildingPlan, .planReveal: true
        case .emailEntry: isEmailValid
        case .emailVerification:
            verificationCode.count == 6
                && Self.sanitizedVerificationCode(verificationCode) == verificationCode
        case .name:
            !trimmedFirstName.isEmpty
                && firstName.precomposedStringWithCanonicalMapping.unicodeScalars.count
                    <= SessionService.maxDisplayNameLength
        case .experience: experience != nil
        case .collectionSize: collectionSize != nil
        case .environment: environment != nil
        case .overcome: !overcome.isEmpty && overcome.count <= GrovePlanCatalog.focusPickLimit
        case .challenge: challenge != nil
        case .location: location != nil
        case .notifications, .paywall: true
        }
    }

    var isEmailValid: Bool {
        Self.isValidEmailAddress(normalizedEmail)
    }

    static func isValidEmailAddress(_ normalizedEmail: String) -> Bool {
        guard normalizedEmail.count <= 254 else { return false }
        let parts = normalizedEmail.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = String(parts[0])
        let domain = String(parts[1])
        let allowedLocal = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".!#$%&'*+-/=?^_`{|}~")
        )
        guard !local.isEmpty, local.count <= 64,
              !local.hasPrefix("."), !local.hasSuffix("."), !local.contains(".."),
              local.unicodeScalars.allSatisfy({ allowedLocal.contains($0) }),
              domain.count <= 253, !domain.hasPrefix("."), !domain.hasSuffix(".") else {
            return false
        }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let topLevel = labels.last,
              topLevel.count >= 2,
              topLevel.allSatisfy(\.isLetter) || topLevel.hasPrefix("xn--") else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Supabase OTPs are ASCII decimal digits. `Character.isNumber` also
    /// accepts Arabic-Indic digits, superscripts, and other numeric Unicode;
    /// allowing those made a six-cell code look complete while the server could
    /// only reject it. Paste and autofill are capped here as well as in the UI.
    static func sanitizedVerificationCode(_ value: String) -> String {
        String(value.compactMap { character -> Character? in
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first,
                  (48...57).contains(Int(scalar.value)) else { return nil }
            return character
        }.prefix(6))
    }

    // MARK: - Draft persistence

    private struct Draft: Codable {
        /// Missing on drafts written before the value-first flow. Those drafts
        /// resume on the manual route so a person is never dropped into a scan
        /// after already answering setup questions.
        var flowVersion: Int?
        var step: Step
        /// Optional so a draft written before the routes existed still decodes;
        /// those drafts are all new-account funnels.
        var route: Route?
        var authMethod: OnboardingAuthMethod?
        /// Optional so drafts written before email recovery was added decode.
        var email: String?
        var firstName: String
        var experience: String?
        var collectionSize: String?
        var environment: String?
        var overcome: [String]
        var challenge: String?
        /// Optional so drafts written while location was in the funnel still
        /// decode; current builds carry it forward without making it a gate.
        var location: GroveLocation?
    }

    func persistDraft() {
        let draft = Draft(
            flowVersion: 7,
            step: step,
            route: route,
            authMethod: authMethod,
            email: normalizedEmail.isEmpty ? nil : normalizedEmail,
            firstName: firstName,
            experience: experience,
            collectionSize: collectionSize,
            environment: environment,
            overcome: overcome.sorted(),
            challenge: challenge,
            location: location
        )
        if let data = try? JSONEncoder().encode(draft) {
            storage.set(data, forKey: Self.draftKey)
        }
    }

    /// Called once onboarding hands off to a real session.
    func clearDraft() {
        storage.removeObject(forKey: Self.draftKey)
    }

    /// Establishes a newly authenticated account with the answers collected by
    /// setup. The current auth screen remains visible while provider work
    /// finishes; `RootView` then swaps directly to the signed-in Today tab.
    @discardableResult
    func completeSignup(using session: SessionService, method: OnboardingAuthMethod) async -> Bool {
        authMethod = method
        var pendingFirstPlantID: UUID?
        if route == .newAccount {
            do {
                guard let pending = try await PendingFirstPlantStore.shared.loadUnclaimed() else {
                    recoverMissingFirstPlant(
                        reason: "Your first plant is no longer saved on this iPhone. Scan it again before creating the account."
                    )
                    return false
                }
                pendingFirstPlantID = pending.plantID
            } catch {
                recoverMissingFirstPlant(reason: error.localizedDescription)
                return false
            }
        }
        // Identity providers may supply a name; email and device accounts get
        // the service's neutral "Gardener" fallback until the optional Today
        // checklist row is completed. Only manual setup collects a quiz plan,
        // so an abandoned manual attempt cannot leak answers into scan-first.
        let outcome = await session.completeOnboarding(
            method: method,
            displayName: trimmedFirstName,
            plan: route == .manual ? plan : nil,
            location: location,
            pendingFirstPlantID: pendingFirstPlantID
        )
        guard outcome == .signedIn else {
            persistDraft()
            return false
        }
        if route == .newAccount {
            OnboardingAnalytics.firstPlantActivationStarted(method: method)
        }
        // Scan-first completion is recorded after its durable plant import.
        // The no-plant route completes when its account is established.
        if route == .manual {
            storage.set(false, forKey: GroveDefaults.firstPlantActivationPending)
            storage.set(false, forKey: GroveDefaults.firstPlantAutoScanPresented)
            OnboardingAnalytics.completed(route: .manual, notificationOutcome: nil)
            GrovePremiumOffer.arm(in: storage)
        }
        clearDraft()
        return true
    }

    private func restoreDraft() {
        guard let data = storage.data(forKey: Self.draftKey),
              let draft = try? JSONDecoder().decode(Draft.self, from: data) else { return }
        firstName = draft.firstName
        experience = draft.experience
        collectionSize = draft.collectionSize
        environment = draft.environment
        overcome = Set(draft.overcome)
        challenge = draft.challenge
        location = draft.location
        email = draft.email ?? ""
        authMethod = draft.authMethod
        route = draft.route ?? .manual

        // The returning route carries nothing worth resuming — it is one screen
        // in front of a provider sheet — so it always reopens at the front door.
        if route == .returning {
            step = .welcome
            route = .newAccount
            authMethod = nil
            clearManualPersonalization()
            storage.removeObject(forKey: Self.draftKey)
            return
        }

        // Every provider credential is transient — the pending Apple and Google
        // credentials and the verified email session on `SessionService` all die
        // with the process. Completion correctly refuses a missing credential,
        // so retaining the stamped method would only strand the person at the
        // last step with no way to finish. A provider method therefore never
        // survives a relaunch; the restored step decides when to ask again.
        authMethod = nil

        let isValueFirstDraft = (draft.flowVersion ?? 0) >= 2 && route == .newAccount

        switch draft.step {
        case .welcome:
            step = .welcome
        case .explore:
            route = .manual
            step = .explore
        case .firstPlantScan:
            route = .newAccount
            step = .firstPlantScan
            OnboardingAnalytics.resumed(at: .firstPlantScan)
        case .firstPlantDetails, .firstPlantRoom:
            route = .newAccount
            step = draft.step
            OnboardingAnalytics.resumed(at: draft.step)
        case .name:
            route = isValueFirstDraft ? .newAccount : .manual
            let resumed = route == .newAccount ? Step.signIn : manualResumeStep
            step = resumed
            OnboardingAnalytics.resumed(at: resumed)
        // Preserve legacy answers, but never resume retired setup questions.
        case .experience, .collectionSize, .environment, .overcome, .challenge:
            route = .manual
            let resumed = manualResumeStep
            step = resumed
            OnboardingAnalytics.resumed(at: resumed)
        case .location:
            route = isValueFirstDraft ? .newAccount : .manual
            let resumed = route == .newAccount ? Step.location : manualResumeStep
            step = resumed
            OnboardingAnalytics.resumed(at: resumed)
        // At or past the gate: the credential is gone, so sign in again. The
        // answers survive, because the quiz now sits before this point. A draft
        // written while the retired paywall step was live resumes here too —
        // that step is what the account gate now directly follows.
        case .signIn, .accountNotFound, .emailEntry, .emailVerification, .buildingPlan, .planReveal, .notifications, .paywall:
            route = isValueFirstDraft ? .newAccount : .manual
            let resumed = route == .newAccount ? Step.signIn : manualResumeStep
            step = resumed
            OnboardingAnalytics.resumed(at: resumed)
        }
    }

    /// Returns an invisible completion sentinel to the visible account gate if
    /// its transient credential disappeared unexpectedly.
    func recoverFromCompletionFailure() {
        arrivedFromSignIn = false
        authMethod = nil
        navigationGeneration += 1
        navigationDirection = .backward
        move(to: .signIn)
        persistDraft()
    }

    /// A scan-first route may outlive its protected media only if storage was
    /// externally cleared or corrupted. Never continue to a paywall or account
    /// gate for a plant Grove can no longer deliver.
    func recoverMissingFirstPlant(reason: String? = nil) {
        guard route == .newAccount else { return }
        scanRecoveryNotice = reason
            ?? "Grove couldn't find your saved plant. Scan it again to keep it."
        navigationGeneration += 1
        navigationDirection = .backward
        move(to: .firstPlantScan)
        persistDraft()
    }

    private func move(to destination: Step) {
        if prefersReducedMotion {
            step = destination
        } else {
            withAnimation(GroveMotion.settle) { step = destination }
        }
    }

    private func clearManualPersonalization() {
        firstName = ""
        experience = nil
        collectionSize = nil
        environment = nil
        overcome = []
        challenge = nil
        location = nil
        email = ""
        verificationCode = ""
        scanRecoveryNotice = nil
    }

    /// Cleared once the person has a fresh capture in hand, or after the notice
    /// has been read on the capture step.
    func clearScanRecoveryNotice() {
        guard scanRecoveryNotice != nil else { return }
        scanRecoveryNotice = nil
    }

    private var manualResumeStep: Step {
        .signIn
    }
}

/// Account-scoped, durable progress. Missing means an existing account, not new setup.
enum PostSignupSetupProgress {
    static func key(_ accountID: String) -> String { "grove.profile-setup.v1.\(accountID)" }
    static func arm(accountID: String, storage: UserDefaults) {
        guard storage.object(forKey: key(accountID)) == nil else { return }
        storage.set(1, forKey: key(accountID))
    }
    static func isPending(accountID: String, storage: UserDefaults = .standard) -> Bool {
        (1...2).contains(storage.integer(forKey: key(accountID)))
    }
}
