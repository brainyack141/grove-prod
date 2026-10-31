import XCTest
@testable import Grove

@MainActor
private final class FakeRemoteRepository: GroveRemoteRepository {
    var checkInCalls = 0
    var careTaskCalls = 0
    var gardenerProgressCalls = 0
    var error: APIError?
    /// Fails one kind of change while the rest of the queue still succeeds.
    var checkInError: APIError?
    var recorder: SyncCallRecorder?
    var bootstrapResponse: GroveBootstrapResponse?
    var bootstrapStarted: XCTestExpectation?
    var bootstrapGate: TestAsyncGate?
    var friendMutationStarted: XCTestExpectation?
    var friendMutationGate: TestAsyncGate?
    var observedAccountScopes: [String?] = []

    func bootstrap() async throws -> GroveBootstrapResponse {
        observedAccountScopes.append(GroveAPIRequestScope.expectedAccountID)
        bootstrapStarted?.fulfill()
        await bootstrapGate?.wait()
        if let error { throw error }
        guard let bootstrapResponse else { throw APIError.notFound }
        recorder?.calls.append("bootstrap")
        return bootstrapResponse
    }

    func createPlant(_ request: CreatePlantRequest) async throws -> Plant {
        if let error { throw error }
        return Self.plant(id: request.clientPlantID)
    }

    func createCheckIn(_ request: CreateCheckInRequest) async throws -> Plant {
        checkInCalls += 1
        recorder?.calls.append("checkIn")
        if let checkInError { throw checkInError }
        if let error { throw error }
        return Self.plant(id: request.plantID)
    }

    func createSittingInvite(_ request: CreateSittingInviteRequest) async throws -> SittingInviteLink {
        recorder?.calls.append("createSittingInvite")
        if let error { throw error }
        return SittingInviteLink(
            id: request.inviteID,
            url: URL(string: "https://example.test/sit/token")!,
            expiresAt: request.endDate
        )
    }

    func revokeSittingInvite(_ request: RevokeSittingInviteRequest) async throws {
        recorder?.calls.append("revokeSittingInvite")
        if let error { throw error }
    }

    func createSittingAssignment(_ request: CreateSittingRequest) async throws -> SittingAssignment {
        recorder?.calls.append("createSittingAssignment")
        if let error { throw error }
        return SittingAssignment(
            id: request.clientRequestID ?? UUID(),
            sitterName: "Sitter",
            sitterInitials: "S",
            startDate: request.startDate,
            endDate: request.endDate,
            plantIDs: request.plantIDs,
            status: .invited,
            completedTasks: 0,
            totalTasks: 1
        )
    }

    func createFriendInvitation(_ request: CreateFriendInvitationRequest) async throws -> FriendInvitation {
        if let error { throw error }
        return FriendInvitation(
            id: request.clientRequestID,
            accountID: nil,
            name: "@\(request.username)",
            username: request.username,
            initials: String(request.username.prefix(2)).uppercased(),
            direction: .outgoing,
            createdAt: .now
        )
    }

    func respondToFriendInvitation(_ request: RespondToFriendInvitationRequest) async throws {
        recorder?.calls.append(request.accept ? "acceptFriendInvitation" : "declineFriendInvitation")
        if let error { throw error }
    }

    func withdrawFriendInvitation(_ request: WithdrawFriendInvitationRequest) async throws {
        recorder?.calls.append("withdrawFriendInvitation")
        if let error { throw error }
    }

    func removeFriend(_ request: RemoveFriendRequest) async throws {
        observedAccountScopes.append(GroveAPIRequestScope.expectedAccountID)
        friendMutationStarted?.fulfill()
        await friendMutationGate?.wait()
        recorder?.calls.append("removeFriend")
        if let error { throw error }
    }

    func blockFriend(_ request: BlockFriendRequest) async throws {
        recorder?.calls.append("blockFriend")
        if let error { throw error }
    }

    func reportFriend(_ request: ReportFriendRequest) async throws {
        recorder?.calls.append("reportFriend")
        if let error { throw error }
    }

    func updateCareTask(_ request: CareTaskMutationRequest) async throws -> CareTask {
        careTaskCalls += 1
        if let error { throw error }
        return CareTask(
            id: request.taskID,
            plantID: UUID(),
            kind: .rotate,
            dueDate: request.rescheduledFor ?? .now,
            detail: "Rotate gently",
            isCompleted: request.outcome == .completed,
            isSittingTask: false,
            ownerName: nil
        )
    }

    func updateProfile(_ request: UpdateProfileRequest) async throws -> UserProfile {
        if let error { throw error }
        return UserProfile(
            name: request.displayName,
            username: request.username,
            initials: "TP",
            friendCount: 0,
            regionCode: request.regionCode,
            usesMetricSystem: request.usesMetricSystem,
            isPrivate: request.isPrivate
        )
    }

    func updateGardenerProgress(_ request: UpdateGardenerProgressRequest) async throws -> GardenerProgressSyncResponse {
        gardenerProgressCalls += 1
        if let error { throw error }
        return GardenerProgressSyncResponse(gardener: request.gardener, updatedAt: request.updatedAt)
    }

    static func plant(id: UUID) -> Plant {
        Plant(
            id: id,
            nickname: "Test plant",
            species: "Monstera",
            scientificName: "Monstera deliciosa",
            location: "Room",
            healthScore: 80,
            healthBand: .healthy,
            trend: .stable,
            confidence: 90,
            nextCheckIn: .now,
            symbol: "leaf.fill",
            palette: .fern,
            summary: "Healthy",
            positiveSigns: [],
            concerns: [],
            nextActions: []
        )
    }
}

private actor TestAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class SyncCallRecorder {
    var calls: [String] = []
}

@MainActor
private final class FakeMediaUploader: MediaUploading {
    let recorder: SyncCallRecorder

    init(recorder: SyncCallRecorder) {
        self.recorder = recorder
    }

    func upload(_ pending: PendingMediaUpload) async throws -> CompletedMediaUpload {
        recorder.calls.append("upload")
        return CompletedMediaUpload(mediaAssetID: pending.localMediaID, status: "ready")
    }
}

@MainActor
final class SyncEngineTests: XCTestCase {
    func testWatchQuickLogPersistsACareEventMutation() async throws {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let engine = SyncEngine(queueStore: queue, repository: FakeRemoteRepository())
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let suiteName = "watch-sync-engine-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        let service = WatchSyncService(defaults: defaults)
        service.configure(store: store, syncEngine: engine, connectivity: nil)
        let performedAt = Date.now.addingTimeInterval(-90)
        let action = WatchCareAction.logCare(
            plantID: plant.id,
            careKind: .cleanLeaves,
            at: performedAt
        )

        XCTAssertTrue(service.apply(action))

        var queued: [QueuedMutation] = []
        for _ in 0..<20 {
            queued = await queue.all()
            if !queued.isEmpty { break }
            await Task.yield()
        }
        let mutation = try XCTUnwrap(queued.first)
        guard case .createCareEvent(let request) = mutation.payload else {
            return XCTFail("A Watch quick log must enqueue createCareEvent")
        }
        XCTAssertEqual(request.clientRequestID, action.id)
        XCTAssertEqual(request.task.plantID, plant.id)
        XCTAssertEqual(request.task.kind, .cleanLeaves)
        XCTAssertEqual(request.task.performedAt.timeIntervalSince1970,
                       performedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testDurableInitialProfileHandoffCannotDuplicateItsQueuedMutation() async throws {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let request = UpdateProfileRequest(
            displayName: "Ari",
            username: "ari_grows",
            regionCode: "NZ",
            usesMetricSystem: true,
            isPrivate: true,
            clientRequestID: UUID()
        )

        let first = try await queue.enqueue(.updateProfile(request))
        let replay = try await queue.enqueue(.updateProfile(request))

        XCTAssertEqual(first.id, replay.id)
        let queued = await queue.all()
        XCTAssertEqual(queued.count, 1)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testOfflineMutationPersistsAndSyncsExactlyOnceWhenConnected() async throws {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let repository = FakeRemoteRepository()
        let engine = SyncEngine(queueStore: queue, repository: repository)
        let request = checkInRequest()

        await engine.enqueue(.createCheckIn(request), isConnected: false)

        XCTAssertEqual(engine.pendingCount, 1)
        XCTAssertEqual(engine.state, .offline)
        let queuedBeforeSync = await queue.all()
        XCTAssertEqual(queuedBeforeSync.count, 1)

        await engine.processPending(isConnected: true)

        XCTAssertEqual(repository.checkInCalls, 1)
        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertEqual(engine.state, .upToDate)
        let queuedAfterSync = await queue.all()
        XCTAssertTrue(queuedAfterSync.isEmpty)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testGardenerProgressQueuesOfflineAndReachesTheAccount() async throws {
        let fileURL = temporaryQueueURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let repository = FakeRemoteRepository()
        let engine = SyncEngine(queueStore: MutationQueueStore(fileURL: fileURL), repository: repository)
        await engine.activate(accountID: UUID().uuidString.lowercased())
        var gardener = GardenerProgress.new
        gardener.currentStreak = 9
        gardener.longestStreak = 14
        gardener.lastTendDay = .now
        let request = UpdateGardenerProgressRequest(
            gardener: gardener,
            updatedAt: .now,
            clientRequestID: UUID()
        )

        let enqueued = await engine.enqueue(.updateGardenerProgress(request), isConnected: false)
        XCTAssertTrue(enqueued)
        XCTAssertEqual(engine.pendingCount, 1)

        await engine.processPending(isConnected: true)

        XCTAssertEqual(repository.gardenerProgressCalls, 1)
        XCTAssertEqual(engine.pendingCount, 0)
    }

    /// A conflict is the server saying it already has this change — every
    /// queued request carries a client id, so the duplicate is the receipt.
    /// Parking it behind a "retry" button asked the user to press send on
    /// something that had already arrived.
    func testConflictLetsTheChangeGoRatherThanParkingItForTheUser() async {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let repository = FakeRemoteRepository()
        repository.error = .conflict
        let engine = SyncEngine(queueStore: queue, repository: repository)

        await engine.enqueue(.createCheckIn(checkInRequest()), isConnected: true)

        XCTAssertEqual(repository.checkInCalls, 1)
        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertEqual(engine.state, .upToDate)
        let remaining = await queue.all()
        XCTAssertTrue(remaining.isEmpty)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// An expired bearer is not the change's fault. It must not burn an attempt,
    /// must not be dropped, and must go out by itself once a token comes back —
    /// which is what returning to the app does.
    func testAnExpiredSessionHoldsTheChangeAndSendsItOnceSignedInAgain() async {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let repository = FakeRemoteRepository()
        repository.error = .unauthorised
        let engine = SyncEngine(queueStore: queue, repository: repository)

        await engine.enqueue(.createCheckIn(checkInRequest()), isConnected: true)

        XCTAssertEqual(engine.pendingCount, 1)
        let held = await queue.all().first
        XCTAssertEqual(held?.attemptCount, 0)
        XCTAssertEqual(held?.state, .pending)

        repository.error = nil
        await engine.resume(isConnected: true)

        XCTAssertEqual(repository.checkInCalls, 2)
        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertEqual(engine.state, .upToDate)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// A server having a bad minute is Grove's problem, not the gardener's. The
    /// change stays queued with a later time to try, and no screen mentions it.
    func testAServerFailureBacksOffInsteadOfAskingForHelp() async {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let repository = FakeRemoteRepository()
        repository.error = .server(status: 502, message: nil)
        let engine = SyncEngine(queueStore: queue, repository: repository)

        await engine.enqueue(.createCheckIn(checkInRequest()), isConnected: true)

        XCTAssertEqual(engine.pendingCount, 1)
        let queued = await queue.all().first
        XCTAssertEqual(queued?.state, .retrying)
        XCTAssertEqual(queued?.attemptCount, 1)
        XCTAssertGreaterThan(queued?.nextAttemptAt ?? .distantPast, .now)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// A week of failure outlives any outage worth waiting through. The queued
    /// delivery is let go so it cannot wedge everything behind it forever; the
    /// check-in itself was written to the device long before it was queued.
    func testAChangeThatHasFailedForAWeekIsLetGo() async throws {
        let fileURL = temporaryQueueURL()
        try seed(
            [queuedMutation(createdAt: Date.now.addingTimeInterval(-8 * 24 * 60 * 60))],
            at: fileURL
        )
        let queue = MutationQueueStore(fileURL: fileURL)
        let repository = FakeRemoteRepository()
        repository.error = .server(status: 500, message: nil)
        let engine = SyncEngine(queueStore: queue, repository: repository)

        await engine.processPending(isConnected: true)

        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertEqual(engine.state, .upToDate)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// Anyone upgrading with a change parked behind the old "hasn't reached the
    /// server" banner gets it sent for them, without ever being told it was
    /// stuck in the first place.
    func testAChangeParkedByAnOlderBuildIsSentOnFirstLaunch() async throws {
        let fileURL = temporaryQueueURL()
        try seed([queuedMutation(state: .needsAttention, attemptCount: 4)], at: fileURL)
        let queue = MutationQueueStore(fileURL: fileURL)
        let repository = FakeRemoteRepository()
        let engine = SyncEngine(queueStore: queue, repository: repository)

        await engine.processPending(isConnected: true)

        XCTAssertEqual(repository.checkInCalls, 1)
        XCTAssertEqual(engine.pendingCount, 0)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// One change the server keeps refusing must not hold a week of care tasks
    /// hostage behind it. Past the attempt ceiling the queue steps over it and
    /// comes back to it later.
    func testAStuckChangeDoesNotBlockTheOnesBehindIt() async throws {
        let fileURL = temporaryQueueURL()
        let stuck = queuedMutation(
            createdAt: Date.now.addingTimeInterval(-600),
            state: .retrying,
            attemptCount: 4
        )
        let careTask = QueuedMutation(
            id: UUID(),
            createdAt: .now,
            payload: .updateCareTask(
                CareTaskMutationRequest(
                    taskID: UUID(),
                    outcome: .completed,
                    occurredAt: .now,
                    rescheduledFor: nil,
                    reason: nil,
                    clientRequestID: UUID()
                )
            ),
            attemptCount: 0,
            nextAttemptAt: .now,
            state: .pending,
            lastError: nil
        )
        try seed([stuck, careTask], at: fileURL)
        let queue = MutationQueueStore(fileURL: fileURL)
        let repository = FakeRemoteRepository()
        repository.checkInError = .server(status: 500, message: nil)
        let engine = SyncEngine(queueStore: queue, repository: repository)

        await engine.processPending(isConnected: true)

        XCTAssertEqual(repository.careTaskCalls, 1, "The care task behind a stuck check-in must still go out")
        XCTAssertEqual(engine.pendingCount, 1)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testLocalOnlyModeDoesNotCreateRemoteQueue() async {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let engine = SyncEngine(queueStore: queue)

        await engine.enqueue(.createCheckIn(checkInRequest()), isConnected: false)

        XCTAssertEqual(engine.state, .localOnly)
        XCTAssertEqual(engine.pendingCount, 0)
        let queued = await queue.all()
        XCTAssertTrue(queued.isEmpty)
    }

    func testMediaUploadIsDeliveredBeforeDependentCheckIn() async {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let recorder = SyncCallRecorder()
        let repository = FakeRemoteRepository()
        repository.recorder = recorder
        let uploader = FakeMediaUploader(recorder: recorder)
        let engine = SyncEngine(queueStore: queue, repository: repository, mediaUploader: uploader)
        let mediaID = UUID()
        let pending = PendingMediaUpload(
            localMediaID: mediaID,
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused.jpg"),
            purpose: .observation,
            mimeType: "image/jpeg",
            pixelWidth: 900,
            pixelHeight: 1200
        )

        await engine.enqueue(.uploadMedia(pending), isConnected: false)
        await engine.enqueue(.createCheckIn(checkInRequest(mediaDraftID: mediaID)), isConnected: false)
        await engine.processPending(isConnected: true)

        XCTAssertEqual(recorder.calls, ["upload", "checkIn"])
        XCTAssertEqual(engine.pendingCount, 0)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testCareTaskMutationQueuesOfflineAndSyncsOnReconnect() async {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let repository = FakeRemoteRepository()
        let engine = SyncEngine(queueStore: queue, repository: repository)
        let request = CareTaskMutationRequest(
            taskID: UUID(),
            outcome: .snoozed,
            occurredAt: .now,
            rescheduledFor: Date.now.addingTimeInterval(86_400),
            reason: "Soil is still moist",
            clientRequestID: UUID()
        )

        await engine.enqueue(.updateCareTask(request), isConnected: false)
        XCTAssertEqual(engine.pendingCount, 1)

        await engine.processPending(isConnected: true)

        XCTAssertEqual(repository.careTaskCalls, 1)
        XCTAssertEqual(engine.pendingCount, 0)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// The answer has to survive being given offline. Someone accepting a
    /// request on the tube and closing the app must still have that friendship
    /// reach the other gardener once there is signal.
    func testFriendInvitationAnswerQueuesOfflineAndSyncsOnReconnect() async {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let recorder = SyncCallRecorder()
        let repository = FakeRemoteRepository()
        repository.recorder = recorder
        let engine = SyncEngine(queueStore: queue, repository: repository)
        let request = RespondToFriendInvitationRequest(
            invitationID: UUID(),
            accept: true,
            clientRequestID: UUID()
        )

        await engine.enqueue(.respondToFriendInvitation(request), isConnected: false)
        XCTAssertEqual(engine.pendingCount, 1)

        await engine.processPending(isConnected: true)

        XCTAssertEqual(recorder.calls, ["acceptFriendInvitation"])
        XCTAssertEqual(engine.pendingCount, 0)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testOnlineFriendDecisionsWaitForTheServerWithoutEnteringTheQueue() async throws {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let recorder = SyncCallRecorder()
        let repository = FakeRemoteRepository()
        repository.recorder = recorder
        let engine = SyncEngine(queueStore: queue, repository: repository)
        let invitationID = UUID()

        try await engine.respondToFriendInvitation(
            RespondToFriendInvitationRequest(
                invitationID: invitationID,
                accept: true,
                clientRequestID: UUID()
            )
        )
        try await engine.withdrawFriendInvitation(
            WithdrawFriendInvitationRequest(
                invitationID: invitationID,
                clientRequestID: UUID()
            )
        )
        try await engine.removeFriend(
            RemoveFriendRequest(friendAccountID: UUID().uuidString, clientRequestID: UUID())
        )
        try await engine.blockFriend(
            BlockFriendRequest(friendAccountID: UUID().uuidString, clientRequestID: UUID())
        )
        try await engine.reportFriend(
            ReportFriendRequest(
                friendAccountID: UUID().uuidString,
                reason: .spam,
                details: "Repeated requests",
                clientRequestID: UUID()
            )
        )

        XCTAssertEqual(
            recorder.calls,
            ["acceptFriendInvitation", "withdrawFriendInvitation", "removeFriend", "blockFriend", "reportFriend"]
        )
        XCTAssertEqual(engine.pendingCount, 0)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testFriendMutationIsBoundToTheAccountThatStartedIt() async throws {
        let repository = FakeRemoteRepository()
        let engine = SyncEngine(queueStore: MutationQueueStore(fileURL: temporaryQueueURL()), repository: repository)
        let accountID = UUID().uuidString.lowercased()
        await engine.activate(accountID: accountID)

        try await engine.removeFriend(
            RemoveFriendRequest(friendAccountID: UUID().uuidString, clientRequestID: UUID())
        )

        XCTAssertEqual(repository.observedAccountScopes.count, 1)
        XCTAssertEqual(repository.observedAccountScopes[0], accountID)
    }

    func testOldFriendViewCannotApplySuccessAfterAccountSwitch() async throws {
        let repository = FakeRemoteRepository()
        let started = expectation(description: "friend removal started")
        let gate = TestAsyncGate()
        repository.friendMutationStarted = started
        repository.friendMutationGate = gate
        let engine = SyncEngine(queueStore: MutationQueueStore(fileURL: temporaryQueueURL()), repository: repository)
        await engine.activate(accountID: UUID().uuidString.lowercased())

        let oldViewAction = Task {
            try await engine.removeFriend(
                RemoveFriendRequest(friendAccountID: UUID().uuidString, clientRequestID: UUID())
            )
        }
        await fulfillment(of: [started], timeout: 1)
        await engine.activate(accountID: UUID().uuidString.lowercased())
        await gate.open()

        do {
            try await oldViewAction.value
            XCTFail("an old account's view must not receive a success it could apply to the new store")
        } catch is CancellationError {
            // Expected: the server result belongs to the account that started it.
        }
    }

    func testBootstrapFromPreviousAccountCannotOverwriteNewAccount() async throws {
        let repository = FakeRemoteRepository()
        repository.bootstrapResponse = GroveBootstrapResponse(
            profile: UserProfile(name: "Previous account", username: "previous", initials: "PA", friendCount: 1),
            plants: [],
            tasks: [],
            activity: [],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now
        )
        let started = expectation(description: "previous account bootstrap started")
        let gate = TestAsyncGate()
        repository.bootstrapStarted = started
        repository.bootstrapGate = gate
        let engine = SyncEngine(queueStore: MutationQueueStore(fileURL: temporaryQueueURL()), repository: repository)
        let store = GroveStore(persistenceEnabled: false)
        let first = UserSession(accountID: UUID().uuidString.lowercased(), mode: .apple, displayName: "First")
        let second = UserSession(accountID: UUID().uuidString.lowercased(), mode: .apple, displayName: "Second")
        store.activate(session: first)
        await engine.activate(accountID: first.accountID)

        let staleSync = Task { await engine.synchronize(store: store, isConnected: true) }
        await fulfillment(of: [started], timeout: 1)
        store.activate(session: second)
        await engine.activate(accountID: second.accountID)
        await gate.open()
        await staleSync.value

        XCTAssertEqual(store.activeAccountID, second.accountID)
        XCTAssertNotEqual(store.profile.username, "previous")
        XCTAssertEqual(repository.observedAccountScopes.first!, first.accountID)
    }

    func testInteractiveSittingAssignmentWaitsForTheServerWithoutEnteringTheQueue() async throws {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let recorder = SyncCallRecorder()
        let repository = FakeRemoteRepository()
        repository.recorder = recorder
        let engine = SyncEngine(queueStore: queue, repository: repository)
        let requestID = UUID()
        let request = CreateSittingRequest(
            sitterAccountID: UUID().uuidString,
            startDate: .now,
            endDate: Date.now.addingTimeInterval(86_400),
            plantIDs: [UUID()],
            canCheckIn: true,
            clientRequestID: requestID,
            activityEventID: requestID
        )

        let assignment = try await engine.createSittingAssignment(request)

        XCTAssertEqual(assignment.id, requestID)
        XCTAssertEqual(recorder.calls, ["createSittingAssignment"])
        XCTAssertEqual(engine.pendingCount, 0)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testManagedQueuesAreIsolatedWhenAccountChanges() async {
        let firstAccount = "sync-account-\(UUID().uuidString)"
        let secondAccount = "sync-account-\(UUID().uuidString)"
        let repository = FakeRemoteRepository()
        let engine = SyncEngine(repository: repository)
        defer {
            try? FileManager.default.removeItem(at: AccountStorage.mediaRootURL(for: firstAccount))
            try? FileManager.default.removeItem(at: AccountStorage.mediaRootURL(for: secondAccount))
        }

        await engine.activate(accountID: firstAccount)
        await engine.enqueue(.createCheckIn(checkInRequest()), isConnected: false)
        XCTAssertEqual(engine.pendingCount, 1)

        await engine.activate(accountID: secondAccount)
        XCTAssertEqual(engine.pendingCount, 0)

        await engine.activate(accountID: firstAccount)
        XCTAssertEqual(engine.pendingCount, 1)
        await engine.discardQueuedChanges()
    }

    func testSynchronizeFlushesPendingWritesBeforeApplyingBootstrap() async throws {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let recorder = SyncCallRecorder()
        let repository = FakeRemoteRepository()
        repository.recorder = recorder
        let remotePlant = FakeRemoteRepository.plant(id: UUID())
        repository.bootstrapResponse = GroveBootstrapResponse(
            profile: UserProfile(name: "Remote", username: "remote", initials: "R", friendCount: 0),
            plants: [remotePlant],
            tasks: [],
            activity: [],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now
        )
        let engine = SyncEngine(queueStore: queue, repository: repository)
        let store = GroveStore(persistenceEnabled: false)
        // A grove the server has already vouched for, so this reads as an
        // ordinary sync rather than a first one with unsent plants in it. What
        // is under test is the ordering of the flush against the bootstrap.
        store.replace(with: bootstrap(with: store.plants))

        await engine.enqueue(.createCheckIn(checkInRequest()), isConnected: false)
        await engine.synchronize(store: store, isConnected: true)

        XCTAssertEqual(recorder.calls, ["checkIn", "bootstrap"])
        XCTAssertEqual(store.plants, [remotePlant])
        XCTAssertEqual(store.profile.username, "remote")
        XCTAssertEqual(engine.state, .upToDate)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testSynchronizeRefusesAServerThatCannotStoreAccounts() async throws {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let repository = FakeRemoteRepository()
        let remotePlant = FakeRemoteRepository.plant(id: UUID())
        repository.bootstrapResponse = GroveBootstrapResponse(
            profile: UserProfile(name: "Remote", username: "remote", initials: "R", friendCount: 0),
            plants: [remotePlant],
            tasks: [],
            activity: [],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now,
            storage: "memory"
        )
        let engine = SyncEngine(queueStore: queue, repository: repository)
        let store = GroveStore(persistenceEnabled: false)
        let localPlants = store.plants

        await engine.synchronize(store: store, isConnected: true)

        // The development server keeps accounts in process memory. Its snapshot
        // is applied wholesale, so trusting it is one restart away from wiping
        // the device — even when the snapshot currently looks populated.
        XCTAssertEqual(store.plants, localPlants)
        guard case .needsAttention = engine.state else {
            return XCTFail("A non-durable server must surface as needing attention")
        }
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testSynchronizeAppliesASnapshotFromADurableServer() async throws {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let repository = FakeRemoteRepository()
        let remotePlant = FakeRemoteRepository.plant(id: UUID())
        repository.bootstrapResponse = GroveBootstrapResponse(
            profile: UserProfile(name: "Remote", username: "remote", initials: "R", friendCount: 0),
            plants: [remotePlant],
            tasks: [],
            activity: [],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now,
            storage: "postgres"
        )
        let engine = SyncEngine(queueStore: queue, repository: repository)
        let store = GroveStore(persistenceEnabled: false)
        store.replace(with: bootstrap(with: store.plants))

        await engine.synchronize(store: store, isConnected: true)

        XCTAssertEqual(store.plants, [remotePlant])
        XCTAssertEqual(engine.state, .upToDate)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// The failure mode behind "it should just always work": a plant whose
    /// upload never landed used to be erased from the phone by the very next
    /// successful bootstrap, because the snapshot was assigned wholesale. The
    /// server has never heard of this plant, so the server does not get to
    /// delete it.
    func testAPlantTheServerNeverAcknowledgedSurvivesABootstrap() async throws {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let repository = FakeRemoteRepository()
        let remotePlant = FakeRemoteRepository.plant(id: UUID())
        repository.bootstrapResponse = GroveBootstrapResponse(
            profile: UserProfile(name: "Remote", username: "remote", initials: "R", friendCount: 0),
            plants: [remotePlant],
            tasks: [],
            activity: [],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now
        )
        let engine = SyncEngine(queueStore: queue, repository: repository)
        let store = GroveStore(persistenceEnabled: false)
        let strandedPlant = store.plants[0]

        await engine.synchronize(store: store, isConnected: true)

        XCTAssertTrue(
            store.plants.contains(where: { $0.id == strandedPlant.id }),
            "A plant the server has never confirmed must not be deleted by a snapshot that omits it"
        )
        XCTAssertTrue(store.plants.contains(where: { $0.id == remotePlant.id }))
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// The other half of the same rule: once the server *has* vouched for a
    /// plant, a later snapshot without it is a deletion from another device and
    /// must stick. Otherwise deleting a plant on the iPad would never take.
    func testAPlantTheServerOnceSentIsDeletedWhenItStopsSendingIt() async throws {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let repository = FakeRemoteRepository()
        let first = FakeRemoteRepository.plant(id: UUID())
        let second = FakeRemoteRepository.plant(id: UUID())
        repository.bootstrapResponse = bootstrap(with: [first, second])
        let engine = SyncEngine(queueStore: queue, repository: repository)
        let store = GroveStore(persistenceEnabled: false)

        await engine.synchronize(store: store, isConnected: true)
        XCTAssertTrue(store.plants.contains(where: { $0.id == second.id }))

        repository.bootstrapResponse = bootstrap(with: [first])
        await engine.synchronize(store: store, isConnected: true)

        XCTAssertFalse(
            store.plants.contains(where: { $0.id == second.id }),
            "A plant the server has confirmed and then dropped was deleted elsewhere"
        )
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func bootstrap(with plants: [Plant]) -> GroveBootstrapResponse {
        GroveBootstrapResponse(
            profile: UserProfile(name: "Remote", username: "remote", initials: "R", friendCount: 0),
            plants: plants,
            tasks: [],
            activity: [],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now
        )
    }

    func testSynchronizeRefusesAnEmptyRemoteGroveInsteadOfWipingLocalPlants() async throws {
        let fileURL = temporaryQueueURL()
        let queue = MutationQueueStore(fileURL: fileURL)
        let repository = FakeRemoteRepository()
        repository.bootstrapResponse = GroveBootstrapResponse(
            profile: UserProfile(name: "Remote", username: "remote", initials: "R", friendCount: 0),
            plants: [],
            tasks: [],
            activity: [],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now
        )
        let engine = SyncEngine(queueStore: queue, repository: repository)
        let store = GroveStore(persistenceEnabled: false)
        let localPlants = store.plants
        XCTAssertFalse(localPlants.isEmpty)

        await engine.synchronize(store: store, isConnected: true)

        // The sync service keeps accounts in process memory, so a restart hands
        // back an empty Grove. That must never delete the user's plants.
        XCTAssertEqual(store.plants, localPlants)
        XCTAssertNotEqual(store.profile.username, "remote")
        guard case .needsAttention = engine.state else {
            return XCTFail("An empty remote Grove must surface as needing attention, not as up to date")
        }
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testIncomingRequestAppearsWhileUnrelatedCareChangeIsWaiting() async throws {
        let fileURL = temporaryQueueURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        var queued = queuedMutation()
        queued.nextAttemptAt = .now.addingTimeInterval(3600)
        try seed([queued], at: fileURL)
        let queue = MutationQueueStore(fileURL: fileURL)
        let repository = FakeRemoteRepository()
        let invitation = FriendInvitation(id: UUID(), accountID: "sender", name: "Sender",
            username: "sender", initials: "S", direction: .incoming, createdAt: .now)
        repository.bootstrapResponse = GroveBootstrapResponse(
            profile: UserProfile(name: "Remote", username: "remote", initials: "R", friendCount: 0),
            plants: [], tasks: [], activity: [], assignments: [], observations: [],
            friends: [], friendInvitations: [invitation], serverTime: .now)
        let engine = SyncEngine(queueStore: queue, repository: repository)
        let store = GroveStore(persistenceEnabled: false)
        let localPlants = store.plants
        let localProfile = store.profile.username

        await engine.synchronize(store: store, isConnected: true)

        XCTAssertEqual(store.friendInvitations.map(\.id), [invitation.id])
        XCTAssertEqual(store.plants, localPlants)
        XCTAssertEqual(store.profile.username, localProfile)
        XCTAssertEqual(engine.pendingCount, 1)
    }

    func testPendingOfflineFriendAnswerIsNotUndoneByRefresh() async throws {
        let fileURL = temporaryQueueURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let invitation = FriendInvitation(id: UUID(), accountID: "sender", name: "Sender",
            username: "sender", initials: "S", direction: .incoming, createdAt: .now)
        var queued = queuedMutation()
        queued.payload = .respondToFriendInvitation(RespondToFriendInvitationRequest(
            invitationID: invitation.id, accept: true, clientRequestID: UUID()))
        queued.nextAttemptAt = .now.addingTimeInterval(3600)
        try seed([queued], at: fileURL)
        let queue = MutationQueueStore(fileURL: fileURL)
        let repository = FakeRemoteRepository()
        repository.bootstrapResponse = GroveBootstrapResponse(
            profile: UserProfile(name: "Remote", username: "remote", initials: "R", friendCount: 0),
            plants: [], tasks: [], activity: [], assignments: [], observations: [],
            friends: [], friendInvitations: [invitation], serverTime: .now)
        let engine = SyncEngine(queueStore: queue, repository: repository)
        let store = GroveStore(persistenceEnabled: false)
        store.friendInvitations = [invitation]
        store.acceptFriendInvitation(id: invitation.id)
        let localFriends = store.friends.map(\.id)

        await engine.synchronize(store: store, isConnected: true)

        XCTAssertTrue(store.friendInvitations.isEmpty)
        XCTAssertEqual(store.friends.map(\.id), localFriends)
        XCTAssertEqual(engine.pendingCount, 1)
    }

    /// Writes a queue file by hand so a test can start from a state that would
    /// otherwise take a week of real failures to reach.
    private func seed(_ mutations: [QueuedMutation], at fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(mutations).write(to: fileURL)
    }

    private func queuedMutation(
        createdAt: Date = .now,
        state: QueuedMutationState = .pending,
        attemptCount: Int = 0
    ) -> QueuedMutation {
        QueuedMutation(
            id: UUID(),
            createdAt: createdAt,
            payload: .createCheckIn(checkInRequest()),
            attemptCount: attemptCount,
            nextAttemptAt: .now,
            state: state,
            lastError: nil
        )
    }

    private func checkInRequest(mediaDraftID: UUID? = nil) -> CreateCheckInRequest {
        CreateCheckInRequest(
            plantID: UUID(),
            score: 82,
            band: .healthy,
            note: "Stable",
            mediaDraftID: mediaDraftID,
            clientRequestID: UUID()
        )
    }

    func testCheckInRequestRoundTripsAssessmentEvidence() throws {
        let referenceID = UUID()
        let measuredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let readings = PlantHealthIndicatorKind.allCases.map { kind in
            PlantHealthIndicatorReading(
                kind: kind,
                value: kind == .moisture ? "comfortable" : "unavailable",
                score: kind == .light ? 82 : nil,
                status: kind == .moisture ? "Damp" : "Not read",
                detail: "Evidence detail",
                evidenceLevel: kind == .moisture ? .observed : .unavailable,
                source: kind == .moisture ? .ownerReport : .none,
                confidence: kind == .moisture ? 100 : nil,
                evidence: kind == .moisture ? ["Owner felt the soil"] : [],
                measuredAt: measuredAt,
                validUntil: nil,
                algorithmVersion: "test.v1"
            )
        }
        var request = checkInRequest()
        request.isEstimated = false
        request.appliesToPlant = false
        request.confidence = 47
        request.actionability = .provisional
        request.assessmentAvailable = true
        request.analysisVersion = "gateway.v3"
        request.providerName = "Test provider"
        request.limitations = ["Blurred leaf"]
        request.referenceObservationID = referenceID
        request.indicatorReadings = readings

        let decoded = try JSONDecoder().decode(
            CreateCheckInRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded.appliesToPlant, false)
        XCTAssertEqual(decoded.confidence, 47)
        XCTAssertEqual(decoded.actionability, .provisional)
        XCTAssertEqual(decoded.assessmentAvailable, true)
        XCTAssertEqual(decoded.analysisVersion, "gateway.v3")
        XCTAssertEqual(decoded.providerName, "Test provider")
        XCTAssertEqual(decoded.limitations, ["Blurred leaf"])
        XCTAssertEqual(decoded.referenceObservationID, referenceID)
        XCTAssertEqual(decoded.indicatorReadings, readings)
    }

    private func temporaryQueueURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveSyncTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("mutations.json")
    }
}
