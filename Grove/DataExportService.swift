import Foundation

struct GroveExportedMedia: Codable, Equatable, Sendable {
    let originalURL: URL
    let mimeType: String
    let base64Data: String
}

struct GroveDataExport: Codable, Sendable {
    let schemaVersion: Int
    let exportedAt: Date
    let profile: UserProfile
    let plants: [Plant]
    let tasks: [CareTask]
    let observations: [PlantObservation]
    let diagnoses: [PlantDiagnosis]
    let collections: [PlantCollection]
    let scanHistory: [ScanHistoryRecord]
    let assignments: [SittingAssignment]
    /// Link metadata is account data; bearer URLs are credentials and are
    /// intentionally excluded from a portable plaintext export.
    let sittingInvites: [SittingInvite]
    let activity: [ActivityEvent]
    let friends: [PlantFriend]
    let friendInvitations: [FriendInvitation]
    let gardener: GardenerProgress
    /// Conversations with Ari. Optional so exports written before schema 3
    /// still decode.
    var askThreads: [BotanistThread]? = nil
    var media: [GroveExportedMedia]
}

enum DataExportError: LocalizedError {
    case couldNotCreate

    var errorDescription: String? {
        "Grove couldn't prepare your export. Free up some storage and try again."
    }
}

@MainActor
final class LocalDataExportService {
    private let outputDirectory: URL

    init(outputDirectory: URL? = nil) {
        self.outputDirectory = outputDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("GroveExports", isDirectory: true)
    }

    /// Snapshots the account graph on the main actor, then reads, base64-encodes
    /// and writes the payload off it. A Grove with a season of check-in photos
    /// carries tens of megabytes of media: doing that work inline froze the UI
    /// for as long as it took, and the caller's progress state never had a
    /// chance to render.
    func export(store: GroveStore, storage: UserDefaults = .standard) async throws -> URL {
        // Settings promises a copy of everything Grove holds. Ari
        // conversations and the profile photo were missing, and the Ask
        // transcripts are some of the most personal data on the phone. A
        // plant's cover is its newest check-in or scan photo, both included.
        let askThreads = store.activeAccountID.map {
            AskSession.storedThreads(accountID: $0, storage: storage)
        } ?? []
        var mediaURLs = Set<URL>()
        mediaURLs.formUnion(store.observations.compactMap(\.photoURL))
        mediaURLs.formUnion(store.scanHistory.compactMap(\.photoURL))
        mediaURLs.formUnion(store.diagnoses.compactMap(\.photoURL))
        for thread in askThreads {
            mediaURLs.formUnion(thread.messages.compactMap(\.photoURL))
        }
        if let avatar = store.profile.avatarPhotoURL { mediaURLs.insert(avatar) }
        let payload = GroveDataExport(
            schemaVersion: 3,
            exportedAt: .now,
            profile: store.profile,
            plants: store.plants,
            tasks: store.tasks,
            observations: store.observations,
            diagnoses: store.diagnoses,
            collections: store.collections,
            scanHistory: store.scanHistory,
            assignments: store.assignments,
            sittingInvites: store.sittingInvites.map { invite in
                var tokenFree = invite
                tokenFree.shareURL = nil
                return tokenFree
            },
            activity: store.activity,
            friends: store.friends,
            friendInvitations: store.friendInvitations,
            gardener: store.gardener,
            askThreads: askThreads,
            media: []
        )
        let directory = outputDirectory
        let mediaToCopy = mediaURLs
        return try await Task.detached(priority: .userInitiated) {
            try Self.write(payload, mediaURLs: mediaToCopy, to: directory)
        }.value
    }

    /// Deletes every prepared export. "Delete all local Grove data" has to
    /// reach these too: an export is a plaintext copy of the whole account
    /// graph, photos included, sitting in the temporary directory.
    func removePreparedExports() {
        try? FileManager.default.removeItem(at: outputDirectory)
    }

    private nonisolated static func write(
        _ payload: GroveDataExport,
        mediaURLs: Set<URL>,
        to directory: URL
    ) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            removeOldExports(in: directory)

            var payload = payload
            payload.media = mediaURLs.compactMap { url -> GroveExportedMedia? in
                // Remote (server-restored) photos are not this phone's to embed;
                // stored paths may name a previous install's container.
                guard url.isFileURL,
                      let data = try? Data(contentsOf: GroveMediaPath.resolved(url) ?? url) else { return nil }
                return GroveExportedMedia(originalURL: url, mimeType: "image/jpeg", base64Data: data.base64EncodedString())
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            let fileURL = directory.appendingPathComponent("Grove-data-\(Int(Date.now.timeIntervalSince1970)).json")
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return fileURL
        } catch {
            throw DataExportError.couldNotCreate
        }
    }

    private nonisolated static func removeOldExports(in outputDirectory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .distantPast
        for file in files {
            let createdAt = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if createdAt < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}
