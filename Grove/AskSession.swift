import Foundation
import Observation

/// Owns the botanist conversations and the free-question meter.
///
/// Deliberately knows nothing about `GroveStore`: it takes the grounding context
/// as a string and hands back an answer, so the streak, quests and XP stay in
/// one place (the store) and the meter can be tested without a grove.
@MainActor
@Observable
final class AskSession {
    /// Questions a free account gets each day.
    ///
    /// Daily rather than monthly on purpose. One question a day is the habit
    /// Grove wants — it is what tends the plant-safe streak — so the free tier
    /// has to cover it comfortably or the streak becomes a paywall, which would
    /// be both hostile and a retention own-goal. Three leaves room for a
    /// follow-up and a second plant; the wall lands on the fourth question,
    /// which is a real conversation, not the daily habit.
    static let freeAsksPerDay = 3
    /// Matches the Edge Function's JavaScript string-length boundary. Count
    /// UTF-16 units rather than Swift graphemes so emoji and composed characters
    /// cannot pass locally and then fail at the gateway.
    static let maxQuestionCharacters = 1_000
    /// Matches the Botanist gateway and the scan pipeline. The composer
    /// re-encodes selected photos below this before they reach the session.
    static let maxPhotoBytes = 2 * 1024 * 1024

    /// Conversations kept on device. Old threads are the user's own record of
    /// what they asked, so the cap is generous.
    private static let maxStoredThreads = 40

    enum Outcome: Equatable {
        case answered
        /// The day's free questions are spent and the account has no premium.
        case needsPremium
        case failed(message: String)
    }

    private(set) var threads: [BotanistThread] = []
    /// Conversations waiting on answers. More than one thread can be open while
    /// a request is suspended, so this must be a set: one global id caused a
    /// second conversation to steal the first one's thinking state, then clearing
    /// either request made the other look idle while it was still in flight.
    private var answeringThreadIDs: Set<UUID> = []
    /// Why the last question in each conversation failed, if it did. Transient and
    /// per-session: shown in that conversation with a retry, not stored as history.
    private(set) var failures: [UUID: String] = [:]

    /// True while any answer is in flight — for the tab root, which offers to
    /// start a question rather than watching a particular one.
    var isAnswering: Bool { !answeringThreadIDs.isEmpty }

    func isAnswering(in threadID: UUID) -> Bool { answeringThreadIDs.contains(threadID) }

    func failureMessage(in threadID: UUID) -> String? { failures[threadID] }

    /// Photos Ari will quietly carry into the next turn of this conversation.
    /// The view uses only the count; loading and failure policy stay here in the
    /// session so the composer never performs file I/O or networking work.
    func reusablePhotoCount(in threadID: UUID) -> Int {
        guard let thread = thread(id: threadID) else { return 0 }
        return thread.messages
            .reversed()
            .filter { $0.role == .user && $0.photoURL != nil }
            .prefix(2)
            .count
    }
    /// Free questions already asked today. Reset lazily on the first read or
    /// write of a new day, so a session left open overnight still rolls over.
    private(set) var asksToday = 0

    /// A question raised on the tab root and handed to the conversation screen to
    /// actually send, so exactly one place performs an ask. Transient: if the app
    /// dies between the tap and the send, nothing was charged and nothing is owed.
    struct PendingQuestion: Equatable {
        let question: String
        let photoData: Data?
    }

    private var pendingQuestions: [UUID: PendingQuestion] = [:]

    /// Readable so tests can pin the stamp's shape — a midnight stamp is the
    /// bug, not an implementation detail.
    private(set) var meterDay: Date?
    /// The reset the gateway last reported. Not persisted: it is derivable from
    /// the UTC day, so a relaunch recomputes the same instant rather than
    /// restoring a stale one from a previous day.
    private var serverResetsAt: Date?
    private var activeAccountID: String?
    private var persistenceKey: String?
    private var attachmentRootURL: URL?
    /// Distinguishes two lifetimes of the same account. Comparing only the
    /// account id lets a request started before sign-out land after a rapid
    /// sign-out/sign-in cycle back into the newly loaded transcript.
    private var lifecycleGeneration: UInt64 = 0
    private let storage: UserDefaults
    private let client: any BotanistClient

    init(client: any BotanistClient = LocalBotanistClient(), storage: UserDefaults = .standard) {
        self.client = client
        self.storage = storage
    }

    // MARK: - Account lifecycle

    func activate(accountID: String) {
        guard activeAccountID != accountID else { return }
        lifecycleGeneration &+= 1
        activeAccountID = accountID
        persistenceKey = Self.storageKey(for: accountID)
        attachmentRootURL = AccountStorage.mediaRootURL(for: accountID)
            .appendingPathComponent("Botanist", isDirectory: true)
        threads = []
        asksToday = 0
        meterDay = nil
        serverResetsAt = nil
        failures = [:]
        answeringThreadIDs = []
        // Queued launcher questions are transient account state too. Keeping
        // this dictionary across an account switch allowed a still-mounted old
        // navigation destination to claim account A's question under account B.
        pendingQuestions = [:]
        if let key = persistenceKey,
           let data = storage.data(forKey: key),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            threads = snapshot.threads
            // UserDefaults can be restored from an older build or damaged. Keep
            // arithmetic total and bounded instead of trusting a negative or
            // Int.min value that can overflow the remaining-count calculation.
            asksToday = max(0, min(Self.freeAsksPerDay, snapshot.asksToday))
            meterDay = snapshot.meterDay
            sanitizeStoredThreads()
            trimStoredThreads()
        }
        rollMeterDayIfNeeded()
        // Commit any repaired meter value, trimmed history, invalid attachment
        // URL removal, or day rollover instead of making the next launch repair
        // the same snapshot again.
        persist()
    }

    /// Removes the signed-out account's transcript and quota from process
    /// memory without deleting its protected on-device history. Reactivating
    /// that same account reloads the snapshot; a signed-out or onboarding view
    /// cannot accidentally observe the previous person's conversations.
    func deactivate() {
        lifecycleGeneration &+= 1
        activeAccountID = nil
        persistenceKey = nil
        attachmentRootURL = nil
        threads = []
        asksToday = 0
        meterDay = nil
        serverResetsAt = nil
        failures = [:]
        answeringThreadIDs = []
        pendingQuestions = [:]
    }

    // MARK: - Meter

    /// Free questions left today. Premium accounts are unmetered.
    func remainingFreeAsks(hasPremium: Bool) -> Int {
        if hasPremium { return .max }
        rollMeterDayIfNeeded()
        return max(0, Self.freeAsksPerDay - asksToday)
    }

    func canAsk(hasPremium: Bool) -> Bool {
        hasPremium || remainingFreeAsks(hasPremium: false) > 0
    }

    /// When the free questions come back, in the user's own time.
    ///
    /// The gateway's own value when it has sent one, and the same calculation it
    /// uses otherwise, so a first-launch paywall can still name a time instead of
    /// saying "tomorrow" and being wrong by half a day.
    var freeAsksResetAt: Date {
        serverResetsAt ?? Self.nextUTCDayStart()
    }

    /// Adopts the gateway's count of today's free questions.
    ///
    /// The local meter is an optimistic mirror so the composer can show a number
    /// without a round trip; the server owns the decision, and this is where the
    /// two are reconciled. It fixes the cases a device-local count cannot: the
    /// same account asking from a second device, a subscription bought or lapsed
    /// since launch, a clock or time zone that disagrees with UTC, and a stored
    /// count edited on a jailbroken device.
    private func applyServerQuota(_ quota: BotanistAskQuota) {
        rollMeterDayIfNeeded()
        guard quota.metered else {
            // Premium, or Grove's pre-launch early access. Nothing is owed, and
            // leaving yesterday's spent count behind would put the wall straight
            // back up if the subscription lapsed later in the same session.
            asksToday = 0
            return
        }
        // Derived from `remaining` rather than `used` so the number the app draws
        // stays inside its own bounds even if the server's allowance changes: a
        // larger server limit shows a full local meter, never a negative one.
        let remaining = quota.remaining ?? max(0, Self.freeAsksPerDay - quota.used)
        asksToday = max(0, min(Self.freeAsksPerDay, Self.freeAsksPerDay - remaining))
        if let resetsAt = quota.resetsAt { serverResetsAt = resetsAt }
    }

    /// The gateway refused the question because the allowance is spent. Whatever
    /// the local count said, it was wrong and low.
    private func markAllowanceSpent() {
        rollMeterDayIfNeeded()
        asksToday = Self.freeAsksPerDay
    }

    /// Clears yesterday's count the first time today's meter is touched.
    ///
    /// The day is the UTC day, because the gateway counts in UTC and the gateway
    /// is what refuses the fourth question. A device-local day cannot be used for
    /// this: it would have to come from the device, and a meter that resets when
    /// the device says so resets whenever someone changes their time zone. The
    /// visible cost is that the reset is not local midnight, which is why the
    /// paywall names the actual time rather than saying "tomorrow" — in New
    /// Zealand "tomorrow" would have been wrong by twelve hours.
    ///
    /// Stamped at midday UTC so a stored value cannot land on the neighbouring
    /// day when it is read back. Local-midday stamps written by earlier builds
    /// still compare correctly and are upgraded the next time this writes.
    private func rollMeterDayIfNeeded(on date: Date = .now) {
        guard meterDay == nil || !Self.isSameUTCDay(meterDay!, date) else { return }
        meterDay = Self.dayStamp(for: date)
        asksToday = 0
        serverResetsAt = nil
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private static func isSameUTCDay(_ first: Date, _ second: Date) -> Bool {
        utcCalendar.isDate(first, inSameDayAs: second)
    }

    private static func dayStamp(for date: Date) -> Date {
        let calendar = utcCalendar
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date)
            ?? calendar.startOfDay(for: date)
    }

    static func nextUTCDayStart(after date: Date = .now) -> Date {
        let calendar = utcCalendar
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }

    // MARK: - Threads

    func thread(id: UUID) -> BotanistThread? {
        threads.first { $0.id == id }
    }

    /// The conversations to show in the recents list, newest first. Threads with
    /// no answer yet are drafts the user abandoned, so they stay out of it.
    var recentThreads: [BotanistThread] {
        threads
            .filter { !$0.messages.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Opens an empty conversation for the user to type into.
    @discardableResult
    func startDraftThread(plantID: UUID?) -> BotanistThread {
        let thread = BotanistThread(plantID: plantID)
        threads.append(thread)
        return thread
    }

    /// Opens a conversation with a question already chosen, for the screen it
    /// pushes to send. Returns the new thread's id.
    func queue(_ question: String, plantID: UUID?, photoData: Data? = nil) -> UUID {
        let thread = startDraftThread(plantID: plantID)
        pendingQuestions[thread.id] = PendingQuestion(question: question, photoData: photoData)
        return thread.id
    }

    /// Claims a queued question exactly once, so a view that re-runs its task
    /// (a scroll, a state change) cannot send it twice.
    func takePendingQuestion(for threadID: UUID) -> PendingQuestion? {
        pendingQuestions.removeValue(forKey: threadID)
    }

    /// Drops an empty conversation the user backed out of without asking.
    func discardIfEmpty(threadID: UUID) {
        guard let thread = thread(id: threadID), thread.messages.isEmpty else { return }
        pendingQuestions.removeValue(forKey: threadID)
        failures.removeValue(forKey: threadID)
        threads.removeAll { $0.id == threadID }
    }

    /// The question to resend after a failure: the last user turn that never got
    /// an answer.
    func unansweredQuestion(in threadID: UUID) -> String? {
        guard let thread = thread(id: threadID),
              let last = thread.messages.last,
              last.role == .user else { return nil }
        return last.text
    }

    func clearFailure(in threadID: UUID) {
        failures.removeValue(forKey: threadID)
    }

    // MARK: - Asking

    /// Sends a question, appending both turns to a thread.
    ///
    /// The question is appended before the request so the conversation reflects
    /// the tap immediately, and a failure leaves it standing rather than
    /// swallowing what the user typed — `unansweredQuestion(in:)` finds it again
    /// for a retry.
    ///
    /// Returns the thread id alongside the outcome so a caller starting a new
    /// conversation knows where to navigate.
    @discardableResult
    func ask(
        _ question: String,
        in threadID: UUID? = nil,
        plantID: UUID? = nil,
        context: String?,
        photoData: Data? = nil,
        hasPremium: Bool
    ) async -> (outcome: Outcome, threadID: UUID) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetID = threadID ?? UUID()
        guard !trimmed.isEmpty else { return (.failed(message: "Type a question first."), targetID) }
        guard trimmed.utf16.count <= Self.maxQuestionCharacters else {
            return (
                .failed(message: "That question is a little long. Trim it down and try again."),
                targetID
            )
        }
        // A spent free allowance still gets one server-bounded policy probe.
        // The gateway answers recognized ingestion/exposure emergencies without
        // a provider and rejects every routine question before doing paid work.
        let safetyOnly = !canAsk(hasPremium: hasPremium)
        guard !answeringThreadIDs.contains(targetID) else {
            return (.failed(message: "Ari is already answering that conversation."), targetID)
        }
        if let photoData, (photoData.isEmpty || photoData.count > Self.maxPhotoBytes) {
            return (.failed(message: "Choose a photo smaller than 2 MB and try again."), targetID)
        }

        let index = indexOfThread(id: targetID, plantID: plantID)
        // A retry after a failure finds its question still standing as the last
        // turn; appending it again would show the user asking twice.
        let last = threads[index].messages.last
        let isRetry = last?.role == .user && last?.text == trimmed
        var appendedMessageID: UUID?
        var requestPhotoData = photoData
        if isRetry {
            // The gateway uses the user-message UUID as its idempotency key. A
            // retry therefore has to preserve the exact visual evidence tied to
            // that UUID; swapping or adding a photo could replay the answer for
            // the original request against a different image.
            if let photoURL = last?.photoURL {
                guard let savedData = loadPhoto(at: photoURL) else {
                    return (
                        .failed(message: "That retry's original photo is no longer available. Ask a new question and attach the photo again."),
                        targetID
                    )
                }
                guard photoData == nil || photoData == savedData else {
                    return (
                        .failed(message: "A retry must use the original photo. Ask a new question to use different evidence."),
                        targetID
                    )
                }
                requestPhotoData = savedData
            } else if photoData != nil {
                return (
                    .failed(message: "A retry can't add new evidence. Ask a new question to include that photo."),
                    targetID
                )
            }
        } else {
            var photoURL: URL?
            if let photoData {
                do {
                    photoURL = try savePhoto(photoData)
                } catch {
                    return (.failed(message: "Grove couldn't save that photo. Try another one."), targetID)
                }
            }
            let message = BotanistMessage(role: .user, text: trimmed, photoURL: photoURL)
            appendedMessageID = message.id
            threads[index].messages.append(message)
        }
        threads[index].updatedAt = .now

        guard let currentMessage = threads[index].messages.last,
              currentMessage.role == .user else {
            let message = "Grove couldn't prepare that question. Try again."
            failures[targetID] = message
            persist()
            return (.failed(message: message), targetID)
        }
        var photoAttachments: [BotanistPhotoAttachment] = []
        if !safetyOnly, let requestPhotoData {
            photoAttachments.append(
                BotanistPhotoAttachment(messageID: currentMessage.id, data: requestPhotoData)
            )
        }
        var hadEarlierPhotoCandidate = false
        var newestEarlierPhotoMissing = false
        for message in threads[index].messages.reversed()
        where photoAttachments.count < 2 && message.id != currentMessage.id {
            guard !safetyOnly else { break }
            guard message.role == .user, let photoURL = message.photoURL else { continue }
            let isNewestEarlierPhoto = !hadEarlierPhotoCandidate
            hadEarlierPhotoCandidate = true
            // A missing old file should not block a newly attached, valid
            // photo. Keep looking for another usable comparison image, while
            // remembering that a photo-only follow-up must fail explicitly
            // instead of silently dropping the newest visual context.
            guard let data = loadPhoto(at: photoURL) else {
                if isNewestEarlierPhoto { newestEarlierPhotoMissing = true }
                continue
            }
            photoAttachments.append(BotanistPhotoAttachment(messageID: message.id, data: data))
        }
        if !safetyOnly
            && requestPhotoData == nil
            && hadEarlierPhotoCandidate
            && (photoAttachments.isEmpty || newestEarlierPhotoMissing) {
            let message = "An earlier photo in this conversation is no longer available. Add it again to continue with photo-aware advice."
            failures[targetID] = message
            trimStoredThreads()
            persist()
            return (.failed(message: message), targetID)
        }
        // Gemini receives comparison photos oldest-to-newest so words such as
        // “better” and “worse” have an unambiguous visual direction.
        photoAttachments.reverse()

        // Counted on send, not on success: the request costs provider tokens the
        // moment it leaves, and a failure refunds it below. A premium ask never
        // touches the free allowance; otherwise a subscription expiring later in
        // the same day could reveal that all three "free" asks had already been
        // consumed while the account was meant to be unmetered.
        rollMeterDayIfNeeded()
        let chargedMeterDay: Date?
        if hasPremium || safetyOnly {
            chargedMeterDay = nil
        } else {
            asksToday += 1
            chargedMeterDay = meterDay
        }
        let requestAccountID = activeAccountID
        let requestGeneration = lifecycleGeneration
        answeringThreadIDs.insert(targetID)
        failures.removeValue(forKey: targetID)
        persist()

        defer { answeringThreadIDs.remove(targetID) }
        do {
            let answer = try await client.ask(
                conversation: threads[index].messages,
                plantContext: context,
                plantID: threads[index].plantID,
                threadID: targetID,
                photoAttachments: photoAttachments,
                safetyOnly: safetyOnly
            )
            guard activeAccountID == requestAccountID,
                  lifecycleGeneration == requestGeneration else {
                return (.failed(message: "That question was cancelled."), targetID)
            }
            // Reconciled before the thread lookup below: the question was
            // answered and charged whether or not its conversation still exists
            // to receive it, and a discarded answer must not leave the meter
            // reading one question higher than the gateway will.
            if let quota = answer.quota, meterDay == chargedMeterDay ?? meterDay {
                applyServerQuota(quota)
            }
            guard let settled = threads.firstIndex(where: { $0.id == targetID }) else {
                // Deleting a conversation while its network request is in
                // flight is a cancellation, not an invisible success. Reporting
                // `.answered` here awarded streak/quest progress for an answer
                // that was discarded and could never be read.
                persist()
                return (.failed(message: "That question was cancelled."), targetID)
            }
            if let visualEvidence = answer.visualEvidence,
               let userMessage = threads[settled].messages.lastIndex(where: { $0.role == .user }) {
                threads[settled].messages[userMessage].visualEvidence = visualEvidence
            }
            threads[settled].messages.append(
                BotanistMessage(
                    role: .botanist,
                    text: answer.reply,
                    adviceID: answer.adviceID,
                    disposition: answer.disposition,
                    confidence: answer.confidence,
                    followUpAt: answer.followUpAt,
                    sources: answer.sources,
                    verification: answer.verification,
                    provider: answer.provider,
                    model: answer.model
                )
            )
            threads[settled].updatedAt = .now
            trimStoredThreads()
            persist()
            return (.answered, targetID)
        } catch BotanistClientPolicyError.premiumRequired {
            guard activeAccountID == requestAccountID,
                  lifecycleGeneration == requestGeneration else {
                return (.failed(message: "That question was cancelled."), targetID)
            }
            // The gateway is the authority on the allowance, and it just said
            // there is none left. That can arrive on a question this device
            // believed was free — the same account asking from a second device,
            // or a stored count that drifted — so the local meter is corrected
            // to match rather than left showing questions that do not exist.
            markAllowanceSpent()
            // A routine safety-only probe was never a committed question: it
            // called no provider and consumed no allowance. Remove the turn we
            // optimistically displayed (and its protected photo) before opening
            // the paywall. A genuine retry keeps its pre-existing user turn.
            if let appendedMessageID,
               let settled = threads.firstIndex(where: { $0.id == targetID }),
               let messageIndex = threads[settled].messages.firstIndex(
                   where: { $0.id == appendedMessageID }
               ) {
                removePhoto(at: threads[settled].messages[messageIndex].photoURL)
                threads[settled].messages.remove(at: messageIndex)
                threads[settled].updatedAt = .now
            }
            failures.removeValue(forKey: targetID)
            trimStoredThreads()
            persist()
            return (.needsPremium, targetID)
        } catch {
            // An account switch owns different threads and a different meter.
            // Likewise, an ask sent before midnight must not refund a new day's
            // first question if it happens to fail after the meter rolls over.
            guard activeAccountID == requestAccountID,
                  lifecycleGeneration == requestGeneration else {
                return (.failed(message: "That question was cancelled."), targetID)
            }
            if let chargedMeterDay, meterDay == chargedMeterDay {
                asksToday = max(0, asksToday - 1)
            }
            let message = Self.message(for: error)
            failures[targetID] = message
            trimStoredThreads()
            persist()
            return (.failed(message: message), targetID)
        }
    }

    /// Records immediate usefulness or the plant's later result against the
    /// durable server-side advice record. The message changes only after the
    /// server accepts it, so a failed connection never presents feedback as
    /// saved when it was not.
    @discardableResult
    func recordOutcome(
        _ outcome: BotanistOutcome,
        for messageID: UUID,
        in threadID: UUID
    ) async -> Bool {
        guard let threadIndex = threads.firstIndex(where: { $0.id == threadID }),
              let messageIndex = threads[threadIndex].messages.firstIndex(where: { $0.id == messageID }),
              let adviceID = threads[threadIndex].messages[messageIndex].adviceID else {
            return false
        }
        do {
            try await client.recordOutcome(adviceID: adviceID, outcome: outcome)
            guard let settledThread = threads.firstIndex(where: { $0.id == threadID }),
                  let settledMessage = threads[settledThread].messages.firstIndex(
                    where: { $0.id == messageID }
                  ) else {
                return true
            }
            threads[settledThread].messages[settledMessage].recordedOutcome = outcome
            persist()
            return true
        } catch {
            return false
        }
    }

    /// Erases every conversation this device holds for the active account and
    /// forgets the account itself.
    ///
    /// Part of "Delete my Grove data". The store's own wipe never reached here,
    /// so a screen promising that "nothing Grove stored on this device
    /// survives" left a full transcript of what the user asked about their home
    /// and their plants in `UserDefaults` — and because `activate` is a no-op
    /// for an account it is already on, signing back into the same account
    /// handed the conversations straight back.
    func deleteAllLocalData() {
        lifecycleGeneration &+= 1
        if let persistenceKey { storage.removeObject(forKey: persistenceKey) }
        if let attachmentRootURL { try? FileManager.default.removeItem(at: attachmentRootURL) }
        threads = []
        failures = [:]
        pendingQuestions = [:]
        answeringThreadIDs = []
        asksToday = 0
        meterDay = nil
        serverResetsAt = nil
        activeAccountID = nil
        persistenceKey = nil
        attachmentRootURL = nil
    }

    /// Drops a thread the user no longer wants kept.
    func delete(threadID: UUID) {
        let removed = threads.first { $0.id == threadID }
        removePhotos(in: removed.map { [$0] } ?? [])
        threads.removeAll { $0.id == threadID }
        failures.removeValue(forKey: threadID)
        persist()
    }

    private func indexOfThread(id: UUID, plantID: UUID?) -> Int {
        if let existing = threads.firstIndex(where: { $0.id == id }) { return existing }
        threads.append(BotanistThread(id: id, plantID: plantID))
        return threads.count - 1
    }

    private func trimStoredThreads() {
        guard threads.count > Self.maxStoredThreads else { return }
        let previous = threads
        // Drafts are conversations the user may be typing into right now, so the
        // cap only applies to answered ones — trimming by recency alone would
        // delete an open composer out from under them.
        let drafts = threads.filter { $0.messages.isEmpty }
        let answered = threads
            .filter { !$0.messages.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.maxStoredThreads)
        threads = drafts + answered
        // Failures belong to conversations; the ones just trimmed away have none.
        let kept = Set(threads.map(\.id))
        failures = failures.filter { kept.contains($0.key) }
        removePhotos(in: previous.filter { !kept.contains($0.id) })
    }

    private func savePhoto(_ data: Data) throws -> URL {
        guard let attachmentRootURL else { throw ScanMediaError.couldNotSave }
        try FileManager.default.createDirectory(
            at: attachmentRootURL,
            withIntermediateDirectories: true
        )
        let url = attachmentRootURL.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        return url
    }

    private func removePhotos(in threads: [BotanistThread]) {
        for thread in threads {
            for message in thread.messages {
                removePhoto(at: message.photoURL)
            }
        }
    }

    private func removePhoto(at url: URL?) {
        guard let url, isManagedPhotoURL(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// A transcript contains file URLs, so treat a decoded URL as untrusted. A
    /// restored or modified preferences file must never make a follow-up upload,
    /// or a delete operation remove, some other file in the app container.
    private func isManagedPhotoURL(_ url: URL) -> Bool {
        guard url.isFileURL, let attachmentRootURL else { return false }
        let root = attachmentRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        return candidate.deletingLastPathComponent() == root
    }

    private func loadPhoto(at url: URL) -> Data? {
        guard isManagedPhotoURL(url),
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              data.count <= Self.maxPhotoBytes else { return nil }
        return data
    }

    private func sanitizeStoredThreads() {
        for threadIndex in threads.indices {
            for messageIndex in threads[threadIndex].messages.indices {
                let url = threads[threadIndex].messages[messageIndex].photoURL
                if let url, !isManagedPhotoURL(url) {
                    threads[threadIndex].messages[messageIndex].photoURL = nil
                }
            }
        }
    }

    private static func message(for error: Error) -> String {
        if error is CancellationError { return "That question was cancelled." }
        // `errorDescription` already prefers the gateway's own wording — a spent
        // ceiling, a stalled provider — over anything mapped from a status code,
        // and that wording is the whole reason the gateway bounds its own wait
        // rather than leaving the app to time out and guess.
        if let apiError = error as? APIError {
            return apiError.errorDescription ?? "Ari couldn't answer that. Try again."
        }
        return "Ari couldn't answer that. Try again."
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var threads: [BotanistThread]
        var asksToday: Int
        var meterDay: Date?
    }

    /// An account's saved conversations, read from disk without activating
    /// a session. For the data export, which runs whether or not Ask has been
    /// opened this launch. Photo references outside the account's own Ask
    /// folder are dropped, as `sanitizeStoredThreads` does on activation.
    static func storedThreads(accountID: String, storage: UserDefaults = .standard) -> [BotanistThread] {
        guard let data = storage.data(forKey: storageKey(for: accountID)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return [] }
        let root = AccountStorage.mediaRootURL(for: accountID)
            .appendingPathComponent("Botanist", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        var threads = snapshot.threads
        for threadIndex in threads.indices {
            for messageIndex in threads[threadIndex].messages.indices {
                guard let url = threads[threadIndex].messages[messageIndex].photoURL else { continue }
                let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
                if !url.isFileURL || candidate.deletingLastPathComponent() != root {
                    threads[threadIndex].messages[messageIndex].photoURL = nil
                }
            }
        }
        return threads
    }

    private static func storageKey(for accountID: String) -> String {
        "grove.ask.v1.account.\(AccountStorage.namespace(for: accountID))"
    }

    private func persist() {
        guard let key = persistenceKey else { return }
        // Drafts are in-session state, not history: an empty conversation is worth
        // nothing after a relaunch.
        let snapshot = Snapshot(
            threads: threads.filter { !$0.messages.isEmpty },
            asksToday: asksToday,
            meterDay: meterDay
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        storage.set(data, forKey: key)
    }
}
