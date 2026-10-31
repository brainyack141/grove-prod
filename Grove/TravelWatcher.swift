import CoreLocation
import Foundation
import Observation

/// A trip Grove believes the owner is on: the phone is somewhere the grove is
/// not. Identified by the time zone the phone is reporting, because that is the
/// one thing that reliably changes when you land somewhere and stays changed
/// for as long as you are there.
struct AwayTrip: Equatable, Hashable {
    /// IANA identifier of the zone the phone is in. Doubles as the trip's
    /// identity: a dismissal is remembered against this, so the *next* trip is
    /// allowed to ask again while this one stays quiet.
    var awayZoneIdentifier: String
    /// ISO country code the phone is in, when it could be confirmed without
    /// asking for anything. Nil means "we only have the time zone to go on".
    var awayCountryCode: String?
    /// What to call the place they left, e.g. "Bristol".
    var homeLabel: String

    /// A human name for where the phone is, read off the time zone.
    ///
    /// IANA zones are named after cities on purpose, so the last path component
    /// is a place name nearly every time — "Pacific/Auckland" is Auckland and
    /// "America/Argentina/Buenos_Aires" is Buenos Aires. It is only ever used as
    /// flavour in a question ("moved to Auckland?"), never as a fact Grove acts
    /// on, so the occasional zone that names a region rather than a city costs
    /// nothing.
    var awayLabel: String {
        awayZoneIdentifier
            .split(separator: "/").last
            .map { $0.replacingOccurrences(of: "_", with: " ") }
            ?? awayZoneIdentifier
    }
}

/// The rule that turns "where the grove is" plus "what the phone says" into a
/// trip, kept free of CoreLocation so it can be reasoned about and tested
/// directly.
///
/// Two sources of truth, deliberately ranked:
///
/// 1. **Country, when we know both ends.** The feature is about leaving the
///    country, so if the phone's country can be confirmed, that is the whole
///    answer — Seattle to New York is a time zone away but nobody needs a
///    plant sitter briefing for it, and London to Lisbon is a real trip that
///    shares an offset.
/// 2. **Time zone, when we cannot.** Confirming the country needs a location
///    fix, and Grove will not raise a permission prompt to power a banner. So
///    when the country is unknown the test falls back to the zone, and is
///    deliberately strict about it: the identifier must differ *and* the
///    current offset from GMT must differ too. That ignores the common case of
///    the phone naming the same place differently ("GMT" for "Europe/London")
///    at the price of missing same-offset border hops, which the banner's own
///    wording — a question, not an assertion — can afford.
enum TravelSignal {
    static func trip(
        home: GroveLocation?,
        currentZone: TimeZone = .current,
        currentCountryCode: String? = nil,
        now: Date = .now
    ) -> AwayTrip? {
        guard let home else { return nil }
        // Nothing to compare against yet. `TravelWatcher` repairs this by
        // reverse-geocoding the stored pin, and the next pass reads it.
        guard let homeZoneIdentifier = home.timeZoneIdentifier,
              let homeZone = TimeZone(identifier: homeZoneIdentifier) else { return nil }

        let away: Bool
        if let currentCountryCode, let homeCountry = home.countryCode {
            away = currentCountryCode.uppercased() != homeCountry.uppercased()
        } else {
            away = currentZone.identifier != homeZone.identifier
                && currentZone.secondsFromGMT(for: now) != homeZone.secondsFromGMT(for: now)
        }
        guard away else { return nil }

        return AwayTrip(
            awayZoneIdentifier: currentZone.identifier,
            awayCountryCode: currentCountryCode?.uppercased(),
            homeLabel: home.shortLabel
        )
    }

    /// Whether a trip is worth putting a banner on screen for.
    ///
    /// Being away is necessary and nowhere near sufficient: Grove asks only
    /// when there is something to arrange, nothing already arranged, and the
    /// user has not already waved this trip away.
    static func promptable(
        trip: AwayTrip?,
        plantCount: Int,
        hasSittingCover: Bool,
        dismissedZone: String?
    ) -> AwayTrip? {
        guard let trip, plantCount > 0, !hasSittingCover else { return nil }
        guard dismissedZone != trip.awayZoneIdentifier else { return nil }
        return trip
    }

    /// How long the phone has to stay put somewhere new before Grove stops
    /// reading it as a trip and starts asking whether the grove itself moved.
    ///
    /// Two weeks is chosen to sit past the long end of a holiday. It is
    /// deliberately slow: the cost of asking late is a fortnight of forecasts
    /// from the old city, and the cost of asking early is interrupting someone's
    /// holiday to query where they live.
    static let moveThresholdDays = 14

    /// Whether the trip has gone on long enough to be a move worth asking about.
    ///
    /// The grove's pin is never rewritten from this — nothing in Grove writes it
    /// except the picker, because a pin that follows the phone would silently
    /// re-base light and watering guidance on a city the plants have never been
    /// in. All this earns is the right to put a question on screen.
    ///
    /// Note what is deliberately *not* a gate here: sitting cover and the
    /// sitting banner's own dismissal. Someone who arranged a sitter and then
    /// turned out to have moved still has a wrong pin, and the whole point of
    /// separating the two dismissals is that "no thanks" to a sitter is not an
    /// answer to "do you live here now?".
    static func moved(
        trip: AwayTrip?,
        awaySince: Date?,
        dismissedZone: String?,
        now: Date = .now,
        thresholdDays: Int = moveThresholdDays
    ) -> AwayTrip? {
        guard let trip, let awaySince else { return nil }
        guard dismissedZone != trip.awayZoneIdentifier else { return nil }
        let elapsed = now.timeIntervalSince(awaySince)
        guard elapsed >= Double(thresholdDays) * 86_400 else { return nil }
        return trip
    }
}

/// Watches, quietly, for the owner having gone away, so Today can offer to set
/// up plant sitting before the plants notice.
///
/// The whole design constraint is that this must cost the user nothing. It
/// never requests location permission — it reads the phone's time zone, which
/// is free, and only takes a position fix if permission happens to already be
/// granted for the "use my current location" button in the grove picker. A user
/// who never granted it still gets the banner, just on the time-zone rule alone.
@MainActor
@Observable
final class TravelWatcher: NSObject {
    /// The trip in progress, or nil for "as far as Grove can tell, home".
    private(set) var trip: AwayTrip?
    /// When the phone was first seen in the current away zone. Survives launches
    /// — the whole question it answers is "how long has this been going on?",
    /// which nothing held only in memory could ever answer.
    private(set) var awaySince: Date?

    @ObservationIgnored private let storage: UserDefaults
    @ObservationIgnored private let geocoder = CLGeocoder()
    @ObservationIgnored private let manager = CLLocationManager()
    /// Set once a pass is running so a re-entrant `refresh` (Today's `task`
    /// re-firing on a store change) does not stack geocoder work.
    @ObservationIgnored private var isRefreshing = false
    /// True when the trip came from the debug launch argument rather than from
    /// the world, in which case the gates below are skipped — the point of the
    /// flag is to see the banner, and a fixture grove is always "covered".
    @ObservationIgnored private var isForced = false
    /// As `isForced`, for the debug flag that forces the move question.
    @ObservationIgnored private var isForcedMove = false

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        super.init()
    }

    // MARK: - Refresh

    /// Re-reads the phone against the stored grove. Cheap enough to call on
    /// every appearance of Today: the only network work is a reverse geocode,
    /// and only when something is genuinely unknown.
    func refresh(store: GroveStore) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

#if DEBUG
        // There is no way to test this feature short of leaving the country.
        if ProcessInfo.processInfo.arguments.contains("-GroveForceTravelBanner") {
            isForced = true
            trip = AwayTrip(
                awayZoneIdentifier: "Europe/Lisbon",
                awayCountryCode: "PT",
                homeLabel: store.profile.location?.shortLabel ?? "home"
            )
            awaySince = .now
            return
        }
        // ...and no way at all to test the move question short of emigrating,
        // which is why the away clock is forced back a month here rather than
        // waited out.
        if ProcessInfo.processInfo.arguments.contains("-GroveForceMoveBanner") {
            isForcedMove = true
            trip = AwayTrip(
                awayZoneIdentifier: "Pacific/Auckland",
                awayCountryCode: "NZ",
                homeLabel: store.profile.location?.shortLabel ?? "home"
            )
            awaySince = Date(timeIntervalSinceNow: -30 * 86_400)
            return
        }
#endif

        await backfillHomeIfNeeded(store: store)
        guard let home = store.profile.location else {
            trip = nil
            forgetAwayClock()
            return
        }
        trip = TravelSignal.trip(
            home: home,
            currentZone: .current,
            currentCountryCode: await currentCountryCode()
        )
        awaySince = updatedAwayClock(for: trip)
    }

    // MARK: - The away clock

    /// Starts, keeps, or clears the record of when this stretch away began.
    ///
    /// Being home clears it, which is what makes the count mean "consecutively":
    /// two separate week-long trips to the same city must not add up to a move.
    private func updatedAwayClock(for trip: AwayTrip?, now: Date = .now) -> Date? {
        guard let trip else {
            forgetAwayClock()
            return nil
        }
        let storedZone = storage.string(forKey: GroveDefaults.travelZoneFirstSeenZone)
        let storedDate = storage.object(forKey: GroveDefaults.travelZoneFirstSeenDate) as? Date
        if storedZone == trip.awayZoneIdentifier, let storedDate {
            return storedDate
        }
        storage.set(trip.awayZoneIdentifier, forKey: GroveDefaults.travelZoneFirstSeenZone)
        storage.set(now, forKey: GroveDefaults.travelZoneFirstSeenDate)
        return now
    }

    private func forgetAwayClock() {
        storage.removeObject(forKey: GroveDefaults.travelZoneFirstSeenZone)
        storage.removeObject(forKey: GroveDefaults.travelZoneFirstSeenDate)
    }

    /// Teaches a pin saved before this feature existed which country and time
    /// zone it is in. Reverse geocoding a coordinate the user already chose
    /// needs no permission — it is the *phone's* position that is private, and
    /// this never asks for it.
    private func backfillHomeIfNeeded(store: GroveStore) async {
        guard var home = store.profile.location,
              home.countryCode == nil || home.timeZoneIdentifier == nil else { return }
        guard let placemark = try? await geocoder.reverseGeocodeLocation(
            CLLocation(latitude: home.latitude, longitude: home.longitude)
        ).first else { return }
        home.countryCode = placemark.isoCountryCode?.uppercased()
        home.timeZoneIdentifier = placemark.timeZone?.identifier
        guard home.countryCode != nil || home.timeZoneIdentifier != nil else { return }
        store.updateGroveLocation(home)
    }

    /// The country the phone is in, or nil when that cannot be established
    /// without asking. Never prompts.
    private func currentCountryCode() async -> String? {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: return nil
        }
        guard let location = manager.location else { return nil }
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
        return placemark.isoCountryCode?.uppercased()
    }

    // MARK: - Whether to say anything

    /// The trip worth putting a banner on screen for, if any.
    func promptableTrip(store: GroveStore, now: Date = .now) -> AwayTrip? {
        if isForced { return trip }
        if isForcedMove { return nil }
        return TravelSignal.promptable(
            trip: trip,
            plantCount: store.plants.count,
            hasSittingCover: store.hasSittingCover(on: now),
            dismissedZone: dismissedZone
        )
    }

    /// The trip that has gone on long enough to be worth asking whether the
    /// grove moved, if any.
    func movedPrompt(now: Date = .now) -> AwayTrip? {
        if isForcedMove { return trip }
        if isForced { return nil }
        return TravelSignal.moved(
            trip: trip,
            awaySince: awaySince,
            dismissedZone: moveDismissedZone,
            now: now
        )
    }

    /// Remembers that this trip was declined. Keyed to the away zone, so coming
    /// home and leaving again asks once more — which is the point.
    func dismiss(_ trip: AwayTrip) {
        storage.set(trip.awayZoneIdentifier, forKey: GroveDefaults.travelPromptDismissedZone)
    }

    /// Remembers that the user said they had not moved. Keyed to the zone for
    /// the same reason, and separately from the sitting dismissal so that
    /// declining a sitter never doubles as an answer about where they live.
    func dismissMove(_ trip: AwayTrip) {
        storage.set(trip.awayZoneIdentifier, forKey: GroveDefaults.movePromptDismissedZone)
    }

    private var dismissedZone: String? {
        storage.string(forKey: GroveDefaults.travelPromptDismissedZone)
    }

    private var moveDismissedZone: String? {
        storage.string(forKey: GroveDefaults.movePromptDismissedZone)
    }
}
