import Foundation

// MARK: - Conversation model

struct BotanistSource: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let publisher: String
    let url: URL
    let reviewedAt: String
    let summary: String
}

enum BotanistOutcome: String, Codable, Hashable, Sendable {
    case helpful
    case notHelpful = "not_helpful"
    case improved
    case same
    case worse
}

/// The free-question meter as the gateway counted it.
///
/// The app keeps its own running count so the composer can show a number without
/// waiting for a round trip, but that count is a display convenience and nothing
/// more — this is the one that decides. It arrives with every answer, so a device
/// whose clock, time zone, or stored count has drifted is corrected on the next
/// question rather than at midnight.
///
/// `limit` and `remaining` are nil for an account that is not metered at all
/// (premium, or Grove's pre-launch early access). Nil rather than a large number
/// on purpose: there is no countdown to draw, and a client handed `Int.max` will
/// eventually render it.
struct BotanistAskQuota: Hashable, Sendable, Decodable {
    let metered: Bool
    let premium: Bool
    let limit: Int?
    let used: Int
    let remaining: Int?
    let resetsAt: Date?
}

struct BotanistAnswer: Hashable, Sendable {
    let reply: String
    let adviceID: UUID?
    let disposition: String
    let confidence: String
    let followUpAt: Date?
    let sources: [BotanistSource]
    let verification: String
    let provider: String?
    let model: String?
    let usedPhotoMessageIDs: [UUID]
    let visualEvidence: String?
    /// Absent from deterministic safety answers, which charge nothing, and from
    /// a gateway older than contract 8. Both mean "leave the local count alone".
    let quota: BotanistAskQuota?
}

struct BotanistPhotoAttachment: Hashable, Sendable {
    let messageID: UUID
    let data: Data
}

/// One turn in a botanist conversation. Persisted, so the wire names are stable.
struct BotanistMessage: Identifiable, Hashable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case botanist
    }

    let id: UUID
    let role: Role
    var text: String
    let createdAt: Date
    /// Protected on-device copy of the photo sent with this turn. The image is
    /// deliberately kept out of `UserDefaults`; only this file URL is persisted
    /// with the transcript so a few questions cannot inflate the preferences
    /// store by megabytes.
    var photoURL: URL?
    /// Server-side advice identity and review metadata. Optional so every
    /// conversation saved before Botanist v2 continues to decode.
    var adviceID: UUID?
    var disposition: String?
    var confidence: String?
    var followUpAt: Date?
    var sources: [BotanistSource]?
    var verification: String?
    var recordedOutcome: BotanistOutcome?
    /// Bounded structured observations returned by the photo-capable responder.
    /// The raw image remains in the protected file above; this compact evidence
    /// makes the transcript auditable and survives older photos being removed.
    var visualEvidence: String?
    var provider: String?
    var model: String?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = .now,
        photoURL: URL? = nil,
        adviceID: UUID? = nil,
        disposition: String? = nil,
        confidence: String? = nil,
        followUpAt: Date? = nil,
        sources: [BotanistSource]? = nil,
        verification: String? = nil,
        recordedOutcome: BotanistOutcome? = nil,
        visualEvidence: String? = nil,
        provider: String? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.photoURL = photoURL
        self.adviceID = adviceID
        self.disposition = disposition
        self.confidence = confidence
        self.followUpAt = followUpAt
        self.sources = sources
        self.verification = verification
        self.recordedOutcome = recordedOutcome
        self.visualEvidence = visualEvidence
        self.provider = provider
        self.model = model
    }
}

/// A conversation, optionally scoped to one owned plant. A thread scoped to a
/// plant is answered with that plant's living record attached, which is the
/// whole reason to ask Grove rather than a search engine.
struct BotanistThread: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    /// The plant this conversation is about, or nil for the whole grove.
    var plantID: UUID?
    var messages: [BotanistMessage]
    var updatedAt: Date

    init(id: UUID = UUID(), plantID: UUID? = nil, messages: [BotanistMessage] = [], updatedAt: Date = .now) {
        self.id = id
        self.plantID = plantID
        self.messages = messages
        self.updatedAt = updatedAt
    }

    /// The opening question, used as the thread's title in the recents list.
    var title: String {
        messages.first { $0.role == .user }?.text ?? "New question"
    }

    var lastAnswer: String? {
        messages.last { $0.role == .botanist }?.text
    }
}

// MARK: - Client

enum BotanistClientPolicyError: Error {
    case premiumRequired
}

@MainActor
protocol BotanistClient {
    /// Answers the conversation's final user turn. `plantContext` is untrusted
    /// grounding data, never instructions — the server prompt says so too.
    func ask(
        conversation: [BotanistMessage],
        plantContext: String?,
        plantID: UUID?,
        threadID: UUID,
        photoAttachments: [BotanistPhotoAttachment],
        safetyOnly: Bool
    ) async throws -> BotanistAnswer
    func recordOutcome(adviceID: UUID, outcome: BotanistOutcome) async throws
}

extension BotanistClient {
    func ask(
        conversation: [BotanistMessage],
        plantContext: String?,
        plantID: UUID?,
        threadID: UUID,
        photoAttachments: [BotanistPhotoAttachment]
    ) async throws -> BotanistAnswer {
        try await ask(
            conversation: conversation,
            plantContext: plantContext,
            plantID: plantID,
            threadID: threadID,
            photoAttachments: photoAttachments,
            safetyOnly: false
        )
    }
}

private struct BotanistAskRequest: Encodable {
    struct Message: Encodable {
        let id: UUID
        let role: String
        let content: String
    }

    struct PhotoAttachment: Encodable {
        let messageID: UUID
        let mimeType: String
        let base64Data: String
    }

    let conversation: [Message]
    let plantContext: String?
    let plantID: UUID?
    let threadID: UUID
    let requestID: UUID
    let attachments: [PhotoAttachment]
    let safetyOnly: Bool
}

private struct BotanistAskResponse: Decodable {
    let reply: String
    let adviceID: UUID?
    /// Optional during a rolling backend deploy. Botanist v1 returned only
    /// `reply`; requiring v2 review metadata made a perfectly good v1 answer
    /// decode as `APIError.invalidResponse` while the Edge Function and app were
    /// briefly on different versions.
    let disposition: String?
    let confidence: String?
    let followUpAt: Date?
    let sources: [BotanistSource]?
    let verification: String?
    let provider: String?
    let model: String?
    let usedPhotoMessageIDs: [UUID]?
    let visualEvidence: String?
    let quota: BotanistAskQuota?
}

private struct BotanistOutcomeRequest: Encodable {
    let outcome: BotanistOutcome
}

@MainActor
final class HTTPBotanistClient: BotanistClient {
    /// The turns sent up. The provider trims its own history too; this keeps an
    /// old thread from growing the request without bound in the first place.
    private static let maxTurnsSent = 12

    /// How long the app waits for one answer.
    ///
    /// Deliberately longer than the gateway's worst sequential provider path: a
    /// photo question can spend up to 48s on Gemini visual triage before the
    /// text coach uses its own bounded answer window. The gateway knows which
    /// stage failed and can say so; the app timing out first can report only a
    /// dropped connection.
    static let askTimeout: TimeInterval = 110

    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func ask(
        conversation: [BotanistMessage],
        plantContext: String?,
        plantID: UUID?,
        threadID: UUID,
        photoAttachments: [BotanistPhotoAttachment],
        safetyOnly: Bool
    ) async throws -> BotanistAnswer {
        // A reused photo can belong to a turn older than the normal history
        // window. Keep that owning message in the wire conversation as well as
        // the recent turns; otherwise the gateway correctly rejects an image
        // whose message id it cannot see. With two bounded attachments this is
        // at most 14 messages, still comfortably below the server's limit.
        let recentStart = max(0, conversation.count - Self.maxTurnsSent)
        let photoMessageIDs = Set(photoAttachments.map(\.messageID))
        let turns = conversation.enumerated().compactMap { index, message -> BotanistAskRequest.Message? in
            guard index >= recentStart || photoMessageIDs.contains(message.id) else { return nil }
            return BotanistAskRequest.Message(
                id: message.id,
                role: message.role == .user ? "user" : "assistant",
                content: message.text
            )
        }
        let response: BotanistAskResponse
        do {
            response = try await client.post(
                "botanist/ask",
                body: BotanistAskRequest(
                    conversation: Array(turns),
                    plantContext: plantContext,
                    plantID: plantID,
                    threadID: threadID,
                    requestID: turns.last?.id ?? threadID,
                    attachments: photoAttachments.map {
                        BotanistAskRequest.PhotoAttachment(
                            messageID: $0.messageID,
                            mimeType: "image/jpeg",
                            base64Data: $0.data.base64EncodedString()
                        )
                    },
                    safetyOnly: safetyOnly
                ),
                timeout: Self.askTimeout
            )
        } catch APIError.server(status: 402, message: _) {
            throw BotanistClientPolicyError.premiumRequired
        }
        let reply = response.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw APIError.invalidResponse }
        return BotanistAnswer(
            reply: reply,
            adviceID: response.adviceID,
            disposition: response.disposition ?? "answer",
            confidence: response.confidence ?? "low",
            followUpAt: response.followUpAt,
            sources: response.sources ?? [],
            verification: response.verification ?? "legacy",
            provider: response.provider,
            model: response.model,
            usedPhotoMessageIDs: response.usedPhotoMessageIDs ?? [],
            visualEvidence: response.visualEvidence,
            quota: response.quota
        )
    }

    func recordOutcome(adviceID: UUID, outcome: BotanistOutcome) async throws {
        let _: EmptyAPIResponse = try await client.post(
            "botanist/advice/\(adviceID.uuidString)/outcome",
            body: BotanistOutcomeRequest(outcome: outcome)
        )
    }
}

/// Offline / test stand-in. Deliberately unhelpful about specifics rather than
/// inventing horticulture: a fixture that guessed at plant advice would be
/// indistinguishable from the real coach in a screenshot and wrong in the field.
///
/// It does, however, imitate the real coach's *shape* — headers, bold, bullets,
/// a blockquote. The previous fixture returned clean prose, so every preview and
/// simulator run looked perfect while production shipped raw markdown to the
/// screen for weeks. A stand-in that is tidier than the thing it stands in for
/// hides exactly the bug it should surface.
@MainActor
struct LocalBotanistClient: BotanistClient {
    func ask(
        conversation: [BotanistMessage],
        plantContext: String?,
        plantID: UUID?,
        threadID: UUID,
        photoAttachments: [BotanistPhotoAttachment],
        safetyOnly: Bool
    ) async throws -> BotanistAnswer {
        guard !safetyOnly else { throw BotanistClientPolicyError.premiumRequired }
        try? await Task.sleep(for: .milliseconds(400))
        return BotanistAnswer(
            reply: """
            ### While Ari is offline

            **This is a stand-in, so take none of it as advice about your plant.**

            Ari's real answer needs a connection. In the meantime, the three habits \
            that hold for almost every houseplant:

            1. Check the soil before watering, not the calendar.
            2. Look under the leaves. Pests announce themselves there first.
            3. Note what you see on the plant's record.

            > That history is what makes the real answer worth waiting for.
            """,
            adviceID: nil,
            disposition: "clarify",
            confidence: "low",
            followUpAt: nil,
            sources: [],
            verification: "offline",
            provider: "local",
            model: nil,
            usedPhotoMessageIDs: photoAttachments.map(\.messageID),
            visualEvidence: nil,
            // No gateway answered, so there is no server count to reconcile
            // against. The offline stand-in must not appear to grant or spend an
            // allowance it has no authority over.
            quota: nil
        )
    }

    func recordOutcome(adviceID: UUID, outcome: BotanistOutcome) async throws {}
}

// MARK: - Grounding

/// Builds the untrusted context block sent alongside a question.
///
/// Kept as plain text rather than JSON on purpose: the model reads it as notes
/// from a record, and a person reading the logs can see exactly what was shared
/// about a user's plant.
enum BotanistContext {
    /// Observations included per plant. Three is enough to show a direction of
    /// travel without turning the prompt into a data dump.
    private static let recentObservationLimit = 3

    static func text(
        plant: Plant,
        observations: [PlantObservation],
        tasks: [CareTask],
        profile: UserProfile,
        diagnoses: [PlantDiagnosis] = [],
        activity: [ActivityEvent] = [],
        sky: GroveForecast? = nil,
        now: Date = .now
    ) -> String {
        var lines: [String] = []
        lines.append("The user is asking about one plant they own.")
        lines.append("Nickname: \(plant.nickname)")
        lines.append("Species: \(plant.species)\(plant.scientificName.isEmpty ? "" : " (\(plant.scientificName))")")
        if !plant.location.isEmpty { lines.append("Where it lives: \(plant.location)") }
        // The room name is not the light. Without this the coach has to ask
        // where the plant stands before it can explain anything about light,
        // and the commonest true answer — "that spot is darker than it looks" —
        // is out of reach on the first reply.
        if let placement = plant.effectiveLightPlacement {
            lines.append(
                "Light position: \(placement.title.lowercased())"
                + (plant.lightPlacement == nil ? " (inferred from the location name, not confirmed by the user)" : "")
            )
        } else {
            lines.append("Light position: not recorded. Ask where it stands relative to a window before diagnosing anything light-related.")
        }
        // What the scan read off the pot, and what Grove makes of it.
        //
        // The coach could see that soil was "wet" at three consecutive
        // check-ins and had no way to reach the one fact that explains it —
        // that the plant stands in a cachepot. The pot facts were collected on
        // every scan and never reached this prompt, so the commonest correct
        // answer in houseplant care was the one answer Ari could not give.
        lines.append(contentsOf: soilLines(plant: plant, observations: observations, tasks: tasks, now: now))

        lines.append(
            "Health: \(plant.healthBand.title), score \(plant.healthScore)/100, "
            + "trend \(plant.trend.title), assessment confidence \(plant.confidence)%"
        )
        lines.append(contentsOf: indicatorLines(plant: plant, now: now))
        if !plant.summary.isEmpty { lines.append("Latest assessment: \(plant.summary)") }
        if !plant.concerns.isEmpty { lines.append("Current concerns: \(plant.concerns.joined(separator: "; "))") }
        if !plant.positiveSigns.isEmpty { lines.append("Going well: \(plant.positiveSigns.joined(separator: "; "))") }
        if !plant.nextActions.isEmpty { lines.append("Plan already suggested: \(plant.nextActions.joined(separator: "; "))") }

        if let diagnosis = diagnoses
            .filter({ $0.plantID == plant.id })
            .max(by: { $0.createdAt < $1.createdAt }) {
            lines.append(
                "Latest Gemini photo scan (\(daysAgo(diagnosis.createdAt, from: now)), "
                + "\(diagnosis.confidence)% confidence): \(diagnosis.summary)"
            )
            if let providerName = diagnosis.providerName {
                lines.append("Scan engine: \(providerName).")
            }
            if let identificationConfidence = diagnosis.identificationConfidence {
                let confirmation = diagnosis.identificationRequiresConfirmation == true
                    ? ", species confirmation still required"
                    : ""
                lines.append("Gemini identification confidence: \(identificationConfidence)%\(confirmation).")
            }
            if let positiveSigns = diagnosis.visiblePositiveSigns, !positiveSigns.isEmpty {
                lines.append("Gemini-visible positive signs: " + positiveSigns.prefix(4).joined(separator: "; "))
            }
            if let concerns = diagnosis.visibleConcerns, !concerns.isEmpty {
                lines.append("Gemini-visible concerns: " + concerns.prefix(4).joined(separator: "; "))
            }
            if !diagnosis.possibleConditions.isEmpty {
                let possibilities = diagnosis.possibleConditions
                    .sorted { $0.confidence > $1.confidence }
                    .prefix(3)
                    .map { candidate in
                        let evidence = candidate.evidence.prefix(2).joined(separator: ", ")
                        return "\(candidate.name) (\(candidate.confidence)%, not confirmed"
                            + (evidence.isEmpty ? ")" : "; visible evidence: \(evidence))")
                    }
                lines.append("Gemini photo-based possibilities: " + possibilities.joined(separator: "; "))
            }
            if !diagnosis.actionsToAvoid.isEmpty {
                lines.append("Actions the latest diagnosis says to avoid: " + diagnosis.actionsToAvoid.prefix(4).joined(separator: "; "))
            }
            if let questions = diagnosis.clarifyingQuestions, !questions.isEmpty {
                lines.append(
                    "Useful missing observations from Gemini: "
                    + questions.prefix(3).map(\.prompt).joined(separator: "; ")
                )
            }
            if let limitations = diagnosis.limitations, !limitations.isEmpty {
                lines.append("Gemini scan limitations: " + limitations.prefix(3).joined(separator: "; "))
            }
        }

        let days = plant.daysUntilCheckIn
        lines.append(days < 0
            ? "Next check-in: overdue by \(-days) day\(-days == 1 ? "" : "s")"
            : "Next check-in: in \(days) day\(days == 1 ? "" : "s")")

        let recent = Array(observations
            .filter { $0.plantID == plant.id }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(recentObservationLimit))
        if !recent.isEmpty {
            lines.append("Recent check-ins, newest first:")
            for observation in recent {
                var parts = [
                    "\(daysAgo(observation.createdAt, from: now)): looked \(observation.appearance.title.lowercased())"
                ]
                // A soil answer the owner skipped is a stored default, not a fact.
                if let soil = observation.answeredSoilMoisture {
                    parts.append("soil \(soil.title.lowercased())")
                }
                parts.append("score \(observation.score)")
                if observation.hasNewGrowth { parts.append("new growth") }
                if !observation.note.isEmpty { parts.append("note: \(observation.note)") }
                lines.append("- " + parts.joined(separator: ", "))
            }
            if recent.count >= 2, let newest = recent.first, let oldest = recent.last {
                let delta = newest.score - oldest.score
                let direction = delta > 0 ? "up" : delta < 0 ? "down" : "unchanged"
                lines.append(
                    "Across these check-ins: score \(direction)"
                    + (delta == 0 ? "." : " \(abs(delta)) points.")
                )
                let newestWetRun = recent.prefix { $0.answeredSoilMoisture == .wet }.count
                if newestWetRun >= 2 {
                    lines.append("Soil was wet at the \(newestWetRun) newest consecutive check-ins.")
                }
            }
        }

        let recentCare = activity
            .filter { $0.plantID == plant.id && isCompletedCareEvent($0) }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(5)
        if !recentCare.isEmpty {
            lines.append("Recent completed care, newest first:")
            for event in recentCare {
                lines.append(
                    "- \(daysAgo(event.timestamp, from: now)): \(event.actorName) \(event.message)"
                )
            }
        }

        let open = tasks
            .filter { $0.plantID == plant.id && !$0.isCompleted }
            .sorted { $0.dueDate < $1.dueDate }
            .prefix(4)
        if !open.isEmpty {
            lines.append("Care due: " + open.map { "\($0.kind.title) (\(dueDescription($0.dueDate, from: now)))" }.joined(separator: "; "))
        }

        lines.append(contentsOf: householdLines(profile: profile))
        lines.append(contentsOf: skyLines(profile: profile, plants: [plant], sky: sky))
        return lines.joined(separator: "\n")
    }

    /// The pot, the soil surface, and Grove's own moisture estimate.
    ///
    /// Every number here is labelled as an estimate, because the coach will
    /// quote it back to the user as though it were a measurement otherwise.
    /// The dry-down figure in particular is six enumerated facts multiplied
    /// together, and saying so is what stops "water in 9 days" becoming a
    /// promise Grove cannot keep.
    private static func soilLines(
        plant: Plant,
        observations: [PlantObservation],
        tasks: [CareTask],
        now: Date
    ) -> [String] {
        var lines: [String] = []

        if let conditions = plant.growingConditions, !conditions.isEmpty {
            var facts: [String] = []
            if let pot = conditions.potPhrase { facts.append("pot \(pot.lowercased())") }
            switch conditions.drainage {
            case .cachepot: facts.append("stands inside a cover or basket, so water cannot leave the growing pot")
            case .noHoles: facts.append("no drainage holes")
            case .drains: facts.append("drains freely")
            case .unknown: break
            }
            if let substrate = substratePhrase(conditions.substrate) { facts.append(substrate) }
            switch conditions.potFit {
            case .oversized: facts.append("pot is larger than the rootball needs")
            case .snug: facts.append("roots fill the pot")
            case .balanced, .unknown: break
            }
            if !conditions.surfaceSigns.isEmpty {
                facts.append("on the surface: " + conditions.surfaceSigns.map { $0.phrase.lowercased() }.joined(separator: ", "))
            }
            if !facts.isEmpty {
                let seen = conditions.capturedAt.map { " Read from a photo \(daysAgo($0, from: now))." } ?? ""
                lines.append(
                    "Pot and growing conditions (read from the scan photo, \(conditions.confidence)% of the pot visible): "
                    + facts.joined(separator: "; ") + "."
                    + seen
                )
            }
        } else {
            lines.append("Pot and growing conditions: never scanned. Grove does not know the pot, its drainage or its substrate, so any watering interval it offers is a species average rather than a read of this plant.")
        }

        let read = SoilMoistureRead(plant: plant, observations: observations, tasks: tasks, now: now)
        lines.append("Soil moisture estimate (calculated, never measured): \(read.zone.name.lowercased()), and Grove rates it \(read.confidencePhrase).")
        lines.append("What that estimate rests on: \(read.evidenceReason.text).")
        lines.append(
            "Estimated dry-down for this pot in this spot: about \(Int(read.dryDown.days.rounded())) days from a thorough watering to ready for the next one"
            + (read.dryDown.unknownInputs > 0 ? ", with \(read.dryDown.unknownInputs) of the four pot inputs unresolved" : "")
            + "."
        )
        switch read.verdict {
        case .ready:
            lines.append("Grove's watering verdict: dry enough to water, but the user should still feel the soil first.")
        case .holding:
            lines.append("Grove's watering verdict: still holding water. Watering now is the mistake."
                + (read.daysUntilReady.map { " Expected ready in about \($0) day\($0 == 1 ? "" : "s")." } ?? ""))
        case .unclear:
            lines.append("Grove's watering verdict: the estimate straddles the watering line, so Grove will not call it. Ask the user to feel the soil.")
        case .noReading:
            lines.append("Grove's watering verdict: no soil reading has ever been recorded for this plant.")
        }
        if read.needsWeightCheck {
            lines.append("A fingertip will not settle this pot. It is large or top-dressed. Lifting the pot to judge its weight is the better check.")
        }
        return lines
    }

    private static func substratePhrase(_ substrate: PlantGrowingConditions.Substrate) -> String? {
        switch substrate {
        case .gritty: "gritty, free-draining mix"
        case .standard: "standard potting mix"
        case .dense: "dense, water-retentive mix"
        case .bark: "bark or orchid mix"
        case .moss: "sphagnum moss"
        case .semiHydro: "semi-hydro (LECA or similar)"
        case .unknown: nil
        }
    }

    /// The six stored signals, each with how it was grounded.
    ///
    /// Without these the coach saw one health score and had to infer which of
    /// its parts was dragging. The evidence level travels with every line, so
    /// "posture: watch" cannot be quoted as an observation when it was an
    /// estimate.
    private static func indicatorLines(plant: Plant, now: Date) -> [String] {
        let readings = (plant.healthIndicatorReadings ?? [])
            .filter { $0.measuredAt <= now && $0.evidenceLevel != .unavailable }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
        guard !readings.isEmpty else { return [] }

        var lines = ["Stored signal readings from the latest assessment:"]
        for reading in readings {
            var parts = ["\(reading.kind.rawValue): \(reading.status.lowercased())"]
            if let score = reading.score { parts.append("\(score)/100") }
            parts.append(groundingPhrase(reading.evidenceLevel))
            parts.append(daysAgo(reading.measuredAt, from: now))
            lines.append("- " + parts.joined(separator: ", "))
        }
        return lines
    }

    private static func groundingPhrase(_ level: PlantHealthIndicatorEvidenceLevel) -> String {
        switch level {
        case .measured: "measured"
        case .observed: "observed"
        case .estimated: "estimated, not measured"
        case .unavailable: "unavailable"
        }
    }

    /// Activity also contains social and milestone events. Only actions that
    /// could explain a plant's response belong in the botanist evidence pack.
    private static func isCompletedCareEvent(_ event: ActivityEvent) -> Bool {
        let message = event.message.lowercased()
        let careTerms = ["watering", "soil check", "treatment", "pruning", "rotation", "skipped watering"]
        let recordsAction = message.hasPrefix("logged ")
            || message.hasPrefix("completed ")
            || event.kind == .sitterCare
        return recordsAction && careTerms.contains(where: message.contains)
    }

    /// Context for a question about the grove as a whole rather than one plant.
    static func text(
        plants: [Plant],
        profile: UserProfile,
        observations: [PlantObservation] = [],
        tasks: [CareTask] = [],
        sky: GroveForecast? = nil,
        now: Date = .now
    ) -> String {
        var lines: [String] = []
        if plants.isEmpty {
            lines.append("The user has no plants in their Grove yet, so keep advice general and beginner-friendly.")
        } else {
            lines.append("The user is asking about their grove as a whole. They own \(plants.count) plant\(plants.count == 1 ? "" : "s"):")
            for plant in plants.prefix(12) {
                var line = "- \(plant.nickname) (\(plant.species)): \(plant.healthBand.title), trend \(plant.trend.title)"
                if !plant.location.isEmpty { line += ", in \(plant.location)" }
                if let placement = plant.effectiveLightPlacement { line += ", \(placement.title.lowercased())" }
                if !plant.concerns.isEmpty { line += ". Concerns: \(plant.concerns.prefix(2).joined(separator: "; "))" }
                if let latest = observations
                    .filter({ $0.plantID == plant.id })
                    .max(by: { $0.createdAt < $1.createdAt }) {
                    line += ". Last check-in \(daysAgo(latest.createdAt, from: now)): "
                        + (latest.answeredSoilMoisture.map { "soil \($0.title.lowercased()), " } ?? "")
                        + "score \(latest.score)"
                }
                lines.append(line)
            }
            if plants.count > 12 { lines.append("- …and \(plants.count - 12) more") }

            let open = tasks
                .filter { !$0.isCompleted }
                .sorted { $0.dueDate < $1.dueDate }
                .prefix(12)
            if !open.isEmpty {
                lines.append("Care due across the grove:")
                for task in open {
                    let name = plants.first(where: { $0.id == task.plantID })?.nickname ?? "Unknown plant"
                    lines.append("- \(name): \(task.kind.title) (\(dueDescription(task.dueDate, from: now)))")
                }
            }
        }
        lines.append(contentsOf: householdLines(profile: profile))
        lines.append(contentsOf: skyLines(profile: profile, plants: plants, sky: sky))
        return lines.joined(separator: "\n")
    }

    /// The sky the grove has actually had. "Why has it stopped pushing leaves"
    /// is very often answered by a fortnight of grey that nobody noticed a day
    /// at a time, and without this the coach cannot reach that answer at all.
    ///
    /// Stated as *outdoor* light on purpose, with the caveat spelled out. This
    /// is what the location received, not what landed on a plant three metres
    /// from a north window — a coach that conflates the two will confidently
    /// explain a windowsill it cannot see.
    private static func skyLines(profile: UserProfile, plants: [Plant], sky: GroveForecast?) -> [String] {
        guard let sky else { return [] }
        let sunlight = sky.sunlight
        var lines: [String] = []
        let place = profile.location?.label ?? "their location"

        if !sunlight.isEmpty {
            let total = sunlight.reduce(0) { $0 + $1.fullSunHours }
            let average = total / Double(sunlight.count)
            // Full-strength-sun hours, from measured shortwave radiation. The
            // forecast model's own `sunshine_duration` used to fill this slot
            // and was quietly reporting six hours of sun on days with ten
            // millimetres of rain, which made every light-based conclusion the
            // coach drew from it worthless.
            var headline = "Outdoor light at \(place), last \(sunlight.count) days: "
                + "\(duration(average)) of full-strength sun a day"
            let cloudReadings = sunlight.compactMap(\.cloudCover)
            if !cloudReadings.isEmpty {
                let cloud = cloudReadings.reduce(0, +) / Double(cloudReadings.count)
                headline += ", mean cloud cover \(Int(cloud.rounded()))%"
            }
            lines.append(headline + ".")

            // The unit growers actually reason in, so the coach can compare a
            // spot against a species requirement instead of hand-waving.
            let outdoorDLI = sunlight.reduce(0) { $0 + $1.lightIntegral } / Double(sunlight.count)
            lines.append(
                "That is about \(Int(outdoorDLI.rounded())) mol/m²/day outdoors (DLI). "
                + "A windowsill receives roughly half of it, a step or two into the room a fifth, "
                + "and a spot with no direct sun about a twentieth, so a bright-looking room can still "
                + "sit below the 2–6 mol/m²/day that low-light foliage needs to hold condition."
            )

            // Day length is the season, stated without guessing at a hemisphere.
            if let latest = sunlight.last, latest.daylightHours > 0 {
                lines.append("Day length there is now \(duration(latest.daylightHours)).")
            }
        }

        // Indoor air, which nobody measures and which explains most winter
        // leaf-edge browning.
        let humidityEstimates = sky.days.prefix(5).compactMap { GroveSky.indoorHumidity(for: $0) }
        if humidityEstimates.count >= 3 {
            let mean = humidityEstimates.reduce(0, +) / Double(humidityEstimates.count)
            lines.append(
                "Estimated indoor relative humidity this week: about \(Int(mean.rounded()))%, "
                + "derived from the outdoor dew point for a ventilated home held near 20°C."
            )
        }

        // The coming nights, because a cold pane is the one way the strip's own
        // temperatures reach a plant that never goes outside.
        if let coldest = sky.days.dropFirst().prefix(4).min(by: { $0.lowCelsius < $1.lowCelsius }) {
            lines.append("Coldest night in the next few days: \(Int(coldest.lowCelsius.rounded()))°C outside.")
        }

        // Everything the app itself has concluded, so the coach and the Today
        // card cannot contradict each other in the same session.
        let advisories = GroveSky.advisories(forecast: sky, plants: plants, profile: profile)
        if !advisories.isEmpty {
            lines.append("What Grove has already told them about the sky, in the app:")
            for advisory in advisories.prefix(3) {
                lines.append("- \(advisory.headline)\(advisory.detail.map { " \($0)" } ?? "")")
            }
        }

        lines.append(
            "All of the above is ambient outdoor weather, not a measurement taken at any one plant. "
            + "Use it for season, recent conditions and indoor air; where a plant's own light position is "
            + "recorded above, reason from that, and where it is not, ask before blaming the spot."
        )
        return lines
    }

    /// "6h", "6h 15m" — an amount of afternoon, not a decimal measurement.
    private static func duration(_ value: Double) -> String {
        let whole = Int(value)
        let minutes = Int((value - Double(whole)) * 60)
        return minutes == 0 ? "\(whole)h" : "\(whole)h \(minutes)m"
    }

    /// Region matters for species, seasons and available treatments; the plan
    /// tells the coach how much hand-holding to give.
    private static func householdLines(profile: UserProfile) -> [String] {
        var lines: [String] = []
        if let region = profile.regionCode {
            lines.append("User region: \(region) (season and available products differ by region)")
        }
        lines.append("Units: \((profile.usesMetricSystem ?? true) ? "metric" : "imperial")")
        // The catalogue title, not the stored id: "Total beginner" tells the
        // coach how much to explain, "new" tells it nothing.
        if let experience = GrovePlanCatalog.title(for: profile.plan?.experience, in: GrovePlanCatalog.experience) {
            lines.append("Self-described experience: \(experience)")
        }
        if let environment = GrovePlanCatalog.title(for: profile.plan?.environment, in: GrovePlanCatalog.environment) {
            lines.append("Growing environment: \(environment)")
        }
        return lines
    }

    private static func daysAgo(_ date: Date, from now: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        default: return "\(days) days ago"
        }
    }

    private static func dueDescription(_ date: Date, from now: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch days {
        case ..<0: return "overdue by \(-days) day\(-days == 1 ? "" : "s")"
        case 0: return "today"
        case 1: return "tomorrow"
        default: return "in \(days) days"
        }
    }
}
