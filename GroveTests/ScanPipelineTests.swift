import Foundation
import UIKit
import XCTest
@testable import Grove

final class ScanAddDecisionTests: XCTestCase {
    func testSettledIdentityCanBeAdoptedImmediately() {
        XCTAssertEqual(ScanAddDecision(identification: identification()), .adopt)
    }

    func testProvisionalIdentityCanBeConfirmedAndAddedFromTheLiveCard() throws {
        guard case .confirmAndAdopt(let candidate) = ScanAddDecision(
            identification: identification(requiresConfirmation: true)
        ) else {
            return XCTFail("A named match must not open a second confirmation screen")
        }
        XCTAssertEqual(candidate.scientificName, "Monstera deliciosa")
        XCTAssertEqual(candidate.commonName, "Swiss cheese plant")
    }

    func testConfirmationUsesTheDisplayedMatchInsteadOfTheFirstAlternative() throws {
        var identity = identification(requiresConfirmation: true)
        identity.candidates = [SpeciesCandidate(
            id: "other", commonName: "Pothos", scientificName: "Epipremnum aureum",
            confidence: 70, distinguishingTraits: [], regionalFit: nil
        )]
        guard case .confirmAndAdopt(let candidate) = ScanAddDecision(identification: identity) else {
            return XCTFail("Expected direct confirmation")
        }
        XCTAssertEqual(candidate.scientificName, identity.scientificName)
    }

    func testUnknownIdentityMustBeReviewed() {
        XCTAssertEqual(
            ScanAddDecision(identification: identification(isUnknown: true)),
            .reviewIdentity
        )
    }

    private func identification(
        isUnknown: Bool? = false,
        requiresConfirmation: Bool? = false
    ) -> PlantIdentificationResult {
        PlantIdentificationResult(
            commonName: "Swiss cheese plant",
            scientificName: "Monstera deliciosa",
            confidence: 94,
            alternatives: [],
            distinguishingTraits: [],
            isUnknown: isUnknown,
            requiresConfirmation: requiresConfirmation
        )
    }
}

final class ScanEvidenceRetryGuidanceTests: XCTestCase {
    func testMixedArrangementCannotBecomeOneUnknownPlant() throws {
        let guidance = try XCTUnwrap(
            ScanEvidenceRetryGuidance(
                evidence: evidence(subjectKind: .multiplePlants, subjectCount: 5)
            )
        )

        XCTAssertEqual(guidance.kind, .multiplePlants)
        XCTAssertEqual(guidance.title, "Choose one plant")
        XCTAssertEqual(guidance.actionTitle, "Retake with one plant")
    }

    func testCutArrangementGetsLivingPlantRecoveryCopy() throws {
        let guidance = try XCTUnwrap(
            ScanEvidenceRetryGuidance(
                evidence: evidence(subjectKind: .nonPlant, subjectCount: 1)
            )
        )

        XCTAssertEqual(guidance.kind, .unsupportedSubject)
        XCTAssertEqual(guidance.title, "Show a living plant")
    }

    func testReadableSinglePlantKeepsTheNormalUnknownIdentityPath() {
        XCTAssertNil(ScanEvidenceRetryGuidance(evidence: evidence()))
    }

    private func evidence(
        subjectKind: PlantEvidenceSubjectKind = .plant,
        subjectCount: Int = 1,
        sameSubject: Bool = true,
        usableForIdentification: Bool = true
    ) -> PlantEvidenceQuality {
        PlantEvidenceQuality(
            subjectKind: subjectKind,
            subjectCount: subjectCount,
            sameSubject: sameSubject,
            usableForIdentification: usableForIdentification,
            usableForCondition: true,
            qualityScore: 82,
            retakeStage: .none,
            retakeReason: ""
        )
    }
}

final class ScanMediaStoreTests: XCTestCase {
    func testMediaDraftRoundTripsAndDeletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveScanMediaTests-\(UUID().uuidString)", isDirectory: true)
        let store = ScanMediaStore(rootURL: root)
        let bytes = Data([0xFF, 0xD8, 0xFF]) + Data(repeating: 0xAB, count: 4_093)

        let draft = try await store.save(
            imageData: bytes,
            mode: .identify,
            pixelWidth: 900,
            pixelHeight: 1200
        )

        let loaded = try await store.load(draft)
        XCTAssertEqual(loaded, bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.fileURL.path))

        await store.delete(draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.fileURL.path))
        try? FileManager.default.removeItem(at: root)
    }

    func testMediaDraftRejectsImagesThatAreTooSmall() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveScanMediaTests-\(UUID().uuidString)", isDirectory: true)
        let store = ScanMediaStore(rootURL: root)

        do {
            _ = try await store.save(
                imageData: Data([0x01]),
                mode: .identify,
                pixelWidth: 320,
                pixelHeight: 320
            )
            XCTFail("Expected imageTooSmall")
        } catch let error as ScanMediaError {
            XCTAssertEqual(error, .imageTooSmall)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testArchivedScanPhotoSurvivesDraftDeletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveScanArchiveTests-\(UUID().uuidString)", isDirectory: true)
        let draftRoot = root.appendingPathComponent("ScanDrafts", isDirectory: true)
        let archiveRoot = root.appendingPathComponent("ScanHistory", isDirectory: true)
        let store = ScanMediaStore(rootURL: draftRoot, archiveRootURL: archiveRoot)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data([0xFF, 0xD8, 0xFF]) + Data(repeating: 0xCD, count: 4_093)
        let draft = try await store.save(
            imageData: bytes,
            mode: .identify,
            pixelWidth: 900,
            pixelHeight: 1_200
        )
        let archivedURL = try await store.archive(draft, scanID: UUID())

        await store.delete(draft)

        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: archivedURL), bytes)
    }

    func testMediaStoreRejectsAndWillNotDeleteDraftOutsideItsRoot() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveScanOwnershipTests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("ScanDrafts", isDirectory: true)
        let outside = base.appendingPathComponent("do-not-delete.jpg")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: outside)
        let foreignDraft = ScanMediaDraft(
            id: UUID(),
            mode: .identify,
            createdAt: .now,
            fileURL: outside,
            pixelWidth: 900,
            pixelHeight: 1_200,
            stage: .wholePlant
        )
        let store = ScanMediaStore(rootURL: root)

        do {
            _ = try await store.load(foreignDraft)
            XCTFail("Expected an out-of-root draft to be rejected")
        } catch let error as ScanMediaError {
            XCTAssertEqual(error, .invalidImage)
        }
        await store.delete(foreignDraft)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}

final class ObservationMediaStoreTests: XCTestCase {
    func testSavesAndLoadsProtectedObservationPhoto() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveObservationMediaTests-\(UUID().uuidString)", isDirectory: true)
        let store = ObservationMediaStore(rootURL: root)
        let imageData = Data(repeating: 0xAB, count: 1_024)

        let draft = try await store.save(
            imageData: imageData,
            pixelWidth: 900,
            pixelHeight: 1200
        )

        let loadedData = try await store.load(draft)
        XCTAssertEqual(loadedData, imageData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.fileURL.path))

        await store.delete(draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.fileURL.path))
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class PlantAnalysisServiceTests: XCTestCase {
    func testAcceptingTheSameMatchPreservesPhotoHealthEvidenceAndCareCaution() async throws {
        var result = try await LocalPlantAnalysisClient(simulatedDelay: .zero)
            .analyse(imageData: Data([0x01]), mode: .add)
        result.identification.requiresConfirmation = true
        result.condition.actionability = .provisional
        result.condition.assessmentAvailable = true
        let originalCondition = result.condition
        let suiteName = "GroveIdentityConfirmationTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let session = ScanSession(storage: storage)
        session.result = result
        guard case .confirmAndAdopt(let candidate) = ScanAddDecision(identification: result.identification) else {
            return XCTFail("Expected confirmation on the existing result card")
        }

        session.confirmIdentity(candidate)

        let confirmed = try XCTUnwrap(session.result)
        XCTAssertEqual(confirmed.identification.identityConfirmation, .userConfirmed)
        XCTAssertEqual(confirmed.identification.requiresConfirmation, false)
        XCTAssertEqual(confirmed.condition, originalCondition)
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Unassigned", analysis: confirmed)
        let indicators = PlantHealthIndicators.make(for: plant, observations: [], diagnosis: nil, tasks: store.tasks)
        for kind in [PlantHealthIndicatorKind.foliage, .posture, .growth] {
            XCTAssertEqual(indicators.first { $0.kind == kind }?.evidenceLevel, .observed)
            XCTAssertNil(indicators.first { $0.kind == kind }?.gap)
        }
    }

    func testConfirmingAnIdentityDoesNotInventAnUnavailableAssessment() async throws {
        var result = try await LocalPlantAnalysisClient(simulatedDelay: .zero)
            .analyse(imageData: Data([0x01]), mode: .add)
        result.condition.actionability = .insufficientEvidence
        result.condition.assessmentAvailable = false
        let suiteName = "GroveIdentityConfirmationTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let session = ScanSession(storage: storage)
        session.result = result
        session.confirmIdentity(try XCTUnwrap(result.identification.candidates?.first))

        XCTAssertEqual(session.result?.condition.assessmentAvailable, false)
        XCTAssertEqual(session.result?.condition.actionability, .insufficientEvidence)
    }

    func testChoosingADifferentSpeciesStillClearsPreviousTreatmentAdvice() async throws {
        let result = try await LocalPlantAnalysisClient(simulatedDelay: .zero)
            .analyse(imageData: Data([0x01]), mode: .diagnose)
        let suiteName = "GroveIdentityConfirmationTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let session = ScanSession(storage: storage)
        session.result = result
        session.confirmIdentity(SpeciesCandidate(
            id: "other", commonName: "Pothos", scientificName: "Epipremnum aureum",
            confidence: 90, distinguishingTraits: [], regionalFit: nil
        ))

        XCTAssertEqual(session.result?.condition.assessmentAvailable, false)
        XCTAssertEqual(session.result?.condition.actionability, .provisional)
        XCTAssertEqual(session.result?.condition.possibleCauses, [])
        XCTAssertEqual(session.result?.condition.possibleConditions, [])
        XCTAssertEqual(session.result?.condition.positiveSigns, result.condition.positiveSigns)
    }

    func testDiagnosisReturnsStructuredConcernsAndConservativeActions() async throws {
        let client = LocalPlantAnalysisClient(simulatedDelay: .zero)

        let result = try await client.analyse(imageData: Data([0x01]), mode: .diagnose)

        XCTAssertEqual(result.identification.scientificName, "Monstera deliciosa")
        XCTAssertEqual(result.condition.healthBand, .monitor)
        XCTAssertFalse(result.condition.concerns.isEmpty)
        XCTAssertFalse(result.condition.possibleCauses.isEmpty)
        XCTAssertGreaterThanOrEqual(result.identification.candidates?.count ?? 0, 3)
        XCTAssertFalse(result.condition.possibleConditions?.isEmpty ?? true)
        XCTAssertFalse(result.condition.questions?.isEmpty ?? true)
        XCTAssertFalse(result.condition.actionsToAvoid?.isEmpty ?? true)
        XCTAssertEqual(
            result.condition.indicatorFindings?.map(\.kind),
            [.foliage, .posture, .growth]
        )
        XCTAssertTrue(result.limitations.contains("Visual assessment only"))
    }

    func testAnalysisUsesRegionAndMultipleCaptureStages() async throws {
        let client = LocalPlantAnalysisClient(simulatedDelay: .zero)
        let result = try await client.analyse(
            request: PlantAnalysisRequest(
                mode: .add,
                images: [
                    PlantAnalysisImage(stage: .wholePlant, mimeType: "image/jpeg", base64Data: Data([0x01]).base64EncodedString()),
                    PlantAnalysisImage(stage: .leaf, mimeType: "image/jpeg", base64Data: Data([0x02]).base64EncodedString())
                ],
                regionCode: "GB",
                existingPlant: nil,
                answers: [:]
            )
        )

        XCTAssertEqual(result.identification.regionCode, "GB")
        XCTAssertEqual(result.identification.imageQualityWarnings, [])
        // A decisive top match is asserted, not put to the user as a question.
        XCTAssertEqual(result.identification.requiresConfirmation, false)
        XCTAssertEqual(
            result.condition.indicatorFindings?.map(\.kind),
            [.foliage, .posture, .growth]
        )
    }

    func testAddDraftRestoresAfterSessionRecreation() async throws {
        let suiteName = "GroveScanDraftTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let accountID = "draft-account"
        let root = AccountStorage.mediaRootURL(for: accountID).appendingPathComponent("ScanDrafts", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: AccountStorage.mediaRootURL(for: accountID)) }
        let image = detailedTestImage(size: CGSize(width: 900, height: 1_200))

        let first = ScanSession(mediaStore: ScanMediaStore(rootURL: root), analysisClient: LocalPlantAnalysisClient(simulatedDelay: .zero), storage: storage)
        await first.activate(accountID: accountID)
        await first.begin(mode: .add)
        await first.save(image: image, mode: .add, stage: .wholePlant)
        XCTAssertEqual(first.resumableDraftMode, .add)

        let restored = ScanSession(mediaStore: ScanMediaStore(rootURL: root), analysisClient: LocalPlantAnalysisClient(simulatedDelay: .zero), storage: storage)
        await restored.activate(accountID: accountID)

        XCTAssertEqual(restored.resumableDraftMode, .add)
        XCTAssertNotNil(restored.capture(for: .wholePlant))
    }

    func testRestoredDraftRejectsATamperedFileOutsideItsMediaRoot() async throws {
        let suiteName = "GroveTamperedScanDraft-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveTamperedScanDraft-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("ScanDrafts", isDirectory: true)
        let outside = base.appendingPathComponent("outside.jpg")
        defer { try? FileManager.default.removeItem(at: base) }

        let first = ScanSession(storage: storage)
        await first.activateForOnboarding(rootURL: root)
        await first.begin(mode: .add)
        await first.save(
            image: detailedTestImage(size: CGSize(width: 900, height: 1_200)),
            mode: .add
        )
        let originalDraft = try XCTUnwrap(first.draft)
        try Data(contentsOf: originalDraft.fileURL).write(to: outside)

        let key = "grove.scan.draft.v2.onboarding"
        let snapshotData = try XCTUnwrap(storage.data(forKey: key))
        var snapshot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: snapshotData) as? [String: Any]
        )
        var captures = try XCTUnwrap(snapshot["captures"] as? [[String: Any]])
        captures[0]["fileURL"] = outside.absoluteString
        var primary = try XCTUnwrap(snapshot["primaryDraft"] as? [String: Any])
        primary["fileURL"] = outside.absoluteString
        snapshot["captures"] = captures
        snapshot["primaryDraft"] = primary
        storage.set(try JSONSerialization.data(withJSONObject: snapshot), forKey: key)

        let restored = ScanSession(storage: storage)
        await restored.activateForOnboarding(rootURL: root)

        XCTAssertNil(restored.draft)
        XCTAssertNil(storage.data(forKey: key))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        await restored.discard()
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testOnboardingDraftHasANeutralDurableScopeSeparateFromTheLastAccount() async throws {
        let suiteName = "GroveOnboardingScanScope-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let accountID = "scan-scope-account-\(UUID().uuidString)"
        let accountRoot = AccountStorage.mediaRootURL(for: accountID)
        let onboardingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveOnboardingScanScope-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: accountRoot)
            try? FileManager.default.removeItem(at: onboardingRoot)
        }
        let image = detailedTestImage(size: CGSize(width: 900, height: 1_200))

        let first = ScanSession(
            analysisClient: LocalPlantAnalysisClient(simulatedDelay: .zero),
            storage: storage
        )
        await first.activate(accountID: accountID)
        await first.begin(mode: .add)
        await first.save(image: image, mode: .add)
        let accountScanID = first.scanID
        XCTAssertNotNil(first.draft)

        await first.activateForOnboarding(rootURL: onboardingRoot)
        XCTAssertNil(first.draft, "Signed-out onboarding must not inherit the last account's photo")
        await first.begin(mode: .add)
        await first.save(image: image, mode: .add)
        let onboardingScanID = first.scanID
        XCTAssertNotEqual(onboardingScanID, accountScanID)

        let relaunched = ScanSession(
            analysisClient: LocalPlantAnalysisClient(simulatedDelay: .zero),
            storage: storage
        )
        await relaunched.activateForOnboarding(rootURL: onboardingRoot)
        XCTAssertEqual(relaunched.scanID, onboardingScanID)
        XCTAssertNotNil(relaunched.draft)

        await relaunched.activate(accountID: accountID)
        XCTAssertEqual(relaunched.scanID, accountScanID)
        XCTAssertNotNil(relaunched.draft, "Returning to the account should restore only its own draft")
    }

    func testViewTaskCancellationDoesNotPauseSessionOwnedAnalysis() async throws {
        let suiteName = "GroveScanCancellationTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveScanCancellationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = detailedTestImage(size: CGSize(width: 900, height: 1_200))
        let session = ScanSession(
            mediaStore: ScanMediaStore(rootURL: root),
            analysisClient: SlowSuccessfulPlantAnalysisClient(),
            storage: storage
        )
        await session.activate(accountID: "cancellation-account")
        await session.begin(mode: .identify)
        await session.save(image: image, mode: .identify)

        let task = Task { await session.analyse() }
        try await waitForAnalysisToStart(session)
        XCTAssertEqual(session.state, .analysing)
        task.cancel()
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(session.state, .analysing)
        await session.analyse()
        await task.value
        XCTAssertEqual(session.state, .completed)
        XCTAssertNotNil(session.result)
    }

    func testDiscardCancelsAnalysisAndRejectsItsLateResult() async throws {
        let suiteName = "GroveScanDiscardTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveScanDiscardTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScanSession(
            mediaStore: ScanMediaStore(rootURL: root),
            analysisClient: SlowSuccessfulPlantAnalysisClient(),
            storage: storage
        )
        await session.activate(accountID: "discard-account")
        await session.begin(mode: .diagnose)
        await session.save(
            image: detailedTestImage(size: CGSize(width: 900, height: 1_200)),
            mode: .diagnose
        )

        let task = Task { await session.analyse() }
        try await waitForAnalysisToStart(session)
        XCTAssertEqual(session.state, .analysing)
        await session.discard()
        await task.value

        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.result)
        XCTAssertTrue(session.captures.isEmpty)
    }

    func testScanUsesPersistedScanIDForResumableAnalysisJob() async throws {
        let suiteName = "GroveScanJobIdentityTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveScanJobIdentityTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RecordingPlantAnalysisClient()
        let session = ScanSession(
            mediaStore: ScanMediaStore(rootURL: root),
            analysisClient: client,
            storage: storage
        )
        await session.activate(accountID: "job-identity-account")
        await session.begin(mode: .identify)
        let scanID = session.scanID
        await session.save(image: detailedTestImage(size: CGSize(width: 900, height: 1_200)), mode: .identify)

        await session.analyse(regionCode: "GB")

        XCTAssertEqual(client.requests.first?.clientRequestID, scanID)
        XCTAssertEqual(session.state, .completed)
    }

    func testMalformedCompletedJobRetriesWithNewProviderIdentityButSameScan() async throws {
        let suiteName = "GroveMalformedScanRetry-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveMalformedScanRetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = MalformedOncePlantAnalysisClient()
        let session = ScanSession(
            mediaStore: ScanMediaStore(rootURL: root),
            analysisClient: client,
            storage: storage
        )
        await session.activateForOnboarding(rootURL: root)
        await session.begin(mode: .identify)
        let scanID = session.scanID
        await session.save(
            image: detailedTestImage(size: CGSize(width: 900, height: 1_200)),
            mode: .identify
        )

        await session.analyse()
        guard case .failed(_, let kind) = session.state else {
            return XCTFail("Expected the malformed result to surface as a failure")
        }
        XCTAssertEqual(kind, .service)
        XCTAssertEqual(session.scanID, scanID)

        await session.retry()

        XCTAssertEqual(session.state, .completed)
        XCTAssertEqual(session.scanID, scanID)
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertNotEqual(client.requests[0].clientRequestID, client.requests[1].clientRequestID)
    }

    func testCorruptedSavedPhotoRequiresAReplacementInsteadOfEndlessServiceRetries() async throws {
        let suiteName = "GroveCorruptSavedScan-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveCorruptSavedScan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RecordingPlantAnalysisClient()
        let session = ScanSession(analysisClient: client, storage: storage)
        await session.activateForOnboarding(rootURL: root)
        await session.begin(mode: .identify)
        await session.save(
            image: detailedTestImage(size: CGSize(width: 900, height: 1_200)),
            mode: .identify
        )
        let draft = try XCTUnwrap(session.draft)
        try Data("damaged".utf8).write(to: draft.fileURL, options: .atomic)

        await session.analyse()

        guard case .failed(_, let kind) = session.state else {
            return XCTFail("Expected a corrupted saved photo to fail")
        }
        XCTAssertEqual(kind, .photo)
        XCTAssertFalse(kind.isRetryable)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testExistingPlantContextAndIterativeAnswersStayInsideGatewayContract() async throws {
        let suiteName = "GroveScanContractTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveScanContractTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RecordingPlantAnalysisClient()
        let session = ScanSession(
            mediaStore: ScanMediaStore(rootURL: root),
            analysisClient: client,
            storage: storage
        )
        var plant = GroveStore(plants: [], persistenceEnabled: false)
            .addPlant(nickname: "Edge", location: "Desk")
        plant.species = String(repeating: "🌿", count: 100)
        plant.scientificName = ""
        plant.location = String(repeating: "🪴", count: 100)
        plant.summary = String(repeating: "🌱", count: 400)

        await session.activateForOnboarding(rootURL: root)
        await session.begin(mode: .diagnose, existingPlantID: plant.id)
        await session.save(
            image: detailedTestImage(size: CGSize(width: 900, height: 1_200)),
            mode: .diagnose
        )
        await session.analyse(regionCode: String(repeating: "🇳🇿", count: 8), existingPlant: plant)

        let first = try XCTUnwrap(client.requests.first)
        let context = try XCTUnwrap(first.existingPlant)
        XCTAssertLessThanOrEqual(context.commonName.utf16.count, 120)
        XCTAssertEqual(context.scientificName, "Species unconfirmed")
        XCTAssertLessThanOrEqual(context.location.utf16.count, 120)
        XCTAssertLessThanOrEqual(context.recentSummary.utf16.count, 600)
        XCTAssertLessThanOrEqual(first.regionCode?.utf16.count ?? 0, 8)

        let currentQuestions = try XCTUnwrap(session.result?.condition.questions)
        for question in currentQuestions {
            session.answer(questionID: question.id, optionID: question.options[0].id)
        }
        session.answer(questionID: "stale-a", optionID: "old")
        session.answer(questionID: "stale-b", optionID: "old")
        await session.analyse(existingPlant: plant)

        let refined = try XCTUnwrap(client.requests.last)
        XCTAssertLessThanOrEqual(refined.answers.count, 3)
        XCTAssertEqual(refined.answers.count, currentQuestions.count, "Stale answers never reach the gateway")
        for question in currentQuestions.prefix(3) {
            let value = try XCTUnwrap(refined.answers[question.id], "Current questions must take priority over stale iterative answers")
            // The model sees what was chosen and what was asked, not an option
            // id it invented on a call it cannot remember.
            XCTAssertTrue(value.hasPrefix(question.options[0].title), value)
            XCTAssertTrue(value.contains(question.prompt.prefix(20)), value)
        }
        XCTAssertTrue(refined.answers.allSatisfy { $0.key.utf16.count <= 64 && $0.value.utf16.count <= 120 })

        // One round, then a verdict: the answered scan carries no further
        // questions, the answers are shown back, and the selection is cleared
        // so nothing can offer a second refine.
        XCTAssertEqual(session.result?.condition.questions ?? [], [])
        XCTAssertEqual(session.appliedObservations.map(\.answer), currentQuestions.map { $0.options[0].title })
        XCTAssertTrue(session.answers.isEmpty)
        XCTAssertFalse(session.allQuestionsAnswered)
    }

    func testAnAnsweredScanCommitsInsteadOfAskingAgain() async throws {
        let suiteName = "GroveAnsweredScanTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveAnsweredScanTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RecordingPlantAnalysisClient()
        let session = ScanSession(
            mediaStore: ScanMediaStore(rootURL: root),
            analysisClient: client,
            storage: storage
        )

        await session.activateForOnboarding(rootURL: root)
        await session.begin(mode: .diagnose, existingPlantID: nil)
        await session.save(image: detailedTestImage(size: CGSize(width: 900, height: 1_200)), mode: .diagnose)
        await session.analyse(regionCode: "NZ", existingPlant: nil)

        let questions = try XCTUnwrap(session.result?.condition.questions)
        XCTAssertEqual(questions.count, 2)
        XCTAssertTrue(session.appliedObservations.isEmpty)
        XCTAssertFalse(session.allQuestionsAnswered)

        // Half a round is not enough to refine on.
        session.answer(questionID: questions[0].id, optionID: questions[0].options[2].id)
        XCTAssertEqual(session.pendingObservations.count, 1)
        XCTAssertFalse(session.allQuestionsAnswered)
        session.answer(questionID: questions[1].id, optionID: questions[1].options[1].id)
        XCTAssertTrue(session.allQuestionsAnswered)

        await session.analyse(regionCode: "NZ", existingPlant: nil)

        let refined = try XCTUnwrap(client.requests.last)
        XCTAssertEqual(refined.answers[questions[0].id], "Wet or soggy · asked: How does the soil feel 3–5 cm below the surface?")
        XCTAssertEqual(session.result?.condition.questions ?? [], [])
        XCTAssertEqual(session.appliedObservations.count, 2)
        XCTAssertTrue(session.answers.isEmpty)

        // The answered round survives a relaunch, and a stale answer cannot.
        let restored = ScanSession(
            mediaStore: ScanMediaStore(rootURL: root),
            analysisClient: client,
            storage: storage
        )
        await restored.activateForOnboarding(rootURL: root)
        XCTAssertEqual(restored.appliedObservations, session.appliedObservations)
        XCTAssertEqual(restored.result?.condition.questions ?? [], [])
        XCTAssertTrue(restored.answers.isEmpty)
    }

    func testAThinImageIsRejectedBeforeQualitySamplingOrPersistence() async throws {
        let suiteName = "GroveThinScanTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveThinScanTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScanSession(mediaStore: ScanMediaStore(rootURL: root), storage: storage)
        let image = detailedTestImage(size: CGSize(width: 120, height: 2_000))
        await session.activateForOnboarding(rootURL: root)
        await session.begin(mode: .identify)

        await session.save(image: image, mode: .identify)

        XCTAssertTrue(session.captures.isEmpty)
        guard case .failed(let message, let kind) = session.state else {
            return XCTFail("Expected the narrow capture to be rejected")
        }
        XCTAssertEqual(kind, .photo)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("500 pixels"))
    }

    func testLateHistoryReplayCannotUnlinkAnAdoptedScanOrItsPhoto() async throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let result = try await LocalPlantAnalysisClient(simulatedDelay: .zero)
            .analyse(imageData: Data([0x01]), mode: .add)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen", analysis: result)
        let scanID = UUID()
        let photo = URL(fileURLWithPath: "/tmp/grove-history-race.jpg")
        store.recordScan(id: scanID, mode: .add, result: result, photoURL: photo, plantID: plant.id)

        // Simulates the slower pre-adoption result task landing last.
        store.recordScan(id: scanID, mode: .add, result: result, photoURL: nil)

        XCTAssertEqual(store.scanHistory.first?.plantID, plant.id)
        XCTAssertEqual(store.scanHistory.first?.photoURL, photo)
    }

    func testDeletingTamperedScanHistoryCannotDeleteAFileOutsideAccountMedia() async throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let result = try await LocalPlantAnalysisClient(simulatedDelay: .zero)
            .analyse(imageData: Data([0x01]), mode: .identify)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-scan-history-do-not-delete-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("keep me".utf8).write(to: outside)
        let scanID = UUID()
        store.recordScan(id: scanID, mode: .identify, result: result, photoURL: outside)

        store.deleteScanHistory(ids: [scanID])

        XCTAssertFalse(store.scanHistory.contains { $0.id == scanID })
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testAddPlantBooksAnEarlyFirstCheckIn() async throws {
        var result = try await LocalPlantAnalysisClient(simulatedDelay: .zero)
            .analyse(imageData: Data([0x01]), mode: .diagnose)
        result.condition.followUpDays = 5
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let expected = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 3, to: .now))

        let plant = store.addPlant(nickname: "Fern", location: "Office", analysis: result)

        XCTAssertEqual(plant.nextCheckIn.timeIntervalSince(expected), 0, accuracy: 2)
        XCTAssertEqual(store.tasks.first?.dueDate, plant.nextCheckIn)
    }

    func testFirstCheckInKeepsAShorterAnalysisWindow() async throws {
        var result = try await LocalPlantAnalysisClient(simulatedDelay: .zero)
            .analyse(imageData: Data([0x01]), mode: .diagnose)
        result.condition.followUpDays = 1
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let expected = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: .now))

        let plant = store.addPlant(nickname: "Fern", location: "Office", analysis: result)

        XCTAssertEqual(plant.nextCheckIn.timeIntervalSince(expected), 0, accuracy: 2)
        XCTAssertEqual(store.tasks.first?.dueDate, plant.nextCheckIn)
    }

    func testScanBaselineFillsPhotoGroundedHealthIndicators() async throws {
        var result = try await LocalPlantAnalysisClient(simulatedDelay: .zero)
            .analyse(imageData: Data([0x01]), mode: .add)
        // A completed job can survive a gateway rollout. Reproduce the older
        // result shape that had visible evidence but no dedicated indicators.
        result.condition.indicatorFindings = nil
        result.growingConditions = PlantGrowingConditions(
            soilSurface: .damp,
            confidence: 72
        )
        let store = GroveStore(plants: [], persistenceEnabled: false)

        let plant = store.addPlant(
            nickname: "Pesto",
            location: "Unassigned",
            analysis: result
        )
        let indicators = PlantHealthIndicators.make(
            for: plant,
            observations: [],
            diagnosis: nil,
            tasks: store.tasks
        )

        XCTAssertEqual(indicators.first { $0.kind == .moisture }?.status, "Surface damp")
        XCTAssertEqual(indicators.first { $0.kind == .foliage }?.status, "Watch")
        XCTAssertEqual(indicators.first { $0.kind == .posture }?.status, "Good")
        XCTAssertEqual(indicators.first { $0.kind == .growth }?.status, "Good")
        XCTAssertNil(indicators.first { $0.kind == .moisture }?.gap)
        XCTAssertNil(indicators.first { $0.kind == .foliage }?.gap)
        XCTAssertNil(indicators.first { $0.kind == .posture }?.gap)
        XCTAssertNil(indicators.first { $0.kind == .growth }?.gap)
        XCTAssertNotNil(indicators.first { $0.kind == .light }?.gap)
        XCTAssertNotNil(indicators.first { $0.kind == .care }?.gap)

        // Plants adopted by the affected build already contain six explicit
        // unavailable snapshots. The new renderer repairs their still-current
        // baseline from the scan evidence retained on the plant itself.
        var savedBeforeFix = plant
        savedBeforeFix.healthIndicatorReadings = PlantHealthIndicatorKind.allCases.map { kind in
            PlantHealthIndicatorReading(
                kind: kind,
                value: "unavailable",
                score: nil,
                status: "Not measured",
                detail: "No structured finding was stored.",
                evidenceLevel: .unavailable,
                source: .none,
                confidence: nil,
                evidence: [],
                measuredAt: plant.assessmentDate ?? .now,
                validUntil: Calendar.current.date(byAdding: .day, value: 30, to: .now),
                algorithmVersion: "legacy"
            )
        }
        let recovered = PlantHealthIndicators.make(
            for: savedBeforeFix,
            observations: [],
            diagnosis: nil,
            tasks: store.tasks
        )

        XCTAssertEqual(recovered.first { $0.kind == .moisture }?.status, "Surface damp")
        XCTAssertEqual(recovered.first { $0.kind == .foliage }?.status, "Watch")
        XCTAssertEqual(recovered.first { $0.kind == .posture }?.status, "Good")
        XCTAssertEqual(recovered.first { $0.kind == .growth }?.status, "Good")

        // The duplicate identity step also reduced confidence to 40 and
        // cleared availability when accepting the original match.
        savedBeforeFix.identityConfirmation = .userConfirmed
        savedBeforeFix.confidence = 40
        savedBeforeFix.summary = "Identity selected. Use a fresh photo to establish condition-specific care for Monstera."
        let repairedConfirmation = PlantHealthIndicators.make(
            for: savedBeforeFix, observations: [], diagnosis: nil, tasks: store.tasks
        )
        XCTAssertEqual(repairedConfirmation.first { $0.kind == .foliage }?.status, "Watch")
        XCTAssertEqual(repairedConfirmation.first { $0.kind == .posture }?.status, "Good")
        XCTAssertEqual(repairedConfirmation.first { $0.kind == .growth }?.status, "Good")

        // Recovery must not turn a later unreadable scan into an old positive.
        let later = Date.now.addingTimeInterval(60)
        savedBeforeFix.healthIndicatorReadings = savedBeforeFix.healthIndicatorReadings?.map { reading in
            PlantHealthIndicatorReading(
                kind: reading.kind, value: reading.value, score: reading.score,
                status: reading.status, detail: reading.detail,
                evidenceLevel: reading.evidenceLevel, source: reading.source,
                confidence: reading.confidence, evidence: reading.evidence,
                measuredAt: later, validUntil: reading.validUntil,
                algorithmVersion: reading.algorithmVersion
            )
        }
        let superseded = PlantHealthIndicators.make(
            for: savedBeforeFix, observations: [], diagnosis: nil, tasks: store.tasks, now: later
        )
        XCTAssertEqual(superseded.first { $0.kind == .posture }?.status, "Not visible")
        XCTAssertNotNil(superseded.first { $0.kind == .posture }?.gap)
    }

    func testOversizedCaptureIsDownsampledBeforeStorage() async throws {
        let suiteName = "GroveScanResizeTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveScanResizeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = detailedTestImage(size: CGSize(width: 3_000, height: 4_000))
        let session = ScanSession(mediaStore: ScanMediaStore(rootURL: root), storage: storage)
        await session.activate(accountID: "resize-account")
        await session.begin(mode: .add)

        await session.save(image: image, mode: .add)

        let draft = try XCTUnwrap(session.draft)
        XCTAssertLessThanOrEqual(max(draft.pixelWidth, draft.pixelHeight), 2_048)
        XCTAssertGreaterThanOrEqual(min(draft.pixelWidth, draft.pixelHeight), 500)
    }

    func testDetailedCaptureIsEncodedWithinGatewayImageLimit() async throws {
        let suiteName = "GroveScanByteLimitTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveScanByteLimitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScanSession(mediaStore: ScanMediaStore(rootURL: root), storage: storage)
        await session.activate(accountID: "byte-limit-account")
        await session.begin(mode: .identify)

        await session.save(image: noisyTestImage(width: 2_048, height: 2_048), mode: .identify)

        let draft = try XCTUnwrap(session.draft)
        let storedData = try Data(contentsOf: draft.fileURL)
        XCTAssertLessThanOrEqual(storedData.count, 2 * 1_024 * 1_024)
        XCTAssertGreaterThanOrEqual(min(draft.pixelWidth, draft.pixelHeight), 500)
    }
}

@MainActor
final class ScanImageQualityAnalyzerTests: XCTestCase {
    func testNearlyBlackCaptureIsBlocked() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1_200)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 1_200))
        }

        let report = ScanImageQualityAnalyzer.assess(image)

        XCTAssertFalse(report.isAcceptable)
        XCTAssertTrue(report.blockingMessage?.localizedCaseInsensitiveContains("dark") == true)
    }

    func testDetailedCapturePassesSharpnessGate() {
        let report = ScanImageQualityAnalyzer.assess(
            detailedTestImage(size: CGSize(width: 900, height: 1_200))
        )

        XCTAssertTrue(report.isAcceptable)
        XCTAssertFalse(report.warnings.contains(.softFocus))
        XCTAssertGreaterThan(report.edgeStrength, 4.5)
    }

    func testSmoothImageProducesFocusGuidanceWithoutBlocking() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1_200)).image { context in
            let colours = [UIColor.black.cgColor, UIColor.white.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colours, locations: [0, 1])!
            context.cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 900, y: 1_200),
                options: []
            )
        }

        let report = ScanImageQualityAnalyzer.assess(image)

        XCTAssertTrue(report.isAcceptable)
        XCTAssertTrue(report.warnings.contains(.softFocus))
    }

    func testSessionDoesNotPersistUnusableCapture() async throws {
        let suiteName = "GroveScanQualityTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveScanQualityTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1_200)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 1_200))
        }
        let session = ScanSession(mediaStore: ScanMediaStore(rootURL: root), storage: storage)
        await session.activate(accountID: "quality-account")
        await session.begin(mode: .identify)

        await session.save(image: image, mode: .identify)

        XCTAssertTrue(session.captures.isEmpty)
        guard case .failed(let message, let kind) = session.state else {
            return XCTFail("Expected an unusable capture failure")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("dark"))
        XCTAssertEqual(kind, .photo, "A rejected frame must not offer a retry that re-reads it.")
    }

    func testFailedRetakePreservesPreviousValidCapture() async throws {
        let suiteName = "GroveScanRetakeTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveScanRetakeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScanSession(mediaStore: ScanMediaStore(rootURL: root), storage: storage)
        await session.activate(accountID: "retake-account")
        await session.begin(mode: .identify)
        await session.save(
            image: detailedTestImage(size: CGSize(width: 900, height: 1_200)),
            mode: .identify
        )
        let original = try XCTUnwrap(session.draft)
        let blackImage = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1_200)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 1_200))
        }

        await session.save(image: blackImage, mode: .identify)

        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(session.draft?.id, original.id)
        XCTAssertTrue(session.captureErrorMessage?.localizedCaseInsensitiveContains("dark") == true)
    }
}

@MainActor
private func detailedTestImage(size: CGSize) -> UIImage {
    UIGraphicsImageRenderer(size: size).image { context in
        let tile = max(20, min(size.width, size.height) / 12)
        for row in 0...Int(ceil(size.height / tile)) {
            for column in 0...Int(ceil(size.width / tile)) {
                ((row + column).isMultiple(of: 2) ? UIColor.systemGreen : UIColor.white).setFill()
                context.fill(
                    CGRect(
                        x: CGFloat(column) * tile,
                        y: CGFloat(row) * tile,
                        width: tile,
                        height: tile
                    )
                )
            }
        }
    }
}

@MainActor
private func noisyTestImage(width: Int, height: Int) -> UIImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var state: UInt64 = 0x9E3779B97F4A7C15
    for index in stride(from: 0, to: pixels.count, by: 4) {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
        pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 32)
        pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 40)
        pixels[index + 3] = 255
    }
    let data = Data(pixels) as CFData
    let provider = CGDataProvider(data: data)!
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
    )
    let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
    return UIImage(cgImage: image)
}

@MainActor
private struct SlowSuccessfulPlantAnalysisClient: PlantAnalysisClient {
    func analyse(request: PlantAnalysisRequest) async throws -> PlantAnalysisResult {
        try await Task.sleep(for: .milliseconds(150))
        return try await LocalPlantAnalysisClient(simulatedDelay: .zero).analyse(request: request)
    }
}

@MainActor
private func waitForAnalysisToStart(_ session: ScanSession) async throws {
    for _ in 0..<100 where session.state != .analysing {
        try await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
private final class RecordingPlantAnalysisClient: PlantAnalysisClient {
    private(set) var requests: [PlantAnalysisRequest] = []

    func analyse(request: PlantAnalysisRequest) async throws -> PlantAnalysisResult {
        requests.append(request)
        return try await LocalPlantAnalysisClient(simulatedDelay: .zero).analyse(request: request)
    }
}

@MainActor
private final class MalformedOncePlantAnalysisClient: PlantAnalysisClient {
    private(set) var requests: [PlantAnalysisRequest] = []

    func analyse(request: PlantAnalysisRequest) async throws -> PlantAnalysisResult {
        requests.append(request)
        if requests.count == 1 { throw PlantAnalysisError.malformedResponse }
        return try await LocalPlantAnalysisClient(simulatedDelay: .zero).analyse(request: request)
    }
}

@MainActor
final class CheckInAnalysisTests: XCTestCase {
    func testCheckInAnalysisSendsDiagnoseModeWithPlantContextAndObservations() async throws {
        let client = RecordingPlantAnalysisClient()
        let session = ScanSession(analysisClient: client)
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        _ = try await session.analyseCheckIn(
            imageData: Data(repeating: 0xAB, count: 512),
            plant: plant,
            regionCode: "GB",
            answers: [
                "checkin-appearance": "better",
                "checkin-soil-moisture": "dry",
                "checkin-new-growth": "yes"
            ]
        )

        // The check-in has to reach the gateway as a comparison against a plant
        // Grove already knows, not as an anonymous scan — that context is the
        // whole point of a recurring check-in.
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.mode, .diagnose)
        XCTAssertEqual(request.existingPlant?.id, plant.id)
        XCTAssertEqual(request.existingPlant?.commonName, plant.species)
        XCTAssertEqual(request.existingPlant?.location, "Kitchen")
        XCTAssertEqual(request.regionCode, "GB")
        XCTAssertEqual(request.images.count, 1)
        XCTAssertEqual(request.images.first?.stage, .wholePlant)
        // The gateway rejects more than three answers.
        XCTAssertEqual(request.answers.count, 3)
        XCTAssertEqual(request.answers["checkin-appearance"], "better")
    }

    func testCheckInAnalysisSubstitutesEmptyContextTheGatewayWouldReject() async throws {
        let client = RecordingPlantAnalysisClient()
        let session = ScanSession(analysisClient: client)
        let blank = Plant(
            id: UUID(),
            nickname: "Blank",
            species: "",
            scientificName: "",
            location: "",
            healthScore: 70,
            healthBand: .healthy,
            trend: .baseline,
            confidence: 80,
            nextCheckIn: .now,
            symbol: "leaf.fill",
            palette: .fern,
            summary: "",
            positiveSigns: [],
            concerns: [],
            nextActions: []
        )

        _ = try await session.analyseCheckIn(
            imageData: Data(repeating: 0xAB, count: 512),
            plant: blank,
            regionCode: nil,
            answers: [:]
        )

        // Empty strings fail the gateway's bounded-text validation, which would
        // silently downgrade every check-in to the offline estimate.
        let context = try XCTUnwrap(client.requests.first?.existingPlant)
        XCTAssertFalse(context.commonName.isEmpty)
        XCTAssertFalse(context.scientificName.isEmpty)
        XCTAssertFalse(context.location.isEmpty)
        XCTAssertFalse(context.recentSummary.isEmpty)
    }

    func testCheckInAnalysisLabelsEarlierAndCurrentPhotosSeparately() async throws {
        let client = RecordingPlantAnalysisClient()
        let session = ScanSession(analysisClient: client)
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let previous = Data(repeating: 0x11, count: 256)
        let current = Data(repeating: 0x22, count: 512)

        _ = try await session.analyseCheckIn(
            imageData: current,
            previousImageData: previous,
            plant: plant,
            regionCode: "GB",
            answers: [:]
        )

        let images = try XCTUnwrap(client.requests.first?.images)
        XCTAssertEqual(images.map(\.stage), [.reference, .wholePlant])
        XCTAssertEqual(images[0].base64Data, previous.base64EncodedString())
        XCTAssertEqual(images[1].base64Data, current.base64EncodedString())
    }

    func testCheckInAnalysisTruncatesOverlongSummaryToTheGatewayLimit() async throws {
        let client = RecordingPlantAnalysisClient()
        let session = ScanSession(analysisClient: client)
        let store = GroveStore(plants: [], persistenceEnabled: false)
        var plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        plant.summary = String(repeating: "a", count: 900)

        _ = try await session.analyseCheckIn(
            imageData: Data(repeating: 0xAB, count: 512),
            plant: plant,
            regionCode: nil,
            answers: [:]
        )

        let context = try XCTUnwrap(client.requests.first?.existingPlant)
        XCTAssertEqual(context.recentSummary.count, 600)
    }
}
