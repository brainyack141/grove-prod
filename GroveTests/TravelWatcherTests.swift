import XCTest
@testable import Grove

/// The rule behind "are you travelling?".
///
/// Worth testing directly because the banner it drives is the kind of thing
/// that is either invisible or infuriating: a false positive nags somebody
/// sitting at home, and a false negative is a fortnight of unwatered plants.
final class TravelSignalTests: XCTestCase {
    private func home(
        country: String? = "GB",
        zone: String? = "Europe/London"
    ) -> GroveLocation {
        GroveLocation(
            latitude: 51.4545,
            longitude: -2.5879,
            label: "Bristol, United Kingdom",
            countryCode: country,
            timeZoneIdentifier: zone
        )
    }

    func testNoLocationMeansNoTrip() {
        XCTAssertNil(TravelSignal.trip(home: nil, currentZone: TimeZone(identifier: "Europe/Lisbon")!))
    }

    /// A pin saved before this feature existed cannot answer the question, and
    /// guessing from a bare coordinate is how you nag somebody at home.
    func testHomeWithoutATimeZoneStaysQuiet() {
        XCTAssertNil(
            TravelSignal.trip(
                home: home(country: nil, zone: nil),
                currentZone: TimeZone(identifier: "Asia/Tokyo")!
            )
        )
    }

    func testSameZoneIsHome() {
        XCTAssertNil(
            TravelSignal.trip(home: home(), currentZone: TimeZone(identifier: "Europe/London")!)
        )
    }

    func testDifferentZoneWithoutAConfirmedCountryIsATrip() {
        let trip = TravelSignal.trip(home: home(), currentZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(trip?.awayZoneIdentifier, "Asia/Tokyo")
        XCTAssertNil(trip?.awayCountryCode)
        XCTAssertEqual(trip?.homeLabel, "Bristol")
    }

    /// Seattle to New York changes the zone and nothing else that matters. The
    /// country is the thing the feature is actually about, so when it can be
    /// confirmed it overrules the zone.
    func testConfirmedSameCountryIsHomeEvenAcrossZones() {
        let seattle = GroveLocation(
            latitude: 47.6062,
            longitude: -122.3321,
            label: "Seattle, United States",
            countryCode: "US",
            timeZoneIdentifier: "America/Los_Angeles"
        )
        XCTAssertNil(
            TravelSignal.trip(
                home: seattle,
                currentZone: TimeZone(identifier: "America/New_York")!,
                currentCountryCode: "US"
            )
        )
    }

    func testConfirmedDifferentCountryIsATrip() {
        let trip = TravelSignal.trip(
            home: home(),
            currentZone: TimeZone(identifier: "Europe/Lisbon")!,
            currentCountryCode: "pt"
        )
        XCTAssertEqual(trip?.awayCountryCode, "PT")
    }

    /// London and Lisbon share an offset all year. Without a country to go on
    /// the zone rule deliberately lets this pass as home rather than risk
    /// nagging every user whose phone renames their own zone.
    func testSameOffsetWithoutACountryIsTreatedAsHome() {
        XCTAssertNil(
            TravelSignal.trip(
                home: home(),
                currentZone: TimeZone(identifier: "Europe/Lisbon")!
            )
        )
    }

    /// ...but the same hop *with* a country confirmed is a real trip.
    func testSameOffsetWithAConfirmedCountryIsATrip() {
        XCTAssertNotNil(
            TravelSignal.trip(
                home: home(),
                currentZone: TimeZone(identifier: "Europe/Lisbon")!,
                currentCountryCode: "PT"
            )
        )
    }

    /// The label is only ever flavour in a question, but it is read off an
    /// identifier, so it is worth pinning the two shapes zones actually come in.
    func testAwayLabelReadsTheCityOffTheZone() {
        XCTAssertEqual(
            AwayTrip(awayZoneIdentifier: "Pacific/Auckland", awayCountryCode: "NZ", homeLabel: "Drury").awayLabel,
            "Auckland"
        )
        XCTAssertEqual(
            AwayTrip(awayZoneIdentifier: "America/Argentina/Buenos_Aires", awayCountryCode: "AR", homeLabel: "Drury").awayLabel,
            "Buenos Aires"
        )
    }
}

/// The rule behind "have you moved?".
///
/// The asymmetry it encodes is the whole feature: asking late costs a fortnight
/// of forecasts from the wrong city, asking early interrupts a holiday to
/// question where somebody lives. So the threshold is slow and the "no" is
/// permanent for that zone.
final class MoveSignalTests: XCTestCase {
    private let auckland = AwayTrip(
        awayZoneIdentifier: "Pacific/Auckland",
        awayCountryCode: "NZ",
        homeLabel: "Drury"
    )

    private func daysAgo(_ days: Int) -> Date {
        Date(timeIntervalSinceNow: -Double(days) * 86_400)
    }

    func testBeingHomeIsNeverAMove() {
        XCTAssertNil(TravelSignal.moved(trip: nil, awaySince: daysAgo(90), dismissedZone: nil))
    }

    /// A trip Grove has only just noticed cannot be a move yet, however far away
    /// it is — the clock, not the distance, is what separates the two.
    func testAFreshTripIsNotAMove() {
        XCTAssertNil(TravelSignal.moved(trip: auckland, awaySince: daysAgo(2), dismissedZone: nil))
    }

    func testAHolidayLengthTripIsNotAMove() {
        XCTAssertNil(TravelSignal.moved(trip: auckland, awaySince: daysAgo(13), dismissedZone: nil))
    }

    func testAFortnightInTheSameNewZoneIsWorthAsking() {
        XCTAssertNotNil(TravelSignal.moved(trip: auckland, awaySince: daysAgo(14), dismissedZone: nil))
    }

    /// Without a start date there is no count, and guessing one from the trip
    /// alone would ask everybody who has just landed.
    func testNoClockMeansNoQuestion() {
        XCTAssertNil(TravelSignal.moved(trip: auckland, awaySince: nil, dismissedZone: nil))
    }

    func testAnsweringNoSilencesThatZoneForGood() {
        XCTAssertNil(
            TravelSignal.moved(trip: auckland, awaySince: daysAgo(60), dismissedZone: "Pacific/Auckland")
        )
    }

    /// ...but only that zone. Somebody who spends every winter in one place and
    /// then genuinely moves somewhere else still gets asked about the new one.
    func testAnsweringNoDoesNotSilenceTheNextPlace() {
        let lisbon = AwayTrip(awayZoneIdentifier: "Europe/Lisbon", awayCountryCode: "PT", homeLabel: "Drury")
        XCTAssertNotNil(
            TravelSignal.moved(trip: lisbon, awaySince: daysAgo(60), dismissedZone: "Pacific/Auckland")
        )
    }
}

/// What the banner does with a trip once it has one.
@MainActor
final class TravelPromptTests: XCTestCase {
    private func makeStore() -> GroveStore {
        // No fixture assignment: the default store ships with an upcoming one,
        // which is exactly the cover these tests are checking for.
        let store = GroveStore(assignments: [], persistenceEnabled: false)
        store.updateGroveLocation(
            GroveLocation(
                latitude: 51.4545,
                longitude: -2.5879,
                label: "Bristol, United Kingdom",
                countryCode: "GB",
                timeZoneIdentifier: "Europe/London"
            )
        )
        return store
    }

    private func makeWatcher() -> (TravelWatcher, UserDefaults) {
        let suite = UserDefaults(suiteName: "travel-\(UUID().uuidString)")!
        return (TravelWatcher(storage: suite), suite)
    }

    /// Cover starts when somebody opens the minted care sheet, not when the row
    /// or URL merely exists.
    func testASittingLinkSilencesTheBannerOnlyOnceItHasBeenOpened() {
        let store = makeStore()
        let plant = store.plants[0]
        XCTAssertFalse(store.hasSittingCover(on: .now), "fixtures should start uncovered")

        let invite = store.createSittingInvite(
            sitterLabel: "Neighbour",
            startDate: .now,
            endDate: Calendar.current.date(byAdding: .day, value: 5, to: .now)!,
            plantIDs: [plant.id],
            canLogCare: true
        )
        XCTAssertFalse(
            store.hasSittingCover(on: .now),
            "A row with no URL means nobody was sent anything"
        )

        store.attachShareURL(inviteID: invite.id, url: URL(string: "https://grove.example/sit/token")!)
        XCTAssertFalse(store.hasSittingCover(on: .now), "An unopened message is not accepted cover")
        let index = store.sittingInvites.firstIndex { $0.id == invite.id }!
        store.sittingInvites[index].lastOpenedAt = .now
        store.sittingInvites[index].openCount = 1
        XCTAssertTrue(store.hasSittingCover(on: .now))
    }

    func testAFinishedLinkStopsCounting() {
        let store = makeStore()
        let ended = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        let invite = store.createSittingInvite(
            sitterLabel: "Neighbour",
            startDate: Calendar.current.date(byAdding: .day, value: -8, to: .now)!,
            endDate: ended,
            plantIDs: [store.plants[0].id],
            canLogCare: true
        )
        // Minted, so this tests the end date rather than passing for the
        // unrelated reason that the link was never created.
        store.attachShareURL(inviteID: invite.id, url: URL(string: "https://grove.example/sit/token")!)
        let index = store.sittingInvites.firstIndex { $0.id == invite.id }!
        store.sittingInvites[index].lastOpenedAt = .now
        XCTAssertFalse(store.hasSittingCover(on: .now))
    }

    func testAFutureLinkDoesNotClaimCoverBeforeItsStartDate() {
        let store = makeStore()
        let start = Calendar.current.date(byAdding: .day, value: 3, to: .now)!
        let invite = store.createSittingInvite(
            sitterLabel: "Neighbour",
            startDate: start,
            endDate: Calendar.current.date(byAdding: .day, value: 8, to: .now)!,
            plantIDs: [store.plants[0].id],
            canLogCare: true
        )
        store.attachShareURL(inviteID: invite.id, url: URL(string: "https://grove.example/sit/token")!)
        let index = store.sittingInvites.firstIndex { $0.id == invite.id }!
        store.sittingInvites[index].lastOpenedAt = .now

        XCTAssertFalse(store.hasSittingCover(on: .now))
        XCTAssertTrue(store.hasSittingCover(on: Calendar.current.startOfDay(for: start)))
    }

    func testRevokingKillsTheLinkImmediately() {
        let store = makeStore()
        let invite = store.createSittingInvite(
            sitterLabel: "Neighbour",
            startDate: .now,
            endDate: Calendar.current.date(byAdding: .day, value: 5, to: .now)!,
            plantIDs: [store.plants[0].id],
            canLogCare: true
        )
        store.attachShareURL(inviteID: invite.id, url: URL(string: "https://grove.example/sit/token")!)
        let index = store.sittingInvites.firstIndex { $0.id == invite.id }!
        store.sittingInvites[index].lastOpenedAt = .now
        XCTAssertTrue(store.hasSittingCover(on: .now), "covered before the revoke")

        store.revokeSittingInvite(id: invite.id)
        XCTAssertFalse(store.hasSittingCover(on: .now))
    }

    /// Dismissal is per-trip, not forever: the same zone stays quiet, the next
    /// one gets to ask again.
    func testDismissalIsScopedToTheTrip() {
        let (watcher, storage) = makeWatcher()
        let lisbon = AwayTrip(awayZoneIdentifier: "Europe/Lisbon", awayCountryCode: "PT", homeLabel: "Bristol")
        watcher.dismiss(lisbon)
        let remembered = storage.string(forKey: GroveDefaults.travelPromptDismissedZone)

        XCTAssertNil(
            TravelSignal.promptable(trip: lisbon, plantCount: 4, hasSittingCover: false, dismissedZone: remembered)
        )
        let tokyo = AwayTrip(awayZoneIdentifier: "Asia/Tokyo", awayCountryCode: "JP", homeLabel: "Bristol")
        XCTAssertNotNil(
            TravelSignal.promptable(trip: tokyo, plantCount: 4, hasSittingCover: false, dismissedZone: remembered)
        )
    }

    /// The two questions are separate, so the two answers have to be. Waving off
    /// the offer of a plant sitter is not somebody telling Grove where they
    /// live, and if one key served both, a single tap on the sitting banner's
    /// close button would permanently suppress the only prompt that ever repairs
    /// a stale grove location.
    func testDismissingSittingDoesNotAnswerTheMoveQuestion() {
        let (watcher, storage) = makeWatcher()
        let auckland = AwayTrip(awayZoneIdentifier: "Pacific/Auckland", awayCountryCode: "NZ", homeLabel: "Drury")
        let longAgo = Date(timeIntervalSinceNow: -60 * 86_400)

        watcher.dismiss(auckland)
        XCTAssertNotNil(
            TravelSignal.moved(
                trip: auckland,
                awaySince: longAgo,
                dismissedZone: storage.string(forKey: GroveDefaults.movePromptDismissedZone)
            ),
            "declining a sitter must leave the move question askable"
        )

        watcher.dismissMove(auckland)
        XCTAssertNil(
            TravelSignal.moved(
                trip: auckland,
                awaySince: longAgo,
                dismissedZone: storage.string(forKey: GroveDefaults.movePromptDismissedZone)
            )
        )
        XCTAssertEqual(
            storage.string(forKey: GroveDefaults.travelPromptDismissedZone),
            "Pacific/Auckland",
            "and the sitting dismissal is untouched by the move answer"
        )
    }

    func testAGroveWithNoPlantsIsNeverAsked() {
        let lisbon = AwayTrip(awayZoneIdentifier: "Europe/Lisbon", awayCountryCode: "PT", homeLabel: "Bristol")
        XCTAssertNil(
            TravelSignal.promptable(trip: lisbon, plantCount: 0, hasSittingCover: false, dismissedZone: nil)
        )
    }

    func testCoverSilencesTheBanner() {
        let lisbon = AwayTrip(awayZoneIdentifier: "Europe/Lisbon", awayCountryCode: "PT", homeLabel: "Bristol")
        XCTAssertNil(
            TravelSignal.promptable(trip: lisbon, plantCount: 4, hasSittingCover: true, dismissedZone: nil)
        )
    }

    func testDeletingTheLastPlantRetiresItsLink() {
        let store = makeStore()
        let plant = store.plants[0]
        let invite = store.createSittingInvite(
            sitterLabel: "Neighbour",
            startDate: .now,
            endDate: Calendar.current.date(byAdding: .day, value: 5, to: .now)!,
            plantIDs: [plant.id],
            canLogCare: true
        )
        store.deletePlant(id: plant.id)
        let retired = store.sittingInvites.first { $0.id == invite.id }
        XCTAssertTrue(retired?.isRevocationPending ?? false)
        XCTAssertFalse(retired?.isRevoked ?? true, "server confirmation, not optimism, makes a link revoked")
    }
}
