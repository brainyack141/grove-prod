import XCTest
@testable import Grove

/// The trial flow's routes are pure, so these tests pin the two things that
/// would be expensive to get wrong in a rendered screen: a customer without a
/// trial never sees a reminder step, and the decline screen can never lead back
/// into a purchase.
@MainActor
final class GroveTrialFlowTests: XCTestCase {
    func testTrialRouteIncludesReminder() {
        XCTAssertEqual(
            GroveTrialFlowRoute.steps(hasTrial: true),
            [.tryFree, .reminder, .timeline]
        )
    }

    func testNoTrialRouteSkipsReminder() {
        XCTAssertEqual(
            GroveTrialFlowRoute.steps(hasTrial: false),
            [.tryFree, .timeline]
        )
    }

    func testAdvanceFollowsTheTrialRoute() {
        XCTAssertEqual(GroveTrialFlowRoute.advance(from: .tryFree, hasTrial: true), .reminder)
        XCTAssertEqual(GroveTrialFlowRoute.advance(from: .reminder, hasTrial: true), .timeline)
        XCTAssertNil(GroveTrialFlowRoute.advance(from: .timeline, hasTrial: true))
    }

    func testAdvanceSkipsReminderWithoutATrial() {
        XCTAssertEqual(GroveTrialFlowRoute.advance(from: .tryFree, hasTrial: false), .timeline)
        XCTAssertNil(GroveTrialFlowRoute.advance(from: .timeline, hasTrial: false))
    }

    func testBackTracksThroughTheRoute() {
        XCTAssertEqual(GroveTrialFlowRoute.back(from: .reminder, hasTrial: true), .tryFree)
        XCTAssertEqual(GroveTrialFlowRoute.back(from: .timeline, hasTrial: true), .reminder)
        XCTAssertEqual(GroveTrialFlowRoute.back(from: .timeline, hasTrial: false), .tryFree)
        XCTAssertNil(GroveTrialFlowRoute.back(from: .tryFree, hasTrial: true))
    }

    func testExitGoesToBeforeYouGoOnceThenFinishes() {
        XCTAssertEqual(
            GroveTrialFlowRoute.exit(from: .tryFree, hasVisitedBeforeYouGo: false),
            .beforeYouGo
        )
        XCTAssertEqual(
            GroveTrialFlowRoute.exit(from: .tryFree, hasVisitedBeforeYouGo: true),
            .finish
        )
        XCTAssertEqual(
            GroveTrialFlowRoute.exit(from: .reminder, hasVisitedBeforeYouGo: true),
            .finish
        )
        XCTAssertEqual(
            GroveTrialFlowRoute.exit(from: .timeline, hasVisitedBeforeYouGo: false),
            .beforeYouGo
        )
    }

    func testBeforeYouGoNeverRoutesToAPurchaseStep() {
        XCTAssertNil(GroveTrialFlowRoute.advance(from: .beforeYouGo, hasTrial: true))
        XCTAssertNil(GroveTrialFlowRoute.back(from: .beforeYouGo, hasTrial: true))
        XCTAssertEqual(
            GroveTrialFlowRoute.exit(from: .beforeYouGo, hasVisitedBeforeYouGo: false),
            .finish
        )
        XCTAssertEqual(
            GroveTrialFlowRoute.exit(from: .beforeYouGo, hasVisitedBeforeYouGo: true),
            .finish
        )
        XCTAssertFalse(GroveTrialFlowRoute.steps(hasTrial: true).contains(.beforeYouGo))
    }

    func testDeclineReasonsUseStableWireKeys() {
        XCTAssertEqual(GroveTrialDeclineReason.price.analyticsKey, "price")
        XCTAssertEqual(GroveTrialDeclineReason.unsureAri.analyticsKey, "unsure_ari")
        XCTAssertEqual(GroveTrialDeclineReason.browsing.analyticsKey, "browsing")
        XCTAssertEqual(GroveTrialDeclineReason.other.analyticsKey, "other")
    }
}
