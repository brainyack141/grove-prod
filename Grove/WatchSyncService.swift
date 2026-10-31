import Foundation
import Observation
import WatchConnectivity

/// The phone's half of the watch bridge.
///
/// Grove on the wrist exists for the moment the phone is the wrong tool: a
/// watering can in one hand, soil on the other. Everything the watch shows is
/// a projection of `GroveStore`, pushed here as a `WatchSnapshot` whenever the
/// store moves; everything the watch does comes back as a `WatchCareAction`
/// and is applied through the same store mutations the phone's own UI calls —
/// so a tick from the wrist earns the same activity entry, quest progress and
/// sync mutation as a tick on the screen.
///
/// Transport choices, deliberately boring:
/// - Phone → watch: `updateApplicationContext`. Latest-state-wins is exactly
///   the semantics of "what needs me today"; there is no queue to drain and
///   the newest truth replaces the old one even while the watch sleeps.
/// - Watch → phone: `transferUserInfo`. Queued and delivered in order even
///   when the phone was out of reach, which is what a log tapped in the
///   garden needs. Each action carries its own id, and ids that have already
///   been applied are dropped — a replayed transfer must not water the
///   record twice.
@MainActor
final class WatchSyncService: NSObject {
    private weak var store: GroveStore?
    private var syncEngine: SyncEngine?
    private var connectivity: ConnectivityMonitor?
    private let defaults: UserDefaults
    private var pushTask: Task<Void, Never>?
    private var receiptTransferRetryCounts: [UUID: Int] = [:]
    /// Actions whose server change is being queued right now. A transfer the
    /// watch redelivers inside that window must not be applied a second time
    /// before its receipt exists.
    private var actionsInFlight: Set<UUID> = []

    /// Receipts for actions already handled, newest last. Persisting the result
    /// rather than only the id lets a replay receive the same acknowledgement
    /// without applying care twice.
    /// Catalogued in `GroveDefaults` so deleting local data clears them: each
    /// receipt names a plant, a task and when it was cared for.
    private static let appliedActionsKey = GroveDefaults.watchAppliedActionIDs
    private static let receiptsKey = GroveDefaults.watchActionReceipts
    private static let appliedActionsLimit = 300

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Wires the service to the app's live objects and starts the session.
    /// Safe to call once from the app root; does nothing on devices with no
    /// paired watch beyond a cheap `isSupported` check.
    func attach(store: GroveStore, syncEngine: SyncEngine?, connectivity: ConnectivityMonitor?) {
        configure(store: store, syncEngine: syncEngine, connectivity: connectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        schedulePush()
    }

    /// The session-free half of `attach`, split out so tests can exercise
    /// snapshot building and action application without touching `WCSession`.
    func configure(store: GroveStore, syncEngine: SyncEngine?, connectivity: ConnectivityMonitor?) {
        self.store = store
        self.syncEngine = syncEngine
        self.connectivity = connectivity
        observeStore()
    }

    // MARK: - Snapshot

    /// The watch's whole world, computed from the store. Static and pure so
    /// tests can call it against a fixture store without a session.
    static func snapshot(from store: GroveStore, at date: Date = .now) -> WatchSnapshot {
        // Dormant, archived and deceased plants receive no care reminders on
        // the phone, so they must not appear on the wrist either. Their open
        // tasks are dropped below exactly like tasks for deleted plants.
        let activePlants = store.plants.filter { $0.effectiveLifecycleState.receivesCareReminders }
        let plants = activePlants.map { plant in
            WatchPlantSummary(
                id: plant.id,
                nickname: plant.nickname,
                species: plant.species,
                location: plant.location,
                healthScore: plant.healthScore,
                band: WatchHealthBand(rawValue: plant.healthBand.rawValue) ?? .healthy,
                trend: WatchHealthTrend(rawValue: plant.trend.rawValue) ?? .stable,
                nextCheckIn: plant.nextCheckIn,
                lastWateredAt: store.lastWatering(for: plant.id, at: date)?.performedAt
            )
        }
        let plantIDs = Set(activePlants.map(\.id))
        let tasks = store.pendingTasks.compactMap { task -> WatchTaskSummary? in
            // A task whose plant is gone — or no longer in active care — can't
            // be drawn (or completed meaningfully) on the watch, so it stays
            // off the wire.
            guard plantIDs.contains(task.plantID),
                  let kind = WatchCareKind(rawValue: task.kind.rawValue) else { return nil }
            return WatchTaskSummary(
                id: task.id,
                plantID: task.plantID,
                kind: kind,
                dueDate: task.dueDate,
                detail: task.detail,
                isSittingTask: task.isSittingTask
            )
        }
        return WatchSnapshot(
            generatedAt: date,
            streak: store.displayStreak,
            streakIsShielded: store.streakIsShielded,
            plants: plants,
            tasks: tasks
        )
    }

    /// Re-arms observation of everything the snapshot reads, so any mutation
    /// that would change what the watch shows schedules a push.
    private func observeStore() {
        guard let store else { return }
        withObservationTracking {
            _ = store.plants
            _ = store.tasks
            _ = store.gardener
            _ = store.calendarDay
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.schedulePush()
                self.observeStore()
            }
        }
    }

    /// Coalesces a burst of mutations (a sync landing, a check-in writing
    /// several fields) into one context update.
    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.pushSnapshot()
        }
    }

    private func pushSnapshot() {
        guard let store, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else { return }
        guard let context = try? Self.snapshot(from: store).applicationContext() else { return }
        // Throws only for transient session states; the next store change
        // re-sends a fresher snapshot anyway, so a failed push is never retried.
        try? session.updateApplicationContext(context)
    }

    // MARK: - Actions from the watch

    /// Applies one action from the wrist. Returns whether it changed anything;
    /// a replayed or stale action is dropped without complaint because the
    /// snapshot that follows reconciles the watch either way.
    @discardableResult
    func apply(_ action: WatchCareAction) -> Bool {
        if receipt(for: action.id) != nil || actionsInFlight.contains(action.id) { return false }
        let result = applyNew(action)
        remember(result.receipt)
        if let change = result.change {
            Task { await self.queue(change) }
        }
        return result.didApply
    }

    /// The delivery path. The receipt that makes a replay harmless is stored
    /// only once the change is durably in the sync queue: remembered first, a
    /// background launch killed in between kept the local care and never told
    /// the server, and the watch's redelivery was waved through as handled.
    private func process(_ action: WatchCareAction) async -> WatchActionReceipt? {
        if let existing = receipt(for: action.id) { return existing }
        guard actionsInFlight.insert(action.id).inserted else { return nil }
        defer { actionsInFlight.remove(action.id) }
        let result = applyNew(action)
        if let change = result.change, let syncEngine {
            // Written to disk without waiting on the network, so the window
            // before the receipt is a file write rather than a round trip.
            await syncEngine.enqueue(change, isConnected: false)
        }
        remember(result.receipt)
        if result.change != nil, let syncEngine, isConnected {
            Task { await syncEngine.processPending(isConnected: true) }
        }
        return result.receipt
    }

    /// Whether to try delivering now. The app always attaches a monitor; only
    /// tests run without one, and they read the queue rather than the server.
    private var isConnected: Bool { connectivity?.isConnected ?? false }

    private func queue(_ change: SyncMutationPayload) async {
        guard let syncEngine else { return }
        await syncEngine.enqueue(change, isConnected: isConnected)
    }

    private typealias Outcome = (receipt: WatchActionReceipt, didApply: Bool, change: SyncMutationPayload?)

    private func applyNew(_ action: WatchCareAction) -> Outcome {
        guard let store else {
            return rejected(action, "Open Grove on your iPhone, then try again.")
        }
        guard action.performedAt <= Date.now.addingTimeInterval(5 * 60) else {
            return rejected(action, "The Watch time is ahead of your iPhone. Check both clocks and try again.")
        }
        switch action.kind {
        case .completeTask:
            guard let taskID = action.taskID,
                  let task = store.task(id: taskID) else {
                return rejected(action, "That task is no longer in your grove.")
            }
            guard task.kind != .checkIn else {
                return rejected(action, "Photo check-ins must be completed on your iPhone.")
            }
            guard action.plantID == task.plantID,
                  action.careKind?.rawValue == task.kind.rawValue else {
                return rejected(action, "That task changed on your iPhone. Reopen Grove on your Watch.")
            }
            if task.isCompleted {
                return accepted(action, "Already completed", didApply: false)
            }
            if task.kind == .water,
               let last = store.lastWatering(for: task.plantID, at: action.performedAt) {
                return rejected(
                    action,
                    RecentWateringGuard.message(lastWateredAt: last.performedAt, now: action.performedAt)
                )
            }
            guard let completed = store.complete(taskID: taskID, at: action.performedAt) else {
                return rejected(action, "That task could not be completed.")
            }
            return accepted(
                action,
                "Completed",
                change: completionChange(completed, actionID: action.id, occurredAt: action.performedAt)
            )
        case .logCare:
            guard let plantID = action.plantID,
                  let watchKind = action.careKind,
                  let kind = CareKind(rawValue: watchKind.rawValue),
                  CareKind.loggable.contains(kind) else {
                return rejected(action, "That care type cannot be recorded from your Watch.")
            }
            guard store.plant(id: plantID) != nil else {
                return rejected(action, "That plant is no longer in your grove.")
            }
            if kind == .water,
               let last = store.lastWatering(for: plantID, at: action.performedAt) {
                return rejected(
                    action,
                    RecentWateringGuard.message(lastWateredAt: last.performedAt, now: action.performedAt)
                )
            }
            guard let logged = store.logCare(
                plantID: plantID,
                kind: kind,
                performedAt: action.performedAt
            ) else {
                return rejected(action, "Care could not be recorded. Open Grove on your iPhone to review it.")
            }
            return accepted(
                action,
                "Recorded",
                change: .createCareEvent(CreateCareEventRequest(task: logged, clientRequestID: action.id))
            )
        }
    }

    private func accepted(
        _ action: WatchCareAction,
        _ message: String,
        didApply: Bool
    ) -> Outcome {
        (WatchActionReceipt(action: action, outcome: .accepted, message: message), didApply, nil)
    }

    private func accepted(
        _ action: WatchCareAction,
        _ message: String,
        change: SyncMutationPayload
    ) -> Outcome {
        (WatchActionReceipt(action: action, outcome: .accepted, message: message), true, change)
    }

    private func rejected(
        _ action: WatchCareAction,
        _ message: String
    ) -> Outcome {
        (WatchActionReceipt(action: action, outcome: .rejected, message: message), false, nil)
    }

    private func storedReceipts() -> [WatchActionReceipt] {
        guard let data = defaults.data(forKey: Self.receiptsKey),
              let receipts = try? JSONDecoder().decode([WatchActionReceipt].self, from: data) else { return [] }
        return receipts
    }

    private func receipt(for actionID: UUID) -> WatchActionReceipt? {
        storedReceipts().last { $0.actionID == actionID }
    }

    private func remember(_ receipt: WatchActionReceipt) {
        var receipts = storedReceipts()
        receipts.removeAll { $0.actionID == receipt.actionID }
        receipts.append(receipt)
        if receipts.count > Self.appliedActionsLimit {
            receipts.removeFirst(receipts.count - Self.appliedActionsLimit)
        }
        if let data = try? JSONEncoder().encode(receipts) {
            defaults.set(data, forKey: Self.receiptsKey)
        }
        // Retire the id-only store once this build has successfully written the
        // richer replay record.
        defaults.removeObject(forKey: Self.appliedActionsKey)
    }

    private func send(_ receipt: WatchActionReceipt) {
        let session = WCSession.default
        guard session.activationState == .activated,
              let acknowledgement = try? receipt.userInfo() else { return }
        session.transferUserInfo(acknowledgement)
    }

    private func retryReceiptTransfer(_ receipt: WatchActionReceipt) {
        let retryCount = receiptTransferRetryCounts[receipt.actionID, default: 0] + 1
        receiptTransferRetryCounts[receipt.actionID] = retryCount
        guard retryCount <= 3 else { return }
        let retryDelay = Duration.seconds(Double(1 << retryCount))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: retryDelay)
            guard let self, self.receipt(for: receipt.actionID) != nil else { return }
            self.send(receipt)
        }
    }

    /// Same server mutation a completion on the phone sends, minus the 5-second
    /// undo window — the watch offers no undo, so there is nothing to wait for.
    private func completionChange(_ completed: CareTask, actionID: UUID, occurredAt: Date) -> SyncMutationPayload {
        .updateCareTask(CareTaskMutationRequest(
            taskID: completed.id,
            outcome: .completed,
            occurredAt: occurredAt,
            rescheduledFor: nil,
            reason: nil,
            clientRequestID: actionID
        ))
    }
}

extension WatchSyncService: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in self?.schedulePush() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // The user switched to a different watch; reactivate for the new one.
        session.activate()
    }

    /// Fires when the watch app is installed or removed — the moment the first
    /// snapshot can actually land.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.schedulePush() }
    }

    nonisolated func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // Decoded before the actor hop: the dictionary isn't Sendable, the
        // decoded action is.
        guard let action = WatchCareAction(userInfo: userInfo) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Nil while the same action is already being handled; that pass
            // sends its own receipt.
            guard let receipt = await self.process(action) else { return }
            self.send(receipt)
            // Answer with fresh truth so the watch reconciles its optimistic
            // state promptly rather than on the next unrelated mutation.
            self.schedulePush()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: (any Error)?
    ) {
        guard let receipt = WatchActionReceipt(userInfo: userInfoTransfer.userInfo) else { return }
        let succeeded = error == nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            if succeeded {
                self.receiptTransferRetryCounts.removeValue(forKey: receipt.actionID)
            } else {
                self.retryReceiptTransfer(receipt)
            }
        }
    }
}
