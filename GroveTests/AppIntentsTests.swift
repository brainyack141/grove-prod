import XCTest
@testable import Grove

@MainActor
final class AppIntentsTests: XCTestCase {
    /// The entity query reads `GroveStore.forCurrentSession()` from standard defaults,
    /// so the test pins its own throwaway demo session (and restores whatever session
    /// and legacy snapshot the host app had) instead of assuming the host's state.
    func testPlantQueryResolvesPersistedPlantIdentifiers() async throws {
        let storage = UserDefaults.standard
        let sessionKey = "grove.user.session.v1"
        let legacySnapshotKey = "grove.local.snapshot.v1"
        let accountID = "app-intents-test-\(UUID().uuidString)"
        let previousSession = storage.data(forKey: sessionKey)
        let previousLegacySnapshot = storage.data(forKey: legacySnapshotKey)
        addTeardownBlock {
            storage.removeObject(forKey: AccountStorage.snapshotKey(for: accountID))
            if let previousSession {
                storage.set(previousSession, forKey: sessionKey)
            } else {
                storage.removeObject(forKey: sessionKey)
            }
            if let previousLegacySnapshot {
                storage.set(previousLegacySnapshot, forKey: legacySnapshotKey)
            } else {
                storage.removeObject(forKey: legacySnapshotKey)
            }
        }
        storage.removeObject(forKey: legacySnapshotKey)
        let session = UserSession(accountID: accountID, mode: .demo, displayName: "Alex")
        storage.set(try JSONEncoder().encode(session), forKey: sessionKey)

        let store = GroveStore.forCurrentSession()
        let plant = try XCTUnwrap(store.plants.first)

        let entities = try await GrovePlantQuery().entities(for: [plant.id])

        XCTAssertEqual(entities.map(\.id), [plant.id])
        XCTAssertEqual(entities.first?.nickname, plant.nickname)
    }

    func testIntentRouterCreatesFocusedCheckInAndScanHandoffs() {
        let router = IntentRouter.shared
        let plantID = UUID()

        router.startCheckIn(plantID)
        XCTAssertEqual(router.requestedTab, .today)
        XCTAssertEqual(router.requestedCheckInPlantID, plantID)

        // Scan is presented, not selected: starting one must raise the cover
        // without disturbing whichever tab the user is standing on.
        router.requestedTab = nil
        router.startScan(.diagnose)
        XCTAssertNil(router.requestedTab)
        XCTAssertEqual(router.requestedScan?.mode, .diagnose)

        router.requestedCheckInPlantID = nil
        router.requestedScan = nil
    }

    func testTrustedPersonUniversalLinkOpensPrefilledInviteOnFriendsTab() throws {
        let router = IntentRouter.shared
        let handled = router.handleIncomingURL(
            try XCTUnwrap(URL(string: "https://www.downloadgrove.com/friends?username=%40Maya_Grows"))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(router.requestedRouteTab, .friends)
        XCTAssertEqual(router.requestedRoute, .inviteFriend("maya_grows"))
        router.requestedRoute = nil
        router.requestedRouteTab = nil
    }

    func testTrustedPersonWebFallbackOpensTheSamePrefilledInvite() throws {
        let router = IntentRouter.shared
        let handled = router.handleIncomingURL(
            try XCTUnwrap(URL(string: "nz.co.thinkingai.grove://friends?username=maya_grows"))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(router.requestedRouteTab, .friends)
        XCTAssertEqual(router.requestedRoute, .inviteFriend("maya_grows"))
        router.requestedRoute = nil
        router.requestedRouteTab = nil
    }

    func testForeignURLIsLeftForItsOwnHandler() throws {
        let router = IntentRouter.shared
        router.requestedRoute = nil
        router.requestedRouteTab = nil

        let handled = router.handleIncomingURL(
            try XCTUnwrap(URL(string: "com.googleusercontent.apps.example:/oauth"))
        )

        XCTAssertFalse(handled)
        XCTAssertNil(router.requestedRoute)
        XCTAssertNil(router.requestedRouteTab)
    }

    func testMalformedInviteStillOpensWithoutPrefillingUntrustedText() throws {
        let router = IntentRouter.shared
        let handled = router.handleIncomingURL(
            try XCTUnwrap(URL(string: "https://downloadgrove.com/friends?username=not%20a%20handle"))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(router.requestedRoute, .inviteFriend(nil))
        router.requestedRoute = nil
        router.requestedRouteTab = nil
    }
}
