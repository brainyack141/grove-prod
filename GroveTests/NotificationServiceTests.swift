import UserNotifications
import XCTest
@testable import Grove

@MainActor
final class NotificationServiceTests: XCTestCase {
    func testReleaseDevicePushUsesSigningProfileEnvironment() throws {
        for (entitlement, expected) in [("development", "sandbox"), ("production", "production")] {
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["Entitlements": ["aps-environment": entitlement]],
                format: .xml, options: 0)
            var embedded = Data([0x30, 0x82, 0xff])
            embedded.append(plist)
            embedded.append(Data([0xff, 0x00]))
            XCTAssertEqual(GroveServiceFactory.pushEnvironment(provisioningProfile: embedded), expected)
        }
        XCTAssertEqual(GroveServiceFactory.pushEnvironment(provisioningProfile: nil), "production")
        XCTAssertEqual(GroveServiceFactory.pushEnvironment(provisioningProfile: Data()), "production")
    }

    func testCareRequestTargetsPlantAndUsesStableIdentifier() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let task = CareTask(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            plantID: plant.id,
            kind: .checkIn,
            dueDate: Date(timeIntervalSince1970: 2_000_000_000),
            detail: "Compare new growth.",
            isCompleted: false,
            isSittingTask: false,
            ownerName: nil
        )

        let requests = NotificationService.makeRequests(
            plants: [plant],
            tasks: [task],
            assignments: [],
            careEnabled: true,
            sittingEnabled: false,
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )

        // Two: the reminder, and the single follow-up three days later that
        // stops one missed morning ending the plant's care loop.
        XCTAssertEqual(requests.count, 2)
        let request = try XCTUnwrap(
            requests.first { $0.identifier == "grove.care.\(task.id.uuidString)" }
        )
        XCTAssertEqual(request.identifier, "grove.care.\(task.id.uuidString)")
        XCTAssertEqual(request.content.userInfo["plantID"] as? String, plant.id.uuidString)
        XCTAssertEqual(request.content.categoryIdentifier, "GROVE_CHECKIN")
        XCTAssertTrue(request.trigger is UNCalendarNotificationTrigger)
    }

    /// Watering can be finished from the lock screen, so it keeps the category
    /// whose "Logged it" writes the completion straight away.
    func testWaterReminderKeepsTheCareCategory() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let task = CareTask(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            plantID: plant.id,
            kind: .water,
            dueDate: Date(timeIntervalSince1970: 2_000_000_000),
            detail: "Water only if it's dry.",
            isCompleted: false,
            isSittingTask: false,
            ownerName: nil
        )

        let requests = NotificationService.makeRequests(
            plants: [plant],
            tasks: [task],
            assignments: [],
            careEnabled: true,
            sittingEnabled: false,
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )

        let request = try XCTUnwrap(
            requests.first { $0.identifier == "grove.care.\(task.id.uuidString)" }
        )
        XCTAssertEqual(request.content.categoryIdentifier, NotificationService.careCategory)
    }

    func testReminderFiresInTheMorningRatherThanAtTheRawDueTimestamp() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let dueDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: now))
        // A plant adopted at 23:40 must not wake its owner at 23:40 a
        // fortnight later.
        let lateNightDueDate = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 40, second: 0, of: dueDay))
        let task = CareTask(
            id: UUID(),
            plantID: plant.id,
            kind: .checkIn,
            dueDate: lateNightDueDate,
            detail: "Compare new growth.",
            isCompleted: false,
            isSittingTask: false,
            ownerName: nil
        )

        let requests = NotificationService.makeRequests(
            plants: [plant],
            tasks: [task],
            assignments: [],
            careEnabled: true,
            sittingEnabled: false,
            now: now
        )

        let trigger = try XCTUnwrap(requests.first?.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.dateComponents.hour, NotificationService.reminderHour)
        XCTAssertEqual(trigger.dateComponents.minute, 0)
        XCTAssertEqual(trigger.dateComponents.day, calendar.component(.day, from: lateNightDueDate))
    }

    func testOnboardingPrimerPreviewsTheEarliestRealTaskAndDelivery() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let earlyDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 3, to: now))
        let lateDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 14, to: now))
        let soil = CareTask(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            plantID: plant.id,
            kind: .inspectSoil,
            dueDate: earlyDate,
            detail: "Feel the top 3 cm before you water.",
            isCompleted: false,
            isSittingTask: false,
            ownerName: nil
        )
        let checkIn = CareTask(
            id: UUID(),
            plantID: plant.id,
            kind: .checkIn,
            dueDate: lateDate,
            detail: "Compare a new photo.",
            isCompleted: false,
            isSittingTask: false,
            ownerName: nil
        )

        let first = try XCTUnwrap(
            OnboardingReminderPreview.firstTask(for: plant, in: [checkIn, soil])
        )
        let preview = OnboardingReminderPreview(
            plant: plant,
            task: first,
            reminderHour: 9,
            now: now
        )
        let expectedCopy = GroveReminderCopy.forCare(task: soil, plant: plant)
        let expectedDate = try XCTUnwrap(
            NotificationService.reminderDate(for: earlyDate, now: now, hour: 9)
        )

        XCTAssertEqual(first.id, soil.id)
        XCTAssertEqual(preview.title, expectedCopy.title)
        XCTAssertEqual(preview.body, expectedCopy.body)
        XCTAssertEqual(preview.deliveryDate, expectedDate)
    }

    func testOverdueTasksAreNotRescheduled() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let yesterday = now.addingTimeInterval(-86_400)

        XCTAssertNil(NotificationService.reminderDate(for: yesterday, now: now))
    }

    func testScheduledRemindersStayUnderTheSystemLimitAndKeepTheSoonest() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let tasks: [CareTask] = try (1...80).map { offset in
            let dueDate = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: now))
            return CareTask(
                id: UUID(),
                plantID: plant.id,
                kind: .inspectSoil,
                dueDate: dueDate,
                detail: "Check the soil.",
                isCompleted: false,
                isSittingTask: false,
                ownerName: nil
            )
        }

        let requests = NotificationService.makeRequests(
            plants: [plant],
            tasks: tasks,
            assignments: [],
            careEnabled: true,
            sittingEnabled: false,
            now: now
        )

        // iOS keeps only 64 pending notifications and silently drops the rest,
        // so Grove has to choose which ones survive — the nearest ones.
        XCTAssertEqual(requests.count, NotificationService.maximumScheduledReminders)
        let keptIdentifiers = Set(requests.map(\.identifier))
        // Every surviving slot goes to a *first* reminder, and to the soonest
        // of them. Follow-ups are second chances: valuable, but never at the
        // price of the only notice a later task will ever get. A grove this
        // size used to lose its day-31-onward reminders to day-4 follow-ups.
        let expectedSoonest = tasks
            .prefix(NotificationService.maximumScheduledReminders)
            .map { "grove.care.\($0.id.uuidString)" }
        XCTAssertEqual(keptIdentifiers, Set(expectedSoonest))
        XCTAssertFalse(
            keptIdentifiers.contains { $0.hasPrefix("grove.overdue.") },
            "A follow-up must never displace a reminder that has not fired yet"
        )
    }

    func testDisabledCareRemindersCreateNoCareRequests() {
        let store = GroveStore(persistenceEnabled: false)

        let requests = NotificationService.makeRequests(
            plants: store.plants,
            tasks: store.tasks,
            assignments: [],
            careEnabled: false,
            sittingEnabled: false
        )

        XCTAssertTrue(requests.isEmpty)
    }

    /// The stored status never advances, so "not completed" was true of every
    /// assignment forever. Only the dates know whether a trip is still on.
    func testSittingReminderCopyFollowsTheTripAndFinishedTripsAreDropped() throws {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func assignment(startOffset: Int, endOffset: Int) throws -> SittingAssignment {
            SittingAssignment(
                id: UUID(),
                sitterName: "Maya Kapoor",
                sitterInitials: "MK",
                startDate: try XCTUnwrap(calendar.date(byAdding: .day, value: startOffset, to: now)),
                endDate: try XCTUnwrap(calendar.date(byAdding: .day, value: endOffset, to: now)),
                plantIDs: [UUID()],
                status: .upcoming,
                completedTasks: 0,
                totalTasks: 2
            )
        }

        let underWay = try assignment(startOffset: -1, endOffset: 6)
        let notYet = try assignment(startOffset: 4, endOffset: 12)
        let finished = try assignment(startOffset: -20, endOffset: -6)

        XCTAssertEqual(
            GroveReminderCopy.forSitting(underWay, now: now).title,
            "Maya Kapoor has your plants"
        )
        XCTAssertEqual(
            GroveReminderCopy.forSitting(notYet, now: now).title,
            "Maya Kapoor takes over soon"
        )

        let requests = NotificationService.makeRequests(
            plants: [],
            tasks: [],
            assignments: [finished],
            careEnabled: false,
            sittingEnabled: true,
            now: now
        )
        XCTAssertTrue(requests.isEmpty, "A trip that already ended has nothing left to remind anyone about")
    }

    /// Accepting a sit used to book the owner's "X has your plants" confirmation
    /// on the sitter's own phone, where it named the wrong person and asked for
    /// instructions the sitter had no business receiving.
    func testIncomingHandoverDoesNotScheduleTheOwnerConfirmation() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let outgoing = SittingAssignment(
            id: UUID(),
            sitterName: "Maya Kapoor",
            sitterInitials: "MK",
            startDate: now.addingTimeInterval(-86_400),
            endDate: now.addingTimeInterval(6 * 86_400),
            plantIDs: [UUID()],
            status: .active,
            completedTasks: 0,
            totalTasks: 2
        )
        let incoming = SittingAssignment(
            id: UUID(),
            sitterName: "Aisha",
            sitterInitials: "A",
            startDate: now.addingTimeInterval(-86_400),
            endDate: now.addingTimeInterval(6 * 86_400),
            plantIDs: [UUID()],
            status: .active,
            completedTasks: 0,
            totalTasks: 2,
            ownerName: "Alex",
            isIncoming: true
        )

        let requests = NotificationService.makeRequests(
            plants: [],
            tasks: [],
            assignments: [outgoing, incoming],
            careEnabled: false,
            sittingEnabled: true,
            now: now
        )

        let sitting = requests.map(\.identifier).filter { $0.hasPrefix("grove.sitting.") }
        XCTAssertEqual(sitting, ["grove.sitting.\(outgoing.id.uuidString)"])
    }

    func testSittingConfirmationsSkipIncomingHandovers() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let incoming = SittingAssignment(
            id: UUID(),
            sitterName: "Aisha",
            sitterInitials: "A",
            startDate: now.addingTimeInterval(-86_400),
            endDate: now.addingTimeInterval(6 * 86_400),
            plantIDs: [UUID()],
            status: .active,
            completedTasks: 0,
            totalTasks: 2,
            ownerName: "Alex",
            isIncoming: true
        )

        let confirmations = NotificationService.sittingConfirmations(
            for: [incoming],
            stored: [:],
            now: now
        )

        XCTAssertTrue(confirmations.isEmpty)
    }

    // MARK: - The follow-up

    func testOverdueTaskStillGetsItsFollowUpAndOnlyOne() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        // Missed yesterday: the primary reminder has no future slot left, which
        // used to mean Grove said nothing about this plant ever again.
        let task = CareTask(
            id: UUID(),
            plantID: plant.id,
            kind: .water,
            dueDate: now.addingTimeInterval(-86_400),
            detail: "Check the soil.",
            isCompleted: false,
            isSittingTask: false,
            ownerName: nil
        )

        let requests = NotificationService.makeRequests(
            plants: [plant],
            tasks: [task],
            assignments: [],
            careEnabled: true,
            sittingEnabled: false,
            now: now
        )

        XCTAssertEqual(requests.map(\.identifier), ["grove.overdue.\(task.id.uuidString)"])
        // Rule 2: the ask is the check, never the watering. Grove has not felt
        // this soil, and a follow-up is exactly where an app starts nagging
        // someone into drowning a plant.
        let content = try XCTUnwrap(requests.first).content
        XCTAssertFalse(content.body.lowercased().contains("water it"))
        XCTAssertTrue(content.body.lowercased().contains("dry"))
        // A missed plant reminder is still just a plant reminder: it must not
        // break through Focus the way the trial-ending notice does.
        XCTAssertEqual(content.interruptionLevel, .active)
    }

    /// The identifier is the whole defence against stacking: every rebuild
    /// computes the same instant for the same task, so repeated synchronizes
    /// replace one request instead of piling alerts on somebody already behind.
    func testFollowUpIsStableAcrossRepeatedRebuilds() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let task = CareTask(
            id: UUID(),
            plantID: plant.id,
            kind: .checkIn,
            dueDate: now.addingTimeInterval(86_400),
            detail: "Compare new growth.",
            isCompleted: false,
            isSittingTask: false,
            ownerName: nil
        )

        func rebuild(at moment: Date) -> [String] {
            NotificationService.makeRequests(
                plants: [plant],
                tasks: [task],
                assignments: [],
                careEnabled: true,
                sittingEnabled: false,
                now: moment
            ).map(\.identifier)
        }

        let first = rebuild(at: now)
        let second = rebuild(at: now.addingTimeInterval(60))
        XCTAssertEqual(Set(first), Set(second))
        XCTAssertEqual(Set(first).count, first.count, "A rebuild must not produce two requests for one task")
        XCTAssertTrue(first.contains("grove.care.\(task.id.uuidString)"))
        XCTAssertTrue(first.contains("grove.overdue.\(task.id.uuidString)"))
    }

    /// Under the cap, follow-ups are welcome — they only yield when there is
    /// competition for a slot.
    func testFollowUpsFillTheSlotsPrimariesLeaveOver() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let tasks: [CareTask] = try (1...5).map { offset in
            CareTask(
                id: UUID(),
                plantID: plant.id,
                kind: .inspectSoil,
                dueDate: try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: now)),
                detail: "Check the soil.",
                isCompleted: false,
                isSittingTask: false,
                ownerName: nil
            )
        }

        let identifiers = NotificationService.makeRequests(
            plants: [plant],
            tasks: tasks,
            assignments: [],
            careEnabled: true,
            sittingEnabled: false,
            now: now
        ).map(\.identifier)

        XCTAssertEqual(identifiers.filter { $0.hasPrefix("grove.care.") }.count, 5)
        XCTAssertEqual(identifiers.filter { $0.hasPrefix("grove.overdue.") }.count, 5)
    }

    func testTrialNoticeLandsTheDayBeforeAndIsSkippedOnceItHasPassed() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        let scheduled = NotificationService.makeRequests(
            plants: [],
            tasks: [],
            assignments: [],
            careEnabled: false,
            sittingEnabled: false,
            now: now,
            trialEndsAt: now.addingTimeInterval(3 * 86_400)
        )
        XCTAssertEqual(scheduled.map(\.identifier), ["grove.trial.ending"])
        // Missing it costs money, so the trial notice is the one notification
        // allowed to break through Focus.
        XCTAssertEqual(try XCTUnwrap(scheduled.first).content.interruptionLevel, .timeSensitive)

        // A trial ending within the day has no room left for a day-early
        // notice, and firing one "now" would be an alarm, not a courtesy.
        let tooLate = NotificationService.makeRequests(
            plants: [],
            tasks: [],
            assignments: [],
            careEnabled: false,
            sittingEnabled: false,
            now: now,
            trialEndsAt: now.addingTimeInterval(3600)
        )
        XCTAssertTrue(tooLate.isEmpty)
    }

    /// A trial started at 11:40pm must not book its payment warning for 11:40pm.
    /// The notice keeps its day and moves to the hour Grove delivers everything
    /// else at, so "ends tomorrow" stays true and nobody is woken by it.
    func testTrialNoticeMovesToTheDeliveryHourOnTheDayBefore() throws {
        let calendar = Calendar.current
        let purchase = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 23, minute: 40))
        )
        let trialEndsAt = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: purchase))

        let fireDate = try XCTUnwrap(
            NotificationService.trialNoticeDate(for: trialEndsAt, now: purchase, hour: 9)
        )

        XCTAssertEqual(calendar.component(.hour, from: fireDate), 9)
        XCTAssertEqual(calendar.component(.minute, from: fireDate), 0)
        // Day 2 of a 3-day trial: the day before the charge, as the paywall
        // timeline promises, and comfortably before it.
        XCTAssertTrue(calendar.isDate(
            fireDate,
            inSameDayAs: try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: trialEndsAt))
        ))
        XCTAssertLessThan(fireDate, trialEndsAt)
    }

    /// The delivery hour is a courtesy, not a reason to say nothing. A trial
    /// bought after 9am on its own notice day still gets the day-before warning,
    /// at the unshifted instant.
    func testTrialNoticeKeepsTheRawInstantWhenTheDeliveryHourHasPassed() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 15, minute: 0))
        )
        let trialEndsAt = try XCTUnwrap(calendar.date(byAdding: .hour, value: 30, to: now))

        let fireDate = try XCTUnwrap(
            NotificationService.trialNoticeDate(for: trialEndsAt, now: now, hour: 9)
        )

        XCTAssertEqual(fireDate, calendar.date(byAdding: .day, value: -1, to: trialEndsAt))
        XCTAssertGreaterThan(fireDate, now)
    }

    /// The trial notice is about the user's own money, not their plants, so the
    /// care and sitting switches must not silence it.
    func testTrialNoticeIsNotGatedOnTheCareSwitch() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let requests = NotificationService.makeRequests(
            plants: [],
            tasks: [],
            assignments: [],
            careEnabled: false,
            sittingEnabled: false,
            now: now,
            trialEndsAt: now.addingTimeInterval(5 * 86_400)
        )
        XCTAssertEqual(requests.count, 1)
    }

    // MARK: - Scheduling against a fake centre

    func testSynchronizeRemovesOnlyGrovesOwnPendingRequests() async {
        let centre = FakeNotificationCentre()
        centre.status = .authorized
        centre.pending = [
            "grove.care.\(UUID().uuidString)",
            "grove.overdue.\(UUID().uuidString)",
            "grove.trial.ending",
            "com.example.other.reminder"
        ]
        let service = NotificationService(center: centre)

        await service.synchronize(
            plants: [],
            tasks: [],
            assignments: [],
            careEnabled: true,
            sittingEnabled: true
        )

        XCTAssertEqual(centre.removedPending.filter { $0 == "com.example.other.reminder" }, [])
        XCTAssertEqual(centre.removedPending.count, 3)
    }

    func testSynchronizeTakesBackDeliveredBannersForDeletedPlants() async throws {
        let centre = FakeNotificationCentre()
        centre.status = .authorized
        let store = GroveStore(persistenceEnabled: false)
        let livePlant = try XCTUnwrap(store.plants.first)
        let deletedPlant = UUID()
        centre.deliveredNotifications = [
            DeliveredNotification(identifier: "grove.care.a", userInfo: ["plantID": livePlant.id.uuidString]),
            DeliveredNotification(identifier: "grove.care.b", userInfo: ["plantID": deletedPlant.uuidString]),
            // Not Grove's to take back, even though it names a plant that is gone.
            DeliveredNotification(identifier: "com.example.other", userInfo: ["plantID": deletedPlant.uuidString])
        ]
        let service = NotificationService(center: centre)

        await service.synchronize(
            plants: [livePlant],
            tasks: [],
            assignments: [],
            careEnabled: true,
            sittingEnabled: true
        )

        XCTAssertEqual(centre.removedDelivered, ["grove.care.b"])
    }

    func testCancelClearsPendingDeliveredAndTheBadge() async {
        let centre = FakeNotificationCentre()
        centre.status = .authorized
        centre.pending = ["grove.care.a", "com.example.other"]
        centre.deliveredNotifications = [
            DeliveredNotification(identifier: "grove.sitting.a", userInfo: [:]),
            DeliveredNotification(identifier: "com.example.other", userInfo: [:])
        ]
        centre.badge = 4
        let service = NotificationService(center: centre)

        await service.cancelScheduledReminders()

        XCTAssertEqual(centre.removedPending, ["grove.care.a"])
        XCTAssertEqual(centre.removedDelivered, ["grove.sitting.a"])
        XCTAssertEqual(centre.badge, 0)
        XCTAssertEqual(service.scheduledCount, 0)
    }

    /// Without permission there is nothing to schedule, and reporting a count
    /// would be reporting reminders that do not exist.
    func testSynchronizeSchedulesNothingWithoutPermission() async {
        let centre = FakeNotificationCentre()
        centre.status = .denied
        let store = GroveStore(persistenceEnabled: false)
        let service = NotificationService(center: centre)

        await service.synchronize(
            plants: store.plants,
            tasks: store.tasks,
            assignments: [],
            careEnabled: true,
            sittingEnabled: true
        )

        XCTAssertTrue(centre.added.isEmpty)
        XCTAssertEqual(service.scheduledCount, 0)
        XCTAssertEqual(service.authorization, .denied)
    }

    func testBadgeCountsOnlyWhatIsDueAndClearsWhenCareIsSwitchedOff() async {
        let centre = FakeNotificationCentre()
        centre.status = .authorized
        let store = GroveStore(persistenceEnabled: false)
        let plant = store.plants[0]
        let overdue = CareTask(
            id: UUID(), plantID: plant.id, kind: .water,
            dueDate: .now.addingTimeInterval(-86_400), detail: "",
            isCompleted: false, isSittingTask: false, ownerName: nil
        )
        let laterThisMonth = CareTask(
            id: UUID(), plantID: plant.id, kind: .checkIn,
            dueDate: .now.addingTimeInterval(20 * 86_400), detail: "",
            isCompleted: false, isSittingTask: false, ownerName: nil
        )
        let service = NotificationService(center: centre)

        await service.synchronize(
            plants: [plant], tasks: [overdue, laterThisMonth], assignments: [],
            careEnabled: true, sittingEnabled: false
        )
        XCTAssertEqual(centre.badge, 1, "Only work that is actually due belongs on the icon")

        await service.synchronize(
            plants: [plant], tasks: [overdue, laterThisMonth], assignments: [],
            careEnabled: false, sittingEnabled: false
        )
        XCTAssertEqual(centre.badge, 0, "Switching care reminders off has to take the badge with it")
    }

    func testPartialFailureReportsWhatActuallyGotScheduled() async {
        let centre = FakeNotificationCentre()
        centre.status = .authorized
        centre.failAddsAfter = 2
        let store = GroveStore(persistenceEnabled: false)
        let plant = store.plants[0]
        let tasks = (1...5).map { offset in
            CareTask(
                id: UUID(), plantID: plant.id, kind: .rotate,
                dueDate: .now.addingTimeInterval(Double(offset) * 86_400), detail: "",
                isCompleted: false, isSittingTask: false, ownerName: nil
            )
        }
        let service = NotificationService(center: centre)

        await service.synchronize(
            plants: [plant], tasks: tasks, assignments: [],
            careEnabled: true, sittingEnabled: false
        )

        // The count and the message used to contradict each other: zero
        // scheduled, next to copy saying *some* had failed.
        XCTAssertEqual(service.scheduledCount, 2)
        XCTAssertNotNil(service.errorMessage)
    }

    // MARK: - Tap and action routing

    func testLogCareActionPostsToTheRouterWithoutTouchingTheStore() async {
        IntentRouter.shared.pendingCareAction = nil
        let taskID = UUID()
        let service = NotificationService(center: FakeNotificationCentre())

        await service.handle(
            action: NotificationService.logCareAction,
            userInfo: ["taskID": taskID.uuidString, "plantID": UUID().uuidString]
        )

        XCTAssertEqual(
            IntentRouter.shared.pendingCareAction,
            PendingCareAction(taskID: taskID, outcome: .logged)
        )
        IntentRouter.shared.pendingCareAction = nil
    }

    /// A banner delivered before the check-in category existed still carries
    /// "Logged it". It must open the check-in rather than complete it, because
    /// completing it would record care with no photo and no observations.
    func testLoggedItOnAnOldCheckInBannerOpensTheCheckInInstead() async {
        IntentRouter.shared.pendingCareAction = nil
        IntentRouter.shared.requestedCheckInPlantID = nil
        IntentRouter.shared.requestedTab = nil
        let plantID = UUID()
        let service = NotificationService(center: FakeNotificationCentre())

        await service.handle(
            action: NotificationService.logCareAction,
            userInfo: [
                "plantID": plantID.uuidString,
                "taskID": UUID().uuidString,
                "kind": CareKind.checkIn.rawValue
            ]
        )

        XCTAssertNil(IntentRouter.shared.pendingCareAction)
        XCTAssertEqual(IntentRouter.shared.requestedCheckInPlantID, plantID)
        IntentRouter.shared.requestedCheckInPlantID = nil
        IntentRouter.shared.requestedTab = nil
    }

    func testCheckInNowActionOpensTheCheckIn() async {
        IntentRouter.shared.requestedCheckInPlantID = nil
        IntentRouter.shared.requestedTab = nil
        let plantID = UUID()
        let service = NotificationService(center: FakeNotificationCentre())

        await service.handle(
            action: NotificationService.checkInNowAction,
            userInfo: [
                "plantID": plantID.uuidString,
                "taskID": UUID().uuidString,
                "kind": CareKind.checkIn.rawValue
            ]
        )

        XCTAssertEqual(IntentRouter.shared.requestedCheckInPlantID, plantID)
        IntentRouter.shared.requestedCheckInPlantID = nil
        IntentRouter.shared.requestedTab = nil
    }

    func testTapOnACareReminderOpensItsPlant() async {
        IntentRouter.shared.requestedPlantID = nil
        let plantID = UUID()
        let service = NotificationService(center: FakeNotificationCentre())

        await service.handle(
            action: UNNotificationDefaultActionIdentifier,
            userInfo: ["plantID": plantID.uuidString, "taskID": UUID().uuidString]
        )

        XCTAssertEqual(IntentRouter.shared.requestedPlantID, plantID)
        IntentRouter.shared.requestedPlantID = nil
        IntentRouter.shared.requestedTab = nil
    }

    /// Sitting and trial notices carry a tab rather than a plant. Read rather
    /// than assumed, so a future kind cannot inherit the wrong destination.
    func testTapOnANoticeWithoutAPlantHonoursItsTab() async {
        IntentRouter.shared.requestedTab = nil
        let service = NotificationService(center: FakeNotificationCentre())

        await service.handle(
            action: UNNotificationDefaultActionIdentifier,
            userInfo: ["openTab": AppTab.profile.rawValue]
        )

        XCTAssertEqual(IntentRouter.shared.requestedTab, .profile)
        IntentRouter.shared.requestedTab = nil
    }

    /// A sitting invitation carries a deeper route as well as its tab, so a
    /// newer build lands on the Accept / Decline card instead of the Friends
    /// feed. Older builds never see this test's route and keep using `openTab`.
    func testSittingInvitationPushOpensPlantSitting() async {
        IntentRouter.shared.requestedTab = nil
        IntentRouter.shared.requestedRoute = nil
        IntentRouter.shared.requestedRouteTab = nil
        let service = NotificationService(center: FakeNotificationCentre())

        await service.handle(
            action: UNNotificationDefaultActionIdentifier,
            userInfo: ["openTab": "friends", "openRoute": "sitting"]
        )

        XCTAssertEqual(IntentRouter.shared.requestedRoute, .sitting)
        XCTAssertEqual(IntentRouter.shared.requestedRouteTab, .friends)
        XCTAssertNil(IntentRouter.shared.requestedTab)
        IntentRouter.shared.requestedRoute = nil
        IntentRouter.shared.requestedRouteTab = nil
    }

    func testDismissingANotificationNavigatesNowhere() async {
        IntentRouter.shared.requestedTab = nil
        IntentRouter.shared.requestedPlantID = nil
        let service = NotificationService(center: FakeNotificationCentre())

        await service.handle(
            action: UNNotificationDismissActionIdentifier,
            userInfo: ["plantID": UUID().uuidString]
        )

        XCTAssertNil(IntentRouter.shared.requestedPlantID)
        XCTAssertNil(IntentRouter.shared.requestedTab)
    }

    // MARK: - Device token

    func testFailedDeviceRegistrationRetriesDuringTheSameLaunch() async {
        UserDefaults.standard.removeObject(forKey: GroveDefaults.deviceToken)
        let service = NotificationService(center: FakeNotificationCentre())
        var attempts = 0
        service.onRegisterDeviceToken = { _, _ in
            attempts += 1
            return attempts > 1
        }

        service.acceptDeviceToken(Data([0x01, 0x02, 0x03]))
        while attempts == 0 { await Task.yield() }

        await service.retryRemotePushRegistration()
        XCTAssertEqual(attempts, 2, "a transient auth or network failure must stay retryable")

        await service.retryRemotePushRegistration()
        XCTAssertEqual(attempts, 2, "a successful registration should still be coalesced")
    }

    func testRevokingADeviceTokenTellsTheServerAndForgetsIt() async {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: GroveDefaults.deviceToken)
        let service = NotificationService(center: FakeNotificationCentre())
        var registered: [String] = []
        var revoked: [String] = []
        service.onRegisterDeviceToken = { token, _ in
            registered.append(token)
            return true
        }
        service.onRevokeDeviceToken = { revoked.append($0) }

        service.acceptDeviceToken(Data([0xAB, 0xCD, 0x01]))
        XCTAssertEqual(service.deviceToken, "abcd01")
        XCTAssertEqual(defaults.string(forKey: GroveDefaults.deviceToken), "abcd01")

        await service.revokeDeviceToken()
        XCTAssertEqual(revoked, ["abcd01"])
        XCTAssertNil(service.deviceToken)
        XCTAssertNil(
            defaults.string(forKey: GroveDefaults.deviceToken),
            "A token left behind keeps this phone on the signed-out account's send list"
        )
    }
}

// MARK: - Fake

@MainActor
private final class FakeNotificationCentre: NotificationScheduling {
    var delegate: (any UNUserNotificationCenterDelegate)?
    var status: UNAuthorizationStatus = .notDetermined
    var pending: [String] = []
    var deliveredNotifications: [DeliveredNotification] = []
    var added: [UNNotificationRequest] = []
    var removedPending: [String] = []
    var removedDelivered: [String] = []
    var categories: Set<UNNotificationCategory> = []
    var badge = 0
    /// Number of successful adds before `add` starts throwing.
    var failAddsAfter: Int?

    struct AddFailure: Error {}

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        status = .authorized
        return true
    }

    func pendingIdentifiers() async -> [String] { pending }

    func delivered() async -> [DeliveredNotification] { deliveredNotifications }

    func add(_ request: UNNotificationRequest) async throws {
        if let failAddsAfter, added.count >= failAddsAfter { throw AddFailure() }
        added.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPending += identifiers
        pending.removeAll { identifiers.contains($0) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDelivered += identifiers
        deliveredNotifications.removeAll { identifiers.contains($0.identifier) }
    }

    func setBadgeCount(_ count: Int) async throws { badge = count }
}
