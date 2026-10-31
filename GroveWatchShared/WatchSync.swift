import Foundation

/// "Check, then act": the one rule for a repeat watering, shared by the phone
/// and the Watch so every surface refuses the same thing for the same reason.
enum RecentWateringGuard {
    /// How recently a plant must have been watered for another watering to
    /// count as a repeat rather than as care.
    static let window: TimeInterval = 3 * 24 * 60 * 60

    static func isRecent(_ wateredAt: Date?, now: Date) -> Bool {
        guard let wateredAt else { return false }
        // Inclusive to match `GroveStore.lastWatering(for:at:)`, which keeps a
        // watering exactly `window` old. The two must never disagree.
        return wateredAt <= now && now.timeIntervalSince(wateredAt) <= window
    }

    /// Said wherever a watering is refused.
    static func message(lastWateredAt: Date, now: Date = .now) -> String {
        "Watered \(lastWateredAt.formatted(.relative(presentation: .named))). Feel the soil before watering again."
    }
}

// The wire contract between the iPhone app and the watch app. Compiled into
// both targets, and deliberately free-standing: the watch never links
// `DomainModels.swift`, so everything it needs travels in these lite types.
//
// The phone is the source of truth. It pushes a `WatchSnapshot` through
// `updateApplicationContext` (latest-state-wins is exactly the right
// semantics for "what needs me today"), and the watch queues
// `WatchCareAction`s back through `transferUserInfo`, which survives the
// phone being out of reach. Payload enums mirror the app's own raw values so
// the phone can map them back with `init(rawValue:)` and a schema version
// guards the day the two apps update at different times.

enum WatchSyncSchema {
    static let version = 2
    /// Key holding the JSON-encoded `WatchSnapshot` in the application context.
    static let snapshotKey = "grove.watch.snapshot"
    /// Key holding a JSON-encoded `WatchCareAction` in a userInfo transfer.
    static let actionKey = "grove.watch.action"
    /// Key holding the phone's durable acknowledgement of a watch action.
    static let receiptKey = "grove.watch.receipt"
    static let versionKey = "grove.watch.schemaVersion"

    static func accepts(_ payload: [String: Any]) -> Bool {
        payload[versionKey] as? Int == version
    }

    /// Version 1 actions have the same encoded shape as version 2. Accepting
    /// them prevents care tapped on a Watch that updates a few minutes after
    /// its iPhone from disappearing during the rolling upgrade. Snapshots and
    /// receipts remain exact-version contracts because their shapes changed.
    static func acceptsAction(_ payload: [String: Any]) -> Bool {
        guard let incoming = payload[versionKey] as? Int else { return false }
        return incoming == 1 || incoming == version
    }
}

/// Mirror of `HealthBand`. Raw values must stay in lockstep with the app's
/// enum — the snapshot builder and the action handler both round-trip through
/// `rawValue`.
enum WatchHealthBand: String, Codable, Hashable, Sendable {
    case thriving
    case healthy
    case monitor
    case attention
    case urgent

    var title: String {
        switch self {
        case .thriving: "Thriving"
        case .healthy: "Healthy"
        case .monitor: "Monitor"
        case .attention: "Attention"
        case .urgent: "Urgent"
        }
    }

    var icon: String {
        switch self {
        case .thriving: "sparkles"
        case .healthy: "checkmark.circle.fill"
        case .monitor: "eye.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .urgent: "cross.case.fill"
        }
    }
}

/// Mirror of `HealthTrend`.
enum WatchHealthTrend: String, Codable, Hashable, Sendable {
    case improving
    case stable
    case declining
    case baseline

    var icon: String {
        switch self {
        case .improving: "arrow.up.right"
        case .stable: "arrow.right"
        case .declining: "arrow.down.right"
        case .baseline: "circle.dashed"
        }
    }

    var title: String {
        switch self {
        case .improving: "Improving"
        case .stable: "Stable"
        case .declining: "Declining"
        case .baseline: "Baseline"
        }
    }
}

/// Mirror of `CareKind`. Copy matches the phone app so the wrist and the
/// pocket never phrase the same job differently.
enum WatchCareKind: String, Codable, CaseIterable, Hashable, Sendable {
    case checkIn
    case inspectSoil
    case water
    case fertilise
    case rotate
    case cleanLeaves
    case treat
    case prune
    case repot
    case relocate
    case monitor

    var title: String {
        switch self {
        case .checkIn: "Health check-in"
        case .inspectSoil: "Feel the soil"
        case .water: "Water only if it's dry"
        case .fertilise: "Fertilise"
        case .rotate: "Turn the pot"
        case .cleanLeaves: "Clean the leaves"
        case .treat: "Treatment due"
        case .prune: "Trim what's damaged"
        case .repot: "Repot"
        case .relocate: "Move to a better spot"
        case .monitor: "Monitor the change"
        }
    }

    var icon: String {
        switch self {
        case .checkIn: "camera.viewfinder"
        case .inspectSoil: "hand.point.down.fill"
        case .water: "drop.fill"
        case .fertilise: "leaf.circle.fill"
        case .rotate: "rotate.right.fill"
        case .cleanLeaves: "sparkles"
        case .treat: "cross.case.fill"
        case .prune: "scissors"
        case .repot: "cylinder.split.1x2"
        case .relocate: "arrow.up.and.down.and.arrow.left.and.right"
        case .monitor: "eye.fill"
        }
    }

    var loggedTitle: String {
        switch self {
        case .checkIn: "a health check-in"
        case .inspectSoil: "a soil check"
        case .water: "watering"
        case .fertilise: "fertilising"
        case .rotate: "a rotation"
        case .cleanLeaves: "a leaf clean"
        case .treat: "a treatment"
        case .prune: "pruning"
        case .repot: "repotting"
        case .relocate: "a move"
        case .monitor: "a progress check"
        }
    }

    /// The label on a watch quick-log button, phrased as the thing just done.
    var logTitle: String {
        switch self {
        case .checkIn: "Checked in"
        case .inspectSoil: "Checked the soil"
        case .water: "Watered"
        case .fertilise: "Fertilised"
        case .rotate: "Rotated"
        case .cleanLeaves: "Cleaned leaves"
        case .treat: "Treated"
        case .prune: "Pruned"
        case .repot: "Repotted"
        case .relocate: "Moved"
        case .monitor: "Monitored"
        }
    }

    /// Same rule as the phone's `CareKind.loggable`: a check-in needs the
    /// guided photo flow, so it can never be a one-tap wrist log. The retired
    /// soil check is absent too: the phone drops a log of a non-loggable kind,
    /// so offering it here would record nothing. The case stays for decoding.
    static let loggable: [WatchCareKind] = [
        .water, .fertilise, .prune, .rotate, .cleanLeaves,
        .treat, .repot, .relocate, .monitor,
    ]
}

struct WatchPlantSummary: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var nickname: String
    var species: String
    var location: String
    var healthScore: Int
    var band: WatchHealthBand
    var trend: WatchHealthTrend
    var nextCheckIn: Date
    /// When the phone last recorded a watering, so the wrist can say "check the
    /// soil" before the gesture rather than learning it after a rejection.
    var lastWateredAt: Date? = nil
}

struct WatchTaskSummary: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var plantID: UUID
    var kind: WatchCareKind
    var dueDate: Date
    var detail: String
    var isSittingTask: Bool
}

/// Everything the watch shows, in one document. Small on purpose — the whole
/// grove's glanceable state, not the grove.
struct WatchSnapshot: Codable, Hashable, Sendable {
    var schemaVersion: Int = WatchSyncSchema.version
    var generatedAt: Date
    var streak: Int
    var streakIsShielded: Bool
    var plants: [WatchPlantSummary]
    /// Every incomplete task. The watch derives "due today" against its own
    /// clock so a task that crosses midnight still appears while the phone is
    /// asleep and the cached snapshot remains the newest available truth.
    var tasks: [WatchTaskSummary]

    func dueTasks(at date: Date = .now, calendar: Calendar = .current) -> [WatchTaskSummary] {
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else {
            return tasks
        }
        return tasks.filter { $0.dueDate < endOfDay }
    }

    func applicationContext() throws -> [String: Any] {
        [
            WatchSyncSchema.versionKey: schemaVersion,
            WatchSyncSchema.snapshotKey: try JSONEncoder().encode(self),
        ]
    }

    init(
        generatedAt: Date,
        streak: Int,
        streakIsShielded: Bool,
        plants: [WatchPlantSummary],
        tasks: [WatchTaskSummary]
    ) {
        self.generatedAt = generatedAt
        self.streak = streak
        self.streakIsShielded = streakIsShielded
        self.plants = plants
        self.tasks = tasks
    }

    /// Nil when the context predates this schema or isn't ours. The caller
    /// keeps whatever it already has — a stale snapshot beats a blank screen.
    init?(applicationContext: [String: Any]) {
        guard WatchSyncSchema.accepts(applicationContext),
              let data = applicationContext[WatchSyncSchema.snapshotKey] as? Data,
              let snapshot = try? JSONDecoder().decode(WatchSnapshot.self, from: data),
              snapshot.schemaVersion == WatchSyncSchema.version else {
            return nil
        }
        self = snapshot
    }
}

/// What the Watch's Today screen may claim when no task is due.
///
/// "All tended" is a promise about the plants. It is only made when there are
/// plants to have tended and the phone has spoken recently; otherwise the
/// wrist says what it actually knows.
enum WatchTodayEmptyState: Equatable, Sendable {
    /// No active plants on the phone.
    case noPlants
    /// The snapshot is older than `staleAfter`, so the queue may be wrong.
    case stale(since: Date)
    case allTended

    static let staleAfter: TimeInterval = 24 * 60 * 60

    /// Plain guard/if on purpose: the order is the contract. A grove with no
    /// plants can never be "all tended", and a stale queue can never be.
    static func resolve(snapshot: WatchSnapshot?, now: Date) -> WatchTodayEmptyState {
        guard let snapshot, !snapshot.plants.isEmpty else { return .noPlants }
        if now.timeIntervalSince(snapshot.generatedAt) > staleAfter {
            return .stale(since: snapshot.generatedAt)
        }
        return .allTended
    }
}

/// The few words a complication can carry. Kept here rather than in the widget
/// so the phone's test bundle can prove the empty and stale cases never claim
/// more than the snapshot knows.
enum WatchComplicationCopy {
    /// Matches the Watch's own empty-state threshold, so the widget and the
    /// Today screen never disagree about what counts as stale.
    static func isStale(snapshot: WatchSnapshot?, now: Date) -> Bool {
        guard let generatedAt = snapshot?.generatedAt else { return false }
        return now.timeIntervalSince(generatedAt) > WatchTodayEmptyState.staleAfter
    }

    /// Accessory inline has room for one sentence; when a queue is stale it
    /// keeps the count and appends the warning.
    static func inlineTitle(
        snapshot: WatchSnapshot?,
        dueCount: Int,
        streak: Int,
        now: Date
    ) -> String {
        guard let snapshot else { return "Open Grove to sync" }
        let due = dueLabel(dueCount: dueCount)
        if dueCount > 0 {
            return isStale(snapshot: snapshot, now: now) ? "\(due) · sync needed" : due
        }
        switch WatchTodayEmptyState.resolve(snapshot: snapshot, now: now) {
        case .noPlants:
            return "No plants yet"
        case .stale:
            return "\(due) · sync needed"
        case .allTended:
            return streak > 0 ? "All tended · \(streak)-day streak" : "All tended"
        }
    }

    /// The rectangular family's headline. The freshness line underneath
    /// already says when the snapshot was updated, so the headline only has to
    /// avoid claiming "All tended" for a grove that cannot support it.
    static func primaryTitle(
        snapshot: WatchSnapshot?,
        dueCount: Int,
        streak: Int,
        now: Date
    ) -> String {
        guard let snapshot else { return "Open Grove to sync" }
        if dueCount > 0 { return dueLabel(dueCount: dueCount) }
        switch WatchTodayEmptyState.resolve(snapshot: snapshot, now: now) {
        case .noPlants:
            return "No plants yet"
        case .stale:
            return "Sync needed"
        case .allTended:
            return "All tended"
        }
    }

    /// The spoken version, which keeps the count when there is one.
    static func accessibilityStatus(
        snapshot: WatchSnapshot?,
        dueCount: Int,
        now: Date
    ) -> String {
        guard let snapshot else { return "Open Grove on your iPhone to sync" }
        let due = dueLabel(dueCount: dueCount)
        if dueCount > 0 {
            return isStale(snapshot: snapshot, now: now) ? "\(due). Sync needed." : due
        }
        switch WatchTodayEmptyState.resolve(snapshot: snapshot, now: now) {
        case .noPlants:
            return "No plants yet"
        case .stale:
            return "\(due). Sync needed."
        case .allTended:
            return "All tended"
        }
    }

    private static func dueLabel(dueCount: Int) -> String {
        dueCount == 1 ? "1 care task due" : "\(dueCount) care tasks due"
    }
}

/// One thing the wearer did, queued from the wrist. Carries its own id so the
/// phone can drop a replayed transfer instead of watering the record twice.
struct WatchCareAction: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Tick off a task the phone scheduled. `taskID` names it.
        case completeTask
        /// Record ad-hoc care the wearer just did. `plantID` + `careKind`.
        case logCare
    }

    let id: UUID
    var kind: Kind
    var taskID: UUID?
    var plantID: UUID?
    var careKind: WatchCareKind?
    var performedAt: Date

    static func completeTask(_ task: WatchTaskSummary, at date: Date = .now) -> WatchCareAction {
        WatchCareAction(
            id: UUID(),
            kind: .completeTask,
            taskID: task.id,
            plantID: task.plantID,
            careKind: task.kind,
            performedAt: date
        )
    }

    static func logCare(plantID: UUID, careKind: WatchCareKind, at date: Date = .now) -> WatchCareAction {
        WatchCareAction(
            id: UUID(),
            kind: .logCare,
            taskID: nil,
            plantID: plantID,
            careKind: careKind,
            performedAt: date
        )
    }

    func userInfo() throws -> [String: Any] {
        [
            WatchSyncSchema.versionKey: WatchSyncSchema.version,
            WatchSyncSchema.actionKey: try JSONEncoder().encode(self),
        ]
    }

    init?(userInfo: [String: Any]) {
        guard WatchSyncSchema.acceptsAction(userInfo),
              let data = userInfo[WatchSyncSchema.actionKey] as? Data,
              let action = try? JSONDecoder().decode(WatchCareAction.self, from: data) else {
            return nil
        }
        self = action
    }

    init(
        id: UUID,
        kind: Kind,
        taskID: UUID?,
        plantID: UUID?,
        careKind: WatchCareKind?,
        performedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.taskID = taskID
        self.plantID = plantID
        self.careKind = careKind
        self.performedAt = performedAt
    }
}

/// The phone's answer to one queued wrist action. It repeats the action's
/// subject so a relaunched watch can still reconcile the result even if its
/// in-memory pending state disappeared before delivery.
struct WatchActionReceipt: Codable, Hashable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case accepted
        case rejected
    }

    let actionID: UUID
    let outcome: Outcome
    let taskID: UUID?
    let plantID: UUID?
    let careKind: WatchCareKind?
    let message: String
    let processedAt: Date

    init(
        action: WatchCareAction,
        outcome: Outcome,
        message: String,
        processedAt: Date = .now
    ) {
        actionID = action.id
        self.outcome = outcome
        taskID = action.taskID
        plantID = action.plantID
        careKind = action.careKind
        self.message = message
        self.processedAt = processedAt
    }

    func userInfo() throws -> [String: Any] {
        [
            WatchSyncSchema.versionKey: WatchSyncSchema.version,
            WatchSyncSchema.receiptKey: try JSONEncoder().encode(self),
        ]
    }

    init?(userInfo: [String: Any]) {
        guard WatchSyncSchema.accepts(userInfo),
              let data = userInfo[WatchSyncSchema.receiptKey] as? Data,
              let receipt = try? JSONDecoder().decode(WatchActionReceipt.self, from: data) else {
            return nil
        }
        self = receipt
    }
}

/// One tiny shared container lets the WidgetKit extension read the last state
/// the Watch app received without opening either app or owning a WCSession.
enum WatchSnapshotWidgetStore {
    static let appGroupIdentifier = "group.nz.co.thinkingai.Grove.watch"
    private static let key = "grove.watch.widgetSnapshot"

    static func save(_ snapshot: WatchSnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> WatchSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(WatchSnapshot.self, from: data),
              snapshot.schemaVersion == WatchSyncSchema.version else { return nil }
        return snapshot
    }
}
