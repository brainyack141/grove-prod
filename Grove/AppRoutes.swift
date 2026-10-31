import SwiftUI

enum AppRoute: Hashable {
    case plant(UUID)
    case collection(UUID)
    case checkIn(UUID)
    case careTask(UUID)
    /// The live camera, opened with the mode already decided (and optionally a
    /// plant it belongs to). Entry points that know what the user came to do
    /// push this rather than the mode chooser.
    case liveScan(ScanMode, UUID?)
    case scanResult(ScanMode)
    case plantScanResult(UUID, ScanMode)
    case addPlant
    /// The whole care queue. Today shows what is due now and stops; "see all"
    /// pushes here rather than switching the home page into a different mode,
    /// so Back works and the queue is somewhere a notification can point.
    case care
    case sitting
    /// A sitting link for one named plant, opened from that plant's own page.
    ///
    /// `sitting` carries no payload, so arranging cover from a plant page threw
    /// away the plant the user was standing on and dropped them on a grove-wide
    /// screen — where an empty preselection means *every* plant gets ticked,
    /// the opposite of the "only these ones are fussy" distinction they opened
    /// the page to make. Collections could already preselect; plants could not.
    case sittingLinkForPlant(UUID)
    /// Straight to making a shareable sitting link, skipping the sitting
    /// overview. The travel banner lands here: someone who has just landed
    /// abroad has already decided.
    ///
    /// The composer it opens carries both handovers now, so landing here no
    /// longer decides for the user that their sitter isn't on Grove.
    case sittingLink
    /// The same composer, opened with the in-app handover already chosen.
    case sittingFriend
    case settings
    case editPlant(UUID)
    case plantHistory(UUID)
    /// The curated visual history reached from a plant's single Story button.
    case plantStory(UUID)
    case plantDiagnosis(UUID)
    case scanHistory
    case friends
    /// An actionable web invitation. The optional username pre-fills the
    /// recipient's request after a universal link opens Grove.
    case inviteFriend(String?)
    case friendGrove(String)
    case friendInvitations
    case editProfile
    case groveLocation
    case plan
    case activity
    /// A personal, evidence-weighted measure of how well this grove is being
    /// cared for. Kept as a pushed page so the score's recommended action can
    /// continue deeper into the same Today navigation stack.
    case groveScore
    /// An Academy lesson. Still reached from the Journey map's lesson nodes after
    /// the Learn tab was retired — the curriculum outlived its tab.
    case learnTopic(String)
    /// One botanist conversation.
    case askThread(UUID)
    /// A new botanist conversation about a specific plant, opened from that
    /// plant's record.
    case askAbout(UUID)
    /// The plant page's scan takeaway opens Ari with an editable follow-up
    /// already in the composer. It is separate from `askAbout` so entering the
    /// general plant conversation never assumes what the person wants to ask.
    case askAboutLatestScan(UUID, initialDraft: String)
    case journey
    /// Opens the Journey map with one accessible, non-chest milestone already
    /// presented. Used by onboarding entry points that promise a specific step
    /// rather than dropping somebody at the map and making them hunt for it.
    case journeyMilestone(String)
    case achievements
}

/// A request to open the camera as a cover over whatever the user was doing.
///
/// The raised Scan button, a Siri shortcut and a launch argument all raise one
/// of these; `AppShellView` turns it into a `fullScreenCover`. `mode` is nil
/// when the user came in without saying what they want — the camera then stops
/// at its own "What next?" chooser. The `id` is what makes a second request for
/// the *same* mode present again rather than being swallowed as a no-op.
struct ScanLaunch: Identifiable, Hashable {
    let id = UUID()
    var mode: ScanMode?
    var plantID: UUID?
}

extension AppRoute {
    /// Whether this destination should grow out of the thing that was tapped.
    ///
    /// Only routes that are reached by tapping a *picture of themselves* — a
    /// plant's card, a collection's tile, a friend's row — earn the zoom. A
    /// settings screen has no source to grow from, and pretending otherwise
    /// would be motion for its own sake.
    var zoomsFromSource: Bool {
        switch self {
        case .plant, .collection, .friendGrove, .askThread: true
        default: false
        }
    }
}

private struct GroveHeroNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// The transition namespace belonging to the enclosing navigation stack.
    ///
    /// Each stack owns its own, which is the point: five tabs can all be
    /// showing a card for the same plant, and a single app-wide namespace would
    /// leave the system with several equally valid sources for one destination.
    var groveHeroNamespace: Namespace.ID? {
        get { self[GroveHeroNamespaceKey.self] }
        set { self[GroveHeroNamespaceKey.self] = newValue }
    }
}

private struct GroveHeroSourceModifier: ViewModifier {
    @Environment(\.groveHeroNamespace) private var namespace
    let route: AppRoute

    func body(content: Content) -> some View {
        if let namespace, route.zoomsFromSource {
            content.matchedTransitionSource(id: route, in: namespace)
        } else {
            content
        }
    }
}

extension View {
    /// Marks this view as the thing `route`'s screen grows out of.
    ///
    /// Grove used to navigate entirely by stock push: tapping a plant slid a
    /// completely new screen in from the right, and the photograph the user had
    /// just been looking at was thrown away and redrawn 20 pt to the left. The
    /// card now expands into the page it opens, which is the difference between
    /// an app that shows you screens and one that shows you *things*.
    func groveHeroSource(_ route: AppRoute) -> some View {
        modifier(GroveHeroSourceModifier(route: route))
    }
}

private struct AppDestinationsModifier: ViewModifier {
    // The live camera pushes its own follow-on screens, so the destination
    // builder needs the stack it is being rendered into.
    @Binding var path: [AppRoute]
    /// Declared here rather than at the app root so each `NavigationStack` gets
    /// exactly one, matching sources to destinations within a single tab.
    @Namespace private var heroes

    func body(content: Content) -> some View {
        content
            .environment(\.groveHeroNamespace, heroes)
            .navigationDestination(for: AppRoute.self) { route in
                zoomed(destination(for: route), from: route)
            }
    }

    /// Applies the zoom only where a source exists to zoom from. A route pushed
    /// with no matching source (a deep link, a notification tap) keeps the
    /// standard push, which is the correct transition for arriving from outside.
    @ViewBuilder
    private func zoomed(_ destination: some View, from route: AppRoute) -> some View {
        if route.zoomsFromSource {
            destination.navigationTransition(.zoom(sourceID: route, in: heroes))
        } else {
            destination
        }
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
            case .plant(let id):
                PlantDetailView(plantID: id)
            case .collection(let id):
                CollectionDetailView(collectionID: id)
            case .checkIn(let id):
                CheckInView(plantID: id)
            case .careTask(let id):
                CareTaskDetailView(taskID: id)
            case .liveScan(let mode, let plantID):
                ScanView(path: $path, isActive: true, presetMode: mode, plantID: plantID)
            case .scanResult(let mode):
                ScanResultView(mode: mode)
            case .plantScanResult(let plantID, let mode):
                ScanResultView(mode: mode, plantID: plantID)
            case .addPlant:
                AddPlantView()
            case .care:
                CareQueueView()
            case .sitting:
                PlantSittingView()
            case .sittingLinkForPlant(let id):
                SittingLinkView(preselectedPlantIDs: [id])
            case .sittingLink:
                SittingLinkView()
            case .sittingFriend:
                SittingLinkView(recipient: .friend)
            case .settings:
                SettingsView()
            case .editPlant(let id):
                EditPlantView(plantID: id)
            case .plantHistory(let id):
                PlantHistoryView(plantID: id)
            case .plantStory(let id):
                PlantStoryView(plantID: id)
            case .plantDiagnosis(let id):
                PlantDiagnosisDetailView(diagnosisID: id)
            case .scanHistory:
                ScanHistoryView()
            case .friends:
                FriendsView()
            case .inviteFriend(let username):
                InviteFriendView(initialUsername: username ?? "", showsCancel: false)
            case .friendGrove(let friendID):
                FriendGroveView(friendID: friendID)
            case .friendInvitations:
                FriendInvitationsView()
            case .editProfile:
                ProfileSetupView(isOnboarding: false)
            case .groveLocation:
                GroveLocationPickerView()
            case .plan:
                GrovePlanView()
            case .activity:
                ActivityView()
            case .groveScore:
                GroveScoreView()
            case .learnTopic(let id):
                LearnTopicDetailView(topicID: id)
            case .askThread(let id):
                AskThreadView(threadID: id)
            case .askAbout(let plantID):
                AskAboutPlantView(plantID: plantID)
            case .askAboutLatestScan(let plantID, let initialDraft):
                AskAboutPlantView(
                    plantID: plantID,
                    initialDraft: initialDraft
                )
            case .journey:
                JourneyMapView()
            case .journeyMilestone(let id):
                JourneyMapView(initialMilestoneID: id)
            case .achievements:
                JourneyAchievementsView()
        }
    }
}

extension View {
    func withAppDestinations(path: Binding<[AppRoute]>) -> some View {
        modifier(AppDestinationsModifier(path: path))
    }
}

/// Previews only need destinations to resolve, not a stack of their own, so
/// this owns the path on their behalf.
struct AppDestinationsPreviewHost<Content: View>: View {
    @State private var path: [AppRoute] = []
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack(path: $path) {
            content().withAppDestinations(path: $path)
        }
    }
}
