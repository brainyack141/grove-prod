import XCTest
@testable import Grove

/// Regressions found by walking the ten ICP journeys in `GROVE.md` end to end.
/// Each test names the journey it came from and the wrong behaviour it pins.
@MainActor
final class ICPJourneyRegressionTests: XCTestCase {

    // MARK: - J9: plant sitting covers whole days

    /// Both sitting composers seed their pickers from `.now` and render them
    /// date-only, so the dates carried whatever o'clock the screen opened at.
    /// Stored raw, that became the real boundary: the sitter lost access
    /// mid-afternoon on the last day of the trip.
    func testSittingWindowCoversWholeDays() throws {
        let calendar = Calendar.current
        let threePmToday = try XCTUnwrap(
            calendar.date(bySettingHour: 15, minute: 22, second: 9, of: .now)
        )
        let threePmInAWeek = try XCTUnwrap(
            calendar.date(byAdding: .day, value: 7, to: threePmToday)
        )

        let window = SittingWindow.normalized(start: threePmToday, end: threePmInAWeek)

        XCTAssertEqual(window.start, calendar.startOfDay(for: threePmToday))
        XCTAssertTrue(
            calendar.isDate(window.end, inSameDayAs: threePmInAWeek),
            "The window must still end on the day the owner chose"
        )
        // The last instant of the final day, not the o'clock the composer opened.
        let startOfDayAfter = try XCTUnwrap(
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: threePmInAWeek))
        )
        XCTAssertLessThan(window.end, startOfDayAfter)
        XCTAssertGreaterThan(window.end, threePmInAWeek, "The final evening must still be covered")
    }

    /// A single-day trip is still a whole day, not a zero-length window.
    func testSittingWindowSurvivesASingleDayTrip() throws {
        let day = Date.now
        let window = SittingWindow.normalized(start: day, end: day)
        XCTAssertLessThan(window.start, window.end)
        XCTAssertTrue(Calendar.current.isDate(window.end, inSameDayAs: day))
    }

    /// An end before the start cannot produce a window that has already expired.
    func testSittingWindowClampsAnInvertedRange() throws {
        let start = Date.now
        let end = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -3, to: start))
        let window = SittingWindow.normalized(start: start, end: end)
        XCTAssertLessThanOrEqual(window.start, window.end)
    }

    /// An owner already abroad still chooses home calendar days. The display
    /// calendar supplies the visible year/month/day; the Grove timezone owns
    /// the actual access boundaries.
    func testSittingWindowMaterialisesPickerDaysInTheGroveTimeZone() throws {
        var displayCalendar = Calendar(identifier: .gregorian)
        displayCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let homeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        var homeCalendar = Calendar(identifier: .gregorian)
        homeCalendar.timeZone = homeZone

        let pickedStart = try XCTUnwrap(
            displayCalendar.date(from: DateComponents(year: 2026, month: 9, day: 10))
        )
        let pickedEnd = try XCTUnwrap(
            displayCalendar.date(from: DateComponents(year: 2026, month: 9, day: 12))
        )
        let window = SittingWindow.normalized(
            start: pickedStart,
            end: pickedEnd,
            timeZone: homeZone,
            displayCalendar: displayCalendar
        )

        XCTAssertEqual(
            homeCalendar.dateComponents([.year, .month, .day, .hour], from: window.start),
            DateComponents(year: 2026, month: 9, day: 10, hour: 0)
        )
        XCTAssertEqual(
            homeCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: window.end),
            DateComponents(year: 2026, month: 9, day: 12, hour: 23, minute: 59, second: 59)
        )
    }

    /// The store is where normalisation has to happen, because every caller —
    /// and the mutation each one sends to the server — reads the dates back off
    /// the object it returns.
    func testCreatedAssignmentIsActiveForTheWholeFinalDay() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Fig", location: "Lounge")
        let calendar = Calendar.current
        let lateToday = try XCTUnwrap(calendar.date(bySettingHour: 16, minute: 0, second: 0, of: .now))
        let lateInThreeDays = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: lateToday))

        let assignment = store.createSittingAssignment(
            sitterName: "Maya Kaur",
            startDate: lateToday,
            endDate: lateInThreeDays,
            plantIDs: [plant.id]
        )

        // Breakfast on the last day: previously already expired.
        let finalMorning = try XCTUnwrap(
            calendar.date(bySettingHour: 8, minute: 0, second: 0, of: lateInThreeDays)
        )
        XCTAssertNotEqual(assignment.currentStatus(now: finalMorning), .completed)

        // Late evening on the last day is still covered.
        let finalEvening = try XCTUnwrap(
            calendar.date(bySettingHour: 22, minute: 30, second: 0, of: lateInThreeDays)
        )
        XCTAssertNotEqual(assignment.currentStatus(now: finalEvening), .completed)

        // The morning after is not.
        let dayAfter = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: finalMorning))
        XCTAssertEqual(assignment.currentStatus(now: dayAfter), .completed)
    }

    /// The same for a share link, whose `isLive` gates whether the sitter's page
    /// resolves at all and whether the travel banner counts the grove as covered.
    func testCreatedSittingInviteStaysLiveForTheWholeFinalDay() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Fern", location: "Bathroom")
        let calendar = Calendar.current
        let lateToday = try XCTUnwrap(calendar.date(bySettingHour: 17, minute: 45, second: 0, of: .now))
        let lastDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 5, to: lateToday))

        let invite = store.createSittingInvite(
            sitterLabel: "Sam",
            startDate: lateToday,
            endDate: lastDay,
            plantIDs: [plant.id],
            canLogCare: true
        )
        store.attachShareURL(inviteID: invite.id, url: URL(string: "https://grove.test/s/abc")!)
        let live = try XCTUnwrap(store.sittingInvites.first { $0.id == invite.id })

        let finalMorning = try XCTUnwrap(
            calendar.date(bySettingHour: 7, minute: 0, second: 0, of: lastDay)
        )
        XCTAssertTrue(live.isLive(on: finalMorning))
        XCTAssertTrue(live.isOutstanding(on: finalMorning))
    }

    // MARK: - J4/J9: attribution

    /// "Care is collaborative but accountable." The owner completing their own
    /// check-in used to close the sitter's check-in task too, marking work done
    /// by someone who never did it.
    func testOwnerCheckInLeavesTheSittersCheckInTaskAlone() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Olive", location: "Balcony")
        let sitterTask = CareTask(
            id: UUID(),
            plantID: plant.id,
            kind: .checkIn,
            dueDate: .now,
            detail: "Sitter's look",
            isCompleted: false,
            isSittingTask: true,
            ownerName: "Maya"
        )
        store.tasks.append(sitterTask)

        store.applyCheckIn(plantID: plant.id, score: 80, band: .healthy, note: "Fine")

        let sitters = store.tasks.filter { $0.id == sitterTask.id }
        XCTAssertEqual(sitters.count, 1)
        XCTAssertFalse(
            try XCTUnwrap(sitters.first).isCompleted,
            "The sitter's task is their work and their attribution"
        )
        // The owner's own check-in still closed.
        XCTAssertTrue(
            store.tasks.contains { $0.plantID == plant.id && $0.kind == .checkIn && !$0.isSittingTask && $0.isCompleted }
        )
    }

    // MARK: - J5: a diagnosis is an inspection

    /// The streak advances on inspection and never on watering. A diagnosis is a
    /// photograph of a real plant and a look at what it shows, so the person
    /// whose plant is sick should not lose their streak for attending to it.
    func testDiagnosisAdvancesThePlantSafeStreak() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Calathea", location: "Study")
        store.gardener.currentStreak = 0
        store.gardener.lastTendDay = nil

        store.addDiagnosis(plantID: plant.id, result: Self.concerningResult(), photoURL: nil)

        XCTAssertEqual(store.gardener.currentStreak, 1)
        XCTAssertNotNil(store.gardener.lastTendDay)
    }

    /// Refining an existing diagnosis is the same look, and the streak is once a
    /// day regardless — so this must not be a second tend.
    func testRefiningADiagnosisDoesNotTendTwice() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Calathea", location: "Study")
        let diagnosisID = UUID()

        store.addDiagnosis(id: diagnosisID, plantID: plant.id, result: Self.concerningResult(), photoURL: nil)
        let afterFirst = store.gardener.currentStreak
        store.addDiagnosis(id: diagnosisID, plantID: plant.id, result: Self.concerningResult(), photoURL: nil)

        XCTAssertEqual(store.gardener.currentStreak, afterFirst)
        XCTAssertEqual(store.diagnoses.filter { $0.id == diagnosisID }.count, 1)
    }

    // MARK: - J7: the paywall

    /// `products.isEmpty` is equally true when the store has nothing to sell,
    /// when StoreKit threw, and before the first query resolves. Reading the
    /// last two as "unmetered" made airplane mode a paywall bypass.
    func testMeterStaysOnUntilTheCatalogueHasActuallyAnswered() {
        let premium = GrovePremiumStore()
        XCTAssertFalse(premium.didLoadCatalogue)
        XCTAssertFalse(
            premium.isUnmetered,
            "An unanswered catalogue is unknown, not empty — the meter must stay on"
        )
    }

    /// The same window, on screen: enforcement treats an unanswered catalogue
    /// as metered, but the meter must not draw until limits are proven.
    /// Drawing it on `!isUnmetered` flashed "free questions left" on every
    /// cold open of Ask, then yanked it when the store answered.
    func testMeterUIStaysHiddenUntilLimitsAreProven() {
        let premium = GrovePremiumStore()
        XCTAssertFalse(premium.isUnmetered, "Enforcement: unknown stays metered")
        XCTAssertFalse(premium.showsMeter, "Display: unknown draws no meter")
    }

    /// The escape hatch for a genuinely unsold product must not fire on the
    /// strength of a store that never answered.
    func testUnsoldPremiumIsNotGrantedWhenTheStoreNeverAnswered() {
        let premium = GrovePremiumStore()
        premium.grantUnsoldPremium()
        XCTAssertFalse(premium.hasPremium)
        XCTAssertFalse(premium.isUnmetered)
    }

    // MARK: - J7: the free-question meter travels

    /// The meter is stamped at midday UTC.
    ///
    /// Midday rather than midnight for the same reason the streak is: a stamp on
    /// a day boundary can be re-read as the neighbouring day. UTC rather than the
    /// device's calendar because the gateway counts the allowance in UTC and the
    /// gateway is what refuses the fourth question. A device-local day would also
    /// mean the meter reset whenever someone changed their time zone.
    func testAskMeterDayIsStampedAtMiddayUTC() throws {
        let suiteName = "AskMeterTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let ask = AskSession(storage: storage)
        ask.activate(accountID: "acct-1")

        _ = ask.remainingFreeAsks(hasPremium: false)

        let stamp = try XCTUnwrap(ask.meterDay)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(
            utc.component(.hour, from: stamp),
            12,
            "A midnight stamp re-read in another zone lands on the day before or after"
        )
        XCTAssertTrue(utc.isDate(stamp, inSameDayAs: .now))
    }

    // MARK: - J1: provider failures never impersonate accounts

    func testGoogleCompletionWithoutAnAuthServiceStaysSignedOut() async {
        let suiteName = "GoogleFallbackTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage)

        service.stashGoogleCredential(userID: "108423", idToken: "not-a-real-token", displayName: "Ari")
        let outcome = await service.completeOnboarding(method: .google, displayName: "Ari")

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(service.state, .signedOut)
        XCTAssertNotNil(service.signInError)
    }

    func testGoogleWithoutASubjectIDAlsoStaysSignedOut() async {
        let suiteName = "GoogleFallbackTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        defer { storage.removePersistentDomain(forName: suiteName) }
        let service = SessionService(storage: storage)

        service.stashGoogleCredential(userID: nil, idToken: "not-a-real-token", displayName: "Ari")
        let outcome = await service.completeOnboarding(method: .google, displayName: "Ari")

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(service.state, .signedOut)
    }

    // MARK: - Helpers

    private static func concerningResult() -> PlantAnalysisResult {
        PlantAnalysisResult(
            identification: PlantIdentificationResult(
                commonName: "Calathea",
                scientificName: "Goeppertia orbifolia",
                confidence: 81,
                alternatives: [],
                distinguishingTraits: []
            ),
            condition: PlantConditionResult(
                healthScore: 44,
                healthBand: .attention,
                confidence: 70,
                summary: "Crisping edges on several leaves.",
                positiveSigns: [],
                concerns: ["Crisp leaf margins"],
                possibleCauses: ["Dry air"],
                nextActions: ["Raise humidity"]
            ),
            providerName: "Test",
            limitations: []
        )
    }
}
