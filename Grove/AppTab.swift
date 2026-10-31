import SwiftUI

/// The app's four destinations.
///
/// Scan is deliberately absent. The camera is a task you finish and leave, not
/// a place you dwell, so it is presented — see `ScanLaunch` — rather than
/// selected. It used to be both a tab and the raised button that opened it,
/// which meant tapping the biggest, brightest control in the app destroyed it,
/// left an empty 84pt well behind on every other screen, and gave VoiceOver two
/// separate controls for one action.
enum AppTab: String, CaseIterable, Identifiable {
    case today
    /// Ask opens Ari, the botanist coach. Replaced the Learn tab: a nine-lesson
    /// course ran out
    /// of content in nine days, while a coach that has read the user's grove
    /// never does. The lessons still exist — they live on the Journey map, which
    /// is where their badges and streak progress always came from.
    case ask
    case friends
    case profile

    var id: Self { self }

    var title: String {
        switch self {
        // "Today" over "Home": it names what is on the screen (work due now)
        // rather than where it sits, matches GROVE.md's canonical navigation,
        // and is what the UI tests look for.
        case .today: "Today"
        case .ask: "Ask"
        case .friends: "Friends"
        case .profile: "My Grove"
        }
    }

    /// My Grove uses a compact brand mark so it reads as the user's collection
    /// rather than one anonymous leaf. Ask uses the native filled leaf so
    /// it stays crisp and shares the system tinting of the other tab symbols.
    @ViewBuilder
    var tabLabel: some View {
        switch self {
        case .today: Label(title, systemImage: "house.fill")
        case .ask: Label(title, systemImage: "leaf.fill")
        case .friends: Label(title, systemImage: "person.2.fill")
        case .profile: Label(title, image: "TabGrove")
        }
    }
}
