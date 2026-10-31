import XCTest
@testable import Grove

/// A client the test drives: it records what it was sent and returns whatever
/// the test wants, including a failure.
@MainActor
private final class StubBotanistClient: BotanistClient {
    /// Shaped like a real provider reply, not like the tidy sentence a test
    /// author would write. The old plain-prose fixture is why raw markdown
    /// reached production: nothing in the suite ever carried a marker.
    var reply = """
    **Water less and watch the lower leaves.**

    Soggy roots can't breathe, which shows up as drooping long before rot does.

    - Check the top 5cm of soil first.
    - Skip a week if it's damp.
    """
    var error: Error?
    var outcomeError: Error?
    var adviceID: UUID? = UUID()
    var sources: [BotanistSource] = []
    var receivedConversations: [[BotanistMessage]] = []
    var receivedContexts: [String?] = []
    var receivedPlantIDs: [UUID?] = []
    var receivedThreadIDs: [UUID] = []
    var receivedPhotos: [[BotanistPhotoAttachment]] = []
    var receivedSafetyOnly: [Bool] = []
    var allowsSafetyOnly = false
    /// The meter the gateway reports back. Nil is a deterministic safety answer
    /// or a gateway older than contract 8: both mean "do not touch the count".
    var quota: BotanistAskQuota?
    var recordedOutcomes: [(UUID, BotanistOutcome)] = []
    var responseDelay: Duration?
    /// Runs inside the request, while the session still believes an answer is in
    /// flight — the only moment the thinking state can be observed.
    var whileAnswering: (() -> Void)?

    func ask(
        conversation: [BotanistMessage],
        plantContext: String?,
        plantID: UUID?,
        threadID: UUID,
        photoAttachments: [BotanistPhotoAttachment],
        safetyOnly: Bool
    ) async throws -> BotanistAnswer {
        receivedConversations.append(conversation)
        receivedContexts.append(plantContext)
        receivedPlantIDs.append(plantID)
        receivedThreadIDs.append(threadID)
        receivedPhotos.append(photoAttachments)
        receivedSafetyOnly.append(safetyOnly)
        if safetyOnly && !allowsSafetyOnly {
            throw BotanistClientPolicyError.premiumRequired
        }
        whileAnswering?()
        if let responseDelay { try await Task.sleep(for: responseDelay) }
        if let error { throw error }
        return BotanistAnswer(
            reply: reply,
            adviceID: adviceID,
            disposition: "answer",
            confidence: "medium",
            followUpAt: Date(timeIntervalSince1970: 2_000_000_000),
            sources: sources,
            verification: "approve",
            provider: "google_gemini",
            model: "gemini-3.7-flash",
            usedPhotoMessageIDs: photoAttachments.map(\.messageID),
            visualEvidence: photoAttachments.isEmpty ? nil : "bounded visual evidence",
            quota: quota
        )
    }

    func recordOutcome(adviceID: UUID, outcome: BotanistOutcome) async throws {
        if let outcomeError { throw outcomeError }
        recordedOutcomes.append((adviceID, outcome))
    }
}

@MainActor
final class BotanistAskTests: XCTestCase {

    private func makeSession(
        client: StubBotanistClient = StubBotanistClient(),
        accountID: String = "acct-ask"
    ) throws -> (AskSession, StubBotanistClient, UserDefaults, String) {
        let suite = "AskTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suite))
        let session = AskSession(client: client, storage: storage)
        session.activate(accountID: accountID)
        return (session, client, storage, suite)
    }

    // MARK: - Asking

    func testAnsweredQuestionAppendsBothTurns() async throws {
        let (ask, client, storage, suite) = try makeSession()
        defer { storage.removePersistentDomain(forName: suite) }

        let result = await ask.ask("Why is it drooping?", context: "Nickname: Mo", hasPremium: false)
        XCTAssertEqual(result.outcome, .answered)

        let thread = try XCTUnwrap(ask.thread(id: result.threadID))
        XCTAssertEqual(thread.messages.count, 2)
        XCTAssertEqual(thread.messages[0].role, .user)
        XCTAssertEqual(thread.messages[0].text, "Why is it drooping?")
        XCTAssertEqual(thread.messages[1].role, .botanist)
        XCTAssertEqual(thread.messages[1].text, client.reply)
        XCTAssertEqual(thread.messages[1].adviceID, client.adviceID)
        XCTAssertEqual(thread.messages[1].confidence, "medium")
        XCTAssertEqual(thread.messages[1].verification, "approve")
        XCTAssertEqual(client.receivedContexts, ["Nickname: Mo"])
        XCTAssertEqual(client.receivedThreadIDs, [result.threadID])
    }

    func testPhotoQuestionSavesProtectedAttachmentAndSendsItsBytes() async throws {
        let (ask, client, storage, suite) = try makeSession(accountID: "acct-photo-\(UUID().uuidString)")
        defer {
            ask.deleteAllLocalData()
            storage.removePersistentDomain(forName: suite)
        }
        let photo = Data([0xff, 0xd8, 0xff, 0xd9])

        let result = await ask.ask(
            "What are these spots?",
            context: "Nickname: Mo",
            photoData: photo,
            hasPremium: false
        )

        XCTAssertEqual(result.outcome, .answered)
        XCTAssertEqual(client.receivedPhotos.count, 1)
        XCTAssertEqual(client.receivedPhotos[0].map(\.data), [photo])
        let url = try XCTUnwrap(ask.thread(id: result.threadID)?.messages.first?.photoURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), photo)
    }

    func testPhotoQuestionRetryResendsTheSavedAttachment() async throws {
        let client = StubBotanistClient()
        client.error = APIError.timedOut
        let (ask, _, storage, suite) = try makeSession(
            client: client,
            accountID: "acct-photo-retry-\(UUID().uuidString)"
        )
        defer {
            ask.deleteAllLocalData()
            storage.removePersistentDomain(forName: suite)
        }
        let photo = Data([0xff, 0xd8, 0xff, 0xd9])

        let first = await ask.ask(
            "What are these spots?",
            context: nil,
            photoData: photo,
            hasPremium: false
        )
        client.error = nil
        _ = await ask.ask(
            "What are these spots?",
            in: first.threadID,
            context: nil,
            hasPremium: false
        )

        XCTAssertEqual(client.receivedPhotos.count, 2)
        XCTAssertEqual(client.receivedPhotos[1].map(\.data), [photo])
        XCTAssertEqual(ask.thread(id: first.threadID)?.messages.filter { $0.role == .user }.count, 1)
    }

    func testRetryRejectsAChangedPhotoInsteadOfReusingTheIdempotencyKey() async throws {
        let client = StubBotanistClient()
        client.error = APIError.timedOut
        let (ask, _, storage, suite) = try makeSession(
            client: client,
            accountID: "acct-photo-retry-swap-\(UUID().uuidString)"
        )
        defer {
            ask.deleteAllLocalData()
            storage.removePersistentDomain(forName: suite)
        }
        let original = Data([0xff, 0xd8, 0xff, 0xd9])
        let replacement = Data([0xff, 0xd8, 0xff, 0xda])
        let first = await ask.ask(
            "What are these spots?",
            context: nil,
            photoData: original,
            hasPremium: false
        )
        client.error = nil

        let retry = await ask.ask(
            "What are these spots?",
            in: first.threadID,
            context: nil,
            photoData: replacement,
            hasPremium: false
        )

        XCTAssertEqual(
            retry.outcome,
            .failed(message: "A retry must use the original photo. Ask a new question to use different evidence.")
        )
        XCTAssertEqual(client.receivedConversations.count, 1)
        XCTAssertEqual(ask.thread(id: first.threadID)?.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(ask.remainingFreeAsks(hasPremium: false), AskSession.freeAsksPerDay)
    }

    func testTextOnlyRetryRejectsAddingPhotoEvidence() async throws {
        let client = StubBotanistClient()
        client.error = APIError.timedOut
        let (ask, _, storage, suite) = try makeSession(
            client: client,
            accountID: "acct-text-retry-photo-\(UUID().uuidString)"
        )
        defer {
            ask.deleteAllLocalData()
            storage.removePersistentDomain(forName: suite)
        }
        let first = await ask.ask("Why is it drooping?", context: nil, hasPremium: false)
        client.error = nil

        let retry = await ask.ask(
            "Why is it drooping?",
            in: first.threadID,
            context: nil,
            photoData: Data([0xff, 0xd8, 0xff, 0xd9]),
            hasPremium: false
        )

        XCTAssertEqual(
            retry.outcome,
            .failed(message: "A retry can't add new evidence. Ask a new question to include that photo.")
        )
        XCTAssertEqual(client.receivedConversations.count, 1)
        XCTAssertEqual(ask.thread(id: first.threadID)?.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(ask.remainingFreeAsks(hasPremium: false), AskSession.freeAsksPerDay)
    }

    func testPhotoThreadAutomaticallyReusesEarlierPhotoForFollowUp() async throws {
        let (ask, client, storage, suite) = try makeSession(
            accountID: "acct-photo-follow-up-\(UUID().uuidString)"
        )
        defer {
            ask.deleteAllLocalData()
            storage.removePersistentDomain(forName: suite)
        }
        let photo = Data([0xff, 0xd8, 0xff, 0xd9])
        let first = await ask.ask(
            "What are these spots?",
            context: nil,
            photoData: photo,
            hasPremium: false
        )

        XCTAssertEqual(ask.reusablePhotoCount(in: first.threadID), 1)
        _ = await ask.ask(
            "Do they look worse now?",
            in: first.threadID,
            context: nil,
            hasPremium: false
        )

        XCTAssertEqual(client.receivedPhotos.count, 2)
        XCTAssertEqual(client.receivedPhotos[1].map(\.data), [photo])
        XCTAssertEqual(
            client.receivedPhotos[1].first?.messageID,
            ask.thread(id: first.threadID)?.messages.first?.id
        )
        XCTAssertEqual(
            ask.thread(id: first.threadID)?.messages.last(where: { $0.role == .user })?.visualEvidence,
            "bounded visual evidence"
        )
    }

    func testMissingEarlierPhotoNeverSilentlyDegradesAFollowUpToTextOnly() async throws {
        let (ask, client, storage, suite) = try makeSession(
            accountID: "acct-photo-missing-\(UUID().uuidString)"
        )
        defer {
            ask.deleteAllLocalData()
            storage.removePersistentDomain(forName: suite)
        }
        let first = await ask.ask(
            "What are these spots?",
            context: nil,
            photoData: Data([0xff, 0xd8, 0xff, 0xd9]),
            hasPremium: false
        )
        let photoURL = try XCTUnwrap(ask.thread(id: first.threadID)?.messages.first?.photoURL)
        try FileManager.default.removeItem(at: photoURL)

        let followUp = await ask.ask(
            "What should I do next?",
            in: first.threadID,
            context: nil,
            hasPremium: false
        )

        XCTAssertEqual(
            followUp.outcome,
            .failed(
                message: "An earlier photo in this conversation is no longer available. Add it again to continue with photo-aware advice."
            )
        )
        XCTAssertEqual(client.receivedConversations.count, 1)
    }

    func testNewPhotoStillWorksWhenAnOldComparisonFileIsMissing() async throws {
        let (ask, client, storage, suite) = try makeSession(
            accountID: "acct-photo-replacement-\(UUID().uuidString)"
        )
        defer {
            ask.deleteAllLocalData()
            storage.removePersistentDomain(forName: suite)
        }
        let first = await ask.ask(
            "What are these spots?",
            context: nil,
            photoData: Data([0xff, 0xd8, 0xff, 0xd9]),
            hasPremium: false
        )
        let photoURL = try XCTUnwrap(ask.thread(id: first.threadID)?.messages.first?.photoURL)
        try FileManager.default.removeItem(at: photoURL)
        let replacement = Data([0xff, 0xd8, 0xff, 0xda])

        let followUp = await ask.ask(
            "Here is a fresh photo — what should I do next?",
            in: first.threadID,
            context: nil,
            photoData: replacement,
            hasPremium: false
        )

        XCTAssertEqual(followUp.outcome, .answered)
        XCTAssertEqual(client.receivedPhotos.last?.map(\.data), [replacement])
    }

    func testValidNewestPhotoIsReusedWhenOnlyAnOlderComparisonIsMissing() async throws {
        let (ask, client, storage, suite) = try makeSession(
            accountID: "acct-photo-newest-valid-\(UUID().uuidString)"
        )
        defer {
            ask.deleteAllLocalData()
            storage.removePersistentDomain(forName: suite)
        }
        let older = Data([0xff, 0xd8, 0xff, 0xd9])
        let newer = Data([0xff, 0xd8, 0xff, 0xda])
        let first = await ask.ask(
            "This is the older photo.",
            context: nil,
            photoData: older,
            hasPremium: true
        )
        _ = await ask.ask(
            "This is the newer photo.",
            in: first.threadID,
            context: nil,
            photoData: newer,
            hasPremium: true
        )
        let userPhotos = try XCTUnwrap(ask.thread(id: first.threadID))
            .messages
            .filter { $0.role == .user && $0.photoURL != nil }
        XCTAssertEqual(userPhotos.count, 2)
        try FileManager.default.removeItem(at: try XCTUnwrap(userPhotos.first?.photoURL))

        let followUp = await ask.ask(
            "What changed most recently?",
            in: first.threadID,
            context: nil,
            hasPremium: true
        )

        XCTAssertEqual(followUp.outcome, .answered)
        XCTAssertEqual(client.receivedPhotos.last?.map(\.data), [newer])
    }

    func testEmptyQuestionIsRejectedWithoutSpendingTheMeter() async throws {
        let (ask, client, storage, suite) = try makeSession()
        defer { storage.removePersistentDomain(forName: suite) }

        let result = await ask.ask("   ", context: nil, hasPremium: false)
        XCTAssertEqual(result.outcome, .failed(message: "Type a question first."))
        XCTAssertTrue(client.receivedConversations.isEmpty)
        XCTAssertEqual(ask.remainingFreeAsks(hasPremium: false), AskSession.freeAsksPerDay)
    }

    func testOverlongQuestionIsRejectedBeforeItCanPoisonTheThread() async throws {
        let (ask, client, storage, suite) = try makeSession()
        defer { storage.removePersistentDomain(forName: suite) }
        let threadID = ask.startDraftThread(plantID: nil).id
        let overLimit = String(repeating: "🌿", count: AskSession.maxQuestionCharacters)

        let result = await ask.ask(
            overLimit,
            in: threadID,
            context: nil,
            hasPremium: false
        )

        XCTAssertEqual(
            result.outcome,
            .failed(message: "That question is a little long. Trim it down and try again.")
        )
        XCTAssertTrue(client.receivedConversations.isEmpty)
        XCTAssertTrue(ask.thread(id: threadID)?.messages.isEmpty == true)
        XCTAssertEqual(ask.remainingFreeAsks(hasPremium: false), AskSession.freeAsksPerDay)
    }

    /// A follow-up carries the earlier turns, which is what makes it a
    /// conversation rather than a series of unrelated questions.
    func testFollowUpSendsTheEarlierTurns() async throws {
        let (ask, client, storage, suite) = try makeSession()
        defer { storage.removePersistentDomain(forName: suite) }

        let first = await ask.ask("Why is it drooping?", context: nil, hasPremium: false)
        _ = await ask.ask("And how long until it recovers?", in: first.threadID, context: nil, hasPremium: false)

        let secondRequest = try XCTUnwrap(client.receivedConversations.last)
        XCTAssertEqual(secondRequest.count, 3)
        XCTAssertEqual(secondRequest.map(\.role), [.user, .botanist, .user])
    }

    // MARK: - The free meter

    func testMeterRunsOutAndThenAsksForPremium() async throws {
        let (ask, client, storage, suite) = try makeSession()
        defer { storage.removePersistentDomain(forName: suite) }

        for index in 0..<AskSession.freeAsksPerDay {
            XCTAssertEqual(ask.remainingFreeAsks(hasPremium: false), AskSession.freeAsksPerDay - index)
            let result = await ask.ask("Question \(index)", context: nil, hasPremium: false)
            XCTAssertEqual(result.outcome, .answered)
        }

        XCTAssertEqual(ask.remainingFreeAsks(hasPremium: false), 0)
        XCTAssertFalse(ask.canAsk(hasPremium: false))
        let blocked = await ask.ask("One more?", context: nil, hasPremium: false)
        XCTAssertEqual(blocked.outcome, .needsPremium)
        XCTAssertEqual(client.receivedSafetyOnly.last, true)
        XCTAssertTrue(ask.thread(id: blocked.threadID)?.messages.isEmpty == true)
        XCTAssertNil(ask.failureMessage(in: blocked.threadID))
    }

    func testSafetyAnswerRemainsAvailableAfterFreeAllowanceIsSpent() async throws {
        let (ask, client, storage, suite) = try makeSession()
        defer { storage.removePersistentDomain(forName: suite) }

        for index in 0..<AskSession.freeAsksPerDay {
            _ = await ask.ask("Question \(index)", context: nil, hasPremium: false)
        }
        client.allowsSafetyOnly = true

        let urgent = await ask.ask("My cat ate a pothos leaf.", context: nil, hasPremium: false)

        XCTAssertEqual(urgent.outcome, .answered)
        XCTAssertEqual(client.receivedSafetyOnly.last, true)
        XCTAssertTrue(client.receivedPhotos.last?.isEmpty == true)
        XCTAssertEqual(ask.remainingFreeAsks(hasPremium: false), 0)
        XCTAssertEqual(ask.thread(id: urgent.threadID)?.messages.count, 2)
    }

    func testPremiumIsNeverMetered() async throws {
        let (ask, _, storage, suite) = try makeSession()
        defer { storage.removePersistentDomain(forName: suite) }

        for _ in 0..<(AskSession.freeAsksPerDay + 4) {
            let result = await ask.ask("Another one", context: nil, hasPremium: true)
            XCTAssertEqual(result.outcome, .answered)
        }
        XCTAssertTrue(ask.canAsk(hasPremium: true))
        XCTAssertEqual(
            ask.remainingFreeAsks(hasPremium: false),
            AskSession.freeAsksPerDay,
            "Premium questions must not consume the allowance revealed if the entitlement later expires"
        )
    }

    // MARK: - The server owns the meter

    /// The local count is a display convenience; the gateway decides. A device
    /// that thinks it has questions left must adopt the server's answer, or the
    /// same account on a second phone gets six free questions instead of three.
    func testServerQuotaOverridesTheLocalCount() async throws {
        let client = StubBotanistClient()
        client.quota = BotanistAskQuota(
            metered: true,
            premium: false,
            limit: 3,
            used: 3,
            remaining: 0,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let (ask, _, storage, suite) = try makeSession(client: client)
        defer { storage.removePersistentDomain(forName: suite) }

        let result = await ask.ask("Why is it drooping?", context: nil, hasPremium: false)

        XCTAssertEqual(result.outcome, .answered)
        XCTAssertEqual(
            ask.remainingFreeAsks(hasPremium: false),
            0,
            "One answer spent the whole allowance because the gateway said it had"
        )
        XCTAssertFalse(ask.canAsk(hasPremium: false))
        XCTAssertEqual(ask.freeAsksResetAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// The correction runs both ways. A gateway that reports questions still
    /// available must give them back, not leave a wall the server would not draw.
    func testServerQuotaRestoresQuestionsTheDeviceThoughtWereSpent() async throws {
        let client = StubBotanistClient()
        client.quota = BotanistAskQuota(
            metered: true,
            premium: false,
            limit: 3,
            used: 1,
            remaining: 2,
            resetsAt: nil
        )
        let (ask, _, storage, suite) = try makeSession(client: client)
        defer { storage.removePersistentDomain(forName: suite) }

        for _ in 0..<AskSession.freeAsksPerDay {
            _ = await ask.ask("Question", context: nil, hasPremium: false)
        }

        XCTAssertEqual(ask.remainingFreeAsks(hasPremium: false), 2)
    }

    /// An unmetered account is unmetered even if this device is holding a spent
    /// count from before the subscription started.
    func testUnmeteredServerQuotaClearsTheLocalCount() async throws {
        let client = StubBotanistClient()
        let (ask, _, storage, suite) = try makeSession(client: client)
        defer { storage.removePersistentDomain(forName: suite) }

        for _ in 0..<AskSession.freeAsksPerDay {
            _ = await ask.ask("Question", context: nil, hasPremium: false)
        }
        XCTAssertEqual(ask.remainingFreeAsks(hasPremium: false), 0)

        client.quota = BotanistAskQuota(
            metered: false,
            premium: true,
            limit: nil,
            used: 0,
            remaining: nil,
            resetsAt: nil
        )
        client.allowsSafetyOnly = true
        _ = await ask.ask("One more", context: nil, hasPremium: false)

        XCTAssertEqual(ask.remainingFreeAsks(hasPremium: false), AskSession.freeAsksPerDay)
    }

    /// A gateway that sends no quota is either answering a deterministic safety
    /// question or running an older contract. Neither is permission to reset the
    /// meter, and neither is a reason to double-charge it.
    func testAnAnswerWithoutQuotaLeavesTheLocalCountAlone() async throws {
        let client = StubBotanistClient()
        client.quota = nil
        let (ask, _, storage, suite) = try makeSession(client: client)
        defer { storage.removePersistentDomain(forName: suite) }

        _ = await ask.ask("Why is it drooping?", context: nil, hasPremium: false)

        XCTAssertEqual(ask.remainingFreeAsks(hasPremium: false), AskSession.freeAsksPerDay - 1)
    }

    /// The gateway refusing on a question this device believed was free is the
    /// case a device-local meter cannot produce on its own. The count has to end
    /// up spent, or the composer offers a question that will be refused again.
    func testARefusalSpendsTheLocalMeterEvenWhenTheDeviceThoughtItWasFree() async throws {
        let client = StubBotanistClient()
        client.error = BotanistClientPolicyError.premiumRequired
        let (ask, _, storage, suite) = try makeSession(client: client)
        defer { storage.removePersistentDomain(forName: suite) }

        XCTAssertTrue(ask.canAsk(hasPremium: false))
        let refused = await ask.ask("Why is it drooping?", context: nil, hasPremium: false)

        XCTAssertEqual(refused.outcome, .needsPremium)
        XCTAssertEqual(ask.remainingFreeAsks(hasPremium: false), 0)
        XCTAssertFalse(ask.canAsk(hasPremium: false))
    }

    /// The meter resets on the gateway's UTC day. Reading it through the device's
    /// calendar is what let a time-zone change hand out a fresh allowance, and in
    /// New Zealand it also made the app promise three questions for the twelve
    /// hours before the gateway agreed.
    func testTheMeterDayIsStampedInUTC() async throws {
        let (ask, _, storage, suite) = try makeSession()
        defer { storage.removePersistentDomain(forName: suite) }

        _ = await ask.ask("Why is it drooping?", context: nil, hasPremium: false)

        let stamp = try XCTUnwrap(ask.meterDay)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(utc.component(.hour, from: stamp), 12)
        XCTAssertTrue(utc.isDate(stamp, inSameDayAs: .now))
        XCTAssertTrue(utc.isDate(ask.freeAsksResetAt, inSameDayAs: AskSession.nextUTCDayStart()))
        XCTAssertEqual(utc.component(.hour, from: ask.freeAsksResetAt), 0)
    }

    /// The paywall used to say the questions came back "tomorrow". On a UTC
    /// reset that is wrong by half a day in New Zealand, in the direction that
    /// charges someone for what they were about to get free.
    func testTheResetSentenceNamesTheActualTime() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let noon = Date(timeIntervalSince1970: 1_785_672_000)

        let laterToday = AskPaywallSheet.resetSentence(
            at: noon,
            now: noon.addingTimeInterval(-3_600),
            calendar: utc
        )
        XCTAssertTrue(laterToday.hasPrefix("They come back at "), laterToday)
        XCTAssertFalse(laterToday.contains("tomorrow"), laterToday)

        let nextDay = AskPaywallSheet.resetSentence(
            at: noon,
            now: noon.addingTimeInterval(-86_400),
            calendar: utc
        )
        XCTAssertTrue(nextDay.contains("tomorrow at "), nextDay)
    }

    /// Opening Premium proactively must describe the allowance still available,
    /// not reuse the copy for a fourth question that the gateway rejected.
    func testProactivePaywallNamesTheActualFreeQuestionsRemaining() {
        XCTAssertEqual(
            AskPaywallSheet.allowanceSentence(remaining: 3),
            "You have 3 free questions left today."
        )
        XCTAssertEqual(
            AskPaywallSheet.allowanceSentence(remaining: 2),
            "You have 2 free questions left today."
        )
        XCTAssertEqual(
            AskPaywallSheet.allowanceSentence(remaining: 1),
            "You have 1 free question left today."
        )
        XCTAssertEqual(
            AskPaywallSheet.allowanceSentence(remaining: 0),
            "You've used today's 3 free questions."
        )
    }

    /// Running out must not read as "there is nothing left for you here": the
    /// gateway still answers a recognised emergency for free, and a parent
    /// whose child has just eaten a leaf has to know that before they give up.
    func testSpentAllowanceSaysSafetyQuestionsAreStillAnswered() {
        XCTAssertTrue(AskAllowance.safetyStillAnswered.contains("safety"))
        XCTAssertTrue(AskAllowance.safetyStillAnswered.contains("still answered"))
    }

    /// The safety line belongs in the wall's opening sentence only once the
    /// allowance is actually spent, not on a proactive upgrade with questions
    /// still left.
    func testSpentPaywallSaysSafetyQuestionsAreStillAnswered() {
        let resetAt = Date(timeIntervalSince1970: 1_785_672_000)

        let spent = AskPaywallSheet.subtitle(
            reason: .limitReached,
            remaining: 0,
            isPurchasable: true,
            isStoreUnreachable: false,
            isUnmetered: false,
            resetAt: resetAt
        )
        XCTAssertTrue(spent.contains(AskAllowance.safetyStillAnswered), spent)

        let browsing = AskPaywallSheet.subtitle(
            reason: .browsing,
            remaining: 2,
            isPurchasable: true,
            isStoreUnreachable: false,
            isUnmetered: false,
            resetAt: resetAt
        )
        XCTAssertFalse(browsing.contains(AskAllowance.safetyStillAnswered), browsing)

        let settings = AskPaywallSheet.subtitle(
            reason: .settings,
            remaining: 2,
            isPurchasable: true,
            isStoreUnreachable: false,
            isUnmetered: false,
            resetAt: resetAt
        )
        XCTAssertEqual(
            settings,
            browsing,
            "Settings copy must match browsing; only its heading names Premium"
        )
    }

    /// Ari's answers are generated, and the composer says so in one line.
    func testAIDisclosureNamesAriAsAnAI() {
        XCTAssertTrue(AskAllowance.aiDisclosure.contains("AI"))
    }

    /// A failure must not cost the user a question — they got no answer.
    func testFailedQuestionRefundsTheMeterAndKeepsTheQuestion() async throws {
        let client = StubBotanistClient()
        client.error = APIError.server(status: 503, message: nil)
        let (ask, _, storage, suite) = try makeSession(client: client)
        defer { storage.removePersistentDomain(forName: suite) }

        let result = await ask.ask("Why is it drooping?", context: nil, hasPremium: false)
        guard case .failed = result.outcome else {
            return XCTFail("Expected a failure, got \(result.outcome)")
        }
        XCTAssertEqual(ask.remainingFreeAsks(hasPremium: false), AskSession.freeAsksPerDay)
        XCTAssertNotNil(ask.failureMessage(in: result.threadID))
        XCTAssertEqual(ask.unansweredQuestion(in: result.threadID), "Why is it drooping?")
    }

    /// A failure belongs to the conversation it happened in. Held globally, it
    /// followed the user into an unrelated, fully answered thread and offered to
    /// retry a question that thread had never asked.
    func testAFailureStaysInItsOwnConversation() async throws {
        let client = StubBotanistClient()
        let (ask, _, storage, suite) = try makeSession(client: client)
        defer { storage.removePersistentDomain(forName: suite) }

        let answered = await ask.ask("Why is it drooping?", context: nil, hasPremium: false)
        client.error = APIError.timedOut
        let failed = await ask.ask("And the yellow leaf?", context: nil, hasPremium: false)

        XCTAssertNotNil(ask.failureMessage(in: failed.threadID))
        XCTAssertNil(
            ask.failureMessage(in: answered.threadID),
            "An answered conversation must not show another one's failure"
        )
    }

    /// The thinking bubble and the composer belong to one conversation too: a
    /// question in flight elsewhere must not freeze an unrelated composer.
    func testOnlyTheAskingConversationShowsAsAnswering() async throws {
        let client = StubBotanistClient()
        let (ask, _, storage, suite) = try makeSession(client: client)
        defer { storage.removePersistentDomain(forName: suite) }

        let idle = ask.startDraftThread(plantID: nil).id
        let asking = ask.startDraftThread(plantID: nil).id

        // `anywhere` rather than `any`: as a tuple label the latter collides
        // with the existential keyword and the syntax gate cannot parse it.
        var observed: (asking: Bool, idle: Bool, anywhere: Bool)?
        client.whileAnswering = { observed = (ask.isAnswering(in: asking), ask.isAnswering(in: idle), ask.isAnswering) }
        _ = await ask.ask("Why is it drooping?", in: asking, context: nil, hasPremium: false)

        let state = try XCTUnwrap(observed, "The stub never ran, so nothing was observed in flight")
        XCTAssertTrue(state.asking, "The conversation being answered shows its thinking bubble")
        XCTAssertFalse(state.idle, "An untouched conversation must not borrow it")
        XCTAssertTrue(state.anywhere, "The tab root still knows something is in flight")

        XCTAssertFalse(ask.isAnswering, "Nothing is in flight once the answer lands")
        XCTAssertFalse(ask.isAnswering(in: asking))
    }

    /// Opening another conversation while the first request is suspended is a
    /// supported flow. Each thread must retain its own thinking state until its
    /// own answer settles.
    func testTwoInFlightConversationsKeepIndependentAnsweringState() async throws {
        let client = StubBotanistClient()
        client.responseDelay = .milliseconds(250)
        let (ask, _, storage, suite) = try makeSession(client: client)
        defer { storage.removePersistentDomain(forName: suite) }

        let firstID = ask.startDraftThread(plantID: nil).id
        let secondID = ask.startDraftThread(plantID: nil).id
        let first = Task {
            await ask.ask("First question", in: firstID, context: nil, hasPremium: true)
        }
        for _ in 0..<1_000 {
            if ask.isAnswering(in: firstID) { break }
            await Task.yield()
        }
        XCTAssertTrue(ask.isAnswering(in: firstID), "The first request never entered its in-flight state")

        let second = Task {
            await ask.ask("Second question", in: secondID, context: nil, hasPremium: true)
        }
        for _ in 0..<1_000 {
            if ask.isAnswering(in: secondID) { break }
            await Task.yield()
        }
        XCTAssertTrue(ask.isAnswering(in: secondID), "The second request never entered its in-flight state")

        XCTAssertTrue(ask.isAnswering(in: firstID))
        XCTAssertTrue(ask.isAnswering(in: secondID))
        XCTAssertTrue(ask.isAnswering)

        _ = await first.value
        _ = await second.value
        XCTAssertFalse(ask.isAnswering)
    }

    func testDeletingAnInFlightConversationDoesNotReportAnInvisibleAnswer() async throws {
        let client = StubBotanistClient()
        client.responseDelay = .milliseconds(150)
        let (ask, _, storage, suite) = try makeSession(client: client)
        defer { storage.removePersistentDomain(forName: suite) }
        let threadID = ask.startDraftThread(plantID: nil).id
        let request = Task {
            await ask.ask("What should I check?", in: threadID, context: nil, hasPremium: true)
        }
        for _ in 0..<1_000 {
            if ask.isAnswering(in: threadID) { break }
            await Task.yield()
        }
        XCTAssertTrue(ask.isAnswering(in: threadID))

        ask.delete(threadID: threadID)
        let result = await request.value

        XCTAssertEqual(result.outcome, .failed(message: "That question was cancelled."))
        XCTAssertNil(ask.thread(id: threadID))
        XCTAssertFalse(ask.isAnswering(in: threadID))
    }

    /// A timeout has its own wording because it has its own fix: wait and tap
    /// again, rather than go looking for a broken connection.
    func testTransportFailuresReadDifferently() {
        XCTAssertEqual(APIError.offline.errorDescription, "You're offline. Reconnect and try again.")
        XCTAssertEqual(APIError.timedOut.errorDescription, "That's taking longer than it should. Try again.")
        XCTAssertNotEqual(APIError.timedOut.errorDescription, APIError.transport("lost").errorDescription)
    }

    /// The gateway bounds its own wait precisely so it can say *why* it gave up.
    /// That only pays off if its wording survives the trip: a 5xx flattened to
    /// its status code puts "Grove's service is down" under a coach that was
    /// merely slow.
    func testTheGatewaysOwnWordingReachesTheConversation() async throws {
        let stalled = "Ari took too long to answer. Try asking again."
        let client = StubBotanistClient()
        client.error = APIError.server(status: 504, message: stalled)
        let (ask, _, storage, suite) = try makeSession(client: client)
        defer { storage.removePersistentDomain(forName: suite) }

        let result = await ask.ask("Why is it drooping?", context: nil, hasPremium: false)
        XCTAssertEqual(result.outcome, .failed(message: stalled))
        XCTAssertEqual(ask.failureMessage(in: result.threadID), stalled)
    }

    /// The app must outlast the gateway, or the gateway's specific 504 copy never
    /// reaches the user — they get a bare dropped connection instead. The gateway
    /// spends up to 40s checking an attached photo and then at most 52s on the
    /// text provider, so the app's ask has to clear that sequence plus a cold
    /// start, and the session ceiling has to clear the ask.
    func testTheAppWaitsLongerForAnAnswerThanTheGatewayDoes() {
        XCTAssertGreaterThan(HTTPBotanistClient.askTimeout, 92, "Below the gateway's photo-plus-answer budget")
        XCTAssertGreaterThan(HTTPBotanistClient.askTimeout, APITimeout.standard, "A coach answer is not plain CRUD")
        XCTAssertGreaterThanOrEqual(
            APITimeout.ceiling,
            HTTPBotanistClient.askTimeout,
            "The session ceiling silently caps every per-request timeout above it"
        )
    }

    /// Retrying must not show the user asking twice.
    func testRetryAfterFailureDoesNotDuplicateTheQuestion() async throws {
        let client = StubBotanistClient()
        client.error = APIError.server(status: 503, message: nil)
        let (ask, _, storage, suite) = try makeSession(client: client)
        defer { storage.removePersistentDomain(forName: suite) }

        let first = await ask.ask("Why is it drooping?", context: nil, hasPremium: false)
        client.error = nil
        let retried = await ask.ask("Why is it drooping?", in: first.threadID, context: nil, hasPremium: false)
        XCTAssertEqual(retried.outcome, .answered)

        let thread = try XCTUnwrap(ask.thread(id: first.threadID))
        XCTAssertEqual(thread.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(thread.messages.count, 2)
        XCTAssertNil(ask.failureMessage(in: first.threadID))
    }

    func testAdviceOutcomeIsSavedRemotelyBeforeTheMessageChanges() async throws {
        let (ask, client, storage, suite) = try makeSession()
        defer { storage.removePersistentDomain(forName: suite) }

        let result = await ask.ask("What should I check?", context: nil, hasPremium: false)
        let message = try XCTUnwrap(ask.thread(id: result.threadID)?.messages.last)
        let saved = await ask.recordOutcome(.improved, for: message.id, in: result.threadID)

        XCTAssertTrue(saved)
        XCTAssertEqual(client.recordedOutcomes.count, 1)
        XCTAssertEqual(client.recordedOutcomes.first?.0, client.adviceID)
        XCTAssertEqual(client.recordedOutcomes.first?.1, .improved)
        XCTAssertEqual(
            ask.thread(id: result.threadID)?.messages.last?.recordedOutcome,
            .improved
        )
    }

    func testFailedOutcomeDoesNotPretendFeedbackWasSaved() async throws {
        let client = StubBotanistClient()
        let (ask, _, storage, suite) = try makeSession(client: client)
        defer { storage.removePersistentDomain(forName: suite) }

        let result = await ask.ask("What should I check?", context: nil, hasPremium: false)
        let message = try XCTUnwrap(ask.thread(id: result.threadID)?.messages.last)
        client.outcomeError = APIError.offline

        let saved = await ask.recordOutcome(.helpful, for: message.id, in: result.threadID)
        XCTAssertFalse(saved)
        XCTAssertNil(ask.thread(id: result.threadID)?.messages.last?.recordedOutcome)
    }

    // MARK: - Persistence and account scoping

    func testThreadsAndMeterSurviveAReopen() async throws {
        let suite = "AskTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }

        let first = AskSession(client: StubBotanistClient(), storage: storage)
        first.activate(accountID: "acct-ask")
        let result = await first.ask("Why is it drooping?", context: nil, hasPremium: false)
        XCTAssertEqual(result.outcome, .answered)

        let reopened = AskSession(client: StubBotanistClient(), storage: storage)
        reopened.activate(accountID: "acct-ask")
        XCTAssertEqual(reopened.recentThreads.count, 1)
        XCTAssertEqual(reopened.thread(id: result.threadID)?.messages.count, 2)
        XCTAssertEqual(reopened.remainingFreeAsks(hasPremium: false), AskSession.freeAsksPerDay - 1)
    }

    func testMessagesSavedBeforeBotanistV2StillDecode() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "role": "botanist",
          "text": "Check the soil first.",
          "createdAt": 0
        }
        """

        let message = try JSONDecoder().decode(BotanistMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.id, id)
        XCTAssertNil(message.photoURL)
        XCTAssertNil(message.adviceID)
        XCTAssertNil(message.followUpAt)
        XCTAssertNil(message.sources)
        XCTAssertNil(message.recordedOutcome)
    }

    /// A second account must inherit neither the conversations nor the meter.
    func testAnotherAccountStartsClean() async throws {
        let suite = "AskTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }

        let session = AskSession(client: StubBotanistClient(), storage: storage)
        session.activate(accountID: "acct-one")
        _ = await session.ask("Mine", context: nil, hasPremium: false)

        session.activate(accountID: "acct-two")
        XCTAssertTrue(session.recentThreads.isEmpty)
        XCTAssertEqual(session.remainingFreeAsks(hasPremium: false), AskSession.freeAsksPerDay)
    }

    func testSignOutClearsBotanistMemoryButReactivationRestoresItsSnapshot() async throws {
        let (ask, _, storage, suite) = try makeSession(accountID: "acct-signout")
        defer { storage.removePersistentDomain(forName: suite) }
        _ = await ask.ask("Keep this for my next sign-in", context: nil, hasPremium: false)

        ask.deactivate()

        XCTAssertTrue(ask.threads.isEmpty)
        XCTAssertTrue(ask.recentThreads.isEmpty)
        XCTAssertEqual(ask.asksToday, 0)

        ask.activate(accountID: "acct-signout")
        XCTAssertEqual(ask.recentThreads.first?.title, "Keep this for my next sign-in")
        XCTAssertEqual(ask.remainingFreeAsks(hasPremium: false), AskSession.freeAsksPerDay - 1)
    }

    func testInFlightAnswerCannotCrossAQuickSignOutAndSameAccountSignIn() async throws {
        let client = StubBotanistClient()
        client.responseDelay = .milliseconds(150)
        let (ask, _, storage, suite) = try makeSession(
            client: client,
            accountID: "acct-signout-race"
        )
        defer { storage.removePersistentDomain(forName: suite) }
        let threadID = ask.startDraftThread(plantID: nil).id
        let request = Task {
            await ask.ask("Old session question", in: threadID, context: nil, hasPremium: true)
        }
        for _ in 0..<1_000 {
            if ask.isAnswering(in: threadID) { break }
            await Task.yield()
        }
        XCTAssertTrue(ask.isAnswering(in: threadID))

        ask.deactivate()
        ask.activate(accountID: "acct-signout-race")
        let result = await request.value

        XCTAssertEqual(result.outcome, .failed(message: "That question was cancelled."))
        XCTAssertEqual(ask.thread(id: threadID)?.messages.count, 1)
        XCTAssertNil(ask.thread(id: threadID)?.lastAnswer)
    }

    func testQueuedQuestionCannotCrossAnAccountSwitch() throws {
        let (ask, _, storage, suite) = try makeSession(accountID: "acct-one")
        defer { storage.removePersistentDomain(forName: suite) }
        let oldThreadID = ask.queue("This belongs to account one", plantID: nil, photoData: Data([1, 2, 3]))

        ask.activate(accountID: "acct-two")

        XCTAssertNil(ask.takePendingQuestion(for: oldThreadID))
        XCTAssertNil(ask.thread(id: oldThreadID))
    }

    func testCorruptMeterAndForeignPhotoURLAreSanitizedOnRestore() throws {
        struct StoredSnapshot: Encodable {
            let threads: [BotanistThread]
            let asksToday: Int
            let meterDay: Date?
        }

        let suite = "AskTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        let accountID = "acct-corrupt"
        let foreignURL = URL(fileURLWithPath: "/private/tmp/not-a-botanist-attachment.jpg")
        let thread = BotanistThread(messages: [
            BotanistMessage(role: .user, text: "Old question", photoURL: foreignURL)
        ])
        let snapshot = StoredSnapshot(threads: [thread], asksToday: .min, meterDay: .now)
        let key = "grove.ask.v1.account.\(AccountStorage.namespace(for: accountID))"
        storage.set(try JSONEncoder().encode(snapshot), forKey: key)

        let ask = AskSession(client: StubBotanistClient(), storage: storage)
        ask.activate(accountID: accountID)

        XCTAssertEqual(ask.remainingFreeAsks(hasPremium: false), AskSession.freeAsksPerDay)
        XCTAssertNil(ask.thread(id: thread.id)?.messages.first?.photoURL)
    }

    func testRepeatedFailedThreadsStillRespectTheStorageCap() async throws {
        let client = StubBotanistClient()
        client.error = APIError.timedOut
        let (ask, _, storage, suite) = try makeSession(client: client)
        defer { storage.removePersistentDomain(forName: suite) }

        for index in 0..<48 {
            _ = await ask.ask("Failed question \(index)", context: nil, hasPremium: true)
        }

        XCTAssertEqual(ask.recentThreads.count, 40)
        XCTAssertNotNil(ask.recentThreads.first { $0.title == "Failed question 47" })
        XCTAssertNil(ask.recentThreads.first { $0.title == "Failed question 0" })
    }

    // MARK: - Drafts

    func testAbandonedDraftIsNotKeptAsHistory() throws {
        let (ask, _, storage, suite) = try makeSession()
        defer { storage.removePersistentDomain(forName: suite) }

        let draft = ask.startDraftThread(plantID: nil)
        XCTAssertTrue(ask.recentThreads.isEmpty, "A thread with no turns is not history")
        ask.discardIfEmpty(threadID: draft.id)
        XCTAssertNil(ask.thread(id: draft.id))
    }

    func testQueuedQuestionIsClaimedExactlyOnce() throws {
        let (ask, _, storage, suite) = try makeSession()
        defer { storage.removePersistentDomain(forName: suite) }

        let photo = Data([1, 2, 3])
        let threadID = ask.queue("Why is it drooping?", plantID: nil, photoData: photo)
        let queued = try XCTUnwrap(ask.takePendingQuestion(for: threadID))
        XCTAssertEqual(queued.question, "Why is it drooping?")
        XCTAssertEqual(queued.photoData, photo)
        XCTAssertNil(ask.takePendingQuestion(for: threadID), "A re-run task must not send it twice")
    }

    // MARK: - Streak and quests

    /// The whole reason Ask could replace the Learn tab: an answered question is
    /// the day's learning, so it tends the plant-safe streak and the learn quest.
    func testAnsweredQuestionTendsTheStreakAndTheLearnQuest() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        XCTAssertEqual(store.displayStreak, 0)

        let reward = try XCTUnwrap(store.recordBotanistAnswer())
        XCTAssertEqual(reward.xp, LearnLibrary.refresherXP)
        XCTAssertEqual(store.displayStreak, 1)

        let quest = try XCTUnwrap(store.dailyQuests.first { $0.objective == .learn })
        XCTAssertTrue(quest.isComplete, "Asking about a plant finishes today's learning quest")
    }

    /// One learning dividend a day, not one per surface — asking and then doing a
    /// lesson must not pay twice.
    func testDailyLearningDividendPaysOncePerDay() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        XCTAssertTrue(store.dailyLearningDividendAvailable)

        XCTAssertNotNil(store.recordBotanistAnswer())
        XCTAssertFalse(store.dailyLearningDividendAvailable)

        let xpAfterFirst = store.gardener.xp
        XCTAssertNil(store.recordBotanistAnswer(), "A second question the same day pays nothing")
        XCTAssertEqual(store.gardener.xp, xpAfterFirst)
        // The streak still holds — it just doesn't pay again.
        XCTAssertEqual(store.displayStreak, 1)
    }

    /// The other half of "one payout a day, not one per surface": a finished
    /// lesson spends the day's dividend too, so the two surfaces cannot be
    /// farmed back to back for it.
    func testALessonSpendsTheSameDailyDividendAsAsking() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let topic = try XCTUnwrap(LearnLibrary.all.first)

        XCTAssertNotNil(store.completeLearnLesson(topic.id))
        XCTAssertFalse(store.dailyLearningDividendAvailable, "The lesson was today's learning")

        let xpAfterLesson = store.gardener.xp
        XCTAssertNil(store.recordBotanistAnswer(), "Asking after a lesson must not pay a second time")
        XCTAssertEqual(store.gardener.xp, xpAfterLesson)
        XCTAssertEqual(store.displayStreak, 1, "It still tends the streak, it just doesn't pay")
    }

    /// The streak must never be reachable by watering, whatever tends it.
    func testWateringStillDoesNotTendTheStreak() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        XCTAssertNotNil(store.logCare(plantID: plant.id, kind: .water))
        XCTAssertEqual(store.displayStreak, 0, "Watering must never advance the streak")
    }

    // MARK: - Grounding

    func testPlantContextCarriesTheRecordTheAnswerNeeds() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let context = BotanistContext.text(
            plant: plant,
            observations: store.observations,
            tasks: store.tasks,
            profile: store.profile
        )
        XCTAssertTrue(context.contains(plant.nickname))
        XCTAssertTrue(context.contains(plant.species))
        XCTAssertTrue(context.contains(plant.healthBand.title))
        XCTAssertTrue(context.contains(plant.trend.title))
        XCTAssertTrue(context.contains("assessment confidence \(plant.confidence)%"))
    }

    func testPlantContextCarriesDiagnosisSafetyAndCompletedCare() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let possibility = PlantConditionCandidate(
            id: "excess-moisture",
            name: "Excess moisture stress",
            confidence: 72,
            explanation: "Lower leaves are yellowing.",
            evidence: ["Wet soil"],
            alternativeExplanation: "Normal leaf ageing"
        )
        let diagnosis = PlantDiagnosis(
            id: UUID(),
            plantID: plant.id,
            createdAt: now.addingTimeInterval(-86_400),
            summary: "Moisture stress is possible, but not confirmed.",
            healthBand: .monitor,
            confidence: 74,
            possibleConditions: [possibility],
            actionsToTake: ["Check the soil"],
            actionsToAvoid: ["Do not water yet"],
            providerName: "Google Gemini",
            identificationConfidence: 67,
            identificationRequiresConfirmation: true,
            visiblePositiveSigns: ["Stems remain firm"],
            visibleConcerns: ["Lower leaf yellowing"],
            clarifyingQuestions: [
                DiagnosisQuestion(
                    id: "soil",
                    prompt: "How does the soil feel below the surface?",
                    options: [
                        DiagnosisAnswerOption(id: "wet", title: "Wet"),
                        DiagnosisAnswerOption(id: "dry", title: "Dry")
                    ],
                    reason: "Separates moisture stress from normal ageing."
                )
            ],
            limitations: ["Roots were not visible"],
            photoURL: nil
        )
        let watering = ActivityEvent(
            id: UUID(),
            kind: .milestone,
            actorName: ActivityEvent.selfActorName,
            actorInitials: "AR",
            message: "logged watering",
            plantID: plant.id,
            timestamp: now.addingTimeInterval(-2 * 86_400)
        )

        let context = BotanistContext.text(
            plant: plant,
            observations: [],
            tasks: [],
            profile: store.profile,
            diagnoses: [diagnosis],
            activity: [watering],
            now: now
        )

        XCTAssertTrue(context.contains("Latest Gemini photo scan (yesterday, 74% confidence)"))
        XCTAssertTrue(context.contains("Scan engine: Google Gemini."))
        XCTAssertTrue(context.contains("Gemini identification confidence: 67%, species confirmation still required"))
        XCTAssertTrue(context.contains("Gemini-visible positive signs: Stems remain firm"))
        XCTAssertTrue(context.contains("Gemini-visible concerns: Lower leaf yellowing"))
        XCTAssertTrue(context.contains("Excess moisture stress (72%, not confirmed; visible evidence: Wet soil)"))
        XCTAssertTrue(context.contains("Do not water yet"))
        XCTAssertTrue(context.contains("Useful missing observations from Gemini"))
        XCTAssertTrue(context.contains("Gemini scan limitations: Roots were not visible"))
        XCTAssertTrue(context.contains("2 days ago: You logged watering"))
    }

    func testPlantContextDerivesARepeatedWetAndFallingTrend() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let observations = [
            PlantObservation(
                id: UUID(),
                plantID: plant.id,
                createdAt: now,
                previousScore: 75,
                score: 64,
                band: .monitor,
                note: "",
                appearance: .worse,
                soilMoisture: .wet,
                hasNewGrowth: false,
                photoURL: nil,
                actorName: "You"
            ),
            PlantObservation(
                id: UUID(),
                plantID: plant.id,
                createdAt: now.addingTimeInterval(-3 * 86_400),
                previousScore: 78,
                score: 75,
                band: .healthy,
                note: "",
                appearance: .same,
                soilMoisture: .wet,
                hasNewGrowth: false,
                photoURL: nil,
                actorName: "You"
            )
        ]

        let context = BotanistContext.text(
            plant: plant,
            observations: observations,
            tasks: [],
            profile: store.profile,
            now: now
        )

        XCTAssertTrue(context.contains("score down 11 points"))
        XCTAssertTrue(context.contains("wet at the 2 newest consecutive check-ins"))
    }

    func testGroveContextHandlesAnEmptyGrove() {
        let profile = GroveStore(plants: [], persistenceEnabled: false).profile
        let context = BotanistContext.text(plants: [], profile: profile)
        XCTAssertTrue(context.contains("no plants"))
    }

    /// Whole-grove questions promise comparisons that only work when the answer
    /// includes the same soil checks and care dates used to choose the question.
    func testGroveContextCarriesRecentChecksAndCareDue() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let observation = PlantObservation(
            id: UUID(),
            plantID: plant.id,
            createdAt: now,
            previousScore: 70,
            score: 68,
            band: .monitor,
            note: "",
            appearance: .same,
            soilMoisture: .wet,
            hasNewGrowth: false,
            photoURL: nil,
            actorName: "You"
        )
        let task = CareTask(
            id: UUID(),
            plantID: plant.id,
            kind: .inspectSoil,
            dueDate: now.addingTimeInterval(-86_400),
            detail: "Check the soil.",
            isCompleted: false,
            isSittingTask: false,
            ownerName: nil
        )

        let context = BotanistContext.text(
            plants: [plant],
            profile: store.profile,
            observations: [observation],
            tasks: [task],
            now: now
        )

        XCTAssertTrue(context.contains("Last check-in today: soil wet, score 68"))
        XCTAssertTrue(context.contains("\(plant.nickname): Feel the soil (overdue by 1 day)"))
    }

    // MARK: - Sky grounding

    /// A fortnight of grey is the answer to a great many "why has it stopped
    /// growing" questions, and the coach can only reach it if it is told.
    func testContextCarriesTheGrovesRecentLight() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let context = BotanistContext.text(
            plant: plant,
            observations: store.observations,
            tasks: store.tasks,
            profile: store.profile,
            sky: Self.sky(fullSunHoursPerDay: 3)
        )
        XCTAssertTrue(context.contains("3h of full-strength sun a day"), "The headline figure has to be in the block")
        XCTAssertTrue(context.contains("Day length"), "Season is carried by day length, not by a guessed hemisphere")
    }

    /// The DLI line is what lets the coach compare a spot against a species
    /// requirement instead of hand-waving about "bright indirect light".
    func testContextCarriesTheLightIntegralAndTheIndoorFractions() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let context = BotanistContext.text(
            plants: [],
            profile: store.profile,
            sky: Self.sky(fullSunHoursPerDay: 5)
        )
        XCTAssertTrue(context.contains("mol/m²/day"), "The unit growers reason in has to be present")
        XCTAssertTrue(context.contains("windowsill receives roughly half"), "Outdoor light is useless without the indoor fraction")
    }

    /// The caveat is load-bearing, not decoration: this is outdoor weather, and
    /// a coach that reads it as the plant's own will explain a windowsill it has
    /// never seen.
    func testLightIsLabelledAsOutdoorAmbient() throws {
        let store = GroveStore(persistenceEnabled: false)
        let context = BotanistContext.text(
            plants: store.plants,
            profile: store.profile,
            sky: Self.sky(fullSunHoursPerDay: 5)
        )
        XCTAssertTrue(context.contains("ambient outdoor weather"))
        XCTAssertTrue(context.contains("not a measurement taken at any one plant"))
    }

    /// No forecast yet, or no pinned location, must read as silence rather than
    /// as a grove that gets no sun.
    func testContextSaysNothingAboutTheSkyWhenThereIsNoForecast() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let context = BotanistContext.text(plants: [], profile: store.profile)
        XCTAssertFalse(context.contains("Outdoor light"))
        XCTAssertFalse(context.contains("of full-strength sun"))
    }

    /// A duller-than-usual run is the causal hook; a steady one rules light out.
    func testASharpDropInLightIsReportedAsATrend() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let bright = Self.sunlight(fullSunHoursPerDay: 8, count: 7, endingDaysAgo: 7)
        let dull = Self.sunlight(fullSunHoursPerDay: 2, count: 7)
        let context = BotanistContext.text(
            plants: [],
            profile: store.profile,
            sky: GroveForecast(days: Self.days(), sunlight: bright + dull)
        )
        XCTAssertTrue(context.contains("darker than"), "A halved fortnight is exactly what the coach needs to notice")

        let steady = BotanistContext.text(
            plants: [],
            profile: store.profile,
            sky: Self.sky(fullSunHoursPerDay: 6)
        )
        XCTAssertFalse(steady.contains("darker than"), "Flat weather must not be narrated as a trend")
        XCTAssertFalse(steady.contains("Brighter fortnight"), "Flat weather must not be narrated as a trend")
    }

    /// Where a plant stands decides how much of that light it actually gets, so
    /// the coach is told — and told plainly when nobody has said.
    func testContextCarriesThePlantsLightPosition() throws {
        let store = GroveStore(persistenceEnabled: false)
        var plant = try XCTUnwrap(store.plants.first)
        plant.lightPlacement = .sill
        let known = BotanistContext.text(
            plant: plant,
            observations: store.observations,
            tasks: store.tasks,
            profile: store.profile
        )
        XCTAssertTrue(known.contains("Light position: on the windowsill"))

        plant.lightPlacement = nil
        plant.location = "Bedroom"
        let unknown = BotanistContext.text(
            plant: plant,
            observations: store.observations,
            tasks: store.tasks,
            profile: store.profile
        )
        XCTAssertTrue(unknown.contains("Light position: not recorded"))
        XCTAssertTrue(unknown.contains("Ask where it stands"))
    }

    // MARK: - Sky fixtures

    /// Days ending today, oldest first — the order `WeatherService` hands over.
    private static func sunlight(
        fullSunHoursPerDay: Double,
        count: Int = 14,
        endingDaysAgo: Int = 0
    ) -> [GroveSunlightDay] {
        (0..<count).reversed().map { offset in
            GroveSunlightDay(
                date: Calendar.current.date(byAdding: .day, value: -(offset + endingDaysAgo), to: .now) ?? .now,
                fullSunHours: fullSunHoursPerDay,
                daylightHours: 12,
                cloudCover: 40
            )
        }
    }

    /// A mild, unremarkable week ahead: nothing here should trip a hazard rule.
    private static func days(count: Int = 7) -> [GroveWeatherDay] {
        (0..<count).map { offset in
            GroveWeatherDay(
                date: Calendar.current.date(byAdding: .day, value: offset, to: .now) ?? .now,
                symbol: "cloud.sun.fill",
                highCelsius: 22,
                lowCelsius: 14,
                dewPointCelsius: 12,
                outdoorHumidity: 62,
                precipitationMillimetres: 0
            )
        }
    }

    private static func sky(fullSunHoursPerDay: Double) -> GroveForecast {
        GroveForecast(days: days(), sunlight: sunlight(fullSunHoursPerDay: fullSunHoursPerDay))
    }

    // MARK: - Grounded prompts

    /// The suggestions have to come from the plant's own state — that is the
    /// difference between Ask and a search box.
    func testSuggestionsNameThePlantAndItsProblem() throws {
        var plant = try XCTUnwrap(GroveStore(persistenceEnabled: false).plants.first)
        plant.healthBand = .attention
        plant.trend = .declining
        plant.concerns = ["Mild yellowing on one lower leaf"]

        let prompts = AskPrompts.suggestions(for: plant)
        XCTAssertFalse(prompts.isEmpty)
        XCTAssertTrue(prompts.allSatisfy { $0.plantID == plant.id })
        XCTAssertTrue(prompts.contains { $0.text.contains(plant.nickname) })
        XCTAssertTrue(
            prompts.contains { $0.text.contains("Mild yellowing on one lower leaf") },
            "A concern on the record should become a question about it"
        )
        XCTAssertTrue(prompts.contains { $0.text.contains("downwards") }, "A declining trend should be asked about")
    }

    func testHealthyPlantStillHasSomethingToAsk() throws {
        var plant = try XCTUnwrap(GroveStore(persistenceEnabled: false).plants.first)
        plant.healthBand = .thriving
        plant.trend = .stable
        plant.concerns = []
        plant.nextActions = []
        XCTAssertFalse(AskPrompts.suggestions(for: plant).isEmpty)
    }

    // MARK: - Browsing must not invent symptoms

    /// A standing suggestion is a browse item, not a report. The botanist is
    /// handed the real grove alongside the question, so "One of my plants has
    /// pests" sent on behalf of a curious tap invites the coach to pin an
    /// invented symptom on a named plant that is perfectly healthy.
    func testEvergreenPromptsNeverClaimASymptomTheUserDidNotReport() throws {
        let store = GroveStore(persistenceEnabled: false)
        var plants = store.plants
        for index in plants.indices {
            plants[index].healthBand = .thriving
            plants[index].trend = .stable
            plants[index].concerns = []
        }

        // Phrases that assert a state of affairs about the user's own plants.
        // A question may describe a symptom; it may not claim to have one.
        let claims = [
            "one of my plants has",
            "my leaves are",
            "there's white fuzz",
            "keep rising off the soil",
            "none of my plants",
            "i'm going away",
            "i've just brought",
            "my place doesn't"
        ]

        for prompt in AskPrompts.groveSuggestions(plants: plants) + AskPrompts.groveSuggestions(plants: []) {
            let text = prompt.text.lowercased()
            for claim in claims {
                XCTAssertFalse(
                    text.contains(claim),
                    "“\(prompt.label)” asserts a symptom the user never reported: \(prompt.text)"
                )
            }
        }
    }

    /// The label is the promise and the text is what gets sent. A row reading
    /// "Should I move them?" that sends a question about seasonal light is a
    /// row nobody can predict the result of.
    ///
    /// Driven with *record-length* text on purpose. The first version of this
    /// test used the fixture's tidy one-clause concerns, passed, and shipped a
    /// four-line row quoting a whole assessment sentence — a suite that only
    /// ever sees convenient data proves nothing about the screen.
    func testEveryLabelReadsAsSomethingAPersonWouldTap() throws {
        let store = GroveStore(persistenceEnabled: false)
        var plant = try XCTUnwrap(store.plants.first)
        plant.location = "Living room"
        plant.concerns = [
            "Some leaves show minor yellowing or browning at the edges, which could indicate slight watering issues or nutrient deficiency."
        ]
        plant.nextActions = ["Feel the top 3 cm of soil before you water", "Keep it bright, out of direct sun"]

        let pools = [
            AskPrompts.groveSuggestions(plants: store.plants),
            AskPrompts.groveSuggestions(plants: []),
            AskPrompts.suggestions(for: plant, tasks: store.tasks)
        ]
        for prompt in pools.flatMap({ $0 }) {
            XCTAssertFalse(prompt.label.isEmpty)
            XCTAssertFalse(prompt.text.isEmpty)
            XCTAssertLessThanOrEqual(
                prompt.label.count,
                44,
                "“\(prompt.label)” is too long to read as a row"
            )
        }
    }

    /// COPY.md is the canonical voice contract, and it is specific: "your
    /// grove" is the term the product owns, "collection" and "assessment" are
    /// named as the words not to use for it, and the health vocabulary is fixed
    /// at five phrases with "any other health wording, ever" ruled out.
    ///
    /// Worth a test because the failure is invisible one string at a time —
    /// "doing well", "struggling", "going downhill" and "sliding" each read
    /// fine alone, and together they are four more ways of saying what the
    /// health band already says in one.
    func testPromptCopyKeepsTheHouseVocabulary() throws {
        let store = GroveStore(persistenceEnabled: false)
        var plants = store.plants
        plants[0].healthBand = .attention
        plants[0].trend = .declining
        plants[0].location = "Living room"
        var plant = plants[0]
        plant.concerns = ["Some leaves show minor yellowing at the edges"]
        plant.nextActions = ["Move away from the radiator"]

        // Left-hand side is what COPY.md bans; right-hand side is what it owns.
        let banned = [
            "collection": "your grove",
            "assessment": "check-in",
            "struggling": "needs attention",
            "doing well": "thriving or healthy",
            "downhill": "declining",
            "sliding": "declining"
        ]

        let pools = [
            AskPrompts.groveSuggestions(plants: plants, tasks: store.tasks),
            AskPrompts.groveSuggestions(plants: []),
            AskPrompts.suggestions(for: plant, tasks: store.tasks)
        ]
        for prompt in pools.flatMap({ $0 }) {
            let copy = (prompt.label + " " + prompt.text).lowercased()
            for (word, instead) in banned {
                XCTAssertFalse(
                    copy.contains(word),
                    "“\(prompt.label)” says “\(word)”; COPY.md says “\(instead)”"
                )
            }
            XCTAssertFalse(prompt.label.contains("!"), "“\(prompt.label)” exclaims outside a celebration")
        }
    }

    /// "How do I do that?" sat in a list of questions with nothing to point at,
    /// so the only way to learn what the row meant was to tap it. A label that
    /// needs its own hidden text to make sense is not a label.
    func testNoLabelLeansOnAWordWithNothingToPointAt() throws {
        let store = GroveStore(persistenceEnabled: false)
        var plant = try XCTUnwrap(store.plants.first)
        plant.nextActions = ["Move away from the radiator"]
        plant.healthBand = .attention

        let pools = [
            AskPrompts.groveSuggestions(plants: store.plants),
            AskPrompts.groveSuggestions(plants: []),
            AskPrompts.suggestions(for: plant, tasks: store.tasks)
        ]
        for prompt in pools.flatMap({ $0 }) {
            let words = prompt.label.lowercased().split { !$0.isLetter }
            XCTAssertFalse(
                words.contains("that"),
                "“\(prompt.label)” points at something the row never names"
            )
            XCTAssertFalse(
                prompt.label.lowercased().hasSuffix("this?"),
                "“\(prompt.label)” points at something the row never names"
            )
        }

        let action = try XCTUnwrap(
            AskPrompts.suggestions(for: plant).first { $0.id.hasSuffix("-action") }
        )
        XCTAssertEqual(action.label, "Why move away from the radiator?")
    }

    /// Every one of these reached a row on screen.
    func testRecordedTextIsMadeFitForARow() {
        XCTAssertEqual(
            AskPhrase.short(
                "Some leaves show minor yellowing or browning at the edges, which could indicate slight watering issues",
                limit: 30
            ),
            "Some leaves show minor…",
            "An assessment's opening clause is the finding; the rest is qualification"
        )
        XCTAssertEqual(AskPhrase.short("Root rot", limit: 30), "Root rot")
        XCTAssertEqual(AskPhrase.short("Check soil again in 5–7 days.", limit: 40), "Check soil again in 5–7 days")

        // "Is Living room a good spot?" shipped in the per-plant list.
        XCTAssertEqual(AskPhrase.inSentence("Living room"), "the living room")
        XCTAssertEqual(AskPhrase.inSentence("Kitchen"), "the kitchen")
        // Free-typed proper nouns keep their capitals and go without an article.
        XCTAssertEqual(AskPhrase.inSentence("Alex's Office"), "Alex's Office")

        XCTAssertEqual(AskPhrase.careNoun(.water), "watering")
        XCTAssertEqual(AskPhrase.careNoun(.inspectSoil), "soil check")
    }

    /// A good band does not outrank a live finding: "How do I keep it healthy?"
    /// reading directly above the evidence that it is not healthy is the tab
    /// arguing with itself.
    func testALiveConcernOutranksAReassuringBand() throws {
        var plant = try XCTUnwrap(GroveStore(persistenceEnabled: false).plants.first)
        plant.healthBand = .thriving
        plant.trend = .stable
        plant.concerns = ["Some leaves show minor yellowing at the edges"]

        let first = try XCTUnwrap(AskPrompts.suggestions(for: plant).first)
        XCTAssertTrue(first.id.hasSuffix("-concern"), "The finding leads, not the reassurance")

        plant.concerns = []
        let clean = try XCTUnwrap(AskPrompts.suggestions(for: plant).first)
        XCTAssertTrue(clean.id.hasSuffix("-thriving"), "With nothing found, the band leads again")
    }

    /// Both halves of this reached the user in the question that got sent.
    func testSpeciesReadCorrectlyInsideASentence() {
        XCTAssertEqual(SpeciesPhrase.indefinite("Monstera"), "a Monstera")
        XCTAssertEqual(SpeciesPhrase.indefinite("Aloe vera"), "an Aloe vera")
        XCTAssertEqual(SpeciesPhrase.indefinite("Echeveria"), "an Echeveria")
        XCTAssertEqual(SpeciesPhrase.indefinite("umbrella plant"), "an umbrella plant")
        // Spelled with a vowel, spoken with a "y".
        XCTAssertEqual(SpeciesPhrase.indefinite("Euphorbia"), "a Euphorbia")
        // Casing is preserved: lowercasing mangles a legitimate proper noun.
        XCTAssertEqual(SpeciesPhrase.indefinite("Boston fern"), "a Boston fern")
    }

    // MARK: - Whole-grove prompts read the grove

    /// One plant in trouble used to clear the "more than one" threshold and
    /// produce nothing, so the grove list opened on a seasonal reminder while a
    /// plant was dying.
    func testASingleStrugglingPlantStillLeadsTheGroveList() throws {
        let store = GroveStore(persistenceEnabled: false)
        var plants = store.plants
        for index in plants.indices {
            plants[index].healthBand = .thriving
            plants[index].trend = .stable
        }
        plants[0].healthBand = .urgent

        let first = try XCTUnwrap(AskPrompts.groveSuggestions(plants: plants).first)
        XCTAssertEqual(first.id, "grove-struggling")
        XCTAssertTrue(first.text.contains(plants[0].nickname))
    }

    /// Two struggling plants sharing a windowsill is the case a per-plant view
    /// can never see: the room is the patient.
    func testPlantsFailingInTheSameSpotBecomeAQuestionAboutTheSpot() throws {
        let store = GroveStore(persistenceEnabled: false)
        var plants = store.plants
        XCTAssertGreaterThan(plants.count, 1)
        for index in plants.indices {
            plants[index].healthBand = .thriving
            plants[index].location = "the study"
        }
        plants[0].healthBand = .urgent
        plants[1].healthBand = .attention

        let prompts = AskPrompts.groveSuggestions(plants: plants)
        let spot = try XCTUnwrap(prompts.first { $0.id == "grove-shared-location" })
        XCTAssertTrue(spot.text.contains("the study"))
    }

    /// The settling-in question is only true for a plant that was actually
    /// brought home recently, so it is left out entirely rather than asserted.
    func testSettlingInIsOfferedOnlyForARecentlyAddedPlant() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plants = store.plants
        let plant = try XCTUnwrap(plants.first)

        func observation(daysAgo: Int) -> PlantObservation {
            PlantObservation(
                id: UUID(),
                plantID: plant.id,
                createdAt: Date.now.addingTimeInterval(TimeInterval(-daysAgo) * 86_400),
                previousScore: 70,
                score: 72,
                band: .healthy,
                note: "",
                appearance: .same,
                soilMoisture: .comfortable,
                hasNewGrowth: true,
                photoURL: nil,
                actorName: "You"
            )
        }

        let settled = AskPrompts.groveSuggestions(plants: plants, observations: [observation(daysAgo: 400)])
        XCTAssertFalse(settled.contains { $0.id == "grove-settle-in" })

        let fresh = AskPrompts.groveSuggestions(plants: plants, observations: [observation(daysAgo: 4)])
        let prompt = try XCTUnwrap(fresh.first { $0.id == "grove-settle-in" })
        XCTAssertTrue(prompt.text.contains(plant.nickname))
        XCTAssertFalse(
            fresh.contains { $0.id == "grove-new-plant" },
            "The named version replaces the general one rather than sitting beside it"
        )
    }

    /// Onboarding makes the user name the things they get wrong. Asking for
    /// that and then ignoring it is worse than never asking.
    func testThePlanTheUserBuiltDecidesWhatIsOnTheFirstPage() throws {
        let store = GroveStore(persistenceEnabled: false)
        var plants = store.plants
        for index in plants.indices {
            plants[index].healthBand = .thriving
            plants[index].trend = .stable
            plants[index].concerns = []
        }

        var profile = UserProfile(name: "Ari", username: "ari", initials: "A", friendCount: 0)
        profile.plan = GrovePlan(focuses: ["watering"], challenge: "watering")

        let planned = AskPrompts.groveSuggestions(plants: plants, profile: profile)
        let unplanned = AskPrompts.groveSuggestions(plants: plants)
        let firstPage = Set(AskPrompts.page(planned, page: 0).map(\.id))

        XCTAssertTrue(
            firstPage.contains("grove-water-rhythm"),
            "A user who said watering is their problem should not have to page to find it"
        )
        XCTAssertEqual(
            Set(planned.map(\.id)),
            Set(unplanned.map(\.id)),
            "The plan reorders the pool; it never shrinks it"
        )
    }

    // MARK: - The four-page catalogue

    /// Every scope supplies the promised four full pages even after today's
    /// question is removed from the menu above it.
    func testEverySuggestionScopeFillsFourPages() throws {
        let store = GroveStore(persistenceEnabled: false)
        var plant = try XCTUnwrap(store.plants.first)
        plant.healthBand = .thriving
        plant.trend = .stable
        plant.concerns = []
        plant.nextActions = []

        let plantPool = AskPrompts.suggestions(for: plant)
        let beginnerPool = AskPrompts.groveSuggestions(plants: [])
        let scopes = [
            AskPrompts.curated(plantPool, excluding: plantPool.first?.id),
            AskPrompts.curated(AskPrompts.groveSuggestions(plants: store.plants)),
            AskPrompts.curated(beginnerPool, excluding: beginnerPool.first?.id)
        ]

        XCTAssertEqual(AskPrompts.suggestionLimit, 24)
        XCTAssertEqual(AskPrompts.pageCount, 4)
        for scope in scopes {
            XCTAssertEqual(scope.count, AskPrompts.suggestionLimit)
        }
    }

    /// The four pages are disjoint, full, and return to page one only after all
    /// 24 questions have been available.
    func testPaginationShowsEveryCuratedQuestionOnceBeforeWrapping() throws {
        var plant = try XCTUnwrap(GroveStore(persistenceEnabled: false).plants.first)
        plant.healthBand = .attention
        let pool = AskPrompts.curated(AskPrompts.suggestions(for: plant))
        let first = AskPrompts.page(pool, page: 0)

        XCTAssertEqual(first.map(\.id), pool.prefix(AskPrompts.pageSize).map(\.id))

        var seen = Set<String>()
        for index in 0..<AskPrompts.pageCount {
            let current = AskPrompts.page(pool, page: index)
            XCTAssertEqual(current.count, AskPrompts.pageSize, "Every page is full")
            XCTAssertTrue(seen.isDisjoint(with: current.map(\.id)), "A question appears on only one page")
            seen.formUnion(current.map(\.id))
        }
        XCTAssertEqual(seen.count, AskPrompts.suggestionLimit)
        XCTAssertEqual(AskPrompts.page(pool, page: AskPrompts.pageCount).map(\.id), first.map(\.id))
    }

    /// A pool that fits on one page is shown whole rather than rotated, so the
    /// refresh button is hidden instead of shuffling three questions forever.
    func testShortPoolIsNotRotated() {
        let pool = AskPrompts.groveSuggestions(plants: [])
        for page in 0...3 {
            XCTAssertEqual(AskPrompts.page(pool, page: page, size: pool.count + 1).map(\.id), pool.map(\.id))
        }
        XCTAssertTrue(AskPrompts.page([], page: 2).isEmpty)
    }

    /// The daily card must not change under the user between launches, and must
    /// change when the day does.
    ///
    /// Pinned to explicit times rather than `.now + 6h`: run in the evening, that
    /// offset crosses midnight and the prompt is *supposed* to rotate, so the
    /// naive version failed for the right reason at the wrong time.
    func testDailyQuestionIsStableWithinADayAndRotatesAcrossDays() throws {
        let store = GroveStore(persistenceEnabled: false)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let morning = try XCTUnwrap(calendar.date(byAdding: .hour, value: 8, to: today))
        let evening = try XCTUnwrap(calendar.date(byAdding: .hour, value: 22, to: today))
        let tomorrowMorning = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: morning))

        func prompt(at date: Date) -> AskPrompt {
            AskPrompts.daily(
                plants: store.plants,
                tasks: store.tasks,
                observations: store.observations,
                now: date
            )
        }

        XCTAssertEqual(prompt(at: morning).id, prompt(at: evening).id)
        XCTAssertNotEqual(
            prompt(at: morning).id,
            prompt(at: tomorrowMorning).id,
            "A new day should offer a new question"
        )
    }

    /// New Year and leap day are ordinary adjacent days in the rotation. The
    /// former `year * 366 + dayOfYear` seed jumped two slots after every
    /// non-leap year, which made the catalogue silently skip a question.
    func testDailyQuestionAdvancesOneSlotAcrossCalendarBoundaries() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let pool = AskPrompts.groveSuggestions(plants: [])

        func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
        }

        func position(on date: Date) throws -> Int {
            let id = AskPrompts.daily(plants: [], now: date, timeZone: timeZone).id
            return try XCTUnwrap(pool.firstIndex { $0.id == id })
        }

        let sequences = [
            [try date(2025, 12, 31), try date(2026, 1, 1)],
            [try date(2028, 2, 28), try date(2028, 2, 29), try date(2028, 3, 1)]
        ]
        for dates in sequences {
            let positions = try dates.map(position)
            for pair in zip(positions, positions.dropFirst()) {
                XCTAssertEqual(pair.1, (pair.0 + 1) % pool.count)
            }
        }
    }

    /// A Gregorian local day is independent of its duration. Spring-forward
    /// has a 23-hour day, but it still advances the question exactly once.
    func testDailyQuestionAdvancesOnceAcrossDST() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let pool = AskPrompts.groveSuggestions(plants: [])
        let dates = try [7, 8, 9].map { day in
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: 12)))
        }
        let positions = try dates.map { date in
            let id = AskPrompts.daily(plants: [], now: date, timeZone: timeZone).id
            return try XCTUnwrap(pool.firstIndex { $0.id == id })
        }

        for pair in zip(positions, positions.dropFirst()) {
            XCTAssertEqual(pair.1, (pair.0 + 1) % pool.count)
        }
    }

    /// The same instant can belong to different local dates. Supplying the
    /// active time zone makes that choice explicit and lets SwiftUI invalidate
    /// the card when the phone changes zones.
    func testDailyQuestionUsesTheSuppliedTimeZone() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let instant = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 1))
        )

        XCTAssertNotEqual(
            AskPrompts.daily(plants: [], now: instant, timeZone: utc).id,
            AskPrompts.daily(plants: [], now: instant, timeZone: losAngeles).id
        )
    }

    /// A plant in trouble beats the rotation every day, not merely on whichever
    /// day index happens to select it from the broader attention pool.
    func testDailyQuestionAlwaysPrefersTheHighestPriorityPlant() throws {
        let store = GroveStore(persistenceEnabled: false)
        var plants = Array(store.plants.prefix(2))
        XCTAssertGreaterThan(plants.count, 1)
        plants[0].healthBand = .urgent
        plants[0].trend = .stable
        plants[1].healthBand = .attention
        plants[1].trend = .declining

        let timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))
        )

        for offset in 0..<30 {
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: start))
            let prompt = AskPrompts.daily(plants: plants, now: date, timeZone: timeZone)
            XCTAssertEqual(prompt.plantID, plants[0].id)
        }
    }

    /// Plant and prompt rotation are separate cycles. With two plants, using
    /// the raw day index for both meant each plant could receive only every
    /// second prompt forever.
    func testDailyQuestionEventuallyUsesEveryPromptForEveryTiedPlant() throws {
        let store = GroveStore(persistenceEnabled: false)
        var plants = Array(store.plants.prefix(2))
        XCTAssertEqual(plants.count, 2)
        for index in plants.indices {
            plants[index].healthBand = .urgent
            plants[index].trend = .stable
        }

        let expected = Dictionary(uniqueKeysWithValues: plants.map { plant in
            (plant.id, Set(AskPrompts.suggestions(for: plant).map(\.id)))
        })
        let longestPromptCycle = expected.values.map(\.count).max() ?? 0
        var seen: [UUID: Set<String>] = [:]

        let timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))
        )
        // One extra plant cycle covers a start date that lands part-way through
        // the selector's absolute cycle.
        let horizon = plants.count * (longestPromptCycle + 1)
        for offset in 0..<horizon {
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: start))
            let prompt = AskPrompts.daily(plants: plants, now: date, timeZone: timeZone)
            let plantID = try XCTUnwrap(prompt.plantID)
            seen[plantID, default: []].insert(prompt.id)
        }

        for plant in plants {
            XCTAssertEqual(seen[plant.id], expected[plant.id])
        }
    }

    func testDailyQuestionWorksWithNoPlants() {
        let prompt = AskPrompts.daily(plants: [])
        XCTAssertNil(prompt.plantID)
        XCTAssertFalse(prompt.text.isEmpty)
    }

    // MARK: - Deleting local data

    /// "Delete my Grove data" promises that nothing Grove stored on this device
    /// survives. Conversations were stored under their own key and outlived it
    /// — and because `activate` is a no-op for an account it is already on,
    /// signing back into the same account handed the transcript straight back.
    func testDeletingLocalDataErasesConversationsAndDoesNotHandThemBack() async throws {
        let suite = "AskTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        let client = StubBotanistClient()
        let session = AskSession(client: client, storage: storage)
        session.activate(accountID: "acct-ask")
        _ = await session.ask("Why is it drooping?", context: nil, hasPremium: true)
        XCTAssertFalse(session.recentThreads.isEmpty, "The conversation has to exist before it can be deleted")

        session.deleteAllLocalData()

        XCTAssertTrue(session.threads.isEmpty)

        // The same account signs back in on the same device.
        session.activate(accountID: "acct-ask")
        XCTAssertTrue(session.threads.isEmpty, "A deleted conversation must not come back with the account")
    }

    // MARK: - Answer formatting

    /// The reply the coach actually writes, markers and all.
    private static let markdownReply = """
    ### What's going on

    Fiddle leaf figs drop leaves for **three** main reasons:

    1. **Overwatering** — the most common cause.
    2. *Light* — it needs bright, indirect light.

    - Check the soil first.
    * Then check the draughts.

    ```
    not a code sample
    ```

    > Recheck in 7 days.
    """

    /// The defect this whole file guards: `Text(String)` renders verbatim, so
    /// every marker reached the user as literal punctuation.
    func testNoMarkdownSyntaxSurvivesToTheScreen() {
        let shown = String(BotanistFormatting.attributed(Self.markdownReply).characters)
        for marker in ["**", "###", "```", "> ", "- ", "* "] {
            XCTAssertFalse(shown.contains(marker), "\(marker) reached the screen as literal text")
        }
        XCTAssertFalse(BotanistFormatting.plain(Self.markdownReply).contains("*"))
    }

    /// Stripping the markers is only half the job — the emphasis they encoded
    /// has to survive as actual styling.
    func testEmphasisBecomesStylingRatherThanBeingDropped() {
        let attributed = BotanistFormatting.attributed(Self.markdownReply)
        let bold = attributed.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false
        }
        XCTAssertTrue(bold, "**three** should be bold, not plain")
        XCTAssertTrue(
            String(attributed.characters).contains("three"),
            "The emphasised word itself must remain"
        )
    }

    /// Content survives, including the words the markers were wrapped around.
    func testTheAnswersWordsAllSurvive() {
        let shown = BotanistFormatting.plain(Self.markdownReply)
        for phrase in ["What's going on", "Overwatering", "Check the soil first", "Recheck in 7 days"] {
            XCTAssertTrue(shown.contains(phrase), "Lost: \(phrase)")
        }
        XCTAssertTrue(shown.contains("•"), "Bullets should become a glyph, not vanish")
    }

    /// Line structure is the difference between three steps and one paragraph.
    func testLineBreaksBetweenStepsAreKept() {
        let shown = BotanistFormatting.plain(Self.markdownReply)
        XCTAssertTrue(shown.contains("\n"))
        XCTAssertFalse(shown.contains("\n\n\n"), "Runs of blank lines are padding, not structure")
    }

    /// A model mid-sentence, a stray marker, an empty reply: none of these may
    /// cost the user the answer they spent a question on.
    func testMalformedMarkdownNeverSwallowsTheAnswer() {
        let ragged = "**Water it now\n\n# \n***\nUnclosed *italic and a [link](https://example.com)"
        let shown = BotanistFormatting.plain(ragged)
        XCTAssertTrue(shown.contains("Water it now"))
        XCTAssertTrue(shown.contains("link"))
        XCTAssertFalse(shown.isEmpty)

        XCTAssertTrue(BotanistFormatting.plain("").isEmpty)
        XCTAssertEqual(BotanistFormatting.plain("Just a plain sentence."), "Just a plain sentence.")
    }

    func testModelAuthoredLinksKeepTheirWordsButNeverBecomeTapTargets() {
        let attributed = BotanistFormatting.attributed(
            "Read [this source](https://attacker.example/path) or <https://second.example>."
        )

        XCTAssertTrue(String(attributed.characters).contains("this source"))
        XCTAssertFalse(attributed.runs.contains { $0.link != nil })
    }

    /// The output ceiling and the renderer interact: a reply cut off at the token
    /// cap can end mid-emphasis, and markdown treats an unclosed marker as
    /// literal — so the cap that stops essays would put asterisks back on screen.
    func testAReplyTruncatedMidEmphasisShowsNoAsterisks() {
        let truncated = "Water it now. The reason is that **soggy roots can't brea"
        let shown = BotanistFormatting.plain(truncated)
        XCTAssertFalse(shown.contains("*"))
        XCTAssertTrue(shown.hasSuffix("soggy roots can't brea"), "The words must survive the closing")

        XCTAssertFalse(BotanistFormatting.plain("- Check the **top 5cm of so").contains("*"))
        // A lone asterisk is more often arithmetic than an unclosed italic.
        XCTAssertEqual(
            BotanistFormatting.plain("Feed at half strength, 5*5 dilution."),
            "Feed at half strength, 5*5 dilution."
        )
    }
}
