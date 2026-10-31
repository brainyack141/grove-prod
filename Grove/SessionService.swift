import AuthenticationServices
import CryptoKit
import Foundation
import Observation

enum AccountMode: String, Codable, Hashable {
    case demo
    case apple
    case google
    case email
    /// A Grove that exists only on this device. This is an explicit onboarding
    /// choice, never a fallback for a provider sign-in: presenting a verified
    /// Apple/Google/email identity while silently creating something else is an
    /// account-integrity failure, not an offline feature.
    ///
    /// The raw value stays `"guest"` deliberately. It is persisted inside
    /// `UserSession` in `UserDefaults`, and a Grove is keyed by its account id:
    /// renaming the wire format would fail to decode every existing local
    /// session, sign those users out, and strand groves whose `local-<uuid>` id
    /// nothing can ever name again.
    case local = "guest"

    /// Modes whose account lives in Supabase (`auth.users`) rather than only on
    /// this device. Only these sessions carry tokens and sync to the backend.
    var isSupabaseBacked: Bool {
        switch self {
        case .apple, .google, .email: true
        case .demo, .local: false
        }
    }
}

struct UserSession: Codable, Hashable {
    var accountID: String
    var mode: AccountMode
    var displayName: String
    /// The plan collected during onboarding, carried here only long enough for
    /// `GroveStore.activate` to write it onto the profile. It rides on the
    /// session because the session is persisted at `establish` time, so a kill
    /// between finishing onboarding and opening the grove cannot lose the
    /// answers the user just gave. Nil for every session
    /// that did not just come through onboarding.
    var plan: GrovePlan? = nil
    /// A Grove home carried from older onboarding drafts or an existing account.
    /// Current new accounts may leave it nil and set it from Today's checklist.
    var location: GroveLocation? = nil
    /// Authorizes exactly one account bootstrap to claim the neutral first
    /// plant staged before sign-in. Returning sign-ins and account switches
    /// leave this nil, so they can never inherit an abandoned onboarding photo.
    var pendingFirstPlantID: UUID? = nil

    /// An isolated local account available only in Simulator builds.
    var isSimulatorTroubleshooting: Bool {
        #if targetEnvironment(simulator)
        mode == .demo && accountID == "simulator-troubleshooting-v1"
        #else
        false
        #endif
    }
}

enum SessionState: Equatable {
    case signedOut
    case signedIn(UserSession)
}

/// Account path taken during onboarding. Provider paths are verified by
/// Supabase before a session is established; `.device` is the local-only
/// path, which a shipping build never offers — it is reachable only from a
/// build with no Supabase credentials, and from groves created before the
/// choice was withdrawn.
enum OnboardingAuthMethod: String, Codable, Hashable, CaseIterable {
    case apple
    case google
    case email
    case device

    /// Whether a draft resumed after relaunch has to send the user back through
    /// sign-in before it can finish.
    ///
    /// True for every provider method, because `completeOnboarding` cannot
    /// recover its credential after process death: pending Apple/Google tokens
    /// and the verified email session are intentionally held in memory only.
    /// A resumed provider draft must therefore authenticate again. The explicit
    /// device-only path needs no external credential and can resume safely.
    ///
    /// Exhaustive on purpose: a new provider must decide this deliberately
    /// rather than inherit a default that loses accounts.
    var needsReauthenticationOnResume: Bool {
        switch self {
        case .apple, .google, .email: true
        case .device: false
        }
    }

    /// The account mode a completed sign-in through this provider produces.
    var accountMode: AccountMode {
        switch self {
        case .apple: .apple
        case .google: .google
        case .email: .email
        case .device: .local
        }
    }
}

@MainActor
@Observable
final class SessionService {
    static let maxDisplayNameLength = 80

    static func normalizedDisplayName(_ value: String) -> String {
        let unsafeFormatting = CharacterSet.controlCharacters.union(
            CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
        )
        let cleaned = value.unicodeScalars.map { scalar in
            unsafeFormatting.contains(scalar) ? " " : String(scalar)
        }.joined()
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let canonical = collapsed.precomposedStringWithCanonicalMapping
        // JavaScript spread and PostgreSQL char_length both count Unicode code
        // points, not Swift grapheme clusters. Cap the same unit everywhere so
        // combining sequences cannot pass the app and fail the profile write.
        return String(canonical.unicodeScalars.prefix(maxDisplayNameLength))
    }

    enum CompletionOutcome: Equatable {
        case signedIn
        case failed
    }

    var state: SessionState
    var signInError: String?

    /// Apple credential captured on the welcome screen. The session is not
    /// established until the personalization flow finishes, so the funnel is
    /// identical for every auth method.
    struct PendingAppleCredential {
        let userID: String
        let displayName: String?
        /// The signed OpenID token Supabase exchanges for a session, and the raw
        /// nonce it was bound to. `identityToken` is nil only if Apple declined
        /// to vend one, in which case completion fails without creating an
        /// unrelated local account.
        let identityToken: String?
        let rawNonce: String?
    }
    private(set) var pendingApple: PendingAppleCredential?

    /// Google identity token captured on the welcome screen, exchanged for a
    /// Supabase session when the personalization flow finishes — mirroring the
    /// Apple flow. Google does not attach a nonce.
    struct PendingGoogleCredential {
        /// Google's stable subject id, retained for provider diagnostics only.
        /// Grove uses the verified Supabase uuid as the account key.
        let userID: String?
        let idToken: String
        let displayName: String?
    }
    private(set) var pendingGoogle: PendingGoogleCredential?

    /// Supabase session established by a verified email code, held until the
    /// personalization flow finishes — mirroring the Apple and Google funnels.
    private(set) var pendingEmail: SupabaseAuthClient.Session?

    /// A Supabase session obtained on the returning route when that provider
    /// identity did not have a Grove account before this sign-in. The provider
    /// authentication succeeded, but the id-token grant created the account just
    /// now; the person must explicitly accept the sign-up handoff before the
    /// funnel collects a plan and `completeOnboarding` finishes onto *this*
    /// account.
    ///
    /// The whole session is held rather than the provider token that produced
    /// it: an Apple identity token expires within minutes and the quiz can
    /// easily outlast it, so re-exchanging at the end could reject a person who
    /// had already signed in successfully. Its access-token deadline is absolute
    /// and remains the one captured when Auth answered; completion never extends
    /// that bearer locally.
    struct PendingSignupSession {
        let session: SupabaseAuthClient.Session
        let mode: AccountMode
        let displayName: String
    }
    private(set) var pendingSignup: PendingSignupSession?

    /// Withheld at launch, ahead of the mail infrastructure it needs.
    ///
    /// Grove's Supabase project sends auth mail through a personal Gmail
    /// account with hCaptcha switched off, and its project-wide ceiling of 60
    /// sign-in emails an hour is the same as its per-address cooldown. Two
    /// things follow. A launch busy enough to be worth having exhausts that
    /// hourly budget and locks out everyone still waiting for a code — and
    /// since the anon key ships inside the binary, `POST /auth/v1/otp` is an
    /// open endpoint that sends mail in Grove's name from a personal address
    /// that can be suspended for it.
    ///
    /// Raising the ceiling is not the fix; it only moves the failure onto the
    /// Gmail account. Apple and Google carry the funnel meanwhile, and Hide My
    /// Email means nobody has to surrender a real address to use Grove.
    ///
    /// Flip this back to `true` once Supabase Auth sends from a Grove-owned
    /// domain (Resend or similar) with captcha enabled — the whole email flow
    /// below is intact and tested, and needs nothing else to come back.
    private static let isEmailSignInEnabled = false

    /// Whether this build can actually verify an email address. Without a
    /// configured Supabase project there is no service to send or check a code,
    /// and the flow previously accepted *any* six digits — so the option is
    /// hidden rather than faked.
    @MainActor
    static var isEmailSignInAvailable: Bool {
        isEmailSignInEnabled && SupabaseAuthClient.fromBundle() != nil
    }

    /// Apple, Google and email all finish through the same Supabase project.
    /// A build without that project may still offer the explicit device-only
    /// path, but it must not draw provider buttons that can never create the
    /// account their labels promise.
    @MainActor
    static var isAccountSignInAvailable: Bool {
        SupabaseAuthClient.fromBundle() != nil
    }

    /// Device-only creation is a development escape hatch, never a production
    /// fallback for malformed/missing account configuration. Existing local
    /// Groves remain readable in every build; only creating a new one is gated.
    @MainActor
    static var isDeviceOnlySignupAvailable: Bool {
#if DEBUG
        !isAccountSignInAvailable
#else
        false
#endif
    }

    /// Sends a one-time code to `email`. Returns false (with `signInError` set)
    /// when the code could not be sent, so the flow stays on the entry screen
    /// instead of advancing to a code screen that can never succeed.
    ///
    /// `createAccount` is false on the returning route: the OTP endpoint signs
    /// *up* as readily as it signs in, and "I already have a Grove" must never
    /// quietly mint an empty account the person mistakes for lost plants. The
    /// unknown-address rejection Supabase sends back in that mode becomes a
    /// plain "no grove for that address" here.
    func sendEmailCode(to email: String, createAccount: Bool = true) async -> Bool {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let authenticationGeneration = pendingAuthenticationGeneration
        guard let client = authClientProvider() else {
            signInError = "Email sign-in isn't switched on in this build. Use Apple or Google instead."
            return false
        }
        do {
            try await client.sendEmailCode(to: address, createUser: createAccount)
            guard authenticationIsCurrent(authenticationGeneration) else { return false }
            signInError = nil
            return true
        } catch {
            guard authenticationIsCurrent(authenticationGeneration) else { return false }
            if !createAccount, Self.isUnknownReturningEmail(error) {
                // Deliberately indistinguishable from a real send. Revealing
                // whether an address has a Grove account lets anyone enumerate
                // accounts from the signed-out screen.
                signInError = nil
                return true
            } else {
                signInError = Self.message(for: error, fallback: "Grove couldn't send that code. Check the address and try again.")
            }
            return false
        }
    }

    /// GoTrue has used several messages for an unknown email with
    /// `create_user: false`. Keying privacy to one English word made a wording
    /// change turn account enumeration back on, so use the stable client-error
    /// status class while still surfacing throttling and server outages.
    private static func isUnknownReturningEmail(_ error: Error) -> Bool {
        guard case SupabaseAuthClient.AuthError.provider(_, let status) = error else { return false }
        return [400, 404, 422].contains(status)
    }

    /// Verifies an emailed code. Returns false (with `signInError` set) when the
    /// code is wrong or expired — the flow no longer advances on any six digits.
    func verifyEmailCode(email: String, code: String) async -> Bool {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let authenticationGeneration = pendingAuthenticationGeneration
        guard token.count == 6,
              token.unicodeScalars.allSatisfy({ (48...57).contains(Int($0.value)) }) else {
            signInError = "Enter the six digits from your email."
            return false
        }
        guard let client = authClientProvider() else {
            signInError = "Email sign-in isn't switched on in this build. Use Apple or Google instead."
            return false
        }
        do {
            let verified = try await client.verifyEmailCode(email: address, code: token)
            guard authenticationIsCurrent(authenticationGeneration) else { return false }
            pendingEmail = verified
            signInError = nil
            return true
        } catch {
            guard authenticationIsCurrent(authenticationGeneration) else { return false }
            pendingEmail = nil
            signInError = Self.message(for: error, fallback: "That code didn't work. Check it and try again.")
            return false
        }
    }

    private static func message(for error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }

    /// Supabase access token for the current session when the account is backed
    /// by Supabase Auth. Access tokens are short-lived, so this stays in memory;
    /// the long-lived refresh token goes to the Keychain via
    /// `SupabaseSessionStore` and is traded for a fresh one on launch by
    /// `restoreProviderSession()`. See SSO_SETUP.md.
    private(set) var supabaseAccessToken: String?

    /// True when this account is provider-backed but no longer holds a
    /// credential the server will accept — the refresh token was rotated away,
    /// revoked, or refused.
    ///
    /// The state used to be invisible: the app stayed "signed in", sync went
    /// quiet, and the only symptom was every server request failing. Account
    /// deletion made it unsurvivable, because deletion is the one action that
    /// cannot fall back to the local copy. Settings surfaces this so the way
    /// out — sign in again — is on screen instead of inferred.
    private(set) var needsReauthentication = false

    /// Deduplicates concurrent refreshes so parallel API calls share one
    /// refresh-token exchange (GoTrue rotates the token on every use).
    private var refreshTask: Task<SupabaseTokenSet?, Never>?
    private var refreshTaskAccountID: String?
    private var refreshTaskGeneration: Int?
    /// Invalidates any provider refresh that crossed an account or credential
    /// boundary while its network request was suspended.
    private var providerCredentialGeneration = 0

    /// Invalidates interactive Apple/Google/email work when the person backs
    /// out, changes provider, dismisses reauthentication, or starts over.
    /// Task cancellation is advisory; a response that was already delivered
    /// can still resume, so account establishment also checks this generation.
    private var pendingAuthenticationGeneration = 0

    /// Same protection for the anonymous Auth session used by legacy
    /// device-only Groves for plant analysis. Multiple scans submitted close
    /// together must not mint identities or race refresh-token rotation.
    private var localAnalysisRefreshTask: Task<BotanistTokenSet?, Never>?

    /// Independent refresh rotation for the signed-out first-scan identity.
    /// It cannot share `localAnalysisRefreshTask`: that task is keyed to an
    /// existing Grove account, while this one intentionally exists before any
    /// account.
    private var onboardingGuestRefreshTask: Task<OnboardingGuestTokenSet?, Never>?
    private var onboardingGuestCredentialGeneration = 0

    /// Raw nonce for the in-flight Apple request; the hashed form is sent to
    /// Apple and the raw form to Supabase so the token stays bound to this
    /// specific sign-in.
    private var currentAppleNonce: String?
    /// OAuth state echoed by Apple, used to associate a system callback with
    /// the exact request whose nonce is still active.
    private var currentAppleState: String?

    private let storage: UserDefaults
    private let storageKey = "grove.user.session.v1"
    @ObservationIgnored private let authClientProvider: @MainActor () -> SupabaseAuthClient?

    init(
        storage: UserDefaults = .standard,
        authClientProvider: @escaping @MainActor () -> SupabaseAuthClient? = { SupabaseAuthClient.fromBundle() }
    ) {
        self.storage = storage
        self.authClientProvider = authClientProvider
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-GroveResetFirstPlantActivation") {
            storage.removeObject(forKey: GroveDefaults.firstPlantActivationPending)
            storage.removeObject(forKey: GroveDefaults.firstPlantAutoScanPresented)
        }
        if arguments.contains("-GrovePreviewSignedOut") {
            state = .signedOut
            return
        }
        if let flagIndex = arguments.firstIndex(of: "-GroveUITestDemoAccount") {
            let suppliedIDIndex = arguments.index(flagIndex, offsetBy: 1, limitedBy: arguments.index(before: arguments.endIndex))
            let suppliedID = suppliedIDIndex.map { arguments[$0] } ?? UUID().uuidString
            state = .signedIn(
                UserSession(
                    accountID: "ui-test-demo-\(suppliedID)",
                    mode: .demo,
                    displayName: "Alex"
                )
            )
            return
        }
        if let flagIndex = arguments.firstIndex(of: "-GroveUITestAppleAccount") {
            let suppliedIDIndex = arguments.index(flagIndex, offsetBy: 1, limitedBy: arguments.index(before: arguments.endIndex))
            let suppliedID = suppliedIDIndex.map { arguments[$0] } ?? UUID().uuidString
            state = .signedIn(
                UserSession(
                    accountID: "ui-test-apple-\(suppliedID)",
                    mode: .apple,
                    displayName: "Alex Green"
                )
            )
            return
        }
#endif
        if let data = storage.data(forKey: storageKey),
           let session = try? JSONDecoder().decode(UserSession.self, from: data) {
            var restored = session
            // Before provider exchange became mandatory, a failed Apple or
            // Google request could be persisted under the provider label while
            // actually being device-only. Preserve its account id (and thus
            // its on-device Grove), but migrate the mode so Settings offers
            // local deletion and warns truthfully about sign-out instead of
            // attempting server sync/deletion with an account that never
            // existed there.
            if restored.mode.isSupabaseBacked, UUID(uuidString: restored.accountID) == nil {
                restored.mode = .local
                if let migrated = try? JSONEncoder().encode(restored) {
                    storage.set(migrated, forKey: storageKey)
                }
            }
            state = .signedIn(restored)
            if restored.mode.isSupabaseBacked {
                if let tokens = SupabaseSessionStore.load(),
                   tokens.userID != restored.accountID {
                    // A crash between account transitions can leave the next
                    // local session beside the previous account's credential.
                    // It is never eligible for this Grove and must not linger.
                    SupabaseSessionStore.clear()
                }
            } else {
                SupabaseSessionStore.clear()
            }
            // A guest credential has one legitimate reason to coexist with a
            // signed-in session: that session still carries the exact pending
            // first-plant marker. If the marker was already consumed and the
            // process died before Keychain cleanup, finish the cleanup here so
            // the pre-account identity cannot become an indefinite orphan.
            if restored.pendingFirstPlantID == nil {
                OnboardingGuestSessionStore.clear()
                storage.removeObject(forKey: GroveDefaults.onboardingGuestCredentialPresent)
            }
        } else {
            state = .signedOut
            // Keychain items can outlive an app uninstall. With no matching
            // persisted session there is no account they may authenticate, so
            // clear them on the first launch after reinstall (and after any
            // corrupted-session recovery) instead of retaining orphan tokens.
            SupabaseSessionStore.clear()
            BotanistSessionStore.clear()
            // Unlike the two account credentials above, a signed-out onboarding
            // credential is valid state and must survive a normal relaunch. Its
            // UserDefaults marker does not survive an uninstall, so a missing
            // marker identifies the orphaned Keychain item that should not.
            if !storage.bool(forKey: GroveDefaults.onboardingGuestCredentialPresent) {
                OnboardingGuestSessionStore.clear()
            }
        }
    }

    var currentSession: UserSession? {
        guard case .signedIn(let session) = state else { return nil }
        return session
    }

    /// Whether signing out of the current account can be undone by signing back
    /// in.
    ///
    /// A Grove is stored under a key derived from its account id, so getting
    /// back to it means minting the same id again. Demo and provider-backed
    /// accounts resolve to a stable id (a fixed demo id or the Supabase uuid).
    /// An explicit device-only account cannot: it is keyed by a UUID minted at
    /// `establishLocalAccount`, and no provider can name it after sign-out.
    /// Settings therefore has to disclose that trade-off before the user taps.
    var canRestoreCurrentAccountAfterSignOut: Bool {
        guard let session = currentSession else { return true }
        switch session.mode {
        case .demo:
            return true
        case .local:
            return false
        case .apple, .google:
            return UUID(uuidString: session.accountID) != nil
        case .email:
            // Existing email accounts can repair a lapsed credential in place,
            // but cannot return after a full sign-out while the public email
            // entry point is disabled for sender-domain/CAPTCHA hardening.
            return Self.isEmailSignInAvailable
        }
    }

    /// The sign-in a credential repair has to reproduce: the same provider this
    /// account was created with. Nil when there is no server identity to prove.
    var reauthenticationMethod: OnboardingAuthMethod? {
        switch currentSession?.mode {
        case .apple: .apple
        case .google: .google
        case .email: .email
        case .demo, .local, .none: nil
        }
    }

    /// Finishes the personalization flow. Provider methods either establish the
    /// verified Supabase account or fail in place; they never mint a local
    /// account under a provider label. The only local path is `.device`, which
    /// onboarding offers solely when the build has no Supabase project to
    /// create an account against.
    @discardableResult
    func completeOnboarding(
        method: OnboardingAuthMethod,
        displayName: String = "",
        plan: GrovePlan? = nil,
        location: GroveLocation? = nil,
        pendingFirstPlantID: UUID? = nil
    ) async -> CompletionOutcome {
        guard !Task.isCancelled else { return .failed }
        let name = Self.normalizedDisplayName(displayName)
        // An untouched plan carries no information; storing it would only give
        // My Grove an empty card to render.
        let collectedPlan = (plan?.isEmpty == false) ? plan : nil

        if method == .device {
            guard Self.isDeviceOnlySignupAvailable else {
                return failCompletion("Account sign-in isn't configured correctly in this build. Grove did not create an unbacked account.")
            }
            establishLocalAccount(
                displayName: name,
                plan: collectedPlan,
                location: location,
                pendingFirstPlantID: pendingFirstPlantID
            )
            clearPendingAuthentication()
            return .signedIn
        }

        let authenticationGeneration = pendingAuthenticationGeneration

        // Someone who came in through "I already have a Grove", signed in
        // successfully, and turned out to be new here. They are already
        // authenticated against the right account — finish onto it rather than
        // asking a provider for a second credential.
        if let signup = pendingSignup, signup.mode == method.accountMode {
            let resolvedName = name.nilIfEmpty ?? signup.displayName
            guard let authClient = authClientProvider() else {
                return failCompletion("Account sign-in isn't set up in this build. Try again from a build with Grove's credentials.")
            }
            guard let prepared = await prepareSignupSession(
                signup.session,
                using: authClient,
                expectedGeneration: authenticationGeneration,
                displayName: resolvedName,
                plan: collectedPlan,
                location: location,
                pendingFirstPlantID: pendingFirstPlantID
            ) else { return .failed }
            guard establishSupabaseAccount(
                prepared.session,
                mode: signup.mode,
                displayName: prepared.ownedHandoff?.displayName ?? resolvedName,
                plan: prepared.ownedHandoff?.plan,
                location: prepared.onboardingLocation,
                pendingFirstPlantID: prepared.pendingFirstPlantID
            ) else { return .failed }
            clearPendingAuthentication()
            return .signedIn
        }

        if method == .apple {
            guard let credential = pendingApple else {
                return failCompletion("Apple sign-in expired before Grove could finish. Try Apple again.")
            }
            let resolvedName = name.nilIfEmpty ?? credential.displayName ?? ""
            guard let authClient = authClientProvider() else {
                return failCompletion("Account sign-in isn't set up in this build. Try again from a build with Grove's credentials.")
            }
            guard let idToken = credential.identityToken else {
                return failCompletion("Apple didn't return a verification token. Try Apple again.")
            }
            guard let supabase = await exchange(
                provider: .apple,
                idToken: idToken,
                nonce: credential.rawNonce,
                using: authClient,
                expectedAuthenticationGeneration: authenticationGeneration
            ) else { return .failed }
            guard let prepared = await prepareSignupSession(
                supabase,
                using: authClient,
                expectedGeneration: authenticationGeneration,
                displayName: resolvedName,
                plan: collectedPlan,
                location: location,
                pendingFirstPlantID: pendingFirstPlantID
            ) else { return .failed }
            guard establishSupabaseAccount(
                prepared.session,
                mode: .apple,
                displayName: prepared.ownedHandoff?.displayName ?? resolvedName,
                plan: prepared.ownedHandoff?.plan,
                location: prepared.onboardingLocation,
                pendingFirstPlantID: prepared.pendingFirstPlantID
            ) else { return .failed }
        } else if method == .google {
            guard let credential = pendingGoogle else {
                return failCompletion("Google sign-in expired before Grove could finish. Try Google again.")
            }
            let resolvedName = name.nilIfEmpty ?? credential.displayName ?? ""
            guard let authClient = authClientProvider() else {
                return failCompletion("Account sign-in isn't set up in this build. Try again from a build with Grove's credentials.")
            }
            guard let supabase = await exchange(
                provider: .google,
                idToken: credential.idToken,
                nonce: nil,
                using: authClient,
                expectedAuthenticationGeneration: authenticationGeneration
            ) else { return .failed }
            guard let prepared = await prepareSignupSession(
                supabase,
                using: authClient,
                expectedGeneration: authenticationGeneration,
                displayName: resolvedName,
                plan: collectedPlan,
                location: location,
                pendingFirstPlantID: pendingFirstPlantID
            ) else { return .failed }
            guard establishSupabaseAccount(
                prepared.session,
                mode: .google,
                displayName: prepared.ownedHandoff?.displayName ?? resolvedName,
                plan: prepared.ownedHandoff?.plan,
                location: prepared.onboardingLocation,
                pendingFirstPlantID: prepared.pendingFirstPlantID
            ) else { return .failed }
        } else if method == .email {
            guard let credential = pendingEmail else {
                return failCompletion("Verify the code from your email before Grove creates the account.")
            }
            guard let authClient = authClientProvider() else {
                return failCompletion("Account sign-in isn't set up in this build. Try again from a build with Grove's credentials.")
            }
            guard let prepared = await prepareSignupSession(
                credential,
                using: authClient,
                expectedGeneration: authenticationGeneration,
                displayName: name,
                plan: collectedPlan,
                location: location,
                pendingFirstPlantID: pendingFirstPlantID
            ) else { return .failed }
            // The code was already verified against Supabase on the code
            // screen, so this account is genuinely provider-backed.
            guard establishSupabaseAccount(
                prepared.session,
                mode: .email,
                displayName: prepared.ownedHandoff?.displayName ?? name,
                plan: prepared.ownedHandoff?.plan,
                location: prepared.onboardingLocation,
                pendingFirstPlantID: prepared.pendingFirstPlantID
            ) else { return .failed }
        } else {
            return failCompletion("Choose how you want to save your grove and try again.")
        }

        clearPendingAuthentication()
        return .signedIn
    }

    /// What the returning route found behind a provider sign-in.
    enum ResumeOutcome: Equatable {
        /// Signed in, and the grove is waiting.
        case signedIn
        /// The sign-in worked — this really is their account — but there is no
        /// no Grove account before this attempt. Not an error and not a silent
        /// redirect: the session is kept in `pendingSignup` while the UI clearly
        /// offers to create an account or use a different sign-in.
        case accountNotFound
        /// The account could not be reached at all. `signInError` explains.
        case unreachable
    }

    /// Signs someone back into a Grove they already have. Same token exchange as
    /// `completeOnboarding`, with two deliberate differences: no plan and no
    /// display name are collected (they already exist on the server, and the
    /// first bootstrap hydrates them), and **no initial profile push is staged**
    /// — that push carries provisioning defaults, so firing it here would
    /// overwrite a real profile's name and username with "Gardener".
    ///
    /// Never passes a freshly created identity off as an existing account: it
    /// comes back as `.accountNotFound` for an explicit sign-up offer, while an
    /// unreachable identity comes back as `.unreachable`.
    @discardableResult
    func resumeExistingAccount(method: OnboardingAuthMethod) async -> ResumeOutcome {
        let authenticationGeneration = pendingAuthenticationGeneration
        let outcome = await resolveResume(
            method: method,
            expectedGeneration: authenticationGeneration
        )
        // An `.accountNotFound` sign-in is still in flight — the UI is about to
        // offer sign-up against the session held in `pendingSignup`.
        // Every other outcome has spent its credential.
        if outcome != .accountNotFound,
           authenticationIsCurrent(authenticationGeneration) {
            clearPendingAuthentication()
        }
        return outcome
    }

    private func resolveResume(
        method: OnboardingAuthMethod,
        expectedGeneration: Int
    ) async -> ResumeOutcome {
        guard authenticationIsCurrent(expectedGeneration) else { return .unreachable }
        let authClient = authClientProvider()

        switch method {
        case .apple:
            guard let credential = pendingApple else { return failResume() }
            guard let authClient else {
                return failResumeNotConfigured()
            }
            guard let idToken = credential.identityToken,
                  let supabase = await exchange(
                      provider: .apple,
                      idToken: idToken,
                      nonce: credential.rawNonce,
                      using: authClient,
                      expectedAuthenticationGeneration: expectedGeneration
                  ) else {
                // A failed exchange used to fall back to a *local* Apple-keyed
                // session — a different account key than a Supabase-backed
                // grove, so the person's plants seemed to vanish into an empty
                // grove with no error. Fail loudly instead.
                return authenticationIsCurrent(expectedGeneration) ? failResume() : .unreachable
            }
            guard let durable = await durableInteractiveSession(
                supabase,
                using: authClient,
                expectedGeneration: expectedGeneration
            ), let completed = await completedSignupStatus(
                durable,
                using: authClient,
                expectedGeneration: expectedGeneration
            ) else { return .unreachable }
            guard completed else {
                return holdForSignup(durable, mode: .apple, displayName: credential.displayName ?? "")
            }
            guard await establishResumedAccount(
                durable,
                mode: .apple,
                displayName: credential.displayName ?? "",
                using: authClient,
                expectedGeneration: expectedGeneration
            ) else { return .unreachable }
            return .signedIn

        case .google:
            guard let credential = pendingGoogle else { return failResume() }
            guard let authClient else {
                return failResumeNotConfigured()
            }
            guard let supabase = await exchange(
                provider: .google,
                idToken: credential.idToken,
                nonce: nil,
                using: authClient,
                expectedAuthenticationGeneration: expectedGeneration
            ) else {
                return authenticationIsCurrent(expectedGeneration) ? failResume() : .unreachable
            }
            guard let durable = await durableInteractiveSession(
                supabase,
                using: authClient,
                expectedGeneration: expectedGeneration
            ), let completed = await completedSignupStatus(
                durable,
                using: authClient,
                expectedGeneration: expectedGeneration
            ) else { return .unreachable }
            guard completed else {
                return holdForSignup(durable, mode: .google, displayName: credential.displayName ?? "")
            }
            guard await establishResumedAccount(
                durable,
                mode: .google,
                displayName: credential.displayName ?? "",
                using: authClient,
                expectedGeneration: expectedGeneration
            ) else { return .unreachable }
            return .signedIn

        case .email:
            guard let credential = pendingEmail else { return failResume() }
            guard let authClient else { return failResumeNotConfigured() }
            guard let durable = await durableInteractiveSession(
                credential,
                using: authClient,
                expectedGeneration: expectedGeneration
            ), let completed = await completedSignupStatus(
                durable,
                using: authClient,
                expectedGeneration: expectedGeneration
            ) else { return .unreachable }
            guard completed else {
                return holdForSignup(durable, mode: .email, displayName: "")
            }
            guard await establishResumedAccount(
                durable,
                mode: .email,
                displayName: "",
                using: authClient,
                expectedGeneration: expectedGeneration
            ) else {
                return .unreachable
            }
            return .signedIn

        case .device:
            // Device-only Groves have no remote identity to resume. This route
            // never offers the option, but the exhaustive branch prevents a
            // future caller from treating it like provider auth.
            return failResume()
        }
    }

    /// Opens the signed-in session for a resume. No profile push is staged —
    /// see `resumeExistingAccount`.
    private func establishResumedAccount(
        _ supabase: SupabaseAuthClient.Session,
        mode: AccountMode,
        displayName: String,
        using authClient: SupabaseAuthClient,
        expectedGeneration: Int
    ) async -> Bool {
        guard let resolution = await resolveSignupHandoff(
            session: supabase,
            using: authClient,
            expectedGeneration: expectedGeneration
        ) else { return false }
        if let handoff = resolution.ownedHandoff {
            return establishSupabaseAccount(
                supabase,
                mode: mode,
                displayName: handoff.displayName,
                plan: handoff.plan,
                location: handoff.location,
                pendingFirstPlantID: handoff.pendingFirstPlantID
            )
        }
        guard persistRefreshToken(supabase, accountID: supabase.userID) else {
            signInError = "This iPhone couldn't securely save the sign-in. Check that it is unlocked and try again."
            return false
        }
        cacheAccessToken(from: supabase)
        establish(
            UserSession(
                accountID: supabase.userID,
                mode: mode,
                displayName: Self.normalizedDisplayName(displayName).nilIfEmpty ?? "Gardener"
            )
        )
        return true
    }

    /// Holds a good provider sign-in that created a new Grove identity, pending
    /// the person's explicit choice to sign up. Nothing is persisted yet: the
    /// session becomes the device's account only once `completeOnboarding` runs,
    /// so choosing another sign-in leaves no orphan session on the phone.
    private func holdForSignup(
        _ supabase: SupabaseAuthClient.Session,
        mode: AccountMode,
        displayName: String
    ) -> ResumeOutcome {
        pendingSignup = PendingSignupSession(
            session: supabase,
            mode: mode,
            displayName: displayName
        )
        signInError = nil
        return .accountNotFound
    }

    private struct PreparedSignupSession {
        let session: SupabaseAuthClient.Session
        /// Present only when this device's durable random claim owns the server
        /// transition. It remains present across a lost response/relaunch; a
        /// competing claim can never overwrite this account's provisioning
        /// defaults with answers from this device.
        let ownedHandoff: PendingSignupHandoff?
        /// Value-bearing work the person explicitly completed in this signup
        /// attempt. These are deliberately independent of `ownedHandoff`: an
        /// identity can already have a completed Grove (or another device can
        /// win account provisioning) while this iPhone still has a newly
        /// scanned plant that the person just asked to save. Profile defaults
        /// must not overwrite that account, but dropping the additive plant is
        /// equally wrong.
        let onboardingLocation: GroveLocation?
        let pendingFirstPlantID: UUID?
    }

    /// Durable local half of the signup commit. It is written before the server
    /// marker changes, so a process kill after that change cannot strand the
    /// plan or first plant. A later login for this exact account consumes it.
    private struct PendingSignupHandoff: Codable, Equatable {
        /// Optional only for decoding a handoff written by a pre-claim build.
        /// Such a handoff is discarded rather than guessed to own a completion.
        let claimID: UUID?
        let displayName: String
        let plan: GrovePlan?
        let location: GroveLocation?
        let pendingFirstPlantID: UUID?
    }

    private struct SignupHandoffResolution {
        let ownedHandoff: PendingSignupHandoff?
    }

    /// A provider-backed account must retain a refresh credential before Grove
    /// publishes it as signed in. Accepting an access-token-only response made
    /// an account appear to work for an hour, then turn into an unrecoverable
    /// zombie at relaunch.
    private func durableInteractiveSession(
        _ session: SupabaseAuthClient.Session,
        using authClient: SupabaseAuthClient,
        expectedGeneration: Int
    ) async -> SupabaseAuthClient.Session? {
        guard authenticationIsCurrent(expectedGeneration),
              let originalRefresh = session.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !originalRefresh.isEmpty else {
            if authenticationIsCurrent(expectedGeneration) {
                signInError = "That sign-in didn't include a lasting credential. Try again."
            }
            return nil
        }
        guard session.needsRefresh else { return session }

        do {
            let refreshed = try await authClient.refresh(refreshToken: originalRefresh)
            guard authenticationIsCurrent(expectedGeneration),
                  refreshed.userID == session.userID else { return nil }
            let durable = SupabaseAuthClient.Session(
                userID: refreshed.userID,
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken?.nilIfEmpty ?? originalRefresh,
                expiresAt: refreshed.expiresAt,
                userCreatedAt: refreshed.userCreatedAt ?? session.userCreatedAt,
                userLastSignInAt: refreshed.userLastSignInAt ?? session.userLastSignInAt
            )
            guard !durable.needsRefresh else {
                signInError = "The account service returned an already-expired sign-in. Check this iPhone's date and try again."
                return nil
            }
            return durable
        } catch {
            guard authenticationIsCurrent(expectedGeneration) else { return nil }
            signInError = "Grove couldn't keep that sign-in active. Check your connection and try again."
            return nil
        }
    }

    /// Reads the server-owned account-completion marker. Unlike Auth creation
    /// timestamps, this remains false across every later sign-in until the
    /// person explicitly accepts account creation.
    private func completedSignupStatus(
        _ session: SupabaseAuthClient.Session,
        using authClient: SupabaseAuthClient,
        expectedGeneration: Int
    ) async -> Bool? {
        guard authenticationIsCurrent(expectedGeneration) else { return nil }
        do {
            let completed = try await authClient.hasCompletedSignup(accessToken: session.accessToken)
            guard authenticationIsCurrent(expectedGeneration) else { return nil }
            return completed
        } catch {
            guard authenticationIsCurrent(expectedGeneration) else { return nil }
            signInError = "Grove couldn't confirm whether that account is set up. Check your connection and try again."
            return nil
        }
    }

    /// Makes a newly accepted signup durable on the server before exposing its
    /// local session. The marker is always read at this final boundary: another
    /// device may have completed the same identity while this phone was still
    /// collecting onboarding answers, and stale defaults must not overwrite it.
    private func prepareSignupSession(
        _ session: SupabaseAuthClient.Session,
        using authClient: SupabaseAuthClient,
        expectedGeneration: Int,
        displayName: String,
        plan: GrovePlan?,
        location: GroveLocation?,
        pendingFirstPlantID: UUID?
    ) async -> PreparedSignupSession? {
        guard let durable = await durableInteractiveSession(
            session,
            using: authClient,
            expectedGeneration: expectedGeneration
        ) else { return nil }

        guard let completed = await completedSignupStatus(
            durable,
            using: authClient,
            expectedGeneration: expectedGeneration
        ) else { return nil }
        let wasIncomplete = !completed

        if wasIncomplete {
            guard stageSignupHandoff(
                accountID: durable.userID,
                displayName: displayName,
                plan: plan,
                location: location,
                pendingFirstPlantID: pendingFirstPlantID
            ) != nil else {
                signInError = "This iPhone couldn't securely stage the account setup. Check its storage and try again."
                return nil
            }
            stageInitialProfileSync(
                accountID: durable.userID,
                displayName: displayName,
                location: location
            )
        }

        // If the account was already complete, a local handoff may be the
        // winner of an earlier request whose response was lost. Ask the server
        // to compare its claim instead of either dropping it or trusting it.
        guard let resolution = await resolveSignupHandoff(
            session: durable,
            using: authClient,
            expectedGeneration: expectedGeneration
        ) else { return nil }
        return PreparedSignupSession(
            session: durable,
            ownedHandoff: resolution.ownedHandoff,
            onboardingLocation: resolution.ownedHandoff?.location ?? location,
            pendingFirstPlantID: resolution.ownedHandoff?.pendingFirstPlantID ?? pendingFirstPlantID
        )
    }

    /// Resolves a staged handoff against the server's immutable winning claim.
    /// Reusing the same claim makes a response-lost retry idempotent. A different
    /// claim proves another device won, so local defaults are removed before
    /// they can overwrite the established account.
    private func resolveSignupHandoff(
        session: SupabaseAuthClient.Session,
        using authClient: SupabaseAuthClient,
        expectedGeneration: Int
    ) async -> SignupHandoffResolution? {
        guard authenticationIsCurrent(expectedGeneration) else { return nil }
        guard let handoff = pendingSignupHandoff(accountID: session.userID) else {
            return SignupHandoffResolution(ownedHandoff: nil)
        }
        guard let claimID = handoff.claimID else {
            clearSignupHandoff(accountID: session.userID)
            storage.removeObject(forKey: pendingProfileKey(for: session.userID))
            return SignupHandoffResolution(ownedHandoff: nil)
        }

        do {
            let ownsCompletion = try await authClient.completeSignup(
                accessToken: session.accessToken,
                claimID: claimID
            )
            guard authenticationIsCurrent(expectedGeneration) else { return nil }
            if ownsCompletion {
                PostSignupSetupProgress.arm(accountID: session.userID, storage: storage)
                return SignupHandoffResolution(ownedHandoff: handoff)
            }
            clearSignupHandoff(accountID: session.userID)
            storage.removeObject(forKey: pendingProfileKey(for: session.userID))
            return SignupHandoffResolution(ownedHandoff: nil)
        } catch {
            guard authenticationIsCurrent(expectedGeneration) else { return nil }
            signInError = "Grove couldn't finish creating the account. Check your connection and try again."
            return nil
        }
    }

    private func failResume() -> ResumeOutcome {
        signInError = "Grove couldn't reach your account. Check your connection and try again."
        return .unreachable
    }

    private func failResumeNotConfigured() -> ResumeOutcome {
        signInError = "Account sign-in isn't configured in this build. Use a configured build to reach your grove."
        return .unreachable
    }

    private func failCompletion(_ message: String) -> CompletionOutcome {
        signInError = message
        return .failed
    }

    private func stageInitialProfileSync(
        accountID: String,
        displayName: String,
        location: GroveLocation?
    ) {
        // Provisioning defaults — a generated username, "Gardener", private —
        // belong only to the request that actually completes a new signup.
        let resolvedDisplayName = Self.normalizedDisplayName(displayName).nilIfEmpty ?? "Gardener"
        let request = UpdateProfileRequest(
            displayName: resolvedDisplayName,
            username: Self.generatedUsername(from: resolvedDisplayName),
            regionCode: Locale.current.region?.identifier ?? "GB",
            usesMetricSystem: Locale.current.measurementSystem != .us,
            isPrivate: true,
            latitude: location?.latitude,
            longitude: location?.longitude,
            locationLabel: location?.label,
            locationCountryCode: location?.countryCode,
            locationTimeZoneIdentifier: location?.timeZoneIdentifier,
            clientRequestID: UUID()
        )
        if let data = try? JSONEncoder().encode(request) {
            storage.set(data, forKey: pendingProfileKey(for: accountID))
        }
    }

    @discardableResult
    private func stageSignupHandoff(
        accountID: String,
        displayName: String,
        plan: GrovePlan?,
        location: GroveLocation?,
        pendingFirstPlantID: UUID?
    ) -> PendingSignupHandoff? {
        let existingClaimID = pendingSignupHandoff(accountID: accountID)?.claimID
        let handoff = PendingSignupHandoff(
            claimID: existingClaimID ?? UUID(),
            displayName: Self.normalizedDisplayName(displayName).nilIfEmpty ?? "Gardener",
            plan: plan,
            location: location,
            pendingFirstPlantID: pendingFirstPlantID
        )
        if let data = try? JSONEncoder().encode(handoff) {
            storage.set(data, forKey: pendingSignupHandoffKey(for: accountID))
        }
        // Never commit the server marker unless the exact claim/data can be
        // decoded from durable storage first.
        return pendingSignupHandoff(accountID: accountID)
    }

    private func pendingSignupHandoff(accountID: String) -> PendingSignupHandoff? {
        guard let data = storage.data(forKey: pendingSignupHandoffKey(for: accountID)) else {
            return nil
        }
        return try? JSONDecoder().decode(PendingSignupHandoff.self, from: data)
    }

    private func clearSignupHandoff(accountID: String) {
        storage.removeObject(forKey: pendingSignupHandoffKey(for: accountID))
    }

    private func pendingSignupHandoffKey(for accountID: String) -> String {
        "grove.pending-signup-handoff.v1.\(accountID)"
    }

    /// Persists the Supabase tokens and establishes the signed-in session.
    private func establishSupabaseAccount(
        _ supabase: SupabaseAuthClient.Session,
        mode: AccountMode,
        displayName: String,
        plan: GrovePlan? = nil,
        location: GroveLocation? = nil,
        pendingFirstPlantID: UUID? = nil
    ) -> Bool {
        let resolvedDisplayName = Self.normalizedDisplayName(displayName).nilIfEmpty ?? "Gardener"
        guard persistRefreshToken(supabase, accountID: supabase.userID) else {
            signInError = "This iPhone couldn't securely save the sign-in. Check that it is unlocked and try again."
            return false
        }
        cacheAccessToken(from: supabase)
        // Publish the signed-in state only after every piece RootView needs has
        // reached durable storage.
        establish(
            UserSession(
                accountID: supabase.userID,
                mode: mode,
                displayName: resolvedDisplayName,
                plan: plan,
                location: location,
                pendingFirstPlantID: pendingFirstPlantID
            )
        )
        clearSignupHandoff(accountID: supabase.userID)
        return true
    }

    /// Reads the staged initial profile mutation without consuming it. RootView
    /// acknowledges it only after the durable sync queue accepts the mutation,
    /// closing the second kill window between reading this value and enqueueing.
    func pendingInitialProfileSync(accountID: String? = nil) -> UpdateProfileRequest? {
        guard let accountID = accountID ?? currentSession?.accountID else { return nil }
        let key = pendingProfileKey(for: accountID)
        guard let data = storage.data(forKey: key),
              let request = try? JSONDecoder().decode(UpdateProfileRequest.self, from: data) else {
            return nil
        }
        return request
    }

    func markInitialProfileSyncEnqueued(accountID: String) {
        storage.removeObject(forKey: pendingProfileKey(for: accountID))
    }

    /// Restores the one-shot import authorization when a legacy build reached
    /// the account before persisting it. The caller must either have an
    /// account-owned manifest or obtain explicit confirmation for an unclaimed
    /// one; this method only makes that already-checked decision durable.
    @discardableResult
    func authorizePendingFirstPlantImport(accountID: String, plantID: UUID) -> Bool {
        guard var current = currentSession, current.accountID == accountID else { return false }
        if let pending = current.pendingFirstPlantID { return pending == plantID }
        current.pendingFirstPlantID = plantID
        guard let data = try? JSONEncoder().encode(current) else { return false }
        storage.set(data, forKey: storageKey)
        state = .signedIn(current)
        return true
    }

    /// Consumes the one-shot authorization only after the pending store and
    /// mutation queue have acknowledged the same stable plant id.
    func markPendingFirstPlantImported(accountID: String, plantID: UUID) {
        guard var current = currentSession,
              current.accountID == accountID,
              current.pendingFirstPlantID == plantID else { return }
        current.pendingFirstPlantID = nil
        if let data = try? JSONEncoder().encode(current) {
            storage.set(data, forKey: storageKey)
        }
        state = .signedIn(current)
    }

    /// Explicit escape for an unrecoverable handoff. Unlike the success path,
    /// this is called only after a screen names the loss and the person chooses
    /// to continue without that plant.
    func abandonPendingFirstPlantImport(accountID: String, plantID: UUID) {
        markPendingFirstPlantImported(accountID: accountID, plantID: plantID)
    }

    private func pendingProfileKey(for accountID: String) -> String {
        "grove.initial-profile-sync.v1.\(accountID)"
    }

    /// True for a handle `generatedUsername` minted, which nobody chose and
    /// nobody should be shown as if it were their name.
    static func isGeneratedUsername(_ username: String) -> Bool {
        username.range(of: "^[a-z0-9_]{3,7}_[0-9a-f]{16}$", options: .regularExpression) != nil
    }

    /// A collision-resistant starter username the user can change later, e.g.
    /// "jay_4f2ac91d76e84b10". Matches the server's `^[a-z0-9_]{3,24}$` rule.
    static func generatedUsername(from displayName: String) -> String {
        let folded = displayName.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        var slug = String(
            folded.unicodeScalars.filter {
                (97...122).contains(Int($0.value))
                    || (48...57).contains(Int($0.value))
                    || $0.value == 95
            }
        )
        if slug.count > 7 { slug = String(slug.prefix(7)) }
        if slug.count < 3 { slug = "gardene" }
        let suffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(16)
        return "\(slug)_\(suffix)"
    }

    // MARK: - API bearer token

    /// Whether the active session syncs with the backend: a Supabase-backed
    /// mode with tokens stored for the same account.
    var isSupabaseBacked: Bool {
        guard let current = currentSession, current.mode.isSupabaseBacked else { return false }
        guard let tokens = SupabaseSessionStore.load() else { return false }
        return tokens.userID == current.accountID
    }

    /// The bearer token for authenticated Grove API calls, refreshing through
    /// Supabase when the stored access token is near expiry. Returns nil for
    /// local-only sessions or when a refresh conclusively fails.
    func apiBearerToken() async -> String? {
        await apiBearerToken(forcingRefresh: false)
    }

    /// A bearer obtained by exchanging the refresh token even when the stored
    /// access token still looks valid locally.
    ///
    /// Expiry is not the only reason a server rejects a token: a revoked
    /// session, a rotated signing key, or a device clock running slow all
    /// produce a 401 on a token this app believes is fine. Callers that have
    /// *seen* the rejection use this to get a genuinely new one before giving
    /// up on the request.
    func refreshedAPIBearerToken() async -> String? {
        await apiBearerToken(forcingRefresh: true)
    }

    private func apiBearerToken(forcingRefresh: Bool) async -> String? {
        guard let current = currentSession, current.mode.isSupabaseBacked else { return nil }
        guard let tokens = SupabaseSessionStore.load(), tokens.userID == current.accountID else { return nil }
        guard forcingRefresh || tokens.needsRefresh else { return tokens.accessToken }
        return await sharedRefresh(tokens: tokens)?.accessToken
    }

    /// Exchanges the refresh token, sharing one in-flight exchange across every
    /// caller.
    ///
    /// GoTrue rotates the refresh token on use, so a second exchange of the same
    /// token is answered with "already used" — a genuine rejection, which
    /// `performRefresh` acts on by deleting the credential. Two callers racing
    /// each other is therefore enough to sign a working account out of its own
    /// server, so every refresh in the app funnels through here.
    private func sharedRefresh(tokens: SupabaseTokenSet) async -> SupabaseTokenSet? {
        guard let current = currentSession,
              current.mode.isSupabaseBacked,
              current.accountID == tokens.userID else { return nil }

        if let refreshTask {
            if refreshTaskAccountID == tokens.userID,
               let taskGeneration = refreshTaskGeneration,
               taskGeneration == providerCredentialGeneration {
                let refreshed = await refreshTask.value
                return currentRefreshResult(
                    refreshed,
                    accountID: tokens.userID,
                    generation: taskGeneration
                )
            }
            // A task for another credential must never be shared with this
            // caller. This is defensive—the normal account transitions already
            // invalidate it synchronously.
            invalidateProviderRefreshWork()
        }

        let accountID = tokens.userID
        let generation = providerCredentialGeneration
        let task = Task<SupabaseTokenSet?, Never> { [weak self] in
            await self?.performRefresh(
                tokens: tokens,
                expectedAccountID: accountID,
                generation: generation
            )
        }
        refreshTask = task
        refreshTaskAccountID = accountID
        refreshTaskGeneration = generation
        let refreshed = await task.value
        if refreshTaskAccountID == accountID,
           refreshTaskGeneration == generation {
            refreshTask = nil
            refreshTaskAccountID = nil
            refreshTaskGeneration = nil
        }
        return currentRefreshResult(
            refreshed,
            accountID: accountID,
            generation: generation
        )
    }

    private func currentRefreshResult(
        _ refreshed: SupabaseTokenSet?,
        accountID: String,
        generation: Int
    ) -> SupabaseTokenSet? {
        guard providerCredentialGeneration == generation,
              let current = currentSession,
              current.mode.isSupabaseBacked,
              current.accountID == accountID,
              let refreshed,
              refreshed.userID == accountID,
              let stored = SupabaseSessionStore.load(),
              stored.userID == accountID,
              stored.accessToken == refreshed.accessToken else { return nil }
        return refreshed
    }

    /// A verified provider-account bearer for Ari. Anonymous Auth signup is a
    /// public capability, so no caller-selected purpose can authorize this paid
    /// surface; the server independently requires a provisioned account row.
    func botanistBearerToken() async -> String? {
        guard currentSession?.mode.isSupabaseBacked == true else { return nil }
        return await apiBearerToken()
    }

    /// Preserves scan access for Groves created by older builds without turning
    /// their public anonymous identity into an account. The backend subjects
    /// this token to the same per-identity and project-wide guest ceilings as
    /// signed-out onboarding.
    private func localAnalysisBearerToken(for current: UserSession) async -> String? {
        guard !current.mode.isSupabaseBacked else { return nil }

        if let tokens = BotanistSessionStore.load(),
           tokens.ownerAccountID == current.accountID,
           !tokens.needsRefresh {
            return tokens.accessToken
        }

        if let localAnalysisRefreshTask {
            return await localAnalysisRefreshTask.value?.accessToken
        }

        let stored = BotanistSessionStore.load()
            .flatMap { $0.ownerAccountID == current.accountID ? $0 : nil }
        let ownerAccountID = current.accountID
        let task = Task<BotanistTokenSet?, Never> { [weak self] in
            await self?.obtainLocalAnalysisTokens(
                ownerAccountID: ownerAccountID,
                existing: stored
            )
        }
        localAnalysisRefreshTask = task
        let tokens = await task.value
        localAnalysisRefreshTask = nil
        return tokens?.accessToken
    }

    private func obtainLocalAnalysisTokens(
        ownerAccountID: String,
        existing: BotanistTokenSet?
    ) async -> BotanistTokenSet? {
        guard let authClient = authClientProvider() else { return nil }
        do {
            let session: SupabaseAuthClient.Session
            if let existing {
                session = try await authClient.refresh(refreshToken: existing.refreshToken)
                // Refresh rotation may change tokens, never subjects. Refuse a
                // mismatched response rather than silently resetting the guest
                // quota identity attached to this local Grove.
                guard session.userID == existing.userID else {
                    if currentSession?.accountID == ownerAccountID {
                        BotanistSessionStore.clear()
                    }
                    return nil
                }
            } else {
                session = try await authClient.signInAnonymously(purpose: .onboardingScan)
            }
            guard currentSession?.accountID == ownerAccountID,
                  let refreshToken = session.refreshToken?
                      .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                      ?? existing?.refreshToken else {
                return nil
            }
            let tokens = BotanistTokenSet(
                ownerAccountID: ownerAccountID,
                userID: session.userID,
                accessToken: session.accessToken,
                refreshToken: refreshToken,
                expiresAt: session.expiresAt
            )
            BotanistSessionStore.save(tokens)
            return tokens
        } catch let error as SupabaseAuthClient.AuthError {
            // A *rejected* refresh is permanently unusable. Clear it so the next
            // scan can mint one fresh anonymous identity. A server that merely
            // failed to answer keeps its token — discarding it there would strand
            // the anonymous quota history this identity carries.
            if error.isCredentialRejection,
               currentSession?.accountID == ownerAccountID {
                BotanistSessionStore.clear()
            }
            return nil
        } catch {
            // Preserve the refresh token on transient transport failures.
            return nil
        }
    }

    /// Bearer used by plant analysis and species correction.
    ///
    /// Provider accounts use their account JWT. A legacy device-only Grove gets
    /// a separate guest-limited identity tied to its local namespace. Only a
    /// genuinely signed-out onboarding flow reaches the independent pre-account
    /// identity below.
    func analysisBearerToken() async -> String? {
        if let current = currentSession {
            if current.mode.isSupabaseBacked { return await apiBearerToken() }
            return await localAnalysisBearerToken(for: current)
        }

        if let tokens = OnboardingGuestSessionStore.load(), !tokens.needsRefresh {
            return tokens.accessToken
        }
        if let onboardingGuestRefreshTask {
            return await onboardingGuestRefreshTask.value?.accessToken
        }

        let stored = OnboardingGuestSessionStore.load()
        let generation = onboardingGuestCredentialGeneration
        let task = Task<OnboardingGuestTokenSet?, Never> { [weak self] in
            await self?.obtainOnboardingGuestTokens(existing: stored, generation: generation)
        }
        onboardingGuestRefreshTask = task
        let tokens = await task.value
        onboardingGuestRefreshTask = nil
        return tokens?.accessToken
    }

    private func obtainOnboardingGuestTokens(
        existing: OnboardingGuestTokenSet?,
        generation: Int
    ) async -> OnboardingGuestTokenSet? {
        guard currentSession == nil,
              onboardingGuestCredentialGeneration == generation,
              let authClient = authClientProvider() else { return nil }
        do {
            let session: SupabaseAuthClient.Session
            if let existing {
                session = try await authClient.refresh(refreshToken: existing.refreshToken)
                // A refresh token is bound to one Auth subject. Treat a response
                // that changes it as credential corruption, never as a new owner.
                guard session.userID == existing.userID else {
                    clearOnboardingGuestCredentialStorage()
                    return nil
                }
            } else {
                session = try await authClient.signInAnonymously(purpose: .onboardingScan)
            }
            guard currentSession == nil,
                  onboardingGuestCredentialGeneration == generation,
                  let refreshToken = session.refreshToken?
                      .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                      ?? existing?.refreshToken else {
                return nil
            }
            let tokens = OnboardingGuestTokenSet(
                userID: session.userID,
                accessToken: session.accessToken,
                refreshToken: refreshToken,
                expiresAt: session.expiresAt
            )
            OnboardingGuestSessionStore.save(tokens)
            storage.set(true, forKey: GroveDefaults.onboardingGuestCredentialPresent)
            return tokens
        } catch let error as SupabaseAuthClient.AuthError {
            // Preserve a refresh token through transport/5xx/429 failures. Only
            // GoTrue explicitly rejecting it proves it can never recover.
            if error.isCredentialRejection,
               currentSession == nil,
               onboardingGuestCredentialGeneration == generation {
                clearOnboardingGuestCredentialStorage()
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Removes only the pre-account analysis identity. The pending-plant handoff
    /// calls this after its local import and sync mutation are durable; clearing
    /// it earlier would make a killed app unable to resume the same server job.
    func clearOnboardingGuestCredential() {
        onboardingGuestCredentialGeneration += 1
        onboardingGuestRefreshTask?.cancel()
        onboardingGuestRefreshTask = nil
        clearOnboardingGuestCredentialStorage()
    }

    private func clearOnboardingGuestCredentialStorage() {
        OnboardingGuestSessionStore.clear()
        storage.removeObject(forKey: GroveDefaults.onboardingGuestCredentialPresent)
    }

    private func performRefresh(
        tokens: SupabaseTokenSet,
        expectedAccountID: String,
        generation: Int
    ) async -> SupabaseTokenSet? {
        guard tokens.userID == expectedAccountID,
              providerRefreshIsCurrent(accountID: expectedAccountID, generation: generation),
              let authClient = authClientProvider() else { return nil }
        do {
            let refreshed = try await authClient.refresh(refreshToken: tokens.refreshToken)
            guard providerRefreshIsCurrent(accountID: expectedAccountID, generation: generation) else {
                return nil
            }
            // A refresh rotates credentials for one immutable Auth subject. A
            // different subject is a broken response, never a new owner for the
            // active Grove.
            guard refreshed.userID == expectedAccountID else {
                clearSupabaseTokens()
                return nil
            }
            let updated = SupabaseTokenSet(
                userID: refreshed.userID,
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? tokens.refreshToken,
                expiresAt: refreshed.expiresAt
            )
            guard SupabaseSessionStore.save(updated) else {
                // The refresh token has rotated on the server. Keeping the old
                // Keychain value would guarantee a rejection on the next try,
                // while publishing the new access token would create another
                // short-lived zombie session. Fail closed and ask for repair.
                clearSupabaseTokens()
                signInError = "This iPhone couldn't securely save the refreshed sign-in. Sign in again to repair it."
                return nil
            }
            cacheAccessToken(from: refreshed)
            needsReauthentication = false
            return updated
        } catch let error as SupabaseAuthClient.AuthError {
            // Only a refusal spends the credential. This used to fire on *any*
            // non-2xx, so a single 5xx while the auth project restarted — or a
            // 429, or a hotel wifi splash page — deleted the refresh token, and
            // with it every chance of ever getting a bearer again. The account
            // stayed "signed in", sync went silent for good, and Settings put up
            // a permanent "your sign-in expired" that nothing could clear.
            guard providerRefreshIsCurrent(accountID: expectedAccountID, generation: generation) else {
                return nil
            }
            if error.isCredentialRejection { clearSupabaseTokens() }
            return nil
        } catch {
            // Keep the stored tokens: a transient network failure must not sign
            // the user out. The API returns 401 and sync retries later.
            return nil
        }
    }

    private func providerRefreshIsCurrent(accountID: String, generation: Int) -> Bool {
        guard providerCredentialGeneration == generation,
              let current = currentSession,
              current.mode.isSupabaseBacked,
              current.accountID == accountID else { return false }
        return SupabaseSessionStore.load()?.userID == accountID
    }

    private func invalidateProviderRefreshWork() {
        providerCredentialGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskAccountID = nil
        refreshTaskGeneration = nil
    }

    private func clearSupabaseTokens() {
        invalidateProviderRefreshWork()
        supabaseAccessToken = nil
        SupabaseSessionStore.clear()
        // Losing the credential under a signed-in provider account is the
        // zombie state described on `needsReauthentication`. Sign-out and
        // switching to a local account both clear the flag straight after,
        // because `establish` and `signOut` reset it.
        needsReauthentication = currentSession?.mode.isSupabaseBacked == true
    }

    /// Exchanges a provider identity token for a Supabase session, storing the
    /// access token on success. Returns nil and leaves an actionable error on
    /// failure; callers remain signed out and let the person retry.
    private func exchange(
        provider: SupabaseAuthClient.Provider,
        idToken: String,
        nonce: String?,
        using authClient: SupabaseAuthClient,
        expectedAuthenticationGeneration: Int
    ) async -> SupabaseAuthClient.Session? {
        guard authenticationIsCurrent(expectedAuthenticationGeneration) else { return nil }
        // An interactive credential supersedes any refresh that was already in
        // flight for the prior session, even before the provider answers.
        invalidateProviderRefreshWork()
        do {
            let session = try await authClient.signIn(provider: provider, idToken: idToken, nonce: nonce)
            guard authenticationIsCurrent(expectedAuthenticationGeneration) else { return nil }
            signInError = nil
            return session
        } catch {
            guard authenticationIsCurrent(expectedAuthenticationGeneration) else { return nil }
            signInError = "Grove couldn't verify that sign-in with the account service. Check your connection and try again."
            return nil
        }
    }

    private func establishLocalAccount(
        displayName: String,
        plan: GrovePlan? = nil,
        location: GroveLocation? = nil,
        pendingFirstPlantID: UUID? = nil
    ) {
        // Clears the Keychain too: a local account must not inherit a previous
        // Supabase session's refresh token.
        clearSupabaseTokens()
        let accountID = "local-\(UUID().uuidString)"
        PostSignupSetupProgress.arm(accountID: accountID, storage: storage)
        establish(
            UserSession(
                accountID: accountID,
                mode: .local,
                displayName: displayName.nilIfEmpty ?? "Gardener",
                plan: plan,
                location: location,
                pendingFirstPlantID: pendingFirstPlantID
            )
        )
    }

    /// Captures a Google identity token (minted by `GoogleAuthenticator`)
    /// without establishing a session, so the user continues through the
    /// personalization flow first — identical to the Apple funnel.
    func stashGoogleCredential(userID: String?, idToken: String, displayName: String?) {
        cancelPendingAuthentication(clearError: false)
        pendingGoogle = PendingGoogleCredential(userID: userID, idToken: idToken, displayName: displayName)
        signInError = nil
    }

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        cancelPendingAuthentication(clearError: false)
        let nonce = Self.randomNonceString()
        let state = UUID().uuidString
        currentAppleNonce = nonce
        currentAppleState = state
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
        request.state = state
    }

    enum AppleCredentialOutcome: Equatable {
        case accepted
        /// The request was canceled/replaced before this system callback arrived.
        case stale
        case failed
    }

    /// Captures the Apple credential without establishing a session, so the
    /// user continues through the personalization flow first. The outcome lets
    /// the UI distinguish a real failure from a callback for an abandoned request.
    func stashAppleCredential(_ result: Result<ASAuthorization, Error>) -> AppleCredentialOutcome {
        guard currentAppleState != nil else { return .stale }
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                clearPendingAuthentication()
                signInError = "Apple didn't return a usable credential. Try again."
                return .failed
            }
            guard let credentialState = credential.state else {
                clearPendingAuthentication()
                signInError = "Apple didn't return the sign-in state Grove requested. Try Apple again."
                return .failed
            }
            // A canceled/replaced request has a different state. Never pair its
            // identity token with the nonce from a newer attempt.
            guard credentialState == currentAppleState else { return .stale }
            guard let rawNonce = currentAppleNonce else {
                clearPendingAuthentication()
                signInError = "Apple sign-in expired before Grove could verify it. Try Apple again."
                return .failed
            }
            guard let identityToken = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
                clearPendingAuthentication()
                signInError = "Apple didn't return a verification token. Try Apple again."
                return .failed
            }
            pendingApple = PendingAppleCredential(
                userID: credential.user,
                displayName: credential.fullName
                    .flatMap { PersonNameComponentsFormatter().string(from: $0).nilIfEmpty },
                identityToken: identityToken,
                rawNonce: rawNonce
            )
            signInError = nil
            return .accepted
        case .failure(let error):
            clearPendingAuthentication()
            if let authorizationError = error as? ASAuthorizationError, authorizationError.code == .canceled {
                signInError = nil
                return .failed
            }
            signInError = "Grove couldn't finish signing you in. Try again."
            return .failed
        }
    }

    /// Signs out locally immediately, then makes a best-effort request to revoke
    /// this refresh session on Supabase. Local sign-out never depends on the
    /// network; a user in airplane mode must still be able to leave the account.
    /// Other devices remain signed in because the Auth request uses local scope.
    func signOutAndRevokeRemoteSession() async {
        let account = currentSession
        let stored = SupabaseSessionStore.load()
        let authClient = authClientProvider()
        signOut()

        guard let account,
              account.mode.isSupabaseBacked,
              let stored,
              stored.userID == account.accountID,
              let authClient else { return }
        await revokeRemoteSession(
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            userID: stored.userID,
            expiresAt: stored.expiresAt,
            using: authClient
        )
    }

    /// Best-effort revocation for a session Grove is deliberately discarding.
    /// A bearer can be rejected before the phone's local expiry says it should
    /// be (clock skew or signing-key rotation), so one 401 gets a refresh and a
    /// second logout attempt. No refreshed credential is ever persisted here.
    private func revokeRemoteSession(
        accessToken: String,
        refreshToken: String?,
        userID: String,
        expiresAt: Date,
        using authClient: SupabaseAuthClient
    ) async {
        let durableRefresh = refreshToken?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var bearer = accessToken
        var didRefresh = false

        if Date.now >= expiresAt.addingTimeInterval(-60),
           let durableRefresh,
           let refreshed = try? await authClient.refresh(refreshToken: durableRefresh),
           refreshed.userID == userID {
            bearer = refreshed.accessToken
            didRefresh = true
        }

        do {
            try await authClient.signOut(accessToken: bearer)
        } catch SupabaseAuthClient.AuthError.provider(_, let status)
            where status == 401 && !didRefresh && durableRefresh != nil {
            guard let durableRefresh,
                  let refreshed = try? await authClient.refresh(refreshToken: durableRefresh),
                  refreshed.userID == userID else {
                GroveDiag.log("auth: remote session revocation failed")
                return
            }
            do {
                try await authClient.signOut(accessToken: refreshed.accessToken)
            } catch {
                GroveDiag.log("auth: remote session revocation failed")
            }
        } catch {
            // The phone is already safely signed out. A transient failure leaves
            // only the server session, whose access JWT expires normally; never
            // resurrect local credentials just to retry logout.
            GroveDiag.log("auth: remote session revocation failed")
        }
    }

    func signOut() {
        let signedOutAccountID = currentSession?.accountID
        storage.removeObject(forKey: storageKey)
        if let signedOutAccountID {
            // A provisioning request belongs to the signup handoff that staged
            // it. Letting it survive an explicit sign-out could overwrite a
            // profile changed on another device the next time this phone logs
            // into the same account.
            storage.removeObject(forKey: pendingProfileKey(for: signedOutAccountID))
            clearSignupHandoff(accountID: signedOutAccountID)
        }
        state = .signedOut
        signInError = nil
        needsReauthentication = false
        // The refresh token can mint new access tokens indefinitely, so it must
        // not outlive the session it belongs to.
        clearSupabaseTokens()
        localAnalysisRefreshTask?.cancel()
        localAnalysisRefreshTask = nil
        BotanistSessionStore.clear()
        clearOnboardingGuestCredential()
        clearPendingAuthentication()
    }

    /// Drops every transient credential when the user changes route, provider,
    /// or returns to the welcome screen. In particular this clears a pending
    /// returning-route sign-up session, so it can never be consumed by a later signup
    /// that merely chose the same provider.
    func cancelPendingAuthentication(clearError: Bool = true) {
        let abandonedSignup = pendingSignup
        let authClient = abandonedSignup == nil ? nil : authClientProvider()
        clearPendingAuthentication()
        if let abandonedSignup, let authClient {
            Task { [weak self] in
                await self?.revokeRemoteSession(
                    accessToken: abandonedSignup.session.accessToken,
                    refreshToken: abandonedSignup.session.refreshToken,
                    userID: abandonedSignup.session.userID,
                    expiresAt: abandonedSignup.session.expiresAt,
                    using: authClient
                )
            }
        }
        if clearError { signInError = nil }
    }

    private func clearPendingAuthentication() {
        pendingAuthenticationGeneration &+= 1
        pendingApple = nil
        pendingGoogle = nil
        pendingEmail = nil
        pendingSignup = nil
        currentAppleNonce = nil
        currentAppleState = nil
    }

    private func authenticationIsCurrent(_ generation: Int) -> Bool {
        pendingAuthenticationGeneration == generation && !Task.isCancelled
    }

    /// Restores a provider-backed session by trading the stored refresh token
    /// for a fresh access token.
    ///
    /// Without this the access token lived only in memory, so after a relaunch a
    /// Supabase-backed account had no bearer and every authenticated request
    /// would fail — the account looked signed in while behaving as local-only.
    ///
    /// Safe and cheap to call repeatedly: it returns immediately once a bearer
    /// is in hand, and shares any exchange already in flight. That matters
    /// because failure is not fatal — the app is offline-first and the local
    /// Grove is fully usable — so the right response to a refresh that could not
    /// complete is to try again when the app comes forward or the network
    /// returns, rather than to wait for the next launch with sync switched off.
    func restoreProviderSession() async {
        guard supabaseAccessToken == nil,
              let session = currentSession,
              session.mode.isSupabaseBacked else { return }
        guard let tokens = SupabaseSessionStore.load(), tokens.userID == session.accountID else {
            // A real Supabase account (uuid id) with no credential behind it
            // cannot sync or delete itself. Say so rather than launching into a
            // session that only looks signed in. Test and legacy sessions keyed
            // by a non-uuid id never had a credential to lose.
            needsReauthentication = UUID(uuidString: session.accountID) != nil
            return
        }
        // A stored access token that is still valid needs no round trip; only a
        // near-expired one is exchanged.
        guard tokens.needsRefresh else {
            supabaseAccessToken = tokens.accessToken
            return
        }
        // `performRefresh` discards the tokens only when the server actually
        // refuses them, and keeps them when it merely failed to answer.
        _ = await sharedRefresh(tokens: tokens)
    }

    /// What a repair attempt from Settings did.
    enum ReauthenticationOutcome: Equatable {
        case restored
        /// A valid sign-in, but for a different identity than the one this
        /// grove belongs to.
        case wrongAccount
        case failed
    }

    /// Puts a working credential back on a signed-in provider account without
    /// signing out.
    ///
    /// The grove on this iPhone is keyed by the account id, so someone whose
    /// refresh token has genuinely gone needs to lose nothing: proving the same
    /// identity again is the entire repair, and every plant, photo and queued
    /// change stays where it is. The previous advice — sign out, then sign back
    /// in — asked the user to take their whole grove offline on the promise that
    /// the sign-in would return the same account id.
    ///
    /// A different identity is refused outright. Storing *those* tokens under
    /// this account id would point the sync engine at someone else's grove.
    @discardableResult
    func reauthenticateCurrentAccount(method: OnboardingAuthMethod) async -> ReauthenticationOutcome {
        guard let current = currentSession,
              current.mode.isSupabaseBacked,
              reauthenticationMethod == method else {
            signInError = "Use the same sign-in method that owns this grove."
            return .failed
        }
        guard let authClient = authClientProvider() else {
            signInError = "Account sign-in isn't configured in this build."
            return .failed
        }
        let authenticationGeneration = pendingAuthenticationGeneration

        let exchanged: SupabaseAuthClient.Session?
        switch method {
        case .apple:
            guard let credential = pendingApple, let idToken = credential.identityToken else {
                return failReauthentication()
            }
            exchanged = await exchange(
                provider: .apple,
                idToken: idToken,
                nonce: credential.rawNonce,
                using: authClient,
                expectedAuthenticationGeneration: authenticationGeneration
            )
        case .google:
            guard let credential = pendingGoogle else { return failReauthentication() }
            exchanged = await exchange(
                provider: .google,
                idToken: credential.idToken,
                nonce: nil,
                using: authClient,
                expectedAuthenticationGeneration: authenticationGeneration
            )
        case .email:
            exchanged = pendingEmail
        case .device:
            // No remote identity to prove.
            return .failed
        }

        // `exchange` has already left an actionable `signInError`.
        guard let exchanged else { return .failed }

        guard exchanged.userID == current.accountID else {
            // Nothing local is touched, and the session just obtained for the
            // other identity is revoked rather than written to the Keychain.
            await revokeRemoteSession(
                accessToken: exchanged.accessToken,
                refreshToken: exchanged.refreshToken,
                userID: exchanged.userID,
                expiresAt: exchanged.expiresAt,
                using: authClient
            )
            if authenticationIsCurrent(authenticationGeneration) {
                clearPendingAuthentication()
            }
            signInError = nil
            return .wrongAccount
        }
        guard let durable = await durableInteractiveSession(
            exchanged,
            using: authClient,
            expectedGeneration: authenticationGeneration
        ) else { return .failed }
        guard authenticationIsCurrent(authenticationGeneration) else { return .failed }
        clearPendingAuthentication()

        guard persistRefreshToken(durable, accountID: durable.userID) else {
            signInError = "This iPhone couldn't securely save the sign-in. Check that it is unlocked and try again."
            return .failed
        }
        cacheAccessToken(from: durable)
        needsReauthentication = false
        signInError = nil
        return .restored
    }

    private func failReauthentication() -> ReauthenticationOutcome {
        clearPendingAuthentication()
        signInError = "That sign-in didn't come through. Try again."
        return .failed
    }

    /// Persists the tokens from a fresh Supabase session, keyed to the account
    /// they belong to.
    private func persistRefreshToken(_ session: SupabaseAuthClient.Session, accountID: String) -> Bool {
        invalidateProviderRefreshWork()
        guard let refreshToken = session.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            SupabaseSessionStore.clear()
            supabaseAccessToken = nil
            return false
        }
        let saved = SupabaseSessionStore.save(
            SupabaseTokenSet(
                userID: accountID,
                accessToken: session.accessToken,
                refreshToken: refreshToken,
                expiresAt: session.expiresAt
            )
        )
        if !saved {
            SupabaseSessionStore.clear()
            supabaseAccessToken = nil
        }
        return saved
    }

    /// A held sign-up session can outlive its access token. Keep the refresh
    /// token and original deadline, but never advertise that stale bearer as an
    /// in-memory session; Root's normal restore path will exchange it first.
    private func cacheAccessToken(from session: SupabaseAuthClient.Session) {
        supabaseAccessToken = session.needsRefresh ? nil : session.accessToken
    }

    #if targetEnvironment(simulator)
    /// Never grants provider credentials, cloud sync, or a paid entitlement.
    func startSimulatorTroubleshooting() {
        guard case .signedOut = state else { return }
        cancelPendingAuthentication()
        clearSupabaseTokens()
        establish(UserSession(
            accountID: "simulator-troubleshooting-v1",
            mode: .demo,
            displayName: "Test Gardener"
        ))
    }
    #endif

    private func establish(_ session: UserSession) {
        if let data = try? JSONEncoder().encode(session) {
            storage.set(data, forKey: storageKey)
        }
        signInError = nil
        needsReauthentication = false
        state = .signedIn(session)
    }

    // MARK: - Sign in with Apple nonce

    /// A cryptographically random nonce, per Apple's Sign in with Apple
    /// guidance. `SystemRandomNumberGenerator` is cryptographically secure on
    /// Apple platforms; values are drawn uniformly from a 64-character set
    /// (bytes ≥ 64 are discarded to avoid modulo bias).
    private static func randomNonceString(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        var result = ""
        var remaining = length
        while remaining > 0 {
            let random = UInt8.random(in: 0...255, using: &generator)
            if Int(random) < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
