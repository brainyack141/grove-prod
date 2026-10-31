import Foundation

/// Binds a sync request to the account that started it.
///
/// The API client is app-scoped while sessions can change. Without a task-local
/// expectation, an await inside token refresh could resume after account B was
/// activated and send account A's queued mutation with B's bearer.
enum GroveAPIRequestScope {
    @TaskLocal static var expectedAccountID: String?
}

enum APIEnvironment: String, Codable {
    case development
    case staging
    case production
}

struct APIConfiguration: Hashable {
    let baseURL: URL
    let environment: APIEnvironment
    /// Shared app secret sent as `X-Grove-App-Key` on every request. Empty disables it.
    /// Must match the backend's `GROVE_APP_KEY`; lets a public API reject unknown callers.
    var appKey: String = ""

    static let development = APIConfiguration(
        baseURL: URL(string: "http://localhost:8080/v1/")!,
        environment: .development
    )
}

/// How long one request may take before the app gives up.
///
/// This exists because URLSession's 60-second default is the wrong shape for an
/// LLM-backed endpoint: the botanist coach is a synchronous call to a model that
/// routinely thinks for tens of seconds, and the app giving up first turns a
/// specific, actionable gateway error ("the botanist took too long") into a bare
/// "the connection dropped". Every caller's ceiling must stay *above* the
/// server's own deadline for that endpoint, never below it.
enum APITimeout {
    /// Plain CRUD against the sync API — a slow one of these really is stuck.
    static let standard: TimeInterval = 60
    /// The longest any single Grove request is allowed to run. The session is
    /// configured with this, and per-request values scale down from it.
    static let ceiling: TimeInterval = 120
}

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

enum APIError: LocalizedError, Equatable {
    case invalidURL
    /// The device has no usable connection — nothing left the phone.
    case offline
    /// The request left, but nothing came back inside the deadline.
    case timedOut
    case transport(String)
    case unauthorised
    case forbidden
    case notFound
    case conflict
    case validation(String)
    /// A ceiling the account has reached, not a mistake it made. Separated from
    /// `.validation` because retrying cannot succeed until the window rolls
    /// over, so any screen showing this must offer something other than a
    /// button that fails again.
    case rateLimited(message: String?)
    /// `message` is the gateway's own wording when it sent any. Carried rather
    /// than flattened to the status code because the specific reason — "the
    /// botanist took too long to answer" — is the difference between a user
    /// tapping Try again and giving up on a screen that says nothing useful.
    case server(status: Int, message: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Grove couldn't build that request."
        // Separated from `.transport` because the fix differs: one is "turn your
        // data back on", the other is "wait a moment and tap again". Telling an
        // offline user their connection dropped partway through sends them
        // looking for a problem at Grove's end.
        case .offline: "You're offline. Reconnect and try again."
        case .timedOut: "That's taking longer than it should. Try again."
        case .transport: "The connection dropped partway through. Try again."
        case .unauthorised: "You've been signed out. Sign in again to carry on."
        case .forbidden: "You don't have permission to do that any more."
        case .notFound: "That's been deleted, maybe on another device."
        case .conflict: "This changed on another device. Refresh and try again."
        case .validation(let message): message
        case .rateLimited(let message): message ?? "You've hit today's limit. Try again tomorrow."
        case .server(_, let message): message ?? "Grove's service is down for a moment. Try again shortly."
        case .invalidResponse: "Grove got a response it didn't understand. Try again."
        }
    }
}

private struct APIErrorEnvelope: Decodable {
    let message: String?

    /// The message only if it is fit to put in front of a user. A gateway is not
    /// the only thing that can answer a Grove request — a proxy or an edge
    /// runtime in front of it can too, and their bodies carry stack traces and
    /// request ids rather than sentences.
    var userFacingMessage: String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return nil }
        return trimmed
    }
}

private struct EmptyRequest: Encodable {}

@MainActor
final class APIClient {
    typealias AccessTokenProvider = @MainActor () async -> String?

    private let configuration: APIConfiguration
    private let session: URLSession
    private let accessToken: AccessTokenProvider
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Grove's own session rather than `URLSession.shared`, whose 60-second
    /// request timeout is fixed for every caller in the process. Configured at
    /// the ceiling so the per-request `timeoutInterval` set in `send` is always
    /// the binding constraint, whichever of the two the platform prefers.
    ///
    /// `waitsForConnectivity` stays off deliberately: a request made with no
    /// signal should say "you're offline" straight away rather than sit on a
    /// spinner until the deadline in the hope that a network turns up.
    ///
    /// One instance for the whole app — a `URLSession` keeps itself alive until
    /// it is invalidated, so minting one per client would strand a connection
    /// pool every time the services are rebuilt.
    private static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = APITimeout.ceiling
        // A whole request, redirects and all, should never outlive the screen
        // the user is looking at.
        configuration.timeoutIntervalForResource = APITimeout.ceiling * 2
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Pass a session only to drive it from a test; production callers take the
    /// configured one above.
    init(
        configuration: APIConfiguration,
        session: URLSession? = nil,
        accessToken: @escaping AccessTokenProvider
    ) {
        self.configuration = configuration
        self.session = session ?? Self.shared
        self.accessToken = accessToken
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func get<Response: Decodable>(_ path: String) async throws -> Response {
        try await send(path, method: .get, body: Optional<EmptyRequest>.none)
    }

    func delete<Response: Decodable>(_ path: String) async throws -> Response {
        try await send(path, method: .delete, body: Optional<EmptyRequest>.none)
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        idempotencyKey: UUID? = nil,
        timeout: TimeInterval = APITimeout.standard
    ) async throws -> Response {
        try await send(path, method: .post, body: body, idempotencyKey: idempotencyKey, timeout: timeout)
    }

    func patch<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        idempotencyKey: UUID? = nil
    ) async throws -> Response {
        try await send(path, method: .patch, body: body, idempotencyKey: idempotencyKey)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: HTTPMethod,
        body: Body?,
        idempotencyKey: UUID? = nil,
        timeout: TimeInterval = APITimeout.standard
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: configuration.baseURL) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = min(timeout, APITimeout.ceiling)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The key must be stable across retries of the same logical mutation —
        // a fresh key per HTTP attempt would defeat server replay protection
        // exactly when it matters (ambiguous transport/server failures where
        // the first attempt may have committed).
        request.setValue((idempotencyKey ?? UUID()).uuidString, forHTTPHeaderField: "Idempotency-Key")
        if !configuration.appKey.isEmpty {
            request.setValue(configuration.appKey, forHTTPHeaderField: "X-Grove-App-Key")
        }
        if let token = await accessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try encoder.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw Self.failure(for: error)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data)
            switch http.statusCode {
            case 401: throw APIError.unauthorised
            // Feature clients translate 402 into their own product policy
            // result. Treating it as field validation erased the status and
            // made a legitimate premium boundary look like bad user input.
            case 402: throw APIError.server(status: 402, message: envelope?.userFacingMessage)
            case 403: throw APIError.forbidden
            case 404: throw APIError.notFound
            case 409: throw APIError.conflict
            case 429: throw APIError.rateLimited(message: envelope?.userFacingMessage)
            case 400..<500: throw APIError.validation(envelope?.userFacingMessage ?? "That couldn't be saved as it is. Check it and try again.")
            default: throw APIError.server(status: http.statusCode, message: envelope?.userFacingMessage)
            }
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Splits URLSession's failures into the three things a user can act on:
    /// they have no connection, the wait ran out, or the connection broke.
    private static func failure(for error: URLError) -> APIError {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut:
            return .timedOut
        default:
            return .transport(error.localizedDescription)
        }
    }
}
