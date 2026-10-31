import UserNotifications
import XCTest
@testable import Grove

/// The parts of the Settings screen that can be wrong without anything looking
/// wrong: the reminder hour it writes, the sign-out warning it decides to show,
/// and the preferences "delete my data" has to reach.
@MainActor
final class SettingsBehaviourTests: XCTestCase {

    // MARK: - Reminder delivery hour

    func testChosenReminderHourReplacesTheDefaultMorningSlot() throws {
        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let task = CareTask(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
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
            now: Date(timeIntervalSince1970: 1_900_000_000),
            hour: 19
        )

        let trigger = try XCTUnwrap(requests.first?.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.dateComponents.hour, 19)
        XCTAssertEqual(trigger.dateComponents.minute, 0)
    }

    /// `@AppStorage` reads a missing or non-numeric value as `0`, which is a
    /// legitimate hour — but a corrupt or out-of-range one would silently move
    /// every reminder rather than fall back.
    func testOutOfRangeReminderHourFallsBackToTheDefault() {
        XCTAssertEqual(NotificationService.normalizedHour(-1), NotificationService.reminderHour)
        XCTAssertEqual(NotificationService.normalizedHour(24), NotificationService.reminderHour)
        XCTAssertEqual(NotificationService.normalizedHour(0), 0, "Midnight is a real choice, not a fallback")
        XCTAssertEqual(NotificationService.normalizedHour(23), 23)
    }

    func testReminderDateHonoursTheChosenHourOnTheDueDay() throws {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let dueDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: now))

        let fireDate = try XCTUnwrap(NotificationService.reminderDate(for: dueDate, now: now, hour: 7))
        XCTAssertEqual(calendar.component(.hour, from: fireDate), 7)
        XCTAssertTrue(calendar.isDate(fireDate, inSameDayAs: dueDate))
    }

    // MARK: - Sign-out recoverability

    /// The Settings sign-out dialog warns about permanent loss based on this
    /// property alone, so each account shape has to answer correctly. A local
    /// account is keyed by a UUID minted at onboarding: nothing can name it
    /// again after sign-out, and its Grove is stranded on disk forever.
    func testLocalOnlyAccountsAreReportedAsUnrecoverable() async {
        let suiteName = "SettingsRecoverability-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage)

        XCTAssertTrue(service.canRestoreCurrentAccountAfterSignOut, "Signed out: nothing to lose")

        // The demo grove — reachable now only from a UI-test launch argument —
        // has a fixed id, so it reopens.
        service.state = .signedIn(
            UserSession(accountID: "demo-local-account", mode: .demo, displayName: "Alex")
        )
        XCTAssertTrue(service.canRestoreCurrentAccountAfterSignOut, "The demo id is fixed and reopens")

        // The explicit device-only choice mints a fresh per-completion local id
        // — the case the warning exists for.
        await service.completeOnboarding(method: .device, displayName: "Ari")
        XCTAssertEqual(service.currentSession?.mode, .local)
        XCTAssertTrue(service.currentSession?.accountID.hasPrefix("local-") == true)
        XCTAssertFalse(
            service.canRestoreCurrentAccountAfterSignOut,
            "A per-completion local account cannot be signed back into and must warn before sign-out"
        )
    }

    func testLegacyProviderLabelledLocalAccountStillGetsThePermanentLossWarning() throws {
        let suiteName = "SettingsLegacyRecoverability-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        storage.set(
            try JSONEncoder().encode(
                UserSession(accountID: "google-108423", mode: .google, displayName: "Ari")
            ),
            forKey: "grove.user.session.v1"
        )

        let migrated = SessionService(storage: storage)
        XCTAssertEqual(migrated.currentSession?.mode, .local)
        XCTAssertEqual(migrated.currentSession?.accountID, "google-108423")
        XCTAssertFalse(
            migrated.canRestoreCurrentAccountAfterSignOut,
            "A provider label must not hide an old non-Supabase account id"
        )

        storage.set(
            try JSONEncoder().encode(
                UserSession(
                    accountID: "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
                    mode: .google,
                    displayName: "Ari"
                )
            ),
            forKey: "grove.user.session.v1"
        )
        XCTAssertTrue(SessionService(storage: storage).canRestoreCurrentAccountAfterSignOut)
    }

    func testEmailAccountDoesNotPromiseARecoveryDoorThatIsCurrentlyHidden() {
        let suiteName = "SettingsEmailRecoverability-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage)
        service.state = .signedIn(
            UserSession(
                accountID: "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
                mode: .email,
                displayName: "Ari"
            )
        )

        XCTAssertFalse(
            service.canRestoreCurrentAccountAfterSignOut,
            "The dialog must not promise a return while the public email button is disabled"
        )
    }

    // MARK: - Device preferences and consents

    /// "Delete my Grove data" promises that nothing Grove stored on the device
    /// survives — including keys no live code writes any more, such as the
    /// retired photo-processing consent. Left behind, a wiped device handed its
    /// reminder schedule and its history to whoever signed in next.
    func testResettingDefaultsClearsEveryPreferenceAndConsent() {
        let suiteName = "SettingsDefaults-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }

        storage.set(false, forKey: GroveDefaults.careReminders)
        storage.set(false, forKey: GroveDefaults.sittingUpdates)
        storage.set(21, forKey: GroveDefaults.reminderHour)
        storage.set(1, forKey: GroveDefaults.photoProcessingDisclosureVersion)
        storage.set(true, forKey: GroveDefaults.hasSeenScanTips)
        storage.set(true, forKey: GroveDefaults.friendsEmptyExampleDismissed)
        storage.set(false, forKey: GroveDefaults.hapticsEnabled)

        GroveDefaults.reset(in: storage)

        XCTAssertNil(storage.object(forKey: GroveDefaults.careReminders))
        XCTAssertNil(storage.object(forKey: GroveDefaults.sittingUpdates))
        XCTAssertNil(storage.object(forKey: GroveDefaults.reminderHour))
        XCTAssertNil(
            storage.object(forKey: GroveDefaults.photoProcessingDisclosureVersion),
            "A retired consent key still belongs to the previous user of this device"
        )
        XCTAssertNil(storage.object(forKey: GroveDefaults.hasSeenScanTips))
        XCTAssertNil(storage.object(forKey: GroveDefaults.friendsEmptyExampleDismissed))
        XCTAssertNil(
            storage.object(forKey: GroveDefaults.hapticsEnabled),
            "The haptics switch is a device preference the next owner must not inherit"
        )
    }

    /// The engine and the settings toggle read one key. Declared as a literal
    /// in each, they agreed only by luck — and the delete path, which walks
    /// `GroveDefaults`, could not reach a key it had never been told about.
    func testHapticsPreferenceKeyIsTheOneDeletionClears() {
        XCTAssertEqual(Haptics.preferenceKey, GroveDefaults.hapticsEnabled)
    }
}
