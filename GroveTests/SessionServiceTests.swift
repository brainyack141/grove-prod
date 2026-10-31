import AuthenticationServices
import Dispatch
import XCTest
@testable import Grove

@MainActor
final class SessionServiceTests: XCTestCase {
    func testAuthBaseURLMustBeAbsoluteHTTPSWithoutEmbeddedCredentials() {
        XCTAssertTrue(SupabaseAuthClient.isSecureAuthBaseURL(URL(string: "https://project.supabase.co/")!))
        XCTAssertFalse(SupabaseAuthClient.isSecureAuthBaseURL(URL(string: "http://project.supabase.co/")!))
        XCTAssertFalse(SupabaseAuthClient.isSecureAuthBaseURL(URL(string: "https://user:pass@project.supabase.co/")!))
        XCTAssertFalse(SupabaseAuthClient.isSecureAuthBaseURL(URL(string: "https://project.supabase.co/?redirect=evil")!))
        XCTAssertFalse(SupabaseAuthClient.isSecureAuthBaseURL(URL(string: "auth.local", relativeTo: URL(string: "https://example.com")!)!))
    }

    func testFailedAppleCallbackInvalidatesItsNonceAndState() {
        let suiteName = "SessionServiceAppleFailure-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage)
        let request = ASAuthorizationAppleIDProvider().createRequest()
        service.prepareAppleRequest(request)

        XCTAssertNotNil(request.nonce)
        XCTAssertNotNil(request.state)
        XCTAssertEqual(
            service.stashAppleCredential(.failure(URLError(.cancelled))),
            .failed
        )
        XCTAssertEqual(
            service.stashAppleCredential(.failure(URLError(.cancelled))),
            .stale,
            "A second callback for the abandoned request must not revive it"
        )
    }

    func testSessionRestorationClearsAKeychainCredentialOwnedByAnotherAccount() throws {
        let accountA = "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"
        let accountB = "B0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"
        let suiteName = "SessionServiceMismatchedKeychain-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        storage.set(
            try JSONEncoder().encode(UserSession(accountID: accountA, mode: .google, displayName: "A")),
            forKey: "grove.user.session.v1"
        )
        XCTAssertTrue(
            SupabaseSessionStore.save(
                SupabaseTokenSet(
                    userID: accountB,
                    accessToken: "account-b-access",
                    refreshToken: "account-b-refresh",
                    expiresAt: .now.addingTimeInterval(3_600)
                )
            )
        )

        let restored = SessionService(storage: storage)

        XCTAssertEqual(restored.currentSession?.accountID, accountA)
        XCTAssertNil(SupabaseSessionStore.load())
        XCTAssertFalse(restored.isSupabaseBacked)
    }

    override func tearDown() {
        AuthMockURLProtocol.handler = nil
        SupabaseSessionStore.clear()
        BotanistSessionStore.clear()
        OnboardingGuestSessionStore.clear()
        UserDefaults.standard.removeObject(forKey: GroveDefaults.onboardingGuestCredentialPresent)
        super.tearDown()
    }

    /// A session has to outlive the process that created it: the account id is
    /// the key the entire grove is stored under, so a relaunch that forgets it
    /// loses the plants. Driven through the device-only path, which is the one
    /// establish route that needs no server — the demo entry point it used to
    /// use was withdrawn once nothing in the app offered a demo grove.
    func testASignedInSessionSurvivesRelaunchAndSignOutClearsIt() async throws {
        let suiteName = "SessionServiceTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        storage.removePersistentDomain(forName: suiteName)
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage)

        XCTAssertEqual(service.state, .signedOut)
        await service.completeOnboarding(method: .device, displayName: "Ari")
        let accountID = try XCTUnwrap(service.currentSession?.accountID)
        XCTAssertEqual(service.currentSession?.mode, .local)

        // A service built from the same storage is what the next launch sees.
        let restored = SessionService(storage: storage)
        XCTAssertEqual(restored.currentSession?.accountID, accountID)
        XCTAssertEqual(restored.currentSession?.mode, .local)

        restored.signOut()
        XCTAssertEqual(restored.state, .signedOut)
        XCTAssertEqual(SessionService(storage: storage).state, .signedOut)
    }

    /// Without a configured Supabase project there is no service that can send
    /// or check a code. The flow must refuse rather than wave the user through
    /// — it previously accepted any six digits and issued a real account.
    ///
    /// The absent client is injected rather than inferred from the environment.
    /// Relying on ambient config meant this test asserted nothing on any machine
    /// that bakes real Supabase values into the build: `fromBundle()` handed it
    /// a live client, and every run mailed a genuine sign-in code from the
    /// production project to `someone@example.com` — an address reserved by
    /// IANA that accepts no mail, so each one bounced straight back into the
    /// SMTP sender's inbox. A high bounce rate to a non-existent address is
    /// also the strongest spam signal there is, and the sender is a real
    /// mailbox whose reputation the whole email sign-in path depends on.
    func testEmailCodeIsRefusedWhenNoVerificationServiceIsConfigured() async {
        let suiteName = "SessionServiceEmailTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage, authClientProvider: { nil })

        let sent = await service.sendEmailCode(to: "someone@example.com")
        XCTAssertFalse(sent)
        XCTAssertNotNil(service.signInError)

        let verified = await service.verifyEmailCode(email: "someone@example.com", code: "123456")
        XCTAssertFalse(verified)
        XCTAssertEqual(service.state, .signedOut, "An unverified code must never establish a session")
    }

    /// An unverified email attempt must not fall through to a signed-in account
    /// of any kind on completion.
    func testCompletingOnboardingWithoutAVerifiedCodeDoesNotCreateAnEmailAccount() async {
        let suiteName = "SessionServiceEmailCompletionTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage)

        let outcome = await service.completeOnboarding(method: .email, displayName: "Ari")

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(service.state, .signedOut)
        XCTAssertNotNil(service.signInError)
    }

    func testExplicitDeviceOnlyCompletionCreatesALocalAccount() async {
        let suiteName = "SessionServiceDeviceOnlyTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage)

        let outcome = await service.completeOnboarding(method: .device, displayName: "Ari")

        XCTAssertEqual(outcome, .signedIn)
        XCTAssertEqual(service.currentSession?.mode, .local)
        XCTAssertTrue(service.currentSession?.accountID.hasPrefix("local-") == true)
    }

    func testInitialProfileHandoffSurvivesRelaunchUntilQueueAcknowledgesIt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthMockURLProtocol.self]
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        AuthMockURLProtocol.handler = { request in
            let createdAt = ISO8601DateFormatter().string(from: .now)
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(
                url: url, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            if url.path == "/rest/v1/rpc/grove_signup_completed" {
                return (response, Data("false".utf8))
            }
            if url.path == "/rest/v1/rpc/grove_complete_signup" {
                return (response, Data("true".utf8))
            }
            let payload = Data(
                """
                {
                  "access_token": "fresh-access",
                  "refresh_token": "fresh-refresh",
                  "expires_in": 3600,
                  "user": {
                    "id": "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
                    "created_at": "\(createdAt)"
                  }
                }
                """.utf8
            )
            return (response, payload)
        }
        let suiteName = "SessionServiceInitialProfileTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage, authClientProvider: { client })
        service.stashGoogleCredential(userID: "108423", idToken: "token", displayName: "Ari")
        let location = GroveLocation(
            latitude: 51.4545,
            longitude: -2.5879,
            label: "Bristol, United Kingdom",
            countryCode: "GB",
            timeZoneIdentifier: "Europe/London"
        )

        let outcome = await service.completeOnboarding(
            method: .google,
            displayName: "Ari",
            location: location
        )
        XCTAssertEqual(outcome, .signedIn)

        let relaunched = SessionService(storage: storage, authClientProvider: { nil })
        let request = try XCTUnwrap(
            relaunched.pendingInitialProfileSync(accountID: "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6")
        )
        XCTAssertEqual(request.displayName, "Ari")
        XCTAssertEqual(request.latitude, location.latitude)
        XCTAssertEqual(request.longitude, location.longitude)
        XCTAssertEqual(request.locationLabel, location.label)
        XCTAssertEqual(request.locationCountryCode, location.countryCode)
        XCTAssertEqual(request.locationTimeZoneIdentifier, location.timeZoneIdentifier)

        relaunched.markInitialProfileSyncEnqueued(accountID: "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6")
        XCTAssertNil(relaunched.pendingInitialProfileSync())
    }

    func testAnonymousAnalysisSignInReturnsARefreshableSupabaseSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let responseDate = Date(timeIntervalSince1970: 1_800_000_000)
        AuthMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.grove.test/auth/v1/signup")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "publishable-key")
            let body = try sessionRequestBodyData(request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual((json["data"] as? [String: String])?["purpose"], "onboarding_scan")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let payload = Data(
                """
                {
                  "access_token": "signed-anonymous-access",
                  "refresh_token": "anonymous-refresh",
                  "expires_in": 3600,
                  "user": {
                    "id": "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
                    "created_at": "2026-07-30T01:02:03.000Z"
                  }
                }
                """.utf8
            )
            return (response, payload)
        }
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: urlSession,
            dateProvider: { responseDate }
        )

        let session = try await client.signInAnonymously(purpose: .onboardingScan)

        XCTAssertEqual(session.userID, "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6")
        XCTAssertEqual(session.accessToken, "signed-anonymous-access")
        XCTAssertEqual(session.refreshToken, "anonymous-refresh")
        XCTAssertEqual(session.expiresAt, responseDate.addingTimeInterval(3_600))
        XCTAssertNotNil(session.userCreatedAt)
    }

    func testSignedOutAnalysisMintsASeparateOnboardingGuestCredential() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthMockURLProtocol.self]
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        AuthMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.grove.test/auth/v1/signup")
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: sessionRequestBodyData(request)) as? [String: Any]
            )
            XCTAssertEqual((json["data"] as? [String: String])?["purpose"], "onboarding_scan")
            return try anonymousSessionResponse(
                for: request,
                userID: "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
                accessToken: "onboarding-access",
                refreshToken: "onboarding-refresh"
            )
        }
        let suiteName = "SessionServiceOnboardingGuestTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage, authClientProvider: { client })

        let bearer = await service.analysisBearerToken()

        XCTAssertEqual(bearer, "onboarding-access")
        XCTAssertEqual(OnboardingGuestSessionStore.load()?.refreshToken, "onboarding-refresh")
        XCTAssertNil(BotanistSessionStore.load())
        XCTAssertNil(SupabaseSessionStore.load())
        XCTAssertTrue(storage.bool(forKey: GroveDefaults.onboardingGuestCredentialPresent))
    }

    func testSignedOutAnalysisReusesItsGuestCredentialAcrossRelaunch() async throws {
        let suiteName = "SessionServiceOnboardingGuestRelaunchTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        OnboardingGuestSessionStore.save(
            OnboardingGuestTokenSet(
                userID: "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
                accessToken: "still-valid",
                refreshToken: "refresh",
                expiresAt: .now.addingTimeInterval(3_600)
            )
        )
        storage.set(true, forKey: GroveDefaults.onboardingGuestCredentialPresent)

        let relaunched = SessionService(storage: storage, authClientProvider: { nil })
        let bearer = await relaunched.analysisBearerToken()

        XCTAssertEqual(bearer, "still-valid")
        XCTAssertNotNil(OnboardingGuestSessionStore.load())
    }

    func testAReinstallMarkerMismatchClearsAnOrphanedOnboardingCredential() {
        let suiteName = "SessionServiceOnboardingGuestReinstallTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        OnboardingGuestSessionStore.save(
            OnboardingGuestTokenSet(
                userID: "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
                accessToken: "orphaned",
                refreshToken: "refresh",
                expiresAt: .now.addingTimeInterval(3_600)
            )
        )

        _ = SessionService(storage: storage, authClientProvider: { nil })

        XCTAssertNil(OnboardingGuestSessionStore.load())
    }

    func testASignedInRelaunchClearsAGuestCredentialAfterTheHandoffMarkerWasConsumed() async {
        let suiteName = "SessionServiceConsumedOnboardingGuestTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let initial = SessionService(storage: storage, authClientProvider: { nil })
        await initial.completeOnboarding(method: .device, displayName: "Ari")
        OnboardingGuestSessionStore.save(
            OnboardingGuestTokenSet(
                userID: "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
                accessToken: "orphaned-after-import",
                refreshToken: "refresh",
                expiresAt: .now.addingTimeInterval(3_600)
            )
        )
        storage.set(true, forKey: GroveDefaults.onboardingGuestCredentialPresent)

        let relaunched = SessionService(storage: storage, authClientProvider: { nil })

        XCTAssertNotNil(relaunched.currentSession)
        XCTAssertNil(relaunched.currentSession?.pendingFirstPlantID)
        XCTAssertNil(OnboardingGuestSessionStore.load())
        XCTAssertFalse(storage.bool(forKey: GroveDefaults.onboardingGuestCredentialPresent))
    }

    func testASignedInRelaunchKeepsTheGuestCredentialWhileItsExactHandoffIsPending() async {
        let suiteName = "SessionServicePendingOnboardingGuestTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let plantID = UUID()
        let initial = SessionService(storage: storage, authClientProvider: { nil })
        await initial.completeOnboarding(
            method: .device,
            displayName: "Ari",
            pendingFirstPlantID: plantID
        )
        OnboardingGuestSessionStore.save(
            OnboardingGuestTokenSet(
                userID: "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
                accessToken: "needed-for-recovery",
                refreshToken: "refresh",
                expiresAt: .now.addingTimeInterval(3_600)
            )
        )
        storage.set(true, forKey: GroveDefaults.onboardingGuestCredentialPresent)

        let relaunched = SessionService(storage: storage, authClientProvider: { nil })

        XCTAssertEqual(relaunched.currentSession?.pendingFirstPlantID, plantID)
        XCTAssertEqual(OnboardingGuestSessionStore.load()?.accessToken, "needed-for-recovery")
        XCTAssertTrue(storage.bool(forKey: GroveDefaults.onboardingGuestCredentialPresent))
    }

    func testOnboardingGuestRefreshRotatesAndPersistsTheCredential() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthMockURLProtocol.self]
        let responseDate = Date.now
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration),
            dateProvider: { responseDate }
        )
        AuthMockURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://auth.grove.test/auth/v1/token?grant_type=refresh_token"
            )
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: sessionRequestBodyData(request)) as? [String: String]
            )
            XCTAssertEqual(json["refresh_token"], "old-refresh")
            return try anonymousSessionResponse(
                for: request,
                userID: "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
                accessToken: "rotated-access",
                refreshToken: "rotated-refresh"
            )
        }
        let suiteName = "SessionServiceOnboardingGuestRefreshTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        OnboardingGuestSessionStore.save(
            OnboardingGuestTokenSet(
                userID: "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
                accessToken: "expired-access",
                refreshToken: "old-refresh",
                expiresAt: .distantPast
            )
        )
        storage.set(true, forKey: GroveDefaults.onboardingGuestCredentialPresent)
        let service = SessionService(storage: storage, authClientProvider: { client })
        let bearer = await service.analysisBearerToken()

        XCTAssertEqual(bearer, "rotated-access")
        XCTAssertEqual(OnboardingGuestSessionStore.load()?.refreshToken, "rotated-refresh")
        XCTAssertEqual(
            OnboardingGuestSessionStore.load()?.expiresAt,
            responseDate.addingTimeInterval(3_600)
        )
    }

    func testSignedInLocalAnalysisUsesTheStrictGuestIdentity() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthMockURLProtocol.self]
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        AuthMockURLProtocol.handler = { request in
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: sessionRequestBodyData(request)) as? [String: Any]
            )
            XCTAssertEqual((json["data"] as? [String: String])?["purpose"], "onboarding_scan")
            return try anonymousSessionResponse(
                for: request,
                userID: "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
                accessToken: "local-analysis-access",
                refreshToken: "local-analysis-refresh"
            )
        }
        let suiteName = "SessionServiceLocalAnalysisRoutingTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage, authClientProvider: { client })
        _ = await service.completeOnboarding(method: .device, displayName: "Ari")
        let bearer = await service.analysisBearerToken()

        XCTAssertEqual(bearer, "local-analysis-access")
        XCTAssertNotNil(BotanistSessionStore.load())
        XCTAssertNil(OnboardingGuestSessionStore.load())
    }

    func testSignedInLocalAccountCannotMintABotanistBearer() async {
        let suiteName = "SessionServiceLocalBotanistBoundaryTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(
            storage: storage,
            authClientProvider: {
                XCTFail("A local account must not create anonymous credentials for Botanist")
                return nil
            }
        )
        _ = await service.completeOnboarding(method: .device, displayName: "Ari")
        let bearer = await service.botanistBearerToken()

        XCTAssertNil(bearer)
        XCTAssertNil(BotanistSessionStore.load())
    }

    func testLocalAnalysisRejectsARefreshThatChangesGuestSubject() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthMockURLProtocol.self]
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        AuthMockURLProtocol.handler = { request in
            try anonymousSessionResponse(
                for: request,
                userID: "B0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
                accessToken: "wrong-subject-access",
                refreshToken: "rotated-refresh"
            )
        }
        let suiteName = "SessionServiceLocalAnalysisSubjectTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage, authClientProvider: { client })
        _ = await service.completeOnboarding(method: .device, displayName: "Ari")
        let owner = try XCTUnwrap(service.currentSession?.accountID)
        BotanistSessionStore.save(
            BotanistTokenSet(
                ownerAccountID: owner,
                userID: "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
                accessToken: "expired-access",
                refreshToken: "old-refresh",
                expiresAt: .distantPast
            )
        )

        let bearer = await service.analysisBearerToken()

        XCTAssertNil(bearer)
        XCTAssertNil(BotanistSessionStore.load())
    }

    func testRefreshFromPreviousAccountCannotOverwriteOrAnswerForCurrentAccount() async throws {
        let accountA = "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"
        let accountB = "B0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"
        let refreshAStarted = expectation(description: "account A refresh started")
        let releaseRefreshA = DispatchSemaphore(value: 0)
        defer { releaseRefreshA.signal() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthMockURLProtocol.self]
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        AuthMockURLProtocol.handler = { request in
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: sessionRequestBodyData(request)) as? [String: String]
            )
            if body["refresh_token"] == "refresh-a" {
                refreshAStarted.fulfill()
                releaseRefreshA.wait()
                return try anonymousSessionResponse(
                    for: request,
                    userID: accountA,
                    accessToken: "late-access-a",
                    refreshToken: "late-refresh-a"
                )
            }
            XCTAssertEqual(body["refresh_token"], "refresh-b")
            return try anonymousSessionResponse(
                for: request,
                userID: accountB,
                accessToken: "access-b",
                refreshToken: "rotated-refresh-b"
            )
        }

        let suiteName = "SessionServiceProviderRefreshOwnerTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let sessionA = UserSession(accountID: accountA, mode: .google, displayName: "A")
        storage.set(try JSONEncoder().encode(sessionA), forKey: "grove.user.session.v1")
        SupabaseSessionStore.save(
            SupabaseTokenSet(
                userID: accountA,
                accessToken: "expired-a",
                refreshToken: "refresh-a",
                expiresAt: .distantPast
            )
        )
        let service = SessionService(storage: storage, authClientProvider: { client })
        let accountATask = Task { await service.apiBearerToken() }
        await fulfillment(of: [refreshAStarted], timeout: 2)

        // Preserve the in-flight task deliberately: this models the exact
        // stale-owner state the production guards must reject even if an
        // account transition and URLSession cancellation interleave badly.
        let sessionB = UserSession(accountID: accountB, mode: .google, displayName: "B")
        service.state = .signedIn(sessionB)
        storage.set(try JSONEncoder().encode(sessionB), forKey: "grove.user.session.v1")
        SupabaseSessionStore.save(
            SupabaseTokenSet(
                userID: accountB,
                accessToken: "expired-b",
                refreshToken: "refresh-b",
                expiresAt: .distantPast
            )
        )
        let accountBTask = Task { await service.apiBearerToken() }
        releaseRefreshA.signal()

        let accountABearer = await accountATask.value
        let accountBBearer = await accountBTask.value

        XCTAssertNil(accountABearer)
        XCTAssertEqual(accountBBearer, "access-b")
        XCTAssertEqual(SupabaseSessionStore.load()?.userID, accountB)
        XCTAssertEqual(SupabaseSessionStore.load()?.accessToken, "access-b")
    }

    func testRejectedRefreshFromPreviousAccountCannotClearCurrentCredential() async throws {
        let accountA = "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"
        let accountB = "B0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"
        let refreshAStarted = expectation(description: "account A rejected refresh started")
        let releaseRefreshA = DispatchSemaphore(value: 0)
        defer { releaseRefreshA.signal() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthMockURLProtocol.self]
        let client = SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
        AuthMockURLProtocol.handler = { request in
            refreshAStarted.fulfill()
            releaseRefreshA.wait()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"message":"refresh token rejected"}"#.utf8))
        }

        let suiteName = "SessionServiceProviderRefreshRejectionTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let sessionA = UserSession(accountID: accountA, mode: .google, displayName: "A")
        storage.set(try JSONEncoder().encode(sessionA), forKey: "grove.user.session.v1")
        SupabaseSessionStore.save(
            SupabaseTokenSet(
                userID: accountA,
                accessToken: "expired-a",
                refreshToken: "refresh-a",
                expiresAt: .distantPast
            )
        )
        let service = SessionService(storage: storage, authClientProvider: { client })
        let accountATask = Task { await service.apiBearerToken() }
        await fulfillment(of: [refreshAStarted], timeout: 2)

        let sessionB = UserSession(accountID: accountB, mode: .google, displayName: "B")
        service.state = .signedIn(sessionB)
        storage.set(try JSONEncoder().encode(sessionB), forKey: "grove.user.session.v1")
        SupabaseSessionStore.save(
            SupabaseTokenSet(
                userID: accountB,
                accessToken: "valid-b",
                refreshToken: "refresh-b",
                expiresAt: .now.addingTimeInterval(3_600)
            )
        )
        releaseRefreshA.signal()
        let accountABearer = await accountATask.value

        XCTAssertNil(accountABearer)
        XCTAssertEqual(SupabaseSessionStore.load()?.userID, accountB)
        XCTAssertEqual(SupabaseSessionStore.load()?.accessToken, "valid-b")
    }
}

private func anonymousSessionResponse(
    for request: URLRequest,
    userID: String,
    accessToken: String,
    refreshToken: String
) throws -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!
    let payload = Data(
        """
        {
          "access_token": "\(accessToken)",
          "refresh_token": "\(refreshToken)",
          "expires_in": 3600,
          "user": {
            "id": "\(userID)",
            "created_at": "2026-08-02T01:02:03.000Z"
          }
        }
        """.utf8
    )
    return (response, payload)
}

private func sessionRequestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw try XCTUnwrap(stream.streamError) }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private final class AuthMockURLProtocol: URLProtocol, @unchecked Sendable {
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
