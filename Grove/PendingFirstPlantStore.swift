import CryptoKit
import Foundation

/// The value-bearing part of onboarding, kept outside any account until the
/// person has proved where it should live.
///
/// IDs are minted when the result is staged, not during import. Replaying the
/// handoff after a kill therefore names the same plant, scan and media asset at
/// every local and remote boundary.
struct PendingFirstPlantDraft: Codable, Hashable, Sendable {
    let plantID: UUID
    let scanID: UUID
    let mediaID: UUID
    let capturedAt: Date
    let analysis: PlantAnalysisResult
    var nickname: String
    var location: String
    var lightPlacement: PlantLightPlacement?
    let pixelWidth: Int
    let pixelHeight: Int

    fileprivate let photoFilename: String
    fileprivate let photoSHA256: String
    fileprivate var claimedAccountNamespace: String?
}

enum PendingFirstPlantError: LocalizedError, Equatable {
    case invalidPhoto
    case missingPhoto
    case corruptDraft
    case unsupportedVersion
    case alreadyClaimed
    case claimedByAnotherAccount
    case unexpectedPlant
    case couldNotSave

    var errorDescription: String? {
        switch self {
        case .invalidPhoto: "The first plant photo is not readable."
        case .missingPhoto: "The first plant photo is no longer on this iPhone."
        case .corruptDraft: "Grove couldn't read the saved first plant."
        case .unsupportedVersion: "This first plant draft was made by a newer version of Grove."
        case .alreadyClaimed: "This first plant is already being saved to an account."
        case .claimedByAnotherAccount: "This first plant belongs to a different signed-in account."
        case .unexpectedPlant: "This sign-in did not create the saved first plant."
        case .couldNotSave: "Grove couldn't safely save the first plant on this iPhone."
        }
    }
}

struct PendingFirstPlantMaterialization: Sendable {
    let draft: PendingFirstPlantDraft
    let historyPhotoURL: URL
}

/// The only ownership information recovery UI needs. An unclaimed scan still
/// requires the signed-in person's confirmation; a claimed scan can be resumed
/// automatically, but only by the account namespace already written into its
/// protected manifest.
enum PendingFirstPlantRecoveryCandidate: Equatable, Sendable {
    case unclaimed(UUID)
    case claimedByAccount(UUID)

    var plantID: UUID {
        switch self {
        case .unclaimed(let id), .claimedByAccount(let id): id
        }
    }
}

/// Protected, versioned storage for the one plant that crosses the sign-in
/// boundary.
///
/// The manifest stores a relative photo name rather than an app-container URL,
/// so an iOS container relocation cannot strand the handoff. The photo is
/// written before the manifest and the manifest is removed before the photo;
/// a kill can therefore leave an unreferenced file, but never a live manifest
/// pointing at a deliberately deleted file.
actor PendingFirstPlantStore {
    static let shared = PendingFirstPlantStore()

    private static let currentVersion = 1
    private let rootURL: URL
    private let manifestURL: URL

    init(rootURL: URL? = nil) {
        let resolvedRoot: URL
        if let rootURL {
            resolvedRoot = rootURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            resolvedRoot = applicationSupport
                .appendingPathComponent("Grove/Onboarding/FirstPlant", isDirectory: true)
        }
        self.rootURL = resolvedRoot
        manifestURL = resolvedRoot.appendingPathComponent("pending-first-plant-v1.json")
    }

    /// Stages a result before authentication. Re-staging the same scan (for
    /// example after a retake or a form edit) keeps its plant id stable.
    @discardableResult
    func stage(
        scanID: UUID,
        mediaDraft: ScanMediaDraft,
        analysis: PlantAnalysisResult,
        nickname: String? = nil,
        location: String? = nil,
        lightPlacement: PlantLightPlacement? = nil
    ) throws -> PendingFirstPlantDraft {
        guard mediaDraft.mode == .add else { throw PendingFirstPlantError.invalidPhoto }

        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: mediaDraft.fileURL)
        } catch {
            throw PendingFirstPlantError.missingPhoto
        }
        guard !sourceData.isEmpty else { throw PendingFirstPlantError.invalidPhoto }

        let existing: PendingFirstPlantDraft?
        do {
            existing = try loadIfPresent(validatePhoto: true)
        } catch PendingFirstPlantError.missingPhoto,
                PendingFirstPlantError.corruptDraft {
            // Recovery already routes an unowned handoff back to capture. Let a
            // fresh, valid photo replace media that can no longer be delivered;
            // otherwise every rescan hits the same damaged manifest forever.
            // A readable claimed manifest remains protected from replacement.
            if let readable = try? loadIfPresent(validatePhoto: false),
               readable.claimedAccountNamespace != nil {
                throw PendingFirstPlantError.alreadyClaimed
            }
            do {
                try FileManager.default.removeItem(at: rootURL)
            } catch CocoaError.fileNoSuchFile {
                // Nothing remains to recover; continue with the new capture.
            } catch {
                throw PendingFirstPlantError.couldNotSave
            }
            existing = nil
        }
        if existing?.claimedAccountNamespace != nil {
            throw PendingFirstPlantError.alreadyClaimed
        }

        let plantID = existing?.scanID == scanID ? existing!.plantID : UUID()
        let photoFilename = "\(mediaDraft.id.uuidString).jpg"
        let photoURL = rootURL.appendingPathComponent(photoFilename)
        let checksum = Self.sha256(sourceData)
        let resolvedNickname = Self.nonEmpty(
            nickname ?? (analysis.identification.isUnknown == true ? "Unknown plant" : analysis.identification.commonName),
            fallback: "Unknown plant"
        )
        let resolvedLocation = Self.nonEmpty(location ?? "Unassigned", fallback: "Unassigned")
        let draft = PendingFirstPlantDraft(
            plantID: plantID,
            scanID: scanID,
            mediaID: mediaDraft.id,
            capturedAt: mediaDraft.createdAt,
            analysis: analysis,
            nickname: resolvedNickname,
            location: resolvedLocation,
            lightPlacement: lightPlacement,
            pixelWidth: mediaDraft.pixelWidth,
            pixelHeight: mediaDraft.pixelHeight,
            photoFilename: photoFilename,
            photoSHA256: checksum,
            claimedAccountNamespace: nil
        )

        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try sourceData.write(
                to: photoURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            try persist(draft)
            if let oldFilename = existing?.photoFilename, oldFilename != photoFilename {
                try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(oldFilename))
            }
            return draft
        } catch let error as PendingFirstPlantError {
            throw error
        } catch {
            throw PendingFirstPlantError.couldNotSave
        }
    }

    /// Persists the form fields without touching the protected photo.
    @discardableResult
    func updateDetails(
        nickname: String,
        location: String,
        lightPlacement: PlantLightPlacement?
    ) throws -> PendingFirstPlantDraft {
        guard var draft = try loadIfPresent(validatePhoto: true) else {
            throw PendingFirstPlantError.corruptDraft
        }
        guard draft.claimedAccountNamespace == nil else {
            throw PendingFirstPlantError.alreadyClaimed
        }
        draft.nickname = Self.nonEmpty(nickname, fallback: draft.nickname)
        draft.location = Self.nonEmpty(location, fallback: "Unassigned")
        draft.lightPlacement = lightPlacement
        try persist(draft)
        return draft
    }

    func load() throws -> PendingFirstPlantDraft? {
        try loadIfPresent(validatePhoto: true)
    }

    /// Signed-out onboarding may inspect only a neutral draft. A handoff that
    /// has been claimed belongs exclusively to its account recovery flow and
    /// must never drive signed-out navigation or presentation.
    func loadUnclaimed() throws -> PendingFirstPlantDraft? {
        guard let draft = try loadIfPresent(validatePhoto: true) else { return nil }
        guard draft.claimedAccountNamespace == nil else {
            throw PendingFirstPlantError.alreadyClaimed
        }
        return draft
    }

    /// Finds a handoff whose old session marker was lost without exposing its
    /// photo or botanical details across an account boundary.
    ///
    /// Claimed manifests are returned only to their recorded owner. Neutral
    /// manifests are reported as unclaimed so the signed-in UI can ask before
    /// attaching them; a returning account must never silently inherit a scan
    /// made before authentication.
    func recoveryCandidate(for accountID: String) throws -> PendingFirstPlantRecoveryCandidate? {
        guard let draft = try loadIfPresent(validatePhoto: true) else { return nil }
        guard let claimed = draft.claimedAccountNamespace else {
            return .unclaimed(draft.plantID)
        }
        guard claimed == AccountStorage.namespace(for: accountID) else {
            throw PendingFirstPlantError.claimedByAnotherAccount
        }
        return .claimedByAccount(draft.plantID)
    }

    /// A path-free preview for paywall/auth UI. The same checksum validation as
    /// import runs before any bytes leave the actor, so callers never render a
    /// stale or partially-written handoff photo.
    func photoData() throws -> Data? {
        guard let draft = try loadIfPresent(validatePhoto: true) else { return nil }
        guard draft.claimedAccountNamespace == nil else {
            throw PendingFirstPlantError.alreadyClaimed
        }
        let data: Data
        do {
            data = try Data(contentsOf: rootURL.appendingPathComponent(draft.photoFilename))
        } catch {
            throw PendingFirstPlantError.missingPhoto
        }
        guard Self.sha256(data) == draft.photoSHA256 else {
            throw PendingFirstPlantError.corruptDraft
        }
        return data
    }

    /// Claims and copies the photo into durable account-scoped history. The
    /// history copy is also the upload source, so clearing the neutral handoff
    /// cannot break an offline mutation waiting in the sync queue.
    func materialize(
        for accountID: String,
        expectedPlantID: UUID
    ) throws -> PendingFirstPlantMaterialization? {
        guard var draft = try loadIfPresent(validatePhoto: true) else { return nil }
        guard draft.plantID == expectedPlantID else {
            throw PendingFirstPlantError.unexpectedPlant
        }
        let accountNamespace = AccountStorage.namespace(for: accountID)
        if let claimed = draft.claimedAccountNamespace, claimed != accountNamespace {
            throw PendingFirstPlantError.claimedByAnotherAccount
        }
        if draft.claimedAccountNamespace == nil {
            draft.claimedAccountNamespace = accountNamespace
            try persist(draft)
        }

        let sourceURL = rootURL.appendingPathComponent(draft.photoFilename)
        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: sourceURL)
        } catch {
            throw PendingFirstPlantError.missingPhoto
        }
        guard Self.sha256(sourceData) == draft.photoSHA256 else {
            throw PendingFirstPlantError.corruptDraft
        }

        let historyRoot = AccountStorage.mediaRootURL(for: accountID)
            .appendingPathComponent("ScanHistory", isDirectory: true)
        let historyURL = historyRoot.appendingPathComponent("\(draft.scanID.uuidString).jpg")
        do {
            try FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: historyURL.path) {
                let existing = try Data(contentsOf: historyURL)
                guard Self.sha256(existing) == draft.photoSHA256 else {
                    throw PendingFirstPlantError.corruptDraft
                }
            } else {
                try sourceData.write(
                    to: historyURL,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            }
            return PendingFirstPlantMaterialization(draft: draft, historyPhotoURL: historyURL)
        } catch let error as PendingFirstPlantError {
            throw error
        } catch {
            throw PendingFirstPlantError.couldNotSave
        }
    }

    /// Acknowledges a handoff only for the account that claimed it. The account
    /// history copy is intentionally retained; it is the user's baseline and
    /// may still be the source of an offline upload. Returns false when no
    /// neutral manifest remains, making cleanup safe to replay after a kill.
    @discardableResult
    func complete(for accountID: String, expectedPlantID: UUID) throws -> Bool {
        // Materialization already verified and copied the bytes. Completion is
        // an acknowledgement, so a separately-lost neutral source must not
        // leave an otherwise durable handoff wedged forever.
        guard let draft = try loadIfPresent(validatePhoto: false) else { return false }
        guard draft.plantID == expectedPlantID else {
            throw PendingFirstPlantError.unexpectedPlant
        }
        let accountNamespace = AccountStorage.namespace(for: accountID)
        guard draft.claimedAccountNamespace == accountNamespace else {
            throw PendingFirstPlantError.claimedByAnotherAccount
        }
        do {
            try FileManager.default.removeItem(at: manifestURL)
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(draft.photoFilename))
            return true
        } catch {
            throw PendingFirstPlantError.couldNotSave
        }
    }

    /// Explicitly abandons a handoff that the current session was authorized
    /// to receive. Unlike `complete`, this also accepts a still-neutral
    /// manifest: materialization can fail before writing its account claim, and
    /// the recovery screen must still be able to honour "continue without it".
    /// A manifest claimed by another account remains untouchable.
    @discardableResult
    func discardRecoverable(for accountID: String, expectedPlantID: UUID) throws -> Bool {
        guard let draft = try loadIfPresent(validatePhoto: false) else { return false }
        guard draft.plantID == expectedPlantID else {
            throw PendingFirstPlantError.unexpectedPlant
        }
        if let claimed = draft.claimedAccountNamespace,
           claimed != AccountStorage.namespace(for: accountID) {
            throw PendingFirstPlantError.claimedByAnotherAccount
        }
        do {
            try FileManager.default.removeItem(at: manifestURL)
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(draft.photoFilename))
            return true
        } catch {
            throw PendingFirstPlantError.couldNotSave
        }
    }

    /// Used when an unclaimed onboarding attempt is explicitly abandoned.
    func discardUnclaimed() throws {
        guard let draft = try loadIfPresent(validatePhoto: false) else { return }
        guard draft.claimedAccountNamespace == nil else {
            throw PendingFirstPlantError.alreadyClaimed
        }
        do {
            try FileManager.default.removeItem(at: manifestURL)
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(draft.photoFilename))
        } catch {
            throw PendingFirstPlantError.couldNotSave
        }
    }

    /// Removes a stale claimed handoff before its owning account signs out.
    /// The durable account photo is retained; only the neutral cross-account
    /// receipt is removed. Ownership is derived from the live account id, so a
    /// later account can neither inspect nor discard somebody else's receipt.
    func discardClaimed(for accountID: String) throws {
        guard let draft = try loadIfPresent(validatePhoto: false) else { return }
        let accountNamespace = AccountStorage.namespace(for: accountID)
        guard let claimed = draft.claimedAccountNamespace else { return }
        guard claimed == accountNamespace else {
            throw PendingFirstPlantError.claimedByAnotherAccount
        }
        do {
            try FileManager.default.removeItem(at: manifestURL)
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(draft.photoFilename))
        } catch {
            throw PendingFirstPlantError.couldNotSave
        }
    }

    /// Part of Settings' device-wide "delete everything" promise. Unlike the
    /// onboarding cancel action, this intentionally removes a claimed handoff
    /// too: no account photo or recovery receipt may survive that operation.
    func deleteAllLocalData() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func loadIfPresent(validatePhoto: Bool) throws -> PendingFirstPlantDraft? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw PendingFirstPlantError.corruptDraft
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw PendingFirstPlantError.corruptDraft
        }
        guard envelope.version == Self.currentVersion else {
            throw PendingFirstPlantError.unsupportedVersion
        }
        // The filename is derived, never user-controlled. Re-derive it on read
        // so a damaged manifest cannot escape the protected handoff directory.
        guard envelope.draft.photoFilename == "\(envelope.draft.mediaID.uuidString).jpg",
              envelope.draft.photoSHA256.count == 64,
              envelope.draft.pixelWidth > 0,
              envelope.draft.pixelHeight > 0 else {
            throw PendingFirstPlantError.corruptDraft
        }
        if validatePhoto {
            let photoURL = rootURL.appendingPathComponent(envelope.draft.photoFilename)
            guard let photo = try? Data(contentsOf: photoURL) else {
                throw PendingFirstPlantError.missingPhoto
            }
            guard !photo.isEmpty, Self.sha256(photo) == envelope.draft.photoSHA256 else {
                throw PendingFirstPlantError.corruptDraft
            }
        }
        return envelope.draft
    }

    private func persist(_ draft: PendingFirstPlantDraft) throws {
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(
                Envelope(version: Self.currentVersion, draft: draft)
            )
            try data.write(
                to: manifestURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            throw PendingFirstPlantError.couldNotSave
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func nonEmpty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private struct Envelope: Codable {
        let version: Int
        let draft: PendingFirstPlantDraft
    }
}

@MainActor
protocol PendingFirstPlantSyncing: AnyObject {
    func enqueue(_ payload: SyncMutationPayload, isConnected: Bool) async -> Bool
}

extension SyncEngine: PendingFirstPlantSyncing {}

enum PendingFirstPlantImportOutcome: Equatable {
    case noPendingDraft
    case imported(UUID)
    case importedLocally(UUID)
    /// The manifest was acknowledged in an earlier process, but that process
    /// died before consuming the session's one-shot marker, or another
    /// concurrent replay won that same acknowledgement race.
    case alreadyImported(UUID)
    /// The one-shot marker must remain in place until a replay can finish.
    /// `localCopyIsDurable` distinguishes a failed account snapshot from a
    /// durable local baseline whose queue or neutral-manifest acknowledgement
    /// still needs another attempt.
    case deferred(UUID, localCopyIsDurable: Bool)
    case claimedByAnotherAccount
    case failed
}

/// Coordinates the account-side half of the handoff. Every operation is safe
/// to replay: account photo materialization verifies content, `GroveStore`
/// reuses the stable plant id, scan history replaces by scan id, and the sync
/// queue deduplicates the stable media/plant mutations.
@MainActor
struct PendingFirstPlantImporter {
    let pendingStore: PendingFirstPlantStore
    private let localDurabilityCheck: @MainActor (GroveStore, UUID, UUID) -> Bool

    init(
        pendingStore: PendingFirstPlantStore = .shared,
        localDurabilityCheck: @escaping @MainActor (GroveStore, UUID, UUID) -> Bool = {
            store,
            plantID,
            scanID in
            store.hasPersistedFirstPlant(plantID: plantID, scanID: scanID)
        }
    ) {
        self.pendingStore = pendingStore
        self.localDurabilityCheck = localDurabilityCheck
    }

    func importIfNeeded(
        session: UserSession,
        expectedPlantID: UUID?,
        store: GroveStore,
        syncEngine: any PendingFirstPlantSyncing,
        isConnected: Bool
    ) async -> PendingFirstPlantImportOutcome {
        // Only the session established by this exact onboarding completion may
        // claim the neutral draft. Returning sign-in and an account switch both
        // carry no marker and leave it untouched.
        guard let expectedPlantID else { return .noPendingDraft }
        let materialization: PendingFirstPlantMaterialization
        do {
            guard let staged = try await pendingStore.materialize(
                for: session.accountID,
                expectedPlantID: expectedPlantID
            ) else {
                return hasDurablyImportedPlant(expectedPlantID, store: store)
                    ? .alreadyImported(expectedPlantID)
                    : .noPendingDraft
            }
            materialization = staged
        } catch PendingFirstPlantError.claimedByAnotherAccount {
            return .claimedByAnotherAccount
        } catch {
            GroveDiag.log("first plant handoff could not be materialized: \(error.localizedDescription)")
            return .failed
        }

        let draft = materialization.draft
        _ = store.addPlant(
            id: draft.plantID,
            nickname: draft.nickname,
            location: draft.location,
            lightPlacement: draft.lightPlacement,
            analysis: draft.analysis
        )
        store.recordScan(
            id: draft.scanID,
            mode: .add,
            result: draft.analysis,
            photoURL: materialization.historyPhotoURL,
            plantID: draft.plantID,
            createdAt: draft.capturedAt
        )
        guard localDurabilityCheck(store, draft.plantID, draft.scanID) else {
            return .deferred(draft.plantID, localCopyIsDurable: false)
        }

        // A local-only account has no remote queue by design. Its durable local
        // snapshot and history copy are the complete handoff.
        if !session.mode.isSupabaseBacked {
            do {
                let acknowledged = try await pendingStore.complete(
                    for: session.accountID,
                    expectedPlantID: draft.plantID
                )
                return acknowledged ? .importedLocally(draft.plantID) : .alreadyImported(draft.plantID)
            } catch {
                return .deferred(draft.plantID, localCopyIsDurable: true)
            }
        }

        let media = PendingMediaUpload(
            localMediaID: draft.mediaID,
            fileURL: materialization.historyPhotoURL,
            purpose: .scan,
            mimeType: "image/jpeg",
            pixelWidth: draft.pixelWidth,
            pixelHeight: draft.pixelHeight
        )
        let create = CreatePlantRequest(
            clientPlantID: draft.plantID,
            nickname: draft.nickname,
            location: draft.location,
            analysis: draft.analysis,
            mediaDraftID: draft.mediaID,
            plant: store.plant(id: draft.plantID)
        )

        guard await syncEngine.enqueue(.uploadMedia(media), isConnected: isConnected) else {
            return .deferred(draft.plantID, localCopyIsDurable: true)
        }
        guard await syncEngine.enqueue(.createPlant(create), isConnected: isConnected) else {
            return .deferred(draft.plantID, localCopyIsDurable: true)
        }
        do {
            let acknowledged = try await pendingStore.complete(
                for: session.accountID,
                expectedPlantID: draft.plantID
            )
            return acknowledged ? .imported(draft.plantID) : .alreadyImported(draft.plantID)
        } catch {
            // The IDs make a later replay harmless; retaining the manifest is
            // safer than pretending the acknowledgement reached disk.
            return .deferred(draft.plantID, localCopyIsDurable: true)
        }
    }

    private func hasDurablyImportedPlant(_ plantID: UUID, store: GroveStore) -> Bool {
        store.scanHistory
            .filter { $0.plantID == plantID }
            .contains { scan in
                localDurabilityCheck(store, plantID, scan.id)
            }
    }
}
