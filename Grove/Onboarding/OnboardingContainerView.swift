import SwiftUI

/// Root of the signed-out experience. Owns the `OnboardingModel` and renders
/// the current step. Successful authentication establishes the session, then
/// `RootView` swaps directly to the signed-in app's Today tab.
struct OnboardingContainerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SessionService.self) private var session
    @State private var model = OnboardingModel()

    var body: some View {
        Group {
            switch model.step {
            case .welcome:
                OnboardingWelcomeView(model: model)
            case .explore:
                OnboardingExploreView(model: model)
            case .firstPlantScan:
                OnboardingFirstPlantScanView(model: model)
            case .firstPlantDetails:
                OnboardingFirstPlantResultView(model: model)
            case .firstPlantRoom:
                OnboardingRoomStepView(model: model)
            case .signIn:
                OnboardingSignInView(model: model)
            case .accountNotFound:
                OnboardingAccountNotFoundView(model: model)
            case .emailEntry:
                OnboardingEmailEntryView(model: model)
            case .emailVerification:
                OnboardingVerificationView(model: model)
            case .name:
                OnboardingNameStepView(model: model)
            case .experience:
                experienceStep
            case .collectionSize:
                environmentStep
            case .environment:
                environmentStep
            case .overcome:
                challengeStep
            case .challenge:
                challengeStep
            case .location:
                OnboardingHomeStepView(model: model)
            case .planReveal:
                completionStep
            // Retired from the funnel. The Premium offer now waits until the
            // person has an account, a saved plant, and a session of real use
            // behind them; `GrovePremiumOfferPresenter` owns it from there.
            case .buildingPlan, .notifications, .paywall:
                EmptyView()
            }
        }
        .transition(stepTransition)
        // Every first-run page is a photograph under a light sheet, including
        // the account screen. The capture step is the one dark, full-bleed
        // scene: the scan screen draws its own black viewfinder, and because
        // `preferredColorScheme` is a presentation-level preference the
        // wrapper's value is the one the window resolves — so it has to say
        // `.dark` here rather than leave the inline camera under a light status
        // bar and light system sheets.
        .preferredColorScheme(model.step == .firstPlantScan ? .dark : .light)
        .onChange(of: reduceMotion, initial: true) { _, enabled in
            model.prefersReducedMotion = enabled
        }
        .onChange(of: model.step, initial: true) { previous, current in
            OnboardingAnalytics.stepViewed(current, route: model.route)
            // A sign-in failure belongs to the screen that produced it. It used
            // to be cleared only by the next *success*, so "no grove for that
            // email" followed the user back to the welcome screen and reappeared
            // under "Save your plan" on the new-account route — an error about
            // something they were no longer doing.
            guard previous != current else { return }
            if current == .welcome {
                session.cancelPendingAuthentication()
            } else if current == .signIn {
                // A completion failure deliberately returns here with its error;
                // every ordinary route/provider reset starts clean.
                session.cancelPendingAuthentication(clearError: previous != .planReveal)
            } else {
                session.signInError = nil
            }
        }
        .task(id: model.step) {
            await validatePendingFirstPlantIfNeeded()
        }
    }

    /// The invisible last step for a funnel that already holds a credential, so
    /// there is nothing left to ask. Two routes reach it: the debug UI-test path
    /// (provider sheets are out of process and cannot be automated) and someone
    /// who signed in through "I already have a Grove" and turned out to be new.
    /// Nothing from the retired reveal page is drawn — the session is established
    /// immediately and the root opens Today.
    private var completionStep: some View {
        ZStack {
            OnboardingBackground()
            // The token exchange can take a few seconds. An empty garden for
            // that long read as a hang, so the wait says what it is doing.
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(OnboardingTheme.ink)
                Text("Making your account…")
                    .font(.headline)
                    .foregroundStyle(OnboardingTheme.mutedInk)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Making your account")
        }
        .task {
            guard let method = model.authMethod else {
                model.back()
                return
            }
            if !(await model.completeSignup(using: session, method: method)),
               model.step == .planReveal {
                model.recoverFromCompletionFailure()
            }
        }
    }

    /// An account gate is only honest while the baseline it promises to save is
    /// still durable. External storage clearing or a damaged manifest sends the
    /// person back to capture instead of completing an empty account under
    /// first-plant copy.
    private func validatePendingFirstPlantIfNeeded() async {
        guard model.route == .newAccount else { return }
        switch model.step {
        case .firstPlantDetails, .firstPlantRoom, .location, .signIn, .emailEntry, .emailVerification, .planReveal:
            do {
                guard try await PendingFirstPlantStore.shared.loadUnclaimed() != nil else {
                    model.recoverMissingFirstPlant()
                    return
                }
            } catch {
                model.recoverMissingFirstPlant()
            }
        default:
            break
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .identity }

        switch model.navigationDirection {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .backward:
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }

    // MARK: - Quiz steps
    //
    // Every option below is rendered from `GrovePlanCatalog`, which is also
    // what the editable plan screen in My Grove renders and what a stored
    // `GrovePlan` resolves its IDs against. Keeping one catalogue means a
    // reworded answer changes in both places at once, and an ID can never
    // drift out from under a plan a user already saved.

    private var experienceStep: some View {
        OnboardingSingleChoiceStep(
            model: model,
            progress: (1, 3),
            eyebrow: "A quick setup",
            title: "Where are you starting from?",
            subtitle: "This sets how much Grove explains.",
            options: OnboardingOption.from(GrovePlanCatalog.experience),
            selection: model.experience
        ) { model.experience = $0 }
    }

    private var environmentStep: some View {
        OnboardingSingleChoiceStep(
            model: model,
            progress: (2, 3),
            eyebrow: environmentEyebrow,
            title: "Where do your plants live?",
            subtitle: "Indoors and outdoors need different care.",
            options: OnboardingOption.from(GrovePlanCatalog.environment),
            selection: model.environment
        ) { model.environment = $0 }
    }

    private var challengeStep: some View {
        OnboardingSingleChoiceStep(
            model: model,
            progress: (3, 3),
            eyebrow: challengeEyebrow,
            title: "What should Grove help with first?",
            subtitle: "Your plan will start here.",
            options: OnboardingOption.from(GrovePlanCatalog.challenge),
            selection: model.challenge
        ) { model.challenge = $0 }
    }

    // Each step's eyebrow answers the previous step, the way "Nice to meet
    // you" answers the name. One line, in the answer's own words where
    // possible, so the quiz reads as a conversation rather than a form.

    private var environmentEyebrow: String? {
        switch model.experience {
        case "new": "Everyone starts there."
        case "hobbyist": "We'll keep it practical."
        case "experienced": "We'll skip the basics."
        default: nil
        }
    }

    private var challengeEyebrow: String? {
        switch model.environment {
        case "indoor": "Indoors it is."
        case "outdoor": "Outdoors it is."
        case "both": "Inside and out, then."
        default: nil
        }
    }
}

private extension OnboardingOption {
    static func from(_ choices: [GrovePlanCatalog.Choice]) -> [OnboardingOption] {
        choices.map {
            OnboardingOption(
                id: $0.id,
                title: $0.title,
                detail: $0.detail,
                artworkName: $0.onboardingArtworkName,
                systemImage: $0.symbol
            )
        }
    }
}

private extension GrovePlanCatalog.Choice {
    var onboardingArtworkName: String? {
        switch id {
        case "new":
            "OnboardingChoiceExperienceBeginner"
        case "hobbyist":
            "OnboardingChoiceExperienceLearning"
        case "experienced":
            "OnboardingChoiceExperienceExpert"
        case "indoor":
            "OnboardingChoiceEnvironmentIndoor"
        case "outdoor":
            "OnboardingChoiceEnvironmentOutdoor"
        case "both":
            "OnboardingChoiceEnvironmentBoth"
        case "watering":
            "OnboardingChoiceChallengeWatering"
        case "light":
            "OnboardingChoiceChallengeLight"
        case "pests":
            "OnboardingChoiceChallengePests"
        case "id":
            "OnboardingChoiceChallengeIdentification"
        default:
            nil
        }
    }
}
