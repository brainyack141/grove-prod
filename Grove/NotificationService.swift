import Foundation
import Observation
import UIKit
@preconcurrency import UserNotifications

/// Every word Grove puts on a lock screen.
///
/// A reminder is the only place Grove speaks to someone who is not holding the
/// app, so it carries more of the product's character than any screen — and
/// more of its risk. Three rules hold this file together (see `COPY.md`):
///
/// 1. **Name the plant.** "Pesto is due a photo" is a message about something
///    the user loves; "1 plant needs a check-in" is a chore from an app.
/// 2. **Never instruct a blind watering.** Grove has not felt the soil, so a
///    reminder can only ever ask someone to *look*. Getting this wrong drowns
///    plants, which is the single most common way houseplants die.
/// 3. **No guilt.** Overdue is stated as a fact and paired with how little
///    effort the fix takes. Grove never scolds and never counts misses.
///
/// Lines vary per plant so the same sentence does not arrive every fortnight,
/// but the variant is derived from the task's own identifier rather than a
/// random draw: the notification set is rebuilt on every launch, completion and
/// snooze, and a reminder whose wording changed underneath the user would read
/// as a second, different reminder.
enum GroveReminderCopy {
    struct Reminder {
        let title: String
        let body: String
    }

    /// Stable 0..<count selector derived from a UUID's own bytes.
    /// `hashValue` is seeded per process and would reshuffle every launch.
    private static func variant(_ id: UUID, of count: Int) -> Int {
        let bytes = id.uuid
        let mixed = Int(bytes.0) &+ Int(bytes.7) &* 31 &+ Int(bytes.15) &* 131
        return abs(mixed) % max(1, count)
    }

    static func forCare(task: CareTask, plant: Plant) -> Reminder {
        let name = plant.nickname
        let overdue = task.dueDate < Calendar.current.startOfDay(for: .now)
        let pick = variant(task.id, of: 3)

        switch task.kind {
        case .checkIn:
            let titles = [
                "How's \(name) doing?",
                "\(name) is due a photo",
                "Time to check in on \(name)"
            ]
            let body = overdue
                ? "The last photo is a while old now. One minute and you're back on track."
                : "One fresh photo, compared with the last one. Takes about a minute."
            return Reminder(title: titles[pick], body: body)

        case .water:
            // Never "water Pesto" — Grove has not felt the soil. The ask is the
            // check; the watering is the user's call once they have.
            let titles = [
                "Feel \(name)'s soil",
                "Check \(name) before you water",
                "Is \(name) actually thirsty?"
            ]
            return Reminder(
                title: titles[pick],
                body: "Two knuckles into the soil. Water only if it comes out dry. If it's damp, \(name) can wait."
            )

        case .fertilise:
            return Reminder(title: "Feeding check for \(name)", body: task.detail)

        case .inspectSoil:
            return Reminder(
                title: "Check in on \(name)",
                body: "One fresh photo, set beside the last one."
            )

        case .cleanLeaves:
            return Reminder(title: "Clean \(name)'s leaves", body: task.detail)

        case .treat:
            return Reminder(
                title: "\(name)'s treatment is due",
                body: overdue
                    ? "Treatments only work on schedule. Check the symptom is still there, then carry on with the plan."
                    : task.detail
            )

        case .prune:
            return Reminder(
                title: "\(name) has some tidying to do",
                body: task.detail
            )

        case .rotate:
            let titles = [
                "Give \(name) a quarter turn",
                "\(name) is leaning again"
            ]
            return Reminder(
                title: titles[variant(task.id, of: titles.count)],
                body: "Ten seconds. It keeps growth even instead of all reaching one way."
            )

        case .repot:
            return Reminder(title: "Review \(name)'s pot", body: task.detail)
        case .relocate:
            return Reminder(title: "Review \(name)'s new spot", body: task.detail)
        case .monitor:
            return Reminder(title: "Look for change in \(name)", body: task.detail)
        }
    }

    /// The one follow-up a missed reminder gets, three days on.
    ///
    /// Grove used to say nothing at all after the first banner, so a single
    /// distracted morning cost a plant its whole care loop — the app went quiet
    /// until the *next* task came round, which for a fortnightly check-in is two
    /// more weeks of silence.
    ///
    /// Rule 3 does the most work here. This line never counts the miss, never
    /// says "still", and never implies the user let anything down: it re-states
    /// the ask and how small it is. Anyone who wanted to skip it has already
    /// skipped it once, which is why there is exactly one of these and never a
    /// third.
    static func forOverdue(task: CareTask, plant: Plant) -> Reminder {
        let name = plant.nickname
        switch task.kind {
        case .checkIn:
            return Reminder(
                title: "\(name)'s check-in is open",
                body: "Whenever you're next past it. One photo is the whole job."
            )
        case .water:
            return Reminder(
                title: "Worth feeling \(name)'s soil",
                body: "Two knuckles in. Dry means water, damp means \(name) is fine as it is."
            )
        case .fertilise:
            return Reminder(title: "\(name)'s feeding check is open", body: task.detail)
        case .inspectSoil:
            return Reminder(
                title: "\(name)'s check-in is open",
                body: "One fresh photo shows how it's doing."
            )
        case .cleanLeaves:
            return Reminder(title: "\(name)'s leaf clean is open", body: task.detail)
        case .treat:
            return Reminder(
                title: "\(name)'s treatment is open",
                body: "Check whether the symptom has moved, then pick the plan back up."
            )
        case .prune:
            return Reminder(
                title: "\(name)'s trim is open",
                body: task.detail
            )
        case .rotate:
            return Reminder(
                title: "\(name) could use a quarter turn",
                body: "Ten seconds. It keeps growth even instead of all reaching one way."
            )
        case .repot:
            return Reminder(title: "\(name)'s pot review is open", body: task.detail)
        case .relocate:
            return Reminder(title: "Check \(name)'s new spot", body: task.detail)
        case .monitor:
            return Reminder(title: "Check \(name)'s progress", body: task.detail)
        }
    }

    static func forSitting(_ assignment: SittingAssignment, now: Date = .now) -> Reminder {
        let count = assignment.plantIDs.count
        let plants = "\(count) \(count == 1 ? "plant" : "plants")"
        let until = assignment.endDate.formatted(date: .abbreviated, time: .omitted)

        if assignment.currentStatus(now: now) == .active {
            return Reminder(
                title: "\(assignment.sitterName) has your plants",
                body: "\(plants) in their care until \(until). You'll see everything they do."
            )
        }
        return Reminder(
            title: "\(assignment.sitterName) takes over soon",
            body: "\(plants), through to \(until). Add any last instructions before it starts."
        )
    }

    /// The trial notice the paywall promises.
    ///
    /// The paywall's own timeline row commits to this in writing, so it is not
    /// optional copy — a promise made to take someone's card has to be kept
    /// whether or not Apple happens to send its own notice. No urgency, no
    /// countdown theatre: the date, and the fact that doing nothing is a
    /// decision too.
    static func forTrialEnding(on date: Date) -> Reminder {
        Reminder(
            title: "Your Grove trial ends tomorrow",
            body: "It becomes a paid subscription on \(date.formatted(date: .abbreviated, time: .omitted)). Cancel any time in Settings if it isn't for you."
        )
    }
}

enum GroveNotificationAuthorization: String, Sendable {
    case unknown
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    var title: String {
        switch self {
        case .unknown: "Checking…"
        case .notDetermined: "Not enabled"
        case .denied: "Disabled in Settings"
        case .authorized: "Allowed"
        case .provisional: "Quietly allowed"
        case .ephemeral: "Temporarily allowed"
        }
    }

    var canSchedule: Bool {
        self == .authorized || self == .provisional || self == .ephemeral
    }
}

/// A notification already sitting in Notification Centre, reduced to the two
/// things Grove needs in order to decide whether to take it back.
struct DeliveredNotification {
    let identifier: String
    let userInfo: [AnyHashable: Any]
}

/// The slice of `UNUserNotificationCenter` Grove actually uses.
///
/// Exists so the scheduling logic can be tested. `UNUserNotificationCenter` has
/// no useful initialiser and cannot be subclassed into a fake, so injecting the
/// concrete type — which the old `init(center:)` seam did — bought nothing: the
/// half of this file that decides *what to remove and when* had no coverage at
/// all, and that is precisely the half that carried the bugs.
///
/// Deliberately narrower than the real API in two places. `UNNotificationSettings`
/// and `UNNotification` are both un-constructible from a test, so this asks for
/// the authorization status and a plain `DeliveredNotification` instead of the
/// objects that carry them.
@MainActor
protocol NotificationScheduling: AnyObject {
    var delegate: (any UNUserNotificationCenterDelegate)? { get set }
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func pendingIdentifiers() async -> [String]
    func delivered() async -> [DeliveredNotification]
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func setBadgeCount(_ count: Int) async throws
}

extension UNUserNotificationCenter: NotificationScheduling {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }

    func pendingIdentifiers() async -> [String] {
        await pendingNotificationRequests().map(\.identifier)
    }

    func delivered() async -> [DeliveredNotification] {
        await deliveredNotifications().map {
            DeliveredNotification(
                identifier: $0.request.identifier,
                userInfo: $0.request.content.userInfo
            )
        }
    }
}

@MainActor
@Observable
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// Everything Grove is allowed to remove. Anything the system or a future
    /// feature schedules under another prefix survives a rebuild untouched.
    private static let managedPrefixes = [
        "grove.care.",
        "grove.overdue.",
        "grove.sitting.",
        "grove.trial."
    ]

    nonisolated static let careCategory = "GROVE_CARE"
    nonisolated static let checkInCategory = "GROVE_CHECKIN"
    nonisolated static let sittingCategory = "GROVE_SITTING"
    nonisolated static let trialCategory = "GROVE_TRIAL"
    static let logCareAction = "GROVE_LOG_CARE"
    static let checkInNowAction = "GROVE_CHECK_IN_NOW"
    static let snoozeAction = "GROVE_SNOOZE"

    private let center: any NotificationScheduling
    private(set) var authorization: GroveNotificationAuthorization = .unknown
    private(set) var scheduledCount = 0
    private(set) var errorMessage: String?

    init(center: any NotificationScheduling = UNUserNotificationCenter.current()) {
        self.center = center
        super.init()
        center.delegate = self
        center.setNotificationCategories(Self.categories())
        Task { await refreshAuthorization() }
    }

    /// The actions a care reminder can offer.
    ///
    /// Grove's care loop is small enough that most banners can complete it
    /// outright: "Logged it" is the same call the Today row makes, and
    /// "Tomorrow" is the same snooze. Neither is `.foreground`, so the whole
    /// interaction happens on the lock screen — the difference between a
    /// reminder that costs a launch, a tab and a scroll, and one that costs a
    /// swipe. A check-in is the exception: it needs the camera, so its own
    /// category opens the flow instead.
    private static func categories() -> Set<UNNotificationCategory> {
        let logCare = UNNotificationAction(
            identifier: logCareAction,
            title: "Logged it",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: snoozeAction,
            title: "Tomorrow",
            options: []
        )
        // A check-in only means anything with a photo, so it opens the flow
        // rather than pretending the care happened on the lock screen.
        let checkInNow = UNNotificationAction(
            identifier: checkInNowAction,
            title: "Check in now",
            options: [.foreground]
        )
        return [
            UNNotificationCategory(
                identifier: careCategory,
                actions: [logCare, snooze],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: checkInCategory,
                actions: [checkInNow, snooze],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: sittingCategory,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: trialCategory,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        ]
    }

    func requestAuthorization() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            errorMessage = nil
        } catch {
            errorMessage = "Grove couldn't ask iOS for notification permission. Try again from Settings."
        }
        await refreshAuthorization()
    }

    func refreshAuthorization() async {
        authorization = Self.authorization(from: await center.authorizationStatus())
        // The token is only useful once someone has said yes, and asking for it
        // before then registers a device that can never be sent to.
        //
        // Once per launch, not once per call: this method runs on every
        // synchronize — which is every task completion, every snooze and every
        // return to the foreground — and each registration round trip would
        // otherwise turn into another one.
        if authorization.canSchedule, !hasRequestedRemotePush {
            hasRequestedRemotePush = true
            // Logged because the whole registration path is otherwise silent on
            // success, and a phone that quietly never registered is
            // indistinguishable from a server that quietly never sends.
            GroveDiag.log("push: asking iOS for a token (permission=\(authorization.rawValue))")
            registerForRemotePush?()
        } else if !authorization.canSchedule {
            GroveDiag.log("push: no token requested (permission=\(authorization.rawValue))")
        }
    }

    // MARK: - Remote push

    /// Asks the app delegate to register for APNs. Assigned by `GroveApp` rather
    /// than called directly, because `UIApplication.registerForRemoteNotifications`
    /// only pays off if something is listening for the token that comes back.
    @ObservationIgnored var registerForRemotePush: (() -> Void)?

    /// Hands a new token to Grove's server. Injected rather than called, so this
    /// class stays free of the API client and its session.
    /// Returns true only after the server has accepted the token. A false result
    /// stays retryable when auth or connectivity recovers later in this launch.
    @ObservationIgnored var onRegisterDeviceToken: (@MainActor (String, Bool) async -> Bool)?

    /// Tells Grove's server to stop sending to this phone.
    @ObservationIgnored var onRevokeDeviceToken: (@MainActor (String) async -> Void)?

    /// The APNs token this install currently holds, hex-encoded.
    private(set) var deviceToken: String?

    @ObservationIgnored private var hasRequestedRemotePush = false
    @ObservationIgnored private var lastRegisteredSittingPreference: Bool?
    @ObservationIgnored private var registeringSittingPreference: Bool?

    /// APNs answered. Called from the app delegate on every launch, because iOS
    /// reissues the token after a restore, an OS update or a long absence — a
    /// server holding a stale one is a silent outage, not an error anybody sees.
    ///
    /// Re-sent once per launch and no more. The launch registration is what
    /// keeps `last_seen_at` current on the server; repeating it within a session
    /// would only add round trips.
    func acceptDeviceToken(_ data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        guard token != deviceToken else { return }
        // Only the last six characters. Enough to tell two tokens apart in a
        // log; not enough for the log itself to address somebody's phone.
        GroveDiag.log("push: APNs returned a token (…\(token.suffix(6)))")
        deviceToken = token
        lastRegisteredSittingPreference = nil
        UserDefaults.standard.set(token, forKey: GroveDefaults.deviceToken)
        let defaults = UserDefaults.standard
        let sittingEnabled = defaults.object(forKey: GroveDefaults.sittingUpdates) == nil
            ? true
            : defaults.bool(forKey: GroveDefaults.sittingUpdates)
        Task { await registerRemotePushPreference(sittingEnabled: sittingEnabled) }
    }

    /// APNs refused. Nothing to show the user: local reminders are unaffected,
    /// and there is no action they could take. Logged so a device with no push
    /// can be told apart from a server that is not sending.
    func rejectDeviceToken(_ error: any Error) {
        GroveDiag.log("push: APNs registration failed (\(error.localizedDescription))")
    }

    /// Stops this phone receiving the signed-out account's pushes.
    ///
    /// Reads back from defaults as well as memory: a sign-out after a relaunch
    /// has no in-memory token, and that is exactly the case where the phone has
    /// been quietly receiving somebody else's notifications.
    func revokeDeviceToken() async {
        let stored = deviceToken ?? UserDefaults.standard.string(forKey: GroveDefaults.deviceToken)
        guard let stored else { return }
        await onRevokeDeviceToken?(stored)
        deviceToken = nil
        lastRegisteredSittingPreference = nil
        registeringSittingPreference = nil
        UserDefaults.standard.removeObject(forKey: GroveDefaults.deviceToken)
        // Re-armed, so signing a different account in on this phone registers
        // again. Without this the next account would receive nothing at all
        // until the app was force-quit and relaunched.
        hasRequestedRemotePush = false
    }

    func synchronize(
        plants: [Plant],
        tasks: [CareTask],
        assignments: [SittingAssignment],
        careEnabled: Bool,
        sittingEnabled: Bool,
        hour: Int = reminderHour,
        photoURLs: [UUID: URL] = [:],
        trialEndsAt: Date? = nil
    ) async {
        await refreshAuthorization()
        await registerRemotePushPreference(sittingEnabled: sittingEnabled)
        guard authorization.canSchedule else {
            scheduledCount = 0
            return
        }

        let pending = await center.pendingIdentifiers()
        center.removePendingNotificationRequests(withIdentifiers: Self.managed(in: pending))

        // A banner naming a plant that has since been deleted stays in
        // Notification Centre long after its pending request is gone, and
        // tapping it lands on "Plant not found". Removing the plant has to take
        // its delivered mail with it.
        let livePlantIDs = Set(
            plants
                .filter { $0.effectiveLifecycleState.receivesCareReminders }
                .map(\.id)
        )
        let orphaned = await center.delivered()
            .filter { notification in
                guard Self.isManaged(notification.identifier) else { return false }
                guard let raw = notification.userInfo["plantID"] as? String,
                      let plantID = UUID(uuidString: raw) else { return false }
                return !livePlantIDs.contains(plantID)
            }
            .map(\.identifier)
        if !orphaned.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: orphaned)
        }

        // Each sitting confirmation is booked once and remembered, so an
        // assignment arranged after the morning slot still confirms, and
        // opening Grove on later mornings does not confirm it again.
        let confirmations: [UUID: Date]? = sittingEnabled
            ? Self.sittingConfirmations(
                for: assignments,
                stored: Self.storedSittingConfirmations(),
                now: .now,
                hour: hour
            )
            : nil
        if let confirmations { Self.storeSittingConfirmations(confirmations) }

        // Request preparation sorts the whole care queue and may copy several
        // image attachments. None of that belongs on the main actor that is
        // animating the current screen.
        let preparation = Task.detached(priority: .utility) {
            Self.makeRequests(
                plants: plants,
                tasks: tasks,
                assignments: assignments,
                careEnabled: careEnabled,
                sittingEnabled: sittingEnabled,
                hour: hour,
                photoURLs: photoURLs,
                trialEndsAt: trialEndsAt,
                sittingConfirmations: confirmations
            )
        }
        let requests = await withTaskCancellationHandler {
            await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        guard !Task.isCancelled else { return }

        // Counted rather than assumed. A throw partway through used to report
        // zero scheduled reminders next to an error saying *some* had failed,
        // so Settings contradicted itself at the one moment a user was looking
        // for a straight answer.
        var added = 0
        var failed = false
        for request in requests {
            do {
                try await center.add(request)
                added += 1
            } catch {
                failed = true
            }
        }
        scheduledCount = added
        errorMessage = failed
            ? "Some reminders didn't get scheduled. Try again from Settings."
            : nil

        // The app icon has been asking for a badge permission it never used.
        // Plants needing care, the same count the Today tab and the rooms map
        // draw, so the icon, the tab and the card can never disagree.
        let due = GrovePlantCareSummary.needingCareCount(plants: plants, tasks: tasks)
        try? await center.setBadgeCount(careEnabled ? due : 0)
    }

    /// A provider session can become usable after APNs has already delivered
    /// its token. Call this immediately after auth restoration so that race is
    /// repaired without waiting for a preference change or another launch.
    func retryRemotePushRegistration() async {
        let defaults = UserDefaults.standard
        let sittingEnabled = defaults.object(forKey: GroveDefaults.sittingUpdates) == nil
            ? true
            : defaults.bool(forKey: GroveDefaults.sittingUpdates)
        await registerRemotePushPreference(sittingEnabled: sittingEnabled)
    }

    private func registerRemotePushPreference(sittingEnabled: Bool) async {
        guard let token = deviceToken,
              lastRegisteredSittingPreference != sittingEnabled,
              registeringSittingPreference != sittingEnabled,
              let onRegisterDeviceToken else { return }
        registeringSittingPreference = sittingEnabled
        let registered = await onRegisterDeviceToken(token, sittingEnabled)
        if registeringSittingPreference == sittingEnabled {
            registeringSittingPreference = nil
        }
        guard registered, deviceToken == token else { return }
        lastRegisteredSittingPreference = sittingEnabled
    }

    /// Tears down every reminder Grove owns, scheduled or already delivered.
    /// Signing out and deleting local data both dismantle the view tree that
    /// drives `synchronize`, so nothing else can clean up afterwards: without
    /// this, the previous account's reminders keep firing — naming plants the
    /// user has just deleted — and its delivered banners stay in Notification
    /// Centre.
    func cancelScheduledReminders() async {
        let pending = await center.pendingIdentifiers()
        center.removePendingNotificationRequests(withIdentifiers: Self.managed(in: pending))
        let delivered = await center.delivered().map(\.identifier)
        center.removeDeliveredNotifications(withIdentifiers: Self.managed(in: delivered))
        try? await center.setBadgeCount(0)
        UserDefaults.standard.removeObject(forKey: Self.sittingConfirmationsKey)
        scheduledCount = 0
        errorMessage = nil
    }

    // MARK: - Sitting confirmations

    /// When each sitting assignment's confirmation fires, keyed by assignment.
    nonisolated static let sittingConfirmationsKey = "grove.sitting.confirmations"

    /// Books one confirmation per live assignment and keeps it.
    ///
    /// A future handover confirms at the reminder hour on its first day. One
    /// already under way confirms a minute from now: the old code anchored it
    /// to `now` and asked `reminderDate` for a slot, which after 9am returned
    /// nil, so a sitter arranged mid-trip after breakfast was never confirmed
    /// at all, while one arranged before 9am re-confirmed every morning the
    /// app was opened. A booked instant that has passed is kept, so it is
    /// never booked again; ended assignments drop out.
    nonisolated static func sittingConfirmations(
        for assignments: [SittingAssignment],
        stored: [UUID: Date],
        now: Date,
        hour: Int = reminderHour
    ) -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        for assignment in assignments where !assignment.hasEnded(now: now) && !assignment.isIncoming {
            if let booked = stored[assignment.id], booked <= now || assignment.startDate <= now {
                result[assignment.id] = booked
            } else if assignment.startDate > now,
                      let slot = reminderDate(for: assignment.startDate, now: now, hour: hour) {
                result[assignment.id] = slot
            } else {
                // A minute out, not seconds: the calendar trigger matches to
                // the minute, and the minute already under way never matches.
                result[assignment.id] = now.addingTimeInterval(60)
            }
        }
        return result
    }

    private static func storedSittingConfirmations() -> [UUID: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: sittingConfirmationsKey) as? [String: Double] ?? [:]
        var result: [UUID: Date] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) { result[id] = Date(timeIntervalSince1970: value) }
        }
        return result
    }

    private static func storeSittingConfirmations(_ confirmations: [UUID: Date]) {
        let raw = Dictionary(uniqueKeysWithValues: confirmations.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) })
        UserDefaults.standard.set(raw, forKey: sittingConfirmationsKey)
    }

    private static func isManaged(_ identifier: String) -> Bool {
        managedPrefixes.contains { identifier.hasPrefix($0) }
    }

    private static func managed(in identifiers: [String]) -> [String] {
        identifiers.filter(isManaged)
    }

    /// The local hour reminders are delivered at unless the user picks another
    /// in Settings. Due dates are derived from whenever the user happened to
    /// add a plant or finish a check-in, so firing at the raw due timestamp
    /// means a plant adopted at 23:40 wakes its owner at 23:40 a fortnight
    /// later. Care reminders are never urgent to the minute — morning is.
    nonisolated static let reminderHour = 9

    /// How long a missed reminder waits before its single follow-up.
    nonisolated static let overdueNudgeDays = 3

    /// Clamps a stored preference back into a real hour. Every call site passes
    /// `reminderHour` as its `@AppStorage` default, so this is not guarding an
    /// absent key — it guards a stored value that has gone out of range, which
    /// would otherwise be handed straight to `Calendar` and silently produce no
    /// date at all.
    nonisolated static func normalizedHour(_ hour: Int) -> Int {
        (0...23).contains(hour) ? hour : reminderHour
    }

    /// iOS keeps at most 64 pending local notifications per app and silently
    /// discards the rest, which would drop the *soonest* reminders once a
    /// grove grew past that. Stay under the limit deliberately and keep the
    /// nearest ones.
    nonisolated static let maximumScheduledReminders = 60

    /// A request paired with the instant it will fire, so the whole set can be
    /// ordered before the system limit is applied.
    private struct ScheduledReminder {
        let fireDate: Date
        let request: UNNotificationRequest
        /// Follow-ups yield their slot to first-time reminders. See the ranking
        /// in `makeRequests`.
        var isFollowUp = false
    }

    nonisolated static func makeRequests(
        plants: [Plant],
        tasks: [CareTask],
        assignments: [SittingAssignment],
        careEnabled: Bool,
        sittingEnabled: Bool,
        now: Date = .now,
        hour: Int = reminderHour,
        photoURLs: [UUID: URL] = [:],
        trialEndsAt: Date? = nil,
        sittingConfirmations: [UUID: Date]? = nil
    ) -> [UNNotificationRequest] {
        let plantsByID = Dictionary(
            uniqueKeysWithValues: plants
                .filter { $0.effectiveLifecycleState.receivesCareReminders }
                .map { ($0.id, $0) }
        )
        let deliveryHour = normalizedHour(hour)
        var scheduled: [ScheduledReminder] = []

        if careEnabled {
            let open = tasks.filter { !$0.isCompleted }

            scheduled += open.compactMap { task -> ScheduledReminder? in
                guard let plant = plantsByID[task.plantID],
                      let fireDate = reminderDate(for: task.dueDate, now: now, hour: deliveryHour) else { return nil }
                let copy = GroveReminderCopy.forCare(task: task, plant: plant)
                let content = careContent(
                    copy: copy,
                    task: task,
                    plant: plant,
                    photoURL: photoURLs[plant.id],
                    isFollowUp: false
                )
                return ScheduledReminder(
                    fireDate: fireDate,
                    request: UNNotificationRequest(
                        identifier: "grove.care.\(task.id.uuidString)",
                        content: content,
                        trigger: trigger(at: fireDate)
                    )
                )
            }

            // The follow-up is derived from the due date, not from the primary
            // reminder, so a task that is *already* overdue when this runs still
            // gets one. Its own identifier is what keeps it from stacking: every
            // rebuild computes the same instant for the same task, so repeated
            // synchronizes replace one request rather than pile up alerts.
            scheduled += open.compactMap { task -> ScheduledReminder? in
                guard let plant = plantsByID[task.plantID],
                      let nudgeDay = Calendar.current.date(
                          byAdding: .day,
                          value: overdueNudgeDays,
                          to: task.dueDate
                      ),
                      let fireDate = reminderDate(for: nudgeDay, now: now, hour: deliveryHour) else { return nil }
                let copy = GroveReminderCopy.forOverdue(task: task, plant: plant)
                let content = careContent(
                    copy: copy,
                    task: task,
                    plant: plant,
                    photoURL: nil,
                    isFollowUp: true
                )
                return ScheduledReminder(
                    fireDate: fireDate,
                    request: UNNotificationRequest(
                        identifier: "grove.overdue.\(task.id.uuidString)",
                        content: content,
                        trigger: trigger(at: fireDate)
                    ),
                    isFollowUp: true
                )
            }
        }

        if sittingEnabled {
            // An assignment arranged mid-trip has a start date in the past,
            // which used to mean no confirmation at all: the one moment the
            // owner most wants to know their plants are covered. See
            // `sittingConfirmations` for how each one is booked exactly once.
            let confirmations = sittingConfirmations
                ?? Self.sittingConfirmations(for: assignments, stored: [:], now: now, hour: deliveryHour)
            scheduled += assignments
                .filter { !$0.isIncoming && !$0.hasEnded(now: now) }
                .compactMap { assignment -> ScheduledReminder? in
                    guard let fireDate = confirmations[assignment.id], fireDate > now else { return nil }
                    let content = UNMutableNotificationContent()
                    let copy = GroveReminderCopy.forSitting(assignment, now: fireDate)
                    content.title = copy.title
                    content.body = copy.body
                    content.sound = .default
                    content.categoryIdentifier = sittingCategory
                    content.threadIdentifier = "grove.sitting"
                    content.relevanceScore = 0.7
                    content.userInfo = ["openTab": AppTab.today.rawValue]
                    return ScheduledReminder(
                        fireDate: fireDate,
                        request: UNNotificationRequest(
                            identifier: "grove.sitting.\(assignment.id.uuidString)",
                            content: content,
                            trigger: trigger(at: fireDate)
                        )
                    )
                }
        }

        // Not gated on the care or sitting switches: those govern plant care,
        // and this is about the user's own money. It is cancelled by sign-out
        // like everything else Grove schedules.
        if let trialEndsAt,
           let noticeDate = trialNoticeDate(for: trialEndsAt, now: now, hour: deliveryHour) {
            let copy = GroveReminderCopy.forTrialEnding(on: trialEndsAt)
            let content = UNMutableNotificationContent()
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            content.categoryIdentifier = trialCategory
            content.threadIdentifier = "grove.trial"
            content.relevanceScore = 1
            // The one Grove notification with a deadline attached to it. Missing
            // it costs money, which is exactly the bar for interrupting someone.
            content.interruptionLevel = .timeSensitive
            content.userInfo = ["openTab": AppTab.profile.rawValue]
            scheduled.append(
                ScheduledReminder(
                    fireDate: noticeDate,
                    request: UNNotificationRequest(
                        identifier: "grove.trial.ending",
                        content: content,
                        trigger: trigger(at: noticeDate)
                    )
                )
            )
        }

        // Two rules, in this order: a first-time reminder outranks any
        // follow-up, and within each group the soonest wins.
        //
        // Ordering the whole set by date alone looked right and was not. The
        // follow-ups interleave with the primaries — a task due on day 1 also
        // books day 4 — so a grove big enough to hit the cap spent half its
        // sixty slots on second chances and lost the *first* reminder for
        // everything past roughly day 30. That is precisely backwards for the
        // person it matters to: someone who has not opened Grove in a month is
        // exactly who the schedule has to still be reaching.
        let ranked = scheduled.sorted { left, right in
            if left.isFollowUp != right.isFollowUp { return !left.isFollowUp }
            return left.fireDate < right.fireDate
        }
        return ranked
            .prefix(maximumScheduledReminders)
            .map(\.request)
    }

    nonisolated private static func careContent(
        copy: GroveReminderCopy.Reminder,
        task: CareTask,
        plant: Plant,
        photoURL: URL?,
        isFollowUp: Bool
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.body
        content.sound = .default
        // A check-in needs the camera and observations before it can be
        // completed, so it gets a category that offers the flow, not "Logged
        // it". Every other kind keeps the one-tap completion.
        content.categoryIdentifier = task.kind == .checkIn ? checkInCategory : careCategory
        // Grouped by plant, so a morning where six pots are due reads as six
        // conversations about six plants rather than six unrelated alerts.
        content.threadIdentifier = "grove.plant.\(plant.id.uuidString)"
        content.relevanceScore = relevance(for: task.kind, isFollowUp: isFollowUp)
        // Follow-ups are ordinary .active alerts. Nothing about a plant
        // justifies breaking through Focus, so a missed reminder stays in the
        // same interruptible place as the first one. The only Time Sensitive
        // notification Grove sends is the trial-ending notice.
        if isFollowUp { content.interruptionLevel = .active }
        content.userInfo = [
            "plantID": plant.id.uuidString,
            "taskID": task.id.uuidString,
            "kind": task.kind.rawValue
        ]
        if let photoURL, let attachment = attachment(for: photoURL, plant: plant, kind: task.kind) {
            content.attachments = [attachment]
        }
        return content
    }

    /// Which reminder the Notification Summary should lead with when it has
    /// several. Care that decays fastest outranks care that can wait a week.
    nonisolated private static func relevance(for kind: CareKind, isFollowUp: Bool) -> Double {
        if isFollowUp { return 1 }
        switch kind {
        case .water, .treat, .repot: return 0.9
        case .checkIn, .inspectSoil, .relocate, .monitor: return 0.6
        case .fertilise, .prune, .rotate, .cleanLeaves: return 0.3
        }
    }

    /// The last photo of the plant, for check-in reminders only.
    ///
    /// A check-in reminder's whole ask is "take a photo and Grove compares it
    /// with the last one", so the last one belongs in the banner — it is the
    /// before shot. The other kinds get nothing: `UNNotificationAttachment`
    /// **moves** the file it is handed into the system's attachment store, so
    /// every attachment costs a real copy on disk, and paying that for sixty
    /// reminders on every task completion is not worth a decoration.
    ///
    /// The copy is deliberate for the same reason. Handing over the
    /// observation's own URL would move the plant's photo out of Grove's
    /// container and blank the plant page.
    nonisolated private static func attachment(
        for photoURL: URL,
        plant: Plant,
        kind: CareKind
    ) -> UNNotificationAttachment? {
        // A server-restored photo is a signed remote URL, and attachments are
        // files only. Nothing to copy, nothing to attach.
        guard kind == .checkIn, photoURL.isFileURL else { return nil }
        let copyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-reminder-\(plant.id.uuidString)-\(UUID().uuidString)")
            .appendingPathExtension(photoURL.pathExtension.isEmpty ? "jpg" : photoURL.pathExtension)
        do {
            try FileManager.default.copyItem(at: photoURL, to: copyURL)
            return try UNNotificationAttachment(identifier: "", url: copyURL, options: nil)
        } catch {
            // The temp copy is orphaned only when the attachment itself failed;
            // a successful one consumes the file.
            try? FileManager.default.removeItem(at: copyURL)
            return nil
        }
    }

    /// When a reminder for `dueDate` should actually fire, or `nil` when there
    /// is no future slot left for it. Past-due work is visible in the Today
    /// queue and picked up by the follow-up above; re-scheduling the primary
    /// reminder here would fire a fresh "in 60 seconds" alert on every
    /// synchronize (each launch, task completion, or snooze), stacking duplicate
    /// notifications for as long as the task stayed overdue.
    nonisolated static func reminderDate(for dueDate: Date, now: Date, hour: Int = reminderHour) -> Date? {
        let calendar = Calendar.current
        let slotOnDueDay = calendar.date(
            bySettingHour: normalizedHour(hour),
            minute: 0,
            second: 0,
            of: dueDate
        )
        if let slotOnDueDay, slotOnDueDay > now { return slotOnDueDay }
        return dueDate > now ? dueDate : nil
    }

    /// When the trial notice fires, or `nil` when the trial ends too soon for a
    /// day's warning to still be a warning.
    ///
    /// The day before the charge is the promise the paywall's timeline makes, so
    /// that is fixed. The *hour* was not: `trialEndsAt` is whatever second the
    /// purchase happened to complete, which booked a payment warning for 11:40pm
    /// when the trial started at 11:40pm. It now lands in the same morning slot
    /// as every other Grove reminder, staying on the notice day so "ends
    /// tomorrow" remains true. The raw instant is the fallback for a trial whose
    /// notice day is already past that hour, because a late warning about money
    /// still beats none.
    nonisolated static func trialNoticeDate(for trialEndsAt: Date, now: Date, hour: Int = reminderHour) -> Date? {
        let calendar = Calendar.current
        guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: trialEndsAt),
              dayBefore > now else { return nil }
        let slot = calendar.date(
            bySettingHour: normalizedHour(hour),
            minute: 0,
            second: 0,
            of: dayBefore
        )
        if let slot, slot > now, slot < trialEndsAt { return slot }
        return dayBefore
    }

    nonisolated private static func trigger(at date: Date) -> UNNotificationTrigger {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    private static func authorization(from status: UNAuthorizationStatus) -> GroveNotificationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .unknown
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        await handle(action: action, userInfo: userInfo)
    }

    /// What a tap or an action actually does, separated from the delegate.
    ///
    /// `UNNotificationResponse` cannot be constructed outside the system, so
    /// routing could not be tested at all while it lived in the delegate method
    /// — and routing is the part that decides where somebody lands after
    /// touching a notification, which is the whole payoff of sending one.
    ///
    /// Nothing here touches `GroveStore`. An action can wake the app straight
    /// into the background, before the shell has mounted and before the store
    /// has been activated for an account, so this writes the intent to
    /// `IntentRouter` and the shell applies it when it can — the same handoff a
    /// notification tap already used.
    func handle(action: String, userInfo: [AnyHashable: Any]) async {
        let plantID = (userInfo["plantID"] as? String).flatMap(UUID.init(uuidString:))
        let taskID = (userInfo["taskID"] as? String).flatMap(UUID.init(uuidString:))
        // Sitting notices, the trial notice and pushes name the tab they want;
        // anything else lands on Today. Read rather than assumed, so a future
        // reminder kind cannot silently inherit the wrong destination.
        let tab = (userInfo["openTab"] as? String).flatMap(AppTab.init(rawValue:))
        let kind = (userInfo["kind"] as? String).flatMap(CareKind.init(rawValue:))

        if action == Self.checkInNowAction {
            if let plantID {
                IntentRouter.shared.startCheckIn(plantID)
            }
            return
        }
        if let taskID, action == Self.logCareAction {
            // A request delivered under the old care category can still offer
            // "Logged it" for a check-in. Completing that would record care
            // without the photo the flow exists to take, so open the check-in
            // instead — and do nothing when the payload names no plant.
            if kind == .checkIn {
                if let plantID {
                    IntentRouter.shared.startCheckIn(plantID)
                }
                return
            }
            IntentRouter.shared.pendingCareAction = PendingCareAction(taskID: taskID, outcome: .logged)
            return
        }
        if let taskID, action == Self.snoozeAction {
            IntentRouter.shared.pendingCareAction = PendingCareAction(taskID: taskID, outcome: .snoozed)
            return
        }
        guard action != UNNotificationDismissActionIdentifier else { return }
        if let plantID {
            // A care reminder's whole ask is "take a photo and Grove compares it
            // with the last one", but tapping it opened the plant page and left
            // the person to find the action themselves. When the reminder is a
            // check-in, land on the check-in; every other kind still opens the
            // plant, because its task is not a check-in flow.
            if kind == .checkIn {
                IntentRouter.shared.startCheckIn(plantID)
            } else {
                IntentRouter.shared.openPlant(plantID)
            }
        } else if userInfo["openRoute"] as? String == "sitting" {
            // A sitting invitation wants the whole Plant sitting screen, not
            // just the Friends tab: that is where the Accept / Decline card
            // lives. Older builds ignore the unknown key and still honour
            // `openTab`, which stays on the payload for exactly that reason.
            IntentRouter.shared.requestedRouteTab = .friends
            IntentRouter.shared.requestedRoute = .sitting
        } else {
            IntentRouter.shared.requestedTab = tab ?? .today
        }
    }
}
