import Foundation
import Observation
import WatchConnectivity
import WatchKit
import WidgetKit

enum WatchActionState: Equatable {
    case pending
    case accepted(String)
    case rejected(String)
}

/// The watch's whole model layer.
///
/// The wrist never owns plant data — it holds the last `WatchSnapshot` the
/// phone pushed and shows it even with the phone out of reach, because "what
/// needs me today" was true when the phone said it and a stale answer beats a
/// blank screen. Care logged here is applied optimistically (the tapped task
/// leaves the queue at once) and queued to the phone through
/// `transferUserInfo`, which delivers whenever the pair next talk.
///
/// Reconciliation is one rule: the phone's snapshot always wins, except that
/// a task the wearer just ticked stays hidden until a snapshot arrives that
/// no longer lists it as due — otherwise every push generated before the
/// action landed would resurrect it for a few confusing seconds.
@MainActor
@Observable
final class WatchStore: NSObject {
    private(set) var snapshot: WatchSnapshot?
    /// Tasks ticked on the wrist that the phone has not yet confirmed gone.
    private(set) var completedTaskIDs: Set<UUID> = []

    private let defaults: UserDefaults
    /// Kept until the phone explicitly acknowledges them. The system owns a
    /// durable transfer after `transferUserInfo`, but this copy lets the UI stay
    /// honest and safely resubmit the same id after a process restart.
    private var outstandingActions: [WatchCareAction] = []
    private var submittedActionIDs: Set<UUID> = []
    private var transferRetryCounts: [UUID: Int] = [:]
    private var receipts: [WatchActionReceipt] = []

    private static let snapshotKey = "grove.watch.cachedSnapshot"
    private static let completedKey = "grove.watch.optimisticCompletedTaskIDs"
    private static let outstandingKey = "grove.watch.outstandingActions"
    private static let receiptsKey = "grove.watch.actionReceipts"
    private static let receiptLimit = 30

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        if let data = defaults.data(forKey: Self.snapshotKey),
           let cached = try? JSONDecoder().decode(WatchSnapshot.self, from: data),
           cached.schemaVersion == WatchSyncSchema.version {
            snapshot = cached
            WatchSnapshotWidgetStore.save(cached)
        }
        if let ids = defaults.stringArray(forKey: Self.completedKey) {
            completedTaskIDs = Set(ids.compactMap(UUID.init(uuidString:)))
        }
        if let data = defaults.data(forKey: Self.outstandingKey),
           let actions = try? JSONDecoder().decode([WatchCareAction].self, from: data) {
            outstandingActions = actions
        }
        if let data = defaults.data(forKey: Self.receiptsKey),
           let storedReceipts = try? JSONDecoder().decode([WatchActionReceipt].self, from: data) {
            receipts = Array(storedReceipts.suffix(Self.receiptLimit))
        }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        // A context updated while the app was closed is waiting here rather
        // than in a delegate call.
        if let received = WatchSnapshot(applicationContext: session.receivedApplicationContext) {
            apply(received)
        }
    }

    // MARK: - Reading

    var hasSnapshot: Bool { snapshot != nil }

    /// Due work, minus what the wearer already ticked off on the wrist.
    var dueTasks: [WatchTaskSummary] { dueTasks(at: .now) }

    func dueTasks(at date: Date) -> [WatchTaskSummary] {
        (snapshot?.dueTasks(at: date) ?? []).filter { !completedTaskIDs.contains($0.id) }
    }

    var plants: [WatchPlantSummary] { snapshot?.plants ?? [] }
    var streak: Int { snapshot?.streak ?? 0 }
    var streakIsShielded: Bool { snapshot?.streakIsShielded ?? false }
    var updatedAt: Date? { snapshot?.generatedAt }

    /// What the Today screen may say when nothing is due. Pure decision, so
    /// the view stays honest about no plants and stale snapshots.
    func todayEmptyState(at date: Date) -> WatchTodayEmptyState {
        WatchTodayEmptyState.resolve(snapshot: snapshot, now: date)
    }
    var pendingCompletionCount: Int {
        outstandingActions.filter { $0.kind == .completeTask }.count
    }

    func plant(id: UUID) -> WatchPlantSummary? {
        plants.first { $0.id == id }
    }

    /// The plant whose check-in comes up soonest — the one fact worth showing
    /// on a day with nothing due.
    var nextUp: WatchPlantSummary? {
        plants.filter { $0.nextCheckIn > .now }.min { $0.nextCheckIn < $1.nextCheckIn }
    }

    var nextTask: WatchTaskSummary? {
        snapshot?.tasks
            .filter { !completedTaskIDs.contains($0.id) && $0.dueDate > .now }
            .min { $0.dueDate < $1.dueDate }
    }

    func actionState(plantID: UUID, kind: WatchCareKind, now: Date = .now) -> WatchActionState? {
        if outstandingActions.contains(where: { $0.plantID == plantID && $0.careKind == kind }) {
            return .pending
        }
        guard let receipt = receipts.last(where: { $0.plantID == plantID && $0.careKind == kind }),
              now.timeIntervalSince(receipt.processedAt) < 5 * 60 else { return nil }
        switch receipt.outcome {
        case .accepted: return .accepted(receipt.message)
        case .rejected: return .rejected(receipt.message)
        }
    }

    // MARK: - Acting

    func completeTask(_ task: WatchTaskSummary) {
        guard task.kind != .checkIn else { return }
        completedTaskIDs.insert(task.id)
        persistCompleted()
        enqueue(.completeTask(task))
    }

    func logCare(plantID: UUID, kind: WatchCareKind) {
        guard actionState(plantID: plantID, kind: kind) != .pending else { return }
        enqueue(.logCare(plantID: plantID, careKind: kind))
    }

    private func enqueue(_ action: WatchCareAction) {
        outstandingActions.append(action)
        persistOutstanding()
        WKInterfaceDevice.current().play(.click)
        submit(action)
    }

    private func submit(_ action: WatchCareAction) {
        guard WCSession.isSupported(), !submittedActionIDs.contains(action.id) else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard let userInfo = try? action.userInfo() else { return }
        session.transferUserInfo(userInfo)
        submittedActionIDs.insert(action.id)
    }

    private func flushOutstandingActions() {
        for action in outstandingActions { submit(action) }
    }

    private func retryTransfer(for actionID: UUID) {
        submittedActionIDs.remove(actionID)
        guard let action = outstandingActions.first(where: { $0.id == actionID }) else { return }
        let retryCount = transferRetryCounts[actionID, default: 0] + 1
        transferRetryCounts[actionID] = retryCount
        guard retryCount <= 3 else { return }
        let retryDelay = Duration.seconds(Double(1 << retryCount))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: retryDelay)
            guard let self,
                  self.outstandingActions.contains(where: { $0.id == actionID }) else { return }
            self.submit(action)
        }
    }

    // MARK: - Reconciling

    private func apply(_ incoming: WatchSnapshot) {
        // `updateApplicationContext` is latest-wins, but the cached copy can
        // still be newer than a context replayed on reactivation.
        if let current = snapshot, incoming.generatedAt < current.generatedAt { return }
        snapshot = incoming
        // Any ticked task the phone no longer lists as due has been settled;
        // the rest stay hidden until their action lands.
        completedTaskIDs.formIntersection(incoming.tasks.map(\.id))
        if let data = try? JSONEncoder().encode(incoming) {
            defaults.set(data, forKey: Self.snapshotKey)
        }
        WatchSnapshotWidgetStore.save(incoming)
        WidgetCenter.shared.reloadTimelines(ofKind: "GroveTodayWidget")
        persistCompleted()
    }

    func accept(_ receipt: WatchActionReceipt) {
        outstandingActions.removeAll { $0.id == receipt.actionID }
        submittedActionIDs.remove(receipt.actionID)
        transferRetryCounts.removeValue(forKey: receipt.actionID)
        receipts.removeAll { $0.actionID == receipt.actionID }
        receipts.append(receipt)
        if receipts.count > Self.receiptLimit {
            receipts.removeFirst(receipts.count - Self.receiptLimit)
        }
        if receipt.outcome == .rejected, let taskID = receipt.taskID {
            completedTaskIDs.remove(taskID)
            persistCompleted()
        }
        persistOutstanding()
        persistReceipts()
        WKInterfaceDevice.current().play(receipt.outcome == .accepted ? .success : .failure)
    }

    private func persistCompleted() {
        defaults.set(completedTaskIDs.map(\.uuidString), forKey: Self.completedKey)
    }

    private func persistOutstanding() {
        if let data = try? JSONEncoder().encode(outstandingActions) {
            defaults.set(data, forKey: Self.outstandingKey)
        }
    }

    private func persistReceipts() {
        if let data = try? JSONEncoder().encode(receipts) {
            defaults.set(data, forKey: Self.receiptsKey)
        }
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated else { return }
        // A context that arrived while this app was dead is sitting in the
        // property, not in a delegate call — read it before flushing actions.
        let pending = WatchSnapshot(applicationContext: session.receivedApplicationContext)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let pending { self.apply(pending) }
            self.flushOutstandingActions()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        // Decoded before the actor hop — the dictionary isn't Sendable, the
        // snapshot is.
        guard let incoming = WatchSnapshot(applicationContext: applicationContext) else { return }
        Task { @MainActor [weak self] in
            self?.apply(incoming)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let receipt = WatchActionReceipt(userInfo: userInfo) else { return }
        Task { @MainActor [weak self] in
            self?.accept(receipt)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: (any Error)?
    ) {
        guard error != nil,
              let action = WatchCareAction(userInfo: userInfoTransfer.userInfo) else { return }
        Task { @MainActor [weak self] in
            self?.retryTransfer(for: action.id)
        }
    }
}
