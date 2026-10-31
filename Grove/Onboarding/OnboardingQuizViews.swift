import Combine
import SwiftUI
import MapKit
import CoreLocation
import UIKit

/// The small, read-only slice of a staged first plant that conversion screens
/// need. Keeping copy derivation here means Premium and account creation cannot
/// quietly describe the same baseline differently.
struct OnboardingFirstPlantPresentation {
    let nickname: String
    let commonName: String
    let scientificName: String
    let identificationIsUnknown: Bool
    var identificationIsProvisional: Bool = false
    let followUpDays: Int
    let capturedAt: Date
    let photoData: Data?
    /// The staged reading's health, for the first-run result. Optional so the
    /// presentation can still be built by hand without a full analysis.
    var healthScore: Int? = nil
    var healthBand: HealthBand? = nil
    var identificationConfidence: Int? = nil
    var identityConfirmation: PlantIdentityConfirmation? = nil
    /// The room the person filed the plant under, or "Unassigned".
    var room: String = "Unassigned"
    /// False when the photos could not support a health read at all. Kept on
    /// the presentation so the result can withhold a number instead of turning
    /// an unassessed scan into a confident-looking score.
    var assessmentAvailable: Bool = true
    /// The scan's first actions, already trimmed and capped, for the care
    /// basics shown before the account gate. Empty when nothing is safe to say.
    var firstActions: [String] = []

    /// The room, or nil while the plant has not been given one.
    var assignedRoom: String? {
        let trimmed = room.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.caseInsensitiveCompare("Unassigned") == .orderedSame ? nil : trimmed
    }

    /// The date the first check-in falls due, counted from the capture.
    var firstCheckInDate: Date {
        Calendar.current.date(byAdding: .day, value: followUpDays, to: capturedAt) ?? capturedAt
    }

    /// Household safety for the identified species. A photo match never earns
    /// reassurance on its own, so an unconfirmed "no known toxicity" reads as
    /// unverified rather than safe.
    var safety: PlantSafety? {
        guard !isUnknownIdentity else { return nil }
        return PlantSafety(
            commonName: commonName,
            scientificName: scientificName,
            confirmation: identityConfirmation ?? .photoMatch
        )
    }

    var displayName: String {
        let resolvedNickname = Self.nonEmpty(nickname, fallback: "")
        if !Self.isUnknownName(resolvedNickname) { return resolvedNickname }

        let resolvedSpecies = Self.nonEmpty(commonName, fallback: "")
        if !isUnknownIdentity, !Self.isUnknownName(resolvedSpecies) { return resolvedSpecies }
        return "your plant"
    }

    var isUnknownIdentity: Bool {
        identificationIsUnknown || Self.isUnknownName(commonName)
    }

    /// Whether the scientific name is worth showing: not an unknown identity,
    /// not blank, and not the placeholder the service returns when it could not
    /// settle the species. Rendering those raw put "Species unconfirmed" in
    /// italic under a headline that already said the identity was unknown.
    var showsScientificName: Bool {
        guard !isUnknownIdentity else { return false }
        let scientific = scientificName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !scientific.isEmpty
            && scientific.caseInsensitiveCompare("Species unconfirmed") != .orderedSame
    }

    var identityLine: String {
        if identificationIsProvisional { return "Possible match: \(commonName)" }
        if isUnknownIdentity {
            return displayName == "your plant" ? "Your first plant" : displayName
        }
        let species = Self.nonEmpty(commonName, fallback: "Plant identification pending")
        guard displayName.caseInsensitiveCompare(species) != .orderedSame else { return species }
        return "\(displayName) · \(species)"
    }

    var baselineCaptureDescription: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(capturedAt) { return "Baseline captured today" }
        if calendar.isDateInYesterday(capturedAt) { return "Baseline captured yesterday" }
        return "Baseline captured \(capturedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    var carePlanDescription: String {
        isUnknownIdentity || identificationIsProvisional
            ? "You can confirm the species later" : "Care guide ready"
    }

    var firstCheckInDescription: String {
        followUpDays == 1 ? "First check-in tomorrow" : "First check-in in \(followUpDays) days"
    }

    var authTitle: String {
        "Save \(displayName)."
    }

    var accessibilityDescription: String {
        var parts = [identityLine]
        if showsScientificName {
            parts.append(scientificName.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        parts.append(baselineCaptureDescription)
        parts.append(carePlanDescription)
        parts.append(firstCheckInDescription)
        return parts.joined(separator: ". ")
    }

    var image: UIImage? {
        photoData.flatMap(UIImage.init(data:))
    }

    @MainActor
    static func load(from store: PendingFirstPlantStore = .shared) async -> Self? {
        do {
            guard let draft = try await store.loadUnclaimed() else { return nil }
            let photoData = try await store.photoData()
            let condition = draft.analysis.condition
            // An unavailable assessment has no score worth showing and no
            // actions safe to quote; only retake guidance belongs on screen.
            let assessed = condition.assessmentAvailable != false
            var actions: [String] = []
            if assessed {
                let cleaned = condition.nextActions
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                actions = Array(cleaned.prefix(2))
            }
            return Self(
                nickname: draft.nickname,
                commonName: draft.analysis.identification.commonName,
                scientificName: draft.analysis.identification.scientificName,
                identificationIsUnknown: draft.analysis.identification.isUnknown == true,
                identificationIsProvisional: draft.analysis.identification.requiresConfirmation == true,
                followUpDays: GroveStore.firstCheckInDays(
                    analysisDays: condition.followUpDays,
                    band: condition.healthBand
                ),
                capturedAt: draft.capturedAt,
                photoData: photoData,
                healthScore: assessed ? condition.healthScore : nil,
                healthBand: assessed ? condition.healthBand : nil,
                identificationConfidence: draft.analysis.identification.confidence,
                identityConfirmation: draft.analysis.identification.identityConfirmation,
                room: draft.location,
                assessmentAvailable: assessed,
                firstActions: actions
            )
        } catch {
            // Conversion must never strand the funnel because its decorative
            // context could not be restored. The underlying onboarding step owns
            // recovery; these screens keep their truthful generic fallback.
            GroveDiag.log("first plant conversion context unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private static func nonEmpty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func isUnknownName(_ value: String) -> Bool {
        let normalised = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalised.isEmpty
            || normalised == "unknown plant"
            || normalised == "identity uncertain"
            || normalised == "species unconfirmed"
    }
}

/// The first advice a new owner gets, shown before any account is asked for.
///
/// Derived only from what the scan actually settled: checked species care when
/// the identity is confirmed, the scan's own first actions, and an honest
/// generic watering line otherwise. A provisional or unknown plant never
/// borrows species advice it has not earned.
struct OnboardingCareBasics: Equatable {
    struct Line: Equatable, Hashable {
        let label: String
        let text: String
    }

    let lines: [Line]

    static func make(for plant: OnboardingFirstPlantPresentation) -> OnboardingCareBasics {
        var lines: [Line] = []
        var hasWater = false

        if !plant.isUnknownIdentity && !plant.identificationIsProvisional {
            let profile = PlantCareProfile(
                commonName: plant.commonName,
                scientificName: plant.scientificName
            )
            if profile.matchedSpecies {
                let water = profile.wateringShort.replacingOccurrences(of: "; ", with: ", ")
                lines.append(Line(label: "Water", text: water))
                hasWater = true
                lines.append(Line(label: "Light", text: profile.lightHeadline))
            }
        }

        for (index, action) in plant.firstActions.prefix(2).enumerated() {
            lines.append(Line(label: index == 0 ? "First" : "Then", text: action))
        }

        if !hasWater {
            lines.append(Line(
                label: "Water",
                text: "Only when the top 2–3 cm of soil feels dry. Not on a fixed schedule."
            ))
        }

        if plant.followUpDays == 1 {
            lines.append(Line(label: "Check-in", text: "Grove asks for a new photo tomorrow"))
        } else {
            lines.append(Line(
                label: "Check-in",
                text: "Grove asks for a new photo in \(plant.followUpDays) days"
            ))
        }

        return OnboardingCareBasics(lines: lines)
    }
}

// MARK: - Name step

/// The one profile field Grove needs after proving its value with the first
/// plant and before creating the account. It remains editable because the name
/// someone wants on a care app is not always the one on an identity provider.
struct OnboardingNameStepView: View {
    @Bindable var model: OnboardingModel
    @FocusState private var focused: Bool

    var body: some View {
        OnboardingScaffold(
            showsBack: true,
            onBack: model.back
        ) {
            OnboardingStepHeader(
                title: "What's your name?",
                // Someone who tapped "I already have a Grove" and landed here
                // signed in fine — they are just new. Saying so is the whole
                // difference between a welcome and an unexplained detour.
                subtitle: model.arrivedFromSignIn
                    ? "You're signed in. This grove is empty, so let's plant it."
                    : "We'll use it in your morning hello.",
                bottomPadding: 30
            )
            OnboardingRuleField(isFocused: focused) {
                TextField(
                    "",
                    text: $model.firstName,
                    prompt: Text("First name").foregroundColor(OnboardingTheme.mutedInk)
                )
                // The answer is set in the same rounded display voice as the
                // question above it, one step down the scale, so the two read
                // as one sentence.
                .font(GroveTheme.display(GroveDisplayStyle.section.points))
                .foregroundStyle(OnboardingTheme.ink)
                .tint(OnboardingTheme.accentStrong)
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.continue)
                .onSubmit {
                    if model.canAdvanceFromCurrentStep { model.advance() }
                }
                .accessibilityIdentifier("onboardingNameField")
            }
        } footer: {
            OnboardingPrimaryButton(
                title: "Continue",
                isEnabled: model.canAdvanceFromCurrentStep
            ) {
                model.advance()
            }
            .accessibilityIdentifier("onboardingContinue")
        }
        // Focus set during the push transition gets dropped by SwiftUI, which
        // left the step sitting on a full screen of empty white with no keyboard.
        // Waiting for the transition to settle raises it every time, so the CTA
        // rides above the keyboard and the step reads as one compact block.
        .task {
            guard model.firstName.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(450))
            focused = true
        }
        .onChange(of: model.firstName) { _, value in
            let canonical = value.precomposedStringWithCanonicalMapping
            let bounded = String(canonical.unicodeScalars.prefix(SessionService.maxDisplayNameLength))
            if canonical.unicodeScalars.count > SessionService.maxDisplayNameLength {
                model.firstName = bounded
            }
            model.persistDraft()
        }
    }
}

// MARK: - Single-select quiz step

/// A concise personalization question.
///
/// There is nothing to confirm about a single-select answer, so the tap that
/// chooses is the tap that moves: the row fills, and the step leaves a beat
/// later. A separate Continue charged three taps across the quiz, made a
/// disabled grey pill the most prominent thing on the page, and turned three
/// short personal questions into a form being filled in.
///
/// Assistive technology is the exception. VoiceOver and Switch Control move
/// focus deliberately, and a screen that navigates out from under an
/// announcement is disorienting rather than quick — so those users keep the
/// explicit two-step, selection then Continue. (Full Keyboard Access has no
/// public status API; a keyboard user activating a row is making the same
/// deliberate choice a tap does, so it takes the fast path.)
struct OnboardingSingleChoiceStep: View {
    let model: OnboardingModel
    var progress: (current: Int, total: Int)? = nil
    var eyebrow: String? = nil
    let title: String
    var subtitle: String?
    let options: [OnboardingOption]
    let selection: String?
    let onSelect: (String) -> Void

    /// Tracked as state rather than read inline: the switches can be flipped
    /// mid-flow from Control Center or the accessibility shortcut, and the
    /// footer has to appear when they are.
    @State private var usesAssistiveNavigation = OnboardingSingleChoiceStep.assistiveNavigationActive
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A photo the height of a hand-held phone's top third. At accessibility
    /// sizes it steps down so the question and first answer still lead.
    private var heroHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 170 : 300
    }

    var body: some View {
        OnboardingPhotoSheet(
            heroHeight: heroHeight,
            sheetColor: OnboardingTheme.base,
            showsBack: true,
            showsFooter: usesAssistiveNavigation
        ) {
            OnboardingHeroPhoto(name: "OnboardingWelcomeHero")
        } content: {
            if let progress {
                OnboardingStepProgress(current: progress.current, total: progress.total)
            }
            OnboardingStepHeader(eyebrow: eyebrow, title: title, subtitle: subtitle)
            VStack(spacing: 10) {
                ForEach(options) { option in
                    OnboardingChoiceRow(
                        title: option.title,
                        detail: option.detail,
                        artworkName: option.artworkName,
                        systemImage: option.systemImage,
                        isSelected: selection == option.id
                    ) {
                        Haptics.tap()
                        onSelect(option.id)
                        model.persistDraft()
                        if !usesAssistiveNavigation { model.autoAdvance() }
                    }
                    .accessibilityIdentifier("onboardingChoice.\(option.id)")
                }
            }
        } footer: {
            if usesAssistiveNavigation {
                OnboardingPrimaryButton(
                    title: "Continue",
                    isEnabled: model.canAdvanceFromCurrentStep
                ) {
                    model.advance()
                }
                .accessibilityIdentifier("onboardingContinue")
            }
        } onBack: {
            model.back()
        }
        .onReceive(Self.assistiveStatusChanges) { _ in
            usesAssistiveNavigation = Self.assistiveNavigationActive
        }
    }

    private static var assistiveNavigationActive: Bool {
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    }

    private static var assistiveStatusChanges: AnyPublisher<Notification, Never> {
        let center = NotificationCenter.default
        return Publishers.MergeMany(
            center.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification),
            center.publisher(for: UIAccessibility.switchControlStatusDidChangeNotification)
        )
        .eraseToAnyPublisher()
    }
}

// MARK: - Premium

/// Grove's Premium offer.
///
/// It no longer sits inside onboarding. Asking for money before the account
/// existed meant asking someone whose baseline was not saved yet, on the
/// strength of a single screen; `GrovePremiumOfferPresenter` now raises this
/// once the person has completed a meaningful care-loop action in a grove they
/// own. Core plant care is never the price of entry, so dismissing it always
/// moves on.
///
/// The screen is a night-green page: a fern photograph fades into the ground,
/// then a plain Free against Premium table, the Premium mascots, and the two
/// plans. Every limit in the table is read from the constant that enforces it,
/// and every price, saving and trial comes from StoreKit for the current Apple
/// account. Nothing is shown as a price until the catalogue has answered.
struct GrovePremiumOfferView: View {
    /// The plant the offer was raised for. Kept so the presenter's contract is
    /// unchanged; the offer itself now leads with what Premium adds rather than
    /// with one plant.
    var subject: GrovePremiumOfferSubject?
    /// Dismissal, purchase and "continue without Premium" all end here. The
    /// caller decides whether that means advancing a funnel or closing a sheet.
    var onFinish: () -> Void

    @Environment(GrovePremiumStore.self) private var premium
    @Environment(NotificationService.self) private var notifications
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selectedPlan: GrovePremiumStore.Plan = .yearly
    @State private var isWorking = false
    @State private var failure: String?
    @State private var restoreMessage: String?

    private var isPurchasable: Bool {
        premium.displayPrice(for: .yearly) != nil || premium.displayPrice(for: .monthly) != nil
    }

    /// Whether trial copy may be shown at all: only once the catalogue has
    /// answered and StoreKit will actually honour a trial for this Apple
    /// account. Someone who has already used the introductory offer must
    /// never see "free" on this screen.
    ///
    /// There is no trial switch. StoreKit applies an eligible introductory
    /// offer to the purchase whatever the screen says, so a toggle could only
    /// ever describe the purchase wrongly.
    private var showsTrial: Bool {
        !premium.hasPremium
            && (premium.freeTrialDays(for: .yearly) != nil || premium.freeTrialDays(for: .monthly) != nil)
    }

    /// The photo gives way on shorter phones so the title, the comparison
    /// and the mascots all sit above the footer at rest. On a 402x874 phone
    /// the full 380pt photo pushed the mascot caption under the footer.
    private func heroHeight(available height: CGFloat) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 240 }
        return height < 820 ? 290 : 380
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GroveTheme.mapGround.ignoresSafeArea()

            GeometryReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            hero
                                .frame(
                                    width: proxy.size.width,
                                    height: heroHeight(available: proxy.size.height) + proxy.safeAreaInsets.top
                                )
                                .clipped()

                            VStack(alignment: .leading, spacing: 24) {
                                introduction
                                PaywallComparisonTable(rows: PaywallComparison.rows)
                                PaywallMascotRow()
                                    .padding(.horizontal, 4)
                                storeOffer
                            }
                            .padding(.horizontal, 16)
                            // The title sits on the faded lower part of the photo.
                            .padding(.top, dynamicTypeSize.isAccessibilitySize ? -70 : -150)
                            .padding(.bottom, 24)
                        }
                        .animation(reduceMotion ? nil : GroveMotion.snap, value: selectedPlan)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    // A short fade into the footer, so whatever the viewport
                    // cuts at rest reads as more to scroll rather than as text
                    // sliced in half. Kept shallow and eased towards the edge:
                    // a long linear fade over the white plan card read as a
                    // dark band across it rather than a soft edge.
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            stops: [
                                .init(color: GroveTheme.mapGround.opacity(0), location: 0),
                                .init(color: GroveTheme.mapGround.opacity(0.35), location: 0.6),
                                .init(color: GroveTheme.mapGround, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 16)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    // Let the photo own the physical top edge, behind the status
                    // bar, rather than sitting under a flat band.
                    .ignoresSafeArea(edges: .top)

                    footer
                }
            }

            // The close affordance stays anchored to the viewport while the
            // photo scrolls underneath it.
            closeButton
                .padding(.top, 6)
                .padding(.trailing, 16)
        }
        .accessibilityIdentifier("onboardingPaywall")
        .preferredColorScheme(.dark)
        .task { await premium.load() }
        // So the trial promise below is written against what iOS will actually
        // allow, rather than against an unread status.
        .task { await notifications.refreshAuthorization() }
    }

    private var closeButton: some View {
        Button {
            OnboardingAnalytics.paywallAction("skipped")
            onFinish()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(GroveTheme.ink)
                .frame(width: 44, height: 44)
                .background(GroveTheme.ink.opacity(0.14), in: Circle())
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.94, haptics: false))
        .disabled(isWorking)
        .opacity(isWorking ? 0.4 : 1)
        .accessibilityLabel("Continue without Premium")
        .accessibilityIdentifier("onboardingPaywallClose")
    }

    /// Ferns in soft light, dissolving into the night green so the title can
    /// sit on the lower part of the photograph.
    private var hero: some View {
        OnboardingHeroPhoto(name: "PlantShareBackdrop")
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: GroveTheme.mapGround.opacity(0.1), location: 0),
                        .init(color: GroveTheme.mapGround.opacity(0.55), location: 0.55),
                        .init(color: GroveTheme.mapGround, location: 0.96)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .accessibilityHidden(true)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Grove Premium".uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(GroveTheme.mapCaption)
            Text("Unlimited questions to Ari and as many friends as you like.")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var storeOffer: some View {
        VStack(spacing: 10) {
            ForEach([GrovePremiumStore.Plan.yearly, .monthly], id: \.self) { plan in
                planRow(plan)
            }
        }
    }

    private func planRow(_ plan: GrovePremiumStore.Plan) -> some View {
        let isSelected = selectedPlan == plan
        return Button {
            Haptics.selection()
            selectedPlan = plan
            failure = nil
            restoreMessage = nil
            OnboardingAnalytics.paywallAction("plan_selected", plan: plan)
        } label: {
            PaywallPlanCard(
                title: plan == .yearly ? "Yearly" : "Monthly",
                price: premium.displayPrice(for: plan),
                detail: planDetail(for: plan),
                badge: plan == .yearly ? premium.yearlySavingsLabel : nil,
                isSelected: isSelected,
                isUnavailable: premium.didLoadCatalogue && premium.displayPrice(for: plan) == nil
            )
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.985, haptics: false))
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("onboardingPremiumPlan.\(plan.rawValue)")
    }

    /// The line under the plan's name. The trial leads when there is one for
    /// this plan and this Apple account; the yearly plan also says what it
    /// works out to a month, from the live product.
    private func planDetail(for plan: GrovePremiumStore.Plan) -> String? {
        // "7 days free, then $34.99 a year": the trial and what follows it,
        // in the same words every Grove paywall uses.
        if showsTrial, let trial = PremiumTerms.trialLine(premium, plan: plan) {
            return trial
        }
        if plan == .yearly, let perMonth = premium.monthlyEquivalentPrice(for: .yearly) {
            return "\(perMonth) a month, billed yearly"
        }
        return nil
    }

    private func message(_ text: String, colour: Color) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(colour)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    private var restoreButton: some View {
        Button(isWorking ? "Working…" : "Restore") {
            Task { await restorePurchases() }
        }
        .disabled(isWorking)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            if let failure {
                message(failure, colour: GroveTheme.danger)
            } else if let restoreMessage {
                message(restoreMessage, colour: GroveTheme.ink.opacity(0.7))
            }

            Button {
                Task { await primaryAction() }
            } label: {
                HStack(spacing: 10) {
                    Text(primaryActionTitle)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if isWorking {
                        ProgressView()
                            .tint(GroveTheme.mapGround)
                    }
                }
                .foregroundStyle(GroveTheme.mapGround)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(GroveTheme.ink, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(GrovePressStyle())
            .disabled(isWorking)
            .opacity(isWorking ? 0.7 : 1)
            .accessibilityIdentifier("onboardingPaywallPrimary")

            OnboardingLinkRow {
                restoreButton
                    .frame(minHeight: 44)
                Link("Terms", destination: OnboardingLegal.termsURL)
                    .frame(minHeight: 44)
                Link("Privacy", destination: OnboardingLegal.privacyURL)
                    .frame(minHeight: 44)
            }
            .foregroundStyle(GroveTheme.ink.opacity(0.7))
            .tint(GroveTheme.ink.opacity(0.7))
            .padding(.top, -6)

            if let renewalNote {
                Text(renewalNote)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.ink.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(GroveTheme.mapGround)
    }

    /// The renewal terms for the selected plan, said plainly. Nothing when
    /// there is nothing to renew.
    private var renewalNote: String? {
        guard !premium.hasPremium, isPurchasable else { return nil }
        guard let terms = PremiumTerms.renewalNote(premium, plan: selectedPlan) else { return nil }
        // The reminder is only promised to someone Grove can still reach.
        if showsTrial, premium.freeTrialDays(for: selectedPlan) != nil,
           notifications.authorization != .denied {
            return "\(terms) You'll get a reminder before the trial ends."
        }
        return terms
    }

    private var primaryActionTitle: String {
        if premium.hasPremium { return "Continue with Premium" }
        // The store answered with nothing to sell: the button only closes, so
        // it must not read as a purchase.
        if premium.didLoadCatalogue && !isPurchasable { return "Continue to Grove" }
        // The store never answered: the prices are placeholders, so the
        // button retries rather than reading as a purchase that only closes.
        if !premium.didLoadCatalogue { return "Try again" }
        if showsTrial, let trial = PremiumTerms.trialButtonTitle(premium, plan: selectedPlan) {
            return trial
        }
        return "Start Premium, \(selectedPlan == .yearly ? "yearly" : "monthly")"
    }

    private func primaryAction() async {
        failure = nil
        restoreMessage = nil

        if premium.hasPremium {
            OnboardingAnalytics.paywallAction("continued_active")
            onFinish()
            return
        }

        guard isPurchasable else {
            if !premium.didLoadCatalogue {
                // Offline is not "nothing on sale". Retry the catalogue and
                // stay; the close button is still the way past.
                isWorking = true
                await premium.load()
                isWorking = false
                if !premium.didLoadCatalogue {
                    failure = "Still can't reach the App Store. Check your connection and try again."
                }
                return
            }
            OnboardingAnalytics.paywallAction("continued_placeholder", plan: selectedPlan)
            onFinish()
            return
        }

        isWorking = true
        defer { isWorking = false }
        let startsTrial = showsTrial && premium.freeTrialDays(for: selectedPlan) != nil
        OnboardingAnalytics.paywallAction("purchase_started", plan: selectedPlan)
        switch await premium.purchase(selectedPlan) {
        case .unlocked:
            Haptics.celebrate()
            OnboardingAnalytics.paywallAction("purchase_completed", plan: selectedPlan)
            if startsTrial { await armTrialReminder() }
            onFinish()
        case .pending:
            // Ask to Buy: nothing is charged or unlocked yet. Say so, and
            // leave the close button as the way on.
            OnboardingAnalytics.paywallAction("purchase_pending", plan: selectedPlan)
            restoreMessage = PremiumTerms.pendingMessage
        case .cancelled:
            OnboardingAnalytics.paywallAction("purchase_cancelled", plan: selectedPlan)
        case .unavailable:
            failure = PremiumTerms.unavailableMessage
            OnboardingAnalytics.paywallAction("purchase_unavailable", plan: selectedPlan)
        case .failed(let message):
            failure = message
            OnboardingAnalytics.paywallAction("purchase_failed", plan: selectedPlan)
        }
    }

    /// Asks for the permission the footer has just promised to use.
    ///
    /// "You'll get a reminder before the trial ends" was unkeepable copy: the
    /// notice is a local notification, and nothing on the onboarding path had
    /// asked for permission yet, so the one Grove notification with money
    /// attached to it was silently dropped for anyone who started a trial before
    /// their first plant. A trial start is the moment the ask explains itself,
    /// so it happens here rather than three screens later. Only while the answer
    /// is still open — re-asking a denied user does nothing but lose a launch to
    /// a dialog iOS will not show.
    private func armTrialReminder() async {
        // Read it first. Nothing on the signed-out path had ever asked iOS, so
        // the status sits at `.unknown` here — guarding on `.notDetermined`
        // without this would skip the ask for every single trial.
        await notifications.refreshAuthorization()
        guard notifications.authorization == .notDetermined else { return }
        await notifications.requestAuthorization()
        OnboardingAnalytics.notificationsDecision(
            .system(authorization: notifications.authorization)
        )
    }

    private func restorePurchases() async {
        failure = nil
        restoreMessage = nil
        isWorking = true
        let outcome = await premium.restorePurchases()
        isWorking = false
        switch outcome {
        case .restored:
            Haptics.celebrate()
            OnboardingAnalytics.paywallAction("restored")
            onFinish()
        case .notFound:
            restoreMessage = PremiumTerms.restoreNotFoundMessage
            OnboardingAnalytics.paywallAction("restore_not_found")
        case .failed(let message):
            // An unreachable store is not "you never bought it".
            failure = message
            OnboardingAnalytics.paywallAction("restore_failed")
        }
    }

}

struct OnboardingOption: Identifiable {
    let id: String
    let title: String
    var detail: String?
    var artworkName: String?
    var systemImage: String?
}

/// Shown only for the device that owns a newly completed signup. Credentials
/// are already durable; optional profile edits use the normal account sync queue.
struct PostSignupSetupGate<Content: View>: View {
    let accountID: String
    @ViewBuilder let content: () -> Content
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(NotificationService.self) private var notifications
    @AppStorage private var step: Int
    @AppStorage private var nameDraft: String
    @AppStorage(GroveDefaults.firstPlantNotificationPrimerPlantID) private var reminderPlantID = ""
    @AppStorage(GroveDefaults.reminderHour) private var reminderHour = NotificationService.reminderHour
    @State private var selectedLocation: GroveLocation?
    @State private var query = ""
    @State private var places: [GroveLocation] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var saveError: String?
    @State private var saving = false
    @State private var locationManager = GroveLocationManager()
    /// The plant the Day 1 summary celebrates, once reminders are settled.
    @State private var dayOnePlant: Plant?
    @FocusState private var nameFocused: Bool
    @FocusState private var cityFocused: Bool

    init(accountID: String, @ViewBuilder content: @escaping () -> Content) {
        self.accountID = accountID
        self.content = content
        _step = AppStorage(wrappedValue: 0, PostSignupSetupProgress.key(accountID))
        _nameDraft = AppStorage(wrappedValue: "", PostSignupSetupProgress.key(accountID) + ".name")
    }

    var body: some View {
        Group {
            if step == 1 {
                nameSproutPage
            } else if step == 2 {
                setupPage
            } else if let plant = dayOnePlant {
                OnboardingFirstWeekView(plant: plant, reminderHour: reminderHour) {
                    withAnimation(GroveMotion.settle) { dayOnePlant = nil }
                }
                .transition(.opacity)
            } else {
                content()
            }
        }
        .onChange(of: selectedLocation) { _, location in
            if let location, let data = try? JSONEncoder().encode(location) {
                UserDefaults.standard.set(data, forKey: PostSignupSetupProgress.key(accountID) + ".location")
            }
        }
        .task(id: "\(step)-\(reminderPlantID)") {
            guard store.activeAccountID == accountID else { return }
            if step == 1 {
                if nameDraft.isEmpty, store.profile.name.caseInsensitiveCompare("Gardener") != .orderedSame {
                    nameDraft = store.profile.name
                }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                nameFocused = true
            } else if step == 2 {
                selectedLocation = UserDefaults.standard.data(forKey: PostSignupSetupProgress.key(accountID) + ".location")
                    .flatMap { try? JSONDecoder().decode(GroveLocation.self, from: $0) } ?? store.profile.location
            } else if let id = UUID(uuidString: reminderPlantID), let plant = store.plant(id: id) {
                await notifications.refreshAuthorization()
                guard !Task.isCancelled else { return }
                // The first week's plan carries the reminder ask itself, over
                // the day it is for. The marker is consumed as the plan opens.
                dayOnePlant = plant
                finishReminders()
            }
        }
    }

    /// The name question in first run's voice. The location question that used
    /// to follow it is now asked before the account exists, so step 1 hands
    /// straight on to reminders.
    private var nameSproutPage: some View {
        OnboardingSproutPage(step: 5) {
            VStack(alignment: .leading, spacing: 22) {
                OnboardingQuestionTitle(
                    lead: "What’s your ",
                    accent: "name",
                    trail: "?",
                    subtitle: "It’s how friends see you in Grove."
                )
                nameField
                if let saveError {
                    Text(saveError).font(.callout).foregroundStyle(OnboardingTheme.danger)
                }
            }
        } footer: {
            VStack(spacing: 4) {
                OnboardingPrimaryButton(title: saving ? "Saving…" : "Continue", isEnabled: canContinue && !saving) {
                    saveAndAdvance(skip: false)
                }
                .accessibilityIdentifier("profileSetupContinue")
                OnboardingQuietButton(title: "Skip for now") { saveAndAdvance(skip: true) }
                    .disabled(saving)
                    .accessibilityIdentifier("profileSetupSkip")
            }
        }
        .accessibilityIdentifier("postSignupName")
    }

    private var setupPage: some View {
        VStack(spacing: 0) {
            HStack {
                if step == 2 {
                    OnboardingBackButton(isEnabled: !saving) { step = 1 }
                } else {
                    Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                }
                Spacer()
                Text("\(step) of 2")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(OnboardingTheme.mutedInk)
            }
            .padding(.horizontal, 28)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    OnboardingStepHeader(
                        title: step == 1 ? "What's your name?" : "Where do your plants live?",
                        subtitle: step == 1 ? "Make your grove feel like yours." : "Get local weather and seasonal care guidance.",
                        bottomPadding: 0
                    )
                    if step == 1 { nameField } else { locationField }
                    if let saveError {
                        Text(saveError).font(.callout).foregroundStyle(OnboardingTheme.danger)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    OnboardingPrimaryButton(title: saving ? "Saving…" : "Continue", isEnabled: canContinue && !saving) {
                        saveAndAdvance(skip: false)
                    }
                    .accessibilityIdentifier("profileSetupContinue")
                    Button("Skip for now") { saveAndAdvance(skip: true) }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(OnboardingTheme.mutedInk)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(saving)
                        .accessibilityIdentifier("profileSetupSkip")
                }
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(OnboardingTheme.base)
            }
        }
        .background(OnboardingTheme.base.ignoresSafeArea())
        .task(id: query) { await searchCities() }
        .onChange(of: locationManager.lastCoordinate.map { "\($0.latitude),\($0.longitude)" }) { _, _ in
            guard let coordinate = locationManager.lastCoordinate else { return }
            Task { await chooseCurrentLocation(coordinate) }
        }
        .accessibilityIdentifier(step == 1 ? "postSignupName" : "postSignupLocation")
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("First name").font(.subheadline.weight(.semibold))
            TextField("First name", text: $nameDraft)
                .font(.title3)
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($nameFocused)
                .submitLabel(.next)
                .onSubmit { if canContinue { saveAndAdvance(skip: false) } }
                .padding(18)
                .background(OnboardingTheme.elevated, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(nameFocused ? OnboardingTheme.accentStrong : OnboardingTheme.stroke, lineWidth: nameFocused ? 2 : 1) }
                .onChange(of: nameDraft) { _, value in
                    nameDraft = String(value.precomposedStringWithCanonicalMapping.unicodeScalars.prefix(SessionService.maxDisplayNameLength))
                }
                .accessibilityIdentifier("profileSetupNameField")
        }
        .foregroundStyle(OnboardingTheme.ink)
    }

    private var locationField: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Search for a city").font(.subheadline.weight(.semibold))
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("City or town", text: $query)
                    .autocorrectionDisabled()
                    .focused($cityFocused)
                    .submitLabel(.search)
                    .accessibilityIdentifier("profileSetupCitySearch")
                if searching { ProgressView() }
            }
            .padding(18)
            .background(OnboardingTheme.elevated, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(cityFocused ? OnboardingTheme.accentStrong : OnboardingTheme.stroke, lineWidth: cityFocused ? 2 : 1) }
            Button {
                cityFocused = false
                searchError = nil
                locationManager.requestCurrentLocation()
            } label: {
                Label(locationManager.status == .locating ? "Finding your location…" : "Use current location", systemImage: "location")
                    .frame(minHeight: 44)
            }
            .disabled(locationManager.status == .locating)
            .tint(OnboardingTheme.accentStrong)
            if locationManager.status == .denied {
                Text("Location access is off. You can search for your city instead.").font(.callout)
            } else if locationManager.status == .failed {
                Text("We couldn’t find your location. Try searching for your city.").font(.callout)
            }
            if let searchError { Text(searchError).font(.callout) }
            if let selectedLocation {
                Label(selectedLocation.label, systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(OnboardingTheme.accentStrong)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("profileSetupSelectedCity")
            }
            ForEach(places, id: \.self) { place in
                Button {
                    selectedLocation = place
                    cityFocused = false
                    Haptics.selection()
                } label: {
                    HStack {
                        Text(place.label).multilineTextAlignment(.leading)
                        Spacer()
                        if selectedLocation == place { Image(systemName: "checkmark") }
                    }
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .foregroundStyle(OnboardingTheme.ink)
    }

    private var canContinue: Bool {
        step == 1 ? !SessionService.normalizedDisplayName(nameDraft).isEmpty : selectedLocation != nil
    }

    private func saveAndAdvance(skip: Bool) {
        guard !saving, store.activeAccountID == accountID, syncEngine.activeAccountID == accountID else { return }
        nameFocused = false
        cityFocused = false
        guard !skip else { step = step == 1 ? 3 : step + 1; return }
        saving = true
        saveError = nil
        let currentStep = step
        let profile = store.profile
        let name = currentStep == 1 ? SessionService.normalizedDisplayName(nameDraft) : profile.name
        let location = currentStep == 2 ? selectedLocation : profile.location
        let request = UpdateProfileRequest(
            displayName: name, username: profile.username, regionCode: profile.regionCode ?? "",
            usesMetricSystem: profile.usesMetricSystem ?? true, isPrivate: profile.isPrivate ?? true,
            latitude: location?.latitude, longitude: location?.longitude, locationLabel: location?.label,
            locationCountryCode: location?.countryCode, locationTimeZoneIdentifier: location?.timeZoneIdentifier,
            clientRequestID: UUID()
        )
        Task {
            // Queue durably before advancing. Network delivery can happen later.
            let queued = await syncEngine.enqueue(.updateProfile(request), isConnected: false)
            guard store.activeAccountID == accountID else { return }
            saving = false
            guard queued else { saveError = "Your details couldn’t be saved. Try again."; return }
            if currentStep == 1 {
                store.updateProfile(name: name, username: profile.username, regionCode: profile.regionCode ?? "", usesMetricSystem: profile.usesMetricSystem ?? true, isPrivate: profile.isPrivate ?? true)
            } else {
                store.updateGroveLocation(location)
            }
            step = currentStep == 1 ? 3 : currentStep + 1
        }
    }

    private func searchCities() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { places = []; searching = false; return }
        searching = true
        searchError = nil
        do {
            try await Task.sleep(for: .milliseconds(350))
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            request.resultTypes = .address
            let response = try await MKLocalSearch(request: request).start()
            try Task.checkCancellation()
            places = response.mapItems.prefix(6).map { item in
                let pin = item.placemark
                let label = [pin.locality ?? item.name, pin.administrativeArea, pin.country].compactMap { $0 }.joined(separator: ", ")
                return GroveLocation(coordinate: pin.coordinate, label: label, countryCode: pin.isoCountryCode, timeZoneIdentifier: pin.timeZone?.identifier)
            }
            places = Array(Set(places)).sorted { $0.label < $1.label }
            if places.isEmpty { searchError = "No places found. Try a nearby city or add the country." }
            searching = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            places = []
            searching = false
            searchError = "City search is unavailable. Try again or skip for now."
        }
    }

    private func chooseCurrentLocation(_ coordinate: CLLocationCoordinate2D) async {
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard let place = placemarks.first else { return }
            let label = [place.locality ?? place.administrativeArea, place.country].compactMap { $0 }.joined(separator: ", ")
            selectedLocation = GroveLocation(coordinate: coordinate, label: label, countryCode: place.isoCountryCode, timeZoneIdentifier: place.timeZone?.identifier)
        } catch {
            searchError = "We couldn’t find that place. Search for your city instead."
        }
    }

    private func finishReminders() {
        reminderPlantID = ""
    }
}
