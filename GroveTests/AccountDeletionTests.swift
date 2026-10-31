import Foundation
import XCTest
@testable import Grove

/// The one action with no local fallback.
///
/// Every other Grove request can fail and leave the person with a working app;
/// deletion that fails leaves them with an account they asked to be rid of and
/// no way to get rid of it. These cover the ways the request used to end in a
/// dead end: a bearer the server rejects, and a provider session whose stored
/// credential is gone.
private final class DeletionMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: APIError.invalidResponse)
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

@MainActor
final class AccountDeletionTests: XCTestCase {
    private let accountID = "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6"

    override func tearDown() {
        DeletionMockURLProtocol.handler = nil
        DeletionMockURLProtocol.requests = []
        SupabaseSessionStore.clear()
        super.tearDown()
    }

    private func makeClient(token: @escaping @MainActor () async -> String?) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeletionMockURLProtocol.self]
        return APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://api.grove.test/v1/")!,
                environment: .production,
                appKey: "test-key"
            ),
            session: URLSession(configuration: configuration),
            accessToken: token
        )
    }

    private func makeSignedInService(
        storage: UserDefaults,
        authClient: SupabaseAuthClient? = nil
    ) -> SessionService {
        let service = SessionService(storage: storage, authClientProvider: { authClient })
        service.state = .signedIn(
            UserSession(accountID: accountID, mode: .google, displayName: "Ari")
        )
        return service
    }

    /// A Supabase auth client that answers the refresh grant over the same mock
    /// protocol as the API, so a test can watch the app trade one bearer for
    /// another mid-request.
    private func makeAuthClient() -> SupabaseAuthClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeletionMockURLProtocol.self]
        return SupabaseAuthClient(
            baseURL: URL(string: "https://auth.grove.test/")!,
            anonKey: "publishable-key",
            session: URLSession(configuration: configuration)
        )
    }

    /// The failure from the screenshot: a token the app still believed in, a
    /// server that did not. One rejection has to buy a fresh token and a second
    /// attempt, not an alert.
    func testARejectedBearerIsRefreshedOnceAndTheDeletionSucceeds() async throws {
        let suiteName = "AccountDeletionRetry-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = makeSignedInService(storage: storage, authClient: makeAuthClient())

        // An access token with an hour left on it: nothing local suggests it
        // needs replacing, which is exactly the case the retry exists for.
        SupabaseSessionStore.save(
            SupabaseTokenSet(
                userID: accountID,
                accessToken: "stale-token",
                refreshToken: "refresh-token",
                expiresAt: .now.addingTimeInterval(3_600)
            )
        )

        var deleteAttempts = 0
        DeletionMockURLProtocol.handler = { [accountID] request in
            let url = try XCTUnwrap(request.url)
            if url.path.hasPrefix("/auth/v1/token") {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let payload = """
                    {
                      "access_token": "fresh-token",
                      "refresh_token": "rotated-refresh-token",
                      "expires_in": 3600,
                      "user": { "id": "\(accountID)" }
                    }
                    """
                return (response, Data(payload.utf8))
            }
            deleteAttempts += 1
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(url.path, "/v1/account")
            if deleteAttempts == 1 {
                let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"message":"A bearer token is required."}"#.utf8))
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"deleted":true}"#.utf8))
        }

        let client = makeClient { await service.apiBearerToken() }

        try await GroveServiceFactory.deleteAccount(session: service, using: client)

        XCTAssertEqual(deleteAttempts, 2, "the rejection should be retried exactly once")
        let bearers = DeletionMockURLProtocol.requests
            .filter { $0.httpMethod == "DELETE" }
            .map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(bearers, ["Bearer stale-token", "Bearer fresh-token"])
        XCTAssertEqual(SupabaseSessionStore.load()?.refreshToken, "rotated-refresh-token")
    }

    /// With no refresh token in the Keychain there is nothing left to exchange,
    /// so the request must resolve to the one error Settings can act on rather
    /// than the generic "signed out" wording that offered no way forward.
    func testAnUnrecoverableRejectionAsksForANewSignInInsteadOfFailing() async {
        let suiteName = "AccountDeletionExpired-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = makeSignedInService(storage: storage)
        SupabaseSessionStore.clear()

        DeletionMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"message":"A bearer token is required."}"#.utf8))
        }
        let client = makeClient { nil }

        do {
            try await GroveServiceFactory.deleteAccount(session: service, using: client)
            XCTFail("a rejected deletion must not report success")
        } catch let error as GroveServiceFactory.AccountDeletionError {
            XCTAssertEqual(error, .sessionExpired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A 200 that does not confirm the deletion is not a deletion. Local data
    /// survives an ambiguous answer, because the server copy might too.
    func testAnUnconfirmedResponseIsTreatedAsAFailure() async {
        let suiteName = "AccountDeletionUnconfirmed-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = makeSignedInService(storage: storage)

        DeletionMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"deleted":false}"#.utf8))
        }
        let client = makeClient { "live-token" }

        do {
            try await GroveServiceFactory.deleteAccount(session: service, using: client)
            XCTFail("an unconfirmed deletion must not report success")
        } catch let error as APIError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A route the gateway has not deployed yet answers 404. That is a server
    /// that has not deleted anything, and it must never be mistaken for one
    /// that already had.
    func testAMissingServerRouteFailsRatherThanCountingAsDeleted() async {
        let suiteName = "AccountDeletionMissingRoute-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = makeSignedInService(storage: storage)

        DeletionMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 404, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"message":"Route not found."}"#.utf8))
        }
        let client = makeClient { "live-token" }

        do {
            try await GroveServiceFactory.deleteAccount(session: service, using: client)
            XCTFail("a missing route must not report success")
        } catch let error as APIError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A local-only Grove has no server account, and the local wipe is the whole
    /// deletion — it must not be blocked behind a request that cannot be made.
    func testALocalOnlyGroveReportsThereIsNoServerAccountToDelete() async {
        let suiteName = "AccountDeletionLocal-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage, authClientProvider: { nil })
        service.state = .signedIn(
            UserSession(accountID: "local-\(UUID().uuidString)", mode: .local, displayName: "Ari")
        )

        do {
            try await GroveServiceFactory.deleteAccount(session: service)
            XCTFail("a local Grove has no server account")
        } catch let error as GroveServiceFactory.AccountDeletionError {
            XCTAssertEqual(error, .noServerAccount)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The zombie state behind the original report: a provider account still
    /// shown as signed in, with no credential the server would accept. Launch
    /// has to notice, so Settings can offer the way back instead of letting the
    /// person discover it at the delete button.
    func testAProviderSessionWithNoStoredCredentialAsksToSignInAgain() async {
        let suiteName = "AccountDeletionZombie-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = makeSignedInService(storage: storage)
        SupabaseSessionStore.clear()

        XCTAssertFalse(service.needsReauthentication)
        await service.restoreProviderSession()
        XCTAssertTrue(service.needsReauthentication)

        // Signing out is the offered recovery, and it leaves nothing to warn
        // about.
        service.signOut()
        XCTAssertFalse(service.needsReauthentication)
    }

    // MARK: - Keeping and repairing the credential

    /// The report behind this suite's second life: "why does Settings say my
    /// sign-in expired when I'm signed in?"
    ///
    /// Every non-2xx from the auth server used to read as "your credential is
    /// refused", and the answer to a refusal is to delete the refresh token. So
    /// one 503 while the auth project restarted — or a 429, or a hotel wifi
    /// splash page — took the only credential the app had, permanently. Nothing
    /// was left to retry with, sync went quiet for good, and Settings raised a
    /// sign-in warning that no amount of signal could clear. A server that never
    /// judged the credential must leave it alone.
    func testAnUnansweredRefreshKeepsTheCredentialAndRecoversOnTheNextTry() async {
        let suiteName = "CredentialTransient-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = makeSignedInService(storage: storage, authClient: makeAuthClient())
        SupabaseSessionStore.save(
            SupabaseTokenSet(
                userID: accountID,
                accessToken: "expired-token",
                refreshToken: "refresh-token",
                expiresAt: .now.addingTimeInterval(-60)
            )
        )

        DeletionMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 503, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"msg":"upstream unavailable"}"#.utf8))
        }
        await service.restoreProviderSession()

        XCTAssertFalse(
            service.needsReauthentication,
            "a server that failed to answer has not refused the credential"
        )
        XCTAssertEqual(
            SupabaseSessionStore.load()?.refreshToken,
            "refresh-token",
            "the refresh token is the only way back; a 5xx must not spend it"
        )

        // And because it survived, the next attempt is a repair rather than a
        // sign-in screen.
        DeletionMockURLProtocol.handler = { [accountID] request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let payload = """
                {
                  "access_token": "fresh-token",
                  "refresh_token": "rotated-token",
                  "expires_in": 3600,
                  "user": { "id": "\(accountID)" }
                }
                """
            return (response, Data(payload.utf8))
        }
        await service.restoreProviderSession()

        let bearer = await service.apiBearerToken()
        XCTAssertEqual(bearer, "fresh-token")
        XCTAssertFalse(service.needsReauthentication)
    }

    /// The other half of the same rule: a token the server *does* refuse is
    /// spent, and retrying it forever would only keep sync broken quietly.
    func testARefusedRefreshTokenIsStillRetired() async {
        let suiteName = "CredentialRefused-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = makeSignedInService(storage: storage, authClient: makeAuthClient())
        SupabaseSessionStore.save(
            SupabaseTokenSet(
                userID: accountID,
                accessToken: "expired-token",
                refreshToken: "spent-token",
                expiresAt: .now.addingTimeInterval(-60)
            )
        )

        DeletionMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 400, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"error":"invalid_grant","error_description":"Already Used"}"#.utf8))
        }
        await service.restoreProviderSession()

        XCTAssertTrue(service.needsReauthentication)
        XCTAssertNil(SupabaseSessionStore.load())
    }

    /// A grove is keyed by its account id, so a lapsed credential never needed
    /// to cost anyone their plants. Proving the same identity again is the whole
    /// repair — no sign-out, no trip through onboarding, nothing local touched.
    func testReconnectingWithTheSameIdentityRestoresSyncWithoutSigningOut() async {
        let suiteName = "CredentialReconnect-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = makeSignedInService(storage: storage, authClient: makeAuthClient())
        SupabaseSessionStore.clear()

        await service.restoreProviderSession()
        XCTAssertTrue(service.needsReauthentication)

        DeletionMockURLProtocol.handler = { [accountID] request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let payload = """
                {
                  "access_token": "reconnected-token",
                  "refresh_token": "reconnected-refresh",
                  "expires_in": 3600,
                  "user": { "id": "\(accountID)" }
                }
                """
            return (response, Data(payload.utf8))
        }
        service.stashGoogleCredential(userID: "google-sub", idToken: "id-token", displayName: "Ari")

        let outcome = await service.reauthenticateCurrentAccount(method: .google)

        XCTAssertEqual(outcome, .restored)
        XCTAssertFalse(service.needsReauthentication)
        XCTAssertEqual(service.currentSession?.accountID, accountID, "the grove must not be re-keyed")
        XCTAssertEqual(SupabaseSessionStore.load()?.refreshToken, "reconnected-refresh")
        let bearer = await service.apiBearerToken()
        XCTAssertEqual(bearer, "reconnected-token")
    }

    /// Signing in as somebody else is a valid sign-in and the wrong answer.
    /// Storing those tokens under this account id would point the sync engine at
    /// a stranger's grove and hand them this one.
    func testReconnectingWithADifferentIdentityIsRefusedAndChangesNothing() async {
        let suiteName = "CredentialWrongAccount-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = makeSignedInService(storage: storage, authClient: makeAuthClient())
        SupabaseSessionStore.clear()

        await service.restoreProviderSession()
        XCTAssertTrue(service.needsReauthentication)

        DeletionMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let payload = """
                {
                  "access_token": "stranger-token",
                  "refresh_token": "stranger-refresh",
                  "expires_in": 3600,
                  "user": { "id": "11111111-2222-3333-4444-555555555555" }
                }
                """
            return (response, Data(payload.utf8))
        }
        service.stashGoogleCredential(userID: "other-sub", idToken: "id-token", displayName: "Sam")

        let outcome = await service.reauthenticateCurrentAccount(method: .google)

        XCTAssertEqual(outcome, .wrongAccount)
        XCTAssertTrue(service.needsReauthentication, "the account is still unrepaired")
        XCTAssertEqual(service.currentSession?.accountID, accountID)
        XCTAssertNil(SupabaseSessionStore.load(), "a stranger's credential must never be stored here")
    }
}
