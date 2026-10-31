import Foundation
import Network
import Observation

enum SyncMutationPayload: Codable {
    case uploadMedia(PendingMediaUpload)
    case createPlant(CreatePlantRequest)
    case createCheckIn(CreateCheckInRequest)
    case updatePlant(UpdatePlantRequest)
    case deletePlant(DeletePlantRequest)
    case createCareEvent(CreateCareEventRequest)
    case deleteCareEvent(DeleteCareEventRequest)
    case createSittingAssignment(CreateSittingRequest)
    /// Only the revoke half of link sitting is queued. Minting a link is
    /// interactive — the user is waiting to read the URL out loud — so it is
    /// called directly and fails in front of them; pulling one back must
    /// happen whether or not the app is still open, so it queues.
    case revokeSittingInvite(RevokeSittingInviteRequest)
    /// Kept for invitations queued by older builds, which sent them optimistically.
    /// Nothing enqueues this now: an invitation is only real once the server has
    /// found the gardener, so `SyncEngine.sendFriendInvitation` waits for it.
    case createFriendInvitation(CreateFriendInvitationRequest)
    case respondToFriendInvitation(RespondToFriendInvitationRequest)
    case withdrawFriendInvitation(WithdrawFriendInvitationRequest)
    case updateCareTask(CareTaskMutationRequest)
    case updateProfile(UpdateProfileRequest)
    case updateGardenerProgress(UpdateGardenerProgressRequest)
}

extension SyncMutationPayload {
    var changesFriendships: Bool {
        switch self {
        case .createFriendInvitation, .respondToFriendInvitation, .withdrawFriendInvitation: true
        default: false
        }
    }

    /// True when both payloads are retries of the same durable client-side
    /// operation. These identifiers are also the server's idempotency boundary;
    /// using them here keeps a relaunch from filling the local queue with copies
    /// before the server ever sees the first one.
    func replays(_ other: SyncMutationPayload) -> Bool {
        switch (self, other) {
        case let (.uploadMedia(queued), .uploadMedia(replayed)):
            queued.localMediaID == replayed.localMediaID
        case let (.createPlant(queued), .createPlant(replayed)):
            queued.clientPlantID == replayed.clientPlantID
        case let (.deletePlant(queued), .deletePlant(replayed)):
            queued.plantID == replayed.plantID
        case let (.createCareEvent(queued), .createCareEvent(replayed)):
            queued.task.id == replayed.task.id
        case let (.deleteCareEvent(queued), .deleteCareEvent(replayed)):
            queued.taskID == replayed.taskID
        case let (.updateProfile(queued), .updateProfile(replayed)):
            queued.clientRequestID == replayed.clientRequestID
        case let (.updateGardenerProgress(queued), .updateGardenerProgress(replayed)):
            // A relaunch can rediscover the same not-yet-acknowledged local
            // snapshot. Its timestamp is the semantic revision; do not fill
            // the durable queue with new request ids for identical state.
            queued.updatedAt == replayed.updatedAt
        default:
            false
        }
    }

    /// Whether a 404 from the server means "already settled here" rather than
    /// "something went wrong". For these, the device's copy is the answer and a
    /// missing server record is not worth stopping the queue over.
    ///
    /// Exhaustive on purpose: a new mutation has to decide this deliberately
    /// rather than inherit a default that silently discards a user's change.
    var isLocallyAuthoritative: Bool {
        switch self {
        // Withdrawing joins these: the row is gone from this device either way,
        // and a server that never had it is already in the state being asked for.
        case .updatePlant, .deletePlant, .deleteCareEvent, .updateCareTask,
             .respondToFriendInvitation, .withdrawFriendInvitation: true
        case .uploadMedia, .createPlant, .createCheckIn, .createCareEvent, .createSittingAssignment,
             .createFriendInvitation, .updateProfile, .updateGardenerProgress: false
        case .revokeSittingInvite: true
        }
    }

    /// The records this change is about. Two changes that share a key must
    /// reach the server in the order they were made: an edit or a delete that
    /// overtakes its plant's create is answered 404 (and let go) or 200 (and
    /// the create then resurrects the plant), and two edits out of order leave
    /// the older one standing. A check-in or new plant also waits on the photo
    /// upload it names, which shares the media id.
    var orderingKeys: [String] {
        switch self {
        case .uploadMedia(let pending):
            ["media:\(pending.localMediaID)"]
        case .createPlant(let request):
            ["plant:\(request.clientPlantID)", "media:\(request.mediaDraftID)"]
        case .createCheckIn(let request):
            ["plant:\(request.plantID)"] + (request.mediaDraftID.map { ["media:\($0)"] } ?? [])
        case .updatePlant(let request):
            ["plant:\(request.plant.id)"]
        case .deletePlant(let request):
            ["plant:\(request.plantID)"]
        case .createCareEvent(let request):
            ["plant:\(request.task.plantID)", "task:\(request.task.id)"]
        case .deleteCareEvent(let request):
            ["task:\(request.taskID)"]
        case .updateCareTask(let request):
            ["task:\(request.taskID)"]
        case .createSittingAssignment(let request):
            request.plantIDs.map { "plant:\($0)" }
        case .revokeSittingInvite(let request):
            ["invite:\(request.inviteID)"]
        case .createFriendInvitation, .respondToFriendInvitation, .withdrawFriendInvitation:
            ["friendships"]
        case .updateProfile:
            ["profile"]
        case .updateGardenerProgress:
            ["gardener"]
        }
    }
}

/// What the queue still owes the server, in the terms a bootstrap needs to
/// avoid undoing it. A snapshot fetched while a change is waiting describes
/// the server *before* that change, so the records it touches keep their
/// local copy until it lands.
struct PendingSyncChanges {
    /// Plants with an unsent create, edit or check-in.
    var plantIDs: Set<UUID> = []
    /// Plants deleted here whose delete has not reached the server.
    var deletedPlantIDs: Set<UUID> = []
    /// Tasks with an unsent create or completion.
    var taskIDs: Set<UUID> = []
    /// Logged care undone here whose delete has not reached the server.
    var deletedTaskIDs: Set<UUID> = []
    var profile = false
    var friendships = false
    var sittingAssignments = false

    static let none = PendingSyncChanges()

    init() {}

    init(_ mutations: [QueuedMutation]) {
        for mutation in mutations {
            switch mutation.payload {
            case .uploadMedia, .revokeSittingInvite, .updateGardenerProgress:
                // The photo has no record of its own to protect; a pending
                // revoke is already carried by `revocationRequestedAt`; the
                // Journey document is merged, never swapped.
                break
            case .createPlant(let request): plantIDs.insert(request.clientPlantID)
            case .createCheckIn(let request): plantIDs.insert(request.plantID)
            case .updatePlant(let request): plantIDs.insert(request.plant.id)
            case .deletePlant(let request): deletedPlantIDs.insert(request.plantID)
            case .createCareEvent(let request): taskIDs.insert(request.task.id)
            case .deleteCareEvent(let request): deletedTaskIDs.insert(request.taskID)
            case .updateCareTask(let request): taskIDs.insert(request.taskID)
            case .createSittingAssignment: sittingAssignments = true
            case .createFriendInvitation, .respondToFriendInvitation, .withdrawFriendInvitation:
                friendships = mutation.payload.changesFriendships
            case .updateProfile: profile = true
            }
        }
    }
}

enum QueuedMutationState: String, Codable {
    case pending
    case retrying
    /// Written only by builds that parked a failed change and asked the user to
    /// go and retry it by hand. Kept so those queues still decode; anything
    /// carrying it is healed back to `pending` on load. Never written again.
    case needsAttention
}

struct QueuedMutation: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    var payload: SyncMutationPayload
    var attemptCount: Int
    var nextAttemptAt: Date
    var state: QueuedMutationState
    var lastError: String?
}

actor MutationQueueStore {
    private let fileURL: URL
    private var mutations: [QueuedMutation]

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = base.appendingPathComponent("Grove/Sync/mutations.json")
        }

        if let data = try? Data(contentsOf: self.fileURL) {
            // Decoded one entry at a time. A single change this build cannot
            // read (a newer build's payload, after a downgrade) used to fail
            // the whole array, and the next write then replaced every queued
            // change with nothing. The original bytes are kept beside the
            // queue before anything can overwrite them.
            let decoded = (try? JSONDecoder.grove.decode([LossyQueuedMutation].self, from: data)) ?? []
            let readable = decoded.compactMap(\.mutation)
            if readable.count != decoded.count || (decoded.isEmpty && !Self.isEmptyArray(data)) {
                Self.backUpUnreadableQueue(data, beside: self.fileURL)
            }
            // Anything parked by an older build is put back in the queue at the
            // front of the line. Those changes have been sitting behind a banner
            // waiting for a tap that most people never gave it; the first launch
            // on this build is the moment they finally get another go.
            mutations = readable.map { mutation in
                guard mutation.state == .needsAttention else { return mutation }
                var healed = mutation
                healed.state = .pending
                healed.attemptCount = 0
                healed.nextAttemptAt = .now
                healed.lastError = nil
                return healed
            }
        } else {
            mutations = []
        }
    }

    private static func isEmptyArray(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "[]"
    }

    private static func backUpUnreadableQueue(_ data: Data, beside fileURL: URL) {
        let stamp = Int(Date.now.timeIntervalSince1970)
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("mutations.unreadable-\(stamp).json")
        try? data.write(to: backup, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        GroveDiag.log("sync queue had unreadable entries; original kept at \(backup.lastPathComponent)")
    }

    func all() -> [QueuedMutation] {
        mutations.sorted { $0.createdAt < $1.createdAt }
    }

    func enqueue(_ payload: SyncMutationPayload) throws -> QueuedMutation {
        // Durable handoffs are deliberately read without being consumed, then
        // acknowledged only after this file accepts their mutations. A kill in
        // between replays the same semantic id. Reuse the queued entry so
        // closing that kill window does not open a duplicate-queue window.
        if let existing = mutations.first(where: { $0.payload.replays(payload) }) {
            return existing
        }
        let mutation = QueuedMutation(
            id: UUID(),
            createdAt: .now,
            payload: payload,
            attemptCount: 0,
            nextAttemptAt: .now,
            state: .pending,
            lastError: nil
        )
        // Disk first, memory second, for every change below. A caller told
        // the write failed must be able to trust that nothing was queued, and
        // a delivered change whose removal failed must still be in memory so
        // this session and the next launch agree on it.
        try persist(mutations + [mutation])
        mutations.append(mutation)
        return mutation
    }

    func remove(id: UUID) throws {
        try persist(mutations.filter { $0.id != id })
        mutations.removeAll { $0.id == id }
    }

    func replace(_ mutation: QueuedMutation) throws {
        guard let index = mutations.firstIndex(where: { $0.id == mutation.id }) else { return }
        var updated = mutations
        updated[index] = mutation
        try persist(updated)
        mutations = updated
    }

    func clear() throws {
        try persist([])
        mutations = []
    }

    private func persist(_ mutations: [QueuedMutation]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.grove.encode(mutations)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// One queue entry that decodes to nil instead of failing the whole array.
private struct LossyQueuedMutation: Decodable {
    let mutation: QueuedMutation?

    init(from decoder: Decoder) throws {
        mutation = try? QueuedMutation(from: decoder)
    }
}

/// Where the queue currently stands. Diagnostic only, and deliberately so:
/// nothing in Grove draws sync status, because a gardener has no use for one.
/// The queue's job is to finish without being watched.
///
/// `needsAttention` survives for the two bootstrap refusals below, which stop
/// Grove replacing a real grove with a snapshot it does not trust. Delivering a
/// queued change never produces it — a change either lands, waits, or is let go.
enum SyncState: Equatable {
    case localOnly
    case idle
    case offline
    case syncing
    case upToDate
    case needsAttention(message: String)
}

/// What a failed delivery means for the change that caused it.
private enum DeliveryVerdict {
    /// Nothing is wrong with the change; the network or the server is having a
    /// moment. Back off and come back to it, for days if that is what it takes.
    case retry
    /// It can never land. The server already has it, has never heard of what it
    /// points at, or refuses it outright — the same answer waits at the end of
    /// every replay, so stop asking. The plant, check-in or photo it describes
    /// is already saved on this iPhone and is not touched.
    case letGo
    /// There is no session to send it under. That is not the change's fault and
    /// not worth burning an attempt over: hold the whole queue until a token
    /// comes back, which `SessionService` refreshes on foreground and on
    /// reconnect.
    case waitForSignIn
}

@MainActor
@Observable
final class ConnectivityMonitor {
    private(set) var isConnected = true

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.grove.connectivity")

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isConnected = connected
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

@MainActor
@Observable
final class SyncEngine {
    /// How long a change keeps trying before Grove accepts it is never going to
    /// land. A week outlives every outage worth waiting through, and the record
    /// itself is on the phone either way — what expires is the attempt to
    /// mirror it, not the plant.
    private static let deliveryWindow: TimeInterval = 7 * 24 * 60 * 60

    /// After this many failures against a live connection, the queue stops
    /// letting one change hold the rest hostage and moves on, coming back to it
    /// on the next pass.
    private static let attemptsBeforeSkipping = 3

    private(set) var state: SyncState
    private(set) var pendingCount = 0

    private var queueStore: MutationQueueStore
    private let repository: (any GroveRemoteRepository)?
    private let mediaUploader: (any MediaUploading)?
    private let managesAccountQueue: Bool
    private(set) var activeAccountID: String?
    /// Advances before the per-account queue changes. Any suspended delivery or
    /// bootstrap carrying an older value may finish its network request, but it
    /// may not touch the new account's local state.
    private var accountGeneration = 0
    /// Advances after any server mutation succeeds. A bootstrap captures this
    /// before it leaves; if the value changes while it is in flight, its
    /// response predates an action such as Accept or Remove and must not apply.
    private var serverStateRevision = 0

    /// Whether the *current account* may sync. The backend client exists for
    /// every build, but demo/guest accounts have no server identity, so they
    /// stay local-only even though a repository is configured.
    private let accountEligibility: (@MainActor () -> Bool)?

    /// A repository the active account is allowed to use.
    private var syncRepository: (any GroveRemoteRepository)? {
        guard accountEligibility?() ?? true else { return nil }
        return repository
    }

    init(
        queueStore: MutationQueueStore? = nil,
        repository: (any GroveRemoteRepository)? = nil,
        mediaUploader: (any MediaUploading)? = nil,
        accountEligibility: (@MainActor () -> Bool)? = nil
    ) {
        self.queueStore = queueStore ?? MutationQueueStore()
        self.repository = repository
        self.mediaUploader = mediaUploader
        self.accountEligibility = accountEligibility
        managesAccountQueue = queueStore == nil
        state = repository == nil ? .localOnly : .idle
    }

    func activate(accountID: String) async {
        guard activeAccountID != accountID else { return }
        accountGeneration += 1
        activeAccountID = accountID
        if managesAccountQueue {
            let fileURL = AccountStorage.mediaRootURL(for: accountID)
                .appendingPathComponent("Sync", isDirectory: true)
                .appendingPathComponent("mutations.json")
            queueStore = MutationQueueStore(fileURL: fileURL)
        }
        // The previous account's timer must not fire against this one's queue.
        retryTask?.cancel()
        retryTask = nil
        await refreshCount()
        state = syncRepository == nil ? .localOnly : pendingCount == 0 ? .upToDate : .idle
    }

    func start() async {
        await refreshCount()
    }

    /// Called when the app comes back to the front. A backoff timer set before
    /// the phone went in a pocket cannot be relied on to have fired, and coming
    /// back is also the moment a refreshed token turns up, so every return to
    /// Grove is a fresh attempt at whatever is still waiting.
    func resume(isConnected: Bool) async {
        guard pendingCount > 0 else { return }
        await processPending(isConnected: isConnected)
    }

    /// Mints a sitting link, right now, in front of the user.
    ///
    /// Deliberately not queued: a link is worthless until the URL comes back,
    /// so there is nothing useful to do with a "we'll send it later" — the
    /// screen has to be able to say it did not work.
    func createSittingInvite(_ request: CreateSittingInviteRequest) async throws -> SittingInviteLink {
        guard let syncRepository else {
            throw APIError.validation("Sitting links need an account that syncs. Sign in to make one.")
        }
        return try await performActiveAccountMutation {
            try await syncRepository.createSittingInvite(request)
        }
    }

    /// Revokes immediately while the owner is watching. A missing row already
    /// satisfies the security outcome; network failures remain queueable by the
    /// caller without pretending the server has confirmed them.
    func revokeSittingInvite(_ request: RevokeSittingInviteRequest) async throws {
        guard let syncRepository else {
            throw APIError.validation("Sitting links need an account that syncs. Sign in to revoke this one.")
        }
        do {
            try await performActiveAccountMutation {
                try await syncRepository.revokeSittingInvite(request)
            }
        } catch APIError.notFound {
            return
        }
    }

    /// Creates an account-based handover while the owner is still on screen.
    /// Unlike an ordinary offline-first edit, this is not useful until the
    /// server has verified the friendship and plant scope and has made the
    /// invitation visible to the other account.
    func createSittingAssignment(_ request: CreateSittingRequest) async throws -> SittingAssignment {
        guard let syncRepository else {
            throw APIError.validation("In-app handovers need an account that syncs. Sign in and try again.")
        }
        return try await performActiveAccountMutation {
            try await syncRepository.createSittingAssignment(request)
        }
    }

    func respondToSittingAssignment(_ request: RespondToSittingAssignmentRequest) async throws -> SittingAssignment {
        guard let syncRepository else {
            throw APIError.validation("Sitting invitations need an account that syncs. Sign in and try again.")
        }
        return try await performActiveAccountMutation {
            try await syncRepository.respondToSittingAssignment(request)
        }
    }

    func revokeSittingAssignment(_ request: RevokeSittingAssignmentRequest) async throws -> SittingAssignment {
        guard let syncRepository else {
            throw APIError.validation("In-app handovers need an account that syncs. Sign in and try again.")
        }
        return try await performActiveAccountMutation {
            try await syncRepository.revokeSittingAssignment(request)
        }
    }

    /// Sitter care is useful only after the server has re-checked the active
    /// assignment window and permission, so it is confirmed online before the
    /// dashboard changes locally.
    func completeSittingTask(_ request: CareTaskMutationRequest) async throws -> CareTask {
        guard let syncRepository else {
            throw APIError.validation("Sitter care needs an account that syncs. Sign in and try again.")
        }
        return try await performActiveAccountMutation {
            try await syncRepository.updateCareTask(request)
        }
    }

    /// Sends a friend invitation and waits for the answer.
    ///
    /// Deliberately not queued. Only the server knows whether that username
    /// belongs to anyone, so queuing this meant the app showed a Pending row for
    /// a handle nobody had claimed and buried the refusal in the sync issues
    /// list. The person is standing right there: let them hear "no such
    /// gardener" while they can still fix the spelling or share a link instead.
    func sendFriendInvitation(_ request: CreateFriendInvitationRequest) async throws -> FriendInvitation {
        guard let syncRepository else {
            throw APIError.validation("Invitations need an account that syncs. Sign in and try again.")
        }
        return try await performActiveAccountMutation {
            try await syncRepository.createFriendInvitation(request)
        }
    }

    /// Answers a friend request while its card is still visible. Online
    /// callers wait for this before changing the local friend list, so a
    /// request withdrawn or answered on another device cannot manufacture a
    /// friendship on this iPhone. The queue remains available to explicit
    /// offline decisions.
    func respondToFriendInvitation(_ request: RespondToFriendInvitationRequest) async throws {
        guard let syncRepository else {
            throw APIError.validation("Friend requests need an account that syncs. Sign in and try again.")
        }
        try await performActiveAccountMutation {
            try await syncRepository.respondToFriendInvitation(request)
        }
    }

    /// Cancels a sent request while it is still visible. As with responding,
    /// online callers commit locally only after the server confirms ownership
    /// and the pending state; offline callers retain the durable queue path.
    func withdrawFriendInvitation(_ request: WithdrawFriendInvitationRequest) async throws {
        guard let syncRepository else {
            throw APIError.validation("Friend requests need an account that syncs. Sign in and try again.")
        }
        try await performActiveAccountMutation {
            try await syncRepository.withdrawFriendInvitation(request)
        }
    }

    /// Removes a trusted connection only after the server has ended the pair
    /// and revoked any legacy account delegation. This is intentionally not an
    /// optimistic edit: revoking access is too important to merely look done.
    func removeFriend(_ request: RemoveFriendRequest) async throws {
        guard let syncRepository else {
            throw APIError.validation("Removing a friend needs an account that syncs. Sign in and try again.")
        }
        try await performActiveAccountMutation {
            try await syncRepository.removeFriend(request)
        }
    }

    /// Blocks a connection only after the server has committed the safety
    /// boundary. This is intentionally online-only: the UI must never claim a
    /// person is blocked while their account can still contact this one.
    func blockFriend(_ request: BlockFriendRequest) async throws {
        guard let syncRepository else {
            throw APIError.validation("Blocking needs an account that syncs. Sign in and try again.")
        }
        try await performActiveAccountMutation {
            try await syncRepository.blockFriend(request)
        }
    }

    /// Reports and blocks in one server transaction, so a submitted safety
    /// concern never leaves the reporter exposed while another request catches up.
    func reportFriend(_ request: ReportFriendRequest) async throws {
        guard let syncRepository else {
            throw APIError.validation("Reporting needs an account that syncs. Sign in and try again.")
        }
        try await performActiveAccountMutation {
            try await syncRepository.reportFriend(request)
        }
    }

    private func performActiveAccountMutation<T>(_ operation: () async throws -> T) async throws -> T {
        let expectedAccountID = activeAccountID
        let generation = accountGeneration
        let result = try await GroveAPIRequestScope.$expectedAccountID.withValue(expectedAccountID) {
            try await operation()
        }
        // The server may have completed account A's request just as the app
        // switched to B. Do not hand that success to A's old view, whose next
        // line would otherwise edit B's now-active GroveStore.
        guard generation == accountGeneration,
              activeAccountID == expectedAccountID else { throw CancellationError() }
        serverStateRevision &+= 1
        return result
    }

    @discardableResult
    func enqueue(_ payload: SyncMutationPayload, isConnected: Bool) async -> Bool {
        guard syncRepository != nil else {
            state = .localOnly
            return false
        }
        do {
            _ = try await queueStore.enqueue(payload)
            serverStateRevision &+= 1
            await refreshCount()
            if syncRepository == nil {
                state = .localOnly
            } else if isConnected {
                await processPending(isConnected: true)
            } else {
                state = .offline
            }
            return true
        } catch {
            state = .needsAttention(message: "Saved on this device, but Grove couldn't add it to the sync queue.")
            return false
        }
    }

    /// Reentrancy guard: `processPending` suspends at every network await, and
    /// its entry points overlap (enqueue, connectivity flips, manual sync).
    /// Without coalescing, two interleaved runs read the same queue snapshot
    /// and deliver the same mutation twice.
    private var isProcessing = false
    private var needsAnotherPass = false
    /// Snapshot fetches also suspend. Coalesce overlapping foreground, reconnect
    /// and pull-to-refresh calls so an older response can never apply after a
    /// newer one and roll friend state backwards.
    private var isSynchronizing = false
    private var needsAnotherSynchronization = false
    private var latestSynchronizationConnectivity = true

    /// The backoff alarm. One at a time: the queue is delivered in order, so
    /// there is only ever one next moment worth waking up for.
    private var retryTask: Task<Void, Never>?

    /// Whether the last pass stopped for want of a session. A timer would only
    /// hammer the server with the same missing bearer, so waiting for sign-in
    /// deliberately schedules nothing and leans on `resume(isConnected:)`.
    private var isWaitingForSignIn = false

    /// What the app last told the engine about the network, so a timer that
    /// fires with no caller to ask still makes the right call.
    private var lastKnownConnectivity = true

    func processPending(isConnected: Bool) async {
        lastKnownConnectivity = isConnected
        guard syncRepository != nil else {
            state = .localOnly
            await refreshCount()
            return
        }
        guard isConnected else {
            state = .offline
            return
        }
        if isProcessing {
            needsAnotherPass = true
            return
        }
        isProcessing = true
        let generation = accountGeneration
        let scopedQueueStore = queueStore
        let expectedAccountID = activeAccountID
        repeat {
            needsAnotherPass = false
            await drainQueue(
                from: scopedQueueStore,
                expectedAccountID: expectedAccountID,
                generation: generation
            )
        } while needsAnotherPass && generation == accountGeneration
        isProcessing = false
        // `activate` may have replaced the queue while this pass was awaiting a
        // response. Give the new account the pass a reentrant call requested.
        if generation != accountGeneration {
            await processPending(isConnected: lastKnownConnectivity)
            return
        }
        await scheduleNextPass()
    }

    /// Walks the queue once, oldest change first.
    ///
    /// Every exit from here is a state Grove can get itself out of. A change
    /// either lands and leaves the queue, or is let go because replaying it can
    /// only fail the same way, or is put back with a later time to try again —
    /// and `scheduleNextPass` guarantees something comes back for it. Nothing is
    /// ever parked waiting for a person to notice a badge and press retry.
    private func drainQueue(
        from scopedQueueStore: MutationQueueStore,
        expectedAccountID: String?,
        generation: Int
    ) async {
        guard let repository = syncRepository else { return }
        state = .syncing
        var stalled = false
        isWaitingForSignIn = false
        let mutations = await scopedQueueStore.all()
        // Records with a change still waiting earlier in the queue. Anything
        // later that touches one of them waits its turn behind it (see
        // `orderingKeys`); changes about other records step around it rather
        // than being held up.
        var blockedKeys = Set<String>()
        // Whether a plant create is still waiting ahead of the current change.
        // A completion for one of its starting tasks is a 404 until it lands,
        // and that 404 must not be read as "already settled".
        var plantCreateIsWaiting = false
        func holdBack(_ mutation: QueuedMutation) {
            blockedKeys.formUnion(mutation.payload.orderingKeys)
            if case .createPlant = mutation.payload { plantCreateIsWaiting = true }
        }
        delivery: for var mutation in mutations {
            guard generation == accountGeneration else { break delivery }
            guard blockedKeys.isDisjoint(with: mutation.payload.orderingKeys) else {
                holdBack(mutation)
                stalled = true
                continue
            }
            guard mutation.nextAttemptAt <= .now else {
                holdBack(mutation)
                stalled = true
                continue
            }
            do {
                try await GroveAPIRequestScope.$expectedAccountID.withValue(expectedAccountID) {
                    try await send(mutation.payload, repository: repository, mediaUploader: mediaUploader)
                }
                serverStateRevision &+= 1
                // The request belonged to the captured account even if the UI
                // switched while it was in flight, so acknowledge only that
                // account's captured queue.
                try await scopedQueueStore.remove(id: mutation.id)
                guard generation == accountGeneration else { break delivery }
            } catch let error as APIError {
                guard generation == accountGeneration else { break delivery }
                switch verdict(
                    for: error,
                    payload: mutation.payload,
                    plantCreateIsWaiting: plantCreateIsWaiting
                ) {
                case .letGo:
                    await letGo(mutation, from: scopedQueueStore, reason: error)
                    continue
                case .waitForSignIn:
                    // Untouched on purpose: no attempt burned, no backoff. The
                    // queue simply waits for a bearer, which arrives on the next
                    // foreground or reconnect.
                    state = .idle
                    stalled = true
                    isWaitingForSignIn = true
                    break delivery
                case .retry:
                    guard Date.now.timeIntervalSince(mutation.createdAt) < Self.deliveryWindow else {
                        await letGo(mutation, from: scopedQueueStore, reason: error)
                        continue
                    }
                    mutation.attemptCount += 1
                    mutation.lastError = error.localizedDescription
                    mutation.state = .retrying
                    mutation.nextAttemptAt = retryDate(attempt: mutation.attemptCount)
                    try? await scopedQueueStore.replace(mutation)
                    stalled = true
                    if error.stopsWholeQueue || mutation.attemptCount < Self.attemptsBeforeSkipping {
                        // A dead network fails every change identically, so
                        // there is nothing to learn from walking the rest of the
                        // queue. Past the attempt ceiling the failure is
                        // probably about this one record, and the rest deserve
                        // their turn.
                        state = error.stopsWholeQueue ? .offline : .idle
                        break delivery
                    }
                    // Changes about other records go on; this record's later
                    // changes wait for it.
                    holdBack(mutation)
                }
            } catch {
                guard generation == accountGeneration else { break delivery }
                guard Date.now.timeIntervalSince(mutation.createdAt) < Self.deliveryWindow else {
                    await letGo(mutation, from: scopedQueueStore, reason: error)
                    continue
                }
                mutation.attemptCount += 1
                mutation.lastError = error.localizedDescription
                mutation.state = .retrying
                mutation.nextAttemptAt = retryDate(attempt: mutation.attemptCount)
                try? await scopedQueueStore.replace(mutation)
                state = .offline
                stalled = true
                break delivery
            }
        }

        guard generation == accountGeneration else { return }
        await refreshCount()
        if pendingCount == 0 {
            state = .upToDate
        } else if !stalled {
            state = .idle
        }
    }

    /// Drops a change Grove has decided will never land, and says so where a
    /// support conversation can find it. Only the queued *delivery* goes: the
    /// plant, check-in or photo it describes was written to this iPhone before
    /// it was ever queued and stays exactly where it is.
    private func letGo(
        _ mutation: QueuedMutation,
        from scopedQueueStore: MutationQueueStore,
        reason: Error
    ) async {
        try? await scopedQueueStore.remove(id: mutation.id)
        let name = mutation.payload.analyticsName
        let cause = (reason as? APIError).map(\.analyticsReason) ?? "unknown"
        GroveDiag.log("sync dropped \(name) after \(mutation.attemptCount + 1) attempts: \(cause)")
        Task {
            await GroveAnalytics.shared.record(
                "sync_change_dropped",
                ["change": name, "reason": cause, "attempts": String(mutation.attemptCount + 1)]
            )
        }
    }

    private func verdict(
        for error: APIError,
        payload: SyncMutationPayload,
        plantCreateIsWaiting: Bool
    ) -> DeliveryVerdict {
        switch error {
        // A task completion carries no plant id, so ordering cannot hold it
        // behind its plant's create. While any create is still waiting, its
        // 404 may only mean "not created yet".
        case .notFound where plantCreateIsWaiting && payload.isCareTaskUpdate:
            .retry
        case .unauthorised:
            .waitForSignIn
        // A conflict is the server saying it already has this — every queued
        // request carries a client id, so the duplicate is the proof it landed.
        // Forbidden and validation are refusals that a replay cannot argue with.
        case .conflict, .forbidden, .validation:
            .letGo
        case .notFound:
            // For a care task or an invitation answer, a missing server record
            // is the state being asked for, so the change is already true. For
            // everything else a 404 is more likely a route that has not shipped
            // yet than a record that never existed, and a deploy can still land
            // inside the delivery window.
            payload.isLocallyAuthoritative ? .letGo : .retry
        case .offline, .timedOut, .transport, .rateLimited, .server, .invalidResponse, .invalidURL:
            .retry
        }
    }

    /// Sets the alarm for the next attempt, so a queue that is waiting is not
    /// waiting on the user opening a screen. Backgrounded, this may not fire —
    /// `resume(isConnected:)` covers the return to the app.
    private func scheduleNextPass() async {
        retryTask?.cancel()
        retryTask = nil
        guard syncRepository != nil, !isWaitingForSignIn else { return }
        let waiting = await queueStore.all()
        // A change held behind an earlier one for the same record cannot go
        // before that one does, however long ago its own time came. Waking
        // for it would only walk the queue every second to skip it again.
        var keyReadyAt: [String: Date] = [:]
        let readyTimes = waiting.map { mutation -> Date in
            let keys = mutation.payload.orderingKeys
            let ready = keys.compactMap { keyReadyAt[$0] }.reduce(mutation.nextAttemptAt, max)
            for key in keys { keyReadyAt[key] = max(keyReadyAt[key] ?? ready, ready) }
            return ready
        }
        guard let next = readyTimes.min() else { return }
        let delay = max(next.timeIntervalSinceNow, 1)
        let isConnected = lastKnownConnectivity
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.processPending(isConnected: isConnected)
        }
    }

    func synchronize(store: GroveStore, isConnected: Bool) async {
        latestSynchronizationConnectivity = isConnected
        if isSynchronizing {
            needsAnotherSynchronization = true
            return
        }
        isSynchronizing = true
        repeat {
            needsAnotherSynchronization = false
            await synchronizeOnce(
                store: store,
                isConnected: latestSynchronizationConnectivity
            )
        } while needsAnotherSynchronization
        isSynchronizing = false
    }

    private func synchronizeOnce(store: GroveStore, isConnected: Bool) async {
        guard let repository = syncRepository else {
            state = .localOnly
            await refreshCount()
            return
        }
        guard isConnected else {
            state = .offline
            return
        }

        let expectedAccountID = activeAccountID
        let generation = accountGeneration
        await processPending(isConnected: true)
        guard generation == accountGeneration,
              activeAccountID == expectedAccountID,
              expectedAccountID == nil || store.activeAccountID == expectedAccountID else { return }
        let queuedState = state
        state = .syncing
        do {
            let revision = serverStateRevision
            let response = try await GroveAPIRequestScope.$expectedAccountID.withValue(expectedAccountID) {
                try await repository.bootstrap()
            }
            let queuedChanges = await queueStore.all()
            guard generation == accountGeneration,
                  activeAccountID == expectedAccountID,
                  expectedAccountID == nil || store.activeAccountID == expectedAccountID else { return }
            guard revision == serverStateRevision else {
                // A mutation committed while this snapshot was in flight. The
                // coalescing loop immediately asks again for a response that
                // includes it instead of applying this older view of Friends.
                needsAnotherSynchronization = true
                return
            }
            guard !response.isNonDurable else {
                // The development server keeps accounts in process memory. Its
                // snapshot is authoritative from the client's point of view, so
                // applying it would overwrite a real Grove with state that is
                // one restart from empty. Never sync against it.
                state = .needsAttention(
                    message: "This Grove server does not store accounts permanently, so syncing was stopped to protect your plants. Your data is safe on this device."
                )
                return
            }
            // A change still waiting in the queue must not stop the pull. One
            // stuck upload used to hold back every handover, sitting card and
            // other device's edit for the whole delivery window. Apply the
            // snapshot, but let every record with an unsent change keep its
            // local copy (and offline friend decisions keep theirs) until the
            // change lands.
            let pending = PendingSyncChanges(queuedChanges)
            guard store.replace(with: response, pending: pending) else {
                if !pending.friendships { store.replaceFriendships(with: response) }
                // The server returned an empty account while this device still
                // holds plants. Applying it would delete them, so stop and say
                // so rather than silently erasing the user's Grove.
                state = .needsAttention(
                    message: "The server returned an empty grove while this iPhone still has plants, so nothing was changed. Your data is safe on this device. Try again later, and contact support if this keeps happening."
                )
                return
            }
            state = queuedChanges.isEmpty ? .upToDate : queuedState
        } catch let error as APIError {
            switch error {
            case .conflict, .forbidden, .unauthorised, .validation:
                state = .needsAttention(message: error.localizedDescription)
            default:
                state = .offline
            }
        } catch {
            state = .offline
        }
    }

    func discardQueuedChanges() async {
        retryTask?.cancel()
        retryTask = nil
        do {
            try await queueStore.clear()
            pendingCount = 0
            state = syncRepository == nil ? .localOnly : .upToDate
        } catch {
            state = .needsAttention(message: "Grove couldn't clear the queued changes.")
        }
    }

    private func refreshCount() async {
        pendingCount = await queueStore.all().count
    }

    private func send(
        _ payload: SyncMutationPayload,
        repository: any GroveRemoteRepository,
        mediaUploader: (any MediaUploading)?
    ) async throws {
        switch payload {
        case .uploadMedia(let pending):
            guard let mediaUploader else {
                throw APIError.validation("Media sync is not configured for this account.")
            }
            _ = try await mediaUploader.upload(pending)
        case .createPlant(let request):
            _ = try await repository.createPlant(request)
        case .createCheckIn(let request):
            _ = try await repository.createCheckIn(request)
        case .updatePlant(let request):
            _ = try await repository.updatePlant(request)
        case .deletePlant(let request):
            try await repository.deletePlant(request)
        case .createCareEvent(let request):
            _ = try await repository.createCareEvent(request)
        case .deleteCareEvent(let request):
            try await repository.deleteCareEvent(request)
        case .createSittingAssignment(let request):
            _ = try await repository.createSittingAssignment(request)
        case .revokeSittingInvite(let request):
            try await repository.revokeSittingInvite(request)
        case .createFriendInvitation(let request):
            _ = try await repository.createFriendInvitation(request)
        case .respondToFriendInvitation(let request):
            try await repository.respondToFriendInvitation(request)
        case .withdrawFriendInvitation(let request):
            try await repository.withdrawFriendInvitation(request)
        case .updateCareTask(let request):
            _ = try await repository.updateCareTask(request)
        case .updateProfile(let request):
            _ = try await repository.updateProfile(request)
        case .updateGardenerProgress(let request):
            _ = try await repository.updateGardenerProgress(request)
        }
    }

    /// Ten seconds, then twenty, doubling to a ceiling of about eighty-five
    /// minutes. The old ceiling was five minutes, which across the delivery
    /// window meant thousands of identical requests at a server that was
    /// plainly not answering. Backing off further costs a user nothing — their
    /// grove is already on the phone — and costs the service a great deal less.
    private func retryDate(attempt: Int) -> Date {
        let cappedAttempt = min(attempt, 10)
        let seconds = pow(2.0, Double(cappedAttempt)) * 5.0
        return Date.now.addingTimeInterval(seconds)
    }
}

/// Names for the diagnostic trail a dropped change leaves behind. Kinds only —
/// never a nickname, a note or a handle, which would put a user's grove in an
/// analytics payload.
private extension SyncMutationPayload {
    var isCareTaskUpdate: Bool {
        if case .updateCareTask = self { return true }
        return false
    }

    var analyticsName: String {
        switch self {
        case .uploadMedia: "upload_media"
        case .createPlant: "create_plant"
        case .createCheckIn: "create_check_in"
        case .updatePlant: "update_plant"
        case .deletePlant: "delete_plant"
        case .createCareEvent: "create_care_event"
        case .deleteCareEvent: "delete_care_event"
        case .createSittingAssignment: "create_sitting"
        case .revokeSittingInvite: "revoke_sitting_invite"
        case .createFriendInvitation: "create_friend_invitation"
        case .respondToFriendInvitation: "respond_friend_invitation"
        case .withdrawFriendInvitation: "withdraw_friend_invitation"
        case .updateCareTask: "update_care_task"
        case .updateProfile: "update_profile"
        case .updateGardenerProgress: "update_gardener_progress"
        }
    }
}

private extension APIError {
    /// Whether this failure is about the connection rather than the change. A
    /// dead network fails every queued change identically, so the pass stops;
    /// a server-side refusal may well be about one record, so the queue moves on
    /// and comes back to it.
    var stopsWholeQueue: Bool {
        switch self {
        case .offline, .timedOut, .transport: true
        default: false
        }
    }

    /// The status, not the sentence. Server messages can carry a user's own
    /// words back at them, and those must not reach a diagnostics batch.
    var analyticsReason: String {
        switch self {
        case .invalidURL: "invalid_url"
        case .offline: "offline"
        case .timedOut: "timed_out"
        case .transport: "transport"
        case .unauthorised: "unauthorised"
        case .forbidden: "forbidden"
        case .notFound: "not_found"
        case .conflict: "conflict"
        case .validation: "validation"
        case .rateLimited: "rate_limited"
        case .server(let status, _): "server_\(status)"
        case .invalidResponse: "invalid_response"
        }
    }
}

private extension JSONEncoder {
    static var grove: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var grove: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
