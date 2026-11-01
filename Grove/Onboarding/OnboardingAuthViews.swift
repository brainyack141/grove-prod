import AuthenticationServices
import Accessibility
import SwiftUI

/// Where an account is actually made.
///
/// On the new-account route this sits after the user's own plant result; on the
/// manual route it follows the feature preview. Either way, signing in
/// protects something the person already made rather than charging an entry
/// toll. On the returning route a provider tap restores the existing grove.
struct OnboardingSignInView: View {
    @Environment(SessionService.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let model: OnboardingModel
    @State private var isWorking = false
    @State private var authTask: Task<Void, Never>?
    /// Which provider the pending attempt went out to, for the stalled-sign-in
    /// copy. Distinct from `model.authMethod`, which is only stamped on success.
    @State private var workingMethod: OnboardingAuthMethod?
    /// True once a sign-in has been in flight long enough that something is
    /// probably wrong. Reveals the cancel affordance; never blocks completion.
    @State private var showsStalledEscape = false
    @State private var firstPlant: OnboardingFirstPlantPresentation?
    @State private var showsPlantPhoto = false

    private let controlHeight: CGFloat = OnboardingTheme.controlHeight

    private var isReturning: Bool { model.route == .returning }
    private var isValueFirst: Bool { model.route == .newAccount }

    var body: some View {
        Group {
            if isValueFirst {
                saveYourPlant
            } else {
                photoSheetLayout
            }
        }
        .onDisappear {
            authTask?.cancel()
            authTask = nil
        }
        .task {
            guard isValueFirst else { return }
            firstPlant = await OnboardingFirstPlantPresentation.load()
        }
        // A provider sheet that never resumes used to leave this screen fully
        // disabled with no way out — the launch-coloured backdrop and dimmed
        // buttons read as a hung splash screen, and the only exit was force
        // quitting the app. Ten seconds covers every healthy exchange; while
        // Google's or Apple's own sheet is up it covers this screen anyway, so
        // the affordance only ever meets eyes when the wait has genuinely
        // stalled.
        .task(id: isWorking) {
            showsStalledEscape = false
            guard isWorking else { return }
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, isWorking else { return }
            showsStalledEscape = true
        }
    }

    /// The new-account gate in first run's own voice: the plant the account
    /// will keep, in its own photo with Sprout beside it, and the ways in.
    private var saveYourPlant: some View {
        OnboardingSproutPage(step: 4, isBackEnabled: !isWorking, onBack: model.backFromAccountGate) {
            VStack(alignment: .leading, spacing: 22) {
                OnboardingQuestionTitle(
                    lead: "",
                    accent: "Save",
                    trail: " your \(savedPlantNoun).",
                    subtitle: "An account keeps its photos and check-ins safe, on any iPhone."
                )
                OnboardingPlantCard(
                    plant: firstPlant,
                    detail: firstPlant.map { "Day 1 · first check-in \($0.firstCheckInDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))" },
                    room: firstPlant?.assignedRoom.flatMap(OnboardingRoom.init(rawValue:)),
                    home: model.location?.townName
                )
                .onTapGesture { if firstPlant?.image != nil { showsPlantPhoto = true } }
                .sheet(isPresented: $showsPlantPhoto) { plantPhotoSheet }
                SproutImage(pose: .happy, size: 150)
                    .frame(maxWidth: .infinity)

                if let error = session.signInError {
                    OnboardingAuthErrorMessage(message: error)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            GroveTheme.surface,
                            in: RoundedRectangle(cornerRadius: OnboardingTheme.rowRadius, style: .continuous)
                        )
                }
            }
        } footer: {
            VStack(spacing: 12) {
                if showsStalledEscape { stalledEscape }
                footer
            }
            .animation(.easeOut(duration: 0.25), value: showsStalledEscape)
        }
    }

    /// What follows "Save your". An unknown species presents itself as "your
    /// plant", which read as "Save your your plant." here.
    private var savedPlantNoun: String {
        guard let firstPlant, !firstPlant.isUnknownIdentity else { return "plant" }
        return firstPlant.displayName
    }

    private var plantPhotoSheet: some View {
        NavigationStack {
            Group {
                if let image = firstPlant?.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("Your original plant photo")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GroveTheme.mapGround)
            .navigationTitle("Your plant photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsPlantPhoto = false }
                }
            }
        }
    }

    /// Returning sign-in and the no-plant route: Sprout says hello and the
    /// providers wait underneath. No step count, because neither route walks
    /// the counted questions.
    private var photoSheetLayout: some View {
        OnboardingSproutPage(step: nil, isBackEnabled: !isWorking, onBack: model.backFromAccountGate) {
            VStack(alignment: .leading, spacing: 22) {
                if isReturning {
                    OnboardingQuestionTitle(lead: "Welcome ", accent: "back", trail: ".", subtitle: "Sign in to open your grove.")
                } else {
                    OnboardingQuestionTitle(lead: "Make your ", accent: "account", trail: ".", subtitle: "Add your first plant when you’re next to one.")
                }
                SproutImage(pose: isReturning ? .happy : .idle, size: 170)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                if let error = session.signInError {
                    OnboardingAuthErrorMessage(message: error)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            GroveTheme.surface,
                            in: RoundedRectangle(cornerRadius: OnboardingTheme.rowRadius, style: .continuous)
                        )
                }
            }
        } footer: {
            VStack(spacing: 12) {
                if showsStalledEscape { stalledEscape }
                footer
            }
            .animation(.easeOut(duration: 0.25), value: showsStalledEscape)
        }
    }

    /// The way out of a sign-in that has stopped answering. Deliberately not a
    /// timeout: cancelling is the person's call, because only they can see
    /// whether they are still mid-password in a provider sheet.
    private var stalledEscape: some View {
        HStack(spacing: 6) {
            Text("Still waiting on \(workingProviderName).")
                .foregroundStyle(OnboardingTheme.mutedInk)
            Button("Cancel sign-in") { cancelStalledSignIn() }
                .fontWeight(.semibold)
                .foregroundStyle(OnboardingTheme.ink)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var workingProviderName: String {
        switch workingMethod {
        case .apple: "Apple"
        case .google: "Google"
        case .email: "your email"
        case .device, .none: "sign-in"
        }
    }

    private func cancelStalledSignIn() {
        OnboardingAnalytics.authStalled(workingMethod ?? .device)
        authTask?.cancel()
        authTask = nil
        session.cancelPendingAuthentication()
        isWorking = false
    }

    /// The plant the account is about to keep, named, with its full photo a
    /// tap away (the hero above is cropped).
    private var plantSummary: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Your first plant".uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(OnboardingTheme.subtleInk)
                Text(firstPlant?.identityLine ?? "Your first plant")
                    .font(.headline)
                    .foregroundStyle(OnboardingTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("View photo") {
                showsPlantPhoto = true
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(OnboardingTheme.ink)
            .tint(OnboardingTheme.ink)
            .frame(minHeight: 44)
            .disabled(isWorking || firstPlant?.image == nil)
            .opacity(firstPlant?.image == nil ? 0.4 : 1)
            .accessibilityLabel("View your plant photo")
            .accessibilityIdentifier("accountPlantPhoto")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            OnboardingTheme.base,
            in: RoundedRectangle(cornerRadius: OnboardingTheme.rowRadius, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("accountPlantSummary")
        .sheet(isPresented: $showsPlantPhoto) {
            NavigationStack {
                Group {
                    if let image = firstPlant?.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .accessibilityLabel("Your original plant photo")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(GroveTheme.mapGround)
                .navigationTitle("Your plant photo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsPlantPhoto = false }
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if SessionService.isAccountSignInAvailable {
                appleButton

                if GoogleAuthenticator.isConfigured {
                    OnboardingProviderButton(
                        title: isReturning ? "Sign in with Google" : "Sign up with Google",
                        assetImage: "GoogleG",
                        filled: false
                    ) {
                        OnboardingAnalytics.authChosen(.google)
                        continueWithGoogle()
                    }
                    .accessibilityIdentifier("continueWithGoogle")
                }

                if SessionService.isEmailSignInAvailable {
                    Button(isReturning ? "Sign in with email" : "Sign up with email") {
                        session.cancelPendingAuthentication()
                        OnboardingAnalytics.authChosen(.email)
                        model.startFlow(method: .email)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OnboardingTheme.ink)
                    .tint(OnboardingTheme.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("continueWithEmail")
                }
            } else if isReturning {
                Text("Account sign-in isn't configured in this build.")
                    .font(.footnote)
                    .foregroundStyle(OnboardingTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else if SessionService.isDeviceOnlySignupAvailable {
                // A build with no Supabase project behind it has no service to
                // create an account against, so the funnel falls back to a local
                // grove rather than drawing provider buttons that cannot keep
                // the promise in their labels.
                //
                // This is a build-configuration fallback, not a product choice:
                // a shipping build always has credentials, so this never
                // renders there.
                OnboardingProviderButton(
                    title: isWorking ? "Setting up…" : "Continue without an account",
                    systemImage: "iphone",
                    filled: false
                ) {
                    continueOnThisDevice()
                }
                .accessibilityHint("Creates no account or cloud backup. Signing out cannot be undone.")
                .accessibilityIdentifier("continueOnDevice")

                Text("Account sign-in isn't configured in this build, so this grove stays on this iPhone with no backup.")
                    .font(.caption)
                    .foregroundStyle(OnboardingTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Account sign-in isn't configured correctly in this build. Grove won't create an account without its secure account service.")
                    .font(.footnote)
                    .foregroundStyle(OnboardingTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            #if targetEnvironment(simulator)
            Button("Skip for troubleshooting") {
                session.startSimulatorTroubleshooting()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(OnboardingTheme.ink)
            .accessibilityIdentifier("skipSimulatorTroubleshooting")

            Text("Simulator only · Local sample data")
                .font(.caption)
                .foregroundStyle(OnboardingTheme.mutedInk)
            #endif

            OnboardingLegalFooter()
                .frame(maxWidth: 300)
                .lineSpacing(3)
                .padding(.top, 2)
        }
        .disabled(isWorking)
        .opacity(isWorking ? 0.5 : 1)
    }

    /// Sign in with Apple keeps the filled slot: it is the path most people
    /// take, and Apple's guidelines ask for it to be at least as prominent as
    /// any alternative offered beside it. Each route's provider buttons share
    /// one verb — "Sign up with…" or "Sign in with…" — so the stack reads as
    /// one choice of door, not three unrelated controls.
    private var appleButton: some View {
        SignInWithAppleButton(isReturning ? .signIn : .signUp) { request in
            isWorking = true
            workingMethod = .apple
            session.prepareAppleRequest(request)
        } onCompletion: { result in
            switch session.stashAppleCredential(result) {
            case .accepted:
                OnboardingAnalytics.authChosen(.apple)
                proceed(with: .apple)
            case .failed:
                isWorking = false
            case .stale:
                break
            }
        }
        // Black on the white sheet: Apple's own ink capsule, the filled slot.
        .signInWithAppleButtonStyle(.black)
        // Grow with Dynamic Type like the Google capsule beside it. A fixed
        // box made Apple the smallest control at accessibility sizes and
        // truncated its own (independently scaling) label.
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 72 : controlHeight)
        .clipShape(Capsule())
        .accessibilityIdentifier("signInWithApple")
    }

    /// Google's identity token is minted interactively, so it mirrors Apple:
    /// capture the token, then continue.
    private func continueWithGoogle() {
        guard !isWorking else { return }
        isWorking = true
        workingMethod = .google
        session.cancelPendingAuthentication()
        authTask?.cancel()
        authTask = Task {
            do {
                let credential = try await GoogleAuthenticator.signIn()
                guard !Task.isCancelled else { return }
                session.stashGoogleCredential(
                    userID: credential.userID,
                    idToken: credential.idToken,
                    displayName: credential.displayName
                )
                proceed(with: .google)
            } catch GoogleAuthenticator.GoogleAuthError.cancelled {
                // User backed out — stay on this screen, no error.
                isWorking = false
            } catch {
                // A late failure from an attempt the person already cancelled
                // through the stalled-sign-in escape must not resurrect its
                // error onto a screen they have moved on from.
                guard !Task.isCancelled else { return }
                OnboardingAnalytics.authFailed(.google)
                session.signInError = "Grove couldn't finish signing you in. Try again."
                isWorking = false
            }
        }
    }

    private func continueOnThisDevice() {
        guard !isWorking else { return }
        isWorking = true
        workingMethod = .device
        session.cancelPendingAuthentication()
        OnboardingAnalytics.authChosen(.device)
        authTask?.cancel()
        authTask = Task {
            _ = await model.completeSignup(using: session, method: .device)
            guard !Task.isCancelled else { return }
            isWorking = false
        }
    }

    /// Authentication is the last signup step. A new account is established
    /// with its collected plan and opens Today; a returning account restores
    /// its existing grove — or, if that identity has no account yet, keeps the
    /// session it just proved while Grove clearly offers sign-up.
    private func proceed(with method: OnboardingAuthMethod) {
        isWorking = true
        authTask?.cancel()
        authTask = Task {
            if isReturning {
                await resume(method)
            } else {
                _ = await model.completeSignup(using: session, method: method)
            }
            guard !Task.isCancelled else { return }
            isWorking = false
        }
    }

    @MainActor
    private func resume(_ method: OnboardingAuthMethod) async {
        switch await session.resumeExistingAccount(method: method) {
        case .signedIn:
            // RootView swaps to Today the moment the session lands.
            // Returning sign-in has no later completion sentinel to consume
            // the onboarding draft. Remove it now so a later sign-out cannot
            // restore this person's email or stale setup answers.
            model.clearDraft()
            break
        case .accountNotFound:
            model.offerSignup(method: method)
        case .unreachable:
            // `signInError` is already showing above the buttons.
            break
        }
    }
}

/// The provider credential was valid, but it created a Grove identity rather
/// than finding one. This is a product handoff, not an auth error: it explains
/// exactly what happened and asks before turning the returning route into the
/// sign-up funnel.
struct OnboardingAccountNotFoundView: View {
    @Environment(SessionService.self) private var session
    let model: OnboardingModel

    var body: some View {
        OnboardingSproutPage(step: nil, onBack: useDifferentSignIn) {
            VStack(alignment: .leading, spacing: 22) {
                OnboardingQuestionTitle(
                    lead: "No grove for this ",
                    accent: accountDescription,
                    trail: " yet.",
                    subtitle: "You’re signed in with \(providerName). Create a grove with it, then scan your first plant."
                )
                SproutImage(pose: .idle, size: 150)
                    .frame(maxWidth: .infinity)
            }
        } footer: {
            VStack(spacing: 4) {
                OnboardingPrimaryButton(title: "Create a Grove account") {
                    model.acceptSignupOffer()
                }
                .accessibilityIdentifier("createAccountAfterSignIn")
                OnboardingQuietButton(title: "Use a different sign-in", action: useDifferentSignIn)
                    .accessibilityIdentifier("useDifferentSignIn")
            }
        }
    }

    private var providerName: String {
        switch model.authMethod {
        case .apple: "Apple"
        case .google: "Google"
        case .email: "email"
        case .device, .none: "your provider"
        }
    }

    private var accountDescription: String {
        switch model.authMethod {
        case .email: "email address"
        case .apple, .google, .device, .none: "account"
        }
    }

    private func useDifferentSignIn() {
        session.cancelPendingAuthentication()
        model.useDifferentSignIn()
    }
}

/// The email and code screens. Same canvas, bar and back chevron as every
/// other first-run question; the action stays inline under the field because
/// the keyboard owns the foot of the screen here.
private struct OnboardingSheetScaffold<Content: View>: View {
    var step: Int?
    var isBackEnabled = true
    var onBack: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            OnboardingSegmentBar(step: step, isBackEnabled: isBackEnabled, onBack: onBack)
            ScrollView {
                content()
                    .padding(.horizontal, GroveTheme.pagePadding + 4)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(GroveTheme.background.ignoresSafeArea())
    }
}

/// One presentation for async auth failures. Posting an accessibility
/// announcement matters because these messages appear without moving focus.
private struct OnboardingAuthErrorMessage: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(OnboardingTheme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Error. \(message)")
            .task(id: message) { AccessibilityNotification.Announcement(message).post() }
    }
}

/// Rounded input field used inside the auth sheets.
private struct OnboardingField<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                    .strokeBorder(GroveTheme.separator, lineWidth: 2)
            }
    }
}

/// Email address entry. The code is requested from Supabase Auth before the
/// flow moves on, so the code screen can only be reached when a code was
/// genuinely sent.
struct OnboardingEmailEntryView: View {
    @Environment(SessionService.self) private var session
    @Bindable var model: OnboardingModel
    @FocusState private var focused: Bool
    @State private var isSending = false
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        OnboardingSheetScaffold(step: model.route == .newAccount ? 4 : nil, isBackEnabled: !isSending, onBack: model.back) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingQuestionTitle(
                    lead: "What’s your ",
                    accent: "email",
                    trail: "?",
                    subtitle: model.route == .returning
                        ? "If it has a grove, a 6-digit code will arrive in a minute."
                        : "A 6-digit code will arrive in a minute."
                )

                OnboardingField {
                    TextField("", text: $model.email, prompt: Text("Email").foregroundColor(OnboardingTheme.mutedInk))
                        .foregroundStyle(OnboardingTheme.ink)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .accessibilityIdentifier("onboardingEmailField")
                }

                if let error = session.signInError {
                    OnboardingAuthErrorMessage(message: error)
                }

                OnboardingPrimaryButton(
                    title: isSending ? "Sending…" : "Send verification code",
                    isEnabled: model.canAdvanceFromCurrentStep && !isSending
                ) {
                    send()
                }
                .accessibilityIdentifier("sendVerificationCode")
            }
        }
        .onAppear { focused = true }
        .onChange(of: model.email) { model.persistDraft() }
        .onDisappear {
            sendTask?.cancel()
            sendTask = nil
        }
    }

    private func send() {
        guard !isSending else { return }
        isSending = true
        sendTask?.cancel()
        sendTask = Task {
            // Only advance once a code has actually been sent — the screen used
            // to move on regardless, leading to a code screen that accepted any
            // six digits. The returning route must not create an account for an
            // unknown address; it gets told no grove exists instead.
            let sent = await session.sendEmailCode(
                to: model.normalizedEmail,
                createAccount: model.route == .newAccount
            )
            guard !Task.isCancelled else { return }
            isSending = false
            if sent {
                model.verificationCode = ""
                model.advance()
            }
        }
    }
}

/// 6-digit verification code entry rendered as six discrete boxes, driven by
/// a hidden text field so autofill (`oneTimeCode`) still works. Auto-submits
/// on the sixth digit, and the code is checked against Supabase Auth — it used
/// to accept any six digits and hand out an account.
struct OnboardingVerificationView: View {
    @Environment(SessionService.self) private var session
    @Bindable var model: OnboardingModel
    @FocusState private var focused: Bool
    @State private var isVerifying = false
    @State private var isResending = false
    /// Seconds left before another code may be asked for. Starts full, because
    /// reaching this screen means a code was just sent.
    @State private var secondsUntilResend = 0
    /// Set after a resend actually lands, so the button reports back. Without
    /// it the tap produced no visible change at all — which is what made people
    /// tap it again, and again, until Grove's whole hourly mail budget was gone.
    @State private var didResend = false
    @State private var verificationTask: Task<Void, Never>?
    @State private var resendTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Matches the project's per-address `smtp_max_frequency`. A shorter wait
    /// here would only buy a rejection from Supabase with a raw server sentence
    /// attached.
    private static let resendCooldown = 60

    var body: some View {
        OnboardingSheetScaffold(
            step: model.route == .newAccount ? 4 : nil,
            isBackEnabled: !isVerifying && !isResending,
            onBack: model.back
        ) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingQuestionTitle(
                    lead: "Enter the ",
                    accent: "code",
                    trail: ".",
                    subtitle: "Sent to \(model.normalizedEmail.isEmpty ? "your email" : model.normalizedEmail)."
                )

                codeBoxes

                // The address is printed above so a typo is visible; this is the
                // way to fix it without hunting for the back chevron.
                if !model.normalizedEmail.isEmpty {
                    Button("Wrong address? Change email") { model.back() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(OnboardingTheme.accentStrong)
                        .frame(minHeight: 44)
                        .disabled(isVerifying || isResending)
                        .accessibilityIdentifier("changeEmail")
                }

                // An error outranks the confirmation: if the code was just
                // rejected, "New code sent." underneath it would be answering a
                // question the user is no longer asking.
                if let error = session.signInError {
                    OnboardingAuthErrorMessage(message: error)
                } else if didResend {
                    Label("New code sent.", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(OnboardingTheme.accentStrong)
                        .transition(.opacity)
                }

                resendRow

                OnboardingPrimaryButton(
                    title: isVerifying ? "Verifying…" : "Verify",
                    isEnabled: model.canAdvanceFromCurrentStep && !isVerifying
                ) {
                    verify()
                }
                .accessibilityIdentifier("verifyCode")
            }
        }
        .onAppear {
            focused = true
            // A code landed on the way in, so the wait starts now rather than
            // offering a resend the server would refuse.
            if secondsUntilResend == 0, !didResend { secondsUntilResend = Self.resendCooldown }
        }
        // Each change schedules the next tick, so the countdown needs no timer
        // and stops on its own when the step is left.
        .task(id: secondsUntilResend) {
            guard secondsUntilResend > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            updateWithOptionalAnimation {
                secondsUntilResend -= 1
                // The confirmation lives exactly as long as the wait it
                // explains; past that it is a stale claim about an old code.
                if secondsUntilResend == 0 { didResend = false }
            }
        }
        .onDisappear {
            verificationTask?.cancel()
            resendTask?.cancel()
            verificationTask = nil
            resendTask = nil
        }
    }

    /// Either the wait or the offer — never a button that looks tappable and
    /// isn't.
    @ViewBuilder
    private var resendRow: some View {
        if secondsUntilResend > 0 {
            Text("Resend code in \(countdown)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OnboardingTheme.subtleInk)
                .contentTransition(.numericText(countsDown: true))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Resend code, available in \(secondsUntilResend) seconds")
        } else {
            Button {
                resend()
            } label: {
                Text(isResending ? "Sending…" : "Resend code")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(OnboardingTheme.accentStrong)
            .disabled(isVerifying || isResending)
            .accessibilityIdentifier("resendCode")
        }
    }

    private var countdown: String {
        String(format: "%d:%02d", secondsUntilResend / 60, secondsUntilResend % 60)
    }

    private func resend() {
        guard secondsUntilResend == 0, !isResending else { return }
        isResending = true
        didResend = false
        resendTask?.cancel()
        resendTask = Task {
            let sent = await session.sendEmailCode(
                to: model.normalizedEmail,
                createAccount: model.route == .newAccount
            )
            guard !Task.isCancelled else { return }
            isResending = false
            guard sent else { return }
            // Only a code that actually went out starts the wait; a failed send
            // has an error on screen explaining itself, and locking the button
            // for a minute would strand the user with no way to retry.
            Haptics.tap()
            updateWithOptionalAnimation {
                didResend = true
                secondsUntilResend = Self.resendCooldown
            }
        }
    }

    @ViewBuilder
    private var codeBoxes: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // Six separate visual cells cannot grow to accessibility sizes
            // without running off a phone. At those sizes the real input is
            // visible as one roomy field; regular sizes keep the familiar OTP
            // cells with the same underlying value and autofill behaviour.
            OnboardingField {
                TextField("6-digit code", text: $model.verificationCode)
                    .font(.system(.title2, design: .monospaced, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.ink)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .accessibilityLabel("Six-digit verification code")
                    .accessibilityHint("Enter the code sent to your email address")
                    .accessibilityIdentifier("onboardingCodeField")
                    .onChange(of: model.verificationCode) { _, newValue in
                        handleCodeChange(newValue)
                    }
            }
        } else {
            ZStack {
                HStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { index in
                        digitBox(at: index)
                    }
                }

                // Invisible but hittable field that actually receives input.
                // Stretched over the whole box row so tapping any digit box focuses it.
                TextField("", text: $model.verificationCode)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .contentShape(Rectangle())
                    .opacity(0.02)
                    .accessibilityLabel("Six-digit verification code")
                    .accessibilityHint("Enter the code sent to your email address")
                    .accessibilityValue(model.verificationCode.isEmpty ? "No digits entered" : "\(model.verificationCode.count) of 6 digits entered")
                    .accessibilityIdentifier("onboardingCodeField")
                    .onChange(of: model.verificationCode) { _, newValue in
                        handleCodeChange(newValue)
                    }
            }
        }
    }

    private func handleCodeChange(_ newValue: String) {
        let digits = OnboardingModel.sanitizedVerificationCode(newValue)
        if digits != newValue {
            model.verificationCode = digits
            return
        }
        // Typing means the new code arrived; the notice has been read.
        if didResend, !digits.isEmpty { didResend = false }
        if digits.count == 6 {
            verify()
        }
    }

    private func digitBox(at index: Int) -> some View {
        let digits = Array(model.verificationCode)
        let digit = index < digits.count ? String(digits[index]) : ""
        let isActive = focused && index == min(digits.count, 5)
        return Text(digit)
            .font(.system(.title2, design: .monospaced, weight: .semibold))
            .foregroundStyle(OnboardingTheme.ink)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 58)
            .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                    .strokeBorder(isActive ? GroveTheme.accent : GroveTheme.separator, lineWidth: 2)
            }
            .animation(reduceMotion ? nil : GroveMotion.snap, value: isActive)
            .accessibilityHidden(true)
    }

    private func verify() {
        guard model.canAdvanceFromCurrentStep, !isVerifying else { return }
        isVerifying = true
        verificationTask?.cancel()
        verificationTask = Task {
            let verified = await session.verifyEmailCode(email: model.normalizedEmail, code: model.verificationCode)
            guard !Task.isCancelled else { return }
            guard verified else {
                isVerifying = false
                // Let the user correct a wrong code instead of leaving six
                // rejected digits sitting in the boxes.
                model.verificationCode = ""
                focused = true
                return
            }
            // Verification is the last step for both routes. The button stays
            // disabled while the session opens rather than inviting a second
            // tap.
            if model.route == .returning {
                // A verified address with no account behind it is a first-timer
                // who tapped the wrong door, not an auth failure: keep the
                // session while the app clearly offers sign-up.
                let outcome = await session.resumeExistingAccount(method: .email)
                guard !Task.isCancelled else { return }
                if outcome == .accountNotFound {
                    model.offerSignup(method: .email)
                }
                if outcome != .unreachable { Haptics.success() }
                // A successful returning sign-in has no later completion
                // sentinel to consume the onboarding draft, exactly like the
                // provider path. Remove it here too, so a later sign-out cannot
                // restore this person's email or stale setup answers.
                if outcome == .signedIn { model.clearDraft() }
            } else {
                if await model.completeSignup(using: session, method: .email) {
                    Haptics.success()
                }
            }
            isVerifying = false
        }
    }

    private func updateWithOptionalAnimation(_ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(GroveMotion.snap, updates)
        }
    }
}
