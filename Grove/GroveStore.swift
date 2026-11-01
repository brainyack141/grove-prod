import Foundation
import Observation

@MainActor
@Observable
final class GroveStore {
    var plants: [Plant]
    var collections: [PlantCollection]
    var tasks: [CareTask]
    /// Scoped, read-minimal care data from groves this account is temporarily
    /// sitting. These never enter `plants`/`tasks`, so My Grove and its badges
    /// cannot mistake delegated plants for owned ones.
    var sittingPlants: [FriendPlant]
    var sittingTasks: [CareTask]
    var activity: [ActivityEvent]
    var assignments: [SittingAssignment]
    /// Link handovers this account has minted. Local-first like everything
    /// else here: the link is usable the moment the server returns it, and the
    /// list survives relaunches so it can be re-shared or revoked.
    var sittingInvites: [SittingInvite]
    var observations: [PlantObservation]
    var diagnoses: [PlantDiagnosis]
    var scanHistory: [ScanHistoryRecord]
    var friends: [PlantFriend]
    var friendInvitations: [FriendInvitation]
    var profile: UserProfile
    /// Journey / gamification progression for this account.
    var gardener: GardenerProgress
    /// Semantic revision for the account-backed Journey document. Nil belongs
    /// only to a genuinely untouched account; an old local snapshot is given a
    /// migration revision when it is loaded so it can seed the server once.
    private(set) var gardenerUpdatedAt: Date?
    /// The latest semantic revision durably accepted by the local mutation
    /// queue. Queueing is not the same as changing progress and must never
    /// manufacture a newer revision.
    private(set) var gardenerEnqueuedAt: Date?
    private(set) var activeAccountID: String?
    /// Set when a real award crosses a level boundary, so the app can show a
    /// level-up takeover. Transient — never persisted.
    var pendingLevelUp: GardenerLevel?

    /// Badges earned since the last time the celebration layer drained this
    /// queue, oldest first.
    ///
    /// A queue rather than a single value because one `refreshJourney` pass can
    /// award several badges at once — finishing a chapter opens the next one,
    /// whose already-satisfied nodes then pay out in the same fixed-point loop.
    /// Showing only the last of those would quietly swallow the rest, which is
    /// the exact failure this whole feature exists to fix.
    ///
    /// Only genuinely-new, live unlocks land here: a migration repair or a
    /// silent recompute passes no `earnedAt`, and nothing without a real earn
    /// date is ever celebrated. Transient — never persisted.
    var pendingBadges: [Badge] = []

    /// Set when today's first qualifying look actually moved the streak, so the
    /// app can light the flame. Only `recordTend` writes it, and only on the
    /// paths that change the number — a second look on the same day leaves it
    /// alone, because the day has already been celebrated once.
    /// Transient — never persisted.
    var pendingStreakMoment: StreakMoment?

    /// The calendar day the app is currently drawn for.
    ///
    /// Anything that asks "is this today?" needs a *stored* today to ask it of.
    /// `Date.now` is not observable state, so a view built from it never
    /// redraws when the day turns — the streak simply kept yesterday's number
    /// on screen. Moving this stamp is what tells every streak-shaped view to
    /// recompute; `refreshCalendarDay()` is called on midnight and on every
    /// return to the foreground. Transient — never persisted.
    private(set) var calendarDay: Date = GroveStore.dayStamp(for: .now)

    /// The timestamp of the newest activity the user has actually looked at.
    ///
    /// Persisted with the account rather than the device: "have I read this?" is
    /// a fact about a Grove, and two accounts on one phone do not share it. Nil
    /// means the feed has never been opened, which is not the same as "nothing
    /// new" — see `hasUnseenActivity`.
    private(set) var lastSeenActivityAt: Date?

    /// Maps a completed care task to the activity entry its completion wrote,
    /// so `undoCompletion(taskID:)` can retract exactly that entry rather than
    /// guessing at the newest one for the plant.
    ///
    /// Transient on purpose. Undo is an in-session correction for a tap that
    /// just happened; a completion that survived a relaunch is a fact, not a
    /// slip, and its history entry should stand.
    private var completionActivityIDs: [UUID: UUID] = [:]

    /// Care this device minted itself: a watering logged from the plant page, a
    /// soil reading felt on the spot. The API has no endpoint for either — the
    /// mutation queue can complete or snooze a task the server already knows
    /// about, and that is all — so these rows exist nowhere but here.
    ///
    /// Persisted, unlike `completionActivityIDs`, because `replace(with:)`
    /// assigns the bootstrap's task list straight over the local one. Without a
    /// record of which rows the server was never told about, the first
    /// successful sync silently deleted every self-logged watering and every
    /// felt soil reading — which is the evidence the watering card's whole
    /// estimate rests on. See the carry-across in `replace(with:)`.
    private(set) var selfLoggedTaskIDs: Set<UUID> = []

    /// Every plant id the server has ever sent back, which is the only reliable
    /// way to tell "deleted on another device" from "never got there".
    ///
    /// `replace(with:)` assigns the bootstrap's plant list over the local one, so
    /// a plant whose upload never landed was erased by the next successful sync.
    /// The queue tries for a week and can still give up — on a refusal the
    /// server will repeat forever, or on an outage that outlasts the window —
    /// and the plant would go with it. A plant this device minted and the server
    /// has never confirmed is carried across instead. Once it has appeared in
    /// one bootstrap, its later absence is a deletion and is honoured.
    private(set) var serverKnownPlantIDs: Set<UUID> = []

    /// Check-ins and diagnoses this device made that no bootstrap has sent
    /// back yet. The same protection `serverKnownPlantIDs` gives plants, from
    /// the other side: a check-in whose upload was let go (a refusal, or a
    /// week of outage) is not one the server deleted, and the next sync took
    /// it and its only photo reference off the phone. Ids leave the set the
    /// first time the server returns them; after that, absence is honoured.
    private(set) var unacknowledgedObservationIDs: Set<UUID> = []
    private(set) var unacknowledgedDiagnosisIDs: Set<UUID> = []

    /// The streak state a self-logged tend moved, kept only for the life of its
    /// undo offer. See `undoCompletion(taskID:)`.
    private var tendRollbacks: [UUID: TendRollback] = [:]
    /// The self-logged task that last advanced the streak, so an undo can tell
    /// "the tap I am retracting is the one that tended today" from "something
    /// else has tended since, and today stands on its own".
    private var lastTendTaskID: UUID?

    /// Everything `recordTend(on:)` touches, so retracting a tend restores the
    /// streak exactly rather than approximating it.
    private struct TendRollback {
        let currentStreak: Int
        let longestStreak: Int
        let lastTendDay: Date?
        let streakShields: Int
        let lastShieldStreak: Int
    }

    private static let legacyPersistenceKey = "grove.local.snapshot.v1"
    private var persistenceKey = GroveStore.legacyPersistenceKey
    private let persistenceEnabled: Bool
    private let storage: UserDefaults
    /// A single monotonic invalidation token for presentation indexes and
    /// reminder scheduling. Every durable model mutation already funnels
    /// through `persist()`, so views no longer need to rebuild giant string
    /// fingerprints from whole arrays during every body evaluation.
    private(set) var revision: UInt64 = 0
    @ObservationIgnored private var persistenceTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var persistenceGenerations: [String: UInt64] = [:]
    @ObservationIgnored private var cachedPresentationIndex: PresentationIndex?
    @ObservationIgnored private var cachedGroveScore: GroveScoreCache?
    /// Baseline used by the central persistence funnel to notice Journey
    /// mutations without making every care, lesson, and chest caller know
    /// about the sync engine.
    @ObservationIgnored private var persistedGardener: GardenerProgress = .new
    /// Whether this session has applied a bootstrap for the active account,
    /// and so has seen the server's copy of the Journey document. Until it
    /// has, local revisions are minted as provisional (see
    /// `prepareGardenerRevisionForPersistence`). Transient on purpose: every
    /// launch re-earns it from the first successful sync.
    @ObservationIgnored private var gardenerReconciledWithServer = false

    private struct StagedSnapshotKey: Hashable, Sendable {
        let storageID: ObjectIdentifier
        let key: String
    }

    private struct StagedSnapshot {
        let token: UUID
        let snapshot: Snapshot
    }

    /// Keeps a just-mutated snapshot visible to a second store in this process
    /// while JSON encoding finishes off the main actor. Disk remains the source
    /// of truth across launches; this closes the much shorter account-switch
    /// and immediate-reopen window without putting encoding back on the UI.
    private static var stagedSnapshots: [StagedSnapshotKey: StagedSnapshot] = [:]

    private struct PresentationIndex {
        let revision: UInt64
        let latestPhotoURLs: [UUID: URL]
        let latestPhotoDates: [UUID: Date]
        let nextTasks: [UUID: CareTask]
    }

    private struct GroveScoreCache {
        let revision: UInt64
        let calendarDay: Date
        let score: GroveScore?
    }

    static func forCurrentSession(storage: UserDefaults = .standard) -> GroveStore {
        let store = GroveStore(storage: storage)
        if let session = SessionService(storage: storage).currentSession {
            store.activate(session: session)
        }
        return store
    }

    /// The signed-in account's grove for a caller that only reads, such as a
    /// Shortcuts or Spotlight query. `forCurrentSession` re-encodes and writes
    /// the whole snapshot on activation; a lookup has no business doing that,
    /// and with no session it returns an empty grove rather than fixtures.
    static func readOnlyForCurrentSession(storage: UserDefaults = .standard) -> GroveStore {
        let store = GroveStore(
            plants: [],
            collections: [],
            tasks: [],
            activity: [],
            assignments: [],
            observations: [],
            diagnoses: [],
            scanHistory: [],
            friends: [],
            friendInvitations: [],
            persistenceEnabled: false,
            storage: storage
        )
        if let session = SessionService(storage: storage).currentSession {
            store.activate(session: session)
        }
        return store
    }

    init(
        plants: [Plant]? = nil,
        collections: [PlantCollection]? = nil,
        tasks: [CareTask]? = nil,
        sittingPlants: [FriendPlant]? = nil,
        sittingTasks: [CareTask]? = nil,
        activity: [ActivityEvent]? = nil,
        assignments: [SittingAssignment]? = nil,
        sittingInvites: [SittingInvite]? = nil,
        observations: [PlantObservation]? = nil,
        diagnoses: [PlantDiagnosis]? = nil,
        scanHistory: [ScanHistoryRecord]? = nil,
        friends: [PlantFriend]? = nil,
        friendInvitations: [FriendInvitation]? = nil,
        profile: UserProfile = .fixture,
        persistenceEnabled: Bool = true,
        storage: UserDefaults = .standard
    ) {
        self.persistenceEnabled = persistenceEnabled
        self.storage = storage
        activeAccountID = nil
        if persistenceEnabled,
           plants == nil,
           collections == nil,
           tasks == nil,
           sittingPlants == nil,
           sittingTasks == nil,
           activity == nil,
           assignments == nil,
           sittingInvites == nil,
           observations == nil,
           diagnoses == nil,
           scanHistory == nil,
           friends == nil,
           friendInvitations == nil,
           profile == .fixture,
           let snapshot = Self.decodedSnapshot(
               storage: storage,
               key: Self.legacyPersistenceKey
           ) {
            self.plants = snapshot.plants
            self.collections = snapshot.collections ?? []
            self.tasks = snapshot.tasks
            self.sittingPlants = snapshot.sittingPlants ?? []
            self.sittingTasks = snapshot.sittingTasks ?? []
            self.activity = snapshot.activity
            self.assignments = snapshot.assignments
            self.sittingInvites = snapshot.sittingInvites ?? []
            self.observations = snapshot.observations ?? []
            self.diagnoses = snapshot.diagnoses ?? []
            self.scanHistory = snapshot.scanHistory ?? []
            self.friends = snapshot.friends ?? PlantFriend.fixtures
            self.friendInvitations = snapshot.friendInvitations ?? FriendInvitation.fixtures
            self.profile = snapshot.profile
            self.gardener = snapshot.gardener ?? .new
            self.gardenerUpdatedAt = snapshot.gardenerUpdatedAt
            self.gardenerEnqueuedAt = snapshot.gardenerEnqueuedAt
            self.lastSeenActivityAt = snapshot.lastSeenActivityAt
        } else {
            let initialPlants = plants ?? Plant.fixtures
            self.plants = initialPlants
            self.collections = collections ?? (plants == nil ? PlantCollection.fixtures(plants: initialPlants) : [])
            self.tasks = tasks ?? CareTask.fixtures(plants: initialPlants)
            self.sittingPlants = sittingPlants ?? []
            self.sittingTasks = sittingTasks ?? []
            self.activity = activity ?? ActivityEvent.fixtures(plants: initialPlants)
            self.assignments = assignments ?? SittingAssignment.fixtures(plants: initialPlants)
            self.sittingInvites = sittingInvites ?? []
            self.observations = observations ?? (plants == nil ? PlantObservation.fixtures(plants: initialPlants) : [])
            self.diagnoses = diagnoses ?? []
            self.scanHistory = scanHistory ?? []
            self.friends = friends ?? PlantFriend.fixtures
            self.friendInvitations = friendInvitations ?? FriendInvitation.fixtures
            self.profile = profile
            self.gardener = .new
            self.gardenerUpdatedAt = nil
            self.gardenerEnqueuedAt = nil
        }
        persistedGardener = gardener
        migrateLegacyGardenerRevisionIfNeeded()
        // A snapshot loaded here skips `apply`, so it needs the same repair.
        // Persisting is left to the next mutation — the repair is cheap and
        // re-runs on every launch until it sticks.
        repairMediaPaths()
        repairEstimatedCheckInCopy()
    }

    var isProfileSetupComplete: Bool {
        !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var observationMediaDirectory: URL {
        mediaRootDirectory.appendingPathComponent("Observations", isDirectory: true)
    }

    func activate(session: UserSession) {
        guard activeAccountID != session.accountID else { return }

        activeAccountID = session.accountID
        persistenceKey = AccountStorage.snapshotKey(for: session.accountID)
        gardenerReconciledWithServer = false

        if let snapshot = decodedSnapshot(forKey: persistenceKey) {
            apply(snapshot)
            migrateAndHydrateSittingInviteURLs(accountID: session.accountID)
            // A session that has just come through onboarding carries a plan the
            // user built seconds ago, so it wins over whatever the snapshot was
            // holding. Every other session carries none and leaves the stored
            // plan — including any edits made from My Grove — untouched.
            if let plan = session.plan, profile.plan != plan {
                profile.plan = plan
                persist()
            }
            // A provider identity can already have an empty local snapshot
            // when scan-first onboarding completes against it. Keep any real
            // saved location, but fill a missing one from the answer carried
            // across this exact account boundary.
            if let location = session.location, profile.location == nil {
                profile.location = location
                persist()
            }
            // Immediately replace any legacy snapshot that carried a bearer
            // URL. `makeSnapshot()` strips those credentials.
            persistImmediately()
            return
        }

        if session.mode == .demo {
            if !session.isSimulatorTroubleshooting,
               let legacy = decodedSnapshot(forKey: Self.legacyPersistenceKey) {
                apply(legacy)
                migrateAndHydrateSittingInviteURLs(accountID: session.accountID)
                persist()
                discardPendingPersistence(forKey: Self.legacyPersistenceKey)
                storage.removeObject(forKey: Self.legacyPersistenceKey)
                return
            } else {
                installDemoFixtures()
            }
        } else {
            plants = []
            collections = []
            tasks = []
            sittingPlants = []
            sittingTasks = []
            activity = []
            // The read marker is about this account's feed, so it cannot follow
            // the previous account in — an empty feed with a stamp from someone
            // else's would silently swallow the first real update.
            lastSeenActivityAt = nil
            // A sitting link is a working URL into someone's plants. Left
            // standing it would follow the previous account into this one —
            // leaking their plant list, and telling this account its grove is
            // already covered when nobody is watching it.
            sittingInvites = []
            assignments = []
            observations = []
            diagnoses = []
            unacknowledgedObservationIDs = []
            unacknowledgedDiagnosisIDs = []
            scanHistory = []
            friends = []
            friendInvitations = []
            // A fresh account must not inherit the previous account's XP,
            // level, streak, or badges — including any celebration that was
            // still queued when the switch happened.
            gardener = .new
            gardenerUpdatedAt = nil
            gardenerEnqueuedAt = nil
            persistedGardener = .new
            pendingLevelUp = nil
            pendingBadges = []
            pendingStreakMoment = nil
            let displayName = session.displayName == "Plant parent" ? "" : session.displayName
            profile = UserProfile(
                name: displayName,
                // A brand-new account used to start with no username at all,
                // which rendered as a bare "@" on My Grove and produced
                // an incomplete invite URL in the share sheet.
                // Seed a valid one; Edit profile can change it any time.
                username: Self.defaultUsername(for: displayName, accountID: session.accountID),
                initials: Self.initials(for: session.displayName),
                friendCount: 0,
                regionCode: Locale.current.region?.identifier,
                // .uk is a distinct case from .metric — comparing against
                // .metric alone would default UK devices to Imperial.
                usesMetricSystem: Locale.current.measurementSystem != .us,
                isPrivate: true,
                location: session.location,
                plan: session.plan
            )
        }
        persist()
    }

    /// The newest local Journey document that has not yet been handed to the
    /// durable mutation queue. Fresh accounts return nil, so their empty state
    /// can never race ahead of a real server snapshot on first sign-in.
    func pendingGardenerProgressSyncRequest() -> UpdateGardenerProgressRequest? {
        guard let gardenerUpdatedAt, gardenerEnqueuedAt != gardenerUpdatedAt else { return nil }
        return UpdateGardenerProgressRequest(
            gardener: gardener,
            updatedAt: gardenerUpdatedAt,
            clientRequestID: UUID()
        )
    }

    /// Called only after the queue has atomically persisted the request. A
    /// crash before this marker merely replays the same semantic revision;
    /// `SyncMutationPayload.replays` collapses that duplicate safely.
    func markGardenerProgressEnqueued(updatedAt: Date) {
        guard gardenerUpdatedAt == updatedAt else { return }
        gardenerEnqueuedAt = updatedAt
        persist()
    }

    func updateProfile(
        name: String,
        username: String,
        regionCode: String,
        usesMetricSystem: Bool,
        isPrivate: Bool
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
        guard !trimmedName.isEmpty, !normalizedUsername.isEmpty else { return }
        profile.name = trimmedName
        profile.username = normalizedUsername
        profile.initials = Self.initials(for: trimmedName)
        profile.regionCode = regionCode.uppercased()
        profile.usesMetricSystem = usesMetricSystem
        profile.isPrivate = isPrivate
        persist()
    }

    /// Changes the profile portrait without making the remote profile contract
    /// carry device-local file paths. A custom image is already re-encoded by
    /// the picker before it reaches the store, then written with file
    /// protection inside this account's media namespace.
    func updateProfileAvatar(
        assetName: String?,
        existingPhotoURL: URL?,
        customImageData: Data?
    ) throws {
        let previousPhotoURL = profile.avatarPhotoURL
        let nextPhotoURL: URL?

        if let customImageData {
            guard !customImageData.isEmpty else { throw ProfileAvatarError.invalidImage }
            let directory = mediaRootDirectory.appendingPathComponent("Profile", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let url = directory.appendingPathComponent("avatar-\(UUID().uuidString).jpg")
                try customImageData.write(
                    to: url,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
                nextPhotoURL = url
            } catch {
                throw ProfileAvatarError.couldNotSave
            }
        } else {
            nextPhotoURL = GroveMediaPath.resolved(existingPhotoURL)
        }

        profile.avatarAssetName = nextPhotoURL == nil ? assetName : nil
        profile.avatarPhotoURL = nextPhotoURL
        persist()

        if let previousPhotoURL,
           previousPhotoURL != nextPhotoURL,
           previousPhotoURL.isFileURL {
            removeOwnedMediaFile(at: previousPhotoURL)
        }
    }

    /// Sets (or clears, when `nil`) the Grove-wide pinned location.
    func updateGroveLocation(_ location: GroveLocation?) {
        profile.location = location
        persist()
    }

    /// Replaces the personalization plan built during onboarding. An entirely
    /// unanswered plan is stored as `nil` so My Grove offers to build one
    /// rather than rendering an empty card.
    func updatePlan(_ plan: GrovePlan?) {
        profile.plan = (plan?.isEmpty == false) ? plan : nil
        persist()
    }

    /// All incomplete care tasks, soonest first.
    var pendingTasks: [CareTask] {
        let reminderPlantIDs = Set(
            plants
                .filter { $0.effectiveLifecycleState.receivesCareReminders }
                .map(\.id)
        )
        return tasks
            .filter { !$0.isCompleted && reminderPlantIDs.contains($0.plantID) }
            .sorted { $0.dueDate < $1.dueDate }
    }

    /// Incomplete tasks that are actually due — overdue or due today. Tasks
    /// snoozed or scheduled for a later day belong to the upcoming queue, not
    /// the Today section or its badge.
    var dueTasks: [CareTask] {
        let calendar = Calendar.current
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) else {
            return pendingTasks
        }
        return pendingTasks.filter { $0.dueDate < endOfToday }
    }

    var overallHealth: Int {
        let active = plants.filter { $0.effectiveLifecycleState == .active && $0.hasHealthReading }
        guard !active.isEmpty else { return 0 }
        return active.map(\.healthScore).reduce(0, +) / active.count
    }

    /// Incoming handovers still waiting on this account's answer.
    ///
    /// Friends and Plant sitting both read this one list, so an invitation
    /// cannot appear on one screen while the Friends badge claims there is
    /// nothing to answer. Expired, declined and revoked rows drop out because
    /// the live status is read from the dates as well as the stored flag.
    func pendingIncomingSittingInvitations(now: Date = .now) -> [SittingAssignment] {
        assignments
            .filter { $0.isIncoming && $0.currentStatus(now: now) == .invited }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Everything that should light the Friends badge: friend requests plus
    /// plant-sitting invitations awaiting a reply.
    func friendsTabBadgeCount(now: Date = .now) -> Int {
        let requests = friendInvitations.filter { $0.direction == .incoming }.count
        return requests + pendingIncomingSittingInvitations(now: now).count
    }

    func plant(id: UUID) -> Plant? {
        plants.first { $0.id == id }
    }

    // MARK: - Activity

    /// How many entries the feed keeps. Matches the server's own bootstrap
    /// limit, so a synced device and a local-only one agree on how far back
    /// Updates remembers. Without a cap the array grew forever and rode along
    /// in every snapshot write.
    static let activityLimit = 200

    /// Whether the Updates feed holds something the reader has not seen and did
    /// not do themselves.
    ///
    /// The bell used to badge on `dueTasks`, which is neither: it never lit for
    /// new activity, it never cleared when the feed was read, and it duplicated
    /// the numeric badge the Today tab already carries. This is the question the
    /// dot was always claiming to answer.
    var hasUnseenActivity: Bool {
        guard let newest = newestIncomingActivityAt else { return false }
        guard let lastSeen = lastSeenActivityAt else { return true }
        return newest > lastSeen
    }

    /// Records that the feed has been read up to its newest entry.
    ///
    /// Stamped from the newest *incoming* entry, not from the clock: stamping
    /// `.now` would also mark unread anything that arrives in the same second a
    /// sync is landing while the screen is open.
    func markActivitySeen() {
        guard let newest = newestIncomingActivityAt else { return }
        if let lastSeen = lastSeenActivityAt, lastSeen >= newest { return }
        lastSeenActivityAt = newest
        persist()
    }

    private var newestIncomingActivityAt: Date? {
        activity.lazy.filter { !$0.isSelfAuthored }.map(\.timestamp).max()
    }

    /// The one way an activity entry enters the feed.
    ///
    /// Every producer used to `insert(_, at: 0)` and trust that its own entry
    /// was the newest, which held only because they all stamped `.now`. Ordering
    /// is an invariant of the feed, so the feed enforces it — and trims itself
    /// while it is here.
    private func record(_ event: ActivityEvent) {
        let index = activity.firstIndex { $0.timestamp <= event.timestamp } ?? activity.endIndex
        activity.insert(event, at: index)
        if activity.count > Self.activityLimit {
            activity.removeLast(activity.count - Self.activityLimit)
        }
    }

    /// Folds the server's copy of the feed together with this device's.
    ///
    /// A bootstrap is a wholesale replacement for everything the server owns,
    /// but it is not the whole truth about activity: of the app's ten activity
    /// producers the server mirrors two, so a straight assignment deleted the
    /// other eight — completed care, logged care, reschedules, identity
    /// corrections, diagnoses, invitations sent, friendships accepted — on the
    /// first successful sync, and stranded `completionActivityIDs` pointing at
    /// entries that no longer existed. The two mirrored producers now carry the
    /// client's own event id, so the server's row and the local one dedupe by
    /// identity rather than arriving twice.
    static func mergedActivity(local: [ActivityEvent], remote: [ActivityEvent]) -> [ActivityEvent] {
        let remoteIDs = Set(remote.map(\.id))
        let merged = remote + local.filter { !remoteIDs.contains($0.id) }
        return Array(
            merged
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(activityLimit)
        )
    }

    // MARK: - Collections

    func collection(id: UUID) -> PlantCollection? {
        collections.first { $0.id == id }
    }

    /// Plants belonging to a collection, in the app's canonical plant order.
    func plants(in collectionID: UUID) -> [Plant] {
        guard let collection = collection(id: collectionID) else { return [] }
        let members = Set(collection.plantIDs)
        return plants.filter { members.contains($0.id) }
    }

    /// The manual collections a given plant currently belongs to.
    func collections(for plantID: UUID) -> [PlantCollection] {
        collections.filter { $0.plantIDs.contains(plantID) }
    }

    @discardableResult
    func createCollection(
        name: String,
        symbol: String,
        palette: PlantPalette,
        plantIDs: Set<UUID> = []
    ) -> PlantCollection? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        // Preserve canonical plant order in the stored membership.
        let ordered = plants.map(\.id).filter { plantIDs.contains($0) }
        let collection = PlantCollection(
            name: trimmedName,
            symbol: symbol,
            palette: palette,
            plantIDs: ordered
        )
        collections.insert(collection, at: 0)
        persist()
        // A collection can finish a Journey step; pay it now, not on some
        // later unrelated check-in.
        refreshJourney()
        return collection
    }

    func updateCollection(id: UUID, name: String, symbol: String, palette: PlantPalette) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        collections[index].name = trimmedName
        collections[index].symbol = symbol
        collections[index].palette = palette
        persist()
    }

    /// Replaces the membership of a collection, keeping canonical plant order.
    func setPlants(_ plantIDs: Set<UUID>, inCollection id: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].plantIDs = plants.map(\.id).filter { plantIDs.contains($0) }
        persist()
    }

    func toggleMembership(plantID: UUID, inCollection id: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        if let memberIndex = collections[index].plantIDs.firstIndex(of: plantID) {
            collections[index].plantIDs.remove(at: memberIndex)
        } else {
            // Insert in canonical plant order rather than appending.
            var members = Set(collections[index].plantIDs)
            members.insert(plantID)
            collections[index].plantIDs = plants.map(\.id).filter { members.contains($0) }
        }
        persist()
    }

    func deleteCollection(id: UUID) {
        collections.removeAll { $0.id == id }
        persist()
    }

    /// Drops any membership references to plants that no longer exist.
    private func pruneCollectionMembership() {
        let validIDs = Set(plants.map(\.id))
        for index in collections.indices {
            collections[index].plantIDs.removeAll { !validIDs.contains($0) }
        }
    }

    func task(id: UUID) -> CareTask? {
        tasks.first { $0.id == id }
    }

    func observations(for plantID: UUID) -> [PlantObservation] {
        observations
            .filter { $0.plantID == plantID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func diagnoses(for plantID: UUID) -> [PlantDiagnosis] {
        diagnoses
            .filter { $0.plantID == plantID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The diagnosis that still describes the plant's live state.
    ///
    /// Diagnoses remain in the timeline forever, but a later check-in is newer
    /// evidence and must retire the old diagnosis from "current" UI. Keeping
    /// that decision here stops each plant surface from independently deciding
    /// whether an old problem is still active.
    func currentDiagnosis(for plantID: UUID, now: Date = .now) -> PlantDiagnosis? {
        guard let diagnosis = diagnoses(for: plantID).first else { return nil }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        guard diagnosis.createdAt >= cutoff, diagnosis.createdAt <= now else { return nil }
        guard let observation = observations(for: plantID).first else { return diagnosis }
        return diagnosis.createdAt >= observation.createdAt ? diagnosis : nil
    }

    /// The plant's newest photograph, from whichever evidence carries one: a
    /// check-in observation, a diagnosis, or the scan that first identified it.
    ///
    /// One resolver for the whole app. Every plant enters Grove through a
    /// photo, but each surface used to decide for itself which of the three
    /// sources counted — so a plant added by scan showed real imagery on Today
    /// and a gradient on its own page, with the photo on disk the entire time.
    func latestPhotoURL(for plantID: UUID) -> URL? {
        presentationIndex().latestPhotoURLs[plantID]
    }

    /// Every plant's newest photo, keyed by plant.
    ///
    /// Built here rather than at each call site because both places that
    /// schedule reminders need the same map, and a check-in reminder that
    /// carries the previous photo is the "before" shot its own copy promises to
    /// compare against. Remote URLs are included: `UNNotificationAttachment`
    /// only accepts files, so the caller drops anything that is not one.
    var latestPhotoURLs: [UUID: URL] {
        presentationIndex().latestPhotoURLs
    }

    /// When each plant's current presentation photo was captured.
    ///
    /// Kept beside `latestPhotoURLs` so surfaces that choose one plant from a
    /// grove can prefer fresh evidence without rebuilding the photo index or
    /// accidentally treating a missing local file as the newest image.
    var latestPhotoDates: [UUID: Date] {
        presentationIndex().latestPhotoDates
    }

    /// One Grove Score per durable revision/day, shared by Today and its detail
    /// page. Weather, navigation and animation invalidations can now redraw
    /// either screen without re-walking every evidence collection.
    func currentGroveScore() -> GroveScore? {
        let currentRevision = revision
        let currentDay = calendarDay
        if let cachedGroveScore,
           cachedGroveScore.revision == currentRevision,
           cachedGroveScore.calendarDay == currentDay {
            return cachedGroveScore.score
        }
        let score = GroveScore.measure(
            plants: plants,
            observations: observations,
            diagnoses: diagnoses,
            scans: scanHistory,
            tasks: tasks,
            streak: displayStreak
        )
        cachedGroveScore = GroveScoreCache(
            revision: currentRevision,
            calendarDay: currentDay,
            score: score
        )
        return score
    }

    /// The soonest incomplete task for one plant. Profile rows used to filter
    /// and sort the entire task array independently for every visible cell.
    func nextPendingTask(for plantID: UUID) -> CareTask? {
        presentationIndex().nextTasks[plantID]
    }

    private func presentationIndex() -> PresentationIndex {
        // Reading this observable token is intentional: row bodies depend on a
        // narrow scalar, while the expensive arrays below are touched once per
        // mutation rather than once per row.
        let currentRevision = revision
        if let cachedPresentationIndex,
           cachedPresentationIndex.revision == currentRevision {
            return cachedPresentationIndex
        }

        var newestPhotos: [UUID: (date: Date, url: URL)] = [:]
        func consider(plantID: UUID, date: Date, url: URL?) {
            guard let url else { return }
            // A local photo must still be on disk; a server-restored one is a
            // remote signed URL and loads over the network. Paths left over
            // from a previous install are re-rooted at launch, not here.
            guard !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else { return }
            guard newestPhotos[plantID] == nil || date > newestPhotos[plantID]!.date else { return }
            newestPhotos[plantID] = (date, url)
        }
        for observation in observations {
            consider(plantID: observation.plantID, date: observation.createdAt, url: observation.photoURL)
        }
        for diagnosis in diagnoses {
            consider(plantID: diagnosis.plantID, date: diagnosis.createdAt, url: diagnosis.photoURL)
        }
        for scan in scanHistory {
            guard let plantID = scan.plantID else { continue }
            consider(plantID: plantID, date: scan.createdAt, url: scan.photoURL)
        }

        var nextTasks: [UUID: CareTask] = [:]
        for task in tasks where !task.isCompleted {
            if nextTasks[task.plantID] == nil || task.dueDate < nextTasks[task.plantID]!.dueDate {
                nextTasks[task.plantID] = task
            }
        }

        let index = PresentationIndex(
            revision: currentRevision,
            latestPhotoURLs: newestPhotos.mapValues(\.url),
            latestPhotoDates: newestPhotos.mapValues(\.date),
            nextTasks: nextTasks
        )
        cachedPresentationIndex = index
        return index
    }

    /// The history cap of servers deployed before bootstrap reported whether
    /// its history was complete. At or above this count with no flag, an older
    /// server has probably truncated and the local rows it omitted are kept.
    static let legacyBootstrapHistoryCap = 500

    /// Whether a bootstrap history list is only a window over the real history.
    ///
    /// Applying a truncated list wholesale deleted the user's older check-ins
    /// and completed care from this phone on every sync — silent, permanent
    /// data loss. `false` is explicit truncation. `nil` is an older server that
    /// cannot say, so a list as large as its known cap is treated as truncated
    /// too; the cost of being wrong is keeping one stale row, not losing years.
    private static func historyWasTruncated(flag: Bool?, remoteCount: Int) -> Bool {
        if let flag { return !flag }
        return remoteCount >= legacyBootstrapHistoryCap
    }

    /// Local check-ins the truncated window did not include.
    ///
    /// When the server explicitly sent a newest-first window, it is authoritative
    /// inside that window: a check-in deleted elsewhere must not be resurrected.
    /// Only rows strictly older than the oldest returned row are carried. A
    /// legacy server cannot be trusted to have sent a contiguous newest window,
    /// so everything missing is kept.
    private static func carriedTruncatedObservations(
        local: [PlantObservation],
        remote: [PlantObservation],
        remoteIDs: Set<UUID>,
        livePlantIDs: Set<UUID>,
        alreadyCarried: [PlantObservation],
        hasTrustedBoundary: Bool
    ) -> [PlantObservation] {
        let carriedIDs = Set(alreadyCarried.map(\.id))
        let oldestRemote = remote.map(\.createdAt).min()
        return local.filter { observation in
            guard livePlantIDs.contains(observation.plantID) else { return false }
            guard !remoteIDs.contains(observation.id) else { return false }
            guard !carriedIDs.contains(observation.id) else { return false }
            guard hasTrustedBoundary else { return true }
            guard let oldestRemote else { return false }
            return observation.createdAt < oldestRemote
        }
    }

    /// Local completed care the truncated window did not include. Open tasks are
    /// never carried here: Today's live work comes only from the server.
    ///
    /// As with observations, a trusted newest-first window keeps only care
    /// performed strictly before the oldest returned completion; if it returned
    /// no completed care, none qualify. A legacy server's window is unknown, so
    /// every missing completion is kept.
    private static func carriedTruncatedTasks(
        local: [CareTask],
        remote: [CareTask],
        remoteIDs: Set<UUID>,
        livePlantIDs: Set<UUID>,
        deletedTaskIDs: Set<UUID>,
        alreadyCarried: [CareTask],
        hasTrustedBoundary: Bool
    ) -> [CareTask] {
        let carriedIDs = Set(alreadyCarried.map(\.id))
        let oldestRemoteCompleted = remote
            .filter(\.isCompleted)
            .map(\.performedAt)
            .min()
        return local.filter { task in
            guard task.isCompleted else { return false }
            guard !remoteIDs.contains(task.id) else { return false }
            guard livePlantIDs.contains(task.plantID) else { return false }
            guard !deletedTaskIDs.contains(task.id) else { return false }
            guard !carriedIDs.contains(task.id) else { return false }
            guard hasTrustedBoundary else { return true }
            guard let oldestRemoteCompleted else { return false }
            return task.performedAt < oldestRemoteCompleted
        }
    }

    /// Atomically replaces this account's local state with the server's copy.
    ///
    /// Returns `false`, changing nothing, when the remote copy looks like
    /// server amnesia rather than a grove the user actually emptied: a blank
    /// account (no plants, no activity, no Journey) while this device still
    /// holds plants the server has had, or cannot say it never had.
    ///
    /// This is not hypothetical. The sync service keeps account data in process
    /// memory (`Backend/README.md`: "reset when the process exits"), so any
    /// restart, redeploy or scale event returns an empty account — and this
    /// method is a wholesale replacement, so the next sync would delete every
    /// plant, check-in and photo reference the user owns. A wrong bearer token
    /// resolving to a fresh account does the same thing. Losing a user's whole
    /// Grove is unrecoverable and unforgivable; refusing to apply a suspicious
    /// bootstrap costs only a retry.
    ///
    /// It is not a blind overwrite either. `pending` names what the sync queue
    /// has not delivered yet; those records keep their local copy, since the
    /// snapshot predates the change. Check-ins and diagnoses made here that the
    /// server has never returned are kept too (see
    /// `unacknowledgedObservationIDs`).
    @discardableResult
    func replace(
        with bootstrap: GroveBootstrapResponse,
        pending: PendingSyncChanges = .none
    ) -> Bool {
        // An empty plant list alone is not amnesia: the user may have deleted
        // their last plant on another device, or hold only plants the server
        // never acknowledged, and refusing on that alone stopped every later
        // sync for good. A blank account is the signature of a restart or a
        // wrong identity, and it is only dangerous when it would take plants
        // the server has had (an unknown history counts as possibly had).
        let isBlankAccount = bootstrap.plants.isEmpty
            && bootstrap.activity.isEmpty
            && bootstrap.gardener == nil
            && (bootstrap.observations ?? []).isEmpty
        let couldLoseServerPlants = serverKnownPlantIDs.isEmpty
            || plants.contains { serverKnownPlantIDs.contains($0.id) }
        guard !(isBlankAccount && !plants.isEmpty && couldLoseServerPlants) else { return false }
        // The API has no column for light placement yet, so every bootstrap
        // carries it as nil. Assigning the snapshot straight over the top would
        // erase the answer on the first successful sync — the same destructive
        // shape the plan, the avatar and the observation photo URLs below are
        // each protected from. Carry the local answer across where the server
        // has none, and let the server win the day it starts sending one.
        let localPlants = Dictionary(
            uniqueKeysWithValues: plants.map { ($0.id, $0) }
        )
        let localPlacements = Dictionary(
            plants.compactMap { plant in plant.lightPlacement.map { (plant.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        // Same hazard, same remedy: the scan's read of the pot has no column
        // server-side either, and it is the input the watering card's dry-down
        // estimate rests on.
        let localConditions = Dictionary(
            plants.compactMap { plant in plant.growingConditions.map { (plant.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let remotePlantIDs = Set(bootstrap.plants.map(\.id))
        // A plant the server has never once acknowledged is not a plant the
        // server has deleted. Whatever became of its upload, the person who
        // photographed it and named it still has it on a windowsill, and no sync
        // outcome is allowed to take it off their phone.
        let neverAcknowledged = plants.filter { plant in
            !remotePlantIDs.contains(plant.id) && !serverKnownPlantIDs.contains(plant.id)
        }
        plants = bootstrap.plants.compactMap { plant -> Plant? in
            // Deleted here, delete not delivered yet: the snapshot still has
            // it, and showing it again would make the delete look undone.
            if pending.deletedPlantIDs.contains(plant.id) { return nil }
            // Edited or checked in here, change not delivered yet: the local
            // copy is the newer one.
            if pending.plantIDs.contains(plant.id), let local = localPlants[plant.id] { return local }
            var carried = plant
            if plant.lightPlacement == nil, let local = localPlacements[plant.id] {
                carried.lightPlacement = local
            }
            if plant.growingConditions == nil, let local = localConditions[plant.id] {
                carried.growingConditions = local
            }
            if let local = localPlants[plant.id] {
                if carried.lifecycleState == nil { carried.lifecycleState = local.lifecycleState }
                if carried.acquiredAt == nil { carried.acquiredAt = local.acquiredAt }
                if carried.notes == nil { carried.notes = local.notes }
                if carried.environmentReadings == nil { carried.environmentReadings = local.environmentReadings }
                if carried.carePlan == nil { carried.carePlan = local.carePlan }
                if carried.carePlanHistory == nil { carried.carePlanHistory = local.carePlanHistory }
                if carried.assessmentDate == nil { carried.assessmentDate = local.assessmentDate }
                if carried.assessmentSource == nil { carried.assessmentSource = local.assessmentSource }
                if carried.identificationConfidence == nil {
                    carried.identificationConfidence = local.identificationConfidence
                }
                if carried.healthIndicatorReadings == nil {
                    carried.healthIndicatorReadings = local.healthIndicatorReadings
                }
                if carried.checkInFrequencyDays == nil {
                    carried.checkInFrequencyDays = local.checkInFrequencyDays
                }
            }
            return carried
        } + neverAcknowledged
        serverKnownPlantIDs.formUnion(remotePlantIDs)
        pruneCollectionMembership()
        // A task whose plant is not in the same response can never be drawn:
        // every surface that renders one needs the plant to name it, so Today's
        // "Next up" fell silently empty while the tab badge — which counts
        // tasks, not plants — went on advertising work that could not be shown.
        let livePlantIDs = Set(plants.map(\.id))
        let carriedPlantIDs = Set(neverAcknowledged.map(\.id))
        // Same hazard as the plan and the pot, and the most damaging instance of
        // it: care the user logged here has no endpoint to reach the server
        // through, so it comes back missing from every bootstrap. Assigning the
        // remote list straight over the top deleted the watering someone logged
        // this morning and the soil reading they felt on the spot — the two
        // facts the watering card's estimate is drawn from, gone on the first
        // sync after they recorded them, with the card falling back to
        // arithmetic as if they had never touched the plant.
        //
        // Only rows this device minted are carried. A task the server did send
        // once and has since dropped is the server's decision to make, and
        // resurrecting it here would make deletions unstick.
        //
        // A plant the server has never acknowledged is carried whole, so its
        // open tasks come with it: dropping them took its check-in reminder
        // off Today for good. Tasks with an unsent completion keep the local
        // copy, and an undone log whose delete has not landed stays undone.
        let remoteTaskIDs = Set(bootstrap.tasks.map(\.id))
        let localTasks = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let carriedSelfLogged = tasks.filter { task in
            selfLoggedTaskIDs.contains(task.id)
                && !remoteTaskIDs.contains(task.id)
                && livePlantIDs.contains(task.plantID)
        }
        let carriedLocalTasks = tasks.filter { task in
            !selfLoggedTaskIDs.contains(task.id)
                && !remoteTaskIDs.contains(task.id)
                && livePlantIDs.contains(task.plantID)
                && (carriedPlantIDs.contains(task.plantID) || pending.taskIDs.contains(task.id))
        }
        // Completed history is a window, not the whole record. Keep the local
        // completions the window left out, or each sync erases the older care
        // that the Living Record and watering rhythm are drawn from.
        let tasksWereTruncated = Self.historyWasTruncated(
            flag: bootstrap.tasksComplete,
            remoteCount: bootstrap.tasks.count
        )
        let alreadyCarriedTasks = carriedSelfLogged + carriedLocalTasks
        let carriedTruncatedTasks = tasksWereTruncated
            ? Self.carriedTruncatedTasks(
                local: tasks,
                remote: bootstrap.tasks,
                remoteIDs: remoteTaskIDs,
                livePlantIDs: livePlantIDs,
                deletedTaskIDs: pending.deletedTaskIDs,
                alreadyCarried: alreadyCarriedTasks,
                hasTrustedBoundary: bootstrap.tasksComplete == false
            )
            : []
        tasks = bootstrap.tasks.compactMap { task -> CareTask? in
            guard livePlantIDs.contains(task.plantID),
                  !pending.deletedTaskIDs.contains(task.id) else { return nil }
            if pending.taskIDs.contains(task.id), let local = localTasks[task.id] { return local }
            return task
        } + alreadyCarriedTasks + carriedTruncatedTasks
        sittingPlants = bootstrap.sittingPlants ?? []
        let sittingPlantIDs = Set(sittingPlants.map(\.id))
        sittingTasks = (bootstrap.sittingTasks ?? []).filter { sittingPlantIDs.contains($0.plantID) }
        selfLoggedTaskIDs = Set(carriedSelfLogged.map(\.id))
        // Not a replacement: the server mirrors only two of this app's activity
        // producers, so assigning the remote copy over the local one deleted
        // every entry the API has no column for. See `mergedActivity`.
        activity = Self.mergedActivity(local: activity, remote: bootstrap.activity)
        // Handovers created on this phone that the server has not seen yet
        // are kept until they land.
        let remoteAssignmentIDs = Set(bootstrap.assignments.map(\.id))
        let unsentAssignments = pending.sittingAssignments
            ? assignments.filter { !remoteAssignmentIDs.contains($0.id) }
            : []
        assignments = bootstrap.assignments + unsentAssignments
        // The plan is not in the API contract yet, so a bootstrap always
        // carries `plan == nil`. A wholesale profile replacement would
        // therefore delete the user's plan on the first successful sync after
        // they built it. Carry the local one across until the server stores it.
        let localPlan = profile.plan
        // Account creation can discover that the authenticated identity was
        // already provisioned after this iPhone collected a required Grove
        // home. That must not overwrite a real remote location, but an empty
        // remote field must not send Today back to "Set location" either.
        let localLocation = profile.location
        let localAvatarAssetName = profile.avatarAssetName
        let localAvatarPhotoURL = profile.avatarPhotoURL
        // An unsent profile edit is newer than the server's copy.
        profile = pending.profile ? profile : bootstrap.profile
        if profile.plan == nil { profile.plan = localPlan }
        if profile.location == nil { profile.location = localLocation }
        // Profile images are intentionally local until the API has a media
        // contract for them. A routine bootstrap must not reset the user's
        // chosen illustration or discard the protected photo on this device.
        if profile.avatarAssetName == nil, profile.avatarPhotoURL == nil {
            profile.avatarAssetName = localAvatarAssetName
            profile.avatarPhotoURL = localAvatarPhotoURL
        }
        if let remoteObservations = bootstrap.observations {
            // Photo bytes live in object storage and the snapshot deliberately
            // carries `photoURL: nil` for every observation — the server will
            // not claim a URL this device cannot open. That makes a wholesale
            // assignment destructive in exactly the way the plan and avatar
            // above are protected from: the local file reference is the *only*
            // pointer to a check-in photo, so overwriting it orphans every
            // image on disk and silently strips the Living Record hero and
            // every photograph in "What changed" from every plant, on the first
            // successful sync.
            //
            // Carry the local URL across wherever the server has none.
            let localPhotoURLs = Dictionary(
                observations.compactMap { observation in
                    observation.photoURL.map { (observation.id, $0) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            // Check-ins belonging to a plant the server has never seen are held
            // for the same reason the plant itself is: the server cannot be
            // quoted on records it was never told about. So are check-ins made
            // here that the server has not acknowledged yet, whether their
            // upload is still queued or was let go.
            let remoteObservationIDs = Set(remoteObservations.map(\.id))
            let carriedObservations = observations.filter { observation in
                livePlantIDs.contains(observation.plantID)
                    && !remoteObservationIDs.contains(observation.id)
                    && (carriedPlantIDs.contains(observation.plantID)
                        || unacknowledgedObservationIDs.contains(observation.id))
            }
            // The server sends only its newest check-ins. Replacing the local
            // list with that window deleted every older check-in — the Living
            // Record, trends and export all silently lost history. Keep the
            // local rows the window omitted.
            let observationsWereTruncated = Self.historyWasTruncated(
                flag: bootstrap.observationsComplete,
                remoteCount: remoteObservations.count
            )
            let carriedTruncatedObservations = observationsWereTruncated
                ? Self.carriedTruncatedObservations(
                    local: observations,
                    remote: remoteObservations,
                    remoteIDs: remoteObservationIDs,
                    livePlantIDs: livePlantIDs,
                    alreadyCarried: carriedObservations,
                    hasTrustedBoundary: bootstrap.observationsComplete == false
                )
                : []
            unacknowledgedObservationIDs = Set(carriedObservations.map(\.id))
                .intersection(unacknowledgedObservationIDs)
            observations = remoteObservations.filter { livePlantIDs.contains($0.plantID) }.map { observation in
                guard observation.photoURL == nil,
                      let local = localPhotoURLs[observation.id] else { return observation }
                var carried = observation
                carried.photoURL = local
                return carried
            } + carriedObservations + carriedTruncatedObservations
        } else {
            observations.removeAll { !livePlantIDs.contains($0.plantID) }
        }
        if let remoteDiagnoses = bootstrap.diagnoses {
            let localPhotoURLs = Dictionary(
                diagnoses.compactMap { diagnosis in
                    diagnosis.photoURL.map { (diagnosis.id, $0) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            // Diagnoses reach the server only inside a plant update, so one
            // whose update is queued or was dropped is absent here. Keep the
            // ones made here that the server has never returned, and those of
            // a plant it has never seen.
            let remoteDiagnosisIDs = Set(remoteDiagnoses.map(\.id))
            let carriedDiagnoses = diagnoses.filter { diagnosis in
                livePlantIDs.contains(diagnosis.plantID)
                    && !remoteDiagnosisIDs.contains(diagnosis.id)
                    && (carriedPlantIDs.contains(diagnosis.plantID)
                        || unacknowledgedDiagnosisIDs.contains(diagnosis.id))
            }
            unacknowledgedDiagnosisIDs = Set(carriedDiagnoses.map(\.id))
                .intersection(unacknowledgedDiagnosisIDs)
            diagnoses = remoteDiagnoses.filter { livePlantIDs.contains($0.plantID) }.map { diagnosis in
                guard diagnosis.photoURL == nil, let local = localPhotoURLs[diagnosis.id] else { return diagnosis }
                var carried = diagnosis
                carried.photoURL = local
                return carried
            } + carriedDiagnoses
        } else {
            diagnoses.removeAll { !livePlantIDs.contains($0.plantID) }
        }
        // Offline friend decisions must not be undone by the server's older
        // view of the relationship.
        if !pending.friendships {
            if let remoteFriends = bootstrap.friends { friends = remoteFriends }
            if let remoteInvitations = bootstrap.friendInvitations { friendInvitations = remoteInvitations }
        }
        if let remoteInvites = bootstrap.sittingInvites {
            let localByID = Dictionary(
                sittingInvites.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let remoteIDs = Set(remoteInvites.map(\.id))
            // Preserve only attempts the server has never confirmed. A minted
            // row omitted by the authoritative snapshot may have been revoked
            // elsewhere; carrying it would resurrect access in this UI.
            let localOnly = sittingInvites.filter {
                !remoteIDs.contains($0.id) && !$0.isMinted
            }
            sittingInvites = remoteInvites.map { remote in
                var merged = remote
                if remote.revokedAt == nil {
                    let local = localByID[remote.id]
                    merged.revocationRequestedAt = local?.revocationRequestedAt
                    // The server deliberately has no token to return. Preserve
                    // it from memory or Keychain only when a revoke is not
                    // pending on this device.
                    if merged.revocationRequestedAt == nil {
                        merged.shareURL = local?.shareURL
                            ?? activeAccountID.flatMap {
                                SittingInviteURLStore.load(accountID: $0, inviteID: remote.id)
                            }
                    }
                } else if let accountID = activeAccountID {
                    SittingInviteURLStore.remove(accountID: accountID, inviteID: remote.id)
                }
                merged.wasMinted = true
                return merged
            } + localOnly
        }
        // The Journey document is merged, never swapped. Taking whichever copy
        // had the newer revision let a near-empty local document (a new phone
        // that paid the first-plant step before its first sync) stand over the
        // account's real progress, and let an older server copy erase local
        // progress the server had not seen yet. See `mergedGardener`.
        let progressBeforeSync = gardener
        var adoptedServerRevision = false
        if let remoteGardener = bootstrap.gardener,
           let remoteUpdatedAt = bootstrap.gardenerUpdatedAt {
            let localUpdatedAt = gardenerUpdatedAt
            gardener = Self.mergedGardener(
                local: gardener,
                remote: remoteGardener,
                localIsNewer: localUpdatedAt.map { $0 > remoteUpdatedAt } ?? false
            )
            // The server holds `remoteGardener` at `remoteUpdatedAt`, so that
            // is what has been delivered, whatever this phone queued before.
            gardenerEnqueuedAt = remoteUpdatedAt
            if gardener == remoteGardener {
                // Nothing here the server lacks. Adopt its revision so the
                // download is not echoed straight back into the queue.
                gardenerUpdatedAt = remoteUpdatedAt
                persistedGardener = remoteGardener
                adoptedServerRevision = true
            } else {
                // This phone holds progress the server has not seen. Measuring
                // against the server's copy makes `persist()` below mint a
                // revision newer than both, which queues the merged document.
                gardenerUpdatedAt = max(localUpdatedAt ?? remoteUpdatedAt, remoteUpdatedAt)
                persistedGardener = remoteGardener
            }
        }
        gardenerReconciledWithServer = true
        // Pay anything the arrived state qualifies for (outgoing sitting work,
        // plants restored onto a new phone). Celebrate only news: when the
        // server's document brought nothing this phone didn't already have and
        // this isn't a blank phone being restored, a new award was caused by
        // data that just arrived and happened now. A restore, or a catch-up
        // from another device, pays silently like a launch repair.
        let isNews = progressBeforeSync != .new && gardener == progressBeforeSync
        refreshJourney(persistIfChanged: false, announce: isNews)
        if adoptedServerRevision {
            // Awards derived just now are recomputed from synced state, or ride
            // along with the next real change; they don't force an upload of
            // their own over a revision the server already holds.
            persistedGardener = gardener
        }
        profile.friendCount = friends.count
        repairEstimatedCheckInCopy()
        persist()
        return true
    }

    /// Field-by-field union of two copies of the account's Journey document,
    /// so applying either side can never lose what the other earned.
    ///
    /// - Sets of earned things (steps, lessons, badges, chests, keepsakes,
    ///   finds) are unioned; badge dates keep the earliest, the real one.
    /// - XP, longest streak and the learning dividend day take the larger.
    /// - The current streak comes from the run that reaches the later day,
    ///   joined to the other run when the two touch, since days tended on
    ///   either phone are days tended.
    /// - Shields are a spendable balance, so they come from the newer document
    ///   rather than a max that would refund one spent on the other phone.
    /// - Quest counters only combine when both describe the same day.
    private static func mergedGardener(
        local: GardenerProgress,
        remote: GardenerProgress,
        localIsNewer: Bool
    ) -> GardenerProgress {
        let calendar = Calendar.current
        var merged = remote
        merged.xp = max(local.xp, remote.xp)
        merged.completedMilestoneIDs.formUnion(local.completedMilestoneIDs)
        merged.completedInteractiveIDs.formUnion(local.completedInteractiveIDs)
        merged.unlockedBadgeIDs.formUnion(local.unlockedBadgeIDs)
        merged.unlockedBadgeDates.merge(local.unlockedBadgeDates) { min($0, $1) }
        merged.openedChestIDs.formUnion(local.openedChestIDs)
        merged.keepsakeIDs.formUnion(local.keepsakeIDs)
        merged.discoveredLandmarkIDs.formUnion(local.discoveredLandmarkIDs)
        merged.lastRefresherXPDay = [local.lastRefresherXPDay, remote.lastRefresherXPDay]
            .compactMap { $0 }
            .max()

        // Streak: the run that reaches the later day wins (`merged` already
        // holds the remote run), and the larger one on a tie.
        if let localDay = local.lastTendDay {
            let remoteGap = remote.lastTendDay.flatMap { dayGap(from: $0, to: localDay) }
            if remote.lastTendDay == nil || (remoteGap ?? 0) > 0 {
                merged.currentStreak = local.currentStreak
                merged.lastTendDay = local.lastTendDay
                merged.lastShieldStreak = local.lastShieldStreak
            } else if remoteGap == 0 {
                merged.currentStreak = max(local.currentStreak, remote.currentStreak)
                merged.lastShieldStreak = max(local.lastShieldStreak, remote.lastShieldStreak)
            }
            // Join the earlier run on when it ended no more than a day before
            // the later run began (or overlaps it).
            let earlier = merged.lastTendDay == local.lastTendDay ? remote : local
            if let laterDay = merged.lastTendDay,
               let earlierDay = earlier.lastTendDay,
               merged.currentStreak > 0, earlier.currentStreak > 0,
               let laterStart = calendar.date(byAdding: .day, value: -(merged.currentStreak - 1), to: laterDay),
               let earlierStart = calendar.date(byAdding: .day, value: -(earlier.currentStreak - 1), to: earlierDay),
               let touching = dayGap(from: earlierDay, to: laterStart), touching <= 1,
               let span = dayGap(from: min(laterStart, earlierStart), to: laterDay) {
                merged.currentStreak = max(merged.currentStreak, span + 1)
                merged.lastShieldStreak = max(local.lastShieldStreak, remote.lastShieldStreak)
            }
        }
        merged.longestStreak = max(local.longestStreak, remote.longestStreak, merged.currentStreak)
        merged.streakShields = localIsNewer ? local.streakShields : remote.streakShields

        // Quests are a per-day loop: counters from two different days never add.
        switch (local.questDay, remote.questDay) {
        case let (localQuestDay?, remoteQuestDay?)
            where calendar.isDate(localQuestDay, inSameDayAs: remoteQuestDay):
            merged.questCheckIns = max(local.questCheckIns, remote.questCheckIns)
            merged.questCareLogged = max(local.questCareLogged, remote.questCareLogged)
            merged.questLessons = max(local.questLessons, remote.questLessons)
            merged.questPlantsAdded = max(local.questPlantsAdded, remote.questPlantsAdded)
            merged.claimedQuestIDs.formUnion(local.claimedQuestIDs)
        case let (localQuestDay?, remoteQuestDay) where remoteQuestDay.map({ localQuestDay > $0 }) ?? true:
            merged.questDay = local.questDay
            merged.questCheckIns = local.questCheckIns
            merged.questCareLogged = local.questCareLogged
            merged.questLessons = local.questLessons
            merged.questPlantsAdded = local.questPlantsAdded
            merged.claimedQuestIDs = local.claimedQuestIDs
        default:
            break
        }
        return merged
    }

    /// Refresh relationships independently of plant uploads and profile edits.
    func replaceFriendships(with bootstrap: GroveBootstrapResponse) {
        if let remoteFriends = bootstrap.friends { friends = remoteFriends }
        if let remoteInvitations = bootstrap.friendInvitations { friendInvitations = remoteInvitations }
        profile.friendCount = friends.count
        persist()
    }

    /// Removes a plant and everything that only existed because of it: its care
    /// tasks, check-in observations, diagnoses, collection membership, sitting
    /// scope, and activity entries. Photo files are deleted only when no
    /// surviving record still points at them, so a shared scan image is never
    /// pulled out from under the remaining history.
    ///
    /// Plants die, get given away, or get added twice. Without this the only
    /// escape was deleting the entire account's data.
    @discardableResult
    func deletePlant(id: UUID) -> Bool {
        guard plants.contains(where: { $0.id == id }) else { return false }

        let removedMedia = observations.filter { $0.plantID == id }.compactMap(\.photoURL)
            + diagnoses.filter { $0.plantID == id }.compactMap(\.photoURL)
            + scanHistory.filter { $0.plantID == id }.compactMap(\.photoURL)

        plants.removeAll { $0.id == id }
        tasks.removeAll { $0.plantID == id }
        selfLoggedTaskIDs.formIntersection(tasks.map(\.id))
        observations.removeAll { $0.plantID == id }
        diagnoses.removeAll { $0.plantID == id }
        activity.removeAll { $0.plantID == id }
        scanHistory.removeAll { $0.plantID == id }
        pruneCollectionMembership()

        // A sitting assignment that covered only this plant has nothing left to
        // do; the rest simply lose it from their scope.
        for index in assignments.indices {
            assignments[index].plantIDs.removeAll { $0 == id }
        }
        assignments.removeAll { $0.plantIDs.isEmpty }

        // Same for a link handed to a neighbour, except that an invite left with
        // no plants is retired rather than deleted: the row is the only place
        // the owner can see that a link they sent someone is now dead.
        for index in sittingInvites.indices {
            sittingInvites[index].plantIDs.removeAll { $0 == id }
            if sittingInvites[index].plantIDs.isEmpty, sittingInvites[index].revokedAt == nil {
                sittingInvites[index].revocationRequestedAt = .now
                sittingInvites[index].shareURL = nil
                if let accountID = activeAccountID {
                    SittingInviteURLStore.remove(accountID: accountID, inviteID: sittingInvites[index].id)
                }
            }
        }

        let survivingURLs = Set(
            observations.compactMap(\.photoURL)
                + diagnoses.compactMap(\.photoURL)
                + scanHistory.compactMap(\.photoURL)
        )
        let deletedURLs = Set(removedMedia).subtracting(survivingURLs)
        for url in deletedURLs {
            removeOwnedMediaFile(at: url)
        }
        if !deletedURLs.isEmpty { GroveThumbnailCache.clear() }

        persist()
        refreshJourney()
        return true
    }

    /// `lightPlacement` has no default on purpose: it is a nullable field being
    /// written wholesale, and a caller that forgot to pass it would silently
    /// erase the user's answer rather than leave it alone.
    func updatePlant(
        id: UUID,
        nickname: String,
        location: String,
        lightPlacement: PlantLightPlacement?
    ) {
        guard let index = plants.firstIndex(where: { $0.id == id }) else { return }
        let movedRoom = plants[index].location != location
        plants[index].nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        plants[index].location = location
        plants[index].lightPlacement = lightPlacement
        persist()
        // A new room can finish the Journey's rooms step.
        if movedRoom { refreshJourney() }
    }

    /// Sets how often this plant asks for a check-in. A fixed cadence moves the
    /// open check-in to that many days from now; automatic leaves the schedule
    /// alone until the next check-in recalculates it. Returns the moved owner
    /// check-in task so the caller can sync it, or nil when nothing was moved.
    @discardableResult
    func setCheckInFrequency(plantID: UUID, days: Int?) -> CareTask? {
        guard let index = plants.firstIndex(where: { $0.id == plantID }) else { return nil }
        if let days, !Plant.checkInFrequencyOptions.contains(days) { return nil }
        guard plants[index].checkInFrequencyDays != days else { return nil }
        plants[index].checkInFrequencyDays = days
        guard let days else {
            persist()
            return nil
        }
        let date = Calendar.current.date(byAdding: .day, value: days, to: .now) ?? .now
        plants[index].nextCheckIn = date
        let taskIndex = tasks.firstIndex(where: {
            $0.plantID == plantID
                && $0.kind == .checkIn
                && !$0.isCompleted
                && !$0.isSittingTask
        })
        if let taskIndex {
            tasks[taskIndex].dueDate = date
        }
        persist()
        return taskIndex.map { tasks[$0] }
    }

    /// Updates the durable parts of a plant profile that are not the identity
    /// or current health assessment. Passing the complete value set keeps this
    /// one atomic from the editor's point of view and gives sync one payload to
    /// mirror rather than several order-dependent patches.
    @discardableResult
    func updatePlantRecord(
        id: UUID,
        lifecycleState: PlantLifecycleState,
        acquiredAt: Date?,
        notes: String,
        environmentReadings: [PlantEnvironmentReading],
        carePlan: PlantCarePlan?
    ) -> Plant? {
        guard let index = plants.firstIndex(where: { $0.id == id }) else { return nil }
        let wasReceivingReminders = plants[index].effectiveLifecycleState.receivesCareReminders
        plants[index].lifecycleState = lifecycleState
        plants[index].acquiredAt = acquiredAt
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        plants[index].notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        plants[index].environmentReadings = environmentReadings.isEmpty ? nil : environmentReadings

        if let existing = plants[index].carePlan,
           (carePlan == nil || existing.id != carePlan?.id),
           !((plants[index].carePlanHistory ?? []).contains { $0.id == existing.id }) {
            var replaced = existing
            if replaced.status == .active {
                replaced.status = carePlan == nil ? .abandoned : .replaced
            }
            plants[index].carePlanHistory = [replaced] + (plants[index].carePlanHistory ?? [])
        }
        plants[index].carePlan = carePlan
        plants[index].nextActions = carePlan?.actions
            .filter { $0.state == .proposed || $0.state == .due }
            .map(\.instruction) ?? []

        let nowReceivesReminders = lifecycleState.receivesCareReminders
        if !wasReceivingReminders && nowReceivesReminders,
           !tasks.contains(where: { $0.plantID == id && !$0.isCompleted && $0.kind == .checkIn }) {
            tasks.append(
                CareTask(
                    id: UUID(),
                    plantID: id,
                    kind: .checkIn,
                    dueDate: .now,
                    detail: "Take a fresh photo to bring this plant's record back into active care.",
                    isCompleted: false,
                    isSittingTask: false,
                    ownerName: nil
                )
            )
        }
        persist()
        return plants[index]
    }

    /// Records the lifecycle of one recovery-plan step and keeps the compact
    /// `nextActions` summary in lockstep with the structured plan.
    @discardableResult
    func updateCarePlanAction(
        plantID: UUID,
        actionID: UUID,
        state: PlantCarePlanActionState,
        at date: Date = .now
    ) -> Plant? {
        guard let plantIndex = plants.firstIndex(where: { $0.id == plantID }),
              var plan = plants[plantIndex].carePlan,
              plan.status == .active,
              let actionIndex = plan.actions.firstIndex(where: { $0.id == actionID }) else { return nil }
        plan.actions[actionIndex].state = state
        plan.actions[actionIndex].completedAt = (state == .completed || state == .skipped) ? date : nil
        plants[plantIndex].carePlan = plan
        plants[plantIndex].nextActions = plan.actions
            .filter { $0.state == .proposed || $0.state == .due }
            .map(\.instruction)
        persist()
        return plants[plantIndex]
    }

    /// Records what a check turned up. The check is done, the result is kept
    /// against it, and the step that result leads to joins the plan right
    /// after it, so "Green under the bark" becomes something to do rather than
    /// something the owner has to carry to Ari.
    @discardableResult
    func recordCheckFinding(
        plantID: UUID,
        actionID: UUID,
        outcomeID: String,
        at date: Date = .now
    ) -> Plant? {
        guard let plantIndex = plants.firstIndex(where: { $0.id == plantID }),
              var plan = plants[plantIndex].carePlan,
              plan.status == .active,
              let actionIndex = plan.actions.firstIndex(where: { $0.id == actionID }),
              let outcome = plan.actions[actionIndex].outcomes?.first(where: { $0.id == outcomeID }) else { return nil }
        plan.actions[actionIndex].state = .completed
        plan.actions[actionIndex].completedAt = date
        plan.actions[actionIndex].findingID = outcome.id
        let step = outcome.nextStep.trimmingCharacters(in: .whitespacesAndNewlines)
        if !step.isEmpty {
            plan.actions.insert(
                PlantCarePlanAction(
                    id: UUID(),
                    kind: Self.careKind(for: step),
                    instruction: step,
                    rationale: outcome.meaning,
                    dueFrom: date,
                    dueUntil: plan.reviewAt,
                    expectedResponse: "Review the response at the next check-in.",
                    state: .due,
                    completedAt: nil
                ),
                at: actionIndex + 1
            )
        }
        plants[plantIndex].carePlan = plan
        plants[plantIndex].nextActions = plan.actions
            .filter { $0.state == .proposed || $0.state == .due }
            .map(\.instruction)
        persist()
        return plants[plantIndex]
    }

    /// Puts a plan back exactly as it was, for undoing a recorded finding.
    @discardableResult
    func restoreCarePlan(plantID: UUID, to plan: PlantCarePlan) -> Plant? {
        guard let plantIndex = plants.firstIndex(where: { $0.id == plantID }),
              plants[plantIndex].carePlan?.id == plan.id else { return nil }
        plants[plantIndex].carePlan = plan
        plants[plantIndex].nextActions = plan.actions
            .filter { $0.state == .proposed || $0.state == .due }
            .map(\.instruction)
        persist()
        return plants[plantIndex]
    }

    /// Scientific names in the grove that have no canonical taxon id yet, newest
    /// plant first so a scan just taken resolves before an old backlog does.
    var scientificNamesAwaitingTaxonID: [String] {
        var seen = Set<String>()
        return plants
            .filter { $0.canonicalTaxonID == nil }
            .sorted { ($0.acquiredAt ?? .distantPast) > ($1.acquiredAt ?? .distantPast) }
            .map(\.scientificName)
            .filter { PlantTaxonResolver.isResolvable($0) && seen.insert(PlantTaxonResolver.normalized($0)).inserted }
    }

    /// Writes resolved taxon ids onto every plant carrying a matching name.
    ///
    /// Only the id changes. The species, the common name and the confirmation
    /// state are what the user accepted and are not this pass's to revise — the
    /// whole point is that the plant page reads exactly as it did, while the
    /// safety catalogue and the care profile stop matching on display text.
    @discardableResult
    func applyCanonicalTaxonIDs(_ resolved: [String: String]) -> Int {
        guard !resolved.isEmpty else { return 0 }
        let byName = Dictionary(
            resolved.map { (PlantTaxonResolver.normalized($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        var applied = 0
        for index in plants.indices {
            guard plants[index].canonicalTaxonID == nil,
                  let id = byName[PlantTaxonResolver.normalized(plants[index].scientificName)] else { continue }
            plants[index].canonicalTaxonID = id
            applied += 1
        }
        if applied > 0 { persist() }
        return applied
    }

    func updatePlantIdentity(
        id: UUID,
        candidate: SpeciesCandidate,
        confirmation: PlantIdentityConfirmation = .userConfirmed
    ) {
        guard let index = plants.firstIndex(where: { $0.id == id }) else { return }
        plants[index].species = candidate.commonName
        plants[index].scientificName = candidate.scientificName
        plants[index].canonicalTaxonID = candidate.canonicalTaxonID
            ?? (candidate.id.hasPrefix("gbif:") ? candidate.id : nil)
        plants[index].identityConfirmation = confirmation
        // Identification confidence only. Writing this into `confidence` used to
        // make the plant page announce "high confidence" about a health reading
        // that a species correction does not recompute — the app growing *more*
        // sure of itself at the exact moment the user told it that it had been
        // wrong.
        plants[index].identificationConfidence = confirmation == .manualEntry
            ? nil
            : candidate.confidence
        plants[index].summary = "Identity corrected. Recheck species-specific care before making further changes."
        plants[index].nextActions = [
            "Review light and moisture guidance for \(candidate.commonName)",
            "Use the next check-in to establish a new comparison baseline"
        ]
        record(
            ActivityEvent(
                id: UUID(),
                kind: .milestone,
                actorName: ActivityEvent.selfActorName,
                actorInitials: profile.initials,
                // A typed name is the owner's word, not a confirmation.
                message: confirmation == .manualEntry
                    ? "renamed it to \(candidate.commonName)"
                    : "confirmed the identity as \(candidate.commonName)",
                plantID: id,
                timestamp: .now
            )
        )
        persist()
    }

    /// Changes only the plant's common (display) name.
    ///
    /// Calling `updatePlantIdentity` for this cleared the taxon id, downgraded
    /// a confirmed identity to a manual one, replaced the care summary and
    /// logged "confirmed the identity", all because the owner preferred
    /// "Monstera" to "Swiss cheese plant". The species has not changed, so
    /// nothing that hangs off the species does either.
    func renamePlantSpecies(id: UUID, commonName: String) {
        let name = commonName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = plants.firstIndex(where: { $0.id == id }),
              plants[index].species != name else { return }
        plants[index].species = name
        record(
            ActivityEvent(
                id: UUID(),
                kind: .milestone,
                actorName: ActivityEvent.selfActorName,
                actorInitials: profile.initials,
                message: "renamed it to \(name)",
                plantID: id,
                timestamp: .now
            )
        )
        persist()
    }

    func recordScan(
        id: UUID,
        mode: ScanMode,
        result: PlantAnalysisResult,
        photoURL: URL?,
        plantID: UUID? = nil,
        createdAt: Date = .now
    ) {
        let existing = scanHistory.first(where: { $0.id == id })
        let resolvedCreatedAt = existing?.createdAt ?? createdAt
        // Result views and the add-plant handoff can both replay this write. A
        // slower, older write that did not know the plant yet must never unlink
        // a scan after the adoption write attached it.
        let resolvedPlantID = plantID ?? existing?.plantID
        let resolvedPhotoURL = photoURL ?? existing?.photoURL
        scanHistory.removeAll { $0.id == id }
        scanHistory.insert(
            ScanHistoryRecord(
                id: id,
                createdAt: resolvedCreatedAt,
                mode: mode,
                commonName: result.identification.commonName,
                scientificName: result.identification.scientificName,
                identificationConfidence: result.identification.confidence,
                healthScore: result.condition.healthScore,
                healthBand: result.condition.healthBand,
                photoURL: resolvedPhotoURL,
                plantID: resolvedPlantID,
                summary: result.condition.summary,
                isUnknown: result.identification.isUnknown,
                analysisVersion: result.analysisVersion
            ),
            at: 0
        )
        persist()
    }

    func deleteScanHistory(ids: Set<UUID>) {
        let removed = scanHistory.filter { ids.contains($0.id) }
        scanHistory.removeAll { ids.contains($0.id) }
        let remainingURLs = Set(scanHistory.compactMap(\.photoURL) + observations.compactMap(\.photoURL) + diagnoses.compactMap(\.photoURL))
        for url in removed.compactMap(\.photoURL) where !remainingURLs.contains(url) {
            removeOwnedMediaFile(at: url)
        }
        persist()
    }

    @discardableResult
    func addDiagnosis(
        id: UUID = UUID(),
        plantID: UUID,
        result: PlantAnalysisResult,
        photoURL: URL?,
        createdAt: Date = .now
    ) -> PlantDiagnosis? {
        guard let index = plants.firstIndex(where: { $0.id == plantID }) else { return nil }
        let condition = result.condition
        let existingDiagnosis = diagnoses.first { $0.id == id }
        // A refined result is still the same scan and the same moment in the
        // plant's history. Reusing its date keeps the recovery window stable
        // when SwiftUI recreates the result page or the user answers a
        // clarifying question.
        let diagnosisDate = existingDiagnosis?.createdAt ?? createdAt
        let indicatorReadings = PlantHealthIndicators.recordedReadings(
            for: plants[index],
            soil: nil,
            hasNewGrowth: nil,
            visualFindings: PlantHealthIndicators.visualFindings(from: condition),
            growingConditions: result.growingConditions,
            tasks: tasks,
            assessmentAvailable: condition.assessmentAvailable != false,
            analysisVersion: result.analysisVersion,
            now: diagnosisDate
        )
        let followUpDays = min(
            max(condition.followUpDays ?? Self.defaultFollowUpDays(for: condition.healthBand), 1),
            30
        )
        let followUpDate = Calendar.current.date(
            byAdding: .day,
            value: followUpDays,
            to: diagnosisDate
        ) ?? diagnosisDate
        // Provisional visual evidence belongs in the timeline, but it must not
        // overwrite a plant's canonical score, care plan, pot facts, or reminder
        // before the user supplies the evidence the analysis itself says is
        // missing. Results created before this policy field remain actionable.
        let shouldApplyToPlant = condition.actionability == nil || condition.actionability == .actionable
        if shouldApplyToPlant {
            let previousScore = plants[index].healthScore
            let hadReading = plants[index].hasHealthReading
            plants[index].healthScore = condition.healthScore
            plants[index].healthBand = condition.healthBand
            plants[index].confidence = condition.confidence
            plants[index].summary = condition.summary
            plants[index].concerns = condition.concerns
            plants[index].positiveSigns = condition.positiveSigns
            plants[index].nextActions = condition.nextActions
            // A first diagnosis of an unassessed plant is its baseline, not a
            // move away from the hidden placeholder score.
            plants[index].trend = hadReading ? Self.trend(from: previousScore, to: condition.healthScore) : .baseline
            plants[index].nextCheckIn = followUpDate
            plants[index].assessmentDate = diagnosisDate
            plants[index].assessmentSource = .diagnosisPhoto
            plants[index].healthIndicatorReadings = indicatorReadings
            Self.replaceCarePlan(
                on: &plants[index],
                goal: condition.summary,
                actions: condition.nextActions,
                checks: condition.checks ?? [],
                reviewAt: followUpDate,
                at: diagnosisDate
            )
            // A diagnose scan photographs the same pot again, and pots change:
            // people repot or add a cover. Only an actionable newer read that
            // actually saw something replaces the established record.
            if let refreshed = Self.stamped(result.growingConditions) {
                plants[index].growingConditions = refreshed
            }

            // Saving an actionable diagnosis also sets the recovery check-in.
            // A provisional result stays a review item instead of silently
            // changing the user's future care queue.
            if let taskIndex = tasks.firstIndex(where: {
                $0.plantID == plantID && $0.kind == .checkIn && !$0.isCompleted
            }) {
                tasks[taskIndex].dueDate = followUpDate
                tasks[taskIndex].detail = "One fresh photo, compared with this diagnosis."
            } else {
                tasks.append(
                    CareTask(
                        id: UUID(),
                        plantID: plantID,
                        kind: .checkIn,
                        dueDate: followUpDate,
                        detail: "One fresh photo, compared with this diagnosis.",
                        isCompleted: false,
                        isSittingTask: false,
                        ownerName: nil
                    )
                )
            }
        }

        let diagnosis = PlantDiagnosis(
            id: id,
            plantID: plantID,
            createdAt: diagnosisDate,
            summary: condition.summary,
            healthBand: condition.healthBand,
            confidence: condition.confidence,
            possibleConditions: condition.possibleConditions ?? [],
            actionsToTake: condition.nextActions,
            actionsToAvoid: condition.actionsToAvoid ?? [],
            providerName: result.providerName,
            identificationConfidence: result.identification.confidence,
            identificationRequiresConfirmation: result.identification.requiresConfirmation,
            visiblePositiveSigns: condition.positiveSigns,
            visibleConcerns: condition.concerns,
            clarifyingQuestions: condition.questions,
            limitations: result.limitations,
            analysisVersion: result.analysisVersion,
            actionability: condition.actionability,
            photoURL: photoURL ?? existingDiagnosis?.photoURL,
            indicatorReadings: indicatorReadings
        )
        diagnoses.removeAll { $0.id == id }
        diagnoses.insert(diagnosis, at: 0)
        unacknowledgedDiagnosisIDs.insert(diagnosis.id)
        if existingDiagnosis == nil {
            record(
                ActivityEvent(
                    id: id,
                    kind: .milestone,
                    actorName: ActivityEvent.selfActorName,
                    actorInitials: profile.initials,
                    message: "added a concern diagnosis: \(condition.healthBand.shortTitle.lowercased())",
                    plantID: plantID,
                    timestamp: diagnosisDate
                )
            )
        }
        // A diagnosis is an inspection: a photograph of a real plant and a look
        // at what it shows. The streak's rule is that it advances on learning
        // and inspection and never on watering, so this qualifies — and the
        // person whose plant is sick was the one losing their streak for
        // attending to it, which is exactly backwards.
        //
        // Only on a genuinely new diagnosis: refining an existing one is the
        // same look, and `recordTend` is once a day regardless.
        //
        // Deliberately *not* `recordQuestProgress(.look)` — the look quest's own
        // copy says a completed check-in is what counts, and a quest that pays
        // out for something its description excludes is worse than a strict one.
        if existingDiagnosis == nil { recordTend() }
        persist()
        refreshJourney()
        return diagnosis
    }

    /// Everything this device can rule out before a username goes anywhere.
    ///
    /// Whether the gardener *exists* is not on this list: only the server knows
    /// that, which is why sending an invitation waits for its answer instead of
    /// showing a Pending row for a handle nobody has claimed.
    enum FriendInviteProblem: Equatable {
        case emptyUsername
        case yourself
        case alreadyFriends
        case alreadyInvited
        case incomingInvitation

        var message: String {
            switch self {
            case .emptyUsername: "Type the username of someone on Grove."
            case .yourself: "That one is yours. Invite someone else."
            case .alreadyFriends: "You two are already connected."
            case .alreadyInvited: "That invitation is already waiting on them."
            case .incomingInvitation: "They invited you first. Open Connection requests to accept."
            }
        }
    }

    static func normalizedUsername(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }

    func friendInviteProblem(for username: String) -> FriendInviteProblem? {
        let normalized = Self.normalizedUsername(username)
        if normalized.isEmpty { return .emptyUsername }
        if normalized == profile.username.lowercased() { return .yourself }
        if friends.contains(where: { $0.username.lowercased() == normalized }) { return .alreadyFriends }
        if let invitation = friendInvitations.first(where: { $0.username.lowercased() == normalized }) {
            return invitation.direction == .incoming ? .incomingInvitation : .alreadyInvited
        }
        return nil
    }

    /// Records an invitation the server has already accepted.
    ///
    /// `id`, `accountID` and `displayName` come from that answer, so the pending
    /// row names a real gardener and carries the id the withdraw call needs.
    @discardableResult
    func inviteFriend(
        username: String,
        accountID: String? = nil,
        displayName: String? = nil,
        id: UUID = UUID(),
        activityEventID: UUID = UUID()
    ) -> FriendInvitation? {
        let normalized = Self.normalizedUsername(username)
        guard friendInviteProblem(for: normalized) == nil else { return nil }
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmedName.isEmpty ? "@\(normalized)" : trimmedName
        let invitation = FriendInvitation(
            id: id,
            accountID: accountID,
            name: name,
            username: normalized,
            initials: trimmedName.isEmpty
                ? String(normalized.prefix(2)).uppercased()
                : Self.initials(for: trimmedName),
            direction: .outgoing,
            createdAt: .now
        )
        friendInvitations.insert(invitation, at: 0)
        record(
            ActivityEvent(
                id: activityEventID,
                kind: .friendship,
                actorName: ActivityEvent.selfActorName,
                actorInitials: profile.initials,
                message: "sent a trusted-person invitation",
                plantID: nil,
                timestamp: .now
            )
        )
        persist()
        return invitation
    }

    /// Accepts an incoming invitation and returns the mutation the caller must
    /// enqueue, so the friendship becomes real for the other gardener too.
    ///
    /// Returns nil when there is nothing to accept. The local list updates
    /// immediately — the friend should appear the moment the card is tapped —
    /// and the next bootstrap reconciles against the server's answer.
    @discardableResult
    func acceptFriendInvitation(id: UUID, activityEventID: UUID = UUID()) -> RespondToFriendInvitationRequest? {
        guard let index = friendInvitations.firstIndex(where: { $0.id == id && $0.direction == .incoming }) else { return nil }
        let invitation = friendInvitations.remove(at: index)
        // A stale bootstrap can briefly contain both an accepted relationship
        // and its old pending row. Answer the server row, but never render the
        // same person twice while reconciliation catches up.
        let alreadyPresent = friends.contains { friend in
            if let accountID = invitation.accountID, friend.id == accountID { return true }
            return friend.username.caseInsensitiveCompare(invitation.username) == .orderedSame
        }
        if !alreadyPresent {
            friends.append(
                PlantFriend(
                    id: invitation.accountID ?? "local-\(invitation.username)",
                    name: invitation.name,
                    username: invitation.username,
                    initials: invitation.initials,
                    sharedPlantCount: 0,
                    lastActiveAt: .now
                )
            )
        }
        profile.friendCount = friends.count
        if !alreadyPresent {
            record(
                ActivityEvent(
                    id: activityEventID,
                    kind: .friendship,
                    actorName: ActivityEvent.selfActorName,
                    actorInitials: profile.initials,
                    message: "accepted a trusted-person invitation",
                    plantID: nil,
                    timestamp: .now
                )
            )
        }
        persist()
        return RespondToFriendInvitationRequest(invitationID: id, accept: true, clientRequestID: UUID())
    }

    /// Takes back an invitation this account sent, and returns the mutation the
    /// caller must enqueue so it stops waiting in the other gardener's requests.
    ///
    /// The activity entry for sending it stays: it happened, and rewriting the
    /// feed to pretend otherwise is the one thing a history must never do.
    @discardableResult
    func withdrawFriendInvitation(id: UUID) -> WithdrawFriendInvitationRequest? {
        guard let index = friendInvitations.firstIndex(where: { $0.id == id && $0.direction == .outgoing }) else { return nil }
        friendInvitations.remove(at: index)
        persist()
        return WithdrawFriendInvitationRequest(invitationID: id, clientRequestID: UUID())
    }

    /// Declines an incoming invitation. Nothing is added to the activity feed:
    /// saying no is the user's business, not a moment to celebrate.
    @discardableResult
    func declineFriendInvitation(id: UUID) -> RespondToFriendInvitationRequest? {
        guard let index = friendInvitations.firstIndex(where: { $0.id == id && $0.direction == .incoming }) else { return nil }
        friendInvitations.remove(at: index)
        persist()
        return RespondToFriendInvitationRequest(invitationID: id, accept: false, clientRequestID: UUID())
    }

    /// Applies a removal the server has already confirmed. Sitting links are
    /// independent bearer capabilities and remain visible under Plant Sitting
    /// so their owner can revoke them explicitly.
    @discardableResult
    func removeFriend(id: String) -> PlantFriend? {
        guard let index = friends.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = friends.remove(at: index)
        profile.friendCount = friends.count
        friendInvitations.removeAll { $0.accountID == id }
        persist()
        return removed
    }

    /// Ticks a scheduled task off. A watering is refused while the plant has a
    /// watering inside `recentWateringWindow`, unless `force` is set — the same
    /// "check, then act" rule as `logCare`, so a scheduled reminder cannot
    /// become a second watering an hour after the first.
    @discardableResult
    func complete(taskID: UUID, at performedAt: Date = .now, force: Bool = false) -> CareTask? {
        guard let index = tasks.firstIndex(where: { $0.id == taskID && !$0.isCompleted }) else { return nil }
        if !force,
           tasks[index].kind == .water,
           lastWatering(for: tasks[index].plantID, at: performedAt) != nil {
            return nil
        }
        tasks[index].isCompleted = true
        // The tick's own timestamp, not the reminder's. A watering done three
        // days after it was due is three days of dry-down that every history on
        // the plant page used to lose.
        tasks[index].completedAt = performedAt
        let completedTask = tasks[index]
        if completedTask.isSittingTask,
           let assignmentIndex = assignments.firstIndex(where: {
               $0.plantIDs.contains(completedTask.plantID) && !$0.hasEnded()
           }) {
            assignments[assignmentIndex].completedTasks = min(
                assignments[assignmentIndex].totalTasks,
                assignments[assignmentIndex].completedTasks + 1
            )
        }
        let event = ActivityEvent(
            id: UUID(),
            kind: completedTask.isSittingTask ? .sitterCare : .milestone,
            actorName: ActivityEvent.selfActorName,
            actorInitials: profile.initials,
            message: "completed \(completedTask.kind.loggedTitle)",
            plantID: completedTask.plantID,
            timestamp: performedAt
        )
        record(event)
        completionActivityIDs[taskID] = event.id
        // The plant-safe streak advances on inspection only. Watering (and
        // other care actions) must never extend it, or the streak becomes an
        // overwatering incentive; check-ins record their tend in
        // `applyCheckIn`.
        if completedTask.kind == .inspectSoil { recordTend(on: performedAt) }
        // The board splits the same way the streak does: inspection is looking,
        // everything else is tending. A soil check used to pay out the *tend*
        // quest, which left "look" asking for a full photo check-in every day
        // while the plant's own care plan said not to look again for a
        // fortnight. One of those two had to be wrong, and it was the quest.
        //
        // Check-ins are the exception: `applyCheckIn` owns their credit, so
        // completing the task must not pay twice. Watering, feeding and
        // treating pay nothing at all; see `questObjective(for:)`.
        if Calendar.current.isDate(performedAt, inSameDayAs: calendarDay),
           let objective = Self.questObjective(for: completedTask.kind) {
            recordQuestProgress(objective, on: performedAt)
        }
        // Soil checks recur, for the same reason check-ins do: without this the
        // plant leaves the care queue after its first one and the fortnight
        // goes quiet again. A sitter's tick schedules nothing — the rhythm
        // belongs to the owner's grove, not to the week someone covered it.
        if completedTask.kind == .inspectSoil, !completedTask.isSittingTask {
            rescheduleSoilCheck(for: completedTask.plantID, from: performedAt)
        }
        persist()
        refreshJourney()
        return tasks[index]
    }

    /// Puts a completed care task back on the queue.
    ///
    /// A task can now be ticked off from a list in one tap, with nothing in
    /// front of it. That is only a fair trade if the tap is reversible, so this
    /// restores the task, rolls back the sitting assignment's progress, and
    /// retracts the activity entry the completion wrote — a plant's history
    /// should not record care that did not happen.
    ///
    /// XP and badges are deliberately *not* clawed back. They were awarded
    /// against real Grove state, they are shared with other milestones, and
    /// quietly taking progress away is a far worse surprise than being a few
    /// points generous.
    ///
    /// The streak is the one exception, and only for a tend this device minted
    /// itself. A scheduled soil check that was ticked and untucked leaves the
    /// day tended — the user did look at the plant. But the watering card logs a
    /// soil reading the instant a word is tapped, so its undo is the correction
    /// for a mistap, and a day cannot stand as tended on a reading that has been
    /// retracted along with the row that held it. Restored exactly, and only
    /// while nothing else has tended since; see `TendRollback`.
    ///
    /// A self-logged row is *removed* rather than uncompleted. It describes care
    /// the user says they performed, so there is no queue for it to go back to —
    /// leaving it pending invented a chore out of a tap that was taken back, and
    /// put it in Today under a due date of the moment it was undone.
    @discardableResult
    func undoCompletion(taskID: UUID) -> CareTask? {
        guard let index = tasks.firstIndex(where: { $0.id == taskID && $0.isCompleted }) else { return nil }
        if selfLoggedTaskIDs.contains(taskID) {
            return undoSelfLoggedCare(at: index)
        }
        let performedAt = tasks[index].performedAt
        tasks[index].isCompleted = false
        let restored = tasks[index]
        // The tick paid today's board; taking it back takes that back too, so
        // tick-untick-tick cannot run a counter up.
        if let objective = Self.questObjective(for: restored.kind) {
            retractQuestProgress(objective, earnedOn: performedAt)
        }
        if restored.isSittingTask,
           let assignmentIndex = assignments.firstIndex(where: {
               $0.plantIDs.contains(restored.plantID) && !$0.hasEnded()
           }) {
            assignments[assignmentIndex].completedTasks = max(
                0,
                assignments[assignmentIndex].completedTasks - 1
            )
        }
        if let eventID = completionActivityIDs.removeValue(forKey: taskID) {
            activity.removeAll { $0.id == eventID }
        }
        persist()
        return restored
    }

    /// Takes back a care action the user logged themselves: the row goes, its
    /// history entry goes, and a streak day it minted goes with it.
    private func undoSelfLoggedCare(at index: Int) -> CareTask {
        let removed = tasks.remove(at: index)
        selfLoggedTaskIDs.remove(removed.id)

        if let eventID = completionActivityIDs.removeValue(forKey: removed.id) {
            activity.removeAll { $0.id == eventID }
        }

        if let objective = Self.questObjective(for: removed.kind) {
            retractQuestProgress(objective, earnedOn: removed.performedAt)
        }

        if let rollback = tendRollbacks.removeValue(forKey: removed.id), lastTendTaskID == removed.id {
            gardener.currentStreak = rollback.currentStreak
            gardener.longestStreak = rollback.longestStreak
            gardener.lastTendDay = rollback.lastTendDay
            gardener.streakShields = rollback.streakShields
            gardener.lastShieldStreak = rollback.lastShieldStreak
            lastTendTaskID = nil
            // A celebration nobody has seen yet belongs to a day that no longer
            // happened. One the user already saw is theirs to keep.
            pendingStreakMoment = nil
        }

        persist()
        refreshJourney()
        return removed
    }

    /// Records care the user performed outside a scheduled task — "I watered it
    /// this morning" — as a completed care action plus an attributed activity
    /// entry.
    ///
    /// The product has always promised that "care events can be logged outside
    /// a check-in", and it is the single most common thing a plant owner
    /// actually does. Without this, real care only entered the record when
    /// Grove happened to have scheduled a task for it, so the history under-
    /// reported what the owner had done and the next assessment reasoned from
    /// an incomplete picture.
    ///
    /// Undo-able through `undoCompletion(taskID:)` like any other completion.
    ///
    /// Watering inside `recentWateringWindow` of the last logged watering is
    /// refused unless `force` is set — see `lastWatering(for:)`.
    /// What a self-logged care action says when the user left no note.
    ///
    /// Named rather than inlined because surfaces that *render* the record have
    /// to be able to tell this apart from something the user actually wrote —
    /// the plant page's change timeline drops it rather than printing the same
    /// boilerplate under every row.
    nonisolated static let selfLoggedCareDetail = "You recorded this yourself. It was never on the list."

    @discardableResult
    func logCare(
        plantID: UUID,
        kind: CareKind,
        note: String = "",
        soilMoisture: ObservationSoilMoisture? = nil,
        performedAt: Date = .now,
        force: Bool = false
    ) -> CareTask? {
        guard plants.contains(where: { $0.id == plantID }) else { return nil }
        if !force, kind == .water, lastWatering(for: plantID, at: performedAt) != nil { return nil }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = CareTask(
            id: UUID(),
            plantID: plantID,
            kind: kind,
            dueDate: performedAt,
            detail: trimmedNote.isEmpty ? Self.selfLoggedCareDetail : trimmedNote,
            isCompleted: true,
            isSittingTask: false,
            ownerName: nil,
            soilMoisture: soilMoisture,
            // Already true of `dueDate` on this path, but recorded explicitly
            // so the rhythm chart can tell a real record from a reminder date.
            completedAt: performedAt
        )
        tasks.append(task)
        selfLoggedTaskIDs.insert(task.id)
        let event = ActivityEvent(
            id: UUID(),
            kind: .milestone,
            actorName: ActivityEvent.selfActorName,
            actorInitials: profile.initials,
            message: trimmedNote.isEmpty
                ? "logged \(kind.loggedTitle)"
                : "logged \(kind.loggedTitle): \(trimmedNote)",
            plantID: plantID,
            timestamp: performedAt
        )
        record(event)
        completionActivityIDs[task.id] = event.id
        // Same plant-safe rule as `complete`: only inspection tends the streak,
        // so logging a watering can never become an incentive to water.
        if kind == .inspectSoil {
            let before = TendRollback(
                currentStreak: gardener.currentStreak,
                longestStreak: gardener.longestStreak,
                lastTendDay: gardener.lastTendDay,
                streakShields: gardener.streakShields,
                lastShieldStreak: gardener.lastShieldStreak
            )
            recordTend(on: performedAt)
            tendRollbacks[task.id] = before
            lastTendTaskID = task.id
        }
        // Same split as `complete`: feeling the soil is a look, and watering,
        // feeding and treating pay no quest at all.
        if Calendar.current.isDate(performedAt, inSameDayAs: calendarDay),
           let objective = Self.questObjective(for: kind) {
            recordQuestProgress(objective, on: performedAt)
        }
        // Care logged by hand moves the rhythm the same way a ticked task does.
        // Someone who waters on Sunday must not be asked to feel dry soil on
        // Monday: the scheduled check would be wrong, and being wrong about the
        // one reading Grove asks for is how it loses the benefit of the doubt.
        if kind == .inspectSoil || kind == .water {
            rescheduleSoilCheck(for: plantID, from: performedAt)
        }
        persist()
        refreshJourney()
        return task
    }

    /// How recently a plant must have been watered for another watering to
    /// count as a repeat rather than as care.
    static let recentWateringWindow: TimeInterval = RecentWateringGuard.window

    /// The last watering inside `recentWateringWindow`, if there is one.
    ///
    /// `GROVE.md` requires that "conflicting actions should be prevented; for
    /// example, repeated watering after a recent watering event", and the whole
    /// product rests on "check, then act". Nothing enforced it: an anxious owner
    /// could log five waterings in five seconds and be thanked five times, and
    /// the page's own record of the last one was the final block on a very long
    /// scroll — three swipes below the button that let them do it again.
    ///
    /// This lives in the store rather than in a view because three surfaces log
    /// care: the plant page, the grid's long-press menu, and the watch.
    func lastWatering(for plantID: UUID, at date: Date = .now) -> CareTask? {
        let cutoff = date.addingTimeInterval(-Self.recentWateringWindow)
        return tasks
            .filter {
                $0.plantID == plantID
                    && $0.kind == .water
                    && $0.isCompleted
                    && $0.performedAt >= cutoff
                    && $0.performedAt <= date
            }
            .max { $0.performedAt < $1.performedAt }
    }

    @discardableResult
    func snooze(taskID: UUID, until date: Date, reason: String) -> CareTask? {
        guard date > .now,
              let index = tasks.firstIndex(where: { $0.id == taskID && !$0.isCompleted }) else { return nil }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        tasks[index].dueDate = date
        let snoozedTask = tasks[index]
        record(
            ActivityEvent(
                id: UUID(),
                kind: .milestone,
                actorName: ActivityEvent.selfActorName,
                actorInitials: profile.initials,
                message: trimmedReason.isEmpty
                    ? "rescheduled \(snoozedTask.kind.loggedTitle)"
                    : "rescheduled \(snoozedTask.kind.loggedTitle): \(trimmedReason)",
                plantID: snoozedTask.plantID,
                timestamp: .now
            )
        )
        persist()
        return snoozedTask
    }

    @discardableResult
    func applyCheckIn(
        plantID: UUID,
        score: Int,
        band: HealthBand,
        note: String,
        appearance: ObservationAppearance = .same,
        soilMoisture: ObservationSoilMoisture = .comfortable,
        hasNewGrowth: Bool = false,
        photoURL: URL? = nil,
        observationID: UUID = UUID(),
        followUpDays: Int? = nil,
        nextActions: [String]? = nil,
        checks: [PlantCheck]? = nil,
        concerns: [String]? = nil,
        positiveSigns: [String]? = nil,
        isEstimated: Bool = false,
        confidence: Int? = nil,
        appliesToPlant: Bool? = nil,
        actionability: DiagnosisActionability? = nil,
        assessmentAvailable: Bool? = nil,
        analysisVersion: String? = nil,
        providerName: String? = nil,
        limitations: [String]? = nil,
        referenceObservationID: UUID? = nil,
        indicatorReadings: [PlantHealthIndicatorReading]? = nil,
        growingConditions: PlantGrowingConditions? = nil
    ) -> PlantObservation? {
        guard let index = plants.firstIndex(where: { $0.id == plantID }) else { return nil }
        let previousScore = plants[index].healthScore
        // A plant saved without an assessment carries a hidden placeholder
        // score. The first real reading is the first thing anyone measured, so
        // it is a baseline, not a change from a number nobody took.
        let hadReading = plants[index].hasHealthReading
        let shouldApply = appliesToPlant
            ?? (!isEstimated
                && assessmentAvailable != false
                && (actionability == nil || actionability == .actionable))
        if shouldApply {
            plants[index].healthScore = score
            // Score owns the band everywhere. Keeping a separately supplied band
            // allowed impossible states to become durable during retries.
            plants[index].healthBand = HealthBand(score: score)
            plants[index].trend = hadReading ? Self.trend(from: previousScore, to: score) : .baseline
            plants[index].confidence = confidence ?? plants[index].confidence
            plants[index].assessmentDate = .now
            plants[index].assessmentSource = .checkInPhoto
        }
        if let indicatorReadings {
            plants[index].healthIndicatorReadings = indicatorReadings
        }
        // A check-in photographs the same pot as the scan did, and pots change:
        // people repot, add a cover, or let water start standing. The
        // conditions were read on every check-in and thrown away on every one
        // of them, so a cachepot added in August stayed invisible until the
        // next full scan. Matches the diagnose path: only a read that actually
        // saw something replaces the established record.
        if let refreshed = Self.stamped(growingConditions) {
            plants[index].growingConditions = refreshed
        }
        // A struggling plant needs looking at sooner than a thriving one. The
        // cadence used to be a flat fortnight no matter what the check-in
        // found, which contradicts the recovery follow-ups the product
        // promises. Prefer the analysis' own follow-up window, fall back to a
        // band-appropriate default, then let the owner's chosen cadence win
        // unless the plant is struggling.
        let resolvedBand = shouldApply ? HealthBand(score: score) : plants[index].healthBand
        let resolvedFollowUp = Self.checkInFollowUpDays(
            analysisDays: followUpDays,
            band: resolvedBand,
            preferredDays: plants[index].checkInFrequencyDays,
            latitude: profile.location?.latitude
        )
        plants[index].nextCheckIn = Calendar.current.date(byAdding: .day, value: resolvedFollowUp, to: .now) ?? .now
        if shouldApply { plants[index].summary = note }
        if shouldApply, let currentPlan = plants[index].carePlan, currentPlan.status == .active {
            var completed = currentPlan
            let unresolved = completed.actions.filter { $0.state == .proposed || $0.state == .due }
            completed.status = unresolved.isEmpty ? .completed : .abandoned
            let delta = score - previousScore
            let result = delta > 0
                ? "The follow-up improved by \(delta) points."
                : delta < 0
                    ? "The follow-up fell by \(abs(delta)) points."
                    : "The follow-up held steady."
            completed.outcome = unresolved.isEmpty
                ? result
                : "Follow-up recorded before \(unresolved.count) plan \(unresolved.count == 1 ? "step was" : "steps were") resolved. \(result)"
            plants[index].carePlanHistory = [completed] + (plants[index].carePlanHistory ?? [])
            plants[index].carePlan = nil
        }
        if shouldApply, let nextActions, !nextActions.isEmpty {
            plants[index].nextActions = nextActions
            Self.replaceCarePlan(
                on: &plants[index],
                goal: note,
                actions: nextActions,
                checks: checks ?? [],
                reviewAt: plants[index].nextCheckIn,
                at: .now
            )
        } else if shouldApply {
            plants[index].nextActions = []
        }
        if shouldApply, let concerns { plants[index].concerns = concerns }
        if shouldApply, let positiveSigns { plants[index].positiveSigns = positiveSigns }
        // The owner's own open check-ins only. A sitter's check-in task is their
        // work and their attribution: closing it from here marked it done by
        // someone who never did it, and credited the assignment's progress bar
        // for a look the sitter had not taken.
        for taskIndex in tasks.indices
        where tasks[taskIndex].plantID == plantID
            && tasks[taskIndex].kind == .checkIn
            && !tasks[taskIndex].isSittingTask {
            tasks[taskIndex].isCompleted = true
            tasks[taskIndex].completedAt = .now
        }
        // Check-ins recur: schedule the next one to match the plant's new
        // follow-up date, otherwise this plant would never appear in the care
        // queue (or get a reminder) again after its first check-in.
        tasks.append(
            CareTask(
                id: UUID(),
                plantID: plantID,
                kind: .checkIn,
                dueDate: plants[index].nextCheckIn,
                detail: "One fresh photo. Grove lines it up against the last one.",
                isCompleted: false,
                isSittingTask: false,
                ownerName: nil
            )
        )
        record(
            ActivityEvent(
                // Shares the observation's id: the server mirrors this entry, so
                // naming it after the thing it describes lets both ends agree
                // without a round trip and lets a bootstrap dedupe the pair.
                id: observationID,
                kind: .improvement,
                actorName: ActivityEvent.selfActorName,
                actorInitials: profile.initials,
                message: shouldApply
                    ? "checked in, now \(HealthBand(score: score).title.lowercased()) at \(score)%"
                    : "checked in; observations saved and health score unchanged",
                plantID: plantID,
                timestamp: .now
            )
        )
        // The first applied reading records itself as its own baseline, so no
        // delta reader (timeline, detail, living record) reports a move away
        // from the placeholder score. An estimated or unavailable check-in
        // leaves the plant unassessed, so it keeps today's behaviour.
        let observationPreviousScore = shouldApply && !hadReading ? score : previousScore
        let observation = PlantObservation(
            id: observationID,
            plantID: plantID,
            createdAt: .now,
            previousScore: observationPreviousScore,
            score: score,
            band: shouldApply ? HealthBand(score: score) : plants[index].healthBand,
            note: note,
            appearance: appearance,
            soilMoisture: soilMoisture,
            hasNewGrowth: hasNewGrowth,
            photoURL: photoURL,
            actorName: "You",
            isEstimated: isEstimated,
            confidence: confidence,
            actionability: actionability,
            assessmentAvailable: assessmentAvailable,
            analysisVersion: analysisVersion,
            providerName: providerName,
            limitations: limitations,
            referenceObservationID: referenceObservationID,
            indicatorReadings: indicatorReadings
        )
        observations.insert(observation, at: 0)
        unacknowledgedObservationIDs.insert(observation.id)
        // A check-in reads the soil as part of the guided flow, so the dry-down
        // clock restarts here too. Without this, a plant checked in on Tuesday
        // could still be asking to have its soil felt on Wednesday.
        rescheduleSoilCheck(for: plantID)
        recordTend()
        recordQuestProgress(.look)
        persist()
        refreshJourney()
        GrovePremiumOffer.recordMeaningfulUse(in: storage)
        return observation
    }

    /// Below this many points, a change between two readings is noise rather
    /// than a direction of travel.
    ///
    /// A photo-derived score carries real variance — angle, daylight, how much
    /// of the plant is in frame — so a strict `>` comparison meant one point of
    /// wobble flipped the hero's chip to a green "Improving" over a plant that
    /// was dying, and `.stable` required two model integers to land exactly
    /// equal and so almost never appeared. `BotanistService.recentShift` already
    /// applies a floor to sunlight for the same reason: a coach that narrates
    /// noise as a trend teaches people to distrust it.
    nonisolated static let trendDeadband = 3

    /// The direction of travel between two readings, with noise held flat.
    nonisolated static func trend(from previousScore: Int, to score: Int) -> HealthTrend {
        let change = score - previousScore
        if abs(change) < trendDeadband { return .stable }
        return change > 0 ? .improving : .declining
    }

    /// How soon to look again when the analysis did not say. A plant in trouble
    /// earns a recovery-length follow-up; a stable one does not need chasing.
    static func defaultFollowUpDays(for band: HealthBand) -> Int {
        switch band {
        case .urgent: 3
        case .attention: 5
        case .monitor: 7
        case .healthy, .thriving: 14
        }
    }

    /// The first check-in comes early so a new owner sees Grove compare two
    /// photos within days, not a fortnight. A shorter analysis window still wins.
    static let firstCheckInMaxDays = 3

    static func firstCheckInDays(analysisDays: Int?, band: HealthBand) -> Int {
        min(
            min(max(analysisDays ?? defaultFollowUpDays(for: band), 1), 30),
            firstCheckInMaxDays
        )
    }

    /// The next check-in window, with the owner's chosen cadence applied.
    ///
    /// Automatic (`nil`) keeps Grove's health-derived rhythm. A fixed cadence
    /// wins outright for a plant that is coping, but a struggling plant is never
    /// checked less often than Grove recommends, so a 30-day preference cannot
    /// stretch an urgent recovery window.
    static func checkInFollowUpDays(
        analysisDays: Int?,
        band: HealthBand,
        preferredDays: Int?,
        latitude: Double?,
        now: Date = .now
    ) -> Int {
        let computed = min(
            max(
                analysisDays ?? followUpDays(for: band, latitude: latitude, now: now),
                1
            ),
            30
        )
        guard let preferredDays else { return computed }
        let preferred = min(max(preferredDays, 1), 30)
        if band == .urgent || band == .attention {
            return min(preferred, computed)
        }
        return preferred
    }

    /// The follow-up window, stretched for the resting season.
    ///
    /// Nothing here knew what month it was, so a fig that read as struggling
    /// because it was January was chased every five days from November to March
    /// — each honest "worse / no new growth" answer dropping the score again and
    /// holding the cadence short. A plant whose decline is seasonal will not
    /// recover faster for being looked at more, and the looking is what drags it
    /// down. The relief is bounded and applies only to bands that are not
    /// already urgent: real trouble is never deferred for the calendar.
    static func followUpDays(
        for band: HealthBand,
        latitude: Double?,
        now: Date = .now
    ) -> Int {
        let base = defaultFollowUpDays(for: band)
        guard band != .urgent,
              let latitude,
              PlantSeasonAdvisory.season(at: latitude, on: now) == .dormancy else { return base }
        // Roughly half again as long, capped at the same 30 the check-in path
        // already clamps to.
        return min(30, Int((Double(base) * 1.6).rounded()))
    }

    /// Builds a structured plan from the analysis pipeline's legacy string
    /// list. The inference is intentionally conservative: it categorises the
    /// action for logging and iconography but preserves the instruction exactly.
    static func makeCarePlan(
        goal: String,
        actions: [String],
        checks: [PlantCheck] = [],
        reviewAt: Date?,
        at date: Date
    ) -> PlantCarePlan? {
        let useful = actions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !useful.isEmpty else { return nil }
        // The gateway copies each check's action from nextActions, so an exact
        // match is the contract; case and spacing are forgiven, nothing else.
        let outcomesByAction = Dictionary(
            checks.map { (checkKey($0.action), $0.outcomes) },
            uniquingKeysWith: { first, _ in first }
        )
        return PlantCarePlan(
            id: UUID(),
            goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
            actions: useful.map { instruction in
                PlantCarePlanAction(
                    id: UUID(),
                    kind: careKind(for: instruction),
                    instruction: instruction,
                    rationale: "This is one of the next actions from the latest assessment.",
                    dueFrom: date,
                    dueUntil: reviewAt,
                    expectedResponse: "Review the response at the next check-in.",
                    state: .due,
                    completedAt: nil,
                    outcomes: outcomesByAction[checkKey(instruction)].flatMap { $0.count >= 2 ? $0 : nil }
                )
            },
            startedAt: date,
            reviewAt: reviewAt,
            status: .active,
            outcome: nil
        )
    }

    private static func checkKey(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func replaceCarePlan(
        on plant: inout Plant,
        goal: String,
        actions: [String],
        checks: [PlantCheck] = [],
        reviewAt: Date?,
        at date: Date
    ) {
        guard let replacement = makeCarePlan(
            goal: goal,
            actions: actions,
            checks: checks,
            reviewAt: reviewAt,
            at: date
        ) else {
            return
        }
        if var existing = plant.carePlan {
            if existing.status == .active { existing.status = .replaced }
            plant.carePlanHistory = [existing] + (plant.carePlanHistory ?? [])
        }
        plant.carePlan = replacement
    }

    private static func careKind(for instruction: String) -> CareKind {
        let text = instruction.lowercased()
        if text.contains("repot") || text.contains("pot up") { return .repot }
        if text.contains("fertilis") || text.contains("feed") { return .fertilise }
        if text.contains("move") || text.contains("relocat") || text.contains("brighter spot") { return .relocate }
        if text.contains("clean") || text.contains("wipe") { return .cleanLeaves }
        if text.contains("prune") || text.contains("trim") || text.contains("cut") { return .prune }
        if text.contains("rotate") || text.contains("turn the pot") { return .rotate }
        if text.contains("treat") || text.contains("pest") || text.contains("isolate") { return .treat }
        if text.contains("water") { return .water }
        if text.contains("soil") { return .inspectSoil }
        return .monitor
    }

    /// Dates a scan's read of the pot on the way into the record, and drops one
    /// that saw nothing.
    ///
    /// The date matters because the fields age at different speeds: the pot and
    /// the substrate hold for months, while `soilSurface` is a photograph of one
    /// afternoon. Everything downstream needs to know which it is looking at.
    private static func stamped(_ conditions: PlantGrowingConditions?) -> PlantGrowingConditions? {
        guard let conditions, !conditions.isEmpty else { return nil }
        var dated = conditions
        dated.capturedAt = .now
        return dated
    }

    /// The recurring soil check that keeps a plant in the care queue between
    /// its fortnightly check-ins.
    ///
    /// Adopting a plant used to schedule exactly one task: a check-in, a
    /// fortnight out. For the single-plant owner — which is most new users —
    /// that meant Grove had nothing to say for fourteen days, and because
    /// `NotificationService` builds its whole schedule from tasks, nothing to
    /// send either. The habit the product exists to teach was the one thing it
    /// never asked for.
    ///
    /// The recurring soil check is retired.
    ///
    /// "Feel the dirt" was a care ritual of its own: a scheduled hand-in-the-soil
    /// check that owned its own cadence, its own reminders and its own reading.
    /// The product now asks for a photo instead, and a photo check-in already
    /// carries a soil observation, so this keeps the name as a no-op — and
    /// clears any open soil check — rather than deleting the call sites. Every
    /// existing record, and any soil check already in a grove, still decodes and
    /// can still be completed; it is simply never scheduled again.
    private func rescheduleSoilCheck(for plantID: UUID, isFirst: Bool = false, from date: Date = .now) {
        tasks.removeAll {
            $0.plantID == plantID && $0.kind == .inspectSoil && !$0.isCompleted && !$0.isSittingTask
        }
    }

    /// One wording for the soil check everywhere it is scheduled. Retained for
    /// legacy records and the sitter sheet; no longer scheduled.
    static let soilCheckDetail = "Feel the top 3 cm before you water. Dry means go, damp means wait."

    func addPlant(
        id: UUID = UUID(),
        nickname: String,
        location: String,
        lightPlacement: PlantLightPlacement? = nil,
        analysis: PlantAnalysisResult? = nil
    ) -> Plant {
        // First-plant onboarding replays this call after every possible kill
        // window. Its id is minted before sign-in, so finding it here means the
        // local half already landed; returning it avoids duplicate care tasks,
        // quest credit and journey rewards.
        if let existing = plant(id: id) { return existing }
        let isAdditionalPlant = !plants.isEmpty
        let identification = analysis?.identification
        let condition = analysis?.condition
        // Only a real assessment may write a score. With no analysis, or one that
        // said a clearer photo is needed, the plant is saved unassessed rather than
        // handed a reassuring number nobody measured.
        let assessedCondition: PlantConditionResult? = condition?.assessmentAvailable == false ? nil : condition
        let hasAssessment = assessedCondition != nil
        let unassessedSummary = "Grove couldn't assess this plant's health yet. A clear, well-lit photo of the whole plant gives it a first reading."
        let unassessedNextActions = ["Take a clear, well-lit photo of the whole plant for a first health reading"]
        let honestSummary: String
        let honestNextActions: [String]
        if let condition {
            let trimmed = condition.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            honestSummary = trimmed.isEmpty ? unassessedSummary : condition.summary
            honestNextActions = condition.nextActions.isEmpty ? unassessedNextActions : condition.nextActions
        } else {
            honestSummary = unassessedSummary
            honestNextActions = unassessedNextActions
        }
        let followUpDays = min(max(condition?.followUpDays ?? 14, 1), 30)
        let followUpDate = Calendar.current.date(byAdding: .day, value: followUpDays, to: .now) ?? .now
        // The first check-in is deliberately earlier than the care plan's
        // review date: a new owner should see Grove compare two photos within
        // days, which is when the habit forms.
        let firstCheckInDays = Self.firstCheckInDays(
            analysisDays: condition?.followUpDays,
            band: assessedCondition?.healthBand ?? HealthBand(score: Plant.unassessedPlaceholderScore)
        )
        let firstCheckInDate = Calendar.current.date(byAdding: .day, value: firstCheckInDays, to: .now) ?? .now
        var plant = Plant(
            id: id,
            nickname: nickname.isEmpty ? (identification?.isUnknown == true ? "Unknown plant" : "New plant") : nickname,
            species: identification?.commonName ?? "Unknown plant",
            scientificName: identification?.scientificName ?? "Species unconfirmed",
            canonicalTaxonID: identification?.canonicalTaxonID,
            identityConfirmation: identification?.identityConfirmation
                ?? (identification == nil || identification?.isUnknown == true ? .unknown : .photoMatch),
            location: location,
            lightPlacement: lightPlacement,
            growingConditions: Self.stamped(analysis?.growingConditions),
            healthScore: assessedCondition?.healthScore ?? Plant.unassessedPlaceholderScore,
            healthBand: assessedCondition?.healthBand ?? HealthBand(score: Plant.unassessedPlaceholderScore),
            trend: .baseline,
            confidence: assessedCondition?.confidence ?? 0,
            identificationConfidence: identification?.confidence,
            nextCheckIn: firstCheckInDate,
            symbol: "leaf.fill",
            palette: .fern,
            summary: assessedCondition?.summary ?? honestSummary,
            positiveSigns: assessedCondition?.positiveSigns ?? [],
            concerns: assessedCondition?.concerns ?? [],
            nextActions: assessedCondition?.nextActions ?? honestNextActions,
            lifecycleState: .active,
            acquiredAt: .now,
            carePlan: assessedCondition.map {
                Self.makeCarePlan(
                    goal: $0.summary,
                    actions: $0.nextActions,
                    checks: $0.checks ?? [],
                    reviewAt: followUpDate,
                    at: .now
                )
            } ?? Self.makeCarePlan(
                goal: "Get a first health reading with a clear photo.",
                actions: honestNextActions,
                checks: condition?.checks ?? [],
                reviewAt: followUpDate,
                at: .now
            ),
            assessmentDate: hasAssessment ? .now : nil,
            assessmentSource: hasAssessment ? .baselinePhoto : .offlineEstimate
        )
        plant.healthIndicatorReadings = PlantHealthIndicators.recordedReadings(
            for: plant,
            soil: nil,
            hasNewGrowth: nil,
            visualFindings: assessedCondition.map { PlantHealthIndicators.visualFindings(from: $0) } ?? [],
            growingConditions: plant.growingConditions,
            tasks: tasks,
            assessmentAvailable: hasAssessment,
            analysisVersion: analysis?.analysisVersion
        )
        plants.insert(plant, at: 0)
        tasks.append(
            CareTask(
                id: UUID(),
                plantID: plant.id,
                kind: .checkIn,
                dueDate: plant.nextCheckIn,
                detail: "One fresh photo. Grove lines it up against today's baseline.",
                isCompleted: false,
                isSittingTask: false,
                ownerName: nil
            )
        )
        // Adoption schedules the first photo check-in; the recurring soil check
        // that used to fill the fortnight between is retired.
        recordQuestProgress(.look)
        persist()
        refreshJourney()
        if isAdditionalPlant {
            GrovePremiumOffer.recordMeaningfulUse(in: storage)
        }
        return plant
    }

    /// Verifies the first-plant handoff against the account snapshot rather
    /// than merely against observable in-memory arrays. The neutral onboarding
    /// draft is not acknowledged until both records can be decoded back from
    /// the same persistence domain a relaunch will use.
    func hasPersistedFirstPlant(plantID: UUID, scanID: UUID) -> Bool {
        guard persistenceEnabled else {
            return plants.contains { $0.id == plantID } && scanHistory.contains { $0.id == scanID }
        }
        // The onboarding handoff is an explicit crash-consistency boundary:
        // its protected neutral copy is not consumed until the account snapshot
        // is physically encoded. Ordinary interactions use the asynchronous
        // path below and never pay this main-thread cost.
        persistImmediately()
        guard let snapshot = decodedSnapshot(forKey: persistenceKey) else { return false }
        return snapshot.plants.contains { $0.id == plantID }
            && (snapshot.scanHistory ?? []).contains { $0.id == scanID && $0.plantID == plantID }
    }

    /// Commits the latest staged snapshot at an app lifecycle boundary. Normal
    /// interactions encode off-main; once iOS is taking the scene away there is
    /// no reason to leave the last mutation dependent on more runtime.
    func flushPersistence() {
        guard persistenceEnabled else { return }
        let stagedKey = StagedSnapshotKey(storageID: ObjectIdentifier(storage), key: persistenceKey)
        guard Self.stagedSnapshots[stagedKey] != nil else { return }
        persistImmediately()
    }

    @discardableResult
    func createSittingAssignment(
        id: UUID = UUID(),
        sitterName: String,
        startDate: Date,
        endDate: Date,
        plantIDs: Set<UUID>,
        canCheckIn: Bool = true
    ) -> SittingAssignment {
        let initials = sitterName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
        // Whole days, not the o'clock the composer happened to open at — see
        // `SittingWindow`. Normalised here so every caller (and the mutation
        // each one sends to the server) agrees on the same boundaries.
        let timeZone = profile.location?.timeZoneIdentifier
            .flatMap(TimeZone.init(identifier:)) ?? .current
        let window = SittingWindow.normalized(
            start: startDate,
            end: endDate,
            timeZone: timeZone
        )
        let assignment = SittingAssignment(
            id: id,
            sitterName: sitterName,
            sitterInitials: initials,
            startDate: window.start,
            endDate: window.end,
            plantIDs: Array(plantIDs),
            status: .invited,
            completedTasks: 0,
            totalTasks: max(1, plantIDs.count * 2),
            canCheckIn: canCheckIn,
            timeZoneIdentifier: timeZone.identifier
        )
        recordSittingAssignment(assignment)
        return assignment
    }

    /// Commits an in-app handover only after the server has accepted its
    /// account, friendship and plant scope. A rejected handover must never sit
    /// in the owner's list looking live when nobody received access.
    func recordSittingAssignment(_ assignment: SittingAssignment) {
        if let index = assignments.firstIndex(where: { $0.id == assignment.id }) {
            assignments[index] = assignment
        } else {
            assignments.insert(assignment, at: 0)
        }
        if !assignment.isIncoming,
           !activity.contains(where: { $0.id == assignment.activityEventID }) {
            let count = assignment.plantIDs.count
            record(
                ActivityEvent(
                    id: assignment.activityEventID,
                    kind: .assignment,
                    actorName: ActivityEvent.selfActorName,
                    actorInitials: profile.initials,
                    message: "invited \(assignment.sitterName) to care for \(count) \(count == 1 ? "plant" : "plants")",
                    plantID: nil,
                    timestamp: .now
                )
            )
        }
        persist()
        // Handing plants to someone is a Journey step; pay it while the
        // person is still looking at the handover they just made.
        refreshJourney()
    }

    /// Applies a server-confirmed answer/revocation without inventing a local
    /// security state. Declined and revoked incoming rows are removed from the
    /// sitter dashboard immediately; owner receipts remain visible.
    func updateSittingAssignment(_ assignment: SittingAssignment) {
        if assignment.isIncoming && [.declined, .revoked].contains(assignment.status) {
            assignments.removeAll { $0.id == assignment.id }
            let scoped = Set(assignment.plantIDs)
            sittingTasks.removeAll { scoped.contains($0.plantID) }
            sittingPlants.removeAll { scoped.contains($0.id) }
        } else if let index = assignments.firstIndex(where: { $0.id == assignment.id }) {
            assignments[index] = assignment
        } else {
            assignments.insert(assignment, at: 0)
        }
        persist()
        refreshJourney()
    }

    func completeSittingTask(_ completed: CareTask) {
        guard let index = sittingTasks.firstIndex(where: { $0.id == completed.id }) else { return }
        sittingTasks[index] = completed
        if let assignmentIndex = assignments.firstIndex(where: {
            $0.isIncoming && $0.plantIDs.contains(completed.plantID) && !$0.hasEnded()
        }) {
            assignments[assignmentIndex].completedTasks = min(
                assignments[assignmentIndex].totalTasks,
                assignments[assignmentIndex].completedTasks + 1
            )
        }
        persist()
        refreshJourney()
    }

    // MARK: - Sitting by link

    /// Whether someone is already lined up to look after the grove — a friend
    /// assignment the sitter accepted and that has not finished, or an active
    /// link whose care sheet the sitter has acknowledged by opening it.
    ///
    /// This is what keeps the travel banner from nagging a user who has already
    /// done exactly what it is about to suggest.
    func hasSittingCover(on date: Date = .now) -> Bool {
        assignments.contains {
            let status = $0.currentStatus(now: date)
            return status == .upcoming || status == .active
        }
            || sittingInvites.contains { $0.providesCover(on: date) }
    }

    /// Records a link handover locally. The URL arrives separately once the
    /// server has minted the token — see `attachShareURL(inviteID:url:)` — so a
    /// dropped response leaves a visible row that the owner can safely revoke.
    /// The trip is not considered covered until the sitter opens the link.
    @discardableResult
    func createSittingInvite(
        sitterLabel: String,
        startDate: Date,
        endDate: Date,
        plantIDs: Set<UUID>,
        canLogCare: Bool,
        ownerNotes: String = ""
    ) -> SittingInvite {
        let named = sitterLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        // Whole days — the link stops resolving at the end of the last day of
        // the trip, not at the o'clock the composer opened. See `SittingWindow`.
        let timeZone = profile.location?.timeZoneIdentifier
            .flatMap(TimeZone.init(identifier:)) ?? .current
        let window = SittingWindow.normalized(
            start: startDate,
            end: endDate,
            timeZone: timeZone
        )
        let handover = ownerNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let invite = SittingInvite(
            id: UUID(),
            sitterLabel: named.isEmpty ? "Plant sitter" : named,
            startDate: window.start,
            endDate: window.end,
            plantIDs: Array(plantIDs),
            canLogCare: canLogCare,
            ownerNotes: handover.isEmpty ? nil : handover,
            timeZoneIdentifier: timeZone.identifier,
            shareURL: nil,
            createdAt: .now,
            revokedAt: nil
        )
        sittingInvites.insert(invite, at: 0)
        record(
            ActivityEvent(
                id: UUID(),
                kind: .assignment,
                actorName: ActivityEvent.selfActorName,
                actorInitials: profile.initials,
                message: "made a sitting link for \(plantIDs.count) \(plantIDs.count == 1 ? "plant" : "plants")",
                plantID: nil,
                timestamp: .now
            )
        )
        persist()
        return invite
    }

    func attachShareURL(inviteID: UUID, url: URL) {
        guard let index = sittingInvites.firstIndex(where: { $0.id == inviteID }) else { return }
        sittingInvites[index].shareURL = url
        sittingInvites[index].wasMinted = true
        if let accountID = activeAccountID {
            _ = SittingInviteURLStore.save(url, accountID: accountID, inviteID: inviteID)
        }
        persist()
        // A minted link is a real handover (see `computeJourneyMetrics`).
        refreshJourney()
    }

    /// Records that revocation is durable but not yet server-confirmed. The
    /// link may still open, so this state stays visibly distinct from revoked.
    func requestSittingInviteRevocation(id: UUID) {
        guard let index = sittingInvites.firstIndex(where: { $0.id == id }),
              sittingInvites[index].revokedAt == nil else { return }
        sittingInvites[index].revocationRequestedAt = .now
        sittingInvites[index].shareURL = nil
        if let accountID = activeAccountID {
            SittingInviteURLStore.remove(accountID: accountID, inviteID: id)
        }
        persist()
    }

    /// Applies a server-confirmed revocation.
    func revokeSittingInvite(id: UUID) {
        guard let index = sittingInvites.firstIndex(where: { $0.id == id }),
              sittingInvites[index].revokedAt == nil else { return }
        sittingInvites[index].revokedAt = .now
        sittingInvites[index].revocationRequestedAt = nil
        sittingInvites[index].shareURL = nil
        if let accountID = activeAccountID {
            SittingInviteURLStore.remove(accountID: accountID, inviteID: id)
        }
        persist()
    }

    // MARK: - Journey / progression

    /// The whole campaign resolved against the player: every chapter, its
    /// nodes, and whether its region has opened.
    func resolvedCampaign() -> [ResolvedChapter] {
        JourneyEvaluator.resolveCampaign(progress: gardener, metrics: computeJourneyMetrics())
    }

    /// One chapter's nodes.
    func resolvedMilestones(for chapter: JourneyChapter = JourneyLibrary.firstRoots) -> [ResolvedMilestone] {
        resolvedCampaign().first { $0.chapter.id == chapter.id }?.milestones
            ?? JourneyEvaluator.resolve(chapter: chapter, progress: gardener, metrics: computeJourneyMetrics())
    }

    /// A single node's resolved state, wherever it lives in the campaign.
    func resolvedMilestone(id: String) -> ResolvedMilestone? {
        resolvedCampaign().flatMap(\.milestones).first { $0.id == id }
    }

    /// Countable progress for a badge that lives outside the chapter road.
    /// Keeping this calculation in the store means the shelf and full
    /// collection read the exact same snapshot the award engine evaluates.
    func badgeProgress(for achievement: CareAchievement) -> (current: Int, target: Int) {
        JourneyEvaluator.progress(
            achievement.requirement,
            milestoneID: "badge-\(achievement.id)",
            progress: gardener,
            metrics: computeJourneyMetrics(),
            previousCompleted: false
        )
    }

    /// The next milestone the player should tackle, if any remain.
    func currentMilestone() -> JourneyMilestone? {
        resolvedCampaign()
            .filter(\.isUnlocked)
            .flatMap(\.milestones)
            .first { $0.status == .current }?
            .milestone
    }

    /// The chapter the player is standing in: the first unfinished open one,
    /// or the last chapter once the campaign is done.
    func currentChapter() -> ResolvedChapter? {
        let campaign = resolvedCampaign()
        return campaign.first { $0.isUnlocked && !$0.isComplete } ?? campaign.last
    }

    /// Chests standing open-able right now, across every open region.
    func readyChests() -> [JourneyMilestone] {
        resolvedCampaign()
            .filter(\.isUnlocked)
            .flatMap(\.readyChests)
            .map(\.milestone)
    }

    /// The streak to show today: it holds if the player tended today or
    /// yesterday, otherwise it has lapsed back to zero — unless a shield is
    /// banked, which covers exactly one missed day.
    ///
    /// Measured against `calendarDay` rather than the clock, because "has the
    /// streak lapsed?" is a question about today and SwiftUI only redraws when
    /// observed state moves. Reading `.now` here left the number frozen at
    /// whatever it was when the store was last written to — a streak that
    /// lapsed overnight kept showing yesterday's total until some unrelated
    /// mutation happened to refresh the view.
    var displayStreak: Int {
        guard let days = daysSinceLastTend(now: calendarDay) else { return 0 }
        if days <= 1 { return gardener.currentStreak }
        // Day two with a shield in the bank still reads as alive. The shield is
        // only actually spent when the player tends again — nothing is burned
        // for a streak they were going to abandon anyway.
        if days == 2, gardener.streakShields > 0 { return gardener.currentStreak }
        return 0
    }

    /// Whether today's streak is only standing because a shield is holding it
    /// up. Drives the "one missed day, covered" line in the UI.
    var streakIsShielded: Bool {
        guard gardener.streakShields > 0,
              let days = daysSinceLastTend(now: calendarDay) else { return false }
        return days == 2
    }

    /// Whether a qualifying action has already advanced the streak today.
    ///
    /// "Did today count?" is the question a streak product has to be able to
    /// answer on demand — guessing at it is what makes people open the app a
    /// second time at 11pm to be sure.
    var streakCountedToday: Bool {
        daysSinceLastTend(now: calendarDay) == 0
    }

    /// The streak unpacked far enough to explain itself: the run so far, the
    /// week behind it, the shield situation, and the sentence that says where
    /// the gardener stands.
    ///
    /// Grove keeps a last-tend day and a run length rather than a diary of
    /// every day tended — and those two together say exactly which days are in
    /// the current run, which is all the week row ever claims. Days before the
    /// run started are drawn as missed because, for streak purposes, they were.
    var streakSummary: StreakSummary {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: calendarDay)
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let current = displayStreak

        let runEnd = gardener.lastTendDay.map { calendar.startOfDay(for: $0) }
        let runStart: Date? = current > 0
            ? runEnd.flatMap { calendar.date(byAdding: .day, value: -(current - 1), to: $0) }
            : nil

        let week: [StreakSummary.DayMark] = (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset - 6, to: today) else { return nil }
            let isToday = calendar.isDate(day, inSameDayAs: today)
            let state: StreakSummary.DayState
            if let runStart, let runEnd, day >= runStart, day <= runEnd {
                state = .kept
            } else if isToday {
                state = .pending
            } else if streakIsShielded, Self.dayGap(from: day, to: today) == 1 {
                // The day the shield is standing in for. It is only actually
                // spent on the next tend, so it reads as held, not lost.
                state = .shielded
            } else {
                state = .missed
            }
            return StreakSummary.DayMark(
                id: offset,
                date: day,
                initial: symbols[calendar.component(.weekday, from: day) - 1],
                state: state,
                isToday: isToday
            )
        }

        return StreakSummary(
            current: current,
            longest: gardener.longestStreak,
            countedToday: streakCountedToday,
            isShielded: streakIsShielded,
            shields: gardener.streakShields,
            // Shields land on every seventh day of a run, so the next one is
            // always the next multiple of seven above where the run stands.
            daysUntilNextShield: 7 - (current % 7),
            week: week
        )
    }

    /// Re-reads the current day, republishing it only when it has actually
    /// moved so a foreground that lands on the same day costs nothing.
    ///
    /// Safe to call as often as anything likes. The app calls it when the
    /// system reports a day change (midnight, a time-zone hop, a clock nudge)
    /// and every time it becomes active, which together cover both the phone
    /// left open past midnight and the one picked up the next morning.
    func refreshCalendarDay(now: Date = .now) {
        guard !Calendar.current.isDate(calendarDay, inSameDayAs: now) else { return }
        calendarDay = Self.dayStamp(for: now)
    }

    /// Calendar days between the last tend and today, or nil if nothing has ever
    /// tended the streak. Never negative: a stamp that has ended up in the
    /// future (see `dayStamp`) reads as today, which is the lenient reading and
    /// the only one that cannot silently destroy a real streak.
    private func daysSinceLastTend(now: Date = .now) -> Int? {
        guard let last = gardener.lastTendDay else { return nil }
        guard let gap = Self.dayGap(from: last, to: now) else { return nil }
        return max(0, gap)
    }

    /// One dated health reading of a plant in the grove, whoever took it.
    ///
    /// Grove reads a plant's health in two places, not one. A check-in is the
    /// obvious one. The other is a scan attached to a plant — which is how a
    /// plant is adopted, and how a worry gets diagnosed — and it writes the
    /// same `healthScore` onto the same plant from the same kind of
    /// photograph. A week chart drawn from check-ins alone therefore reported
    /// "no readings" on precisely the days someone had been standing over a
    /// sick plant photographing it.
    struct HealthReading {
        let plantID: UUID
        let date: Date
        let score: Int
        /// True when the score came from `CheckInView`'s offline arithmetic
        /// rather than from an assessment that looked at the photograph.
        let isEstimated: Bool
    }

    /// Every health reading in the grove, from every surface that takes one.
    ///
    /// Nothing double-counts: a check-in writes an observation and no scan
    /// record, adopting and diagnosing each write exactly one scan record, and
    /// refining a diagnosis rewrites the record it already had rather than
    /// adding a second. Readings whose plant has left the grove are dropped —
    /// a synced grove can still be holding history for a plant deleted on
    /// another device, and an average over plants you no longer own is not an
    /// average of anything.
    var healthReadings: [HealthReading] {
        let living = Set(plants.map(\.id))
        let fromCheckIns = observations.compactMap { observation -> HealthReading? in
            guard living.contains(observation.plantID) else { return nil }
            return HealthReading(
                plantID: observation.plantID,
                date: observation.createdAt,
                score: observation.score,
                isEstimated: observation.isEstimated
                    || observation.assessmentAvailable == false
                    || (observation.actionability != nil && observation.actionability != .actionable)
            )
        }
        let fromScans = scanHistory.compactMap { record -> HealthReading? in
            guard let plantID = record.plantID, living.contains(plantID) else { return nil }
            return HealthReading(
                plantID: plantID,
                date: record.createdAt,
                score: record.healthScore,
                isEstimated: false
            )
        }
        return fromCheckIns + fromScans
    }

    /// The seven days of the current week, each annotated with how much looking
    /// happened on it and what that looking found. Powers the weekly health
    /// chart on Home. Respects the locale's first weekday so the row reads
    /// naturally.
    ///
    /// A day nobody looked has no health to report — it gets `nil`, never a
    /// zero. Dated against `calendarDay` rather than the clock, so a phone left
    /// open past midnight moves the week over with everything else that counts
    /// in days.
    var currentWeekCheckIns: [CheckInDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: calendarDay)
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start else { return [] }

        var readingsByDay: [Date: [HealthReading]] = [:]
        for reading in healthReadings {
            readingsByDay[calendar.startOfDay(for: reading.date), default: []].append(reading)
        }

        let symbols = calendar.shortStandaloneWeekdaySymbols
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            // `date(byAdding:)` keeps the wall-clock time, so a week containing
            // a daylight-saving jump still lands on midnight — but the key has
            // to be normalised anyway, because the readings' keys are.
            let readings = readingsByDay[calendar.startOfDay(for: day)] ?? []
            let weekdayIndex = calendar.component(.weekday, from: day) - 1
            return CheckInDay(
                id: offset,
                date: day,
                shortName: symbols[weekdayIndex],
                readingCount: readings.count,
                plantsSeen: Set(readings.map(\.plantID)).count,
                averageScore: Self.dayScore(from: readings),
                isToday: calendar.isDate(day, inSameDayAs: today),
                isFuture: day > today
            )
        }
    }

    /// A day's health in one number: each plant's own mean first, then the mean
    /// across plants.
    ///
    /// Averaging every reading flat lets one plant carry the day. Check the
    /// struggling fern three times and the thriving monstera once and the grove
    /// reads as sicker than it is — not because anything got worse, but because
    /// of where the attention went. A plant is one plant however often you
    /// looked at it.
    ///
    /// Estimated readings are excluded outright. The offline estimate nudges
    /// the previous score by three form answers and, by its own comment, knows
    /// nothing about the photograph; drawing it on the trend line is the chart
    /// lying by exactly however wrong the guess was. A day holding nothing but
    /// estimates scores `nil` — you looked, the axis says so, and there is
    /// still nothing measured to plot.
    private static func dayScore(from readings: [HealthReading]) -> Int? {
        let measured = readings.filter { !$0.isEstimated }
        guard !measured.isEmpty else { return nil }
        let perPlant = Dictionary(grouping: measured, by: \.plantID).values.map { group in
            Double(group.reduce(0) { $0 + $1.score }) / Double(group.count)
        }
        return Int((perPlant.reduce(0, +) / Double(perPlant.count)).rounded())
    }

    /// Marks a lesson or quiz node as done, advances the streak, and awards any
    /// milestones (including cascaded reward chests) that this unlocks.
    @discardableResult
    func completeInteractiveMilestone(_ milestone: JourneyMilestone) -> [JourneyMilestone] {
        guard !gardener.completedInteractiveIDs.contains(milestone.id) else { return [] }
        gardener.completedInteractiveIDs.insert(milestone.id)
        recordTend()
        let awarded = refreshJourney(persistIfChanged: false)
        persist()
        return awarded
    }

    // MARK: - Learn progress

    /// Whether a Grove Academy lesson has been finished at least once.
    func isLessonLearned(_ topicID: String) -> Bool {
        gardener.completedInteractiveIDs.contains(Self.learnRecordID(topicID))
    }

    /// How many of the given lessons have been finished.
    func learnedLessonCount(in topics: [LearnTopic]) -> Int {
        topics.filter { isLessonLearned($0.id) }.count
    }

    /// Everything a finished lesson paid out, for the celebration UI.
    struct LearnReward {
        /// Lesson XP plus any achievement bonus XP.
        let xp: Int
        /// Learning achievements unlocked by this completion.
        let achievements: [Badge]
    }

    /// The first learning achievement not yet unlocked, with how many lessons
    /// remain until it. Powers the "next achievement" hint in the Journey.
    var nextLearnAchievement: (achievement: LearnAchievement, lessonsToGo: Int?)? {
        let lessons = learnedLessonCount(in: LearnLibrary.all)
        for achievement in JourneyLibrary.learnAchievements
        where !gardener.unlockedBadgeIDs.contains(achievement.badge.id) {
            switch achievement.requirement {
            case .lessonsLearned(let min):
                return (achievement, max(0, min - lessons))
            case .streakReached:
                return (achievement, nil)
            }
        }
        return nil
    }

    /// An answered botanist question tends the plant-safe streak and today's
    /// learn quest, and pays the same once-a-day learning dividend a repeat
    /// lesson does.
    ///
    /// This is what keeps the streak honest now that Ask has replaced the Learn
    /// tab: on the many days when no check-in is due, asking about a real plant
    /// is the day's learning, and it is inspection-shaped rather than watering-
    /// shaped, so it cannot nudge anyone toward overwatering.
    ///
    /// It shares the dividend with lessons on purpose — there is one learning
    /// payout a day, not one per surface.
    @discardableResult
    func recordBotanistAnswer() -> LearnReward? {
        payDailyLearningDividend()
    }

    /// Whether today's learning dividend is still unclaimed, so a surface can
    /// advertise the XP honestly instead of promising a payout already spent.
    var dailyLearningDividendAvailable: Bool {
        guard let paid = gardener.lastRefresherXPDay else { return true }
        return !Calendar.current.isDate(paid, inSameDayAs: .now)
    }

    /// Marks a Grove Academy lesson as learned, awards its XP and any learning
    /// achievements it unlocks, and advances the plant-safe streak.
    /// A repeat completion falls through to the daily dividend: it still tends
    /// the streak and pays a small once-per-day XP bonus so progression does not
    /// dead-end once the course is finished.
    @discardableResult
    func completeLearnLesson(_ topicID: String) -> LearnReward? {
        let recordID = Self.learnRecordID(topicID)
        guard !gardener.completedInteractiveIDs.contains(recordID) else {
            return payDailyLearningDividend()
        }
        let levelBefore = gardener.level
        gardener.completedInteractiveIDs.insert(recordID)
        gardener.xp += LearnLibrary.lessonXP
        // A finished lesson *is* the day's learning payout, so it spends the
        // dividend too. Without this the two surfaces could be farmed one after
        // the other for the day's XP twice over, which is exactly what sharing
        // one dividend between them was meant to prevent.
        gardener.lastRefresherXPDay = Self.dayStamp(for: .now)
        recordTend()
        recordQuestProgress(.learn)
        // The Academy's completion sheet is the celebration for these — see
        // `unlockBadge(_:earnedAt:celebrate:)`. That opt-out covers learning
        // badges only: a campaign step or care badge this lesson finishes is
        // not on the sheet, so it is dated and queued like any other.
        let unlocked = refreshLearnAchievements(celebrate: false)
        refreshJourney(persistIfChanged: false)
        if gardener.level > levelBefore { pendingLevelUp = gardener.level }
        persist()
        let bonus = unlocked.reduce(0) { $0 + $1.bonusXP }
        return LearnReward(xp: LearnLibrary.lessonXP + bonus, achievements: unlocked.map(\.badge))
    }

    /// The every-day path shared by a repeat lesson and an answered botanist
    /// question: keeps the streak alive and grants the dividend XP at most once
    /// per day. Returns the reward when today's dividend paid out, or nil when
    /// it already had.
    private func payDailyLearningDividend() -> LearnReward? {
        recordTend()
        recordQuestProgress(.learn)
        guard dailyLearningDividendAvailable else {
            // No XP today, but the tend above can still have reached a streak
            // step or badge. `refreshJourney` covers the learning badges too.
            refreshJourney(persistIfChanged: false)
            persist()
            return nil
        }
        gardener.lastRefresherXPDay = Self.dayStamp(for: .now)
        let levelBefore = gardener.level
        gardener.xp += LearnLibrary.refresherXP
        let unlocked = refreshLearnAchievements()
        refreshJourney(persistIfChanged: false)
        if gardener.level > levelBefore { pendingLevelUp = gardener.level }
        persist()
        let bonus = unlocked.reduce(0) { $0 + $1.bonusXP }
        return LearnReward(xp: LearnLibrary.refresherXP + bonus, achievements: unlocked.map(\.badge))
    }

    /// Unlocks every learning achievement whose requirement is now met and
    /// grants its bonus XP. Returns the newly unlocked achievements.
    private func refreshLearnAchievements(
        earnedAt: Date? = .now,
        celebrate: Bool = true
    ) -> [LearnAchievement] {
        let lessons = learnedLessonCount(in: LearnLibrary.all)
        var unlocked: [LearnAchievement] = []
        for achievement in JourneyLibrary.learnAchievements
        where !gardener.unlockedBadgeIDs.contains(achievement.badge.id) {
            let satisfied = switch achievement.requirement {
            case .lessonsLearned(let min): lessons >= min
            case .streakReached(let days): gardener.longestStreak >= days
            }
            guard satisfied else { continue }
            unlockBadge(achievement.badge.id, earnedAt: earnedAt, celebrate: celebrate)
            gardener.xp += achievement.bonusXP
            unlocked.append(achievement)
        }
        return unlocked
    }

    /// Records a badge as earned and, when the unlock is a real one happening
    /// right now, queues it for celebration.
    ///
    /// `earnedAt` is the existing signal for "this happened now" — a repair or a
    /// silent recompute passes nil — so it doubles as the guard on celebrating.
    /// `celebrate` then opts out the one caller that owns its own reward UI:
    /// the Academy shows finished-lesson badges inside its completion sheet,
    /// and queueing them here as well would fire two celebrations for one act.
    @discardableResult
    private func unlockBadge(_ id: String, earnedAt: Date?, celebrate: Bool = true) -> Bool {
        guard !gardener.unlockedBadgeIDs.contains(id) else { return false }
        gardener.unlockedBadgeIDs.insert(id)
        if let earnedAt {
            gardener.unlockedBadgeDates[id] = earnedAt
            if celebrate, let badge = JourneyLibrary.badge(id: id) {
                pendingBadges.append(badge)
            }
        }
        return true
    }

    /// Consumes and returns the oldest unshown badge, if any.
    func takePendingBadge() -> Badge? {
        pendingBadges.isEmpty ? nil : pendingBadges.removeFirst()
    }

    /// Repairs campaign badges for people who completed a milestone before
    /// that milestone gained artwork. The unlock is intentionally undated:
    /// migration day is not the day they did the work.
    private func repairCampaignBadgeUnlocks() -> Bool {
        var changed = false
        for milestone in JourneyLibrary.chapters.flatMap(\.milestones)
        where gardener.completedMilestoneIDs.contains(milestone.id) {
            guard let badgeID = milestone.badgeID else { continue }
            changed = unlockBadge(badgeID, earnedAt: nil) || changed
        }
        return changed
    }

    private func refreshCareAchievements(
        metrics: JourneyMetrics,
        earnedAt: Date?
    ) -> [CareAchievement] {
        var unlocked: [CareAchievement] = []
        for achievement in JourneyLibrary.careAchievements
        where !gardener.unlockedBadgeIDs.contains(achievement.badge.id) {
            let progress = JourneyEvaluator.progress(
                achievement.requirement,
                milestoneID: "badge-\(achievement.id)",
                progress: gardener,
                metrics: metrics,
                previousCompleted: false
            )
            guard progress.current >= progress.target else { continue }
            unlockBadge(achievement.badge.id, earnedAt: earnedAt)
            unlocked.append(achievement)
        }
        return unlocked
    }

    /// Namespaces lesson records so they can never collide with Journey
    /// milestone IDs inside `completedInteractiveIDs`.
    private static func learnRecordID(_ topicID: String) -> String { "learn-\(topicID)" }

    /// Consumes and clears the pending level-up, if any.
    func takePendingLevelUp() -> GardenerLevel? {
        defer { pendingLevelUp = nil }
        return pendingLevelUp
    }

    /// Consumes and clears the pending streak moment, if any.
    func takePendingStreakMoment() -> StreakMoment? {
        defer { pendingStreakMoment = nil }
        return pendingStreakMoment
    }

    /// Grants XP, badges, and keepsakes for every milestone whose requirement is
    /// now met but which has not yet been awarded. Idempotent: safe to call on
    /// any change.
    ///
    /// Runs to a fixed point, because finishing a chapter opens the next one:
    /// a single pass would award the last node of Chapter 2 and then leave
    /// Chapter 3's already-satisfied nodes sitting there until the next
    /// unrelated state change.
    @discardableResult
    func refreshJourney(persistIfChanged: Bool = true, announce: Bool = true) -> [JourneyMilestone] {
        let levelBefore = gardener.level
        let earnedAt: Date? = announce ? .now : nil
        // Streak-based learning achievements can be satisfied by any tend
        // (check-ins, journey nodes, inspections), not only by finishing a
        // lesson — evaluate them on every refresh so they can never be missed.
        let unlockedLearn = refreshLearnAchievements(earnedAt: earnedAt)
        let repairedCampaignBadges = repairCampaignBadgeUnlocks()
        var awarded: [JourneyMilestone] = []

        // One pass per chapter is always enough to reach the fixed point; the
        // bound is a guard against a content mistake, not an expected case.
        for _ in 0..<JourneyLibrary.chapters.count {
            let metrics = computeJourneyMetrics()
            let batch = JourneyEvaluator.newlyCompleted(progress: gardener, metrics: metrics)
            guard !batch.isEmpty else { break }
            for milestone in batch {
                gardener.completedMilestoneIDs.insert(milestone.id)
                gardener.xp += milestone.xpReward
                if let badgeID = milestone.badgeID {
                    unlockBadge(badgeID, earnedAt: earnedAt)
                }
                if let keepsakeID = milestone.keepsakeID { gardener.keepsakeIDs.insert(keepsakeID) }
                bankStreakShields(milestone.shieldReward)
                awarded.append(milestone)
            }
        }

        let unlockedCare = refreshCareAchievements(
            metrics: computeJourneyMetrics(),
            earnedAt: earnedAt
        )

        guard !awarded.isEmpty
                || !unlockedLearn.isEmpty
                || !unlockedCare.isEmpty
                || repairedCampaignBadges
        else { return awarded }
        if announce, gardener.level > levelBefore { pendingLevelUp = gardener.level }
        if persistIfChanged { persist() }
        return awarded
    }

    // MARK: - Chests

    /// Opens a chest: banks its XP, keepsake, and shields, and returns what it
    /// paid so the ceremony can show it. Returns `nil` if the chest is already
    /// open or isn't unlocked yet, so a double tap can never pay twice.
    @discardableResult
    func openChest(_ milestone: JourneyMilestone) -> ChestReward? {
        guard milestone.isChest,
              !gardener.openedChestIDs.contains(milestone.id),
              resolvedMilestone(id: milestone.id)?.status == .ready else { return nil }

        let levelBefore = gardener.level
        let shieldsBefore = gardener.streakShields
        gardener.openedChestIDs.insert(milestone.id)
        // The chest node's own requirement is now satisfied, so the shared
        // award path grants its XP, keepsake, and shields exactly once. The
        // ceremony shows the chest's own payout; anything the opening cascades
        // into (a finished chapter's next steps, their badges) is dated and
        // queued like any other live award.
        refreshJourney(persistIfChanged: false)
        if gardener.level > levelBefore { pendingLevelUp = gardener.level }
        persist()

        return ChestReward(
            milestoneID: milestone.id,
            title: milestone.blurb,
            xp: milestone.xpReward,
            keepsake: milestone.keepsakeID.flatMap(KeepsakeLibrary.keepsake(id:)),
            // What actually landed in the bank, not what the node offers: with
            // the bank already full the chest pays no shields, and a ceremony
            // that announced three anyway would be describing a gift nobody
            // received.
            shields: gardener.streakShields - shieldsBefore
        )
    }

    // MARK: - Landmark discoveries

    /// Records a map landmark once. Discoveries are cosmetic world moments,
    /// not extra care requirements, so they never change XP or milestone truth.
    /// The catalogue guard keeps a stale view or a future deep link from
    /// persisting arbitrary IDs into the account snapshot.
    @discardableResult
    func discoverLandmark(_ landmarkID: String) -> Bool {
        guard JourneyLandmarkLibrary.landmark(id: landmarkID) != nil,
              !gardener.discoveredLandmarkIDs.contains(landmarkID)
        else { return false }

        gardener.discoveredLandmarkIDs.insert(landmarkID)
        persist()
        return true
    }

    // MARK: - Daily quests

    /// Today's quest board.
    var dailyQuests: [DailyQuest] {
        JourneyQuestBoard.quests(progress: gardener, plantsOwned: plants.count)
    }

    /// Banks a finished quest's XP. Safe to call twice — the second call is a
    /// no-op.
    ///
    /// The passed-in quest only names which one. Its `isComplete` and `xp` are
    /// a snapshot of whatever board the view last drew, which can be
    /// yesterday's: trusting it paid a quest finished yesterday on today's
    /// counters. Today's board is rebuilt here and is the only thing that pays.
    @discardableResult
    func claimQuest(_ quest: DailyQuest) -> Bool {
        rollQuestDayIfNeeded()
        guard let live = dailyQuests.first(where: { $0.id == quest.id }),
              live.isComplete,
              !gardener.claimedQuestIDs.contains(live.id) else { return false }
        let levelBefore = gardener.level
        gardener.claimedQuestIDs.insert(live.id)
        gardener.xp += live.xp
        if gardener.level > levelBefore { pendingLevelUp = gardener.level }
        persist()
        return true
    }

    /// Which daily quest a care action pays, if any.
    ///
    /// Inspection is a look; other hands-on care is tending. Check-ins pay
    /// through `applyCheckIn`, never through their task. Watering, feeding and
    /// treating pay nothing: COPY.md rules out any streak, badge, XP or
    /// celebration attached to them, because a reward for watering is an
    /// incentive to overwater. Exhaustive so a new kind has to decide.
    private static func questObjective(for kind: CareKind) -> DailyQuest.Objective? {
        switch kind {
        case .inspectSoil:
            return .look
        case .rotate, .cleanLeaves, .prune, .repot, .relocate, .monitor:
            return .tend
        case .checkIn, .water, .fertilise, .treat:
            return nil
        }
    }

    /// Whether a completed care task counts towards the Journey's "care
    /// logged" steps. Same exclusions as the quest board, for the same reason.
    private static func earnsCareCredit(_ kind: CareKind) -> Bool {
        switch kind {
        case .inspectSoil, .rotate, .cleanLeaves, .prune, .repot, .relocate, .monitor:
            return true
        case .checkIn, .water, .fertilise, .treat:
            return false
        }
    }

    /// Takes back one unit of quest credit when the act that earned it is
    /// undone. Only today's counters move, and only for an act performed
    /// today, so an undo can never dent a fresh board or go below zero.
    private func retractQuestProgress(_ objective: DailyQuest.Objective, earnedOn date: Date) {
        let calendar = Calendar.current
        guard let day = gardener.questDay,
              calendar.isDate(day, inSameDayAs: date),
              calendar.isDate(day, inSameDayAs: .now) else { return }
        switch objective {
        case .look: gardener.questCheckIns = max(0, gardener.questCheckIns - 1)
        case .tend: gardener.questCareLogged = max(0, gardener.questCareLogged - 1)
        case .learn: gardener.questLessons = max(0, gardener.questLessons - 1)
        case .sweep: break
        }
    }

    /// Clears yesterday's quest counters the first time today's state is
    /// touched. Quests are a daily loop; carrying counters over would let one
    /// busy Sunday pay out all week.
    private func rollQuestDayIfNeeded(on date: Date = .now) {
        if let day = gardener.questDay, Calendar.current.isDate(day, inSameDayAs: date) { return }
        gardener.questDay = Self.dayStamp(for: date)
        gardener.questCheckIns = 0
        gardener.questCareLogged = 0
        gardener.questLessons = 0
        gardener.questPlantsAdded = 0
        gardener.claimedQuestIDs = []
    }

    /// Records one unit of today's real work against the quest board.
    private func recordQuestProgress(_ objective: DailyQuest.Objective, on date: Date = .now) {
        rollQuestDayIfNeeded(on: date)
        switch objective {
        case .look: gardener.questCheckIns += 1
        case .tend: gardener.questCareLogged += 1
        case .learn: gardener.questLessons += 1
        case .sweep: break
        }
    }

    // MARK: - Metrics

    private func computeJourneyMetrics() -> JourneyMetrics {
        let bandOrder: [HealthBand] = [.thriving, .healthy, .monitor, .attention, .urgent]
        let bestBand = bandOrder.first { band in
            plants.contains { $0.hasHealthReading && $0.healthBand == band }
        }

        // Deepest single timeline: the plant that has been looked at most.
        var observationsPerPlant: [UUID: Int] = [:]
        for observation in observations {
            observationsPerPlant[observation.plantID, default: 0] += 1
        }

        // Longest uninterrupted Healthy-or-better run on one plant. Sort once
        // into real chronology because observations are normally stored newest
        // first, while a run only makes sense from oldest to newest.
        var currentHealthyRun: [UUID: Int] = [:]
        var longestHealthyRun = 0
        for observation in observations.sorted(by: { $0.createdAt < $1.createdAt }) {
            if observation.band.goodnessRank >= HealthBand.healthy.goodnessRank {
                currentHealthyRun[observation.plantID, default: 0] += 1
                longestHealthyRun = max(
                    longestHealthyRun,
                    currentHealthyRun[observation.plantID, default: 0]
                )
            } else {
                currentHealthyRun[observation.plantID] = 0
            }
        }

        // A recovery: a plant recorded at Needs attention or worse that now
        // sits at Healthy or better. "Recorded" means every reading Grove
        // holds, check-ins *and* the scans attached to the plant: the adoption
        // scan is usually where a struggling plant first shows up, and reading
        // check-ins alone never saw a plant adopted sick and nursed back.
        //
        // Scans add one way to be wrong that check-ins didn't have: a
        // provisional diagnosis is recorded without touching the plant's
        // score, so a healthy plant can carry a low reading taken *after* it
        // was last seen healthy. That is a worry being looked into, not a plant
        // brought back, so a low reading only counts when it came before the
        // plant's latest healthy evidence (a healthy reading, or the assessment
        // that set today's band).
        let isHealthy = { (rank: Int) in rank >= HealthBand.healthy.goodnessRank }
        let measuredReadings = healthReadings.filter { !$0.isEstimated }
        var latestHealthyEvidence: [UUID: Date] = [:]
        for plant in plants where plant.hasHealthReading && isHealthy(plant.healthBand.goodnessRank) {
            latestHealthyEvidence[plant.id] = plant.assessmentDate
        }
        for reading in measuredReadings where isHealthy(HealthBand(score: reading.score).goodnessRank) {
            latestHealthyEvidence[reading.plantID] = max(
                latestHealthyEvidence[reading.plantID] ?? reading.date,
                reading.date
            )
        }
        let broughtBack = Set(
            measuredReadings
                .filter { reading in
                    guard let healthy = latestHealthyEvidence[reading.plantID] else { return false }
                    return HealthBand(score: reading.score).goodnessRank <= HealthBand.attention.goodnessRank
                        && reading.date < healthy
                }
                .map(\.plantID)
        )
        let recovered = plants.filter { plant in
            broughtBack.contains(plant.id) && isHealthy(plant.healthBand.goodnessRank)
        }.count

        let locations = Set(
            plants
                .map { $0.location.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                // "Unassigned" is the placeholder for no room, and Today does
                // not count it as one either.
                .filter { !$0.isEmpty && $0 != "unassigned" }
        )

        // Plant sitting is measured from the owner's side only: handovers this
        // account made, never ones it was asked to cover for a friend. A link
        // is the default way to hand plants over, so a minted link counts the
        // same as an in-app invitation, unless it was pulled before anyone
        // opened it (then nobody was ever handed anything).
        let outgoingHandovers = assignments.filter { !$0.isIncoming }
        let handedOverLinks = sittingInvites.filter { invite in
            invite.isMinted
                && (!(invite.isRevoked || invite.isRevocationPending) || invite.hasBeenOpened)
        }

        return JourneyMetrics(
            plantsOwned: plants.count,
            // Watering, feeding and treating never pay; see `earnsCareCredit`.
            careLogged: tasks.filter { $0.isCompleted && Self.earnsCareCredit($0.kind) }.count,
            checkInsCompleted: observations.count,
            bestBand: bestBand,
            healthyPlants: plants.filter {
                $0.hasHealthReading && $0.healthBand.goodnessRank >= HealthBand.healthy.goodnessRank
            }.count,
            thrivingPlants: plants.filter { $0.hasHealthReading && $0.healthBand == .thriving }.count,
            longestStreak: gardener.longestStreak,
            lessonsLearned: learnedLessonCount(in: LearnLibrary.all),
            deepestTimeline: observationsPerPlant.values.max() ?? 0,
            distinctLocations: locations.count,
            collectionsCreated: collections.count,
            recoveredPlants: recovered,
            sittersInvited: outgoingHandovers.count + handedOverLinks.count,
            newGrowthObservations: observations.filter(\.hasNewGrowth).count,
            longestHealthyCheckInRun: longestHealthyRun,
            // Care someone else actually did for this grove: tasks ticked on an
            // outgoing handover, plus care logged through a link (counted even
            // if the link was later pulled; the care still happened).
            sitterCareCompleted: outgoingHandovers.reduce(0) { $0 + $1.completedTasks }
                + sittingInvites.reduce(0) { $0 + ($1.completedCareCount ?? 0) }
        )
    }

    /// Advances the plant-safe streak for a qualifying learning or inspection
    /// action today. Never triggered by watering, by design.
    ///
    /// A single missed day is covered by a banked shield rather than resetting
    /// the count. Shields come from chests, which come from real care — so the
    /// mercy is earned, and it can only ever be spent once per lapse.
    private func recordTend(on date: Date = .now) {
        let stamp = Self.dayStamp(for: date)
        let bestBefore = gardener.longestStreak
        var shieldSpent = false
        if gardener.lastTendDay != nil {
            guard let gap = daysSinceLastTend(now: date) else { return }
            // Gap zero covers both "already tended today" and a stamp that has
            // landed in the future — a clock change, or a flight east over the
            // date line. Returning leaves `lastTendDay` where it is: rewinding
            // it would let one calendar day tend the streak twice.
            if gap == 0 { return }
            if gap == 1 {
                gardener.currentStreak += 1
            } else if gap == 2, gardener.streakShields > 0 {
                gardener.streakShields -= 1
                gardener.currentStreak += 1
                shieldSpent = true
            } else {
                gardener.currentStreak = 1
                // A fresh streak can earn its shields over again.
                gardener.lastShieldStreak = 0
            }
        } else {
            gardener.currentStreak = 1
            gardener.lastShieldStreak = 0
        }
        gardener.lastTendDay = stamp
        gardener.longestStreak = max(gardener.longestStreak, gardener.currentStreak)
        let shieldsBefore = gardener.streakShields
        grantStreakShieldIfEarned()

        // Every path that reaches this line moved the number; the two that
        // don't (already tended today, a stamp from the future) returned
        // above. `shieldsBanked` is the delta rather than the rule, so a
        // seventh day that finds the bank full is not announced as a gift.
        pendingStreakMoment = StreakMoment(
            day: gardener.currentStreak,
            previousBest: bestBefore,
            shieldSpent: shieldSpent,
            shieldsBanked: gardener.streakShields - shieldsBefore
        )
    }

    /// The instant to remember a calendar day by — the streak's last tend, the
    /// quest board's day, the learning dividend's day.
    ///
    /// Midday, not midnight. These are counted in calendar days, and a calendar
    /// day only exists relative to a time zone — so a midnight stamp re-read in
    /// another zone lands on the day before or the day after. Grove travels with
    /// its owner (there is a whole `TravelWatcher` for it), and a midnight stamp
    /// meant a flight could quietly break a streak that had been tended every
    /// single day. Midday is more than any real zone shift away from either
    /// boundary, so the same day still reads as the same day wherever the phone
    /// wakes up.
    ///
    /// Stamps written before this fix are midnight; `dayGap` and
    /// `isDate(inSameDayAs:)` both read them fine, and they are upgraded the
    /// next time the marker is written.
    private static func dayStamp(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date)
            ?? calendar.startOfDay(for: date)
    }

    /// Whole calendar days from one instant to another, both read in the
    /// current calendar. Normalising to the day is what makes the count a count
    /// of days rather than of 24-hour blocks — without it a stored stamp that is
    /// eight hours off (a zone change, a DST jump) rounds a real day down to
    /// zero and reads as a broken streak.
    private static func dayGap(from: Date, to: Date, calendar: Calendar = .current) -> Int? {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: from),
            to: calendar.startOfDay(for: to)
        ).day
    }

    /// Every seventh day of an unbroken streak banks a shield. The streak is
    /// the thing shields protect, so the streak is what pays for them.
    private func grantStreakShieldIfEarned() {
        guard gardener.currentStreak > 0, gardener.currentStreak.isMultiple(of: 7) else { return }
        guard gardener.currentStreak > gardener.lastShieldStreak else { return }
        gardener.lastShieldStreak = gardener.currentStreak
        bankStreakShields(1)
    }

    /// The most shields anyone can hold. A cap is what keeps the mercy a
    /// cushion rather than a stockpile that makes the streak unloseable.
    static let maxStreakShields = 3

    /// Banks shields up to the cap — and never takes any away.
    ///
    /// Both halves matter. Chests used to add without a cap while the weekly
    /// grant clamped with `min(3,)`, so a player who had opened the campaign's
    /// chests (fourteen shields between them) and then reached day seven of a
    /// streak had their bank *cut* to three by what was supposed to be a
    /// reward. Clamping the sum rather than the result is the fix; the `max`
    /// means an over-cap bank written by an older build is left alone instead
    /// of being confiscated by the first shield it earns afterwards.
    private func bankStreakShields(_ count: Int) {
        guard count > 0 else { return }
        gardener.streakShields = max(
            gardener.streakShields,
            min(Self.maxStreakShields, gardener.streakShields + count)
        )
    }

    func deleteAllLocalData() {
        let accountMediaRoot = mediaRootDirectory
        if let accountID = activeAccountID {
            SittingInviteURLStore.removeAll(accountID: accountID)
        }
        discardPendingPersistence(forKey: persistenceKey)
        discardPendingPersistence(forKey: Self.legacyPersistenceKey)
        revision &+= 1
        cachedPresentationIndex = nil
        completionActivityIDs = [:]
        selfLoggedTaskIDs = []
        serverKnownPlantIDs = []
        unacknowledgedObservationIDs = []
        unacknowledgedDiagnosisIDs = []
        tendRollbacks = [:]
        lastTendTaskID = nil
        plants = []
        collections = []
        tasks = []
        sittingPlants = []
        sittingTasks = []
        activity = []
        lastSeenActivityAt = nil
        // A link the user handed out is live data about them held by someone
        // else. "Delete everything" has to retract it from this device too,
        // rather than leaving a working URL behind the promise.
        sittingInvites = []
        assignments = []
        observations = []
        diagnoses = []
        scanHistory = []
        friends = []
        friendInvitations = []
        gardener = .new
        gardenerUpdatedAt = nil
        gardenerEnqueuedAt = nil
        persistedGardener = .new
        gardenerReconciledWithServer = false
        pendingLevelUp = nil
        pendingBadges = []
        pendingStreakMoment = nil
        // The profile is account data too — name, username, and the pinned
        // Grove location. Leaving it in memory meant any `persist()` between
        // this call and the next sign-in wrote it straight back out under the
        // legacy key, which the demo account then adopts on activation.
        profile = UserProfile(name: "", username: "", initials: Self.initials(for: ""), friendCount: 0)
        // Deleting is the one write allowed over an unreadable snapshot, and
        // its preserved copy goes with it: the screen promises nothing stays.
        for key in [persistenceKey, Self.legacyPersistenceKey] {
            storage.removeObject(forKey: key)
            storage.removeObject(forKey: Self.unreadableSnapshotBackupKey(for: key))
            Self.unreadableSnapshotKeys.remove(StagedSnapshotKey(storageID: ObjectIdentifier(storage), key: key))
        }
        try? FileManager.default.removeItem(at: accountMediaRoot)
        activeAccountID = nil
        persistenceKey = Self.legacyPersistenceKey
    }

    private func persist() {
        prepareGardenerRevisionForPersistence()
        revision &+= 1
        guard persistenceEnabled, !isWriteProtected(persistenceKey) else { return }
        let snapshot = makeSnapshot()
        let key = persistenceKey
        let stagedKey = StagedSnapshotKey(storageID: ObjectIdentifier(storage), key: key)
        let token = UUID()
        Self.stagedSnapshots[stagedKey] = StagedSnapshot(token: token, snapshot: snapshot)

        let generation = (persistenceGenerations[key] ?? 0) &+ 1
        persistenceGenerations[key] = generation
        persistenceTasks[key]?.cancel()
        persistenceTasks[key] = Task.detached(priority: .utility) { [snapshot] in
            guard let data = try? JSONEncoder().encode(snapshot), !Task.isCancelled else { return }
            await self.commitPersistedSnapshot(
                data,
                key: key,
                stagedKey: stagedKey,
                token: token,
                generation: generation
            )
        }
    }

    private func persistImmediately() {
        guard persistenceEnabled, !isWriteProtected(persistenceKey) else { return }
        prepareGardenerRevisionForPersistence()
        let key = persistenceKey
        persistenceTasks[key]?.cancel()
        persistenceTasks[key] = nil
        let snapshot = makeSnapshot()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        storage.set(data, forKey: key)
        Self.stagedSnapshots.removeValue(
            forKey: StagedSnapshotKey(storageID: ObjectIdentifier(storage), key: key)
        )
    }

    /// All durable state mutations already pass through `persist`, so this one
    /// comparison is the reliable place to version Journey progress. A whole
    /// second is used because both URLSession coders intentionally speak the
    /// no-fraction ISO-8601 format; two writes in one second still need a
    /// deterministic order at the server.
    ///
    /// Until this session has seen the server's copy (a bootstrap applied),
    /// a document that has never held a real revision is stamped
    /// *provisionally*: a second or two past 1970. The server keeps whichever
    /// revision is newer, so a provisional upload can seed an account that has
    /// no Journey yet but can never overwrite one that does. Without this, a
    /// new phone that paid the first-plant step before its first sync stamped
    /// a near-empty document "now", uploaded it ahead of the bootstrap, and
    /// replaced the account's real progress. The first applied bootstrap
    /// merges both copies and mints a real revision for the result.
    private func prepareGardenerRevisionForPersistence() {
        guard gardener != persistedGardener else { return }
        if !gardenerReconciledWithServer,
           gardenerUpdatedAt.map({ $0 < Self.provisionalRevisionCeiling }) ?? true {
            gardenerUpdatedAt = (gardenerUpdatedAt ?? Date(timeIntervalSince1970: 0)).addingTimeInterval(1)
            persistedGardener = gardener
            return
        }
        // Whole seconds, as the comment above promises: every coder drops the
        // fraction, so a fractional revision in memory never matched its own
        // queued copy after a relaunch and was queued again.
        let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
        if let previous = gardenerUpdatedAt, now <= previous.addingTimeInterval(1) {
            gardenerUpdatedAt = previous.addingTimeInterval(1)
        } else {
            gardenerUpdatedAt = now
        }
        persistedGardener = gardener
    }

    /// Revisions before this are provisional (see above). A year past the
    /// epoch, far beyond any count of provisional stamps and far before any
    /// real one. `migrateLegacyGardenerRevisionIfNeeded`'s undated fallback
    /// falls in the same range, and is just as unable to beat a real copy.
    private static let provisionalRevisionCeiling = Date(timeIntervalSince1970: 365 * 24 * 60 * 60)

    /// Progress written before account sync had no revision. Use the newest
    /// dated fact already inside it when possible, rather than pretending an
    /// old second device changed the account merely because it opened later.
    private func migrateLegacyGardenerRevisionIfNeeded() {
        guard gardenerUpdatedAt == nil, gardener != .new else { return }
        let datedFacts = [
            gardener.lastTendDay,
            gardener.lastRefresherXPDay,
            gardener.questDay,
            gardener.unlockedBadgeDates.values.max()
        ].compactMap { $0 }
        gardenerUpdatedAt = datedFacts.max() ?? Date(timeIntervalSince1970: 1)
        gardenerEnqueuedAt = nil
    }

    private func commitPersistedSnapshot(
        _ data: Data,
        key: String,
        stagedKey: StagedSnapshotKey,
        token: UUID,
        generation: UInt64
    ) {
        guard persistenceGenerations[key] == generation,
              Self.stagedSnapshots[stagedKey]?.token == token else { return }
        storage.set(data, forKey: key)
        Self.stagedSnapshots.removeValue(forKey: stagedKey)
        persistenceTasks[key] = nil
    }

    private func discardPendingPersistence(forKey key: String) {
        persistenceTasks[key]?.cancel()
        persistenceTasks[key] = nil
        persistenceGenerations[key] = nil
        Self.stagedSnapshots.removeValue(
            forKey: StagedSnapshotKey(storageID: ObjectIdentifier(storage), key: key)
        )
    }

    private func makeSnapshot() -> Snapshot {
        let tokenFreeInvites = sittingInvites.map { invite in
            var copy = invite
            copy.shareURL = nil
            return copy
        }
        return Snapshot(
            plants: plants,
            collections: collections,
            tasks: tasks,
            sittingPlants: sittingPlants,
            sittingTasks: sittingTasks,
            selfLoggedTaskIDs: selfLoggedTaskIDs,
            serverKnownPlantIDs: serverKnownPlantIDs,
            unacknowledgedObservationIDs: unacknowledgedObservationIDs,
            unacknowledgedDiagnosisIDs: unacknowledgedDiagnosisIDs,
            activity: activity,
            assignments: assignments,
            sittingInvites: tokenFreeInvites,
            observations: observations,
            diagnoses: diagnoses,
            scanHistory: scanHistory,
            friends: friends,
            friendInvitations: friendInvitations,
            profile: profile,
            gardener: gardener,
            gardenerUpdatedAt: gardenerUpdatedAt,
            gardenerEnqueuedAt: gardenerEnqueuedAt,
            lastSeenActivityAt: lastSeenActivityAt
        )
    }

    /// Migrates URLs written by older builds into Keychain and restores the
    /// in-memory copy from Keychain after a token-free snapshot load.
    private func migrateAndHydrateSittingInviteURLs(accountID: String) {
        for index in sittingInvites.indices {
            let inviteID = sittingInvites[index].id
            if sittingInvites[index].isRevoked || sittingInvites[index].isRevocationPending {
                SittingInviteURLStore.remove(accountID: accountID, inviteID: inviteID)
                sittingInvites[index].shareURL = nil
            } else if let url = sittingInvites[index].shareURL {
                _ = SittingInviteURLStore.save(url, accountID: accountID, inviteID: inviteID)
            } else {
                sittingInvites[index].shareURL = SittingInviteURLStore.load(
                    accountID: accountID,
                    inviteID: inviteID
                )
            }
        }
    }

    private var mediaRootDirectory: URL {
        AccountStorage.mediaRootURL(for: activeAccountID ?? "unscoped-preview")
    }

    /// Snapshot URLs are references, not deletion authority. A stale or
    /// tampered history record must never be able to remove a file outside the
    /// active account's protected media namespace.
    private func removeOwnedMediaFile(at url: URL) {
        guard url.isFileURL else { return }
        let root = mediaRootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else { return }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return }
        try? FileManager.default.removeItem(at: candidate)
    }

    private func decodedSnapshot(forKey key: String) -> Snapshot? {
        Self.decodedSnapshot(storage: storage, key: key)
    }

    private static func decodedSnapshot(storage: UserDefaults, key: String) -> Snapshot? {
        let stagedKey = StagedSnapshotKey(storageID: ObjectIdentifier(storage), key: key)
        if let staged = stagedSnapshots[stagedKey] {
            return staged.snapshot
        }
        guard let data = storage.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            // "Absent" and "unreadable" used to be the same nil, so a snapshot
            // this build could not read (a newer build's, after a TestFlight
            // downgrade) was treated as a new account and the next write
            // replaced the whole grove with an empty one. Keep the bytes, and
            // keep this key read-only for the rest of the process.
            preserveUnreadableSnapshot(data, storage: storage, key: key, error: error)
            return nil
        }
    }

    /// Keys whose stored snapshot could not be decoded. Nothing writes over
    /// them this session, so installing a build that can read them restores
    /// the grove as it was.
    private static var unreadableSnapshotKeys: Set<StagedSnapshotKey> = []

    static func unreadableSnapshotBackupKey(for key: String) -> String {
        "\(key).unreadable"
    }

    private static func preserveUnreadableSnapshot(
        _ data: Data,
        storage: UserDefaults,
        key: String,
        error: Error
    ) {
        unreadableSnapshotKeys.insert(StagedSnapshotKey(storageID: ObjectIdentifier(storage), key: key))
        storage.set(data, forKey: unreadableSnapshotBackupKey(for: key))
        GroveDiag.log("grove snapshot unreadable (\(data.count) bytes), kept and write-protected: \(error)")
    }

    private func isWriteProtected(_ key: String) -> Bool {
        Self.unreadableSnapshotKeys.contains(StagedSnapshotKey(storageID: ObjectIdentifier(storage), key: key))
    }

    private func apply(_ snapshot: Snapshot) {
        revision &+= 1
        cachedPresentationIndex = nil
        // Undo offers belong to the taps that raised them, never to a snapshot
        // that has just replaced the whole account.
        completionActivityIDs = [:]
        tendRollbacks = [:]
        lastTendTaskID = nil
        plants = snapshot.plants
        collections = snapshot.collections ?? []
        tasks = snapshot.tasks
        sittingPlants = snapshot.sittingPlants ?? []
        sittingTasks = snapshot.sittingTasks ?? []
        // Not transient like the undo bookkeeping above: this is the only record
        // that these rows have no server behind them, and the next bootstrap
        // deletes what it cannot account for.
        selfLoggedTaskIDs = snapshot.selfLoggedTaskIDs ?? []
        serverKnownPlantIDs = snapshot.serverKnownPlantIDs ?? []
        unacknowledgedObservationIDs = snapshot.unacknowledgedObservationIDs ?? []
        unacknowledgedDiagnosisIDs = snapshot.unacknowledgedDiagnosisIDs ?? []
        activity = snapshot.activity
        assignments = snapshot.assignments
        sittingInvites = snapshot.sittingInvites ?? []
        observations = snapshot.observations ?? []
        diagnoses = snapshot.diagnoses ?? []
        scanHistory = snapshot.scanHistory ?? []
        friends = snapshot.friends ?? []
        friendInvitations = snapshot.friendInvitations ?? []
        profile = snapshot.profile
        profile.friendCount = friends.count
        gardener = snapshot.gardener ?? .new
        gardenerUpdatedAt = snapshot.gardenerUpdatedAt
        gardenerEnqueuedAt = snapshot.gardenerEnqueuedAt
        persistedGardener = gardener
        migrateLegacyGardenerRevisionIfNeeded()
        lastSeenActivityAt = snapshot.lastSeenActivityAt
        let mediaPathsChanged = repairMediaPaths()
        let estimatedCopyChanged = repairEstimatedCheckInCopy()
        let progressBeforeRepair = gardener
        refreshJourney(persistIfChanged: false, announce: false)
        if mediaPathsChanged || estimatedCopyChanged || gardener != progressBeforeRepair {
            persist()
        }
    }

    /// Early estimated check-ins called every analysis failure "offline", even
    /// when the phone had a connection and the remote analysis service failed.
    /// Keep the durable record truthful without pretending to know which old
    /// failure category applied.
    @discardableResult
    private func repairEstimatedCheckInCopy() -> Bool {
        let oldPrefix = "Saved offline."
        let newPrefix = "Saved without photo analysis."
        var changed = false

        func repaired(_ copy: String) -> String {
            guard copy.hasPrefix(oldPrefix) else { return copy }
            return newPrefix + copy.dropFirst(oldPrefix.count)
        }

        for index in observations.indices where observations[index].isEstimated {
            let repairedNote = repaired(observations[index].note)
            if repairedNote != observations[index].note {
                observations[index].note = repairedNote
                changed = true
            }
        }

        for index in plants.indices where plants[index].assessmentSource == .offlineEstimate {
            let repairedSummary = repaired(plants[index].summary)
            if repairedSummary != plants[index].summary {
                plants[index].summary = repairedSummary
                changed = true
            }
        }

        return changed
    }

    /// Re-roots photo paths that were written under a previous install's data
    /// container, and reports whether anything moved so the caller can write the
    /// repaired snapshot back rather than re-deriving it every launch.
    ///
    /// A path that resolves nowhere is left exactly as it was: the photo may be
    /// unreachable, but overwriting the only record of where it lived turns a
    /// recoverable state into a permanent one.
    @discardableResult
    private func repairMediaPaths() -> Bool {
        var changed = false
        func repaired(_ url: URL?) -> URL? {
            guard let url, url.isFileURL,
                  !FileManager.default.fileExists(atPath: url.path),
                  let relocated = GroveMediaPath.relocated(url)
            else { return url }
            changed = true
            return relocated
        }
        for index in observations.indices {
            observations[index].photoURL = repaired(observations[index].photoURL)
        }
        for index in diagnoses.indices {
            diagnoses[index].photoURL = repaired(diagnoses[index].photoURL)
        }
        for index in scanHistory.indices {
            scanHistory[index].photoURL = repaired(scanHistory[index].photoURL)
        }
        profile.avatarPhotoURL = repaired(profile.avatarPhotoURL)
        return changed
    }

    private func installDemoFixtures() {
        completionActivityIDs = [:]
        selfLoggedTaskIDs = []
        serverKnownPlantIDs = []
        unacknowledgedObservationIDs = []
        unacknowledgedDiagnosisIDs = []
        tendRollbacks = [:]
        lastTendTaskID = nil
        plants = Plant.fixtures
        collections = PlantCollection.fixtures(plants: plants)
        tasks = CareTask.fixtures(plants: plants)
        activity = ActivityEvent.fixtures(plants: plants)
        assignments = SittingAssignment.fixtures(plants: plants)
        // Demo data is a clean slate, and a real link minted before the reset
        // would otherwise keep the fixture grove looking covered.
        sittingInvites = []
        observations = PlantObservation.fixtures(plants: plants)
        diagnoses = []
        scanHistory = []
        friends = PlantFriend.fixtures
        friendInvitations = FriendInvitation.fixtures
        profile = .fixture
        profile.friendCount = friends.count
        gardener = .new
        gardenerUpdatedAt = nil
        gardenerEnqueuedAt = nil
        persistedGardener = .new
        refreshJourney(persistIfChanged: false, announce: false)
    }

    /// A valid, friendly starting username derived from the display name, made
    /// distinct by a short stable tail from the account id. Matches the format
    /// `ProfileSetupView` validates: 3–24 lowercase ASCII letters, numbers or
    /// underscores.
    static func defaultUsername(for name: String, accountID: String) -> String {
        let letters = name.lowercased().unicodeScalars
            .filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
            .map(Character.init)
        let stem = String(letters.prefix(16))
        let tail = String(accountID.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.suffix(4))
        return String(((stem.count >= 3 ? stem : "gardener") + tail).prefix(24))
    }

    private static func initials(for name: String) -> String {
        let value = name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
        return value.isEmpty ? "GP" : value
    }

    private struct Snapshot: Codable, Sendable {
        let plants: [Plant]
        let collections: [PlantCollection]?
        let tasks: [CareTask]
        let sittingPlants: [FriendPlant]?
        let sittingTasks: [CareTask]?
        /// Which of `tasks` this device logged itself. Optional so groves
        /// written before self-logged care was protected still decode — they
        /// read as "none known", which is the pre-existing behaviour.
        let selfLoggedTaskIDs: Set<UUID>?
        /// Which plant ids the server has confirmed. Optional so groves written
        /// before unacknowledged plants were protected still decode — they read
        /// as "none confirmed", which keeps every existing plant on the phone
        /// until a bootstrap vouches for it.
        let serverKnownPlantIDs: Set<UUID>?
        /// Optional so groves written before these were tracked still decode,
        /// reading as "nothing unacknowledged".
        var unacknowledgedObservationIDs: Set<UUID>? = nil
        var unacknowledgedDiagnosisIDs: Set<UUID>? = nil
        let activity: [ActivityEvent]
        let assignments: [SittingAssignment]
        let sittingInvites: [SittingInvite]?
        let observations: [PlantObservation]?
        let diagnoses: [PlantDiagnosis]?
        let scanHistory: [ScanHistoryRecord]?
        let friends: [PlantFriend]?
        let friendInvitations: [FriendInvitation]?
        let profile: UserProfile
        let gardener: GardenerProgress?
        /// Optional so every account snapshot written before Journey sync still
        /// decodes and can be uploaded rather than being mistaken for empty.
        var gardenerUpdatedAt: Date? = nil
        var gardenerEnqueuedAt: Date? = nil
        /// Optional so snapshots written before Updates had a read marker still
        /// decode — they read as "never opened".
        let lastSeenActivityAt: Date?
    }
}

enum ProfileAvatarError: LocalizedError {
    case invalidImage
    case couldNotSave

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "That photo could not be read. Try choosing another one."
        case .couldNotSave:
            "Grove couldn't save that profile photo. Check your storage and try again."
        }
    }
}

private extension PlantFriend {
    static var fixtures: [PlantFriend] {
        [
            PlantFriend(
                id: "demo-maya",
                name: "Maya Kapoor",
                username: "mayagrows",
                initials: "MK",
                sharedPlantCount: 0,
                lastActiveAt: .now
            ),
            PlantFriend(
                id: "demo-lena",
                name: "Lena Shah",
                username: "leafylena",
                initials: "LS",
                sharedPlantCount: 0,
                lastActiveAt: Calendar.current.date(byAdding: .hour, value: -3, to: .now) ?? .now
            ),
            PlantFriend(id: "demo-omar", name: "Omar Lewis", username: "omarplants", initials: "OL", sharedPlantCount: 0, lastActiveAt: Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now)
        ]
    }
}

private extension FriendInvitation {
    static var fixtures: [FriendInvitation] {
        [
            FriendInvitation(
                id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
                accountID: "demo-noah",
                name: "Noah Williams",
                username: "noahroots",
                initials: "NW",
                direction: .incoming,
                createdAt: Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
            )
        ]
    }
}

private extension PlantObservation {
    static func fixtures(plants: [Plant]) -> [PlantObservation] {
        plants.flatMap { plant in
            let calendar = Calendar.current
            return [28, 14].enumerated().map { index, daysAgo in
                let score = max(30, plant.healthScore - (index == 0 ? 7 : 3))
                return PlantObservation(
                    id: UUID(),
                    plantID: plant.id,
                    createdAt: calendar.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now,
                    previousScore: max(30, score - 2),
                    score: score,
                    band: score >= 90 ? .thriving : score >= 75 ? .healthy : score >= 60 ? .monitor : .attention,
                    note: index == 0 ? "Baseline recorded." : "Routine check-in recorded.",
                    appearance: index == 0 ? .same : .better,
                    soilMoisture: .comfortable,
                    hasNewGrowth: index != 0,
                    photoURL: index == 1 ? DemoPlantPhotos.photoURL(for: plant.id) : nil,
                    actorName: "You"
                )
            }
        }
    }
}

private extension Plant {
    static var fixtures: [Plant] {
        let calendar = Calendar.current
        return [
            Plant(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                nickname: "Monty",
                species: "Swiss cheese plant",
                scientificName: "Monstera deliciosa",
                location: "Living room",
                lightPlacement: .bright,
                growingConditions: PlantGrowingConditions(
                    potMaterial: .plastic,
                    potSize: .large,
                    drainage: .drains,
                    substrate: .standard,
                    soilSurface: .damp,
                    potFit: .balanced,
                    confidence: 78,
                    capturedAt: calendar.date(byAdding: .day, value: -28, to: .now)
                ),
                healthScore: 92,
                healthBand: .thriving,
                trend: .improving,
                confidence: 96,
                nextCheckIn: calendar.date(byAdding: .day, value: 8, to: .now)!,
                symbol: "leaf.fill",
                palette: .fern,
                summary: "New growth is unfurling and leaf colour is even. Your recent move away from direct sun appears to be helping.",
                positiveSigns: ["Fresh leaf unfurling", "Even green colour", "Strong upright stems"],
                concerns: [],
                nextActions: ["Keep in bright, indirect light", "Check soil again in 5–7 days"]
            ),
            Plant(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                nickname: "Sunny",
                species: "Bird of paradise",
                scientificName: "Strelitzia reginae",
                location: "Bedroom",
                lightPlacement: .shaded,
                growingConditions: PlantGrowingConditions(
                    potMaterial: .glazed,
                    potSize: .xlarge,
                    drainage: .cachepot,
                    substrate: .dense,
                    soilSurface: .obscured,
                    surfaceSigns: [.topDressed],
                    potFit: .oversized,
                    confidence: 71,
                    capturedAt: calendar.date(byAdding: .day, value: -28, to: .now)
                ),
                healthScore: 68,
                healthBand: .monitor,
                trend: .stable,
                confidence: 82,
                nextCheckIn: .now,
                symbol: "bird.fill",
                palette: .sunset,
                summary: "The plant looks stable, but leaf curl and dry edges suggest it may need a closer moisture and humidity check.",
                positiveSigns: ["No visible pest activity", "Central growth remains upright"],
                concerns: ["Dry brown leaf edges", "Mild inward leaf curl"],
                nextActions: ["Check soil 5 cm deep", "Move away from the radiator", "Review again in 7 days"]
            ),
            Plant(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                nickname: "Spike",
                species: "Snake plant",
                scientificName: "Dracaena trifasciata",
                location: "Office",
                lightPlacement: .shaded,
                growingConditions: PlantGrowingConditions(
                    potMaterial: .terracotta,
                    potSize: .medium,
                    drainage: .drains,
                    substrate: .gritty,
                    soilSurface: .dry,
                    potFit: .snug,
                    confidence: 84,
                    capturedAt: calendar.date(byAdding: .day, value: -28, to: .now)
                ),
                healthScore: 85,
                healthBand: .healthy,
                trend: .stable,
                confidence: 93,
                nextCheckIn: calendar.date(byAdding: .day, value: 12, to: .now)!,
                symbol: "tree.fill",
                palette: .lime,
                summary: "Leaves are firm and upright with no meaningful change since the last check-in.",
                positiveSigns: ["Firm upright leaves", "No visible discoloration"],
                concerns: [],
                nextActions: ["Wait until soil is fully dry before watering", "Rotate a quarter turn next week"]
            ),
            Plant(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
                nickname: "Pearl",
                species: "String of pearls",
                scientificName: "Curio rowleyanus",
                location: "Kitchen",
                lightPlacement: .sill,
                growingConditions: PlantGrowingConditions(
                    potMaterial: .glazed,
                    potSize: .small,
                    drainage: .noHoles,
                    substrate: .standard,
                    soilSurface: .wet,
                    surfaceSigns: [.algae],
                    potFit: .balanced,
                    confidence: 66,
                    capturedAt: calendar.date(byAdding: .day, value: -28, to: .now)
                ),
                healthScore: 54,
                healthBand: .attention,
                trend: .declining,
                confidence: 87,
                nextCheckIn: calendar.date(byAdding: .day, value: -1, to: .now)!,
                symbol: "circle.hexagongrid.fill",
                palette: .sage,
                summary: "Several pearls look soft and translucent. Overwatering is possible, but inspect the soil and roots before acting.",
                positiveSigns: ["Some healthy green growth remains"],
                concerns: ["Soft translucent pearls", "Sparse growth near the crown"],
                nextActions: ["Do not water until soil is checked", "Inspect drainage holes", "Move to brighter indirect light"]
            )
        ]
    }
}

private extension PlantCollection {
    static func fixtures(plants: [Plant]) -> [PlantCollection] {
        guard plants.count >= 4 else { return [] }
        return [
            PlantCollection(
                name: "Bright spots",
                symbol: "sun.max.fill",
                palette: .lime,
                plantIDs: [plants[0].id, plants[2].id]
            ),
            PlantCollection(
                name: "Recovery watch",
                symbol: "cross.case.fill",
                palette: .sunset,
                plantIDs: [plants[1].id, plants[3].id]
            )
        ]
    }
}

private extension CareTask {
    static func fixtures(plants: [Plant]) -> [CareTask] {
        guard plants.count >= 4 else { return [] }
        return [
            CareTask(id: UUID(), plantID: plants[3].id, kind: .checkIn, dueDate: plants[3].nextCheckIn, detail: "Compare the soft pearls with the previous check-in.", isCompleted: false, isSittingTask: false, ownerName: nil),
            CareTask(id: UUID(), plantID: plants[1].id, kind: .checkIn, dueDate: .now, detail: "Check the curled leaf and soil moisture.", isCompleted: false, isSittingTask: false, ownerName: nil),
            CareTask(id: UUID(), plantID: plants[0].id, kind: .checkIn, dueDate: .now, detail: "One fresh photo, then Grove lines it up against the last one.", isCompleted: false, isSittingTask: false, ownerName: nil),
            CareTask(id: UUID(), plantID: plants[2].id, kind: .rotate, dueDate: Calendar.current.date(byAdding: .day, value: 2, to: .now)!, detail: "A quarter turn, so it stops growing all one way.", isCompleted: false, isSittingTask: true, ownerName: "Maya")
        ]
    }
}

private extension ActivityEvent {
    static func fixtures(plants: [Plant]) -> [ActivityEvent] {
        guard plants.count >= 4 else { return [] }
        return [
            ActivityEvent(id: UUID(), kind: .sitterCare, actorName: "Maya", actorInitials: "MK", message: "checked the soil and skipped watering", plantID: plants[2].id, timestamp: Calendar.current.date(byAdding: .hour, value: -2, to: .now)!),
            ActivityEvent(id: UUID(), kind: .improvement, actorName: "Grove", actorInitials: "G", message: "noticed stronger new growth since the last check-in", plantID: plants[0].id, timestamp: Calendar.current.date(byAdding: .day, value: -1, to: .now)!),
            ActivityEvent(id: UUID(), kind: .friendQuestion, actorName: "Lena", actorInitials: "LS", message: "asked if anyone recognises these spots", plantID: plants[1].id, timestamp: Calendar.current.date(byAdding: .day, value: -2, to: .now)!),
            ActivityEvent(id: UUID(), kind: .assignment, actorName: "Maya", actorInitials: "MK", message: "accepted your plant-sitting invitation", plantID: nil, timestamp: Calendar.current.date(byAdding: .day, value: -3, to: .now)!)
        ]
    }
}

private extension SittingAssignment {
    static func fixtures(plants: [Plant]) -> [SittingAssignment] {
        guard plants.count >= 3 else { return [] }
        return [
            SittingAssignment(
                id: UUID(),
                sitterName: "Maya Kapoor",
                sitterInitials: "MK",
                startDate: Calendar.current.date(byAdding: .day, value: 4, to: .now)!,
                endDate: Calendar.current.date(byAdding: .day, value: 12, to: .now)!,
                plantIDs: [plants[0].id, plants[1].id, plants[2].id],
                status: .upcoming,
                completedTasks: 0,
                totalTasks: 5
            )
        ]
    }
}

private extension UserProfile {
    static let fixture = UserProfile(name: "Alex Rivera", username: "alexgrows", initials: "AR", friendCount: 3)
}
