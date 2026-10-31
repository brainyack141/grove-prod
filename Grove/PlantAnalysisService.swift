import Foundation

enum PlantAnalysisError: LocalizedError, Equatable {
    case invalidImage
    case imageTooSmall
    /// Nothing left the phone. Kept apart from `.unavailable` because the fix
    /// is the user's connection, not patience with Grove — and the screen that
    /// shows it should not blame a service that was never reached.
    case offline
    case unavailable
    /// The account's scan ceiling for today. Nothing to retry until tomorrow.
    case atDailyLimit(message: String)
    case malformedResponse
    case reported(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidImage: "Grove couldn't read that image. Take it again."
        case .imageTooSmall: "That image is too small to read anything from. Get closer and try again."
        case .offline: "You're offline, so this photo hasn't been analysed yet. It's saved. Reconnect and try again."
        // Deliberately does not promise a "later": the photo is kept, but the
        // only thing on offer right now is another attempt.
        case .unavailable: "Grove couldn't read the photo this time. It's saved, so try again in a moment."
        case .atDailyLimit(let message): message
        case .malformedResponse: "That result came back incomplete. Your photo is saved. Try again in a moment."
        case .reported(let message): message
        }
    }
}

@MainActor
protocol PlantAnalysisClient {
    func analyse(request: PlantAnalysisRequest) async throws -> PlantAnalysisResult
}

@MainActor
protocol PlantSpeciesSearchClient {
    func search(query: String, regionCode: String?) async throws -> [SpeciesCandidate]
}

@MainActor
struct LocalPlantSpeciesSearchClient: PlantSpeciesSearchClient {
    private let catalogue = [
        SpeciesCandidate(id: "epipremnum-aureum", commonName: "Golden pothos", scientificName: "Epipremnum aureum", confidence: 100, distinguishingTraits: ["Heart-shaped variegated leaves", "Trailing vine"], regionalFit: "Widely grown indoors"),
        SpeciesCandidate(id: "dracaena-trifasciata", commonName: "Snake plant", scientificName: "Dracaena trifasciata", confidence: 100, distinguishingTraits: ["Upright sword-shaped leaves"], regionalFit: "Widely grown indoors"),
        SpeciesCandidate(id: "ficus-lyrata", commonName: "Fiddle-leaf fig", scientificName: "Ficus lyrata", confidence: 100, distinguishingTraits: ["Large violin-shaped leaves"], regionalFit: "Common indoor tree"),
        SpeciesCandidate(id: "spathiphyllum-wallisii", commonName: "Peace lily", scientificName: "Spathiphyllum wallisii", confidence: 100, distinguishingTraits: ["White spathes", "Glossy lance-shaped leaves"], regionalFit: "Common indoor flowering plant"),
        SpeciesCandidate(id: "monstera-deliciosa", commonName: "Swiss cheese plant", scientificName: "Monstera deliciosa", confidence: 100, distinguishingTraits: ["Fenestrated mature leaves"], regionalFit: "Widely grown indoors")
    ]

    func search(query: String, regionCode: String?) async throws -> [SpeciesCandidate] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return catalogue }
        return catalogue.filter {
            $0.commonName.localizedCaseInsensitiveContains(query)
                || $0.scientificName.localizedCaseInsensitiveContains(query)
        }
    }
}

extension PlantAnalysisClient {
    func analyse(imageData: Data, mode: ScanMode) async throws -> PlantAnalysisResult {
        try await analyse(
            request: PlantAnalysisRequest(
                mode: mode,
                images: [PlantAnalysisImage(stage: .wholePlant, mimeType: "image/jpeg", base64Data: imageData.base64EncodedString())],
                regionCode: nil,
                existingPlant: nil,
                answers: [:]
            )
        )
    }
}

@MainActor
struct LocalPlantAnalysisClient: PlantAnalysisClient {
    var simulatedDelay: Duration = .milliseconds(850)

    func analyse(request: PlantAnalysisRequest) async throws -> PlantAnalysisResult {
        guard !request.images.isEmpty,
              request.images.allSatisfy({ Data(base64Encoded: $0.base64Data)?.isEmpty == false }) else {
            throw PlantAnalysisError.invalidImage
        }
        try await Task.sleep(for: simulatedDelay)
        try Task.checkCancellation()

        let condition: PlantConditionResult
        if request.mode == .diagnose {
            condition = PlantConditionResult(
                healthScore: 66,
                healthBand: .monitor,
                confidence: 81,
                summary: "Leaf yellowing is visible, but a photo alone cannot confirm the cause. Check the soil before changing its care.",
                positiveSigns: ["Stems remain firm", "Newer leaves retain good colour"],
                concerns: ["Yellowing on a lower leaf", "Slight downward curl"],
                possibleCauses: ["Soil staying wet for too long", "Normal ageing of a lower leaf", "Low light slowing water use"],
                nextActions: ["Check soil 3–5 cm deep", "Confirm the pot drains freely", "Review again in 7 days"],
                possibleConditions: [
                    PlantConditionCandidate(
                        id: "excess-moisture",
                        name: "Excess moisture stress",
                        confidence: 68,
                        explanation: "Lower-leaf yellowing and downward curl can occur when roots remain wet.",
                        evidence: ["Yellowing begins on a lower leaf", "Slight downward curl"],
                        alternativeExplanation: "A single old leaf can yellow naturally even when care is appropriate."
                    ),
                    PlantConditionCandidate(
                        id: "natural-senescence",
                        name: "Normal lower-leaf ageing",
                        confidence: 41,
                        explanation: "Older shaded leaves are sometimes shed as the plant redirects energy.",
                        evidence: ["Newer leaves retain good colour", "Stems remain firm"],
                        alternativeExplanation: "Several yellow leaves or persistently wet soil would make moisture stress more likely."
                    )
                ],
                questions: request.answers.isEmpty ? [
                    DiagnosisQuestion(
                        id: "soil-moisture",
                        prompt: "How does the soil feel 3–5 cm below the surface?",
                        options: [
                            DiagnosisAnswerOption(id: "dry", title: "Dry"),
                            DiagnosisAnswerOption(id: "slightly-damp", title: "Slightly damp"),
                            DiagnosisAnswerOption(id: "wet", title: "Wet or soggy")
                        ],
                        reason: "Moisture helps distinguish normal ageing from root stress."
                    ),
                    DiagnosisQuestion(
                        id: "spread",
                        prompt: "Is the yellowing limited to one older leaf?",
                        options: [
                            DiagnosisAnswerOption(id: "one", title: "One older leaf"),
                            DiagnosisAnswerOption(id: "several", title: "Several leaves"),
                            DiagnosisAnswerOption(id: "new-growth", title: "New growth too")
                        ],
                        reason: "Where symptoms appear changes the likely explanation."
                    )
                ] : [],
                actionsToAvoid: ["Do not water again until the soil is checked", "Do not add fertiliser while the cause is uncertain", "Do not repot solely because one older leaf is yellow"],
                urgentFlags: [],
                followUpDays: 7,
                indicatorFindings: [
                    PlantVisualIndicatorFinding(
                        kind: .foliage,
                        state: .watch,
                        severity: 1,
                        confidence: 81,
                        evidence: ["Yellowing is visible on one lower leaf"]
                    ),
                    PlantVisualIndicatorFinding(
                        kind: .posture,
                        state: .watch,
                        severity: 1,
                        confidence: 78,
                        evidence: ["A slight downward curl is visible"]
                    ),
                    PlantVisualIndicatorFinding(
                        kind: .growth,
                        state: .unavailable,
                        severity: 0,
                        confidence: 0,
                        evidence: []
                    )
                ]
            )
        } else {
            condition = PlantConditionResult(
                healthScore: 82,
                healthBand: .healthy,
                confidence: 86,
                summary: "The plant appears healthy overall. One lower leaf shows mild yellowing, so inspect soil moisture before watering.",
                positiveSigns: ["Firm stems", "Even colour on newer leaves", "Visible new growth"],
                concerns: ["Mild yellowing on one lower leaf"],
                possibleCauses: ["Normal leaf ageing", "Soil remaining damp"],
                nextActions: ["Check the top 3 cm of soil before watering", "Keep in bright, indirect light"],
                possibleConditions: [],
                questions: [],
                actionsToAvoid: ["Avoid watering on a fixed calendar without checking the soil"],
                urgentFlags: [],
                followUpDays: 14,
                indicatorFindings: [
                    PlantVisualIndicatorFinding(
                        kind: .foliage,
                        state: .good,
                        severity: 0,
                        confidence: 86,
                        evidence: ["Newer leaves have even colour"]
                    ),
                    PlantVisualIndicatorFinding(
                        kind: .posture,
                        state: .good,
                        severity: 0,
                        confidence: 86,
                        evidence: ["Stems appear firm"]
                    ),
                    PlantVisualIndicatorFinding(
                        kind: .growth,
                        state: .good,
                        severity: 0,
                        confidence: 84,
                        evidence: ["New growth is visible"]
                    )
                ]
            )
        }

        let candidates = [
            SpeciesCandidate(
                id: "monstera-deliciosa",
                commonName: "Swiss cheese plant",
                scientificName: "Monstera deliciosa",
                confidence: 94,
                distinguishingTraits: ["Natural leaf fenestrations", "Heart-shaped juvenile leaves"],
                regionalFit: request.regionCode.map { "Commonly grown indoors in \($0)" }
            ),
            SpeciesCandidate(
                id: "monstera-borsigiana",
                commonName: "Climbing Monstera",
                scientificName: "Monstera deliciosa var. borsigiana",
                confidence: 58,
                distinguishingTraits: ["Longer internodes", "Smaller mature leaves"],
                regionalFit: "Common indoor alternative"
            ),
            SpeciesCandidate(
                id: "thaumatophyllum-bipinnatifidum",
                commonName: "Split-leaf philodendron",
                scientificName: "Thaumatophyllum bipinnatifidum",
                confidence: 29,
                distinguishingTraits: ["Deep lobes without enclosed holes", "Self-heading growth"],
                regionalFit: "Commonly confused ornamental"
            )
        ]

        return PlantAnalysisResult(
            identification: PlantIdentificationResult(
                commonName: "Swiss cheese plant",
                scientificName: "Monstera deliciosa",
                confidence: 94,
                alternatives: ["Monstera borsigiana", "Split-leaf philodendron"],
                distinguishingTraits: ["Natural leaf fenestrations", "Heart-shaped juvenile leaves"],
                candidates: candidates,
                isUnknown: false,
                // 94% against a 58% runner-up is a decisive call — mirrors the
                // gateway's `isDecisive` gate in `analysis-safety.mjs`, so the
                // offline path states the identity rather than asking about it.
                requiresConfirmation: false,
                regionCode: request.regionCode,
                imageQualityWarnings: request.images.count == 1 ? ["Add a leaf detail for a stronger match"] : []
            ),
            condition: condition,
            growingConditions: PlantGrowingConditions(
                potMaterial: .plastic,
                potSize: .medium,
                drainage: .cachepot,
                substrate: .standard,
                soilSurface: .damp,
                surfaceSigns: [],
                potFit: .balanced,
                confidence: 72
            ),
            providerName: "Grove local evaluation",
            limitations: ["Visual assessment only", "Species and condition remain probabilistic"]
        )
    }
}

@MainActor
final class HTTPPlantAnalysisClient: PlantAnalysisClient {
    private let client: APIClient
    private let mediaUploader: any MediaUploading
    private let pollInterval: Duration
    private let initialPollDelay: Duration
    private let pollDeadline: Duration
    private let creationRetryDelay: Duration
    private let maximumCreationAttempts: Int
    /// The Edge Function gateway accepts bounded base64 evidence in the job
    /// body itself; the signed media-upload flow is only for the sync backend.
    private let sendsInlineImages: Bool

    /// - Parameters:
    ///   - pollInterval: the steady cadence between polls once analysis is under
    ///     way. Every poll is a gateway request and a database read, so this is
    ///     a real per-scan cost multiplied by everyone scanning at once.
    ///   - initialPollDelay: how long to wait before the *first* poll. A vision
    ///     model on four photos does not answer in half a second, so asking that
    ///     early only ever produces "still queued" — defaults to twice the
    ///     interval, which is about the fastest a real result has ever arrived.
    init(
        client: APIClient,
        mediaUploader: (any MediaUploading)? = nil,
        pollInterval: Duration = .seconds(2),
        initialPollDelay: Duration? = nil,
        pollDeadline: Duration = .seconds(150),
        creationRetryDelay: Duration = .milliseconds(400),
        maximumCreationAttempts: Int = 3,
        sendsInlineImages: Bool = false
    ) {
        self.client = client
        self.mediaUploader = mediaUploader ?? HTTPMediaUploadService(client: client)
        self.pollInterval = pollInterval
        self.initialPollDelay = initialPollDelay ?? pollInterval * 2
        self.pollDeadline = pollDeadline
        self.creationRetryDelay = creationRetryDelay
        self.maximumCreationAttempts = max(1, maximumCreationAttempts)
        self.sendsInlineImages = sendsInlineImages
    }

    /// Spreads polls out by ±15% so a thousand scans started by a push, a
    /// morning routine, or a recovering network do not all knock on the gateway
    /// in the same instant.
    private func jittered(_ delay: Duration) -> Duration {
        guard delay > .zero else { return delay }
        let milliseconds = Double(delay.components.seconds) * 1_000
            + Double(delay.components.attoseconds) / 1_000_000_000_000_000
        return .milliseconds(Int(milliseconds * Double.random(in: 0.85...1.15)))
    }

    func analyse(request: PlantAnalysisRequest) async throws -> PlantAnalysisResult {
        do {
            var resumableRequest = request
            if resumableRequest.clientRequestID == nil {
                resumableRequest.clientRequestID = UUID()
            }
            var jobImages: [PlantAnalysisJobImage] = []
            for image in resumableRequest.images {
                if !sendsInlineImages,
                   let localMediaID = image.localMediaID,
                   let localFileURL = image.localFileURL,
                   let pixelWidth = image.pixelWidth,
                   let pixelHeight = image.pixelHeight {
                    let uploaded = try await mediaUploader.upload(
                        PendingMediaUpload(
                            localMediaID: localMediaID,
                            fileURL: localFileURL,
                            purpose: .scan,
                            mimeType: image.mimeType,
                            pixelWidth: pixelWidth,
                            pixelHeight: pixelHeight
                        )
                    )
                    jobImages.append(
                        PlantAnalysisJobImage(
                            stage: image.stage,
                            mimeType: image.mimeType,
                            base64Data: nil,
                            mediaAssetID: uploaded.mediaAssetID,
                            qualityWarnings: image.qualityWarnings
                        )
                    )
                } else {
                    jobImages.append(
                        PlantAnalysisJobImage(
                            stage: image.stage,
                            mimeType: image.mimeType,
                            base64Data: image.base64Data,
                            mediaAssetID: nil,
                            qualityWarnings: image.qualityWarnings
                        )
                    )
                }
            }
            let jobRequest = PlantAnalysisJobRequest(
                clientRequestID: resumableRequest.clientRequestID,
                mode: resumableRequest.mode,
                images: jobImages,
                regionCode: resumableRequest.regionCode,
                existingPlant: resumableRequest.existingPlant,
                answers: resumableRequest.answers
            )
            var job = try await createJob(request: jobRequest)

            // The server bounds every job, but the client still enforces its own
            // deadline so a lost response or stalled job can never leave the scan
            // screen spinning indefinitely.
            let deadline = ContinuousClock.now + pollDeadline
            var delay = initialPollDelay
            var consecutivePollFailures = 0
            do {
                while true {
                    try Task.checkCancellation()
                    switch job.status {
                    case .queued, .analysing:
                        guard ContinuousClock.now < deadline else {
                            cancelJobRemotely(id: job.id)
                            throw PlantAnalysisError.reported(
                                message: "This is taking longer than it should. Your photos are saved. Try again in a moment."
                            )
                        }
                        try await Task.sleep(for: jittered(delay))
                        delay = pollInterval
                        do {
                            job = try await client.get("analysis/jobs/\(job.id.uuidString.lowercased())")
                            consecutivePollFailures = 0
                        } catch let pollError as APIError {
                            // The job keeps running server-side, so a brief
                            // network blip while polling should not abandon the
                            // whole analysis. If an Edge instance loses a job,
                            // recreating with the stable client request id
                            // either resumes the durable job or safely starts a
                            // replacement.
                            switch pollError {
                            case .notFound:
                                job = try await createJob(request: jobRequest)
                                consecutivePollFailures = 0
                                delay = pollInterval
                            case .transport, .timedOut, .offline, .server:
                                consecutivePollFailures += 1
                                if consecutivePollFailures >= 5 {
                                    job = try await createJob(request: jobRequest)
                                    consecutivePollFailures = 0
                                    delay = pollInterval
                                }
                            default:
                                throw pollError
                            }
                        }
                    case .completed:
                        guard let result = job.result else { throw PlantAnalysisError.malformedResponse }
                        return result
                    case .failed, .cancelled:
                        // The gateway supplies a safe, user-facing failure message (for example
                        // distinguishing a provider timeout from temporary unavailability).
                        if let message = job.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                            throw PlantAnalysisError.reported(message: message)
                        }
                        throw PlantAnalysisError.unavailable
                    }
                }
            } catch is CancellationError {
                cancelJobRemotely(id: job.id)
                throw CancellationError()
            }
        } catch let error as APIError {
            switch error {
            case .offline:
                // The one failure the phone can diagnose by itself. Flattening
                // it into `.unavailable` sent people looking for a fault at
                // Grove's end while their own data was switched off.
                throw PlantAnalysisError.offline
            case .rateLimited(let message):
                throw PlantAnalysisError.atDailyLimit(
                    message: message ?? "You've used today's scans. Your photos are saved. Try again tomorrow."
                )
            case .server(_, .some(let message)):
                // The gateway distinguishes a provider timeout from a cold
                // model; keep its sentence rather than replace it with ours.
                throw PlantAnalysisError.reported(message: message)
            case .transport, .timedOut, .server, .notFound:
                // .notFound covers a server restart that lost the in-memory job;
                // retrying simply starts a fresh one.
                throw PlantAnalysisError.unavailable
            case .invalidResponse:
                throw PlantAnalysisError.malformedResponse
            default:
                throw error
            }
        }
    }

    /// Exposed so callers (and tests) can await the fire-and-forget cancellation.
    private(set) var pendingRemoteCancellation: Task<Void, Never>?

    /// A brief connection drop or a cold Edge Function should not eject the
    /// user to a failure screen. The request carries a stable client request ID,
    /// so the gateway safely resumes the same job if the first response was
    /// lost after creation.
    private func createJob(request: PlantAnalysisJobRequest) async throws -> PlantAnalysisJobResponse {
        var delay = creationRetryDelay
        for attempt in 1...maximumCreationAttempts {
            do {
                return try await client.post("analysis/jobs", body: request)
            } catch let error as APIError {
                let isTransient: Bool
                switch error {
                case .transport, .server:
                    isTransient = true
                default:
                    isTransient = false
                }
                guard isTransient, attempt < maximumCreationAttempts else { throw error }
                try await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(2))
            }
        }
        throw PlantAnalysisError.unavailable
    }

    /// Fire-and-forget: stop the server working on a job the user no longer awaits.
    private func cancelJobRemotely(id: UUID) {
        let client = self.client
        pendingRemoteCancellation = Task { @MainActor in
            let _: PlantAnalysisJobResponse? = try? await client.delete("analysis/jobs/\(id.uuidString.lowercased())")
        }
    }
}

private struct PlantAnalysisJobRequest: Encodable {
    let clientRequestID: UUID?
    let mode: ScanMode
    let images: [PlantAnalysisJobImage]
    let regionCode: String?
    let existingPlant: PlantAnalysisPlantContext?
    let answers: [String: String]
}

private struct PlantAnalysisJobImage: Encodable {
    let stage: ScanCaptureStage
    let mimeType: String
    let base64Data: String?
    let mediaAssetID: UUID?
    /// The on-device quality gate's findings for this photo. Without them the
    /// gateway labels every photo "no warning" for the model, and its check
    /// for a confident identification never sees a soft or dark capture.
    let qualityWarnings: [String]?
}

private enum PlantAnalysisJobStatus: String, Codable {
    case queued
    case analysing
    case completed
    case failed
    case cancelled
}

private struct PlantAnalysisJobResponse: Codable {
    let id: UUID
    let status: PlantAnalysisJobStatus
    let result: PlantAnalysisResult?
    let message: String?
}

@MainActor
final class HTTPPlantSpeciesSearchClient: PlantSpeciesSearchClient {
    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func search(query: String, regionCode: String?) async throws -> [SpeciesCandidate] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else { return [] }
        // `urlQueryAllowed` includes separators such as `&` and `#`. Letting
        // those through changes the request rather than searching for the text
        // the user typed (and made catalogue search a small query-injection
        // surface). Keep the client inside the server's 160-character bound.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        var bounded = ""
        var usedUTF16Units = 0
        for character in normalized {
            let width = String(character).utf16.count
            guard usedUTF16Units + width <= 160 else { break }
            bounded.append(character)
            usedUTF16Units += width
        }
        guard let escaped = bounded.addingPercentEncoding(withAllowedCharacters: allowed) else { return [] }
        return try await client.get("species/search?q=\(escaped)")
    }
}

/// Resolves the canonical taxon id for plants that were identified from a photo.
///
/// The scan's own identification never carries one. Gemini returns a name, not
/// a key in anybody's taxonomy, and `Plant.canonicalTaxonID` was only ever
/// written when a user opened species search and re-confirmed the match by
/// hand. Everyone who accepted the top answer — which is most people — kept
/// `nil` for the life of the plant, so `PlantSafety` and `PlantCareProfile`
/// both fell through to matching on display text forever.
///
/// String matching on a toxicity table is the failure that matters here: a
/// rename, a subspecies, or a common name in the scientific field and the plant
/// silently stops matching its own safety record. The infrastructure to do
/// better already existed on both sides — GBIF-backed search returning
/// `gbif:<key>`, and a catalogue keyed by those ids — with nothing joining
/// them. This joins them, in the background, for the path most scans take.
///
/// Deliberately narrow: it never touches the species name, the common name, or
/// the confirmation state. Resolving an id is a bookkeeping improvement to a
/// match the user already accepted, not a re-identification, and it must never
/// be able to change what the plant page says the plant is.
@MainActor
enum PlantTaxonResolver {
    /// Names looked up per pass. A returning user with thirty unresolved plants
    /// backfills over a few launches rather than opening thirty requests at once.
    static let batchLimit = 5

    /// The placeholder `addPlant` writes when the scan could not name a species.
    /// Looking it up would return whatever GBIF makes of the phrase.
    static let unresolvedName = "species unconfirmed"

    /// Maps each scientific name to its canonical taxon id, for the names that
    /// resolve to exactly one taxon of the same name.
    ///
    /// The equality check is the whole safety argument. GBIF's search is fuzzy
    /// and will happily return *Ficus benjamina* for a query of *Ficus
    /// benghalensis*; accepting that would attach one plant's toxicity record
    /// to another. A name that does not come back as itself is left unresolved,
    /// which is exactly the state it was already in.
    static func resolve(
        names: [String],
        regionCode: String?,
        using client: any PlantSpeciesSearchClient
    ) async -> [String: String] {
        var resolved: [String: String] = [:]
        for name in names.prefix(batchLimit) {
            if Task.isCancelled { break }
            let wanted = normalized(name)
            guard let candidates = try? await client.search(query: name, regionCode: regionCode) else { continue }
            let matches = candidates.filter { normalized($0.scientificName) == wanted }
            guard matches.count == 1,
                  let id = matches[0].canonicalTaxonID ?? (matches[0].id.hasPrefix("gbif:") ? matches[0].id : nil)
            else { continue }
            resolved[name] = id
        }
        return resolved
    }

    /// Whether a scientific name is worth asking a taxonomy about. A single
    /// word is a genus, and a genus id would match a safety record for a
    /// sibling species.
    static func isResolvable(_ scientificName: String) -> Bool {
        let name = normalized(scientificName)
        guard !name.isEmpty, name != unresolvedName else { return false }
        return name.split(separator: " ").count >= 2
    }

    static func normalized(_ value: String) -> String {
        value
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
