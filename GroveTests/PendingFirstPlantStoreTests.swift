import Foundation
import XCTest
@testable import Grove

@MainActor
private final class RecordingFirstPlantSync: PendingFirstPlantSyncing {
    var results: [Bool]
    private(set) var payloads: [SyncMutationPayload] = []

    init(results: [Bool]) {
        self.results = results
    }

    func enqueue(_ payload: SyncMutationPayload, isConnected: Bool) async -> Bool {
        payloads.append(payload)
        return results.isEmpty ? true : results.removeFirst()
    }
}

@MainActor
private final class ManifestCompletingFirstPlantSync: PendingFirstPlantSyncing {
    let pendingStore: PendingFirstPlantStore
    let accountID: String
    let expectedPlantID: UUID
    private(set) var payloads: [SyncMutationPayload] = []
    private(set) var completionAcknowledged: Bool?

    init(
        pendingStore: PendingFirstPlantStore,
        accountID: String,
        expectedPlantID: UUID
    ) {
        self.pendingStore = pendingStore
        self.accountID = accountID
        self.expectedPlantID = expectedPlantID
    }

    func enqueue(_ payload: SyncMutationPayload, isConnected: Bool) async -> Bool {
        payloads.append(payload)
        if payloads.count == 2 {
            completionAcknowledged = try? await pendingStore.complete(
                for: accountID,
                expectedPlantID: expectedPlantID
            )
        }
        return true
    }
}

@MainActor
final class PendingFirstPlantStoreTests: XCTestCase {
    func testProtectedDraftRoundTripsDetailsAndPhotoWithoutExposingAPath() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = PendingFirstPlantStore(rootURL: fixture.pendingRoot)

        let staged = try await store.stage(
            scanID: fixture.scanID,
            mediaDraft: fixture.mediaDraft,
            analysis: fixture.analysis
        )
        let updated = try await store.updateDetails(
            nickname: "  Monty  ",
            location: "Living room",
            lightPlacement: .bright
        )

        XCTAssertEqual(updated.plantID, staged.plantID)
        XCTAssertEqual(updated.scanID, fixture.scanID)
        XCTAssertEqual(updated.mediaID, fixture.mediaDraft.id)
        XCTAssertEqual(updated.nickname, "Monty")
        XCTAssertEqual(updated.location, "Living room")
        XCTAssertEqual(updated.lightPlacement, .bright)
        let stagedPhoto = try await store.photoData()
        XCTAssertEqual(stagedPhoto, fixture.photoData)

        // A fresh actor proves the value came back from the versioned manifest,
        // not from state retained by the first instance.
        let relaunched = PendingFirstPlantStore(rootURL: fixture.pendingRoot)
        let restoredDraft = try await relaunched.load()
        let restoredPhoto = try await relaunched.photoData()
        XCTAssertEqual(restoredDraft, updated)
        XCTAssertEqual(restoredPhoto, fixture.photoData)
    }

    func testClaimIsAccountScopedAndMaterializationIsContentIdempotent() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = PendingFirstPlantStore(rootURL: fixture.pendingRoot)
        let accountID = "first-owner-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: AccountStorage.mediaRootURL(for: accountID)) }
        _ = try await store.stage(
            scanID: fixture.scanID,
            mediaDraft: fixture.mediaDraft,
            analysis: fixture.analysis,
            nickname: "Monty",
            location: "Lounge"
        )

        let stagedValue = try await store.load()
        let staged = try XCTUnwrap(stagedValue)
        let unclaimedCandidate = try await store.recoveryCandidate(for: accountID)
        XCTAssertEqual(unclaimedCandidate, .unclaimed(staged.plantID))
        do {
            _ = try await store.materialize(
                for: accountID,
                expectedPlantID: UUID()
            )
            XCTFail("A returning or unrelated session must not claim an unmarked handoff")
        } catch let error as PendingFirstPlantError {
            XCTAssertEqual(error, .unexpectedPlant)
        }
        let firstValue = try await store.materialize(
            for: accountID,
            expectedPlantID: staged.plantID
        )
        let replayValue = try await store.materialize(
            for: accountID,
            expectedPlantID: staged.plantID
        )
        let first = try XCTUnwrap(firstValue)
        let replay = try XCTUnwrap(replayValue)

        XCTAssertEqual(first.draft, replay.draft)
        XCTAssertEqual(first.historyPhotoURL, replay.historyPhotoURL)
        XCTAssertEqual(try Data(contentsOf: first.historyPhotoURL), fixture.photoData)
        let claimedCandidate = try await store.recoveryCandidate(for: accountID)
        XCTAssertEqual(claimedCandidate, .claimedByAccount(staged.plantID))
        do {
            _ = try await store.materialize(
                for: "different-owner-\(UUID().uuidString)",
                expectedPlantID: staged.plantID
            )
            XCTFail("A claimed handoff must never cross accounts")
        } catch let error as PendingFirstPlantError {
            XCTAssertEqual(error, .claimedByAnotherAccount)
        }

        do {
            _ = try await store.loadUnclaimed()
            XCTFail("Signed-out UI must not receive a claimed draft")
        } catch let error as PendingFirstPlantError {
            XCTAssertEqual(error, .alreadyClaimed)
        }
        do {
            _ = try await store.photoData()
            XCTFail("Signed-out UI must not receive a claimed draft's photo bytes")
        } catch let error as PendingFirstPlantError {
            XCTAssertEqual(error, .alreadyClaimed)
        }
        do {
            _ = try await store.complete(
                for: accountID,
                expectedPlantID: UUID()
            )
            XCTFail("Cleanup must name the exact claimed plant")
        } catch let error as PendingFirstPlantError {
            XCTAssertEqual(error, .unexpectedPlant)
        }
        let retainedAfterWrongCleanup = try await store.load()
        XCTAssertNotNil(retainedAfterWrongCleanup)
        do {
            _ = try await store.complete(
                for: "different-owner-\(UUID().uuidString)",
                expectedPlantID: staged.plantID
            )
            XCTFail("Cleanup must be performed by the account that claimed the plant")
        } catch let error as PendingFirstPlantError {
            XCTAssertEqual(error, .claimedByAnotherAccount)
        }
        let firstCleanup = try await store.complete(
            for: accountID,
            expectedPlantID: staged.plantID
        )
        let replayedCleanup = try await store.complete(
            for: accountID,
            expectedPlantID: staged.plantID
        )
        XCTAssertTrue(firstCleanup)
        XCTAssertFalse(replayedCleanup, "An already-absent manifest is a safe cleanup replay")
    }

    func testExplicitRecoveryCanDiscardAnUnclaimedManifestButNotAnotherAccountsClaim() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = PendingFirstPlantStore(rootURL: fixture.pendingRoot)
        let staged = try await store.stage(
            scanID: fixture.scanID,
            mediaDraft: fixture.mediaDraft,
            analysis: fixture.analysis
        )

        let discarded = try await store.discardRecoverable(
            for: "recovering-\(UUID().uuidString)",
            expectedPlantID: staged.plantID
        )
        XCTAssertTrue(discarded)
        let emptyStore = try await store.load()
        XCTAssertNil(emptyStore)

        let claimed = try await store.stage(
            scanID: UUID(),
            mediaDraft: fixture.mediaDraft,
            analysis: fixture.analysis
        )
        let owner = "owner-\(UUID().uuidString)"
        _ = try await store.materialize(for: owner, expectedPlantID: claimed.plantID)
        do {
            _ = try await store.discardRecoverable(
                for: "different-\(UUID().uuidString)",
                expectedPlantID: claimed.plantID
            )
            XCTFail("A different account must not discard a claimed recovery handoff")
        } catch let error as PendingFirstPlantError {
            XCTAssertEqual(error, .claimedByAnotherAccount)
        }
        let retainedClaim = try await store.load()
        XCTAssertNotNil(retainedClaim)
    }

    func testARescanReplacesAnUnclaimedDraftWhosePhotoWasLost() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = PendingFirstPlantStore(rootURL: fixture.pendingRoot)
        _ = try await store.stage(
            scanID: fixture.scanID,
            mediaDraft: fixture.mediaDraft,
            analysis: fixture.analysis
        )
        try FileManager.default.removeItem(
            at: fixture.pendingRoot.appendingPathComponent("\(fixture.mediaDraft.id.uuidString).jpg")
        )

        do {
            _ = try await store.load()
            XCTFail("The missing protected copy should invalidate the old handoff")
        } catch let error as PendingFirstPlantError {
            XCTAssertEqual(error, .missingPhoto)
        }

        let replacementScanID = UUID()
        let replacement = try await store.stage(
            scanID: replacementScanID,
            mediaDraft: fixture.mediaDraft,
            analysis: fixture.analysis
        )

        XCTAssertEqual(replacement.scanID, replacementScanID)
        let replacementPhoto = try await store.photoData()
        XCTAssertEqual(replacementPhoto, fixture.photoData)
    }

    func testOwnerScopedSignOutCleanupLetsTheNextOnboardingStageWithoutExposingTheClaim() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = PendingFirstPlantStore(rootURL: fixture.pendingRoot)
        let owner = "owner-\(UUID().uuidString)"
        let staged = try await store.stage(
            scanID: fixture.scanID,
            mediaDraft: fixture.mediaDraft,
            analysis: fixture.analysis
        )
        _ = try await store.materialize(for: owner, expectedPlantID: staged.plantID)

        do {
            try await store.discardClaimed(for: "different-\(UUID().uuidString)")
            XCTFail("A different account must not remove the claimed handoff")
        } catch let error as PendingFirstPlantError {
            XCTAssertEqual(error, .claimedByAnotherAccount)
        }
        do {
            _ = try await store.loadUnclaimed()
            XCTFail("Signed-out onboarding must not read a claimed handoff")
        } catch let error as PendingFirstPlantError {
            XCTAssertEqual(error, .alreadyClaimed)
        }

        try await store.discardClaimed(for: owner)
        let cleared = try await store.loadUnclaimed()
        XCTAssertNil(cleared)

        let replacement = try await store.stage(
            scanID: UUID(),
            mediaDraft: fixture.mediaDraft,
            analysis: fixture.analysis
        )
        XCTAssertNotEqual(replacement.plantID, staged.plantID)
    }

    func testImporterPersistsAndQueuesExactlyOnceBeforeAcknowledgingDraft() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let pending = PendingFirstPlantStore(rootURL: fixture.pendingRoot)
        let suiteName = "PendingFirstPlantImport-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let session = UserSession(
            accountID: UUID().uuidString,
            mode: .apple,
            displayName: "Ari"
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: AccountStorage.mediaRootURL(for: session.accountID))
        }
        let draft = try await pending.stage(
            scanID: fixture.scanID,
            mediaDraft: fixture.mediaDraft,
            analysis: fixture.analysis,
            nickname: "Monty",
            location: "Living room",
            lightPlacement: .bright
        )
        let store = GroveStore(plants: [], persistenceEnabled: true, storage: defaults)
        store.activate(session: session)
        let sync = RecordingFirstPlantSync(results: [true, true])

        let returningOutcome = await PendingFirstPlantImporter(pendingStore: pending).importIfNeeded(
            session: session,
            expectedPlantID: nil,
            store: store,
            syncEngine: sync,
            isConnected: false
        )
        XCTAssertEqual(returningOutcome, .noPendingDraft)
        let draftAfterReturningSkip = try await pending.load()
        XCTAssertNotNil(draftAfterReturningSkip)
        XCTAssertTrue(sync.payloads.isEmpty)

        let outcome = await PendingFirstPlantImporter(pendingStore: pending).importIfNeeded(
            session: session,
            expectedPlantID: draft.plantID,
            store: store,
            syncEngine: sync,
            isConnected: false
        )

        XCTAssertEqual(outcome, .imported(draft.plantID))
        XCTAssertEqual(store.plants.map(\.id), [draft.plantID])
        XCTAssertEqual(store.scanHistory.map(\.id), [draft.scanID])
        XCTAssertEqual(store.scanHistory.first?.plantID, draft.plantID)
        XCTAssertTrue(store.hasPersistedFirstPlant(plantID: draft.plantID, scanID: draft.scanID))
        let pendingAfterImport = try await pending.load()
        XCTAssertNil(pendingAfterImport)
        XCTAssertEqual(sync.payloads.count, 2)
        guard case .uploadMedia(let upload) = sync.payloads[0],
              case .createPlant(let create) = sync.payloads[1] else {
            return XCTFail("The photo must be queued before its plant")
        }
        XCTAssertEqual(upload.localMediaID, draft.mediaID)
        XCTAssertEqual(create.clientPlantID, draft.plantID)
        XCTAssertEqual(create.mediaDraftID, draft.mediaID)
        XCTAssertEqual(try Data(contentsOf: upload.fileURL), fixture.photoData)

        let recoverySync = RecordingFirstPlantSync(results: [])
        let recoveryOutcome = await PendingFirstPlantImporter(pendingStore: pending).importIfNeeded(
            session: session,
            expectedPlantID: draft.plantID,
            store: store,
            syncEngine: recoverySync,
            isConnected: false
        )
        XCTAssertEqual(recoveryOutcome, .alreadyImported(draft.plantID))
        XCTAssertTrue(recoverySync.payloads.isEmpty)
    }

    func testDeferredQueueAcceptanceReplaysWithoutDuplicatingLocalPlantOrCare() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let pending = PendingFirstPlantStore(rootURL: fixture.pendingRoot)
        let suiteName = "PendingFirstPlantReplay-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let session = UserSession(
            accountID: UUID().uuidString,
            mode: .google,
            displayName: "Ari"
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: AccountStorage.mediaRootURL(for: session.accountID))
        }
        let draft = try await pending.stage(
            scanID: fixture.scanID,
            mediaDraft: fixture.mediaDraft,
            analysis: fixture.analysis,
            nickname: "Monty",
            location: "Living room"
        )
        let store = GroveStore(plants: [], persistenceEnabled: true, storage: defaults)
        store.activate(session: session)
        let firstSync = RecordingFirstPlantSync(results: [true, false])
        let importer = PendingFirstPlantImporter(pendingStore: pending)

        let firstOutcome = await importer.importIfNeeded(
            session: session,
            expectedPlantID: draft.plantID,
            store: store,
            syncEngine: firstSync,
            isConnected: false
        )
        XCTAssertEqual(
            firstOutcome,
            .deferred(draft.plantID, localCopyIsDurable: true)
        )
        let careIDsAfterFirstAttempt = Set(store.tasks.filter { $0.plantID == draft.plantID }.map(\.id))
        let retainedDraft = try await pending.load()
        XCTAssertNotNil(retainedDraft, "A failed queue acknowledgement must retain the handoff")

        let replaySync = RecordingFirstPlantSync(results: [true, true])
        let replayOutcome = await importer.importIfNeeded(
            session: session,
            expectedPlantID: draft.plantID,
            store: store,
            syncEngine: replaySync,
            isConnected: false
        )
        XCTAssertEqual(replayOutcome, .imported(draft.plantID))

        XCTAssertEqual(store.plants.filter { $0.id == draft.plantID }.count, 1)
        XCTAssertEqual(store.scanHistory.filter { $0.id == draft.scanID }.count, 1)
        XCTAssertEqual(
            Set(store.tasks.filter { $0.plantID == draft.plantID }.map(\.id)),
            careIDsAfterFirstAttempt,
            "A replay must not mint a second check-in or soil-check task"
        )
        let pendingAfterReplay = try await pending.load()
        XCTAssertNil(pendingAfterReplay)
    }

    func testImporterDoesNotAcknowledgeBeforeTheAccountSnapshotIsDurable() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let pending = PendingFirstPlantStore(rootURL: fixture.pendingRoot)
        let session = UserSession(
            accountID: UUID().uuidString,
            mode: .apple,
            displayName: "Ari"
        )
        defer { try? FileManager.default.removeItem(at: AccountStorage.mediaRootURL(for: session.accountID)) }
        let draft = try await pending.stage(
            scanID: fixture.scanID,
            mediaDraft: fixture.mediaDraft,
            analysis: fixture.analysis
        )
        let store = GroveStore(plants: [], persistenceEnabled: false)
        store.activate(session: session)
        let sync = RecordingFirstPlantSync(results: [true, true])
        let importer = PendingFirstPlantImporter(
            pendingStore: pending,
            localDurabilityCheck: { _, _, _ in false }
        )

        let outcome = await importer.importIfNeeded(
            session: session,
            expectedPlantID: draft.plantID,
            store: store,
            syncEngine: sync,
            isConnected: true
        )

        XCTAssertEqual(
            outcome,
            .deferred(draft.plantID, localCopyIsDurable: false)
        )
        XCTAssertTrue(sync.payloads.isEmpty)
        let retainedDraft = try await pending.load()
        XCTAssertEqual(retainedDraft?.plantID, draft.plantID)
    }

    func testConcurrentManifestAcknowledgementCannotRegressToMissingDraft() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let pending = PendingFirstPlantStore(rootURL: fixture.pendingRoot)
        let suiteName = "PendingFirstPlantConcurrent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let session = UserSession(
            accountID: UUID().uuidString,
            mode: .google,
            displayName: "Ari"
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: AccountStorage.mediaRootURL(for: session.accountID))
        }
        let draft = try await pending.stage(
            scanID: fixture.scanID,
            mediaDraft: fixture.mediaDraft,
            analysis: fixture.analysis
        )
        let store = GroveStore(plants: [], persistenceEnabled: true, storage: defaults)
        store.activate(session: session)
        let sync = ManifestCompletingFirstPlantSync(
            pendingStore: pending,
            accountID: session.accountID,
            expectedPlantID: draft.plantID
        )

        let outcome = await PendingFirstPlantImporter(pendingStore: pending).importIfNeeded(
            session: session,
            expectedPlantID: draft.plantID,
            store: store,
            syncEngine: sync,
            isConnected: true
        )

        XCTAssertEqual(sync.completionAcknowledged, true)
        XCTAssertEqual(outcome, .alreadyImported(draft.plantID))
        XCTAssertTrue(store.hasPersistedFirstPlant(plantID: draft.plantID, scanID: draft.scanID))
        let pendingAfterCompetingCompletion = try await pending.load()
        XCTAssertNil(pendingAfterCompetingCompletion)
    }

    func testMutationQueueDeduplicatesStableMediaAndPlantIDsAcrossRelaunch() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let queueURL = fixture.root.appendingPathComponent("Sync/mutations.json")
        let media = PendingMediaUpload(
            localMediaID: fixture.mediaDraft.id,
            fileURL: fixture.mediaDraft.fileURL,
            purpose: .scan,
            mimeType: "image/jpeg",
            pixelWidth: fixture.mediaDraft.pixelWidth,
            pixelHeight: fixture.mediaDraft.pixelHeight
        )
        let plantID = UUID()
        let create = CreatePlantRequest(
            clientPlantID: plantID,
            nickname: "Monty",
            location: "Living room",
            analysis: fixture.analysis,
            mediaDraftID: fixture.mediaDraft.id
        )
        let first = MutationQueueStore(fileURL: queueURL)
        let firstMedia = try await first.enqueue(.uploadMedia(media))
        let firstPlant = try await first.enqueue(.createPlant(create))

        let relaunched = MutationQueueStore(fileURL: queueURL)
        let replayedMedia = try await relaunched.enqueue(.uploadMedia(media))
        let replayedPlant = try await relaunched.enqueue(.createPlant(create))

        XCTAssertEqual(firstMedia.id, replayedMedia.id)
        XCTAssertEqual(firstPlant.id, replayedPlant.id)
        let replayedQueue = await relaunched.all()
        XCTAssertEqual(replayedQueue.count, 2)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingFirstPlantTests-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let mediaID = UUID()
        let sourceURL = sourceRoot.appendingPathComponent("\(mediaID.uuidString).jpg")
        let photoData = Data((0..<4_096).map { UInt8($0 % 251) })
        try photoData.write(to: sourceURL, options: .atomic)
        let mediaDraft = ScanMediaDraft(
            id: mediaID,
            mode: .add,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            fileURL: sourceURL,
            pixelWidth: 900,
            pixelHeight: 1_200,
            stage: .wholePlant,
            qualityWarnings: []
        )
        return Fixture(
            root: root,
            pendingRoot: root.appendingPathComponent("Pending", isDirectory: true),
            scanID: UUID(),
            mediaDraft: mediaDraft,
            analysis: Self.analysis,
            photoData: photoData
        )
    }

    private static let analysis = PlantAnalysisResult(
        identification: PlantIdentificationResult(
            commonName: "Monstera",
            scientificName: "Monstera deliciosa",
            confidence: 94,
            alternatives: [],
            distinguishingTraits: ["Split leaves"]
        ),
        condition: PlantConditionResult(
            healthScore: 84,
            healthBand: .healthy,
            confidence: 88,
            summary: "Healthy baseline",
            positiveSigns: ["Firm stems"],
            concerns: [],
            possibleCauses: [],
            nextActions: ["Check the soil before watering"],
            followUpDays: 12
        ),
        providerName: "Test",
        limitations: ["Visual assessment only"]
    )

    private struct Fixture {
        let root: URL
        let pendingRoot: URL
        let scanID: UUID
        let mediaDraft: ScanMediaDraft
        let analysis: PlantAnalysisResult
        let photoData: Data

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
