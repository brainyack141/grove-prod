import SwiftUI
import UIKit

/// The four-step free-trial flow shown at the end of onboarding.
///
/// The route decides which steps exist for this Apple account, so a customer
/// who cannot redeem an introductory offer never sees a reminder step for a
/// trial they will not get. Every price and date on screen comes from the live
/// store and the same date functions that schedule the real notification.
struct GroveTrialFlowView: View {
    enum Step: Hashable {
        case tryFree
        case reminder
        case timeline
        case beforeYouGo

        var analyticsAction: String {
            switch self {
            case .tryFree: "trial_step_try_free"
            case .reminder: "trial_step_reminder"
            case .timeline: "trial_step_timeline"
            case .beforeYouGo: "trial_step_before_you_go"
            }
        }
    }

    var subject: GrovePremiumOfferSubject?
    var onFinish: () -> Void

    @Environment(GrovePremiumStore.self) private var premium
    @Environment(NotificationService.self) private var notifications
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(GroveDefaults.reminderHour) private var reminderHour = NotificationService.reminderHour

    @State private var step: Step
    @State private var selectedPlan: GrovePremiumStore.Plan
    @State private var hasVisitedBeforeYouGo = false
    @State private var isWorking = false
    @State private var failure: String?
    @State private var restoreMessage: String?
    @State private var declineReason: GroveTrialDeclineReason?
    @State private var isCompactHeight = false

    init(
        subject: GrovePremiumOfferSubject?,
        initialStep: Step = .tryFree,
        initialPlan: GrovePremiumStore.Plan = .yearly,
        onFinish: @escaping () -> Void
    ) {
        self.subject = subject
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
        _selectedPlan = State(initialValue: initialPlan)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                GroveTheme.mapGround.ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                    stepBody(availableHeight: proxy.size.height)
                }
            }
            .onAppear {
                isCompactHeight = isCompact(proxy)
            }
            .onChange(of: proxy.size.height) { _, _ in
                isCompactHeight = isCompact(proxy)
            }
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("groveTrialFlow")
        .task { await premium.load() }
        .task { await notifications.refreshAuthorization() }
    }

    // MARK: - Store state

    /// The plan whose introductory offer the trial copy describes. Yearly leads,
    /// because that is the plan the flow offers first and the copy file's trial
    /// timeline is the yearly one. Nil means no trial can be redeemed at all.
    private var trialPlan: GrovePremiumStore.Plan? {
        if premium.freeTrialDays(for: .yearly) != nil { return .yearly }
        if premium.freeTrialDays(for: .monthly) != nil { return .monthly }
        return nil
    }

    private var showsTrial: Bool {
        !premium.hasPremium && trialPlan != nil
    }

    private var trialDays: Int? {
        trialPlan.flatMap { premium.freeTrialDays(for: $0) }
    }

    private var isPurchasable: Bool {
        premium.displayPrice(for: .yearly) != nil || premium.displayPrice(for: .monthly) != nil
    }

    private var isEmptyCatalogue: Bool {
        premium.didLoadCatalogue && !isPurchasable && !premium.hasPremium
    }

    private var canPurchase: Bool {
        premium.hasPremium || (premium.didLoadCatalogue && isPurchasable)
    }

    private var plantName: String {
        let name = subject?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "your plant" : name
    }

    private var plantImage: UIImage? {
        subject?.image ?? UIImage(named: "DemoPlantMonstera")
    }

    /// The plan the trial screens describe. Yearly leads whenever it has a
    /// trial, so going back from a monthly selection on the plans screen cannot
    /// quietly rewrite the trial's own price line.
    private var offerPlan: GrovePremiumStore.Plan {
        trialPlan ?? selectedPlan
    }

    // MARK: - Navigation

    private var canGoBack: Bool {
        step == .reminder || step == .timeline
    }

    private func go(to next: Step) {
        failure = nil
        restoreMessage = nil
        if reduceMotion {
            step = next
        } else {
            withAnimation(GroveMotion.settle) { step = next }
        }
    }

    private func advance() {
        if let next = GroveTrialFlowRoute.advance(from: step, hasTrial: showsTrial) {
            go(to: next)
        } else {
            onFinish()
        }
    }

    private func goBack() {
        guard let previous = GroveTrialFlowRoute.back(from: step, hasTrial: showsTrial) else { return }
        go(to: previous)
    }

    private func exitFlow() {
        switch GroveTrialFlowRoute.exit(from: step, hasVisitedBeforeYouGo: hasVisitedBeforeYouGo) {
        case .beforeYouGo:
            hasVisitedBeforeYouGo = true
            go(to: .beforeYouGo)
        case .finish:
            onFinish()
        }
    }

    private func closeFlow() {
        OnboardingAnalytics.paywallAction("skipped")
        onFinish()
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 4) {
            if canGoBack {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(GroveTheme.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(GroveCardPressStyle(scale: 0.94, haptics: false))
                .accessibilityLabel("Back")
                .accessibilityIdentifier("groveTrialBack")
            } else {
                Color.clear
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 0)

            if step != .beforeYouGo {
                Button {
                    Task { await restorePurchases() }
                } label: {
                    Text("Restore")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GroveTheme.ink.opacity(0.85))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .accessibilityIdentifier("groveTrialRestore")
            }

            Button(action: closeFlow) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .frame(width: 44, height: 44)
                    .background {
                        Circle().fill(GroveTheme.mapGround.opacity(0.92))
                    }
                    .overlay {
                        Circle().stroke(GroveTheme.ink.opacity(0.35), lineWidth: 1)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(GroveCardPressStyle(scale: 0.94, haptics: false))
            .disabled(isWorking)
            .opacity(isWorking ? 0.4 : 1)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("groveTrialClose")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    // MARK: - Steps

    @ViewBuilder
    private func stepBody(availableHeight: CGFloat) -> some View {
        Group {
            switch step {
            case .tryFree:
                tryFreeStep(phoneHeight: phoneHeight(for: availableHeight))
            case .reminder:
                reminderStep
            case .timeline:
                timelineStep
            case .beforeYouGo:
                beforeYouGoStep
            }
        }
        .id(step)
        .transition(.opacity)
        .onAppear { OnboardingAnalytics.paywallAction(step.analyticsAction) }
    }

    /// A short phone needs tighter content so the plans and the example
    /// conversation clear the pinned footer at rest. Accessibility sizes opt
    /// out: they already scroll as one page, and shrinking there would only
    /// make text hit the edge sooner.
    private func isCompact(_ proxy: GeometryProxy) -> Bool {
        let fullHeight = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        return fullHeight < 820 && !dynamicTypeSize.isAccessibilitySize
    }

    private func phoneHeight(for availableHeight: CGFloat) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 360 }
        return isCompactHeight
            ? min(max(availableHeight * 0.55, 300), 440)
            : min(max(availableHeight * 0.6, 320), 560)
    }

    private func stepScroll<Content: View, Footer: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    content()
                    if dynamicTypeSize.isAccessibilitySize {
                        footer()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)

            if !dynamicTypeSize.isAccessibilitySize {
                footer()
            }
        }
    }

    private func footerContainer<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 14) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(GroveTheme.mapGround)
    }

    // MARK: - Screen 02 · Try free

    private var tryFreeHeadline: String {
        if showsTrial, let days = trialDays {
            return "Ask Ari about \(plantName), free for \(days) day\(days == 1 ? "" : "s")."
        }
        return "Ask Ari about \(plantName) with Premium."
    }

    private var tryFreeButtonTitle: String {
        if premium.hasPremium { return "Continue with Premium" }
        if !premium.didLoadCatalogue { return "Checking the App Store…" }
        if !isPurchasable { return "Unavailable" }
        return showsTrial ? "Try Premium free" : "See Premium plans"
    }

    private func tryFreeStep(phoneHeight: CGFloat) -> some View {
        stepScroll {
            VStack(alignment: .leading, spacing: 16) {
                Text(tryFreeHeadline)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                phoneMock(height: phoneHeight)
            }
        } footer: {
            tryFreeFooter
        }
    }

    private var tryFreeFooter: some View {
        footerContainer {
            statusMessages
            catalogueNotice
            if showsTrial {
                checkLine("Nothing to pay today")
            }
            primaryButton(
                title: tryFreeButtonTitle,
                enabled: canPurchase
            ) {
                if premium.hasPremium {
                    onFinish()
                } else {
                    advance()
                }
            }
            if let line = priceLine(for: offerPlan) {
                priceCaption(line)
            }
            exitLink
            legalRow(restoreFirst: false, restoreTitle: "Restore")
        }
    }

    private func phoneMock(height: CGFloat) -> some View {
        let outerCorner = GroveTheme.heroRadius
        let innerCorner = GroveTheme.cardRadius
        let bezel: CGFloat = outerCorner - innerCorner
        let contentInset: CGFloat = isCompactHeight ? 10 : 12

        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: outerCorner, style: .continuous)
                .fill(GroveTheme.ink)
                .environment(\.colorScheme, .light)

            VStack(spacing: 0) {
                threadContent
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, contentInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                GroveTheme.background,
                in: RoundedRectangle(cornerRadius: innerCorner, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: innerCorner, style: .continuous))
            .environment(\.colorScheme, .light)
            .padding(bezel)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: outerCorner, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example conversation with Ari")
    }

    private var threadContent: some View {
        VStack(alignment: .leading, spacing: isCompactHeight ? 10 : 12) {
            if !isCompactHeight {
                HStack(spacing: 10) {
                    plantPhoto(size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plantName)
                            .font(.headline)
                            .foregroundStyle(GroveTheme.ink)
                            .lineLimit(1)
                        Text("Ask Ari")
                            .font(.caption)
                            .foregroundStyle(GroveTheme.mutedInk)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityHidden(true)

                Rectangle()
                    .fill(GroveTheme.separator)
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 10) {
                AriChatBubble(
                    role: .user,
                    text: userTurnText,
                    photo: plantImage.map(AriChatPhoto.image),
                    photoSize: isCompactHeight ? 80 : 110
                )
                AriChatBubble(role: .botanist, text: ariTurnText)
            }
        }
    }

    private var userTurnText: String {
        subject == nil
            ? "My plant's lower leaves are going yellow."
            : "\(plantName)'s lower leaves are going yellow."
    }

    private let ariTurnText = "Soil was still wet at Tuesday's check-in. I'd hold off watering for a week and check again."

    // MARK: - Screen 03 · Reminder

    private var reminderChargeDate: Date? {
        premium.trialChargeDate(for: offerPlan)
    }

    private var reminderDate: Date? {
        premium.trialReminderDate(for: offerPlan, from: .now, hour: reminderHour)
    }

    private var reminderHeadline: String {
        "You'll get a reminder before your free trial ends"
    }

    private var reminderButtonTitle: String {
        switch notifications.authorization {
        case .notDetermined, .unknown: "Allow notifications"
        default: "Continue to plans"
        }
    }

    private var reminderStep: some View {
        stepScroll {
            VStack(alignment: .leading, spacing: 24) {
                Text(reminderHeadline)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                bellGraphic

                notificationPreview

                if notifications.authorization == .denied {
                    Text(deniedCaption)
                        .font(.footnote)
                        .foregroundStyle(GroveTheme.ink.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
            }
        } footer: {
            footerContainer {
                statusMessages
                catalogueNotice
                if showsTrial {
                    checkLine("Nothing to pay today")
                }
                primaryButton(
                    title: reminderButtonTitle,
                    enabled: true
                ) {
                    Task { await reminderPrimaryAction() }
                }
                if let line = priceLine(for: offerPlan) {
                    priceCaption(line)
                }
                exitLink
                legalRow(restoreFirst: false, restoreTitle: "Restore")
            }
        }
    }

    private var bellGraphic: some View {
        ZStack(alignment: .topTrailing) {
            Image("TrialReminderBell")
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .accessibilityHidden(true)

            Text("1")
                .font(.headline.weight(.bold))
                .foregroundStyle(GroveTheme.mapGround)
                .frame(width: 36, height: 36)
                .background(Circle().fill(GroveTheme.mapThriving))
                .overlay {
                    Circle().stroke(GroveTheme.mapGround, lineWidth: 2)
                }
                .offset(x: 6, y: -6)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var notificationPreview: some View {
        if let chargeDate = reminderChargeDate {
            let copy = GroveReminderCopy.forTrialEnding(on: chargeDate)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image("GroveAppIconPreview")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("GROVE AI")
                                .font(.caption2.weight(.semibold))
                                .tracking(0.4)
                                .foregroundStyle(GroveTheme.mapCaption)
                            Spacer(minLength: 0)
                            Text("now")
                                .font(.caption2)
                                .foregroundStyle(GroveTheme.mapCaption)
                        }
                        Text(copy.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GroveTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let reminderDate {
                            Text("\(dateText(reminderDate)) · if notifications are on")
                                .font(.caption)
                                .foregroundStyle(GroveTheme.ink.opacity(0.75))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GroveTheme.ink.opacity(0.08),
                in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                    .stroke(GroveTheme.ink.opacity(0.12), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Notification preview: \(copy.title)")
        }
    }

    private var deniedCaption: String {
        if let chargeDate = reminderChargeDate {
            return "Notifications are off. No reminder will be sent before \(dateText(chargeDate))."
        }
        if let reminderDate {
            return "Notifications are off for Grove, so add a reminder to your calendar for \(dateText(reminderDate))."
        }
        return "Notifications are off for Grove, so add a reminder to your calendar."
    }

    private func reminderPrimaryAction() async {
        switch notifications.authorization {
        case .notDetermined, .unknown:
            isWorking = true
            await GroveTrialPurchase.armTrialReminder(notifications: notifications)
            isWorking = false
        default:
            break
        }
        advance()
    }

    // MARK: - Screen 04 · Timeline

    private var timelineHeadline: String {
        if selectedPlanHasTrial, let days = premium.freeTrialDays(for: selectedPlan) {
            return "Start your \(days)-day free trial of Premium."
        }
        return "Choose your Premium plan."
    }

    /// The trial timeline belongs to the plan actually selected, not to the
    /// yearly plan the copy was written for. Picking a plan without a trial
    /// must drop both the trial headline and the timeline rather than describe
    /// a free week the CTA is not selling.
    private var selectedPlanHasTrial: Bool {
        !premium.hasPremium && premium.freeTrialDays(for: selectedPlan) != nil
    }

    private struct TrialTimeline {
        let days: Int
        let reminderDate: Date?
        let chargeDate: Date
        let price: String
    }

    private var trialTimeline: TrialTimeline? {
        guard selectedPlanHasTrial,
              let days = premium.freeTrialDays(for: selectedPlan),
              let chargeDate = premium.trialChargeDate(for: selectedPlan),
              let price = premium.displayPrice(for: selectedPlan) else { return nil }
        return TrialTimeline(
            days: days,
            reminderDate: premium.trialReminderDate(
                for: selectedPlan,
                from: .now,
                hour: reminderHour
            ),
            chargeDate: chargeDate,
            price: price
        )
    }

    private var timelineStep: some View {
        stepScroll {
            VStack(alignment: .leading, spacing: isCompactHeight ? 18 : 22) {
                Text(timelineHeadline)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                planCards

                if let timeline = trialTimeline {
                    timelineView(timeline)
                }
            }
        } footer: {
            timelineFooter
        }
    }

    private func timelineView(_ timeline: TrialTimeline) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            timelineRow(
                symbol: "lock.open.fill",
                title: "Today",
                text: "Ask Ari up to \(AskSession.premiumAsksPerDay) questions a day, share with as many friends as you like, and add \(AvatarView.premiumImageNames.count) mascots.",
                isLast: false
            )
            if let reminderDate = timeline.reminderDate {
                timelineRow(
                    symbol: "bell.fill",
                    title: "\(dateText(reminderDate)) · Reminder",
                    text: "You'll get a notification that your trial ends tomorrow, if notifications are on.",
                    isLast: false
                )
            }
            timelineRow(
                symbol: "creditcard.fill",
                title: "\(dateText(timeline.chargeDate)) · Billing starts",
                text: "You'll be charged \(timeline.price) on \(dateText(timeline.chargeDate)) unless you cancel at least 24 hours before.",
                isLast: true
            )
        }
        .padding(isCompactHeight ? 14 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GroveTheme.ink.opacity(0.06),
            in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
        )
    }

    private func timelineRow(
        symbol: String,
        title: String,
        text: String,
        isLast: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(GroveTheme.mapThriving)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(GroveTheme.ink.opacity(0.08))
                    )
                    .accessibilityHidden(true)

                if !isLast {
                    Rectangle()
                        .fill(GroveTheme.ink.opacity(0.2))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.ink)
                Text(text)
                    .font(.body)
                    .foregroundStyle(GroveTheme.ink.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : (isCompactHeight ? 12 : 18))
        }
        .accessibilityElement(children: .combine)
    }

    private var planCards: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    planCard(.monthly)
                    planCard(.yearly)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    planCard(.monthly)
                    planCard(.yearly)
                }
            }
        }
    }

    private func planCard(_ plan: GrovePremiumStore.Plan) -> some View {
        let selected = selectedPlan == plan
        let shape = RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)

        return Button {
            Haptics.selection()
            selectedPlan = plan
            failure = nil
            restoreMessage = nil
            OnboardingAnalytics.paywallAction("plan_selected", plan: plan)
        } label: {
            planCardContents(plan)
                .background(selected ? GroveTheme.surface : Color.clear, in: shape)
                .environment(\.colorScheme, selected ? .light : .dark)
                .overlay {
                    if !selected {
                        shape.stroke(GroveTheme.ink.opacity(0.25), lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.985, haptics: false))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("groveTrialPlan.\(plan.rawValue)")
    }

    private func planCardContents(_ plan: GrovePremiumStore.Plan) -> some View {
        let isSelected = selectedPlan == plan
        return VStack(alignment: .leading, spacing: 6) {
            Text(plan == .yearly ? "Yearly" : "Monthly")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(premium.displayPrice(for: plan) ?? "—")
                    .font(isSelected ? .title.weight(.bold) : .title2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(GroveTheme.ink)
                Text(plan == .yearly ? "/yr" : "/mo")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            if let detail = planDetail(plan) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !premium.hasPremium, plan == .yearly, let days = premium.freeTrialDays(for: plan) {
                Text("\(days) \(days == 1 ? "day" : "days") free")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroveTheme.accentStrong)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(GroveTheme.softAccent, in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
    }

    private func planDetail(_ plan: GrovePremiumStore.Plan) -> String? {
        if plan == .yearly {
            var parts: [String] = []
            if let monthly = premium.monthlyEquivalentPrice(for: plan) {
                parts.append("\(monthly)/mo")
            }
            if let savings = savingsText {
                parts.append(savings)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        if !premium.hasPremium, let days = premium.freeTrialDays(for: plan) {
            return "\(days) \(days == 1 ? "day" : "days") free"
        }
        return "No free trial"
    }

    private var savingsText: String? {
        guard let label = premium.yearlySavingsLabel, let first = label.first else { return nil }
        return String(first).lowercased() + String(label.dropFirst())
    }

    private var timelineButtonTitle: String {
        if premium.hasPremium { return "Continue with Premium" }
        if !premium.didLoadCatalogue { return "Checking the App Store…" }
        if !isPurchasable { return "Unavailable" }
        if let days = premium.freeTrialDays(for: selectedPlan) {
            return "Start my \(days)-day free trial"
        }
        return PremiumTerms.subscribeTitle(premium, plan: selectedPlan)
    }

    private var selectedCheckLine: String? {
        if !premium.hasPremium, premium.freeTrialDays(for: selectedPlan) != nil {
            return "Nothing to pay today"
        }
        if let price = premium.displayPrice(for: selectedPlan) {
            return "\(price) charged today"
        }
        return nil
    }

    private var renewalNote: String? {
        guard !premium.hasPremium, isPurchasable else { return nil }
        return PremiumTerms.renewalNote(premium, plan: selectedPlan)
    }

    private var timelineFooter: some View {
        footerContainer {
            statusMessages
            catalogueNotice
            if let line = selectedCheckLine {
                checkLine(line)
            }
            primaryButton(
                title: timelineButtonTitle,
                enabled: canPurchase
            ) {
                Task { await purchaseSelectedPlan() }
            }
            if let renewalNote {
                Text(renewalNote)
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.ink.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity)
            }
            exitLink
            legalRow(restoreFirst: true, restoreTitle: "Restore purchases")
        }
    }

    private func purchaseSelectedPlan() async {
        failure = nil
        restoreMessage = nil
        if premium.hasPremium {
            onFinish()
            return
        }
        guard isPurchasable else { return }

        isWorking = true
        defer { isWorking = false }

        let startsTrial = premium.freeTrialDays(for: selectedPlan) != nil
        switch await GroveTrialPurchase.start(
            premium: premium,
            notifications: notifications,
            plan: selectedPlan,
            startsTrial: startsTrial
        ) {
        case .unlocked:
            onFinish()
        case .pending:
            restoreMessage = PremiumTerms.pendingMessage
        case .cancelled:
            break
        case .unavailable:
            failure = PremiumTerms.unavailableMessage
        case .failed(let message):
            failure = message
        }
    }

    // MARK: - Screen 05 · Before you go

    private var beforeYouGoHeadline: AttributedString {
        var headline = AttributedString("Why not ")
        headline.foregroundColor = GroveTheme.ink
        var premiumWord = AttributedString("Premium")
        premiumWord.foregroundColor = GroveTheme.mapThriving
        headline.append(premiumWord)
        var tail = AttributedString(" today?")
        tail.foregroundColor = GroveTheme.ink
        headline.append(tail)
        return headline
    }

    private var beforeYouGoStep: some View {
        stepScroll {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Before you go")
                        .font(.caption.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(GroveTheme.mapCaption)
                    Text(beforeYouGoHeadline)
                        .font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }

                answerChoices

                Text("Your answer just helps us improve Grove. It won't change the price.")
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.ink.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            footerContainer {
                primaryButton(title: "Continue", enabled: true) {
                    if let declineReason {
                        OnboardingAnalytics.paywallDeclineReason(declineReason.analyticsKey)
                    }
                    onFinish()
                }
                exitLink
            }
        }
    }

    @ViewBuilder
    private var answerChoices: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                answerList
            } else {
                ViewThatFits(in: .horizontal) {
                    answerRing
                    answerList
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var answerRing: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                answerChip(.price, compact: true)
                answerChip(.unsureAri, compact: true)
            }
            plantCircle(size: 140)
            HStack(spacing: 12) {
                answerChip(.browsing, compact: true)
                answerChip(.other, compact: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var answerList: some View {
        VStack(spacing: 14) {
            plantCircle(size: 140)
            VStack(spacing: 10) {
                ForEach(GroveTrialDeclineReason.allCases, id: \.self) { reason in
                    answerChip(reason, compact: false)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func answerChip(_ reason: GroveTrialDeclineReason, compact: Bool) -> some View {
        let selected = declineReason == reason

        return Button {
            Haptics.selection()
            declineReason = selected ? nil : reason
        } label: {
            Text(reason.title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(compact ? 2 : nil)
                .minimumScaleFactor(compact ? 0.7 : 1)
                .foregroundStyle(selected ? GroveTheme.mapGround : GroveTheme.ink)
                .padding(.horizontal, compact ? 12 : 18)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    if selected {
                        Capsule().fill(GroveTheme.ink)
                    } else {
                        Capsule().fill(GroveTheme.mapGround)
                        Capsule().stroke(GroveTheme.ink.opacity(0.35), lineWidth: 1.5)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.97, haptics: false))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func plantCircle(size: CGFloat) -> some View {
        Group {
            if let image = plantImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                GroveTheme.softAccent
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(GroveTheme.ink.opacity(0.25), lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }

    private func plantPhoto(size: CGFloat) -> some View {
        Group {
            if let image = plantImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                GroveTheme.softAccent
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
    }

    // MARK: - Shared pieces

    private var statusMessages: some View {
        Group {
            if let failure {
                message(failure, colour: GroveTheme.danger)
            } else if let restoreMessage {
                message(restoreMessage, colour: GroveTheme.ink.opacity(0.75))
            }
        }
    }

    @ViewBuilder
    private var catalogueNotice: some View {
        if !premium.didLoadCatalogue {
            message(PremiumTerms.loadingMessage, colour: GroveTheme.ink.opacity(0.8))
        } else if isEmptyCatalogue {
            message(PremiumTerms.notAvailableMessage, colour: GroveTheme.ink.opacity(0.85))
        }
    }

    private func message(_ text: String, colour: Color) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(colour)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    private func checkLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(GroveTheme.mapThriving)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GroveTheme.ink.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func priceCaption(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(GroveTheme.mapCaption)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    private func priceLine(for plan: GrovePremiumStore.Plan) -> String? {
        guard let price = premium.displayPrice(for: plan) else { return nil }
        let period = PremiumTerms.periodWord(plan)

        if !premium.hasPremium, let days = premium.freeTrialDays(for: plan) {
            let dayWord = days == 1 ? "day" : "days"
            if plan == .yearly, let monthly = premium.monthlyEquivalentPrice(for: plan) {
                return "\(days) \(dayWord) free, then \(price) \(period) (\(monthly)/mo)"
            }
            return "\(days) \(dayWord) free, then \(price) \(period)"
        }

        if plan == .yearly, let monthly = premium.monthlyEquivalentPrice(for: plan) {
            return "\(price) \(period) (\(monthly)/mo)"
        }
        return "\(price) \(period)"
    }

    private var exitLink: some View {
        Button(PremiumTerms.notNowTitle) {
            OnboardingAnalytics.paywallAction("skipped")
            exitFlow()
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(GroveTheme.ink.opacity(0.8))
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        .disabled(isWorking)
        .accessibilityIdentifier("groveTrialSkip")
    }

    private func primaryButton(
        title: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
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
            .background(Capsule().fill(GroveTheme.ink))
            .contentShape(Capsule())
        }
        .buttonStyle(GrovePressStyle())
        .disabled(!enabled || isWorking)
        .opacity((!enabled || isWorking) ? 0.55 : 1)
        .accessibilityIdentifier("groveTrialPrimary")
    }

    private func legalRow(restoreFirst: Bool, restoreTitle: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                if restoreFirst {
                    restoreLink(title: restoreTitle)
                    separatorDot
                }
                termsLink
                separatorDot
                privacyLink
                if !restoreFirst {
                    separatorDot
                    restoreLink(title: restoreTitle)
                }
            }
            VStack(spacing: 4) {
                if restoreFirst {
                    restoreLink(title: restoreTitle)
                }
                termsLink
                privacyLink
                if !restoreFirst {
                    restoreLink(title: restoreTitle)
                }
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(GroveTheme.ink.opacity(0.7))
        .tint(GroveTheme.ink.opacity(0.7))
        .frame(maxWidth: .infinity)
    }

    private var termsLink: some View {
        Link("Terms", destination: OnboardingLegal.termsURL)
            .frame(minHeight: 44)
    }

    private var privacyLink: some View {
        Link("Privacy", destination: OnboardingLegal.privacyURL)
            .frame(minHeight: 44)
    }

    private var separatorDot: some View {
        Text("·")
            .accessibilityHidden(true)
    }

    private func restoreLink(title: String) -> some View {
        Button(title) {
            Task { await restorePurchases() }
        }
        .frame(minHeight: 44)
        .disabled(isWorking)
    }

    private func restorePurchases() async {
        failure = nil
        restoreMessage = nil
        isWorking = true
        let outcome = await GroveTrialPurchase.restore(premium: premium)
        isWorking = false

        switch outcome {
        case .restored:
            onFinish()
        case .notFound:
            restoreMessage = PremiumTerms.restoreNotFoundMessage
        case .failed(let message):
            failure = message
        }
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide))
    }
}

/// The steps this flow may take. Kept apart from the view so the routing can be
/// tested without a store, a notification service or a rendered screen.
enum GroveTrialFlowRoute {
    enum Exit: Equatable {
        case beforeYouGo
        case finish
    }

    static func steps(hasTrial: Bool) -> [GroveTrialFlowView.Step] {
        hasTrial ? [.tryFree, .reminder, .timeline] : [.tryFree, .timeline]
    }

    static func advance(
        from step: GroveTrialFlowView.Step,
        hasTrial: Bool
    ) -> GroveTrialFlowView.Step? {
        switch step {
        case .tryFree:
            return hasTrial ? .reminder : .timeline
        case .reminder:
            return .timeline
        case .timeline, .beforeYouGo:
            return nil
        }
    }

    static func back(
        from step: GroveTrialFlowView.Step,
        hasTrial: Bool
    ) -> GroveTrialFlowView.Step? {
        switch step {
        case .tryFree, .beforeYouGo:
            return nil
        case .reminder:
            return .tryFree
        case .timeline:
            return hasTrial ? .reminder : .tryFree
        }
    }

    /// The exit link goes to the decline screen once. Everything after that —
    /// including the decline screen's own buttons — finishes the flow, and no
    /// path from the decline screen leads back to a purchase.
    static func exit(
        from step: GroveTrialFlowView.Step,
        hasVisitedBeforeYouGo: Bool
    ) -> Exit {
        guard step != .beforeYouGo, !hasVisitedBeforeYouGo else { return .finish }
        return .beforeYouGo
    }
}

/// The decline reasons recorded on the way out. Recording is the only effect:
/// no reason ever changes a price or reopens a purchase step.
enum GroveTrialDeclineReason: String, CaseIterable, Hashable {
    case price
    case unsureAri
    case browsing
    case other

    var title: String {
        switch self {
        case .price: "The price"
        case .unsureAri: "I'm not sure I'd use Ari"
        case .browsing: "I'm just looking round"
        case .other: "Something else"
        }
    }

    /// Stable wire values, so a later copy change cannot break a dashboard.
    var analyticsKey: String {
        switch self {
        case .price: "price"
        case .unsureAri: "unsure_ari"
        case .browsing: "browsing"
        case .other: "other"
        }
    }
}

/// The purchase and restore path shared by the existing offer and the trial
/// flow, so both record the same events, celebrate the same way and arm the
/// same trial reminder.
@MainActor
enum GroveTrialPurchase {
    enum PurchaseResult: Equatable {
        case unlocked
        case pending
        case cancelled
        case unavailable
        case failed(String)
    }

    enum RestoreResult: Equatable {
        case restored
        case notFound
        case failed(String)
    }

    /// The permission ask a trial start is allowed to make. Only while the
    /// answer is still open: re-asking a denied user does nothing but lose a
    /// launch to a dialog iOS will not show.
    static func armTrialReminder(notifications: NotificationService) async {
        await notifications.refreshAuthorization()
        guard notifications.authorization == .notDetermined else { return }
        await notifications.requestAuthorization()
        OnboardingAnalytics.notificationsDecision(
            .system(authorization: notifications.authorization)
        )
    }

    static func start(
        premium: GrovePremiumStore,
        notifications: NotificationService,
        plan: GrovePremiumStore.Plan,
        startsTrial: Bool
    ) async -> PurchaseResult {
        OnboardingAnalytics.paywallAction("purchase_started", plan: plan)
        switch await premium.purchase(plan) {
        case .unlocked:
            Haptics.celebrate()
            OnboardingAnalytics.paywallAction("purchase_completed", plan: plan)
            if startsTrial {
                await armTrialReminder(notifications: notifications)
            }
            return .unlocked
        case .pending:
            OnboardingAnalytics.paywallAction("purchase_pending", plan: plan)
            return .pending
        case .cancelled:
            OnboardingAnalytics.paywallAction("purchase_cancelled", plan: plan)
            return .cancelled
        case .unavailable:
            OnboardingAnalytics.paywallAction("purchase_unavailable", plan: plan)
            return .unavailable
        case .failed(let message):
            OnboardingAnalytics.paywallAction("purchase_failed", plan: plan)
            return .failed(message)
        }
    }

    static func restore(premium: GrovePremiumStore) async -> RestoreResult {
        switch await premium.restorePurchases() {
        case .restored:
            Haptics.celebrate()
            OnboardingAnalytics.paywallAction("restored")
            return .restored
        case .notFound:
            OnboardingAnalytics.paywallAction("restore_not_found")
            return .notFound
        case .failed(let message):
            OnboardingAnalytics.paywallAction("restore_failed")
            return .failed(message)
        }
    }
}
