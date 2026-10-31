import SwiftUI

/// Today's quiet offer to arrange plant sitting, shown when the phone has
/// turned up in a different country from the grove.
///
/// It is a *banner* in the strict sense and not a sheet, an alert, or a
/// full-bleed hero. Someone who has just landed is holding a suitcase and does
/// not need Grove to take over the screen. It sits between the hero and the
/// day's work, it is one tap wide, and the dismiss is a real dismiss — the
/// trip is remembered as declined and this stays gone until the next one.
struct TravelBanner: View {
    let trip: AwayTrip
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                GroveArtworkTile(asset: "FriendsTravelHandoff", size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Away from \(trip.homeLabel)?")
                        .font(.headline)
                        .foregroundStyle(GroveTheme.ink)
                    Text("Set up sitting and send whoever's watering a link. They won't need the app.")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    Haptics.selection()
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(GroveTheme.subtleInk)
                        // A 44pt target around a small glyph, pulled back by
                        // the difference so the card's layout is unchanged.
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(-7)
                .accessibilityLabel("Not travelling")
            }

            NavigationLink(value: AppRoute.sittingLink) {
                Text("Set up sitting")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.accentStrong)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(GroveTheme.softAccent, in: Capsule())
            }
            .buttonStyle(GrovePressStyle())
            .accessibilityIdentifier("travelArrangeSitting")

            // The third answer. Grove asks about sitting because being away is
            // usually a trip, but sometimes it is a move, and until this existed
            // the only way to say so was to guess that the place name at the top
            // of Today was tappable. Offering it here costs a line and turns a
            // signal Grove already computes for free into the one repair path
            // the feature was missing.
            NavigationLink(value: AppRoute.groveLocation) {
                Text("I've moved, update my grove")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GroveTheme.mutedInk)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("travelIHaveMoved")
        }
        .groveCard()
        // One element to VoiceOver: the two buttons still land separately, but
        // the heading and its explanation are read as the single thought they
        // are rather than as two stops on the way to the action.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Away from \(trip.homeLabel)? Set up plant sitting.")
    }
}

/// Today's question, after a fortnight, about whether the grove itself moved.
///
/// This is the one thing Grove could not previously ask. The pin is set once,
/// deliberately never follows the phone — a pin that chased the phone would
/// re-base light, watering and weather guidance on a city the plants have never
/// been in — and so the only way it ever got corrected was a user working out
/// unaided that the place name on Today was tappable. Most did not, and read the
/// stale name as a bug instead.
///
/// It replaces the sitting banner rather than stacking under it: two weeks in,
/// the offer to arrange a sitter has either been taken or is moot, and "do you
/// live here now?" is the more useful question. Both answers are real answers —
/// "no" is remembered against this zone and never asked again for it.
struct MovedBanner: View {
    let trip: AwayTrip
    let onStayPut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                GroveArtworkTile(asset: "GroveLocation", size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Has your grove moved to \(trip.awayLabel)?")
                        .font(.headline)
                        .foregroundStyle(GroveTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    // Names the consequence rather than the setting. Nobody
                    // opens Grove to maintain a location; they will fix it
                    // because the light and watering advice is being read off
                    // the wrong city.
                    Text("You've been away a while. Light and weather advice still comes from \(trip.homeLabel).")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            NavigationLink(value: AppRoute.groveLocation) {
                Text("Update grove location")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.accentStrong)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(GroveTheme.softAccent, in: Capsule())
            }
            .buttonStyle(GrovePressStyle())
            .accessibilityIdentifier("moveUpdateLocation")

            Button {
                Haptics.selection()
                onStayPut()
            } label: {
                Text("No, my plants are still there")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GroveTheme.mutedInk)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("moveStayPut")
        }
        .groveCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Has your grove moved to \(trip.awayLabel)? Light and weather advice still comes from \(trip.homeLabel).")
    }
}

#Preview {
    NavigationStack {
        ScrollView {
            VStack(spacing: 16) {
                TravelBanner(
                    trip: AwayTrip(awayZoneIdentifier: "Europe/Lisbon", awayCountryCode: "PT", homeLabel: "Bristol"),
                    onDismiss: {}
                )
                MovedBanner(
                    trip: AwayTrip(awayZoneIdentifier: "Pacific/Auckland", awayCountryCode: "NZ", homeLabel: "Drury"),
                    onStayPut: {}
                )
            }
            .padding(GroveTheme.pagePadding)
        }
        .groveBackground()
    }
}
