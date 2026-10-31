import Foundation
import Observation
import UIKit

/// What went wrong, in terms of what the user can do about it.
///
/// A failure screen is only useful if its buttons can succeed. Grove used to
/// offer "Try again" for every failure, including the two that can never
/// change outcome on a second tap — a photo the quality gate rejected, and a
/// daily ceiling that resets tomorrow.
enum ScanFailureKind: Equatable {
    /// Nothing left the phone. Same photo, once there's a connection.
    case connection
    /// Grove's side of the wire. Same photo, in a moment.
    case service
    /// This photo can't be read. Only a different photo helps.
    case photo
    /// The account's scan ceiling. Nothing to tap until tomorrow.
    case limit

    var isRetryable: Bool { self == .connection || self == .service }
}

enum ScanProcessingState: Equatable {
    case idle
    case saving
    case ready
    case analysing
    case completed
    case failed(message: String, kind: ScanFailureKind)

    static func failure(for error: Error) -> ScanProcessingState {
        .failed(message: error.localizedDescription, kind: ScanFailureKind(error))
    }
}

extension ScanFailureKind {
    init(_ error: Error) {
        switch error {
        case let analysis as PlantAnalysisError:
            switch analysis {
            case .offline: self = .connection
            case .atDailyLimit: self = .limit
            case .invalidImage, .imageTooSmall: self = .photo
            case .unavailable, .malformedResponse, .reported: self = .service
            }
        case let api as APIError:
            switch api {
            case .offline: self = .connection
            case .rateLimited: self = .limit
            default: self = .service
            }
        case is ScanMediaError:
            self = .photo
        default:
            self = .service
        }
    }
}

@MainActor
@Observable
final class ScanSession {
    var scanID = UUID()
    /// Provider-job identity is normally the scan identity, but can roll
    /// forward independently when a completed job has an undecodable result.
    /// Retrying that same durable job would return the same bad payload forever.
    private var analysisRequestID = UUID()
    var captures: [ScanMediaDraft] = []
    var draft: ScanMediaDraft?
    var imageData: Data?
    /// A decoded copy of the primary photo for the animated analysis/result
    /// hero. Keeping it here prevents SwiftUI from decoding the JPEG again
    /// whenever the progress state advances.
    var previewImage: UIImage?
    var result: PlantAnalysisResult?
    var state: ScanProcessingState = .idle
    var existingPlantID: UUID?
    /// Chosen option per question id, for the questions on the live result.
    var answers: [String: String] = [:]
    /// What the owner answered on the round that produced the current result.
    /// Empty until a refine lands, and cleared again by any fresh analysis.
    var appliedObservations: [DiagnosisObservation] = []
    var captureErrorMessage: String?
    private(set) var archivedPrimaryURL: URL?

    private var mediaStore: ScanMediaStore
    private let analysisClient: any PlantAnalysisClient
    private let speciesSearchClient: any PlantSpeciesSearchClient
    private let storage: UserDefaults
    /// Capture persistence is explicitly scoped. Signed-out onboarding must
    /// never inherit the previous signed-in account's draft just because this
    /// app-wide session object outlives a sign-out.
    private enum StorageScope: Equatable {
        case onboarding
        case account(String)

        var persistenceKey: String {
            switch self {
            case .onboarding:
                "grove.scan.draft.v2.onboarding"
            case .account(let accountID):
                "grove.scan.draft.v2.\(accountID)"
            }
        }
    }

    private var activeScope: StorageScope?
    /// Invalidates actor-reentrant capture work as soon as the account scope
    /// changes. Without this, a save started for account A could return from
    /// disk after activation of account B and append A's photo to B's session.
    private var scopeGeneration = UUID()
    private var captureAttemptID: UUID?
    /// Owned by the session rather than `ScanResultView`.
    ///
    /// SwiftUI cancels a view's `.task` when the app backgrounds or the
    /// navigation layer is temporarily removed. Analysis is resumable work on
    /// a protected draft, so its lifetime must follow the draft instead of the
    /// pixels currently presenting it.
    private var analysisTask: Task<Void, Never>?
    private var analysisAttemptID: UUID?

    init(
        mediaStore: ScanMediaStore = ScanMediaStore(),
        analysisClient: (any PlantAnalysisClient)? = nil,
        speciesSearchClient: (any PlantSpeciesSearchClient)? = nil,
        storage: UserDefaults = .standard
    ) {
        self.mediaStore = mediaStore
        // Main-actor protocol implementations cannot be constructed in a
        // default-argument expression, because Swift evaluates defaults in the
        // caller's isolation. Resolve nil inside this main-actor initializer.
        self.analysisClient = analysisClient ?? LocalPlantAnalysisClient()
        self.speciesSearchClient = speciesSearchClient ?? LocalPlantSpeciesSearchClient()
        self.storage = storage
    }

    var mode: ScanMode? { draft?.mode }

    /// The scan the user can still pick up, if there is one.
    ///
    /// A failed analysis tells people their photo is kept — that was only true
    /// for `add`, so an identification or diagnosis that fell over left a photo
    /// on disk with no way back to it. Any mode with a capture and no reading
    /// is resumable; `add` stays resumable after the reading too, because there
    /// the unfinished part is the plant form.
    var resumableDraftMode: ScanMode? {
        guard let mode, !captures.isEmpty else { return nil }
        if mode == .add { return .add }
        return result == nil ? mode : nil
    }

    /// A diagnosis draft with only its establishing whole-plant view must
    /// resume at the symptom shutter, not jump ahead and analyse incomplete
    /// evidence through the generic result-route affordance.
    var requiredAdditionalCaptureStage: ScanCaptureStage? {
        guard mode == .diagnose,
              capture(for: .wholePlant) != nil,
              capture(for: .symptom) == nil else { return nil }
        return .symptom
    }

    func capture(for stage: ScanCaptureStage) -> ScanMediaDraft? {
        captures.first { ($0.stage ?? .wholePlant) == stage }
    }

    func activate(accountID: String) async {
        await activate(
            scope: .account(accountID),
            rootURL: AccountStorage.mediaRootURL(for: accountID)
                .appendingPathComponent("ScanDrafts", isDirectory: true)
        )
    }

    /// Gives pre-account capture a neutral, protected namespace with its own
    /// durable request id. This closes both sides of an account switch: a guest
    /// cannot read or delete the previous account's draft, and a killed first
    /// scan can resume without spending a second guest allowance.
    func activateForOnboarding(rootURL: URL? = nil) async {
        await activate(
            scope: .onboarding,
            rootURL: rootURL ?? Self.onboardingMediaRootURL
        )
    }

    private func activate(scope: StorageScope, rootURL: URL) async {
        guard activeScope != scope else { return }
        cancelActiveAnalysis()
        captureAttemptID = nil
        let activationID = UUID()
        scopeGeneration = activationID
        activeScope = scope
        let scopedMediaStore = ScanMediaStore(rootURL: rootURL)
        mediaStore = scopedMediaStore
        resetInMemory()
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        await scopedMediaStore.removeExpiredDrafts(olderThan: cutoff)
        guard scopeGeneration == activationID, activeScope == scope else { return }
        await restoreDraft(from: scopedMediaStore, activationID: activationID)
    }

    func begin(mode: ScanMode, existingPlantID: UUID? = nil) async {
        let expectedGeneration = scopeGeneration
        if state == .completed {
            _ = await archivePrimaryForHistory()
            guard scopeGeneration == expectedGeneration else { return }
            finishKeepingMedia()
        }
        if self.mode != mode || self.existingPlantID != existingPlantID {
            await discard()
            guard scopeGeneration == expectedGeneration else { return }
            scanID = UUID()
            analysisRequestID = scanID
        }
        self.existingPlantID = existingPlantID
        persistDraft()
    }

    func save(image: UIImage, mode: ScanMode, stage: ScanCaptureStage? = nil) async {
        // Retaking from the result screen starts a new attempt against new
        // evidence. The old request may still be polling in the background;
        // cancel and invalidate it before it can publish a stale result.
        cancelActiveAnalysis()
        let startingGeneration = scopeGeneration
        if self.mode != nil && self.mode != mode {
            await discard()
            guard scopeGeneration == startingGeneration else { return }
        }
        let attemptID = UUID()
        captureAttemptID = attemptID
        let expectedGeneration = scopeGeneration
        let expectedScanID = scanID
        let targetMediaStore = mediaStore
        state = .saving
        result = nil
        archivedPrimaryURL = nil
        captureErrorMessage = nil
        let captureStage = stage ?? .wholePlant
        let dimensionPreparedImage = image.preparedForPlantAnalysis()
        let preparedPixelWidth = Int(dimensionPreparedImage.size.width * dimensionPreparedImage.scale)
        let preparedPixelHeight = Int(dimensionPreparedImage.size.height * dimensionPreparedImage.scale)
        guard preparedPixelWidth >= 500, preparedPixelHeight >= 500 else {
            let message = ScanMediaError.imageTooSmall.localizedDescription
            captureAttemptID = nil
            captureErrorMessage = message
            state = capture(for: captureStage) == nil ? .failed(message: message, kind: .photo) : .ready
            return
        }
        let qualityReport = ScanImageQualityAnalyzer.assess(dimensionPreparedImage)

        if let blockingMessage = qualityReport.blockingMessage {
            captureAttemptID = nil
            captureErrorMessage = blockingMessage
            state = capture(for: captureStage) == nil ? .failed(message: blockingMessage, kind: .photo) : .ready
            return
        }

        guard let payload = dimensionPreparedImage.boundedPlantAnalysisJPEG() else {
            let message = ScanMediaError.invalidImage.localizedDescription
            captureAttemptID = nil
            captureErrorMessage = message
            state = capture(for: captureStage) == nil ? .failed(message: message, kind: .photo) : .ready
            return
        }

        var newlySaved: ScanMediaDraft?
        do {
            let old = capture(for: captureStage)
            let saved = try await targetMediaStore.save(
                imageData: payload.data,
                mode: mode,
                pixelWidth: Int(payload.image.size.width * payload.image.scale),
                pixelHeight: Int(payload.image.size.height * payload.image.scale),
                stage: captureStage,
                qualityWarnings: qualityReport.warnings
            )
            newlySaved = saved
            guard captureAttemptID == attemptID,
                  scopeGeneration == expectedGeneration,
                  scanID == expectedScanID else {
                await targetMediaStore.delete(saved)
                return
            }

            var updatedCaptures = captures.filter { ($0.stage ?? .wholePlant) != captureStage }
            updatedCaptures.append(saved)
            let primary = updatedCaptures.first(where: { ($0.stage ?? .wholePlant) == .wholePlant }) ?? saved
            let primaryData: Data
            let primaryPreview: UIImage?
            if primary.id == saved.id {
                primaryData = payload.data
                primaryPreview = payload.image
            } else {
                primaryData = try await targetMediaStore.load(primary)
                primaryPreview = previewImage ?? UIImage(data: primaryData)
            }
            guard captureAttemptID == attemptID,
                  scopeGeneration == expectedGeneration,
                  scanID == expectedScanID else {
                await targetMediaStore.delete(saved)
                return
            }

            captures = updatedCaptures
            draft = primary
            imageData = primaryData
            previewImage = primaryPreview
            state = .ready
            captureAttemptID = nil
            persistDraft()
            // Commit the replacement before deleting the prior file. A full
            // disk or interrupted write must leave the last good capture usable.
            if let old { await targetMediaStore.delete(old) }
        } catch {
            if let newlySaved { await targetMediaStore.delete(newlySaved) }
            guard captureAttemptID == attemptID,
                  scopeGeneration == expectedGeneration,
                  scanID == expectedScanID else { return }
            captureAttemptID = nil
            captureErrorMessage = error.localizedDescription
            // Saving the frame failed, so there is nothing on disk to re-read:
            // the only move that can succeed is a fresh photo.
            state = capture(for: captureStage) == nil ? .failed(message: error.localizedDescription, kind: .photo) : .ready
        }
    }

    func analyse(regionCode: String? = nil, existingPlant: Plant? = nil) async {
        if let analysisTask {
            await analysisTask.value
            return
        }

        let attemptID = UUID()
        let expectedScanID = scanID
        let expectedRequestID = analysisRequestID
        let expectedGeneration = scopeGeneration
        let targetMediaStore = mediaStore
        analysisAttemptID = attemptID
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performAnalysis(
                regionCode: regionCode,
                existingPlant: existingPlant,
                expectedScanID: expectedScanID,
                expectedRequestID: expectedRequestID,
                expectedGeneration: expectedGeneration,
                targetMediaStore: targetMediaStore,
                attemptID: attemptID
            )
        }
        analysisTask = task
        // Awaiting an unstructured task does not hand ownership to this
        // caller. If ScanResultView disappears and its `.task` is cancelled,
        // the session-owned analysis continues and the restored result screen
        // observes the same attempt.
        await task.value
    }

    private func performAnalysis(
        regionCode: String?,
        existingPlant: Plant?,
        expectedScanID: UUID,
        expectedRequestID: UUID,
        expectedGeneration: UUID,
        targetMediaStore: ScanMediaStore,
        attemptID: UUID
    ) async {
        defer {
            if analysisAttemptID == attemptID {
                analysisTask = nil
                analysisAttemptID = nil
            }
        }
        guard scanID == expectedScanID,
              scopeGeneration == expectedGeneration,
              analysisAttemptID == attemptID else { return }
        guard let draft, !captures.isEmpty else {
            // No draft to analyse: retrying would re-read the same nothing.
            state = .failed(message: ScanMediaError.invalidImage.localizedDescription, kind: .photo)
            return
        }
        state = .analysing
        do {
            var images: [PlantAnalysisImage] = []
            for capture in captures.sorted(by: { stageIndex($0.stage) < stageIndex($1.stage) }) {
                let data = try await targetMediaStore.load(capture)
                // A scan can carry several 2 MB photos. Base64 encoding those
                // on MainActor stalls the first frames of the analysis screen.
                let base64Data = await Task.detached(priority: .userInitiated) {
                    data.base64EncodedString()
                }.value
                try Task.checkCancellation()
                images.append(
                    PlantAnalysisImage(
                        stage: capture.stage ?? .wholePlant,
                        mimeType: "image/jpeg",
                        base64Data: base64Data,
                        qualityWarnings: capture.qualityWarnings?.map(\.rawValue),
                        localMediaID: capture.id,
                        localFileURL: capture.fileURL,
                        pixelWidth: capture.pixelWidth,
                        pixelHeight: capture.pixelHeight
                    )
                )
            }
            try Task.checkCancellation()
            guard scopeGeneration == expectedGeneration else { throw CancellationError() }
            let context = existingPlant.map {
                PlantAnalysisPlantContext(
                    id: $0.id,
                    commonName: Self.boundedContext($0.species, limit: 120, fallback: "Unknown plant"),
                    scientificName: Self.boundedContext($0.scientificName, limit: 160, fallback: "Species unconfirmed"),
                    location: Self.boundedContext($0.location, limit: 120, fallback: "Unspecified"),
                    recentSummary: Self.boundedContext($0.summary, limit: 600, fallback: "No previous summary recorded.")
                )
            }
            // One round of questions, then a verdict. The observations are
            // captured before the await so a result that lands mid-flight
            // cannot change which answers this request is credited with.
            let observations = Array(pendingObservations.prefix(Self.maximumAnswers))
            var completedResult = try await analysisClient.analyse(
                request: PlantAnalysisRequest(
                    clientRequestID: expectedRequestID,
                    mode: draft.mode,
                    images: images,
                    regionCode: Self.boundedOptionalContext(regionCode, limit: 8),
                    existingPlant: context,
                    answers: Self.boundedAnswers(observations)
                )
            )
            guard scanID == expectedScanID,
                  scopeGeneration == expectedGeneration,
                  analysisAttemptID == attemptID else { return }
            if observations.isEmpty {
                appliedObservations = []
            } else {
                // An answered scan concludes. The gateway strips a second round
                // of questions from an answered request; stripping here too
                // means a lagging deployment cannot reopen the loop.
                appliedObservations = observations
                completedResult.condition.questions = []
                answers = [:]
            }
            result = completedResult
            state = .completed
            persistDraft()
        } catch is CancellationError {
            if scanID == expectedScanID,
               scopeGeneration == expectedGeneration,
               analysisAttemptID == attemptID {
                state = .ready
            }
            return
        } catch {
            if scanID == expectedScanID,
               scopeGeneration == expectedGeneration,
               analysisAttemptID == attemptID {
                if let analysisError = error as? PlantAnalysisError,
                   analysisError == .malformedResponse {
                    analysisRequestID = UUID()
                    persistDraft()
                }
                state = .failure(for: error)
            }
        }
    }

    func answer(questionID: String, optionID: String) {
        answers[questionID] = optionID
        persistDraft()
    }

    /// The live result's questions the owner has answered, in question order.
    /// Only questions on the current result count: an answer keyed to a
    /// question from an earlier read means nothing to the model and is dropped.
    var pendingObservations: [DiagnosisObservation] {
        (result?.condition.questions ?? []).compactMap { question in
            guard let optionID = answers[question.id],
                  let option = question.options.first(where: { $0.id == optionID }) else { return nil }
            return DiagnosisObservation(questionID: question.id, question: question.prompt, answer: option.title)
        }
    }

    /// Whether every question on the live result has an answer. The refine is
    /// offered only then: a half-answered round produces a half-informed read
    /// and the owner cannot ask again afterwards.
    var allQuestionsAnswered: Bool {
        let questions = result?.condition.questions ?? []
        return !questions.isEmpty && pendingObservations.count == questions.count
    }

    func searchSpecies(query: String, regionCode: String?) async throws -> [SpeciesCandidate] {
        try await speciesSearchClient.search(query: query, regionCode: regionCode)
    }

    /// The background taxonomy backfill, through the same search client the
    /// manual species picker uses. It lives here because this is where that
    /// client is owned; the rule about what counts as a match is
    /// `PlantTaxonResolver`'s.
    func resolveCanonicalTaxonIDs(for names: [String], regionCode: String?) async -> [String: String] {
        await PlantTaxonResolver.resolve(
            names: names,
            regionCode: regionCode,
            using: speciesSearchClient
        )
    }

    /// Analyses a recurring check-in photo for a plant already in the Grove.
    ///
    /// A check-in is a scan of a plant Grove already knows, so it runs through
    /// the same gateway in `.diagnose` mode with the plant's identity and last
    /// summary as context — that context is what lets the model answer "has
    /// this changed since last time" rather than assessing a stranger.
    ///
    /// Deliberately stateless: it touches none of the capture-draft state, so a
    /// check-in can never disturb an in-flight scan (or be disturbed by one).
    func analyseCheckIn(
        imageData: Data,
        previousImageData: Data? = nil,
        qualityWarnings: [ScanImageQualityWarning] = [],
        plant: Plant,
        regionCode: String?,
        answers: [String: String]
    ) async throws -> PlantAnalysisResult {
        // Two images of up to 2 MB each. Base64 encoding them on MainActor
        // freezes the check-in's comparison screen for exactly as long as it
        // takes — the same stall `performAnalysis` moved off the main thread,
        // on the flow the owner runs every fortnight rather than once.
        let reference = previousImageData.flatMap { $0.isEmpty ? nil : $0 }
        let encoded = await Task.detached(priority: .userInitiated) {
            (reference: reference?.base64EncodedString(), current: imageData.base64EncodedString())
        }.value
        try Task.checkCancellation()

        var images: [PlantAnalysisImage] = []
        if let referenceBase64 = encoded.reference {
            images.append(
                PlantAnalysisImage(
                    stage: .reference,
                    mimeType: "image/jpeg",
                    base64Data: referenceBase64
                )
            )
        }
        images.append(
            PlantAnalysisImage(
                stage: .wholePlant,
                mimeType: "image/jpeg",
                base64Data: encoded.current,
                // Without this the gateway told the model "on-device quality
                // gate found no warning" about a photo nothing had gated, so a
                // dim, soft check-in photo was presented as verified-clean
                // evidence and scored as though it were.
                qualityWarnings: qualityWarnings.isEmpty ? nil : qualityWarnings.map(\.rawValue)
            )
        )
        return try await analysisClient.analyse(
            request: PlantAnalysisRequest(
                clientRequestID: UUID(),
                mode: .diagnose,
                images: images,
                regionCode: Self.boundedOptionalContext(regionCode, limit: 8),
                // The gateway rejects empty or over-long context fields, and a
                // rejected request would silently downgrade every check-in to
                // the offline estimate — bound them here rather than find out
                // in production.
                existingPlant: PlantAnalysisPlantContext(
                    id: plant.id,
                    commonName: Self.boundedContext(plant.species, limit: 120, fallback: "Unknown plant"),
                    scientificName: Self.boundedContext(plant.scientificName, limit: 160, fallback: "Species unconfirmed"),
                    location: Self.boundedContext(plant.location, limit: 120, fallback: "Unspecified"),
                    recentSummary: Self.boundedContext(plant.summary, limit: 600, fallback: "No previous summary recorded.")
                ),
                answers: Self.boundedAnswers(answers)
            )
        )
    }

    private static func boundedContext(_ value: String, limit: Int, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return boundedUTF16(trimmed, limit: limit) ?? fallback
    }

    private static func boundedOptionalContext(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return boundedUTF16(trimmed, limit: limit)
    }

    /// JavaScript's gateway limits count UTF-16 code units (`String.length`),
    /// whereas Swift's `String.count` counts grapheme clusters. Bounding in the
    /// same unit prevents emoji-heavy user text from passing the phone's clamp
    /// and then failing the otherwise identical server contract.
    private static func boundedUTF16(_ value: String, limit: Int) -> String? {
        guard limit > 0 else { return nil }
        var output = ""
        var used = 0
        for character in value {
            let width = String(character).utf16.count
            guard used + width <= limit else { break }
            output.append(character)
            used += width
        }
        return output.isEmpty ? nil : output
    }

    /// The gateway accepts at most three answers per request.
    static let maximumAnswers = 3

    /// Answers for the gateway: keyed by question id so a retry replays as the
    /// same job, valued by what was chosen and what was asked so the model can
    /// actually use them.
    private static func boundedAnswers(_ observations: [DiagnosisObservation]) -> [String: String] {
        var output: [String: String] = [:]
        for observation in observations {
            guard output.count < maximumAnswers,
                  let key = boundedUTF16(observation.questionID.trimmingCharacters(in: .whitespacesAndNewlines), limit: 64),
                  let value = boundedUTF16(observation.gatewayValue, limit: 120),
                  output[key] == nil else { continue }
            output[key] = value
        }
        return output
    }

    private static func boundedAnswers(_ values: [String: String]) -> [String: String] {
        var output: [String: String] = [:]
        for key in values.keys.sorted() {
            guard output.count < maximumAnswers, let value = values[key] else { continue }
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let safeKey = boundedUTF16(trimmedKey, limit: 64),
                  let safeValue = boundedUTF16(trimmedValue, limit: 120),
                  output[safeKey] == nil else { continue }
            output[safeKey] = safeValue
        }
        return output
    }

    func confirmIdentity(_ candidate: SpeciesCandidate) {
        guard var current = result else { return }
        let identityChanged = comparableIdentity(current.identification.scientificName)
            != comparableIdentity(candidate.scientificName)
        current.identification.commonName = candidate.commonName
        current.identification.scientificName = candidate.scientificName
        current.identification.confidence = candidate.confidence
        current.identification.distinguishingTraits = candidate.distinguishingTraits
        current.identification.canonicalTaxonID = candidate.canonicalTaxonID
            ?? (candidate.id.hasPrefix("gbif:") ? candidate.id : nil)
            ?? (identityChanged ? nil : current.identification.canonicalTaxonID)
        current.identification.identityConfirmation = .userConfirmed
        current.identification.isUnknown = false
        current.identification.requiresConfirmation = false
        // Accepting the displayed match resolves identity only. Provisional
        // care can coexist with a useful photo assessment; preserve both.
        if identityChanged {
            // Visible signs survive a correction; species-dependent causes and
            // treatment do not. A user selecting a catalogue name is evidence
            // about identity, not permission to keep advice generated for the
            // previous candidate.
            current.condition.healthScore = 70
            current.condition.healthBand = .monitor
            current.condition.confidence = min(current.condition.confidence, 40)
            current.condition.summary = "Identity selected. Use a fresh photo to establish condition-specific care for \(candidate.commonName)."
            current.condition.possibleCauses = []
            current.condition.nextActions = [
                "Keep routine care steady until a fresh baseline is assessed",
                "Take a clear whole-plant and symptom photo if anything looks wrong"
            ]
            current.condition.possibleConditions = []
            current.condition.questions = []
            current.condition.actionsToAvoid = [
                "Do not use treatment advice from the earlier identity"
            ]
            current.condition.urgentFlags = []
            current.condition.actionability = .provisional
            current.condition.assessmentAvailable = false
        }
        result = current
        persistDraft()
    }

    private func comparableIdentity(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter(\.isLetter)
    }

    func retry(regionCode: String? = nil, existingPlant: Plant? = nil) async {
        await analyse(regionCode: regionCode, existingPlant: existingPlant)
    }

    func archivePrimaryForHistory() async -> URL? {
        if let archivedPrimaryURL { return archivedPrimaryURL }
        guard let draft else { return nil }
        let expectedGeneration = scopeGeneration
        let expectedScanID = scanID
        let targetMediaStore = mediaStore
        do {
            let url = try await targetMediaStore.archive(draft, scanID: expectedScanID)
            guard scopeGeneration == expectedGeneration, scanID == expectedScanID else { return nil }
            archivedPrimaryURL = url
            return url
        } catch {
            return nil
        }
    }

    func discard() async {
        cancelActiveAnalysis()
        captureAttemptID = nil
        let expectedGeneration = scopeGeneration
        let targetMediaStore = mediaStore
        let discardedCaptures = captures
        for capture in discardedCaptures { await targetMediaStore.delete(capture) }
        guard scopeGeneration == expectedGeneration else { return }
        clearPersistedDraft()
        resetInMemory()
    }

    func finishKeepingMedia(ifCurrentScanID expectedScanID: UUID? = nil) {
        if let expectedScanID, scanID != expectedScanID { return }
        cancelActiveAnalysis()
        clearPersistedDraft()
        resetInMemory()
    }

    /// Deletes every capture draft and forgets the account.
    ///
    /// Part of "Delete my Grove data". A draft is a photograph of the user's
    /// home on disk with a `UserDefaults` record pointing at it, and neither
    /// was cleared by the store's wipe — so signing back into the same account
    /// re-opened the half-finished scan the user believed they had deleted.
    func deleteAllLocalData() async {
        let expectedGeneration = scopeGeneration
        await discard()
        guard scopeGeneration == expectedGeneration else { return }
        storage.removeObject(forKey: StorageScope.onboarding.persistenceKey)
        try? FileManager.default.removeItem(at: Self.onboardingMediaRootURL)
        scopeGeneration = UUID()
        activeScope = nil
    }

    private func stageIndex(_ stage: ScanCaptureStage?) -> Int {
        ScanCaptureStage.allCases.firstIndex(of: stage ?? .wholePlant) ?? 0
    }

    private func resetInMemory() {
        scanID = UUID()
        analysisRequestID = scanID
        captures = []
        draft = nil
        imageData = nil
        previewImage = nil
        result = nil
        state = .idle
        existingPlantID = nil
        answers = [:]
        appliedObservations = []
        captureErrorMessage = nil
        archivedPrimaryURL = nil
        captureAttemptID = nil
    }

    private func cancelActiveAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysisAttemptID = nil
    }

    private static var onboardingMediaRootURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base.appendingPathComponent(
            "Grove/Onboarding/ScanDrafts",
            isDirectory: true
        )
    }

    private var persistenceKey: String? { activeScope?.persistenceKey }

    private func persistDraft() {
        guard let persistenceKey, let draft else { return }
        let snapshot = PersistedDraft(
            scanID: scanID,
            analysisRequestID: analysisRequestID,
            captures: captures,
            primaryDraft: draft,
            result: result,
            existingPlantID: existingPlantID,
            answers: answers,
            appliedObservations: appliedObservations
        )
        if let data = try? JSONEncoder().encode(snapshot) { storage.set(data, forKey: persistenceKey) }
    }

    private func restoreDraft(from targetMediaStore: ScanMediaStore, activationID: UUID) async {
        guard let key = persistenceKey else { return }
        guard let data = storage.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(PersistedDraft.self, from: data),
              !snapshot.captures.isEmpty,
              snapshot.captures.count <= ScanCaptureStage.allCases.count,
              Set(snapshot.captures.map(\.id)).count == snapshot.captures.count,
              Set(snapshot.captures.map { $0.stage ?? .wholePlant }).count == snapshot.captures.count,
              snapshot.captures.allSatisfy({ $0.mode == snapshot.primaryDraft.mode }),
              let primary = snapshot.captures.first(where: { $0.id == snapshot.primaryDraft.id }),
              primary == snapshot.primaryDraft,
              (primary.stage ?? .wholePlant) == .wholePlant,
              snapshot.captures.contains(where: { ($0.stage ?? .wholePlant) == .wholePlant }) else {
            storage.removeObject(forKey: key)
            return
        }
        var loadedData: [UUID: Data] = [:]
        do {
            for capture in snapshot.captures {
                guard capture.pixelWidth >= 500,
                      capture.pixelHeight >= 500,
                      max(capture.pixelWidth, capture.pixelHeight) <= 2_048 else {
                    throw ScanMediaError.invalidImage
                }
                let bytes = try await targetMediaStore.load(capture)
                guard bytes.count <= UIImage.maximumPlantAnalysisJPEGBytes,
                      bytes.starts(with: [0xFF, 0xD8, 0xFF]),
                      let image = UIImage(data: bytes),
                      image.cgImage?.width == capture.pixelWidth,
                      image.cgImage?.height == capture.pixelHeight else {
                    throw ScanMediaError.invalidImage
                }
                loadedData[capture.id] = bytes
            }
        } catch {
            guard scopeGeneration == activationID else { return }
            storage.removeObject(forKey: key)
            return
        }
        guard scopeGeneration == activationID,
              let primaryData = loadedData[primary.id],
              let primaryImage = UIImage(data: primaryData) else { return }
        scanID = snapshot.scanID
        analysisRequestID = snapshot.analysisRequestID ?? snapshot.scanID
        captures = snapshot.captures
        draft = primary
        result = snapshot.result
        existingPlantID = snapshot.existingPlantID
        let currentQuestionIDs = Set(snapshot.result?.condition.questions?.map(\.id) ?? [])
        answers = snapshot.answers.filter { currentQuestionIDs.contains($0.key) }
        appliedObservations = snapshot.appliedObservations ?? []
        imageData = primaryData
        previewImage = primaryImage
        state = result == nil ? .ready : .completed
    }

    private func clearPersistedDraft() {
        guard let persistenceKey else { return }
        storage.removeObject(forKey: persistenceKey)
    }

    private struct PersistedDraft: Codable {
        let scanID: UUID
        let analysisRequestID: UUID?
        let captures: [ScanMediaDraft]
        let primaryDraft: ScanMediaDraft
        let result: PlantAnalysisResult?
        let existingPlantID: UUID?
        let answers: [String: String]
        let appliedObservations: [DiagnosisObservation]?
    }
}

// Internal rather than file-private: the recurring check-in sends evidence to
// the same gateway, under the same 2 MB per-image limit, and must not grow a
// second, subtly different copy of this bounding logic.
extension UIImage {
    static let maximumPlantAnalysisJPEGBytes = 2 * 1024 * 1024

    func preparedForPlantAnalysis(maximumDimension: CGFloat = 2_048) -> UIImage {
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let largestDimension = max(pixelWidth, pixelHeight)
        guard maximumDimension > 0 else { return normalizedUp() }
        guard largestDimension > maximumDimension else { return normalizedUp() }

        let ratio = maximumDimension / largestDimension
        let targetSize = CGSize(
            width: max(1, (pixelWidth * ratio).rounded()),
            height: max(1, (pixelHeight * ratio).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    func boundedPlantAnalysisJPEG(
        maximumBytes: Int = UIImage.maximumPlantAnalysisJPEGBytes
    ) -> (image: UIImage, data: Data)? {
        guard maximumBytes > 0 else { return nil }
        let qualities: [CGFloat] = [0.82, 0.72, 0.62, 0.52, 0.42]
        var candidate = self

        while true {
            for quality in qualities {
                if let data = candidate.jpegData(compressionQuality: quality), data.count <= maximumBytes {
                    return (candidate, data)
                }
            }

            let pixelWidth = candidate.size.width * candidate.scale
            let pixelHeight = candidate.size.height * candidate.scale
            let smallestDimension = min(pixelWidth, pixelHeight)
            guard smallestDimension > 500 else { return nil }

            let scale = max(500 / smallestDimension, 0.82)
            let targetSize = CGSize(
                width: max(1, (pixelWidth * scale).rounded()),
                height: max(1, (pixelHeight * scale).rounded())
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let source = candidate
            candidate = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                source.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        }
    }
}
