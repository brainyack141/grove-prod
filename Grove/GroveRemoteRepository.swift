import Foundation

struct GroveBootstrapResponse: Codable {
    let profile: UserProfile
    let plants: [Plant]
    let tasks: [CareTask]
    let activity: [ActivityEvent]
    let assignments: [SittingAssignment]
    let observations: [PlantObservation]?
    let friends: [PlantFriend]?
    let friendInvitations: [FriendInvitation]?
    let serverTime: Date
    /// Token-free owner metadata. A second device can show and revoke a link,
    /// but the bearer URL itself remains available only where it was minted.
    var sittingInvites: [SittingInvite]? = nil
    /// How the server stores this account: `"postgres"` when it is durable,
    /// `"memory"` when it is the development server, which loses every account
    /// on restart. Optional so an older server simply reads as unknown.
    ///
    /// The client applies a bootstrap wholesale, so a server that forgets
    /// accounts does not merely fail to sync — it deletes the user's Grove.
    /// `SyncEngine` refuses to apply a snapshot from a non-durable server.
    /// Defaulted so an older server (and existing call sites) read as unknown.
    var storage: String? = nil
    /// Full diagnosis records are separate from observations because one scan
    /// can contain a differential, limitations and follow-up questions.
    var diagnoses: [PlantDiagnosis]? = nil
    /// The deliberately-small plant cards and actionable care rows exposed to
    /// this account while it is actively sitting for somebody else.
    var sittingPlants: [FriendPlant]? = nil
    var sittingTasks: [CareTask]? = nil
    /// Account-backed Journey state. Optional so a client can safely talk to
    /// the previous API while the additive database/API rollout completes.
    var gardener: GardenerProgress? = nil
    var gardenerUpdatedAt: Date? = nil
    /// Whether `tasks` is the complete care history or only its newest window.
    ///
    /// The server caps completed history, and this client applies a bootstrap
    /// wholesale. Without this flag a capped response deleted older completed
    /// care from the phone. Optional so an older server reads as unknown, which
    /// `GroveStore.replace` treats as "might be capped".
    var tasksComplete: Bool? = nil
    /// Whether `observations` is the complete check-in history or only its
    /// newest window. Same data-loss hazard as `tasksComplete`.
    var observationsComplete: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case profile, plants, tasks, activity, assignments, observations, friends
        case friendInvitations, serverTime, sittingInvites, storage, diagnoses
        case sittingPlants, sittingTasks, gardener, gardenerUpdatedAt
        case tasksComplete, observationsComplete
    }
}

extension GroveBootstrapResponse {
    /// Rows are decoded one at a time, except plants and the profile. The
    /// database columns behind care kinds, activity kinds and sitting states
    /// are free text, so one value written by a newer client used to fail the
    /// whole snapshot, and an older build then retried forever and never
    /// synced again. A row this build cannot read is skipped instead.
    ///
    /// Plants stay strict on purpose: a plant missing from a snapshot reads as
    /// deleted elsewhere, so skipping one would delete it here.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func rows<Row: Decodable>(_ key: CodingKeys) throws -> [Row]? {
            try container.decodeIfPresent([Lossy<Row>].self, forKey: key)?.compactMap(\.value)
        }
        profile = try container.decode(UserProfile.self, forKey: .profile)
        plants = try container.decode([Plant].self, forKey: .plants)
        tasks = try rows(.tasks) ?? []
        activity = try rows(.activity) ?? []
        assignments = try rows(.assignments) ?? []
        observations = try rows(.observations)
        friends = try rows(.friends)
        friendInvitations = try rows(.friendInvitations)
        serverTime = try container.decode(Date.self, forKey: .serverTime)
        sittingInvites = try rows(.sittingInvites)
        storage = try container.decodeIfPresent(String.self, forKey: .storage)
        diagnoses = try rows(.diagnoses)
        sittingPlants = try rows(.sittingPlants)
        sittingTasks = try rows(.sittingTasks)
        gardener = try container.decodeIfPresent(GardenerProgress.self, forKey: .gardener)
        gardenerUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .gardenerUpdatedAt)
        tasksComplete = try container.decodeIfPresent(Bool.self, forKey: .tasksComplete)
        observationsComplete = try container.decodeIfPresent(Bool.self, forKey: .observationsComplete)
    }

    /// True when the server has explicitly said it cannot keep this account.
    /// Unknown (an older server that does not report) is not treated as unsafe;
    /// `GroveStore.replace(with:)` still guards the empty-Grove case.
    var isNonDurable: Bool { storage == "memory" }
}

/// One array element that decodes to nil instead of failing its array.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

struct CreatePlantRequest: Codable {
    let clientPlantID: UUID
    let nickname: String
    let location: String
    let analysis: PlantAnalysisResult
    let mediaDraftID: UUID
    /// Complete local record, including the profile fields that are not part
    /// of the scan analysis. Optional for persisted mutations from old builds.
    var plant: Plant? = nil
}

struct CreateCheckInRequest: Codable {
    let plantID: UUID
    let score: Int
    let band: HealthBand
    let note: String
    let mediaDraftID: UUID?
    let clientRequestID: UUID
    /// Observation detail so the server-side record matches the local one.
    /// Optional so mutation queues persisted before these fields decode cleanly.
    var appearance: ObservationAppearance? = nil
    var soilMoisture: ObservationSoilMoisture? = nil
    var hasNewGrowth: Bool? = nil
    var isEstimated: Bool? = nil
    var appliesToPlant: Bool? = nil
    var confidence: Int? = nil
    var actionability: DiagnosisActionability? = nil
    var assessmentAvailable: Bool? = nil
    var analysisVersion: String? = nil
    var providerName: String? = nil
    var limitations: [String]? = nil
    var followUpDays: Int? = nil
    var referenceObservationID: UUID? = nil
    var indicatorReadings: [PlantHealthIndicatorReading]? = nil
    /// The id the client already gave this check-in's entry in the Updates feed.
    ///
    /// The server writes its own entry for a check-in too, so without a shared
    /// id the next bootstrap merges two records of one event and the feed says
    /// everything twice. Optional so mutation queues persisted before this field
    /// decode cleanly — the server mints an id when it is absent.
    var activityEventID: UUID? = nil
}

/// Mirrors the complete durable plant record after an owner edit. Keeping the
/// plant as one value means lifecycle, notes, environment and plan updates are
/// atomic on the server and cannot arrive in a half-old combination.
struct UpdatePlantRequest: Codable, Sendable {
    let plant: Plant
    let clientRequestID: UUID
    var diagnoses: [PlantDiagnosis]? = nil
}

/// Removes one owner plant from every device. The stable request id makes the
/// operation safe to replay after a timeout; the plant id is kept separately
/// so the queued mutation remains useful after the local record is gone.
struct DeletePlantRequest: Codable, Sendable {
    let plantID: UUID
    let clientRequestID: UUID
}

/// Mirrors a care event the owner recorded directly from a plant page. These
/// are already completed records, unlike the scheduled care actions updated by
/// `CareTaskMutationRequest`.
struct CreateCareEventRequest: Codable, Sendable {
    let task: CareTask
    let clientRequestID: UUID
}

/// Reverses a directly logged event when the owner taps Undo. This deliberately
/// has its own contract: treating undo as a task update cannot remove the
/// already-completed row from another device's history.
struct DeleteCareEventRequest: Codable, Sendable {
    let taskID: UUID
    let clientRequestID: UUID
}

struct CreateSittingRequest: Codable {
    let sitterAccountID: String
    let startDate: Date
    let endDate: Date
    let plantIDs: [UUID]
    let canCheckIn: Bool
    var canLogCare: Bool = true
    var ownerNotes: String? = nil
    var timeZoneIdentifier: String? = nil
    /// Stable per-mutation identity for idempotent replay. Optional so
    /// mutation queues persisted before this field decode cleanly.
    var clientRequestID: UUID? = nil
    /// The id the client already gave this invitation's entry in the Updates
    /// feed — see `CreateCheckInRequest.activityEventID`.
    var activityEventID: UUID? = nil
}

struct RespondToSittingAssignmentRequest: Codable, Sendable {
    let assignmentID: UUID
    let accept: Bool
    let clientRequestID: UUID
}

struct RevokeSittingAssignmentRequest: Codable, Sendable {
    let assignmentID: UUID
    let clientRequestID: UUID
}

/// Asks the server to mint a shareable sitting link.
///
/// `inviteID` is the row the client already created, so the two ends agree on
/// identity without a second round trip — and so a retry that the client never
/// saw the answer to lands on the same invite rather than a duplicate.
struct CreateSittingInviteRequest: Codable, Sendable {
    let inviteID: UUID
    let label: String
    let startDate: Date
    let endDate: Date
    let plantIDs: [UUID]
    let canLogCare: Bool
    var ownerNotes: String? = nil
    var timeZoneIdentifier: String? = nil
    /// Present only when the owner chose an accepted Grove connection. The
    /// link remains a bearer capability, but this lets Block revoke every link
    /// explicitly created for that account.
    var recipientAccountID: String? = nil
    let clientRequestID: UUID
}

/// The one moment the token exists in the clear. The server keeps only a hash
/// of it, so this response cannot be asked for twice — losing it means minting
/// a new link.
struct SittingInviteLink: Codable, Sendable {
    let id: UUID
    let url: URL
    let expiresAt: Date
}

struct RevokeSittingInviteRequest: Codable, Sendable {
    let inviteID: UUID
    let clientRequestID: UUID
}

/// For endpoints whose answer is only "it worked". Decodes any JSON object,
/// including `{}`.
struct EmptyAPIResponse: Codable, Sendable {}

struct CreateFriendInvitationRequest: Codable {
    let username: String
    let clientRequestID: UUID
}

/// Takes back an invitation this account sent. Only the requester may send it;
/// the server refuses anything else.
struct WithdrawFriendInvitationRequest: Codable, Sendable {
    let invitationID: UUID
    let clientRequestID: UUID
}

/// Answers an invitation this account received. `accept: false` declines it.
///
/// The friendship only becomes real on the server here — accepting used to be
/// local-only, which left the other gardener waiting forever on a request this
/// device had already agreed to.
struct RespondToFriendInvitationRequest: Codable, Sendable {
    let invitationID: UUID
    let accept: Bool
    let clientRequestID: UUID
}

/// Ends an accepted friendship. The server also revokes any legacy
/// account-based sitting assignment between the pair in the same transaction.
struct RemoveFriendRequest: Codable, Sendable {
    let friendAccountID: String
    let clientRequestID: UUID
}

/// Permanently prevents either account from starting another connection.
/// Unlike Remove, this is a safety boundary and has no reconnect affordance.
struct BlockFriendRequest: Codable, Sendable {
    let friendAccountID: String
    let clientRequestID: UUID
}

enum FriendReportReason: String, Codable, CaseIterable, Identifiable, Sendable {
    case harassment
    case impersonation
    case spam
    case inappropriateProfile
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .harassment: "Harassment or bullying"
        case .impersonation: "Impersonation"
        case .spam: "Spam or unwanted contact"
        case .inappropriateProfile: "Inappropriate profile"
        case .other: "Something else"
        }
    }
}

/// Sends a bounded safety report and blocks the reported account atomically.
/// The report id is also the idempotency key, so a retry cannot file it twice.
struct ReportFriendRequest: Codable, Sendable {
    let friendAccountID: String
    let reason: FriendReportReason
    let details: String
    let clientRequestID: UUID
}

enum CareTaskMutationOutcome: String, Codable, Sendable {
    case completed
    case snoozed
}

struct CareTaskMutationRequest: Codable, Sendable {
    let taskID: UUID
    let outcome: CareTaskMutationOutcome
    let occurredAt: Date
    let rescheduledFor: Date?
    let reason: String?
    let clientRequestID: UUID
}

struct UpdateProfileRequest: Codable, Sendable {
    let displayName: String
    let username: String
    let regionCode: String
    let usesMetricSystem: Bool
    let isPrivate: Bool
    var latitude: Double? = nil
    var longitude: Double? = nil
    var locationLabel: String? = nil
    var locationCountryCode: String? = nil
    var locationTimeZoneIdentifier: String? = nil
    let clientRequestID: UUID
}

/// The whole Journey state is one small, internally-consistent document. A
/// single last-write-wins mutation avoids splitting a streak's count, last day
/// and shield balance across requests that could arrive out of order offline.
struct UpdateGardenerProgressRequest: Codable, Sendable {
    let gardener: GardenerProgress
    let updatedAt: Date
    let clientRequestID: UUID
}

struct GardenerProgressSyncResponse: Codable, Sendable {
    let gardener: GardenerProgress
    let updatedAt: Date
}

@MainActor
protocol GroveRemoteRepository {
    func bootstrap() async throws -> GroveBootstrapResponse
    func createPlant(_ request: CreatePlantRequest) async throws -> Plant
    func createCheckIn(_ request: CreateCheckInRequest) async throws -> Plant
    func updatePlant(_ request: UpdatePlantRequest) async throws -> Plant
    func deletePlant(_ request: DeletePlantRequest) async throws
    func createCareEvent(_ request: CreateCareEventRequest) async throws -> CareTask
    func deleteCareEvent(_ request: DeleteCareEventRequest) async throws
    func createSittingAssignment(_ request: CreateSittingRequest) async throws -> SittingAssignment
    func respondToSittingAssignment(_ request: RespondToSittingAssignmentRequest) async throws -> SittingAssignment
    func revokeSittingAssignment(_ request: RevokeSittingAssignmentRequest) async throws -> SittingAssignment
    func createSittingInvite(_ request: CreateSittingInviteRequest) async throws -> SittingInviteLink
    func revokeSittingInvite(_ request: RevokeSittingInviteRequest) async throws
    func createFriendInvitation(_ request: CreateFriendInvitationRequest) async throws -> FriendInvitation
    func respondToFriendInvitation(_ request: RespondToFriendInvitationRequest) async throws
    func withdrawFriendInvitation(_ request: WithdrawFriendInvitationRequest) async throws
    func removeFriend(_ request: RemoveFriendRequest) async throws
    func blockFriend(_ request: BlockFriendRequest) async throws
    func reportFriend(_ request: ReportFriendRequest) async throws
    func updateCareTask(_ request: CareTaskMutationRequest) async throws -> CareTask
    func updateProfile(_ request: UpdateProfileRequest) async throws -> UserProfile
    func updateGardenerProgress(_ request: UpdateGardenerProgressRequest) async throws -> GardenerProgressSyncResponse
}

extension GroveRemoteRepository {
    /// Lightweight test and preview repositories written before plant editing
    /// synced can accept the mutation without growing unrelated boilerplate.
    func updatePlant(_ request: UpdatePlantRequest) async throws -> Plant {
        request.plant
    }

    func deletePlant(_ request: DeletePlantRequest) async throws {}

    func createCareEvent(_ request: CreateCareEventRequest) async throws -> CareTask {
        request.task
    }

    func deleteCareEvent(_ request: DeleteCareEventRequest) async throws {}

    func respondToSittingAssignment(_ request: RespondToSittingAssignmentRequest) async throws -> SittingAssignment {
        throw APIError.validation("This preview cannot answer sitting invitations.")
    }

    func revokeSittingAssignment(_ request: RevokeSittingAssignmentRequest) async throws -> SittingAssignment {
        throw APIError.validation("This preview cannot revoke sitting invitations.")
    }

    func blockFriend(_ request: BlockFriendRequest) async throws {}

    func reportFriend(_ request: ReportFriendRequest) async throws {}

    func updateGardenerProgress(_ request: UpdateGardenerProgressRequest) async throws -> GardenerProgressSyncResponse {
        GardenerProgressSyncResponse(gardener: request.gardener, updatedAt: request.updatedAt)
    }
}

@MainActor
final class HTTPGroveRemoteRepository: GroveRemoteRepository {
    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func bootstrap() async throws -> GroveBootstrapResponse {
        try await client.get("bootstrap")
    }

    func createPlant(_ request: CreatePlantRequest) async throws -> Plant {
        try await client.post("plants", body: request, idempotencyKey: request.clientPlantID)
    }

    func createCheckIn(_ request: CreateCheckInRequest) async throws -> Plant {
        try await client.post(
            "plants/\(request.plantID.uuidString)/check-ins",
            body: request,
            idempotencyKey: request.clientRequestID
        )
    }

    func updatePlant(_ request: UpdatePlantRequest) async throws -> Plant {
        try await client.patch(
            "plants/\(request.plant.id.uuidString)",
            body: request,
            idempotencyKey: request.clientRequestID
        )
    }

    func deletePlant(_ request: DeletePlantRequest) async throws {
        let _: EmptyAPIResponse = try await client.post(
            "plants/\(request.plantID.uuidString)/delete",
            body: request,
            idempotencyKey: request.clientRequestID
        )
    }

    func createCareEvent(_ request: CreateCareEventRequest) async throws -> CareTask {
        try await client.post(
            "care-actions",
            body: request,
            idempotencyKey: request.clientRequestID
        )
    }

    func deleteCareEvent(_ request: DeleteCareEventRequest) async throws {
        let _: EmptyAPIResponse = try await client.post(
            "care-actions/\(request.taskID.uuidString)/delete",
            body: request,
            idempotencyKey: request.clientRequestID
        )
    }

    func createSittingAssignment(_ request: CreateSittingRequest) async throws -> SittingAssignment {
        try await client.post("sitting-assignments", body: request, idempotencyKey: request.clientRequestID)
    }

    func respondToSittingAssignment(_ request: RespondToSittingAssignmentRequest) async throws -> SittingAssignment {
        try await client.post(
            "sitting-assignments/\(request.assignmentID.uuidString)/respond",
            body: request,
            idempotencyKey: request.clientRequestID
        )
    }

    func revokeSittingAssignment(_ request: RevokeSittingAssignmentRequest) async throws -> SittingAssignment {
        try await client.post(
            "sitting-assignments/\(request.assignmentID.uuidString)/revoke",
            body: request,
            idempotencyKey: request.clientRequestID
        )
    }

    /// Sent without an idempotency key on purpose. The server caches replayed
    /// response bodies for a day, and this body carries the link's token in the
    /// clear — the one thing the design promises is never stored. A retry
    /// therefore collides on the invite id and is refused, which the screen
    /// reports rather than papering over.
    func createSittingInvite(_ request: CreateSittingInviteRequest) async throws -> SittingInviteLink {
        try await client.post("sitting-invites", body: request)
    }

    func revokeSittingInvite(_ request: RevokeSittingInviteRequest) async throws {
        let _: EmptyAPIResponse = try await client.post(
            "sitting-invites/\(request.inviteID.uuidString)/revoke",
            body: request,
            idempotencyKey: request.clientRequestID
        )
    }

    func createFriendInvitation(_ request: CreateFriendInvitationRequest) async throws -> FriendInvitation {
        try await client.post("friendships/invitations", body: request, idempotencyKey: request.clientRequestID)
    }

    func respondToFriendInvitation(_ request: RespondToFriendInvitationRequest) async throws {
        let _: EmptyAPIResponse = try await client.post(
            "friendships/\(request.invitationID.uuidString)/respond",
            body: request,
            idempotencyKey: request.clientRequestID
        )
    }

    func withdrawFriendInvitation(_ request: WithdrawFriendInvitationRequest) async throws {
        let _: EmptyAPIResponse = try await client.post(
            "friendships/\(request.invitationID.uuidString)/withdraw",
            body: request,
            idempotencyKey: request.clientRequestID
        )
    }

    func removeFriend(_ request: RemoveFriendRequest) async throws {
        let _: EmptyAPIResponse = try await client.post(
            "friendships/\(request.friendAccountID)/remove",
            body: request,
            idempotencyKey: request.clientRequestID
        )
    }

    func blockFriend(_ request: BlockFriendRequest) async throws {
        let _: EmptyAPIResponse = try await client.post(
            "friendships/\(request.friendAccountID)/block",
            body: request,
            idempotencyKey: request.clientRequestID
        )
    }

    func reportFriend(_ request: ReportFriendRequest) async throws {
        let _: EmptyAPIResponse = try await client.post(
            "friendships/\(request.friendAccountID)/report",
            body: request,
            idempotencyKey: request.clientRequestID
        )
    }

    func updateCareTask(_ request: CareTaskMutationRequest) async throws -> CareTask {
        try await client.patch(
            "care-actions/\(request.taskID.uuidString)",
            body: request,
            idempotencyKey: request.clientRequestID
        )
    }

    func updateProfile(_ request: UpdateProfileRequest) async throws -> UserProfile {
        try await client.patch("profile", body: request, idempotencyKey: request.clientRequestID)
    }

    func updateGardenerProgress(_ request: UpdateGardenerProgressRequest) async throws -> GardenerProgressSyncResponse {
        try await client.patch("journey-progress", body: request, idempotencyKey: request.clientRequestID)
    }
}
