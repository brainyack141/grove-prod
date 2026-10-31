import Foundation
import RevenueCat
import Testing

@testable import Grove

/// Covers the paywall's honesty rules, which had no tests before RevenueCat
/// landed and which are the rules most likely to break quietly: a savings badge
/// that stops being true, trial copy shown to an account that cannot redeem
/// one, and the metering rules that decide whether an offline user walks past
/// the only wall in the app.
@MainActor
struct PremiumStoreTests {

    // MARK: - Fixtures

    private static func product(
        id: String,
        price: Decimal,
        display: String,
        period: SubscriptionPeriod,
        trial: TestStoreProductDiscount? = nil
    ) -> StoreProduct {
        TestStoreProduct(
            localizedTitle: "Grove Premium",
            price: price,
            currencyCode: "USD",
            localizedPriceString: display,
            productIdentifier: id,
            productType: .autoRenewableSubscription,
            localizedDescription: "Grove Premium",
            subscriptionGroupIdentifier: "grove.premium",
            subscriptionPeriod: period,
            isFamilyShareable: false,
            introductoryDiscount: trial,
            discounts: [],
            locale: Locale(identifier: "en_US")
        ).toStoreProduct()
    }

    private static func package(_ plan: GrovePremiumStore.Plan, _ product: StoreProduct) -> Package {
        Package(
            identifier: plan.rawValue,
            packageType: plan.packageType,
            storeProduct: product,
            presentedOfferingContext: PresentedOfferingContext(offeringIdentifier: "default"),
            webCheckoutUrl: nil
        )
    }

    private static func freeTrial(days: Int) -> TestStoreProductDiscount {
        TestStoreProductDiscount(
            identifier: "trial",
            price: 0,
            localizedPriceString: "$0.00",
            paymentMode: .freeTrial,
            subscriptionPeriod: SubscriptionPeriod(value: days, unit: .day),
            numberOfPeriods: 1,
            type: .introductory
        )
    }

    /// The catalogue Grove intends to launch with: $34.99 a year against
    /// $6.99 a month, with a three-day trial on the annual plan only.
    private static func launchCatalogue(trialDays: Int? = 3) -> [GrovePremiumStore.Plan: Package] {
        [
            .yearly: package(.yearly, product(
                id: GrovePremiumStore.Plan.yearly.defaultProductID,
                price: 34.99,
                display: "$34.99",
                period: SubscriptionPeriod(value: 1, unit: .year),
                trial: trialDays.map { freeTrial(days: $0) }
            )),
            .monthly: package(.monthly, product(
                id: GrovePremiumStore.Plan.monthly.defaultProductID,
                price: 6.99,
                display: "$6.99",
                period: SubscriptionPeriod(value: 1, unit: .month)
            ))
        ]
    }

    // MARK: - Savings badge

    @Test("The savings badge states the real discount between the two live prices")
    func savingsBadgeIsComputedFromLivePrices() {
        let store = GrovePremiumStore()
        store.seedCatalogueForTesting(packages: Self.launchCatalogue())
        // $6.99 x 12 = $83.88 against $34.99 is a 58.28% saving, floored.
        #expect(store.yearlySavingsLabel == "Save 58%")
    }

    @Test("No badge is shown when the annual plan is not actually cheaper")
    func savingsBadgeIsAbsentWhenAnnualIsNotCheaper() {
        let store = GrovePremiumStore()
        store.seedCatalogueForTesting(packages: [
            .yearly: Self.package(.yearly, Self.product(
                id: "yearly", price: 99.99, display: "$99.99",
                period: SubscriptionPeriod(value: 1, unit: .year)
            )),
            .monthly: Self.package(.monthly, Self.product(
                id: "monthly", price: 6.99, display: "$6.99",
                period: SubscriptionPeriod(value: 1, unit: .month)
            ))
        ])
        #expect(store.yearlySavingsLabel == nil)
    }

    @Test("A half-loaded catalogue makes no claim about savings")
    func savingsBadgeNeedsBothPrices() {
        let store = GrovePremiumStore()
        store.seedCatalogueForTesting(packages: [.yearly: Self.launchCatalogue()[.yearly]!])
        #expect(store.yearlySavingsLabel == nil)
    }

    // MARK: - Trial copy

    @Test("Trial copy only appears for a plan this account can actually redeem")
    func trialCopyFollowsEligibility() {
        let store = GrovePremiumStore()
        let catalogue = Self.launchCatalogue()
        // The monthly product defines no trial and the yearly one is seeded as
        // eligible — exactly the shape the launch catalogue has.
        store.seedCatalogueForTesting(
            packages: catalogue,
            eligibleFreeTrials: [.yearly: catalogue[.yearly]!.storeProduct.introductoryDiscount!]
        )
        #expect(store.freeTrialLabel(for: .yearly) == "3-day free trial")
        #expect(store.freeTrialDays(for: .yearly) == 3)
        #expect(store.freeTrialLabel(for: .monthly) == nil)
        #expect(store.freeTrialDays(for: .monthly) == nil)
    }

    @Test("A product with a trial it cannot redeem shows no trial copy")
    func ineligibleAccountIsNeverPromisedATrial() {
        let store = GrovePremiumStore()
        // The product still carries the introductory offer; eligibility is
        // empty, which is what `checkTrialOrIntroDiscountEligibility` returns
        // for an account that has already used one in this group.
        store.seedCatalogueForTesting(packages: Self.launchCatalogue(), eligibleFreeTrials: [:])
        #expect(store.freeTrialLabel(for: .yearly) == nil)
        #expect(store.freeTrialDays(for: .yearly) == nil)
    }

    @Test("A trial expressed in weeks is reported in days for the timeline")
    func weekLongTrialIsConvertedToDays() {
        let store = GrovePremiumStore()
        let weekly = TestStoreProductDiscount(
            identifier: "trial",
            price: 0,
            localizedPriceString: "$0.00",
            paymentMode: .freeTrial,
            subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .week),
            numberOfPeriods: 1,
            type: .introductory
        ).toStoreProductDiscount()
        store.seedCatalogueForTesting(
            packages: Self.launchCatalogue(),
            eligibleFreeTrials: [.yearly: weekly]
        )
        #expect(store.freeTrialDays(for: .yearly) == 7)
    }

    // MARK: - Price copy

    @Test("The yearly card can state what the year works out to per month")
    func monthlyEquivalentIsDerivedFromTheBillingPeriod() {
        let store = GrovePremiumStore()
        store.seedCatalogueForTesting(packages: Self.launchCatalogue())
        // $34.99 over its real billing period, not "price / 12" assumed by the
        // call site. The onboarding paywall hard-codes "$4.17" as its
        // placeholder; at the launch price the live answer is $2.92.
        #expect(store.monthlyEquivalentPrice(for: .yearly) == "$2.92")
        #expect(store.displayPrice(for: .yearly) == "$34.99")
        #expect(store.priceLine(for: .monthly) == "$6.99 per month")
    }

    // MARK: - Metering

    @Test("A catalogue that has not answered yet is metered, so offline is never a bypass")
    func unresolvedCatalogueStaysMetered() {
        let store = GrovePremiumStore()
        #expect(store.isUnmetered == false)
        // ...and the meter UI does not draw while the answer is unknown.
        #expect(store.showsMeter == false)
    }

    @Test("A resolved but empty catalogue means nothing is metered")
    func emptyCatalogueLiftsTheMeter() {
        let store = GrovePremiumStore()
        store.seedCatalogueForTesting(packages: [:])
        #expect(store.isUnmetered)
        #expect(store.showsMeter == false)
    }

    @Test("A loaded catalogue meters the free tier and draws the meter")
    func loadedCatalogueMeters() {
        let store = GrovePremiumStore()
        store.seedCatalogueForTesting(packages: Self.launchCatalogue())
        #expect(store.isUnmetered == false)
        #expect(store.showsMeter)
    }

    @Test("The unsold grant refuses while there is something to sell")
    func unsoldGrantRefusesWithALoadedCatalogue() {
        let store = GrovePremiumStore()
        store.seedCatalogueForTesting(packages: Self.launchCatalogue())
        store.grantUnsoldPremium()
        #expect(store.hasPremium == false)
        #expect(store.isUnmetered == false)
    }

    @Test("The unsold grant only fires when there is genuinely nothing to sell")
    func unsoldGrantRefusesWhenAnswerIsUnknown() {
        let store = GrovePremiumStore()
        // Catalogue never resolved: an offline user, not an empty product line.
        store.seedCatalogueForTesting(packages: [:], didLoadCatalogue: false)
        store.grantUnsoldPremium()
        #expect(store.hasPremium == false)
        #expect(store.isUnmetered == false)
    }

    @Test("The unsold grant lifts the limit when the catalogue resolved to nothing")
    func unsoldGrantAppliesToAnEmptyCatalogue() {
        let store = GrovePremiumStore()
        store.seedCatalogueForTesting(packages: [:])
        store.grantUnsoldPremium()
        #expect(store.hasPremium)
        #expect(store.isUnmetered)
    }

    // MARK: - Key handling

    @Test("A secret RevenueCat key is refused rather than shipped")
    func secretKeyIsRejected() {
        #expect(GrovePremiumStore.sanitizedAPIKey("sk_live_abc123") == nil)
    }

    @Test("An unexpanded build setting is not mistaken for a key")
    func unexpandedBuildSettingIsRejected() {
        #expect(GrovePremiumStore.sanitizedAPIKey("$(REVENUECAT_API_KEY)") == nil)
        #expect(GrovePremiumStore.sanitizedAPIKey("   ") == nil)
        #expect(GrovePremiumStore.sanitizedAPIKey(nil) == nil)
    }

    @Test("The public Apple key is accepted and trimmed")
    func publicKeyIsAccepted() {
        #expect(GrovePremiumStore.sanitizedAPIKey(" appl_abc123 ") == "appl_abc123")
    }
}
