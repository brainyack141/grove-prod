import Foundation
import Observation

/// Care logged from a notification action, waiting for a store to apply it to.
///
/// A lock-screen action can wake the app straight into the background, before
/// the shell has mounted and before `GroveStore` has been activated for an
/// account. Writing the outcome down and letting the shell apply it is the same
/// handoff a notification *tap* already uses — and it means one code path, the
/// Today row's, owns what "logged" and "snoozed" actually do.
struct PendingCareAction: Equatable {
    enum Outcome: Equatable {
        case logged
        case snoozed
    }

    let taskID: UUID
    let outcome: Outcome
}

@MainActor
@Observable
final class IntentRouter {
    static let shared = IntentRouter()

    var requestedTab: AppTab?
    /// Set by `NotificationService`, drained by the app shell. See
    /// `PendingCareAction`.
    var pendingCareAction: PendingCareAction?
    var requestedPlantID: UUID?
    var requestedCheckInPlantID: UUID?
    /// A request to raise the camera over whatever is on screen. Scan is not a
    /// tab, so it is presented rather than selected.
    var requestedScan: ScanLaunch?
    var requestedRoute: AppRoute?
    var requestedRouteTab: AppTab?
    /// A route to push onto whichever tab is already showing, without switching
    /// tabs or clearing the stack.
    ///
    /// `requestedRoute` exists for arrivals from outside the app (a shortcut, a
    /// notification), so it takes the user to a known tab and replaces the
    /// stack. Quick actions raised *inside* the app need the opposite: a
    /// context menu on a plant card should push the same screen the card
    /// pushes, in place. `NavigationLink` cannot live inside a context menu, so
    /// this is how those menus navigate.
    var pushedRoute: AppRoute?

    private init() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }

        if let flag = arguments.firstIndex(of: "-GroveLaunchTab"),
           arguments.indices.contains(flag + 1) {
            requestedTab = AppTab(rawValue: arguments[flag + 1])
        }

        if let route = value(after: "-GroveLaunchRoute") {
            let demoPlantID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            switch route {
            case "plant":
                requestedRouteTab = .profile
                requestedRoute = .plant(demoPlantID)
            case "checkin":
                requestedRouteTab = .today
                requestedRoute = .checkIn(demoPlantID)
            case "editplant":
                requestedRouteTab = .profile
                requestedRoute = .editPlant(demoPlantID)
            case "scan-identify":
                requestedScan = ScanLaunch(mode: .identify)
            case "scan-add":
                requestedScan = ScanLaunch(mode: .add)
            case "scan-diagnose":
                requestedScan = ScanLaunch(mode: .diagnose)
            case "addplant":
                requestedRouteTab = .today
                requestedRoute = .addPlant
            case "sitting":
                requestedRouteTab = .friends
                requestedRoute = .sitting
            case "friends":
                requestedTab = .friends
            case "invitations":
                requestedRouteTab = .friends
                requestedRoute = .friendInvitations
            case "history":
                requestedRouteTab = .profile
                requestedRoute = .scanHistory
            case "settings":
                requestedRouteTab = .profile
                requestedRoute = .settings
            case "editprofile":
                requestedRouteTab = .profile
                requestedRoute = .editProfile
            default:
                break
            }
        }
#endif
    }

    func openPlant(_ plantID: UUID) {
        requestedTab = .today
        requestedPlantID = plantID
    }

    func startCheckIn(_ plantID: UUID) {
        requestedTab = .today
        requestedCheckInPlantID = plantID
    }

    /// Pushes a route onto the current tab's stack. See `pushedRoute`.
    func push(_ route: AppRoute) {
        pushedRoute = route
    }

    func startScan(_ mode: ScanMode? = nil, plantID: UUID? = nil) {
        requestedScan = ScanLaunch(mode: mode, plantID: plantID)
    }

    /// Routes the one public Grove invitation arrival currently supported.
    ///
    /// The HTTPS form is what one gardener shares. Its web fallback opens the
    /// custom-scheme form because the development provisioning profile cannot
    /// carry Associated Domains. Both forms land on the same route, and a cold
    /// link can wait through sign-in until the signed-in shell consumes it.
    @discardableResult
    func handleIncomingURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased() ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let isWebInvite = scheme == "https"
            && ["downloadgrove.com", "www.downloadgrove.com"].contains(host)
            && path == "friends"
        let isAppInvite = scheme == "nz.co.thinkingai.grove"
            && ((host == "friends" && path.isEmpty) || (host.isEmpty && path == "friends"))
        guard isWebInvite || isAppInvite else { return false }

        let rawUsername = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "username" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
        let username = rawUsername.flatMap { value in
            value.range(of: "^[a-z0-9_]{3,24}$", options: .regularExpression) == nil ? nil : value
        }
        requestedRouteTab = .friends
        requestedRoute = .inviteFriend(username)
        return true
    }
}
