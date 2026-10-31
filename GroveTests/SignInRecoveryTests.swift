import Dispatch
import XCTest
@testable import Grove

/// Regressions for the two ways "I already have a Grove" used to refuse people
/// who really did have one.
@MainActor
final class SignInRecoveryTests: XCTestCase {
    override func tearDown() {
        RecoveryAuthURLProtocol.handler = nil
        SupabaseSessionStore.clear()
        super.tearDown()
    }

    // MARK: - Google configuration is one indivisible pair

    /// The client id and callback scheme are one configuration unit. Deriving
    /// the scheme from the same id prevents a build from presenting Google and
    /// then failing only after the user leaves Grove for the provider sheet.
    func testGoogleCallbackSchemeIsDerivedFromTheSameClientID() {
        XCTAssertEqual(
            GoogleAuthenticator.expectedReversedClientID(
                for: "000000000000-example.apps.googleusercontent.com"
            ),
            "com.googleusercontent.apps.000000000000-example"
        )
    }

    // MARK: - Sign-in and sign-up remain distinct

    /// Every method maps to the account mode its finished session carries, which
    /// is what lets `completeOnboarding` recognise the session the returning
    /// route is holding instead of asking a provider for a second credential.
    func testEveryAuthMethodMapsToItsSupabaseBackedAccountMode() {
        for method in [OnboardingAuthMethod.apple, .google, .email] {
            XCTAssertTrue(
                method.accountMode.isSupabaseBacked,
                "\(method) should finish on a Supabase-backed account"
            )
        }
        XCTAssertEqual(OnboardingAuthMethod.apple.accountMode, .apple)
        XCTAssertEqual(OnboardingAuthMethod.google.accountMode, .google)
        XCTAssertEqual(OnboardingAuthMethod.email.accountMode, .email)
        XCTAssertEqual(OnboardingAuthMethod.device.accountMode, .local)
        XCTAssertFalse(OnboardingAuthMethod.device.accountMode.isSupabaseBacked)
    }

    /// With no credential stashed there is nothing to exchange, so the returning
    /// route reports that it could not reach the account — it must never fall
    /// through to a session of any kind.
    func testResumingWithNoCredentialReportsAnUnreachableAccountAndStaysSignedOut() async {
        let suiteName = "SignInRecoveryTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage)

        for method in OnboardingAuthMethod.allCases {
            let outcome = await service.resumeExistingAccount(method: method)
            XCTAssertEqual(outcome, .unreachable, "\(method) had no credential to exchange")
        }
        XCTAssertEqual(service.state, .signedOut)
        XCTAssertNotNil(service.signInError)
    }

    func testReturningGoogleWithoutAnAccountServiceNeverCreatesALocalSession() async {
        let suiteName = "SignInRecoveryUnconfiguredTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage, authClientProvider: { nil })
        service.stashGoogleCredential(userID: "108423", idToken: "token", displayName: "Ari")

        let outcome = await service.resumeExistingAccount(method: .google)

        XCTAssertEqual(outcome, .unreachable)
        XCTAssertEqual(service.state, .signedOut)
        XCTAssertNotNil(service.signInError)
    }

    /// Account existence is not plant existence. A person who created an account
    /// earlier must be signed in even if they have not added their first plant.
    func testExistingAccountSignsInWithoutDependingOnAccountContent() async {
        let suiteName = "SignInRecoveryExistingAccountTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let client = makeAuthClient(
            userCreatedAt: .now.addingTimeInterval(-60),
            lastSignInAt: .now,
            signupCompleted: true
        )
        let service = SessionService(
            storage: storage,
            authClientProvider: { client }
        )
        service.stashGoogleCredential(userID: "108423", idToken: "token", displayName: "Ari")

        let outcome = await service.resumeExistingAccount(method: .google)

        XCTAssertEqual(outcome, .signedIn)
        XCTAssertEqual(service.currentSession?.accountID, "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6")
        XCTAssertEqual(service.currentSession?.mode, .google)
        XCTAssertNil(service.pendingSignup)
    }

    /// A fresh provider identity must stop at a clear sign-up offer. It cannot
    /// silently begin the questions simply because the auth grant made a user.
    func testFreshProviderIdentityOffersSignupAndStaysSignedOutUntilAccepted() async {
        let suiteName = "SignInRecoveryFreshAccountTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let now = Date.now
        let client = makeAuthClient(
            userCreatedAt: now,
            lastSignInAt: now,
            signupCompleted: false
        )
        let service = SessionService(
            storage: storage,
            authClientProvider: { client }
        )
        service.stashGoogleCredential(userID: "108423", idToken: "token", displayName: "Ari")

        let outcome = await service.resumeExistingAccount(method: .google)

        XCTAssertEqual(outcome, .accountNotFound)
        XCTAssertEqual(service.state, .signedOut)
        XCTAssertNotNil(service.pendingSignup)
    }

    func testCancelingAHeldSignupRevokesItsServerSession() async {
        let logout = expectation(description: "abandoned signup session revoked")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryAuthURLProtocol.self]
        RecoveryAuthURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(
                url: url, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            if url.path == "/rest/v1/rpc/grove_signup_completed" {
                return (response, Data("false".utf8))
            }
            if url.path == "/auth/v1/logout" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-access")
                logout.fulfill()
                return (response, Data())
            }
            return (
                response,
                Data(
                    #"{"access_token":"account-access","refresh_token":"account-refresh","expires_in":3600,"user":{"id":"A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"}}"#.utf8
                )
            )
        }
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        let suiteName = "SignInRecoveryCancelHeldSignup-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage, authClientProvider: { client })
        service.stashGoogleCredential(userID: "108423", idToken: "token", displayName: "Ari")

        let outcome = await service.resumeExistingAccount(method: .google)
        XCTAssertEqual(outcome, .accountNotFound)

        service.cancelPendingAuthentication()

        await fulfillment(of: [logout], timeout: 2)
        XCTAssertNil(service.pendingSignup)
        XCTAssertEqual(service.state, .signedOut)
    }

    func testHeldSignupKeepsNewPlantAndLocationWithoutOverwritingAProfileCompletedElsewhere() async {
        let accountID = "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"
        let firstPlantID = UUID()
        let location = GroveLocation(
            latitude: 51.4545,
            longitude: -2.5879,
            label: "Bristol, United Kingdom",
            countryCode: "GB",
            timeZoneIdentifier: "Europe/London"
        )
        let statusReads = RecoveryCounter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryAuthURLProtocol.self]
        RecoveryAuthURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(
                url: url, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            if url.path == "/rest/v1/rpc/grove_signup_completed" {
                let read = statusReads.increment()
                return (response, Data((read == 1 ? "false" : "true").utf8))
            }
            XCTAssertEqual(url.path, "/auth/v1/token")
            return (
                response,
                Data(
                    #"{"access_token":"account-access","refresh_token":"account-refresh","expires_in":3600,"user":{"id":"A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"}}"#.utf8
                )
            )
        }
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        let suiteName = "SignInRecoveryCrossDeviceSignup-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage, authClientProvider: { client })
        service.stashGoogleCredential(userID: "108423", idToken: "token", displayName: "Old answer")

        let resume = await service.resumeExistingAccount(method: .google)
        let completion = await service.completeOnboarding(
            method: .google,
            displayName: "Stale answer",
            location: location,
            pendingFirstPlantID: firstPlantID
        )

        XCTAssertEqual(resume, .accountNotFound)
        XCTAssertEqual(completion, .signedIn)
        XCTAssertEqual(statusReads.value, 2, "Completion must re-check the marker after a held signup")
        XCTAssertEqual(service.currentSession?.accountID, accountID)
        XCTAssertEqual(
            service.currentSession?.pendingFirstPlantID,
            firstPlantID,
            "A newly scanned plant is additive work and must survive even when account provisioning already won elsewhere"
        )
        XCTAssertEqual(service.currentSession?.location, location)
        XCTAssertNil(
            service.pendingInitialProfileSync(accountID: accountID),
            "The profile completed elsewhere must not be overwritten with stale onboarding answers"
        )
    }

    func testLostSignupCompletionResponseRecoversTheDurableHandoffOnNextLogin() async {
        let accountID = "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"
        let firstPlantID = UUID()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryAuthURLProtocol.self]
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        let suiteName = "SignInRecoveryLostCompletion-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let completionClaims = RecoveryPathRecorder()

        RecoveryAuthURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/rest/v1/rpc/grove_complete_signup" {
                completionClaims.append(try signupClaimID(from: request))
                let failure = HTTPURLResponse(
                    url: url, statusCode: 502,
                    httpVersion: nil, headerFields: nil
                )!
                return (failure, Data(#"{"message":"response lost"}"#.utf8))
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            if url.path == "/rest/v1/rpc/grove_signup_completed" {
                return (response, Data("false".utf8))
            }
            return (
                response,
                Data(
                    #"{"access_token":"first-access","refresh_token":"first-refresh","expires_in":3600,"user":{"id":"A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"}}"#.utf8
                )
            )
        }
        let interrupted = SessionService(storage: storage, authClientProvider: { client })
        interrupted.stashGoogleCredential(userID: "108423", idToken: "token", displayName: "Ari")
        let firstResume = await interrupted.resumeExistingAccount(method: .google)
        let firstCompletion = await interrupted.completeOnboarding(
            method: .google,
            displayName: "Ari",
            pendingFirstPlantID: firstPlantID
        )
        XCTAssertEqual(firstResume, .accountNotFound)
        XCTAssertEqual(firstCompletion, .failed)

        RecoveryAuthURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(
                url: url, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            if url.path == "/rest/v1/rpc/grove_signup_completed" {
                return (response, Data("true".utf8))
            }
            if url.path == "/rest/v1/rpc/grove_complete_signup" {
                completionClaims.append(try signupClaimID(from: request))
                return (response, Data("true".utf8))
            }
            return (
                response,
                Data(
                    #"{"access_token":"retry-access","refresh_token":"retry-refresh","expires_in":3600,"user":{"id":"A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"}}"#.utf8
                )
            )
        }
        let relaunched = SessionService(storage: storage, authClientProvider: { client })
        relaunched.stashGoogleCredential(userID: "108423", idToken: "token", displayName: nil)

        let recovered = await relaunched.resumeExistingAccount(method: .google)

        XCTAssertEqual(recovered, .signedIn)
        XCTAssertEqual(relaunched.currentSession?.accountID, accountID)
        XCTAssertEqual(relaunched.currentSession?.displayName, "Ari")
        XCTAssertEqual(relaunched.currentSession?.pendingFirstPlantID, firstPlantID)
        XCTAssertNotNil(relaunched.pendingInitialProfileSync(accountID: accountID))
        XCTAssertEqual(completionClaims.values.count, 2)
        XCTAssertEqual(
            completionClaims.values.first,
            completionClaims.values.last,
            "The retry must prove the same durable completion claim"
        )
    }

    func testRelaunchDiscardsAStagedHandoffWhenAnotherDeviceWonCompletion() async {
        let accountID = "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"
        let firstPlantID = UUID()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryAuthURLProtocol.self]
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        let suiteName = "SignInRecoveryLostRace-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }

        RecoveryAuthURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/rest/v1/rpc/grove_complete_signup" {
                let failure = HTTPURLResponse(
                    url: url, statusCode: 502,
                    httpVersion: nil, headerFields: nil
                )!
                return (failure, Data(#"{"message":"response lost"}"#.utf8))
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            if url.path == "/rest/v1/rpc/grove_signup_completed" {
                return (response, Data("false".utf8))
            }
            return (
                response,
                Data(
                    #"{"access_token":"first-access","refresh_token":"first-refresh","expires_in":3600,"user":{"id":"A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"}}"#.utf8
                )
            )
        }
        let interrupted = SessionService(storage: storage, authClientProvider: { client })
        interrupted.stashGoogleCredential(userID: "108423", idToken: "token", displayName: "Stale Ari")
        let firstResume = await interrupted.resumeExistingAccount(method: .google)
        let firstCompletion = await interrupted.completeOnboarding(
            method: .google,
            displayName: "Stale Ari",
            pendingFirstPlantID: firstPlantID
        )
        XCTAssertEqual(firstResume, .accountNotFound)
        XCTAssertEqual(firstCompletion, .failed)

        RecoveryAuthURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(
                url: url, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            if url.path == "/rest/v1/rpc/grove_signup_completed" {
                return (response, Data("true".utf8))
            }
            if url.path == "/rest/v1/rpc/grove_complete_signup" {
                return (response, Data("false".utf8))
            }
            return (
                response,
                Data(
                    #"{"access_token":"winner-access","refresh_token":"winner-refresh","expires_in":3600,"user":{"id":"A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"}}"#.utf8
                )
            )
        }
        let relaunched = SessionService(storage: storage, authClientProvider: { client })
        relaunched.stashGoogleCredential(userID: "108423", idToken: "token", displayName: "Server name")

        let recovered = await relaunched.resumeExistingAccount(method: .google)

        XCTAssertEqual(recovered, .signedIn)
        XCTAssertNil(relaunched.currentSession?.pendingFirstPlantID)
        XCTAssertNil(relaunched.pendingInitialProfileSync(accountID: accountID))
    }

    /// The returning route can receive an already-expired provider token (for
    /// example after a suspended network response). It must refresh before the
    /// session is held for signup, never make the stale bearer look new locally.
    func testExpiredProviderResponseIsRefreshedBeforeSignupIsHeld() async throws {
        SupabaseSessionStore.clear()
        let suiteName = "SignInRecoveryHeldExpiry-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer {
            storage.removePersistentDomain(forName: suiteName)
            SupabaseSessionStore.clear()
        }
        let authResponseDate = Date.now.addingTimeInterval(-7_200)
        let identityCreatedAt = authResponseDate
        let client = makeAuthClient(
            userCreatedAt: identityCreatedAt,
            lastSignInAt: identityCreatedAt,
            responseDate: authResponseDate,
            refreshResponseDate: .now,
            signupCompleted: false
        )
        let service = SessionService(storage: storage, authClientProvider: { client })
        service.stashGoogleCredential(userID: "108423", idToken: "token", displayName: "Ari")

        let resumeOutcome = await service.resumeExistingAccount(method: .google)
        XCTAssertEqual(resumeOutcome, .accountNotFound)
        let held = try XCTUnwrap(service.pendingSignup)
        let originalExpiry = authResponseDate.addingTimeInterval(3_600)
        XCTAssertGreaterThan(held.session.expiresAt, originalExpiry)

        let completion = await service.completeOnboarding(method: .google, displayName: "Ari")
        let persisted = try XCTUnwrap(SupabaseSessionStore.load())

        XCTAssertEqual(completion, .signedIn)
        XCTAssertEqual(persisted.expiresAt, held.session.expiresAt)
        XCTAssertFalse(persisted.needsRefresh)
        XCTAssertEqual(service.supabaseAccessToken, "account-access")
    }

    func testAlreadyExpiredRefreshResponseIsNeverAccepted() async {
        let staleDate = Date.now.addingTimeInterval(-7_200)
        let client = makeAuthClient(
            userCreatedAt: staleDate,
            lastSignInAt: staleDate,
            responseDate: staleDate,
            signupCompleted: true
        )
        let suiteName = "SignInRecoveryStaleRefresh-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage, authClientProvider: { client })
        service.stashGoogleCredential(userID: "108423", idToken: "token", displayName: "Ari")

        let outcome = await service.resumeExistingAccount(method: .google)

        XCTAssertEqual(outcome, .unreachable)
        XCTAssertEqual(service.state, .signedOut)
        XCTAssertNil(service.pendingSignup)
        XCTAssertNil(SupabaseSessionStore.load())
        XCTAssertTrue(service.signInError?.contains("already-expired") == true)
    }

    func testMalformedSessionLifetimeIsRejectedBeforeAnyAccountStateChanges() async {
        for expiresIn in [0, -1, 604_801] {
            let client = makeAuthClient(
                userCreatedAt: .now,
                lastSignInAt: .now,
                expiresIn: expiresIn,
                signupCompleted: true
            )
            let suiteName = "SignInRecoveryMalformedExpiry-\(expiresIn)-\(UUID().uuidString)"
            let storage = UserDefaults(suiteName: suiteName)!
            defer { storage.removePersistentDomain(forName: suiteName) }
            let service = SessionService(storage: storage, authClientProvider: { client })
            service.stashGoogleCredential(userID: "108423", idToken: "token", displayName: "Ari")

            let outcome = await service.resumeExistingAccount(method: .google)

            XCTAssertEqual(outcome, .unreachable)
            XCTAssertEqual(service.state, .signedOut)
            XCTAssertNil(service.pendingSignup)
            XCTAssertNil(SupabaseSessionStore.load())
        }
    }

    /// The no-account result gets its own explanatory step. Only an explicit
    /// acceptance turns the returning route into sign-up, and the credential is
    /// carried forward so it is never requested twice.
    func testAccountNotFoundRequiresExplicitSignupAcceptance() {
        let suiteName = "SignInRecoveryModelTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)

        model.signInToExistingAccount()
        XCTAssertEqual(model.step, .signIn)

        model.offerSignup(method: .google)

        XCTAssertEqual(model.step, .accountNotFound)
        XCTAssertEqual(model.route, .returning, "The route stays sign-in until the person accepts")
        XCTAssertFalse(model.arrivedFromSignIn)

        model.acceptSignupOffer()

        XCTAssertTrue(model.arrivedFromSignIn)
        XCTAssertEqual(model.route, .newAccount)
        XCTAssertEqual(model.authMethod, .google)
        XCTAssertEqual(model.step, .firstPlantScan, "The value-first scan starts straight after the sign-in that worked")
        XCTAssertFalse(
            model.orderedSteps.contains(.signIn),
            "A funnel already holding a session must never ask for another sign-in"
        )
        XCTAssertEqual(
            model.orderedSteps.last, .planReveal,
            "The scan-first flow should end on the invisible completion step that establishes the session"
        )
    }

    func testUsingADifferentSignInDoesNotStartSignup() {
        let suiteName = "SignInRecoveryDifferentAccountTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)

        model.signInToExistingAccount()
        model.offerSignup(method: .apple)
        model.useDifferentSignIn()

        XCTAssertEqual(model.step, .signIn)
        XCTAssertEqual(model.route, .returning)
        XCTAssertNil(model.authMethod)
        XCTAssertFalse(model.arrivedFromSignIn)
    }

    func testAReturningDraftCannotLeakIdentityOrManualAnswersAfterSignOut() {
        let suiteName = "SignInRecoveryReturningDraftPrivacy-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)
        model.firstName = "Previous person"
        model.experience = "experienced"
        model.environment = "outdoor"
        model.challenge = "watering"
        model.email = "previous@example.com"
        model.verificationCode = "123456"
        model.signInToExistingAccount()
        model.persistDraft()

        let relaunchedSignedOutFlow = OnboardingModel(storage: storage)

        XCTAssertEqual(relaunchedSignedOutFlow.step, .welcome)
        XCTAssertEqual(relaunchedSignedOutFlow.route, .newAccount)
        XCTAssertTrue(relaunchedSignedOutFlow.firstName.isEmpty)
        XCTAssertNil(relaunchedSignedOutFlow.experience)
        XCTAssertNil(relaunchedSignedOutFlow.environment)
        XCTAssertNil(relaunchedSignedOutFlow.challenge)
        XCTAssertTrue(relaunchedSignedOutFlow.email.isEmpty)
        XCTAssertTrue(relaunchedSignedOutFlow.verificationCode.isEmpty)
        XCTAssertNil(storage.data(forKey: "grove.onboarding.draft.v1"))
    }

    /// Walking back to the front door after accepting sign-up is the one way to
    /// abandon that account, so it has to drop the held sign-in with the route.
    func testReturningToTheWelcomeScreenDropsTheAcceptedSignIn() {
        let suiteName = "SignInRecoveryBackTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)

        model.signInToExistingAccount()
        model.offerSignup(method: .apple)
        model.acceptSignupOffer()
        model.back()

        XCTAssertEqual(model.step, .welcome)
        XCTAssertFalse(model.arrivedFromSignIn)
        XCTAssertNil(model.authMethod)
        XCTAssertTrue(
            model.orderedSteps.contains(.signIn),
            "Starting over has no credential in hand, so the gate comes back"
        )
    }

    func testManualFallbackKeepsAnAlreadyAcceptedProviderSession() {
        let suiteName = "SignInRecoveryManualFallback-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)

        model.signInToExistingAccount()
        model.offerSignup(method: .google)
        model.acceptSignupOffer()
        model.beginManualSetup()

        XCTAssertEqual(model.route, .manual)
        XCTAssertEqual(model.step, .explore)
        XCTAssertTrue(model.arrivedFromSignIn)
        XCTAssertEqual(model.authMethod, .google)
        XCTAssertFalse(model.orderedSteps.contains(.signIn))
        XCTAssertEqual(model.orderedSteps.last, .planReveal)
    }

    /// "Use a plant photo" on the no-plant route re-enters the scan-first
    /// funnel. The session accepted on the sign-in route must come with it.
    func testPhotoImportFromManualFallbackKeepsAnAlreadyAcceptedProviderSession() {
        let suiteName = "SignInRecoveryPhotoImport-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)

        model.signInToExistingAccount()
        model.offerSignup(method: .google)
        model.acceptSignupOffer()
        model.beginManualSetup()
        model.beginFirstPlant()

        XCTAssertEqual(model.route, .newAccount)
        XCTAssertEqual(model.step, .firstPlantScan)
        XCTAssertTrue(model.arrivedFromSignIn)
        XCTAssertEqual(model.authMethod, .google)
        XCTAssertFalse(model.orderedSteps.contains(.signIn))
        XCTAssertEqual(model.orderedSteps.last, .planReveal)
    }

    func testMissingFirstPlantRecoveryKeepsAnAlreadyAcceptedProviderSession() {
        let suiteName = "SignInRecoveryMissingPlant-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)

        model.signInToExistingAccount()
        model.offerSignup(method: .apple)
        model.acceptSignupOffer()
        model.recoverMissingFirstPlant()

        XCTAssertEqual(model.step, .firstPlantScan)
        XCTAssertTrue(model.arrivedFromSignIn)
        XCTAssertEqual(model.authMethod, .apple)
        XCTAssertFalse(model.orderedSteps.contains(.signIn))
    }

    func testCancellingSignupOfferClearsTheHeldSession() async throws {
        let suiteName = "SignInRecoveryAdoptionTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let now = Date.now
        let client = makeAuthClient(
            userCreatedAt: now,
            lastSignInAt: now,
            signupCompleted: false
        )
        let service = SessionService(
            storage: storage,
            authClientProvider: { client }
        )
        service.stashGoogleCredential(userID: "108423", idToken: "token", displayName: "Ari")

        let resumeOutcome = await service.resumeExistingAccount(method: .google)
        XCTAssertEqual(resumeOutcome, .accountNotFound)
        XCTAssertNotNil(service.pendingSignup)

        service.cancelPendingAuthentication()

        XCTAssertNil(service.pendingSignup)
        let completion = await service.completeOnboarding(method: .google, displayName: "Ari")
        XCTAssertEqual(completion, .failed)
        XCTAssertEqual(service.state, .signedOut)
    }

    /// The held session dies with the process, so a relaunch must land back at
    /// the gate rather than resuming a quiz that would finish onto nothing.
    func testAnAcceptedSignInDoesNotSurviveRelaunch() {
        let suiteName = "SignInRecoveryRelaunchTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }

        let model = OnboardingModel(storage: storage)
        model.signInToExistingAccount()
        model.offerSignup(method: .apple)
        model.acceptSignupOffer()
        model.firstName = "Ari"
        model.persistDraft()

        let relaunched = OnboardingModel(storage: storage)
        XCTAssertFalse(relaunched.arrivedFromSignIn)
        XCTAssertNil(relaunched.authMethod)
        XCTAssertEqual(relaunched.firstName, "Ari", "The answers still survive the relaunch")
        XCTAssertTrue(relaunched.orderedSteps.contains(.signIn))
    }

    func testEmailValidationRejectsCommonMalformedAddresses() {
        let suiteName = "SignInRecoveryEmailValidation-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)

        for invalid in [
            "a@b", "a@@b.com", ".a@example.com", "a..b@example.com",
            "a b@example.com", "a,b@example.com", "a@example..com",
            "a@-example.com", "a@example.1"
        ] {
            model.email = invalid
            XCTAssertFalse(model.isEmailValid, "\(invalid) should not pass validation")
        }

        model.email = "  Gardener@Example.COM  "
        XCTAssertTrue(model.isEmailValid)
        XCTAssertEqual(model.normalizedEmail, "gardener@example.com")

        XCTAssertEqual(OnboardingModel.sanitizedVerificationCode("12 34-567"), "123456")
        XCTAssertEqual(
            OnboardingModel.sanitizedVerificationCode("١٢٣456"),
            "456",
            "Non-ASCII numerals must not render as a complete Supabase code"
        )
        model.step = .emailVerification
        model.verificationCode = "١٢٣456"
        XCTAssertFalse(model.canAdvanceFromCurrentStep)
    }

    func testSignupNameAndGeneratedUsernameStayInsideServerContracts() {
        let suiteName = "SignInRecoveryProfileContract-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(storage: storage)
        model.step = .name
        model.firstName = String(repeating: "a", count: SessionService.maxDisplayNameLength + 1)
        XCTAssertFalse(model.canAdvanceFromCurrentStep)
        XCTAssertEqual(
            SessionService.normalizedDisplayName(model.firstName).count,
            SessionService.maxDisplayNameLength
        )
        XCTAssertLessThanOrEqual(
            SessionService.normalizedDisplayName(String(repeating: "e\u{301}", count: 81))
                .unicodeScalars.count,
            SessionService.maxDisplayNameLength
        )
        XCTAssertEqual(
            SessionService.normalizedDisplayName("  Ari\n\u{202E}Green\t  "),
            "Ari Green"
        )

        for name in ["José 🌿", "李雷", "Ｆｕｌｌ Ｗｉｄｔｈ", "___"] {
            let username = SessionService.generatedUsername(from: name)
            XCTAssertNotNil(username.range(of: #"^[a-z0-9_]{3,24}$"#, options: .regularExpression))
            XCTAssertLessThanOrEqual(username.count, 24)
        }
        XCTAssertTrue(SessionService.generatedUsername(from: "José").hasPrefix("jose_"))
    }

    func testEmailSurvivesAReauthenticationDraftRecovery() {
        let suiteName = "SignInRecoveryEmailDraft-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let interrupted = OnboardingModel(storage: storage)
        interrupted.email = "gardener@example.com"
        interrupted.authMethod = .email
        interrupted.step = .emailVerification
        interrupted.persistDraft()

        let restored = OnboardingModel(storage: storage)

        XCTAssertEqual(restored.step, .signIn)
        XCTAssertNil(restored.authMethod)
        XCTAssertEqual(restored.email, "gardener@example.com")
    }

    /// Cancellation is a credential boundary, not just a spinner update. A
    /// response already delivered by URLSession can resume after Task.cancel(),
    /// so the service generation must reject it independently.
    func testCancelledSlowResumeCannotSignInWhenItsStatusResponseArrivesLate() async throws {
        let statusStarted = expectation(description: "signup status started")
        let releaseStatus = DispatchSemaphore(value: 0)
        defer { releaseStatus.signal() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryAuthURLProtocol.self]
        RecoveryAuthURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.path == "/rest/v1/rpc/grove_signup_completed" {
                statusStarted.fulfill()
                releaseStatus.wait()
                return (response, Data("true".utf8))
            }
            return (
                response,
                Data(
                    #"{"access_token":"late-access","refresh_token":"late-refresh","expires_in":3600,"user":{"id":"A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"}}"#.utf8
                )
            )
        }
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        let suiteName = "SignInRecoveryCancelledResume-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage, authClientProvider: { client })
        service.stashGoogleCredential(userID: "108423", idToken: "token", displayName: "Ari")

        let resume = Task { await service.resumeExistingAccount(method: .google) }
        await fulfillment(of: [statusStarted], timeout: 2)
        service.cancelPendingAuthentication()
        releaseStatus.signal()
        let outcome = await resume.value

        XCTAssertEqual(outcome, .unreachable)
        XCTAssertEqual(service.state, .signedOut)
        XCTAssertNil(service.currentSession)
        XCTAssertNil(service.pendingSignup)
        XCTAssertNil(SupabaseSessionStore.load())
        XCTAssertNil(service.signInError)
    }

    func testProviderSessionWithoutRefreshTokenNeverBecomesAnAccount() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryAuthURLProtocol.self]
        RecoveryAuthURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/auth/v1/token")
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (
                response,
                Data(
                    #"{"access_token":"one-hour-only","expires_in":3600,"user":{"id":"A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"}}"#.utf8
                )
            )
        }
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        let suiteName = "SignInRecoveryMissingRefresh-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage, authClientProvider: { client })
        service.stashGoogleCredential(userID: "108423", idToken: "token", displayName: "Ari")

        let outcome = await service.completeOnboarding(method: .google, displayName: "Ari")

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(service.state, .signedOut)
        XCTAssertNil(SupabaseSessionStore.load())
        XCTAssertTrue(service.signInError?.contains("lasting credential") == true)
    }

    func testNormalSignOutRevokesOnlyTheRemoteSessionAndAlwaysClearsLocalState() async throws {
        let accountID = "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryAuthURLProtocol.self]
        RecoveryAuthURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.grove.test/auth/v1/logout?scope=local")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer active-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "publishable-key")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 204,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        let suiteName = "SignInRecoveryRemoteLogout-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        storage.set(
            try JSONEncoder().encode(UserSession(accountID: accountID, mode: .google, displayName: "Ari")),
            forKey: "grove.user.session.v1"
        )
        SupabaseSessionStore.save(
            SupabaseTokenSet(
                userID: accountID,
                accessToken: "active-access",
                refreshToken: "active-refresh",
                expiresAt: .now.addingTimeInterval(3_600)
            )
        )
        let service = SessionService(storage: storage, authClientProvider: { client })

        await service.signOutAndRevokeRemoteSession()

        XCTAssertEqual(service.state, .signedOut)
        XCTAssertNil(SupabaseSessionStore.load())
        XCTAssertNil(storage.data(forKey: "grove.user.session.v1"))
    }

    func testSignOutRefreshesAndRetriesWhenServerRejectsALocallyValidBearer() async throws {
        let accountID = "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"
        let requests = RecoveryPathRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryAuthURLProtocol.self]
        // `@Sendable` keeps this closure and its nested `filter` off the test's
        // main actor. Inherited isolation made the isolation check trap on
        // URLSession's queue and take the whole test host with it.
        RecoveryAuthURLProtocol.handler = { @Sendable request in
            let url = try XCTUnwrap(request.url)
            requests.append("\(url.path)?\(url.query ?? ""):\(request.value(forHTTPHeaderField: "Authorization") ?? "")")
            if url.path == "/auth/v1/token" {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (
                    response,
                    Data(
                        #"{"access_token":"fresh-logout-access","refresh_token":"fresh-logout-refresh","expires_in":3600,"user":{"id":"A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"}}"#.utf8
                    )
                )
            }
            let logoutAttempt = requests.values.filter { $0.hasPrefix("/auth/v1/logout") }.count
            let status = logoutAttempt == 1 ? 401 : 204
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, status == 401 ? Data(#"{"message":"JWT expired"}"#.utf8) : Data())
        }
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        let suiteName = "SignInRecoveryRejectedLogoutBearer-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        storage.set(
            try JSONEncoder().encode(UserSession(accountID: accountID, mode: .google, displayName: "Ari")),
            forKey: "grove.user.session.v1"
        )
        SupabaseSessionStore.save(
            SupabaseTokenSet(
                userID: accountID,
                accessToken: "locally-valid-access",
                refreshToken: "logout-refresh",
                expiresAt: .now.addingTimeInterval(3_600)
            )
        )
        let service = SessionService(storage: storage, authClientProvider: { client })

        await service.signOutAndRevokeRemoteSession()

        XCTAssertEqual(
            requests.values,
            [
                "/auth/v1/logout?scope=local:Bearer locally-valid-access",
                "/auth/v1/token?grant_type=refresh_token:",
                "/auth/v1/logout?scope=local:Bearer fresh-logout-access"
            ]
        )
        XCTAssertEqual(service.state, .signedOut)
        XCTAssertNil(SupabaseSessionStore.load())
    }

    func testEmailCodeCanRepairTheMatchingExistingAccountInPlace() async throws {
        let accountID = "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryAuthURLProtocol.self]
        RecoveryAuthURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/auth/v1/verify")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (
                response,
                Data(
                    #"{"access_token":"email-access","refresh_token":"email-refresh","expires_in":3600,"user":{"id":"A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"}}"#.utf8
                )
            )
        }
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        let suiteName = "SignInRecoveryEmailRepair-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        storage.set(
            try JSONEncoder().encode(UserSession(accountID: accountID, mode: .email, displayName: "Ari")),
            forKey: "grove.user.session.v1"
        )
        let service = SessionService(storage: storage, authClientProvider: { client })

        let verified = await service.verifyEmailCode(email: "ari@example.com", code: "123456")
        let outcome = await service.reauthenticateCurrentAccount(method: .email)

        XCTAssertTrue(verified)
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(service.currentSession?.accountID, accountID)
        XCTAssertEqual(SupabaseSessionStore.load()?.userID, accountID)
        XCTAssertEqual(SupabaseSessionStore.load()?.refreshToken, "email-refresh")
        XCTAssertEqual(service.supabaseAccessToken, "email-access")
    }

    func testEmailCodeForAnotherIdentityCannotReplaceTheExistingAccount() async throws {
        let accountID = "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"
        let requests = RecoveryPathRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryAuthURLProtocol.self]
        RecoveryAuthURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            requests.append(url.path)
            if url.path == "/auth/v1/logout" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer other-access")
                let response = HTTPURLResponse(
                    url: url, statusCode: 204,
                    httpVersion: nil, headerFields: nil
                )!
                return (response, Data())
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (
                response,
                Data(
                    #"{"access_token":"other-access","refresh_token":"other-refresh","expires_in":3600,"user":{"id":"02D2DB36-4C93-433C-A895-51001744ABEF"}}"#.utf8
                )
            )
        }
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        let suiteName = "SignInRecoveryEmailWrongAccount-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        storage.set(
            try JSONEncoder().encode(UserSession(accountID: accountID, mode: .email, displayName: "Ari")),
            forKey: "grove.user.session.v1"
        )
        let service = SessionService(storage: storage, authClientProvider: { client })

        let verified = await service.verifyEmailCode(email: "other@example.com", code: "123456")
        let outcome = await service.reauthenticateCurrentAccount(method: .email)

        XCTAssertTrue(verified)
        XCTAssertEqual(outcome, .wrongAccount)
        XCTAssertEqual(service.currentSession?.accountID, accountID)
        XCTAssertNil(SupabaseSessionStore.load(), "Another person's tokens must never be persisted")
        XCTAssertNil(service.supabaseAccessToken)
        XCTAssertEqual(requests.values, ["/auth/v1/verify", "/auth/v1/logout"])
    }

    func testReturningEmailDoesNotRevealUnknownAccountWording() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryAuthURLProtocol.self]
        RecoveryAuthURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 422,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"message":"User not found"}"#.utf8))
        }
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        let suiteName = "SignInRecoveryEmailPrivacy-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage, authClientProvider: { client })

        let sent = await service.sendEmailCode(to: "unknown@example.com", createAccount: false)

        XCTAssertTrue(sent, "The UI must look the same as a real email-code send")
        XCTAssertNil(service.signInError)
    }

    private func makeAuthClient(
        userCreatedAt: Date,
        lastSignInAt: Date,
        responseDate: Date = .now,
        refreshResponseDate: Date? = nil,
        expiresIn: Int = 3_600,
        signupCompleted: Bool
    ) -> SupabaseAuthClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryAuthURLProtocol.self]
        let createdAt = ISO8601DateFormatter().string(from: userCreatedAt)
        let signedInAt = ISO8601DateFormatter().string(from: lastSignInAt)
        let responseClock = RecoveryResponseClock(
            dates: [responseDate] + (refreshResponseDate.map { [$0] } ?? [])
        )
        RecoveryAuthURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(
                url: url, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            if url.path == "/rest/v1/rpc/grove_signup_completed" {
                return (response, Data(String(signupCompleted).utf8))
            }
            if url.path == "/rest/v1/rpc/grove_complete_signup" {
                return (response, Data("true".utf8))
            }
            if url.path == "/auth/v1/logout" {
                return (response, Data())
            }
            XCTAssertTrue(
                url.absoluteString == "https://auth.grove.test/auth/v1/token?grant_type=id_token"
                    || url.absoluteString == "https://auth.grove.test/auth/v1/token?grant_type=refresh_token"
            )
            let payload = Data(
                """
                {
                  "access_token": "account-access",
                  "refresh_token": "account-refresh",
                  "expires_in": \(expiresIn),
                  "user": {
                    "id": "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
                    "created_at": "\(createdAt)",
                    "last_sign_in_at": "\(signedInAt)"
                  }
                }
                """.utf8
            )
            return (response, payload)
        }
        return SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration),
            dateProvider: { responseClock.next() }
        )
    }
}

private final class RecoveryResponseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]
    private var index = 0

    init(dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        guard !dates.isEmpty else { return .now }
        let date = dates[min(index, dates.count - 1)]
        index += 1
        return date
    }
}

private final class RecoveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class RecoveryPathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    func append(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }
}

private func signupClaimID(from request: URLRequest) throws -> String {
    let body: Data
    if let httpBody = request.httpBody {
        body = httpBody
    } else {
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var streamed = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw try XCTUnwrap(stream.streamError) }
            if count == 0 { break }
            streamed.append(buffer, count: count)
        }
        body = streamed
    }
    let object = try JSONSerialization.jsonObject(with: body)
    let payload = try XCTUnwrap(object as? [String: String])
    let claim = try XCTUnwrap(payload["p_claim_id"])
    XCTAssertNotNil(UUID(uuidString: claim))
    return claim
}

private final class RecoveryAuthURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
