import Foundation

@MainActor
enum GroveServiceFactory {
    /// Production gateway origins, baked in at build time exactly like the app
    /// key: the `GROVE_ANALYSIS_URL` and `GROVE_SYNC_URL` build settings (from
    /// the gitignored `Config/Secrets.xcconfig`, or the xcodebuild command line
    /// in the release scripts and CI) → the `GroveAnalysisURL` / `GroveSyncURL`
    /// Info.plist values.
    ///
    /// No endpoint is compiled into the source. A missing URL disables the
    /// services that depend on it with a logged config error; it never crashes
    /// and never falls back to 127.0.0.1. Release builds refuse to build
    /// without both (project.yml pre-build check).
    private nonisolated static var analysisURL: URL? { bundleURL(forKey: "GroveAnalysisURL") }
    private nonisolated static var syncURL: URL? { bundleURL(forKey: "GroveSyncURL") }

    /// The configured production origin, or `nil` after logging why `service`
    /// is off.
    private nonisolated static func productionURL(_ url: URL?, setting: String, for service: String) -> URL? {
        if let url { return url }
        let message = "config error: \(setting) is not set, \(service) disabled. "
            + "Copy Config/Secrets.example.xcconfig to Config/Secrets.xcconfig and set it."
        GroveDiag.log(message)
        NSLog("Grove %@", message)
        return nil
    }

    private nonisolated static func productionAnalysisURL(for service: String) -> URL? {
        productionURL(analysisURL, setting: "GROVE_ANALYSIS_URL", for: service)
    }

    private nonisolated static func productionSyncURL(for service: String) -> URL? {
        productionURL(syncURL, setting: "GROVE_SYNC_URL", for: service)
    }

    /// Shared app key baked in at build time: the `GROVE_APP_KEY` build setting
    /// (from the gitignored `Config/Secrets.xcconfig`, or the xcodebuild command
    /// line in the release scripts) → the `GroveAppKey` Info.plist value.
    /// Sent as `X-Grove-App-Key` on every request.
    ///
    /// There is deliberately no fallback in source. Without a key the
    /// production gateway would reject every request, so `nil` here disables
    /// the production analysis, botanist, sync and analytics clients with a
    /// logged error rather than sending requests that cannot succeed. Release
    /// builds refuse to build without it (project.yml pre-build check).
    ///
    /// Nonisolated, like the URL resolution below it: these read only `Bundle`
    /// and `ProcessInfo`, both safe from any thread, and `GroveAnalytics` is an
    /// actor that needs them off the main actor.
    private nonisolated static var appKey: String? {
        configuredAppKey(from: Bundle.main.object(forInfoDictionaryKey: "GroveAppKey") as? String)
    }

    /// An unset build setting reaches Info.plist as "" (or, in some tools, as the
    /// literal `$(GROVE_APP_KEY)`); both mean "not configured".
    nonisolated static func configuredAppKey(from rawValue: String?) -> String? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (value.isEmpty || value.contains("$(")) ? nil : value
    }

    /// The production key, or `nil` after logging why that service is off.
    private nonisolated static func productionAppKey(for service: String) -> String? {
        if let key = appKey { return key }
        let message = "config error: GROVE_APP_KEY is not set, \(service) disabled. "
            + "Copy Config/Secrets.example.xcconfig to Config/Secrets.xcconfig and set it."
        GroveDiag.log(message)
        NSLog("Grove %@", message)
        return nil
    }

    /// True when scans would go to the production gateway but there is no app
    /// key to send, or no `GROVE_ANALYSIS_URL`. Analysis then fails with
    /// `.unavailable` instead of falling back to the canned local result, which
    /// must never reach a real user.
    private nonisolated static var productionAnalysisIsUnconfigured: Bool {
#if DEBUG
        let process = ProcessInfo.processInfo
        if process.arguments.contains("-GroveUseFixtureAnalysis") { return false }
        if serviceURL(from: process.environment["GROVE_ANALYSIS_BASE_URL"]) != nil { return false }
#endif
        return appKey == nil || analysisURL == nil
    }

    /// Only absolute HTTP(S) service origins are valid overrides. Xcode schemes
    /// commonly leave environment rows enabled with an empty value; `URL(string:
    /// "")` still produces a relative URL, which used to replace the working
    /// production default and make every scan fail with "Analysis paused".
    ///
    /// Normalising the trailing slash matters too: Foundation resolves
    /// `analysis/jobs` by replacing the final path component when the base URL
    /// does not end in `/`.
    nonisolated static func serviceURL(from rawValue: String?) -> URL? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$("),
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.query == nil,
              components.fragment == nil else { return nil }

        if components.path.isEmpty {
            components.path = "/"
        } else if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        return components.url
    }

    private nonisolated static func bundleURL(forKey key: String) -> URL? {
        serviceURL(from: Bundle.main.object(forInfoDictionaryKey: key) as? String)
    }

    /// Where funnel diagnostics go, and the key that gets them accepted.
    ///
    /// Analytics ride the same gateway as analysis: one origin to configure and
    /// one key to rotate. Resolution mirrors `makeAnalysisAPIClient` so a dev
    /// run pointed at a local stack does not post to production.
    ///
    /// Nil under `-GroveUseFixtureAnalysis`, so tests and UI runs never send
    /// anything anywhere.
    nonisolated static var analyticsEndpoint: (url: URL, appKey: String)? {
#if DEBUG
        let process = ProcessInfo.processInfo
        if process.arguments.contains("-GroveUseFixtureAnalysis") { return nil }
        if let baseURL = serviceURL(from: process.environment["GROVE_ANALYSIS_BASE_URL"]) {
            return (baseURL.appendingPathComponent("events"), appKey ?? "")
        }
#endif
        guard let appKey = productionAppKey(for: "analytics"),
              let baseURL = productionAnalysisURL(for: "analytics") else { return nil }
        return (baseURL.appendingPathComponent("events"), appKey)
    }

    /// Client for the data-sync backend. Resolution order mirrors the analysis
    /// client: explicit local-dev override, then the `GROVE_SYNC_URL` build
    /// setting (`GroveSyncURL`); without it sync is off. The production client
    /// authenticates with the account's Supabase JWT; local-only accounts have
    /// none, and `SyncEngine`'s account-eligibility gate keeps them offline.
    private static func makeAPIClient(session: SessionService) -> APIClient? {
#if DEBUG
        let process = ProcessInfo.processInfo
        if process.arguments.contains("-GroveUseFixtureAnalysis") {
            return nil
        }
        let environmentBaseURL = serviceURL(from: process.environment["GROVE_API_BASE_URL"])
        let usesLocalBackend = process.arguments.contains("-GroveUseLocalBackend")
            || process.environment["GROVE_USE_LOCAL_BACKEND"] == "1"
            || environmentBaseURL != nil
        if usesLocalBackend,
           let baseURL = environmentBaseURL
               ?? serviceURL(from: "http://127.0.0.1:8080/v1/") {
            return APIClient(
                configuration: APIConfiguration(baseURL: baseURL, environment: .development, appKey: appKey ?? ""),
                accessToken: {
                    let expected = GroveAPIRequestScope.expectedAccountID
                    guard expected == nil || session.currentSession?.accountID == expected else { return nil }
                    return session.currentSession.map { "dev:\($0.accountID)" }
                }
            )
        }
#endif
        guard let appKey = productionAppKey(for: "data sync"),
              let baseURL = productionSyncURL(for: "data sync") else { return nil }
        return APIClient(
            configuration: APIConfiguration(baseURL: baseURL, environment: .production, appKey: appKey),
            accessToken: {
                let expected = GroveAPIRequestScope.expectedAccountID
                guard expected == nil || session.currentSession?.accountID == expected else { return nil }
                let token = await session.apiBearerToken()
                // Token refresh suspends and may overlap an account switch.
                guard expected == nil || session.currentSession?.accountID == expected else { return nil }
                return token
            }
        )
    }

    private struct RegisterDeviceRequest: Encodable {
        let token: String
        let environment: String
        let sittingUpdatesEnabled: Bool
    }

    /// Which APNs host the server should send this token to.
    ///
    /// Debug builds are signed with the development entitlement and receive
    /// sandbox tokens, which the production host rejects outright. Reporting the
    /// environment rather than assuming one is what lets a TestFlight build and
    /// a build straight from Xcode both work without a second table.
    private static var pushEnvironment: String {
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
        return pushEnvironment(provisioningProfile: profile)
    }

    /// Release is also installed with a development provisioning profile on a
    /// physical phone. APNs routes by that signing entitlement, not DEBUG.
    /// App Store builds omit the profile and always use production APNs.
    static func pushEnvironment(provisioningProfile: Data?) -> String {
        guard let data = provisioningProfile,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let profile = try? PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil
              ) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any],
              entitlements["aps-environment"] as? String == "development" else {
            return "production"
        }
        return "sandbox"
    }

    /// Wires `NotificationService` to Grove's device registry.
    ///
    /// Registration is deliberately fire-and-forget: a token that failed to
    /// reach the server is re-sent on the next launch, and there is nothing a
    /// user could do about it in the moment. Revocation is awaited, because it
    /// happens during sign-out and the promise it keeps — that this phone stops
    /// receiving the previous account's notifications — is worth the round trip.
    static func attachPushRegistration(to notifications: NotificationService, session: SessionService) {
        notifications.onRegisterDeviceToken = { token, sittingUpdatesEnabled in
            guard let client = makeAPIClient(session: session) else {
                // No sync client means a local-only account (guest or demo),
                // which has no server to be reached from. Logged because it is
                // otherwise indistinguishable from a registration that failed.
                GroveDiag.log("push: no API client, token not registered")
                return false
            }
            do {
                let _: EmptyAPIResponse = try await client.post(
                    "devices",
                    body: RegisterDeviceRequest(
                        token: token,
                        environment: pushEnvironment,
                        sittingUpdatesEnabled: sittingUpdatesEnabled
                    )
                )
                GroveDiag.log("push: device registered (\(pushEnvironment))")
                return true
            } catch {
                GroveDiag.log("push: device registration failed (\(error.localizedDescription))")
                return false
            }
        }
        notifications.onRevokeDeviceToken = { token in
            guard let client = makeAPIClient(session: session) else { return }
            do {
                let _: EmptyAPIResponse = try await client.delete("devices/\(token)")
            } catch {
                GroveDiag.log("push: device revoke failed (\(error.localizedDescription))")
            }
        }
    }

    private struct AccountDeletionResponse: Decodable {
        let deleted: Bool
    }

    /// Why a deletion could not even be attempted against the server. Kept
    /// separate from `APIError` because the recovery differs: these are not
    /// "try again", they are "sign in again first".
    enum AccountDeletionError: LocalizedError, Equatable {
        /// The account never existed on the server — nothing to delete there.
        case noServerAccount
        /// The account is real, but this device no longer holds a credential the
        /// server accepts.
        case sessionExpired

        var errorDescription: String? {
            switch self {
            case .noServerAccount:
                "This grove has no server account to delete."
            case .sessionExpired:
                "The sign-in for this account has expired, so the server copy can't be deleted yet. Sign in again, then delete."
            }
        }
    }

    /// Permanently removes a Supabase-backed identity and its server Grove.
    /// Local cleanup happens only after this returns, so a network failure can
    /// never leave the UI claiming an account was deleted when it still exists.
    ///
    /// A rejected bearer is retried once with a freshly exchanged one. Deletion
    /// is usually the last thing someone does in an app they have stopped
    /// opening, which is exactly when the stored access token has gone stale —
    /// and unlike every other request, this one has no local fallback, so
    /// spending a round trip to be sure is always worth it.
    static func deleteAccount(session: SessionService) async throws {
        guard session.currentSession?.mode.isSupabaseBacked == true,
              let client = makeAPIClient(session: session) else {
            throw AccountDeletionError.noServerAccount
        }
        try await deleteAccount(session: session, using: client)
    }

    /// The deletion exchange itself, over a caller-supplied client so tests can
    /// drive the retry without reaching the production gateway.
    static func deleteAccount(session: SessionService, using client: APIClient) async throws {
        do {
            try await requestDeletion(using: client)
        } catch APIError.unauthorised {
            guard await session.refreshedAPIBearerToken() != nil else {
                throw AccountDeletionError.sessionExpired
            }
            do {
                try await requestDeletion(using: client)
            } catch APIError.unauthorised {
                throw AccountDeletionError.sessionExpired
            }
        }
    }

    private static func requestDeletion(using client: APIClient) async throws {
        let response: AccountDeletionResponse = try await client.delete("account")
        guard response.deleted else { throw APIError.invalidResponse }
    }

    /// Client for the scan-analysis gateway. Resolution order:
    /// 1. `-GroveUseFixtureAnalysis` (tests) — no client, deterministic local analysis.
    /// 2. `GROVE_ANALYSIS_BASE_URL` environment value (Debug runs from Xcode/scripts).
    /// 3. `GroveAnalysisURL` baked into Info.plist from the `GROVE_ANALYSIS_URL`
    ///    build setting (Config/Secrets.xcconfig, release scripts, CI).
    /// 4. Nothing: without it the service is off and a config error is logged.
    ///
    /// Production authenticates with a verified Supabase JWT, exactly as the
    /// botanist does. A scan costs real provider money, so the gateway has to
    /// know the account is real before it spends any — an account id the caller
    /// simply asserted would make the per-account daily ceiling meaningless,
    /// since anyone holding the app key could invent a fresh one per request.
    private static func makeAnalysisAPIClient(session: SessionService) -> APIClient? {
#if DEBUG
        let process = ProcessInfo.processInfo
        if process.arguments.contains("-GroveUseFixtureAnalysis") {
            return nil
        }
        if let baseURL = serviceURL(from: process.environment["GROVE_ANALYSIS_BASE_URL"]) {
            return APIClient(
                configuration: APIConfiguration(baseURL: baseURL, environment: .development, appKey: appKey ?? ""),
                accessToken: { session.currentSession.map { "dev:\($0.accountID)" } }
            )
        }
#endif
        guard let appKey = productionAppKey(for: "plant analysis"),
              let baseURL = productionAnalysisURL(for: "plant analysis") else { return nil }
        return APIClient(
            configuration: APIConfiguration(baseURL: baseURL, environment: .production, appKey: appKey),
            accessToken: { await session.analysisBearerToken() }
        )
    }

    /// Botanist uses the analysis origin but a stronger identity contract. In
    /// production every request requires the Supabase JWT of a provisioned
    /// account; public anonymous identities are accepted only by the strictly
    /// capped analysis route. An explicit Debug server keeps the development
    /// `dev:<account>` contract so local backend work stays usable.
    private static func makeBotanistAPIClient(session: SessionService) -> APIClient? {
#if DEBUG
        let process = ProcessInfo.processInfo
        if process.arguments.contains("-GroveUseFixtureAnalysis") {
            return nil
        }
        if let baseURL = serviceURL(from: process.environment["GROVE_ANALYSIS_BASE_URL"]) {
            return APIClient(
                configuration: APIConfiguration(baseURL: baseURL, environment: .development, appKey: appKey ?? ""),
                accessToken: { session.currentSession.map { "dev:\($0.accountID)" } }
            )
        }
#endif
        guard let appKey = productionAppKey(for: "botanist"),
              let baseURL = productionAnalysisURL(for: "botanist") else { return nil }
        return APIClient(
            configuration: APIConfiguration(baseURL: baseURL, environment: .production, appKey: appKey),
            accessToken: { await session.botanistBearerToken() }
        )
    }

    static func makeSyncEngine(session: SessionService) -> SyncEngine {
        guard let client = makeAPIClient(session: session) else { return SyncEngine() }
#if DEBUG
        // The local dev server accepts `dev:<account-id>` bearers for any
        // account, so every session is eligible when it is in use.
        let process = ProcessInfo.processInfo
        let usesLocalBackend = process.arguments.contains("-GroveUseLocalBackend")
            || process.environment["GROVE_USE_LOCAL_BACKEND"] == "1"
            || process.environment["GROVE_API_BASE_URL"] != nil
        if usesLocalBackend {
            return SyncEngine(
                repository: HTTPGroveRemoteRepository(client: client),
                mediaUploader: HTTPMediaUploadService(client: client)
            )
        }
#endif
        return SyncEngine(
            repository: HTTPGroveRemoteRepository(client: client),
            mediaUploader: HTTPMediaUploadService(client: client),
            accountEligibility: { session.isSupabaseBacked }
        )
    }

    static func makePlantAnalysisClient(session: SessionService) -> any PlantAnalysisClient {
        let client: any PlantAnalysisClient
        if let analysisClient = makeAnalysisAPIClient(session: session) {
            client = HTTPPlantAnalysisClient(client: analysisClient, sendsInlineImages: true)
        } else if productionAnalysisIsUnconfigured {
            client = UnconfiguredPlantAnalysisClient()
        } else {
            client = LocalPlantAnalysisClient()
        }
        #if targetEnvironment(simulator)
        return SimulatorAnalysisClient(session: session, live: client)
        #else
        return client
        #endif
    }

    static func makeBotanistClient(session: SessionService) -> any BotanistClient {
        let client: any BotanistClient
        if let botanistClient = makeBotanistAPIClient(session: session) {
            client = HTTPBotanistClient(client: botanistClient)
        } else {
            client = LocalBotanistClient()
        }
        #if targetEnvironment(simulator)
        return SimulatorBotanistClient(session: session, live: client)
        #else
        return client
        #endif
    }

    static func makeSpeciesSearchClient(session: SessionService) -> any PlantSpeciesSearchClient {
        let client: any PlantSpeciesSearchClient
        if let analysisClient = makeAnalysisAPIClient(session: session) {
            client = HTTPPlantSpeciesSearchClient(client: analysisClient)
        } else {
            client = LocalPlantSpeciesSearchClient()
        }
        #if targetEnvironment(simulator)
        return SimulatorSpeciesSearchClient(session: session, live: client)
        #else
        return client
        #endif
    }
}

/// Used when `GROVE_APP_KEY` is missing (see `GroveServiceFactory.appKey`):
/// every scan fails with the ordinary "couldn't read the photo" error, and the
/// cause is in the log, rather than inventing a health reading locally.
@MainActor
private struct UnconfiguredPlantAnalysisClient: PlantAnalysisClient {
    func analyse(request: PlantAnalysisRequest) async throws -> PlantAnalysisResult {
        throw PlantAnalysisError.unavailable
    }
}

#if targetEnvironment(simulator)
// Choose at request time: these clients are created before the skip button is
// tapped. Every other session continues to exercise its real configured service.
@MainActor
private struct SimulatorAnalysisClient: PlantAnalysisClient {
    let session: SessionService
    let live: any PlantAnalysisClient

    func analyse(request: PlantAnalysisRequest) async throws -> PlantAnalysisResult {
        if session.currentSession?.isSimulatorTroubleshooting == true {
            return try await LocalPlantAnalysisClient().analyse(request: request)
        }
        return try await live.analyse(request: request)
    }
}

@MainActor
private struct SimulatorSpeciesSearchClient: PlantSpeciesSearchClient {
    let session: SessionService
    let live: any PlantSpeciesSearchClient

    func search(query: String, regionCode: String?) async throws -> [SpeciesCandidate] {
        if session.currentSession?.isSimulatorTroubleshooting == true {
            return try await LocalPlantSpeciesSearchClient().search(query: query, regionCode: regionCode)
        }
        return try await live.search(query: query, regionCode: regionCode)
    }
}

@MainActor
private struct SimulatorBotanistClient: BotanistClient {
    let session: SessionService
    let live: any BotanistClient

    private var activeClient: any BotanistClient {
        session.currentSession?.isSimulatorTroubleshooting == true ? LocalBotanistClient() : live
    }

    func ask(
        conversation: [BotanistMessage], plantContext: String?, plantID: UUID?,
        threadID: UUID, photoAttachments: [BotanistPhotoAttachment], safetyOnly: Bool
    ) async throws -> BotanistAnswer {
        try await activeClient.ask(
            conversation: conversation, plantContext: plantContext, plantID: plantID,
            threadID: threadID, photoAttachments: photoAttachments, safetyOnly: safetyOnly
        )
    }

    func recordOutcome(adviceID: UUID, outcome: BotanistOutcome) async throws {
        try await activeClient.recordOutcome(adviceID: adviceID, outcome: outcome)
    }
}
#endif
