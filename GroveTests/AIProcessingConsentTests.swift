import XCTest
@testable import Grove

/// The gate that stands in front of every photo sent to Google's Gemini: what
/// counts as agreement, what does not, and where it is stored.
final class AIProcessingConsentTests: XCTestCase {
    private var suiteName: String!
    private var storage: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AIProcessingConsent-\(UUID().uuidString)"
        storage = UserDefaults(suiteName: suiteName)!
        storage.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        storage.removePersistentDomain(forName: suiteName)
        storage = nil
        suiteName = nil
        super.tearDown()
    }

    func testConsentIsNotGrantedByDefault() {
        XCTAssertFalse(AIProcessingConsent.isGranted(in: storage))
    }

    func testGrantMarksTheCurrentVersionAsGranted() {
        AIProcessingConsent.grant(in: storage)
        XCTAssertTrue(AIProcessingConsent.isGranted(in: storage))
    }

    /// An install stamped by the old disclosure must see the new one once.
    func testVersionOneIsNotGranted() {
        storage.set(1, forKey: GroveDefaults.photoProcessingDisclosureVersion)
        XCTAssertFalse(AIProcessingConsent.isGranted(in: storage))
    }

    func testConsentUsesTheCataloguedDefaultsKey() {
        XCTAssertEqual(
            GroveDefaults.photoProcessingDisclosureVersion,
            "grove.photoProcessingDisclosureVersion"
        )

        AIProcessingConsent.grant(in: storage)

        XCTAssertEqual(
            storage.integer(forKey: GroveDefaults.photoProcessingDisclosureVersion),
            AIProcessingConsent.currentVersion
        )
    }
}
