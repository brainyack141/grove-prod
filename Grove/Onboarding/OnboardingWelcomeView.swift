import SwiftUI
import PhotosUI

/// The first screen: Sprout potted on a sunny windowsill, saying hello, over
/// the one promise and the way in.
///
/// Grove is scan-first, so the primary capsule opens the camera on the
/// person's own plant; signing in to an existing grove is the outlined
/// alternative, and the no-plant escape, privacy and terms are quiet links.
struct OnboardingWelcomeView: View {
    let model: OnboardingModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(ScanSession.self) private var scanSession
    @Environment(SessionService.self) private var session
    @State private var isChangingRoute = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        WindowsillScene()
                            .frame(maxWidth: sceneWidth(for: proxy.size))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)

                        OnboardingQuestionTitle(
                            lead: "Know what every plant ",
                            accent: "needs",
                            trail: ", and when.",
                            subtitle: "Scan a plant to learn its name, its light, and when to water it."
                        )
                        .padding(.horizontal, GroveTheme.pagePadding + 4)
                        .padding(.top, 18)

                        if dynamicTypeSize.isAccessibilitySize {
                            welcomeActions
                                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                                .padding(.horizontal, GroveTheme.pagePadding + 4)
                                .padding(.top, 24)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }

            if !dynamicTypeSize.isAccessibilitySize {
                welcomeActions
                    .padding(.horizontal, GroveTheme.pagePadding + 4)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .background(GroveTheme.background)
            }
        }
        .background(GroveTheme.background.ignoresSafeArea())
        .task { await scanSession.activateForOnboarding() }
    }

    /// The scene takes the width it can while the promise and all three capsules
    /// still share the first view; on a 4.7-inch phone or at accessibility
    /// sizes it shrinks rather than pushing the buttons below the fold.
    private func sceneWidth(for size: CGSize) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return min(size.width, 160) }
        let reserved: CGFloat = 390
        let available = max(220, size.height - reserved)
        let widthForHeight = available * WindowsillScene.designSize.width / WindowsillScene.designSize.height
        return min(size.width, widthForHeight)
    }

    private var welcomeActions: some View {
        VStack(spacing: 10) {
            Button {
                Haptics.commit()
                beginFirstPlant()
            } label: {
                OnboardingInkCapsuleLabel(
                    title: scanSession.resumableDraftMode == nil ? "Scan my plant" : "Resume saved photo",
                    isWorking: isChangingRoute
                )
            }
            .buttonStyle(GrovePressStyle())
            .accessibilityIdentifier("onboardingGetStarted")

            Button {
                Haptics.tap()
                leaveRetainedScanForSignIn()
            } label: {
                OnboardingOutlineCapsuleLabel(title: "I already have an account")
            }
            .buttonStyle(GrovePressStyle())
            .accessibilityLabel("Sign in to an existing Grove")
            .accessibilityIdentifier("onboardingSignIn")

            Button {
                Haptics.tap()
                model.beginManualSetup()
            } label: {
                OnboardingOutlineCapsuleLabel(title: "I'll add a plant later")
            }
            .buttonStyle(GrovePressStyle())
            .accessibilityHint("Set up Grove without scanning a plant now")
            .accessibilityIdentifier("onboardingExplore")

            OnboardingLinkRow {
                HStack(spacing: 18) {
                    Link("Privacy", destination: OnboardingLegal.privacyURL)
                        .foregroundStyle(OnboardingTheme.mutedInk)
                        .tint(OnboardingTheme.mutedInk)
                        .frame(minHeight: 44)

                    Link("Terms", destination: OnboardingLegal.termsURL)
                        .foregroundStyle(OnboardingTheme.mutedInk)
                        .tint(OnboardingTheme.mutedInk)
                        .frame(minHeight: 44)
                }
            }
            .padding(.top, 2)
        }
        .disabled(isChangingRoute)
    }

    private func leaveRetainedScanForSignIn() {
        guard !isChangingRoute else { return }
        isChangingRoute = true
        Task {
            await scanSession.activateForOnboarding()
            await scanSession.discard()
            try? await PendingFirstPlantStore.shared.discardUnclaimed()
            session.clearOnboardingGuestCredential()
            guard !Task.isCancelled else {
                isChangingRoute = false
                return
            }
            model.signInToExistingAccount()
        }
    }

    private func beginFirstPlant() {
        guard !isChangingRoute else { return }
        isChangingRoute = true
        model.beginFirstPlant()
    }
}

/// A quiet escape hatch for someone who does not have a plant nearby: the
/// same windowsill, an empty pot's worth of reassurance, and two ways on.
struct OnboardingExploreView: View {
    let model: OnboardingModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(ScanSession.self) private var scanSession
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        OnboardingSproutPage(step: nil, isBackEnabled: !isImporting, onBack: model.back) {
            VStack(alignment: .leading, spacing: 20) {
                OnboardingQuestionTitle(
                    lead: "No plant ",
                    accent: "nearby",
                    trail: "?",
                    subtitle: "Make your account now and scan a plant when you’re next to one, or use a photo you already have."
                )
                WindowsillScene()
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 160 : 300)
                    .frame(maxWidth: .infinity)
                if let importError {
                    Text(importError)
                        .font(.callout)
                        .foregroundStyle(GroveTheme.danger)
                }
            }
        } footer: {
            VStack(spacing: 4) {
                OnboardingPrimaryButton(title: "Create an account", isEnabled: !isImporting) {
                    Haptics.commit()
                    model.advance()
                }
                .accessibilityIdentifier("onboardingCreateAccount")

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    HStack(spacing: 8) {
                        if isImporting { ProgressView() }
                        Text(isImporting ? "Opening photo…" : "Use a plant photo")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(GroveTheme.mutedInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .disabled(isImporting)
                .accessibilityIdentifier("onboardingUsePlantPhoto")
            }
        }
        .task(id: selectedPhoto) {
            guard let selectedPhoto else { return }
            isImporting = true
            importError = nil
            defer { isImporting = false; self.selectedPhoto = nil }
            do {
                guard let data = try await selectedPhoto.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { throw ScanMediaError.invalidImage }
                try Task.checkCancellation()
                await scanSession.activateForOnboarding()
                await scanSession.save(image: image, mode: .add, stage: .wholePlant)
                try Task.checkCancellation()
                if case .failed(let message, _) = scanSession.state {
                    importError = message
                } else if let message = scanSession.captureErrorMessage {
                    importError = message
                } else {
                    model.beginFirstPlant()
                }
            } catch is CancellationError {
                return
            } catch {
                importError = "That photo couldn’t be opened. Choose another one."
            }
        }
    }
}
