import Foundation
import Observation
import RevenueCat

/// Grove Premium subscriptions, served by RevenueCat over StoreKit 2.
///
/// The paywall works in three honest states:
/// 1. Offerings loaded → localized prices and real purchases.
/// 2. Nothing to sell (RevenueCat unconfigured pre-launch, or an offering that
///    came back empty) → the paywall shows its fallback copy and the primary
///    button simply continues, so the flow never dead-ends and never takes
///    money it cannot take.
/// 3. An entitlement already exists (restore / Family Sharing / an offer code
///    redeemed in the App Store) → premium.
///
/// RevenueCat is here for three things StoreKit alone did not give this app:
///
/// * **A transaction stream that is actually observed.** `customerInfoStream`
///   runs for the life of the process, so an Ask to Buy approval, a refund, a
///   renewal, an offer code redeemed outside the app and a Family Sharing grant
///   all land without a relaunch. The hand-rolled store checked entitlements
///   exactly once per launch and never observed `Transaction.updates`, which
///   meant a `.pending` purchase could never complete and a refund never
///   revoked.
/// * **Server-side entitlement**, so the botanist gateway can meter a paying
///   account differently instead of trusting a client boolean.
/// * **Dashboard-served offerings**, so a price test does not need a binary.
///
/// Plans are read off `PackageType`, never off a hard-coded product id, which
/// is what lets the dashboard swap the underlying product mid-test.
@MainActor
@Observable
final class GrovePremiumStore {
    /// The RevenueCat entitlement every paid plan grants. Must match the
    /// entitlement identifier in the RevenueCat dashboard exactly.
    static let entitlementID = "premium"

    enum Plan: String, CaseIterable {
        case yearly
        case monthly

        var packageType: PackageType {
            switch self {
            case .yearly: .annual
            case .monthly: .monthly
            }
        }

        /// The App Store product this plan ships as by default. RevenueCat
        /// serves the real one, so this is only the local StoreKit rehearsal
        /// catalogue (Grove.storekit) and diagnostics — never purchase input.
        var defaultProductID: String {
            switch self {
            case .yearly: "nz.co.thinkingai.Grove.premium.yearly"
            case .monthly: "nz.co.thinkingai.Grove.premium.monthly"
            }
        }
    }

    enum PurchaseOutcome {
        /// Entitlement active (purchase completed, or deferred approval granted).
        case unlocked
        /// The user cancelled; stay on the paywall.
        case cancelled
        /// Waiting on Ask to Buy or similar; let the user continue. The
        /// entitlement will arrive over `customerInfoStream` when it clears,
        /// with no relaunch needed.
        case pending
        /// Nothing to sell; continue without purchase.
        case unavailable
        case failed(message: String)
    }

    private(set) var packages: [Plan: Package] = [:]
    /// Introductory free trials that the current Apple account can actually
    /// redeem. A product merely having an offer is not enough: someone who has
    /// already used an introductory offer in the subscription group must never
    /// be shown "free trial" copy the App Store will not honour.
    private(set) var eligibleFreeTrials: [Plan: StoreProductDiscount] = [:]
    private(set) var hasPremium = false
    private(set) var isLoading = false

    /// When the current free trial converts to a paid subscription, or nil when
    /// the entitlement is not in its trial period.
    ///
    /// The paywall's timeline promises a reminder before this date in writing,
    /// which makes the date itself product surface rather than an internal
    /// detail: `NotificationService` schedules against it. Nil for a paying
    /// subscriber, a lapsed one, and anyone who never started a trial.
    private(set) var trialEndsAt: Date?

    /// Whether an offerings query has resolved in this session. False means
    /// *unknown*, never *empty* — see `isUnmetered`.
    private(set) var didLoadCatalogue = false

    /// Set when the catalogue resolved to nothing while RevenueCat was
    /// configured. That combination is always a misconfiguration — a missing
    /// offering, an entitlement that was never attached, products still in
    /// "Waiting for Review" — and it silently gives the app away, so it is
    /// surfaced rather than absorbed. See `grantUnsoldPremium()`.
    private(set) var didReportEmptyCatalogue = false

    /// Lives as long as the store does. Cancelling it would restore exactly the
    /// bug this class exists to fix, so nothing cancels it.
    @ObservationIgnored private var entitlementObserver: Task<Void, Never>?
    /// RevenueCat must use the same opaque account UUID as the Botanist gateway.
    /// Without this login the SDK invents a device-local anonymous id, leaving
    /// the server unable to verify which Grove account owns an entitlement.
    @ObservationIgnored private var requestedAppUserID: String?

    // MARK: - Bootstrap

    /// Configures RevenueCat once per process, before any other call touches
    /// `Purchases.shared` (which traps if it is not configured).
    ///
    /// A missing key is the pre-launch state, not an error: Debug builds
    /// without an environment loaded should still run, and `isUnmetered` reads
    /// "nothing configured" as "nothing to meter". Release builds cannot reach
    /// here without a key — project.yml fails the build first, precisely so a
    /// keyless Release can never ship the whole app for free.
    static func bootstrap(bundle: Bundle = .main) {
        guard !Purchases.isConfigured else { return }
        guard let key = configuredAPIKey(in: bundle) else {
            GroveDiag.log("premium: no RevenueCat key, running unmetered")
            return
        }
#if DEBUG
        Purchases.logLevel = .info
#else
        Purchases.logLevel = .warn
#endif
        Purchases.configure(withAPIKey: key)
    }

    /// The public `appl_…` SDK key from Info.plist.
    static func configuredAPIKey(in bundle: Bundle = .main) -> String? {
        sanitizedAPIKey(bundle.object(forInfoDictionaryKey: "RevenueCatAPIKey") as? String)
    }

    /// Accepts only a public Apple SDK key.
    ///
    /// A secret key is refused outright rather than passed to `configure`: it
    /// can issue refunds and read every customer record, and one pasted into
    /// the wrong variable has to fail here as well as at build time. An
    /// unexpanded `$(REVENUECAT_API_KEY)` is refused for the same reason it
    /// exists — a Debug build with no environment loaded should run unmetered,
    /// not hand RevenueCat a literal build setting.
    static func sanitizedAPIKey(_ raw: String?) -> String? {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        guard value.hasPrefix("appl_") else {
            GroveDiag.log("premium: RevenueCatAPIKey is not a public appl_ key, ignoring")
            return nil
        }
        return value
    }

    // MARK: - Catalogue

    /// Localized display price for a plan, nil until offerings load.
    func displayPrice(for plan: Plan) -> String? {
        packages[plan]?.storeProduct.localizedPriceString
    }

    /// Localised billing copy assembled from the live product.
    func priceLine(for plan: Plan) -> String? {
        guard let product = packages[plan]?.storeProduct else { return nil }
        return "\(product.localizedPriceString) per \(billingPeriod(for: product))"
    }

    /// The free-trial label for this Apple account, always in whole days — a
    /// one-week introductory offer reads "7-day free trial", never "1-week free
    /// trial". Nil means the CTA and plan row must talk about a paid
    /// subscription, even if the product defines an introductory offer.
    func freeTrialLabel(for plan: Plan) -> String? {
        guard let days = freeTrialDays(for: plan) else { return nil }
        return "\(days)-day free trial"
    }

    /// A badge is only shown when the live prices prove the annual product is
    /// cheaper than twelve monthly renewals. "Best value" should be a fact,
    /// not hard-coded marketing copy.
    var yearlySavingsLabel: String? {
        guard let yearly = packages[.yearly]?.storeProduct,
              let monthly = packages[.monthly]?.storeProduct else { return nil }
        let monthlyYear = NSDecimalNumber(decimal: monthly.price).doubleValue * 12
        let yearlyPrice = NSDecimalNumber(decimal: yearly.price).doubleValue
        guard monthlyYear > 0, yearlyPrice < monthlyYear else { return nil }
        let percentage = Int(((monthlyYear - yearlyPrice) / monthlyYear * 100).rounded(.down))
        return percentage > 0 ? "Save \(percentage)%" : nil
    }

    /// What the plan works out to per month, in the product's own currency and
    /// over its real billing period — so a yearly card can say what the year
    /// costs a month without the call site assuming the period is twelve.
    ///
    /// Rounded up to the cent. RevenueCat's `localizedPricePerMonth` rounds down,
    /// which turns $34.99 a year into "$2.91 a month" when a month of it actually
    /// costs $2.9158. A cent is nothing to a user and everything to a price
    /// claim: rounding down means the paywall advertises a monthly figure that
    /// twelve payments of would not buy the year. Round up and the number is one
    /// Grove can always stand behind.
    func monthlyEquivalentPrice(for plan: Plan) -> String? {
        guard let product = packages[plan]?.storeProduct,
              let months = billingMonths(for: product), months > 0 else { return nil }
        let perMonth = NSDecimalNumber(decimal: product.price)
            .dividing(
                by: NSDecimalNumber(value: months),
                withBehavior: NSDecimalNumberHandler(
                    roundingMode: .up,
                    scale: 2,
                    raiseOnExactness: false,
                    raiseOnOverflow: false,
                    raiseOnUnderflow: false,
                    raiseOnDivideByZero: false
                )
            )
        // The product's own formatter carries its storefront currency and
        // locale, so a euro price never renders with a dollar sign.
        let formatter = product.priceFormatter ?? {
            let fallback = NumberFormatter()
            fallback.numberStyle = .currency
            fallback.currencyCode = product.currencyCode
            return fallback
        }()
        return formatter.string(from: perMonth)
    }

    /// About what the plan costs a week, for example a $34.99 yearly plan ->
    /// $0.68 a week, so call sites can label it "about". Only yearly plans need
    /// it; a monthly product returns nil.
    ///
    /// Rounded up to the cent for the same reason as `monthlyEquivalentPrice`:
    /// a weekly figure the paywall states must be one Grove can stand behind.
    func weeklyEquivalentPrice(for plan: Plan) -> String? {
        guard let product = packages[plan]?.storeProduct,
              let weeks = billingWeeks(for: product), weeks > 0 else { return nil }
        let perWeek = NSDecimalNumber(decimal: product.price)
            .dividing(
                by: NSDecimalNumber(value: weeks),
                withBehavior: NSDecimalNumberHandler(
                    roundingMode: .up,
                    scale: 2,
                    raiseOnExactness: false,
                    raiseOnOverflow: false,
                    raiseOnUnderflow: false,
                    raiseOnDivideByZero: false
                )
            )
        let formatter = product.priceFormatter ?? {
            let fallback = NumberFormatter()
            fallback.numberStyle = .currency
            fallback.currencyCode = product.currencyCode
            return fallback
        }()
        return formatter.string(from: perWeek)
    }

    /// How many months one billing period covers, or nil for a product billed in
    /// something months cannot express.
    private func billingMonths(for product: StoreProduct) -> Int? {
        guard let period = product.subscriptionPeriod else { return nil }
        switch period.unit {
        case .month: return period.value
        case .year: return period.value * 12
        case .day, .week: return nil
        @unknown default: return nil
        }
    }

    /// How many weeks one billing period covers, or nil for a product billed in
    /// something weeks cannot express. Only yearly plans need a weekly figure.
    private func billingWeeks(for product: StoreProduct) -> Int? {
        guard let period = product.subscriptionPeriod else { return nil }
        switch period.unit {
        case .year: return period.value * 52
        case .day, .week, .month: return nil
        @unknown default: return nil
        }
    }

    /// The eligible free trial's length in whole days; nil when this Apple
    /// account has no trial to redeem. Drives the paywall's trial timeline.
    func freeTrialDays(for plan: Plan) -> Int? {
        guard let offer = eligibleFreeTrials[plan] else { return nil }
        let units = offer.subscriptionPeriod.value * max(offer.numberOfPeriods, 1)
        switch offer.subscriptionPeriod.unit {
        case .day: return units
        case .week: return units * 7
        case .month: return units * 30
        case .year: return units * 365
        @unknown default: return nil
        }
    }

    /// When an eligible free trial converts to a paid charge, counted from
    /// `start`. Nil when this Apple account has no trial to redeem.
    func trialChargeDate(
        for plan: Plan,
        from start: Date = .now,
        calendar: Calendar = .current
    ) -> Date? {
        guard let days = freeTrialDays(for: plan) else { return nil }
        return calendar.date(byAdding: .day, value: days, to: start)
    }

    /// The instant the paywall promises a reminder before the first charge,
    /// using exactly the function that schedules the real notification, so the
    /// dated terms and the notification can never disagree.
    func trialReminderDate(
        for plan: Plan,
        from start: Date = .now,
        hour: Int = NotificationService.reminderHour
    ) -> Date? {
        guard let chargeDate = trialChargeDate(for: plan, from: start) else { return nil }
        return NotificationService.trialNoticeDate(for: chargeDate, now: start, hour: hour)
    }

    /// Whether premium limits should apply to this account at all.
    ///
    /// False while there is no catalogue to sell from, because onboarding tells
    /// those users "everything below is yours while Grove is in early access".
    /// Metering a feature against a subscription nobody can buy would make that
    /// promise a lie and put a wall in front of a user with no way through it.
    /// The day offerings exist, every meter turns on by itself.
    ///
    /// In Debug, `-GroveForceAskMeter` forces limits on so the metered path and
    /// its wall can be exercised before the catalogue lands.
    var isUnmetered: Bool {
        if hasPremium { return true }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-GroveForceAskMeter") { return false }
#endif
        // Both halves matter. An empty catalogue only means "nothing to sell"
        // once the query has actually resolved — `packages` is equally empty
        // when the request threw (offline) and in the window before the first
        // `load()` completes. Reading either of those as "unmetered" made
        // airplane mode a paywall bypass, and made every cold launch one for as
        // long as the query took.
        return didLoadCatalogue && packages.isEmpty
    }

    /// Whether meter UI — the free-question quota line, the composer's running
    /// count — should draw at all. Not `!isUnmetered`: both are false while
    /// the catalogue query is still in flight. Enforcement must read that
    /// window as metered so offline never becomes a bypass, but drawing the
    /// meter on the same rule put a "free questions" line beside the composer
    /// on every cold open of Ask for exactly as long as the store took to
    /// answer, then yanked it.
    /// Display waits for proof that limits apply; enforcement never does.
    var showsMeter: Bool {
        if hasPremium { return false }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-GroveForceAskMeter") { return true }
#endif
        return didLoadCatalogue && !packages.isEmpty
    }

    // MARK: - Loading

    /// Identifies the signed-in Grove account to RevenueCat before entitlement
    /// state is used. Calling `logIn` directly also handles switching between two
    /// identified accounts without merging them.
    func activate(accountID: String) async {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        requestedAppUserID = normalized

        guard Purchases.isConfigured else {
            // The deliberate pre-launch state: no catalogue exists to meter.
            await load()
            return
        }
        if Purchases.shared.appUserID == normalized {
            await load()
            return
        }

        // Never let account B inherit account A's in-memory entitlement while a
        // network login is pending or failed.
        hasPremium = false
        trialEndsAt = nil
        do {
            let result = try await Purchases.shared.logIn(normalized)
            // `logIn` mutates the SDK before it resumes us. If account A's slower
            // request lands after account B's, record that fact and immediately
            // restore the latest requested identity; merely ignoring A's stale
            // result would leave the SDK secretly logged into the wrong account.
            guard requestedAppUserID == normalized else {
                if let latest = requestedAppUserID {
                    await activate(accountID: latest)
                } else {
                    await deactivate()
                }
                return
            }
            apply(result.customerInfo)
            await load()
        } catch {
            guard requestedAppUserID == normalized else { return }
            GroveDiag.log("premium: account login failed (\(error.localizedDescription))")
        }
    }

    /// Leaves an identified Grove account before signed-out onboarding can
    /// restore or purchase against it. RevenueCat creates a fresh anonymous id;
    /// a later Grove sign-in aliases that receipt to the new account normally.
    func deactivate() async {
        requestedAppUserID = nil
        hasPremium = false
        trialEndsAt = nil
        guard Purchases.isConfigured, !Purchases.shared.isAnonymous else { return }

        do {
            let info = try await Purchases.shared.logOut()
            guard requestedAppUserID == nil else {
                if let latest = requestedAppUserID { await activate(accountID: latest) }
                return
            }
            apply(info)
        } catch {
            guard requestedAppUserID == nil else { return }
            GroveDiag.log("premium: account logout failed (\(error.localizedDescription))")
        }
    }

    /// Loads the catalogue once, refreshes the entitlement on every call.
    ///
    /// The split matters. Offerings change on RevenueCat's schedule and cost a
    /// network round trip; entitlement changes the moment a subscription
    /// lapses, is refunded, or an Ask to Buy clears. The previous version
    /// guarded the whole method on "already loaded", so entitlement was read
    /// exactly once per launch and an expiry mid-session never applied.
    func load() async {
        startObservingEntitlement()
        guard Purchases.isConfigured else {
            // Nothing configured is a *resolved* answer: there is nothing to
            // sell, so the meter stays off. Distinct from a request that threw.
            didLoadCatalogue = true
            return
        }
        // A failed logout stays fail-closed, but foreground and screen refreshes
        // should keep trying so signed-out onboarding is not permanently unable
        // to restore or purchase.
        if requestedAppUserID == nil, !Purchases.shared.isAnonymous {
            await deactivate()
        }
        if !didLoadCatalogue, !isLoading {
            isLoading = true
            await loadCatalogue()
            isLoading = false
        }
        await refreshEntitlement()
    }

    private func loadCatalogue() async {
        do {
            let offerings = try await Purchases.shared.offerings()
            guard let offering = offerings.current else {
                // A configured project with no current offering is a dashboard
                // mistake, not an empty product line. Resolve the query so the
                // paywall stops waiting, and raise the alarm.
                didLoadCatalogue = true
                reportEmptyCatalogue(reason: "no current offering")
                return
            }
            var catalogue: [Plan: Package] = [:]
            for plan in Plan.allCases {
                if let package = offering.availablePackages.first(where: { $0.packageType == plan.packageType }) {
                    catalogue[plan] = package
                }
            }
            packages = catalogue
            await loadTrialEligibility(for: catalogue)
            // Only a query that came back tells us anything about the
            // catalogue. Set after the await so a thrown request stays
            // "unknown" and the next `load()` retries it.
            didLoadCatalogue = true
            if catalogue.isEmpty {
                reportEmptyCatalogue(reason: "current offering has no annual or monthly package")
            }
        } catch {
            // Offline or a RevenueCat outage. The meter stays on; the paywall
            // says it could not reach the store rather than quietly giving it
            // away, and `didLoadCatalogue` stays false so this retries.
            GroveDiag.log("premium: offerings unavailable (\(error.localizedDescription))")
        }
    }

    /// Narrows the products that merely *define* a trial down to the ones this
    /// Apple account can still redeem.
    private func loadTrialEligibility(for catalogue: [Plan: Package]) async {
        let withOffers = catalogue.filter { $0.value.storeProduct.introductoryDiscount?.paymentMode == .freeTrial }
        guard !withOffers.isEmpty else {
            eligibleFreeTrials = [:]
            return
        }
        let identifiers = withOffers.values.map(\.storeProduct.productIdentifier)
        let eligibility = await Purchases.shared.checkTrialOrIntroDiscountEligibility(productIdentifiers: identifiers)
        var trials: [Plan: StoreProductDiscount] = [:]
        for (plan, package) in withOffers {
            let identifier = package.storeProduct.productIdentifier
            // `.unknown` is treated as ineligible on purpose. Promising a free
            // trial the App Store then declines is worse than under-promising
            // a real one, and this is the only screen where that copy appears.
            guard eligibility[identifier]?.status == .eligible,
                  let offer = package.storeProduct.introductoryDiscount else { continue }
            trials[plan] = offer
        }
        eligibleFreeTrials = trials
    }

    /// The fix for the bug this class was rewritten around: a live subscription
    /// to entitlement changes, for the life of the process.
    ///
    /// Everything that used to require a relaunch now arrives here — a parent
    /// approving an Ask to Buy purchase, a refund, a renewal, an offer code
    /// redeemed in the App Store, a Family Sharing grant, a lapse.
    private func startObservingEntitlement() {
        guard entitlementObserver == nil, Purchases.isConfigured else { return }
        entitlementObserver = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                guard let self else { return }
                // An update produced while logIn/logOut is switching identities
                // must never restore the previous account's premium bit.
                guard self.revenueCatIdentityIsCurrent else { continue }
                self.apply(info)
            }
        }
    }

    private func refreshEntitlement() async {
        guard Purchases.isConfigured, revenueCatIdentityIsCurrent else { return }
        let expectedIdentity = requestedAppUserID
        do {
            let info = try await Purchases.shared.customerInfo()
            guard requestedAppUserID == expectedIdentity,
                  revenueCatIdentityIsCurrent else { return }
            apply(info)
        } catch {
            // Leave the last known entitlement in place. Dropping premium
            // because a refresh failed would lock a paying user out offline.
            GroveDiag.log("premium: entitlement refresh failed (\(error.localizedDescription))")
        }
    }

    private var revenueCatIdentityIsCurrent: Bool {
        guard Purchases.isConfigured else { return requestedAppUserID == nil }
        if let requestedAppUserID {
            return Purchases.shared.appUserID == requestedAppUserID
        }
        return Purchases.shared.isAnonymous
    }

    private func apply(_ info: CustomerInfo) {
        let entitlement = info.entitlements[Self.entitlementID]
        // Read before the guard below. An entitlement that is still active but
        // has moved from trial to paid changes this date without changing
        // `hasPremium`, and the early return would have skipped it.
        trialEndsAt = entitlement?.periodType == .trial ? entitlement?.expirationDate : nil
        let active = entitlement?.isActive == true
        guard active != hasPremium else { return }
        hasPremium = active
        GroveDiag.log("premium: entitlement \(active ? "active" : "inactive")")
    }

    // MARK: - Purchase

    func purchase(_ plan: Plan) async -> PurchaseOutcome {
        guard Purchases.isConfigured,
              revenueCatIdentityIsCurrent,
              let package = packages[plan] else { return .unavailable }
        let purchaseIdentity = requestedAppUserID
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return .cancelled }
            guard requestedAppUserID == purchaseIdentity,
                  revenueCatIdentityIsCurrent else { return .unavailable }
            apply(result.customerInfo)
            // A completed purchase that did not grant the entitlement means the
            // product is not attached to it in the dashboard. The money is
            // taken either way, so the user is let through rather than charged
            // and walled; the alarm is for us.
            if !hasPremium {
                reportEmptyCatalogue(reason: "purchase completed without granting \(Self.entitlementID)")
                hasPremium = true
            }
            return .unlocked
        } catch {
            return outcome(for: error)
        }
    }

    private func outcome(for error: Error) -> PurchaseOutcome {
        guard let code = error as? RevenueCat.ErrorCode else {
            return .failed(message: "The purchase couldn't be completed. Try again.")
        }
        switch code {
        case .purchaseCancelledError:
            return .cancelled
        case .paymentPendingError:
            // Ask to Buy, or a bank confirmation. The entitlement arrives over
            // `customerInfoStream` when it clears, so the user is let through.
            return .pending
        case .productNotAvailableForPurchaseError:
            return .unavailable
        case .networkError, .offlineConnectionError:
            return .failed(message: "Grove couldn't reach the App Store. Check your connection and try again.")
        default:
            return .failed(message: "The purchase couldn't be completed. Try again.")
        }
    }

    /// Lifts a premium limit when there is genuinely nothing to sell.
    ///
    /// This exists so a metered feature can ship before the catalogue does
    /// without ever becoming a wall a user cannot pay to pass. It grants the
    /// entitlement in memory only: nothing is written, so the next launch
    /// re-checks and the limit returns the moment offerings exist. Never call
    /// it on a cancelled or failed purchase.
    func grantUnsoldPremium() {
        // `didLoadCatalogue` is the difference between "there is nothing to
        // charge for" and "the query never resolved". Only the first is grounds
        // for lifting a limit; the second is an offline user, and handing them
        // the entitlement is the same bypass `isUnmetered` closes.
        guard didLoadCatalogue, packages.isEmpty else { return }
        hasPremium = true
    }

    /// One place to notice that Grove is giving itself away.
    ///
    /// An empty catalogue is the correct, deliberate state before launch. After
    /// launch it means a dashboard mistake, and because the app fails open it
    /// would otherwise be invisible until the revenue graph stayed flat. Fail
    /// open for the user, loudly for us.
    private func reportEmptyCatalogue(reason: String) {
        guard !didReportEmptyCatalogue else { return }
        didReportEmptyCatalogue = true
        GroveDiag.log("premium: SELLING NOTHING — \(reason)")
        Task { await GroveAnalytics.shared.record("premium_catalogue_empty", ["reason": reason]) }
    }

    /// What a restore found. Kept apart from a plain yes/no because "the App
    /// Store has no purchase for you" and "the App Store could not be asked"
    /// need different answers: telling a paying subscriber who is offline that
    /// there is nothing to restore is wrong, and it sends them to buy again.
    enum RestoreOutcome: Equatable {
        case restored
        case notFound
        case failed(message: String)
    }

    /// App Review requires restore to exist even before purchases ship.
    func restorePurchases() async -> RestoreOutcome {
        guard Purchases.isConfigured else {
            return .failed(message: "Restoring isn't available in this version of Grove.")
        }
        // The account is still being handed to RevenueCat. Restoring now could
        // attach the purchase to the wrong identity, so ask for a moment.
        guard revenueCatIdentityIsCurrent else {
            return .failed(message: "Your account is still loading. Try again in a moment.")
        }
        let restoreIdentity = requestedAppUserID
        do {
            let info = try await Purchases.shared.restorePurchases()
            guard requestedAppUserID == restoreIdentity,
                  revenueCatIdentityIsCurrent else {
                return .failed(message: "Your account changed while restoring. Try again.")
            }
            apply(info)
        } catch {
            GroveDiag.log("premium: restore failed (\(error.localizedDescription))")
            return .failed(message: restoreFailureMessage(for: error))
        }
        return hasPremium ? .restored : .notFound
    }

    /// Kept for callers that only need a yes. A failure reads as "not
    /// restored" here; use `restorePurchases()` to tell the two apart.
    func restore() async -> Bool {
        await restorePurchases() == .restored
    }

    private func restoreFailureMessage(for error: Error) -> String {
        switch error as? RevenueCat.ErrorCode {
        case .networkError?, .offlineConnectionError?:
            "Couldn't reach the App Store. Check your connection and try again."
        default:
            "Your purchases couldn't be restored just now. Try again."
        }
    }

#if DEBUG
    /// Seeds a resolved catalogue without a network round trip, so the price,
    /// savings, trial and metering rules can be tested directly. Debug-only:
    /// the real catalogue only ever comes from RevenueCat.
    func seedCatalogueForTesting(
        packages: [Plan: Package],
        eligibleFreeTrials: [Plan: StoreProductDiscount] = [:],
        didLoadCatalogue: Bool = true
    ) {
        self.packages = packages
        self.eligibleFreeTrials = eligibleFreeTrials
        self.didLoadCatalogue = didLoadCatalogue
    }
#endif

    // MARK: - Formatting

    private func billingPeriod(for product: StoreProduct) -> String {
        guard let period = product.subscriptionPeriod else {
            return product.productIdentifier == Plan.yearly.defaultProductID ? "year" : "month"
        }
        if period.value == 1 {
            switch period.unit {
            case .day: return "day"
            case .week: return "week"
            case .month: return "month"
            case .year: return "year"
            @unknown default: return "billing period"
            }
        }
        return "\(period.value) \(periodUnit(period.unit, value: period.value))"
    }

    private func periodUnit(_ unit: SubscriptionPeriod.Unit, value: Int) -> String {
        switch unit {
        case .day: value == 1 ? "day" : "days"
        case .week: value == 1 ? "week" : "weeks"
        case .month: value == 1 ? "month" : "months"
        case .year: value == 1 ? "year" : "years"
        @unknown default: "period"
        }
    }
}
