import Foundation

/// Minimal client for Supabase Auth's native identity-token grant.
///
/// Sign in with Apple and Google both hand the app a signed OpenID identity
/// token. Supabase exchanges that token for a real session at
/// `POST /auth/v1/token?grant_type=id_token`, creating the `auth.users` row
/// (which the `on_auth_user_created` trigger turns into an `app.accounts` row
/// and a default Grove). This is a plain URLSession call — it deliberately
/// avoids the supabase-swift SDK so the offline-first app takes on no new
/// dependency for what is one HTTPS request.
struct SupabaseAuthClient: Sendable {
    enum Provider: String, Sendable {
        case apple
        case google
    }

    /// Why Grove is creating an anonymous Auth identity. This is descriptive
    /// metadata for retention and diagnostics, never authorization: anonymous
    /// signup is public, so the server treats every such identity as a strictly
    /// limited analysis guest and reserves Botanist for provisioned accounts.
    enum AnonymousPurpose: String, Sendable {
        case onboardingScan = "onboarding_scan"
    }

    /// A Supabase-authenticated session. `userID` is the `auth.users` UUID. For
    /// provider sign-in it also equals `app.accounts.id`, the identity RLS keys
    /// on; deliberately unprovisioned anonymous sessions have no account row.
    struct Session: Sendable {
        let userID: String
        let accessToken: String
        let refreshToken: String?
        /// Absolute expiry captured when this auth response arrived. Keeping the
        /// original deadline matters for sessions held while onboarding runs;
        /// adding `expires_in` again at completion would make an old token look
        /// newly valid.
        let expiresAt: Date
        /// When the `auth.users` row was created, when the response carried it.
        /// The id-token grant signs *up* as readily as it signs *in*, so this is
        /// one half of how the returning route tells an existing account from an
        /// identity this very grant just created.
        let userCreatedAt: Date?
        /// Supabase updates this on every interactive authentication. On a first
        /// sign-in it is effectively equal to `userCreatedAt`; on every return it
        /// is newer, even when the account itself was created only moments ago.
        let userLastSignInAt: Date?

        init(
            userID: String,
            accessToken: String,
            refreshToken: String?,
            expiresAt: Date,
            userCreatedAt: Date? = nil,
            userLastSignInAt: Date? = nil
        ) {
            self.userID = userID
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.userCreatedAt = userCreatedAt
            self.userLastSignInAt = userLastSignInAt
        }

        /// Refresh slightly early so a request cannot outlive its bearer.
        var needsRefresh: Bool {
            Date.now >= expiresAt.addingTimeInterval(-60)
        }
    }

    enum AuthError: LocalizedError {
        case notConfigured
        case invalidResponse
        /// The server answered and the answer was not a session. `status` is the
        /// HTTP status, because "we refused your credential" and "we could not
        /// answer right now" arrive through this same case and mean opposite
        /// things to a caller holding a stored refresh token.
        case provider(message: String, status: Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Sign-in isn't available in this build."
            case .invalidResponse: "Sign-in didn't go through. Try again."
            case .provider(let message, _): message
            }
        }

        /// Whether the server specifically refused the credential, as opposed to
        /// failing to answer for it.
        ///
        /// Only a refusal may destroy a stored refresh token. GoTrue rejects a
        /// spent or revoked one with 400/401, and retrying that forever is
        /// pointless. But a 429, a 502 while the project restarts, or a captive
        /// portal's redirect all used to arrive here as "refused" too — and
        /// deleting the token on one of those signs a perfectly good account out
        /// of its own server permanently, with no credential left to retry.
        var isCredentialRejection: Bool {
            guard case .provider(_, let status) = self else { return false }
            switch status {
            // Ask again later, in the server's own words.
            case 408, 425, 429: return false
            case 400..<500: return true
            // 5xx, and anything else that got past the 2xx guard: the credential
            // was never judged, so it keeps the benefit of the doubt.
            default: return false
            }
        }
    }

    let baseURL: URL
    let anonKey: String
    private let session: URLSession
    private let dateProvider: @Sendable () -> Date

    init(
        baseURL: URL,
        anonKey: String,
        session: URLSession = .shared,
        dateProvider: @escaping @Sendable () -> Date = { .now }
    ) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.session = session
        self.dateProvider = dateProvider
    }

    /// Builds a client from the `SupabaseURL` / `SupabaseAnonKey` Info.plist
    /// values populated by matching build settings. Missing means unavailable:
    /// a Debug build must never contact production merely because a developer
    /// forgot to load the intended environment.
    @MainActor
    static func fromBundle(bundle: Bundle = .main) -> SupabaseAuthClient? {
        guard let baseURL = configuredURL(forKey: "SupabaseURL", in: bundle),
              let anonKey = configuredString(forKey: "SupabaseAnonKey", in: bundle) else {
            return nil
        }
        return SupabaseAuthClient(baseURL: baseURL, anonKey: anonKey)
    }

    /// Exchanges a provider identity token for a Supabase session.
    /// `nonce` is the raw (un-hashed) nonce for Apple; Google does not send one.
    func signIn(provider: Provider, idToken: String, nonce: String?) async throws -> Session {
        try await sessionRequest(
            path: "auth/v1/token?grant_type=id_token",
            body: TokenGrantRequest(provider: provider.rawValue, idToken: idToken, nonce: nonce)
        )
    }

    /// Creates a real anonymous Supabase Auth session for a purpose that does not
    /// own a synced Grove. Both an existing device-only Grove and signed-out
    /// first-plant onboarding get a signed, rate-limitable subject instead of
    /// asking a paid gateway to trust an id supplied by the app.
    func signInAnonymously(purpose: AnonymousPurpose) async throws -> Session {
        try await sessionRequest(
            path: "auth/v1/signup",
            body: AnonymousSignUpRequest(data: ["purpose": purpose.rawValue])
        )
    }

    /// Exchanges a refresh token for a fresh session. GoTrue rotates the refresh
    /// token, so callers must persist the returned one.
    func refresh(refreshToken: String) async throws -> Session {
        try await sessionRequest(
            path: "auth/v1/token?grant_type=refresh_token",
            body: RefreshGrantRequest(refreshToken: refreshToken)
        )
    }

    /// Emails a 6-digit sign-in code. `createUser` decides whether an unknown
    /// address mints a fresh auth user (the new-account funnel) or is rejected
    /// (the returning route, which must never invent an empty grove).
    ///
    /// The project's "Magic Link" email template must include `{{ .Token }}`
    /// for a 6-digit code to arrive (see SSO_SETUP.md); without it Supabase
    /// sends a link instead and the code screen has nothing to accept.
    func sendEmailCode(to email: String, createUser: Bool = true) async throws {
        _ = try await rawRequest(
            path: "auth/v1/otp",
            body: EmailOTPRequest(email: email, createUser: createUser)
        )
    }

    /// Verifies an emailed 6-digit code and returns the resulting session.
    func verifyEmailCode(email: String, code: String) async throws -> Session {
        try await sessionRequest(
            path: "auth/v1/verify",
            body: EmailVerifyRequest(type: "email", email: email, token: code)
        )
    }

    /// Whether this Auth identity has crossed Grove's explicit account-creation
    /// boundary. The id-token grant creates an Auth user even on the returning
    /// route, so timestamps alone cannot distinguish a real Grove from an
    /// abandoned "wrong door" sign-in on a later attempt.
    func hasCompletedSignup(accessToken: String) async throws -> Bool {
        let data = try await rawRequest(
            path: "rest/v1/rpc/grove_signup_completed",
            body: EmptyRequest(),
            accessToken: accessToken
        )
        guard let completed = try? JSONDecoder().decode(Bool.self, from: data) else {
            throw AuthError.invalidResponse
        }
        return completed
    }

    /// Marks the authenticated account as explicitly accepted by the person.
    /// The database function is idempotent and scoped to `auth.uid()`; a client
    /// can never complete somebody else's account.
    /// Returns true when this durable random claim crossed the boundary, including
    /// a retry after the original response was lost. False means a competing
    /// device's claim completed it first, so this caller must discard stale data.
    func completeSignup(accessToken: String, claimID: UUID) async throws -> Bool {
        let data = try await rawRequest(
            path: "rest/v1/rpc/grove_complete_signup",
            body: CompleteSignupRequest(claimID: claimID),
            accessToken: accessToken
        )
        guard let completedNow = try? JSONDecoder().decode(Bool.self, from: data) else {
            throw AuthError.invalidResponse
        }
        return completedNow
    }

    /// Revokes only the refresh session represented by `accessToken`. Other
    /// signed-in iPhones and browsers stay signed in.
    func signOut(accessToken: String) async throws {
        _ = try await rawRequest(
            path: "auth/v1/logout?scope=local",
            body: EmptyRequest(),
            accessToken: accessToken
        )
    }

    private func sessionRequest(path: String, body: some Encodable) async throws -> Session {
        let data = try await rawRequest(path: path, body: body)
        // Capture this immediately after the response returns. Every grant,
        // including refresh-token exchanges, comes through this method.
        let receivedAt = dateProvider()
        let decoded: TokenGrantResponse
        do {
            decoded = try JSONDecoder().decode(TokenGrantResponse.self, from: data)
        } catch {
            throw AuthError.invalidResponse
        }
        let expiresIn = decoded.expiresIn ?? 3_600
        guard UUID(uuidString: decoded.user.id) != nil,
              !decoded.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...604_800).contains(expiresIn) else {
            throw AuthError.invalidResponse
        }
        return Session(
            userID: decoded.user.id,
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            expiresAt: receivedAt.addingTimeInterval(TimeInterval(expiresIn)),
            userCreatedAt: decoded.user.createdAt.flatMap(Self.parseTimestamp),
            userLastSignInAt: decoded.user.lastSignInAt.flatMap(Self.parseTimestamp)
        )
    }

    /// GoTrue emits `created_at` as ISO 8601 with fractional seconds; older
    /// deployments omit the fraction. Unparseable is fine — the caller treats a
    /// missing date as "unknown", never as "new".
    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private func rawRequest(
        path: String,
        body: some Encodable,
        accessToken: String? = nil
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw AuthError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(GoTrueError.self, from: data))?.readableMessage
            // The status rides on the case for callers; it is not for people.
            throw AuthError.provider(
                message: message ?? "Sign-in didn't go through. Try again in a moment.",
                status: http.statusCode
            )
        }
        return data
    }

    // MARK: - Wire types

    private struct TokenGrantRequest: Encodable {
        let provider: String
        let idToken: String
        let nonce: String?

        enum CodingKeys: String, CodingKey {
            case provider
            case idToken = "id_token"
            case nonce
        }
    }

    private struct RefreshGrantRequest: Encodable {
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
        }
    }

    private struct AnonymousSignUpRequest: Encodable {
        let data: [String: String]
    }

    private struct EmailOTPRequest: Encodable {
        let email: String
        let createUser: Bool

        enum CodingKeys: String, CodingKey {
            case email
            case createUser = "create_user"
        }
    }

    private struct EmailVerifyRequest: Encodable {
        let type: String
        let email: String
        let token: String
    }

    private struct CompleteSignupRequest: Encodable {
        let claimID: UUID

        enum CodingKeys: String, CodingKey {
            case claimID = "p_claim_id"
        }
    }

    private struct EmptyRequest: Encodable {}

    private struct TokenGrantResponse: Decodable {
        struct User: Decodable {
            let id: String
            let createdAt: String?
            let lastSignInAt: String?

            enum CodingKeys: String, CodingKey {
                case id
                case createdAt = "created_at"
                case lastSignInAt = "last_sign_in_at"
            }
        }
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?
        let user: User

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case user
        }
    }

    private struct GoTrueError: Decodable {
        let error: String?
        let errorDescription: String?
        let message: String?
        let msg: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
            case message
            case msg
        }

        var readableMessage: String? {
            errorDescription ?? message ?? msg ?? error
        }
    }

    // MARK: - Info.plist reads (mirrors GroveServiceFactory.bundleURL)

    @MainActor
    private static func configuredString(forKey key: String, in bundle: Bundle) -> String? {
        guard let rawValue = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
              !value.isEmpty,
              !value.contains("$(") else { return nil }
        return value
    }

    @MainActor
    private static func configuredURL(forKey key: String, in bundle: Bundle) -> URL? {
        guard let value = configuredString(forKey: key, in: bundle) else { return nil }
        // Normalise so relative-URL resolution keeps the /auth/v1 path segment.
        let normalised = value.hasSuffix("/") ? value : value + "/"
        guard let url = URL(string: normalised), isSecureAuthBaseURL(url) else { return nil }
        return url
    }

    /// Provider identity and refresh tokens must never be sent to a relative,
    /// cleartext, credential-bearing, or otherwise malformed build-time URL.
    /// Kept internal so release-configuration tests can lock the boundary.
    static func isSecureAuthBaseURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme?.lowercased() == "https"
            && components.host?.isEmpty == false
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
    }
}
