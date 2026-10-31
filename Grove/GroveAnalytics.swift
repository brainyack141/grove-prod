import Foundation
import os

/// Where `OnboardingAnalytics` events actually go.
///
/// Everything here is deliberately small and deliberately lossy. Diagnostics are
/// the least important thing the app does, so this never blocks a screen, never
/// retries into a loop, and drops a batch rather than let a failing network hold
/// memory. Events also keep going to the unified log, which stays the fastest
/// way to watch a funnel while developing.
///
/// **Identity.** A batch carries one random per-install UUID and nothing else —
/// no account id, no device identifier, no IP recorded on the server. It exists
/// so one person's six screens read as one funnel rather than six unrelated
/// rows, and it is reset by "Delete my Grove data" along with every other
/// device-level value. Adding anything identifying here means updating both
/// `PrivacyInfo.xcprivacy` and the Diagnostics section of the hosted privacy
/// policy in `supabase/functions/legal/index.ts`.
actor GroveAnalytics {
    static let shared = GroveAnalytics()

    struct Event: Encodable {
        let name: String
        let params: [String: String]
        let occurredAt: Date
    }

    private struct Batch: Encodable {
        let installID: UUID
        let events: [Event]
    }

    /// Flush once the buffer reaches this, so a long funnel does not sit
    /// entirely in memory waiting for a backgrounding that may never come.
    private static let flushThreshold = 8

    /// Quiet-period flush. Long enough that a fast tapper sends one request
    /// rather than six, short enough that abandoning the app mid-funnel still
    /// reports what happened.
    private static let flushDelay = Duration.seconds(10)

    /// A buffer that has outgrown this is dropped from the front. Only reachable
    /// if the network has been failing for a long time; keeping events is never
    /// worth unbounded memory.
    private static let maximumBuffered = 200

    private let storage: UserDefaults
    private let session: URLSession
    private let endpoint: (url: URL, appKey: String)?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "grove",
        category: "analytics"
    )

    private var buffer: [Event] = []
    private var flushTask: Task<Void, Never>?

    init(
        storage: UserDefaults = .standard,
        session: URLSession = .shared,
        endpoint: (url: URL, appKey: String)? = nil
    ) {
        self.storage = storage
        self.session = session
        // Resolved once: the gateway cannot change while the process lives.
        self.endpoint = endpoint ?? GroveServiceFactory.analyticsEndpoint
    }

    /// The random id this install reports under. Created on first use and kept
    /// in `UserDefaults` so it survives launches but not a reinstall.
    private var installID: UUID {
        if let raw = storage.string(forKey: GroveDefaults.analyticsInstallID),
           let existing = UUID(uuidString: raw) {
            return existing
        }
        let created = UUID()
        storage.set(created.uuidString, forKey: GroveDefaults.analyticsInstallID)
        return created
    }

    func record(_ name: String, _ params: [String: String]) {
        let payload = params
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        logger.log("\(name, privacy: .public) \(payload, privacy: .public)")

        guard endpoint != nil else { return }
        buffer.append(Event(name: name, params: params, occurredAt: .now))
        if buffer.count > Self.maximumBuffered {
            buffer.removeFirst(buffer.count - Self.maximumBuffered)
        }
        if buffer.count >= Self.flushThreshold {
            flushTask?.cancel()
            flushTask = nil
            Task { await self.flush() }
        } else {
            scheduleFlush()
        }
    }

    /// Drops diagnostics that have not left the phone and breaks the random
    /// install-id link for future events. A local-data wipe must reach this
    /// actor as well as UserDefaults; otherwise its in-memory batch can flush
    /// after deletion and silently recreate the identifier that was removed.
    func deleteAllLocalData() {
        flushTask?.cancel()
        flushTask = nil
        buffer = []
        storage.removeObject(forKey: GroveDefaults.analyticsInstallID)
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [flushDelay = Self.flushDelay] in
            try? await Task.sleep(for: flushDelay)
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    /// Sends whatever is buffered. Called on a timer, on a full buffer, and when
    /// the app leaves the foreground.
    ///
    /// The buffer is cleared *before* the request: a failed batch is gone. That
    /// is the intended trade — a retry queue for diagnostics would mean holding
    /// user-adjacent data across launches to protect a number nobody is waiting
    /// on, and the funnel reads fine with a few percent missing.
    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        guard let endpoint, !buffer.isEmpty else { return }
        let batch = Batch(installID: installID, events: buffer)
        buffer = []

        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(endpoint.appKey, forHTTPHeaderField: "X-Grove-App-Key")
        request.timeoutInterval = 10

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(batch) else { return }
        request.httpBody = body

        do {
            _ = try await session.data(for: request)
        } catch {
            // Nothing to do and nobody to tell. A dropped batch of diagnostics
            // is not worth a single pixel of the user's attention.
            logger.debug("analytics flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
