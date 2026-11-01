import PhotosUI
import SwiftUI
import UIKit

struct ScanView: View {
    @Environment(ScanSession.self) private var session
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    @Environment(\.dismiss) private var dismiss
    @Binding var path: [AppRoute]
    let isActive: Bool
    /// Set when the user arrived from a mode-specific entry point ("Diagnose",
    /// "Add a plant", a Siri shortcut…). The photo then goes straight into that
    /// flow instead of stopping at the "What next?" chooser.
    var presetMode: ScanMode? = nil
    /// The plant being diagnosed, when the scan was started from a plant page.
    var plantID: UUID? = nil
    /// True when this is the root of the scan cover rather than a screen pushed
    /// onto a tab's stack. Without a dismiss control here the cover has no exit:
    /// the navigation bar is hidden for the full-bleed preview, and there is no
    /// tab bar behind a cover to escape to.
    var isModalRoot: Bool = false
    /// The raised tab action hands its miniature focus brackets into this view.
    /// Other entrances (Shortcuts, onboarding, a plant concern) start directly
    /// at the full reticle because there is no visible source to grow from.
    var animatesReticleEntry: Bool = false
    /// When supplied, `.add` stops at the resolved scan instead of routing into
    /// the signed-in add-plant stack. Onboarding owns the durable handoff and
    /// decides when the result may cross the account boundary.
    var onFirstPlantResolved: ((PlantAnalysisResult, ScanMediaDraft, UUID) -> Void)? = nil
    /// Reports the first durable, quality-approved onboarding capture before
    /// analysis starts, so failed analyses still count as real funnel progress.
    var onFirstPlantPhotoCaptured: (() -> Void)? = nil
    /// A scan embedded in onboarding is not a modal, so `dismiss()` has no
    /// parent presentation to close. Its chrome delegates Back explicitly.
    var onOnboardingCancel: (() -> Void)? = nil
    /// Daily scan ceilings are different from cancellation: onboarding returns
    /// to Welcome while the durable photo and guest credential stay intact, so
    /// the same baseline can resume after the allowance resets.
    var onOnboardingKeepForLater: (() -> Void)? = nil
    /// Camera denial must not make account creation impossible. The same manual
    /// setup escape offered on Welcome remains reachable from the failure UI.
    var onManualSetup: (() -> Void)? = nil

    @State private var model = CameraCaptureModel()
    /// The live-frame brain: plant presence, light, focus and framing read
    /// from the preview stream while the user lines up the shot.
    @State private var liveScan = LiveScanModel()
    /// Set once a captured photo is being identified in place — the dark
    /// camera context holds while the result card resolves over the photo.
    @State private var liveResultMode: ScanMode?
    @State private var focusIndicator: ScanFocusIndicator?
    @State private var captureError: String?
    @State private var reviewImage: UIImage?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showLibraryPicker = false
    @State private var isSavingChoice = false
    @State private var isAddingResolvedPlant = false
    @State private var choiceError: String?
    @State private var speciesSearchPresentation: SpeciesSearchPresentation?
    @State private var showReviewExitConfirmation = false
    /// Diagnosis deliberately gathers two different scales of evidence: the
    /// whole plant first, then the affected area. This state keeps the second
    /// shutter tied to the existing durable draft instead of starting a new
    /// one-photo scan.
    @State private var diagnosisCaptureStage: ScanCaptureStage = .wholePlant
    @State private var showScanTips = false
    @State private var showsAIConsent = false
    @State private var aiConsentOutcome: AIConsentOutcome?
    @State private var showsCompositionGrid = false
    @State private var afterTipsDismiss: (() -> Void)?
    /// The focus bloom belongs to presentation, not every return from a result
    /// or photo review. The child captures the first `true` before this flips.
    @State private var hasConsumedReticleEntry = false
    /// The tips → camera chain has run for this presentation, so re-appearances
    /// (returning from a result page) may resume the camera directly.
    @State private var introComplete = false
    /// The flow the next capture feeds. The activation camera arrives preset to
    /// `.add`, but adding a plant you own is only one of the three questions
    /// people install Grove to ask — `firstScanModeRow` lets that camera switch
    /// to identify or diagnose without abandoning onboarding.
    @State private var modeOverride: ScanMode?
    /// A durable onboarding draft is reopened once, before camera startup. The
    /// source photo and stable request id survive a kill, so resumption polls or
    /// retries the same paid analysis instead of consuming another guest scan.
    @State private var hasRestoredOnboardingDraft = false
#if DEBUG
    /// A physical-device UI test cannot depend on the room, camera permission,
    /// or a plant being in front of the phone. The fixture still travels
    /// through capture review, `ScanSession`, and the durable onboarding
    /// handoff; only the camera source is deterministic.
    @State private var hasPresentedOnboardingUITestPhoto = false
#endif
    @AppStorage(GroveDefaults.hasSeenScanTips) private var hasSeenScanTips = false
    @AppStorage(GroveDefaults.firstPlantActivationPending) private var firstPlantActivationPending = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let reviewImage {
                reviewContent(image: reviewImage)
            } else {
                Group {
                    switch model.status {
                    case .ready:
                        cameraContent
                    case .denied:
                        permissionState(
                            icon: "camera.fill",
                            title: "Camera access is off",
                            message: "Turn on camera access in Settings to photograph a plant, or choose one from your library.",
                            showsSettings: true
                        )
                    case .unavailable(let message):
                        permissionState(icon: "camera.badge.ellipsis", title: "Camera unavailable", message: message, showsSettings: false)
                    case .idle:
                        ProgressView().controlSize(.large).tint(.white)
                    }
                }
                overlayChrome
            }
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard isActive else { return }
            beginSession()
        }
        // A pushed instance stays alive behind the capture screens it navigates
        // to, so the preview has to be torn down and brought back by hand.
        .onAppear {
            guard isActive, introComplete, reviewImage == nil else { return }
            Task { await model.resume() }
        }
        .onDisappear {
            model.stop()
        }
        .onChange(of: isActive) { _, active in
            if active {
                beginSession()
            } else {
                model.stop()
            }
        }
        .photosPicker(isPresented: $showLibraryPicker, selection: $selectedPhoto, matching: .images)
        .task(id: selectedPhoto) {
            guard let selectedPhoto else { return }
            defer { self.selectedPhoto = nil }
            do {
                guard let data = try await selectedPhoto.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    throw ScanMediaError.invalidImage
                }
                present(image)
            } catch is CancellationError {
                return
            } catch {
                captureError = "Grove couldn't open that library photo. Choose another one."
                if isActive, introComplete, reviewImage == nil {
                    await model.resume()
                }
            }
        }
        .onChange(of: showLibraryPicker) { _, isPresented in
            // A cancelled picker has no selected-item task to restart the camera.
            guard !isPresented,
                  reviewImage == nil,
                  isActive,
                  introComplete else { return }
            Task {
                // PhotosPicker can publish dismissal just before its selection.
                // Give that binding one beat to arrive so a real selection does
                // not briefly restart the camera behind a photo download.
                try? await Task.sleep(for: .milliseconds(120))
                guard selectedPhoto == nil,
                      reviewImage == nil,
                      isActive else { return }
                await model.resume()
            }
        }
        .sheet(isPresented: $showScanTips, onDismiss: finishScanTips) {
            ScanTipsView(
                mode: activeMode ?? .add,
                onDismiss: { hasSeenScanTips = true },
                onManualSetup: onManualSetup.map { action in
                    { leaveTips(perform: action) }
                },
                onSwitchCamera: model.status == .ready ? {
                    model.flip()
                    showScanTips = false
                } : nil,
                onToggleGrid: model.status == .ready ? {
                    showsCompositionGrid.toggle()
                    showScanTips = false
                } : nil,
                showsGrid: showsCompositionGrid,
                onScanHistory: onFirstPlantResolved == nil ? {
                    leaveTips { path.append(.scanHistory) }
                } : nil,
                onResumeScan: canResumeScan ? {
                    leaveTips(perform: resumeSavedScan)
                } : nil
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showsAIConsent, onDismiss: finishAIConsent) {
            AIProcessingConsentView(
                onAgree: {
                    aiConsentOutcome = .agreed
                    showsAIConsent = false
                },
                onDecline: {
                    aiConsentOutcome = .declined
                    showsAIConsent = false
                },
                declineTitle: onManualSetup == nil ? "Not now" : "Add it by hand instead"
            )
        }
        .sheet(item: $speciesSearchPresentation) { _ in
            NavigationStack { SpeciesSearchView(isOnboarding: onFirstPlantResolved != nil) }
        }
        .confirmationDialog(
            "Leave this scan?",
            isPresented: $showReviewExitConfirmation,
            titleVisibility: .visible
        ) {
            Button("Keep for later") { dismiss() }
            Button("Discard scan", role: .destructive) {
                Task {
                    await session.discard()
                    dismiss()
                }
            }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("This photo and result can be kept so you can finish another time.")
        }
    }

    // MARK: Live camera

    private var cameraContent: some View {
        GeometryReader { proxy in
            ZStack {
                CameraPreviewView(session: model.engine.session) { devicePoint, viewPoint in
                    model.focus(at: devicePoint)
                    showFocusIndicator(at: viewPoint)
                }
                .ignoresSafeArea()

                if let focusIndicator {
                    FocusRing()
                        .position(focusIndicator.point)
                        .transition(.scale.combined(with: .opacity))
                        .id(focusIndicator.id)
                }
            }
            // The analyzer's lifetime is exactly the preview's: this view only
            // exists while the camera is ready and no photo is under review.
            .onAppear { liveScan.attach(to: model.engine) }
            .onDisappear { liveScan.detach(from: model.engine) }
        }
    }

    /// `presetMode` with any first-run switch applied. Reads that decide what
    /// the captured photo *does* go through this; the structural reads (which
    /// dismiss control to draw, whether the chooser exists) stay on
    /// `presetMode`.
    private var activeMode: ScanMode? { modeOverride ?? presetMode }

    private var overlayChrome: some View {
        VStack(spacing: 0) {
            topBar
            if model.status == .ready {
                ZStack {
                    if showsCompositionGrid {
                        GridOverlay()
                    }
                    LiveScanReticle(
                        phase: liveScan.phase,
                        frameScore: liveScan.frameScore,
                        animatesEntry: animatesReticleEntry && !hasConsumedReticleEntry
                    )
                    .onAppear { hasConsumedReticleEntry = true }
                }
                .padding(.horizontal, 32)
                .padding(.top, 36)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            } else {
                Spacer()
            }
            if model.status == .ready {
                VStack(spacing: 0) {
                    if let captureError {
                        Label(captureError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(GroveTheme.danger.opacity(0.9), in: Capsule())
                            .padding(.horizontal, 26)
                            .padding(.bottom, 10)
                    }
                    instructionBanner
                    modeSwitcher
                        .padding(.bottom, 14)
                    bottomBar
                }
                .background(alignment: .bottom) {
                    CaptureBottomScrim()
                        .padding(.top, -40)
                }
            } else {
                VStack(spacing: 4) {
                    Button("Tips and scan options") { showScanTips = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("scanTipsButton")
                    if let onManualSetup {
                        Button("No plant nearby?", action: onManualSetup)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("scanManualSetup")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 16)
            }
        }
    }

    /// Which question the photo answers, as camera-style text segments. A
    /// camera that arrived with a mode can switch between the three questions
    /// without leaving: someone whose plant is sick, or who only wants a name,
    /// shouldn't have to back out to ask the question they actually came with.
    /// A scan tied to a plant, onboarding's first plant and the diagnosis
    /// close-up are locked to their flow, so they show only their own mode.
    @ViewBuilder private var modeSwitcher: some View {
        if let mode = activeMode {
            let current: ScanMode = diagnosisCaptureStage == .symptom ? .diagnose : mode
            CaptureModeSwitcher(
                modes: canSwitchMode ? [.identify, .diagnose, .add] : [current],
                selected: current,
                isInteractive: canSwitchMode,
                identifierPrefix: isActivationCamera ? "firstScanMode" : "scanMode",
                onSelect: { selectMode($0) }
            )
            .disabled(model.isCapturing)
        }
    }

    private var canSwitchMode: Bool {
        presetMode != nil
            && plantID == nil
            && onFirstPlantResolved == nil
            && diagnosisCaptureStage == .wholePlant
    }

    /// The first-plant activation camera, which arrives preset to "add".
    private var isActivationCamera: Bool {
        presetMode == .add && onFirstPlantResolved == nil && firstPlantActivationPending
    }

    private func selectMode(_ mode: ScanMode) {
        Haptics.selection()
        withAnimation(GroveMotion.snap) {
            modeOverride = mode == presetMode ? nil : mode
        }
    }

    private func resumeTitle(for mode: ScanMode) -> String {
        switch mode {
        case .add: "Continue adding your plant"
        case .identify: "Finish identifying your photo"
        case .diagnose: "Finish your diagnosis"
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            if isModalRoot || presetMode != nil {
                Button {
                    if let onOnboardingCancel {
                        onOnboardingCancel()
                    } else {
                        dismiss()
                    }
                } label: {
                    CaptureGlassChip(systemImage: isModalRoot ? "xmark" : "chevron.left")
                }
                .buttonStyle(GroveTilePressStyle())
                .accessibilityLabel(isModalRoot ? "Close" : "Back")
                .accessibilityIdentifier("scanBack")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }

            // No visible title: the mode segments along the bottom already say
            // what this photo is for.
            Spacer(minLength: 0)

            Button {
                model.toggleFlash()
            } label: {
                CaptureGlassChip(
                    systemImage: model.flash.icon,
                    tint: model.flash == .on ? GroveTheme.gold : .white
                )
            }
            .buttonStyle(GroveTilePressStyle())
            .disabled(model.status != .ready)
            .opacity(model.status == .ready ? 1 : 0)
            .accessibilityLabel("Flash \(model.flash == .auto ? "auto" : model.flash == .on ? "on" : "off")")
            .accessibilityIdentifier("scanFlashToggle")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background {
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
        .disabled(model.isCapturing)
    }

    private var canResumeScan: Bool {
        onFirstPlantResolved == nil && presetMode == nil && session.resumableDraftMode != nil
    }

    private func resumeSavedScan() {
        guard let resumable = session.resumableDraftMode else { return }
        if let missingStage = session.requiredAdditionalCaptureStage {
            diagnosisCaptureStage = missingStage
            continueAfterScanIntro()
        } else {
            path.append(session.existingPlantID.map { .plantScanResult($0, resumable) }
                ?? .scanResult(resumable))
        }
    }

    private func leaveTips(perform action: @escaping () -> Void) {
        afterTipsDismiss = action
        showScanTips = false
    }

    private func finishScanTips() {
        hasSeenScanTips = true
        if let action = afterTipsDismiss {
            afterTipsDismiss = nil
            action()
        } else {
            continueAfterScanIntro()
        }
    }

    private var instructionText: String {
        if diagnosisCaptureStage == .symptom {
            return "Fill the frame with the affected area"
        }
        return switch activeMode {
        case .none: "Fit the whole plant and its pot in frame"
        case .identify: "Fit the whole plant and its pot in frame"
        case .add: "Fit the whole plant and its pot in frame"
        case .diagnose: "First, photograph the whole plant and its pot"
        }
    }

    /// One live sentence above the controls, led by a dot: white while
    /// searching, amber when something needs fixing, green once the frame will
    /// land. The same reading drives the reticle.
    private var instructionBanner: some View {
        CaptureLiveHint(model: liveScan, idleInstruction: instructionText)
            .padding(.horizontal, 26)
            .padding(.bottom, 18)
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            Button {
                openLibraryPicker()
            } label: {
                CaptureLibraryTile()
            }
            .buttonStyle(GroveTilePressStyle())
            .accessibilityLabel("Choose from photos")
            .accessibilityIdentifier("scanLibraryButton")
            .frame(width: 56)

            Spacer()

            Button(action: captureTapped) {
                CaptureShutterLabel(isBusy: model.isCapturing)
            }
            .buttonStyle(GroveCardPressStyle(scale: 0.94, haptics: false))
            .disabled(model.isCapturing)
            .accessibilityLabel("Take photo")
            .accessibilityIdentifier("scanShutter")

            Spacer()

            Button {
                model.stop()
                showScanTips = true
            } label: {
                CaptureGlassChip(systemImage: "questionmark")
            }
            .buttonStyle(GroveTilePressStyle())
            .accessibilityLabel("Scanning tips and camera options")
            .accessibilityIdentifier("scanTipsButton")
            .frame(width: 56)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 24)
        .disabled(model.isCapturing)
    }

    // MARK: Non-ready state

    private func permissionState(icon: String, title: String, message: String, showsSettings: Bool) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(.white.opacity(0.85))
            Text(title).font(.title2.bold()).foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 12) {
                // The signature CTA in its on-dark form, so the primary action
                // here is the same pill it is everywhere else.
                if allowsSamplePhoto {
                    Button {
                        present(demoScanImage())
                    } label: {
                        GroveCTALabel(title: "Use a sample photo", systemImage: "wand.and.stars", onDark: true)
                    }
                    .buttonStyle(GrovePressStyle())
                    .accessibilityIdentifier("scanUseSample")
                }

                GroveOutlineButton(title: "Choose from library", systemImage: "photo.on.rectangle", onDark: true) {
                    openLibraryPicker()
                }

                if showsSettings {
                    Button("Open Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(.white)
                }

                // The shared overlay keeps manual setup reachable below this
                // state, even when the live camera and its Tips control are off.
            }
            .padding(.horizontal, 40)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    /// A synthetic image is useful for signed-in exploration and deterministic
    /// UI coverage, but a shipping onboarding must never save it as the user's
    /// first health baseline.
    private var allowsSamplePhoto: Bool {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-GroveUseFixtureAnalysis") { return true }
#endif
        return onFirstPlantResolved == nil
    }

    // MARK: Photo review

    private func reviewContent(image: UIImage) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .ignoresSafeArea()

                LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack {
                        Button {
                            if liveResultMode != nil {
                                // The card owns a saved draft and possibly an
                                // in-flight analysis; both go with the photo.
                                retakeFromLiveCard()
                            } else {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    self.reviewImage = nil
                                    choiceError = nil
                                }
                                Task { await model.resume() }
                            }
                        } label: {
                            CaptureGlassChip(systemImage: "arrow.uturn.left")
                        }
                        .buttonStyle(GroveTilePressStyle())
                        .disabled(isSavingChoice)
                        .accessibilityLabel("Retake photo")
                        .accessibilityIdentifier("scanRetake")
                        Spacer()
                        Button(action: closeReviewTapped) {
                            CaptureGlassChip(systemImage: "xmark")
                        }
                        .buttonStyle(GroveTilePressStyle())
                        .disabled(isSavingChoice || isAddingResolvedPlant)
                        .accessibilityLabel("Close scan")
                        .accessibilityIdentifier("scanReviewClose")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    Spacer()

                    if let mode = liveResultMode {
                        // The reference moment: the photo holds full-bleed and
                        // the identification resolves in place, in the dark.
                        ScanLiveResultCard(
                            mode: mode,
                            usesOnboardingStyle: onFirstPlantResolved != nil,
                            captureError: choiceError,
                            unknownContinueTitle: onFirstPlantResolved == nil ? nil : "Keep as an unknown plant",
                            onRetake: retakeFromLiveCard,
                            onRetry: retryLiveAnalysis,
                            onKeepForLater: leaveKeepingDraft,
                            onManualSetup: onManualSetup,
                            isCommitting: isAddingResolvedPlant,
                            onChangeIdentity: { speciesSearchPresentation = SpeciesSearchPresentation() },
                            onContinue: { finishToFullReading(mode) }
                        )
                    } else if diagnosisCaptureStage == .symptom {
                        presetProgress(mode: .diagnose)
                    } else if let mode = activeMode {
                        // Diagnosis keeps its dedicated result page — its
                        // answer is the condition, not the name.
                        presetProgress(mode: mode)
                    } else {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            GroveEyebrow(text: "Your photo", color: .white.opacity(0.8))
                            Text("What next?")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                                .accessibilityAddTraits(.isHeader)
                        }
                        .padding(.bottom, 2)

                        ScanChoiceButton(
                            artwork: "GroveQuickAdd",
                            title: "Add to my grove",
                            subtitle: "Save it and start its care plan"
                        ) { choose(.add) }
                        .accessibilityIdentifier("scanChoice.add")

                        ScanChoiceButton(
                            artwork: "GroveQuickDiagnose",
                            title: "Diagnose",
                            subtitle: "Work out what it is and what to do"
                        ) { choose(.diagnose) }
                        .accessibilityIdentifier("scanChoice.diagnose")

                        ScanChoiceButton(
                            artwork: "GroveQuickIdentify",
                            title: "Identify",
                            subtitle: "Identify it without adding it"
                        ) { choose(.identify) }
                        .accessibilityIdentifier("scanChoice.identify")

                        if let choiceError {
                            Text(choiceError).font(.caption).foregroundStyle(GroveTheme.danger)
                        }
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: GroveTheme.heroRadius, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                    .disabled(isSavingChoice)
                    .opacity(isSavingChoice ? 0.6 : 1)
                    .overlay {
                        if isSavingChoice { ProgressView().tint(.white) }
                    }
                    }
                }
            }
        }
    }

    /// Stand-in for the chooser when the mode was decided before the camera
    /// opened: the photo is already on its way into that flow.
    private func presetProgress(mode: ScanMode) -> some View {
        VStack(spacing: 12) {
            if let choiceError {
                Label(choiceError, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                // Most rejections here are the quality gate, and the quality
                // gate is deterministic — "Try again" resubmitted the same
                // photo and failed the same way forever. The fix is always a
                // different photo.
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        reviewImage = nil
                        self.choiceError = nil
                    }
                    Task { await model.resume() }
                } label: {
                    GroveCTALabel(title: "Retake photo", systemImage: "camera", onDark: true)
                }
                .buttonStyle(GrovePressStyle())
            } else {
                ProgressView().tint(.white)
                Text(mode.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: GroveTheme.heroRadius, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    // MARK: Actions

    private enum AIConsentOutcome {
        case agreed
        case declined
    }

    /// Nothing reaches Gemini until the person has agreed to the third-party
    /// disclosure. Both the onboarding first plant and an ordinary scan pass
    /// through here, and neither opens the camera or restores a draft while
    /// the sheet is unanswered.
    private func beginSession() {
        guard AIProcessingConsent.isGranted() else {
            guard !showsAIConsent else { return }
            showsAIConsent = true
            return
        }
        beginSessionAfterConsent()
    }

    /// Ordinary scans show the once-per-install tips before starting camera
    /// work. Onboarding has already demonstrated the capture on its welcome
    /// screen and the viewfinder carries task-specific guidance, so it opens
    /// directly; the help button still makes the tips available on demand.
    private func beginSessionAfterConsent() {
        if onFirstPlantResolved != nil {
            hasSeenScanTips = true
            continueAfterScanIntro()
            return
        }
        if !hasSeenScanTips {
            showScanTips = true
            return
        }
        continueAfterScanIntro()
    }

    private func finishAIConsent() {
        let outcome = aiConsentOutcome
        aiConsentOutcome = nil
        switch outcome {
        case .agreed:
            beginSessionAfterConsent()
        case .declined:
            closeForDeclinedAIConsent()
        case nil:
            break
        }
    }

    /// In onboarding, declining routes to manual setup so the person can add
    /// the plant by hand without a photo instead of being ejected to Welcome.
    /// Elsewhere it leaves the camera closed and returns the person to
    /// wherever they came from, using the same exit as the chrome's close
    /// button.
    private func closeForDeclinedAIConsent() {
        model.stop()
        if let onManualSetup {
            onManualSetup()
        } else if let onOnboardingCancel {
            onOnboardingCancel()
        } else {
            dismiss()
        }
    }

    /// Restoration may submit a saved photo immediately, so it belongs behind
    /// the same intro gate as a brand-new capture.
    private func continueAfterScanIntro() {
        guard hasSeenScanTips else { return }
        if restoreOnboardingDraftIfAvailable() { return }
        startCameraAfterIntro()
    }

    private func startCameraAfterIntro() {
        introComplete = true
#if DEBUG
        if shouldPresentOnboardingUITestPhoto {
            hasPresentedOnboardingUITestPhoto = true
            present(demoScanImage())
            return
        }
#endif
        Task { await model.resume() }
    }

    private func restoreOnboardingDraftIfAvailable() -> Bool {
        guard onFirstPlantResolved != nil,
              !hasRestoredOnboardingDraft,
              session.mode == .add,
              let image = session.previewImage else { return false }
        hasRestoredOnboardingDraft = true
        introComplete = true
        reviewImage = image
        liveResultMode = .add
        if session.result == nil {
            Task { await session.analyse(regionCode: analysisRegionCode) }
        }
        return true
    }

#if DEBUG
    /// Two flags keep this test seam explicit: one selects deterministic local
    /// analysis, and the other opts this onboarding instance into a synthetic
    /// camera source. Shipping builds compile the seam out entirely.
    private var shouldPresentOnboardingUITestPhoto: Bool {
        guard onFirstPlantResolved != nil,
              !hasPresentedOnboardingUITestPhoto else { return false }
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-GroveUseFixtureAnalysis")
            && arguments.contains("-GroveUITestOnboardingSample")
    }
#endif

    private func captureTapped() {
        Task {
            captureError = nil
            do {
                let image = try await model.capture()
                present(image)
            } catch {
                captureError = error.localizedDescription
            }
        }
    }

    /// Shows the photo for review. When the user already told us what they came
    /// to do, there is nothing left to choose — go straight into that flow.
    private func present(_ image: UIImage) {
        // The preview is completely covered from this point onward. Leaving the
        // capture session alive kept the green privacy indicator lit throughout
        // review and remote analysis and wasted power while no live pixels were
        // visible.
        model.stop()
        captureError = nil
        withAnimation(.easeOut(duration: 0.2)) { reviewImage = image }
        if diagnosisCaptureStage == .symptom {
            choose(.diagnose, image: image)
        } else if let mode = activeMode {
            choose(mode, image: image)
        }
    }

    private func choose(_ mode: ScanMode, image: UIImage? = nil) {
        guard let image = image ?? reviewImage, !isSavingChoice else { return }
        isSavingChoice = true
        choiceError = nil
        // Identification happens here, over the photo: the dark camera context
        // holds while the card resolves, and the cream result page becomes one
        // tap deeper. Diagnosis still travels straight to its own page.
        if mode != .diagnose {
            withAnimation(GroveMotion.snap) { liveResultMode = mode }
        }
        Task {
            await session.begin(mode: mode, existingPlantID: plantID)
            session.state = .saving
            let captureStage = mode == .diagnose ? diagnosisCaptureStage : .wholePlant
            await session.save(image: image, mode: mode, stage: captureStage)
            isSavingChoice = false
            if case .failed(let message, _) = session.state {
                choiceError = message
                return
            }
            // A rejected retake leaves the session `.ready` when an older
            // capture survived — proceeding would silently analyse that
            // previous photo instead of the one the user just took.
            if let rejection = session.captureErrorMessage {
                choiceError = rejection
                return
            }
            if captureStage == .wholePlant { onFirstPlantPhotoCaptured?() }
            if mode == .diagnose {
                if captureStage == .wholePlant {
                    // Keep the accepted whole-plant draft, return to the same
                    // camera, and collect the close evidence the diagnosis
                    // prompt and UI have always promised.
                    diagnosisCaptureStage = .symptom
                    self.reviewImage = nil
                    choiceError = nil
                    await model.resume()
                } else {
                    diagnosisCaptureStage = .wholePlant
                    self.reviewImage = nil
                    path.append(nextRoute(for: mode))
                }
            } else {
                await session.analyse(
                    regionCode: analysisRegionCode,
                    existingPlant: plantID.flatMap(store.plant(id:))
                )
            }
        }
    }

    /// Back to a live viewfinder, abandoning the capture and any in-flight
    /// analysis. The quality gate is deterministic, so the fix for a rejected
    /// photo is always a different photo.
    private func retakeFromLiveCard() {
        withAnimation(.easeOut(duration: 0.2)) {
            reviewImage = nil
            liveResultMode = nil
            choiceError = nil
        }
        Task {
            await session.discard()
            await model.resume()
        }
    }

    /// Back to the viewfinder with the photo intact.
    ///
    /// The counterpart to `retakeFromLiveCard`: when the failure is a ceiling
    /// rather than a bad frame, discarding the capture would contradict the
    /// sentence above the button. A regular scan exposes it from the top bar;
    /// onboarding returns to Welcome, whose primary action restores it.
    private func leaveKeepingDraft() {
        if let onOnboardingKeepForLater {
            onOnboardingKeepForLater()
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            reviewImage = nil
            liveResultMode = nil
            choiceError = nil
        }
        Task { await model.resume() }
    }

    /// Review is still part of the modal scan task, so leaving must be possible
    /// without pretending that "Retake" means "Cancel". A durable draft gets a
    /// real keep-or-discard decision; an unsaved chooser can simply close.
    private func closeReviewTapped() {
        if session.draft != nil || liveResultMode != nil {
            showReviewExitConfirmation = true
        } else {
            dismiss()
        }
    }

    private func openLibraryPicker() {
        // A sheet does not make the presenting view disappear, so `onDisappear`
        // cannot be relied on to release the camera while PhotosPicker is open.
        model.stop()
        showLibraryPicker = true
    }

    private func retryLiveAnalysis() {
        Task {
            await session.analyse(
                regionCode: analysisRegionCode,
                existingPlant: plantID.flatMap(store.plant(id:))
            )
        }
    }

    /// Leaves the camera for whatever the in-context card was leading to.
    ///
    /// A settled identity becomes a plant in one tap. Personal details belong
    /// on the plant page after ownership, not in a form between identification
    /// and the payoff. Unknown or provisional identities still stop for an
    /// explicit human decision before species-dependent care is trusted.
    private func finishToFullReading(_ mode: ScanMode) {
        if mode == .add,
           plantID == nil,
           let result = session.result,
           let draft = session.draft,
           let onFirstPlantResolved {
            onFirstPlantResolved(result, draft, session.scanID)
            return
        }
        if mode == .add,
           plantID == nil,
           let identification = session.result?.identification {
            switch ScanAddDecision(identification: identification) {
            case .adopt:
                adoptResolvedPlant()
            case .confirmAndAdopt(let candidate):
                session.confirmIdentity(candidate)
                adoptResolvedPlant()
            case .reviewIdentity:
                liveResultMode = nil
                reviewImage = nil
                path.append(.scanResult(mode))
            }
            return
        }
        liveResultMode = nil
        reviewImage = nil
        path.append(nextRoute(for: mode))
    }

    private func adoptResolvedPlant() {
        let isFirstPlant = store.plants.isEmpty
        guard !isAddingResolvedPlant,
              let adoption = ScanPlantAdoption.prepare(session: session, store: store) else {
            choiceError = "Grove couldn't add this plant yet. Try again in a moment."
            return
        }
        isAddingResolvedPlant = true
        choiceError = nil

        if firstPlantActivationPending {
            OnboardingAnalytics.firstPlantBaselineSaved()
            firstPlantActivationPending = false
        }
        Haptics.celebrate()
        toasts?.show("\(adoption.plant.nickname) is in your grove", symbol: "leaf.fill")
        IntentRouter.shared.openPlant(adoption.plant.id)

        Task {
            await adoption.persist(
                session: session,
                store: store,
                syncEngine: syncEngine,
                connectivity: connectivity
            )
            if isFirstPlant {
                UserDefaults.standard.set(adoption.plant.id.uuidString, forKey: GroveDefaults.firstPlantNotificationPrimerPlantID)
            }
            isAddingResolvedPlant = false
        }
    }

    /// Every scan works from the single whole-plant photo, so all modes go
    /// straight to analysis.
    private func nextRoute(for mode: ScanMode) -> AppRoute {
        if let plantID {
            return .plantScanResult(plantID, mode)
        }
        return .scanResult(mode)
    }

    /// The app-wide store can still be activated to the account that just
    /// signed out. Signed-out capture uses only device locale and never reads
    /// that previous account's profile through the shared environment.
    private var analysisRegionCode: String? {
        if onFirstPlantResolved != nil {
            return Locale.current.region?.identifier
        }
        return store.profile.regionCode
    }

    private func showFocusIndicator(at point: CGPoint) {
        withAnimation(.easeOut(duration: 0.2)) {
            focusIndicator = ScanFocusIndicator(point: point)
        }
        let current = focusIndicator?.id
        Task {
            try? await Task.sleep(for: .seconds(1))
            if focusIndicator?.id == current {
                withAnimation(.easeIn(duration: 0.25)) { focusIndicator = nil }
            }
        }
    }
}

/// The add path may be short only when Grove's identity is settled. Keeping the
/// rule in one tiny value makes it impossible for routing and the result UI to
/// develop different definitions of "ready to adopt" again.
enum ScanAddDecision: Equatable {
    case adopt
    case confirmAndAdopt(SpeciesCandidate)
    case reviewIdentity

    init(identification: PlantIdentificationResult) {
        if identification.isUnknown == true {
            self = .reviewIdentity
        } else if identification.requiresConfirmation == true {
            let candidate = identification.candidates?.first {
                $0.scientificName == identification.scientificName
            } ?? SpeciesCandidate(
                id: identification.scientificName,
                commonName: identification.commonName,
                scientificName: identification.scientificName,
                confidence: identification.confidence,
                distinguishingTraits: identification.distinguishingTraits,
                regionalFit: nil,
                canonicalTaxonID: identification.canonicalTaxonID
            )
            self = .confirmAndAdopt(candidate)
        } else {
            self = .adopt
        }
    }
}

/// Evidence failures are not uncertain identities. A readable single plant may
/// still be worth keeping as unknown, but a bouquet, a cut arrangement, or two
/// different plants cannot become one care record without making every later
/// reminder and diagnosis misleading.
struct ScanEvidenceRetryGuidance: Equatable {
    enum Kind: Equatable {
        case multiplePlants
        case unsupportedSubject
        case mismatchedPhotos
        case unreadablePlant
    }

    let kind: Kind
    let eyebrow: String
    let title: String
    let detail: String
    let actionTitle: String
    /// The one view the analysis asked for again, when it named one.
    ///
    /// The structural failures leave this nil on purpose: a bouquet in frame is
    /// not fixed by retaking a stage, and offering "retake the leaf photo" for
    /// it would send someone back to the camera to make the same mistake more
    /// carefully.
    let retakeStage: ScanCaptureStage?

    init?(evidence: PlantEvidenceQuality?) {
        guard let evidence else { return nil }

        if evidence.subjectKind == .multiplePlants || evidence.subjectCount > 1 {
            kind = .multiplePlants
            eyebrow = "One at a time"
            title = "Choose one plant"
            detail = "This looks like several plants in one frame. Centre one living plant and keep the others out of shot."
            actionTitle = "Retake with one plant"
            retakeStage = nil
        } else if evidence.subjectKind == .nonPlant {
            kind = .unsupportedSubject
            eyebrow = "Try again"
            title = "Show a living plant"
            detail = "This looks like a cut arrangement or another subject that can't become a plant care record."
            actionTitle = "Retake photo"
            retakeStage = nil
        } else if !evidence.sameSubject {
            kind = .mismatchedPhotos
            eyebrow = "Photos don't match"
            title = "Show the same plant"
            detail = "The photos appear to show different plants. Retake them with the same plant in every view."
            actionTitle = "Retake photos"
            retakeStage = nil
        } else if evidence.subjectKind != .plant
            || evidence.subjectCount != 1
            || !evidence.usableForIdentification {
            // The catch-all, and the one branch where the analysis knows more
            // than the client can work out for itself. It is prompted to name
            // the exact retake and the single view that would help most, and
            // both were being discarded in favour of one sentence that fits
            // every failure and describes none of them.
            let stage = Self.stage(evidence.retakeStage)
            kind = .unreadablePlant
            eyebrow = "Try again"
            title = stage.map { "Retake the \($0.retakeNoun)" } ?? "Show a little more"
            detail = Self.reason(evidence.retakeReason)
                ?? stage?.instruction
                ?? "Frame one whole living plant clearly, with its leaves and stems visible."
            actionTitle = stage.map { "Retake the \($0.retakeNoun)" } ?? "Retake photo"
            retakeStage = stage
        } else {
            return nil
        }
    }

    /// `.none` is the model saying no single view would help, which is not a
    /// stage. `wholePlant` for an unreadable set is the sanitizer's default
    /// rather than a judgement, but it is also the right answer for it.
    private static func stage(_ stage: PlantEvidenceRetakeStage) -> ScanCaptureStage? {
        switch stage {
        case .wholePlant: .wholePlant
        case .leaf: .leaf
        case .stem: .stem
        case .symptom: .symptom
        case .none: nil
        }
    }

    /// The sanitizer substitutes a generic sentence when the model wrote
    /// nothing usable, and that sentence says less than the stage instruction
    /// it would replace. Only a real reason is shown.
    private static func reason(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "The photos do not show one readable plant clearly enough."
        else { return nil }
        return trimmed
    }
}

extension ScanCaptureStage {
    /// How the stage is named inside a sentence asking for it again.
    var retakeNoun: String {
        switch self {
        case .wholePlant: "whole-plant photo"
        case .leaf: "leaf photo"
        case .stem: "stem photo"
        case .symptom: "close-up"
        case .reference: "reference photo"
        }
    }
}

/// The durable work behind one-tap adoption. Local creation happens before any
/// network wait, while the photo/history/server work keeps the same idempotent
/// payloads the former add form used.
private struct ScanPlantAdoption {
    let plant: Plant
    let scanID: UUID
    let mode: ScanMode
    let analysis: PlantAnalysisResult
    let draft: ScanMediaDraft
    let request: CreatePlantRequest

    @MainActor
    static func prepare(session: ScanSession, store: GroveStore) -> ScanPlantAdoption? {
        guard let analysis = session.result, let draft = session.draft else { return nil }
        let identifiedName = analysis.identification.commonName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = analysis.identification.isUnknown == true || identifiedName.isEmpty
            ? "Unknown plant"
            : identifiedName
        let plant = store.addPlant(
            nickname: nickname,
            location: "Unassigned",
            lightPlacement: nil,
            analysis: analysis
        )
        return ScanPlantAdoption(
            plant: plant,
            scanID: session.scanID,
            mode: draft.mode,
            analysis: analysis,
            draft: draft,
            request: CreatePlantRequest(
                clientPlantID: plant.id,
                nickname: plant.nickname,
                location: plant.location,
                analysis: analysis,
                mediaDraftID: draft.id,
                plant: plant
            )
        )
    }

    @MainActor
    func persist(
        session: ScanSession,
        store: GroveStore,
        syncEngine: SyncEngine,
        connectivity: ConnectivityMonitor
    ) async {
        let archivedURL = await session.archivePrimaryForHistory() ?? draft.fileURL
        store.recordScan(
            id: scanID,
            mode: mode,
            result: analysis,
            photoURL: archivedURL,
            plantID: plant.id
        )
        let pendingMedia = PendingMediaUpload(
            localMediaID: draft.id,
            fileURL: draft.fileURL,
            purpose: .scan,
            mimeType: "image/jpeg",
            pixelWidth: draft.pixelWidth,
            pixelHeight: draft.pixelHeight
        )
        await syncEngine.enqueue(.uploadMedia(pendingMedia), isConnected: connectivity.isConnected)
        await syncEngine.enqueue(.createPlant(request), isConnected: connectivity.isConnected)
        if mode == .diagnose {
            _ = store.addDiagnosis(id: scanID, plantID: plant.id, result: analysis, photoURL: archivedURL)
            if let updated = store.plant(id: plant.id) {
                await syncEngine.enqueue(.updatePlant(UpdatePlantRequest(
                    plant: updated,
                    clientRequestID: scanID,
                    diagnoses: store.diagnoses(for: plant.id).map(\.withoutLocalPhoto)
                )), isConnected: connectivity.isConnected)
            }
        }
        OnboardingAnalytics.plantSaved(mode: mode, identification: analysis.identification)
        session.finishKeepingMedia(ifCurrentScanID: scanID)
    }
}

private struct ScanFocusIndicator: Equatable {
    let id = UUID()
    let point: CGPoint
}

// MARK: - In-context identification card

/// The identification, resolved where the photo was taken. The captured frame
/// holds full-bleed behind a dark card that moves through three honest states:
/// saving, identifying (narrated, with the card's own border filling as the
/// progress bar), and the reveal — name, confidence ring, and the three care
/// facts a plant person checks first. The full editorial reading is one tap
/// deeper, not forced on anyone who only wanted the name.
private struct ScanLiveResultCard: View {
    @Environment(ScanSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let mode: ScanMode
    var usesOnboardingStyle = false
    /// A capture/quality-gate rejection surfaced by the save step.
    let captureError: String?
    /// Onboarding has no signed-in result stack in which to resolve matches.
    /// It keeps a genuinely unknown baseline honestly instead of promising a
    /// picker that cannot be reached before account creation.
    let unknownContinueTitle: String?
    let onRetake: () -> Void
    let onRetry: () -> Void
    let onKeepForLater: () -> Void
    /// Onboarding only. The daily ceiling is the one failure this card cannot
    /// retry out of, and it covers the camera rather than sitting beside it,
    /// so the top bar's escape is not on screen to fall back to.
    let onManualSetup: (() -> Void)?
    let isCommitting: Bool
    let onChangeIdentity: (() -> Void)?
    let onContinue: () -> Void

    @State private var stageIndex = 0
    @State private var traceProgress: Double = 0

    private static let stages = [
        "Checking leaf shape and colour",
        "Ranking the likeliest species",
        "Checking how it's doing"
    ]

    private var isUnknown: Bool { session.result?.identification.isUnknown == true }
    private var isProvisional: Bool {
        session.result?.identification.requiresConfirmation == true && !isUnknown
    }

    var body: some View {
        Group {
            if let captureError {
                // The quality gate is deterministic: only a different photo
                // clears it.
                errorState(message: captureError, kind: .photo)
            } else if case .failed(let message, let kind) = session.state {
                errorState(message: message, kind: kind)
            } else if session.state == .completed, let result = session.result {
                if let guidance = ScanEvidenceRetryGuidance(evidence: result.evidenceQuality) {
                    evidenceRetryState(guidance)
                } else {
                    resolvedState(result)
                }
            } else {
                identifyingState
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if usesOnboardingStyle {
                RoundedRectangle(cornerRadius: GroveTheme.heroRadius, style: .continuous)
                    .fill(OnboardingTheme.forest)
            } else {
                RoundedRectangle(cornerRadius: GroveTheme.heroRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay { ScanPerimeterTrace(progress: traceProgress, visible: traceIsVisible) }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .animation(GroveMotion.reveal, value: session.state)
        .onChange(of: traceTarget) { _, target in advanceTrace(to: target) }
        .onAppear { traceProgress = traceTarget }
        .accessibilityIdentifier("scanLiveResultCard")
    }

    // MARK: Identifying

    private var identifyingState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Identifying")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.9))
            Text(session.state == .saving ? "Saving your photo" : Self.stages[stageIndex])
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .id(stageIndex)
                .transition(.opacity)
        }
        .task {
            // The narration reads forward only, in step with the border trace;
            // looping back to "Reading leaf shape" would contradict a bar that
            // never retreats.
            while !Task.isCancelled && stageIndex < Self.stages.count - 1 {
                try? await Task.sleep(for: .seconds(2.6))
                guard !Task.isCancelled else { break }
                withAnimation(reduceMotion ? .none : GroveMotion.settle) {
                    stageIndex = min(stageIndex + 1, Self.stages.count - 1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Identifying your plant")
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: Border trace

    /// Where the border trace should sit right now. Stage-anchored rather than
    /// timed: the bar only claims progress the pipeline has narrated, holds
    /// short of full while the result is genuinely outstanding, and closes the
    /// loop only when the name lands.
    private var traceTarget: Double {
        guard captureError == nil else { return 0 }
        switch session.state {
        case .saving: return 0.15
        case .ready: return 0.22
        case .analysing: return [0.48, 0.7, 0.88][min(stageIndex, Self.stages.count - 1)]
        case .completed: return 1
        case .idle, .failed: return 0
        }
    }

    private var traceIsVisible: Bool {
        guard captureError == nil else { return false }
        switch session.state {
        case .saving, .ready, .analysing: return true
        case .idle, .completed, .failed: return false
        }
    }

    /// The trace only ever moves forward while a scan is live; a failure or
    /// retake snaps it home without a reverse sweep, ready to narrate again.
    private func advanceTrace(to target: Double) {
        guard !reduceMotion, target > traceProgress else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { traceProgress = target }
            if target == 0 { stageIndex = 0 }
            return
        }
        withAnimation(target >= 1 ? .easeOut(duration: 0.4) : GroveMotion.settle) {
            traceProgress = target
        }
    }

    // MARK: Resolved

    /// A failed subject gate needs a different next move from a genuinely
    /// difficult single-plant identity. In particular, never offer to save a
    /// bouquet as one unknown plant: that turns a correct abstention into a bad
    /// care record and makes the scan look as though it simply gave up.
    private func evidenceRetryState(_ guidance: ScanEvidenceRetryGuidance) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                GroveEyebrow(text: guidance.eyebrow, color: .white.opacity(0.8))
                Text(guidance.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(guidance.detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onRetake) {
                GroveCTALabel(title: guidance.actionTitle, systemImage: "camera", onDark: true)
            }
            .buttonStyle(GrovePressStyle())
            .disabled(isCommitting)
            .accessibilityIdentifier("scanLiveCardEvidenceRetake")

            if let onManualSetup {
                Button("Set up without a plant", action: onManualSetup)
                    .font(.subheadline.weight(.semibold))
                    .tint(.white.opacity(0.78))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(isCommitting)
                    .accessibilityIdentifier("scanEvidenceManualSetup")
            }
        }
        .onAppear { Haptics.arrive() }
    }

    private func resolvedState(_ result: PlantAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    GroveEyebrow(text: eyebrow, color: .white.opacity(0.8))
                    Text(
                        isUnknown && unknownContinueTitle != nil
                            ? "Species unconfirmed"
                            : (isUnknown ? "A few look-alikes" : result.identification.commonName)
                    )
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    Text(
                        isUnknown
                            ? "Couldn't name it for certain from this photo."
                            : result.identification.scientificName
                    )
                    .font(.subheadline.italic())
                    .foregroundStyle(.white.opacity(0.72))
                }
                Spacer(minLength: 8)
                if !isUnknown {
                    ConfidenceRing(value: result.identification.confidence)
                }
            }

            careFacts(for: result)
            if result.condition.assessmentAvailable != false,
               let nextAction = result.condition.nextActions.first, !nextAction.isEmpty {
                Text(nextAction)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                Button(action: onContinue) {
                    GroveCTALabel(title: continueTitle(for: result), onDark: true)
                }
                .buttonStyle(GrovePressStyle())
                .disabled(isCommitting)
                .opacity(isCommitting ? 0.68 : 1)
                .accessibilityIdentifier("scanLiveCardContinue")

                HStack(spacing: 18) {
                    if let onChangeIdentity {
                        Button(action: onChangeIdentity) {
                            Text("Change species")
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("changeIdentity")
                    }
                    Button(action: onRetake) {
                        Text("Retake photo")
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
                .font(.subheadline.weight(.semibold))
                .tint(.white.opacity(0.78))
                .frame(maxWidth: .infinity)
                .disabled(isCommitting)
            }
        }
        .onAppear { Haptics.arrive() }
    }

    private var eyebrow: String {
        if isUnknown { return "Not sure yet" }
        if isProvisional { return "Most likely" }
        return mode == .add ? "Ready for your grove" : "Found it"
    }

    private func continueTitle(for result: PlantAnalysisResult) -> String {
        if isCommitting {
            return unknownContinueTitle == nil ? "Adding to your grove…" : "Keeping your baseline…"
        }
        if isUnknown { return unknownContinueTitle ?? "See the closest matches" }
        if isProvisional {
            if mode == .add, unknownContinueTitle == nil { return "Confirm and add plant" }
            return unknownContinueTitle == nil ? "Review this match" : "Keep this match"
        }
        guard mode == .add else { return "See the full results" }
        let name = result.identification.commonName
        if unknownContinueTitle != nil {
            return name.count <= 18 ? "Keep \(name)" : "Keep this plant"
        }
        return name.count <= 18 ? "Add \(name)" : "Add to my grove"
    }

    /// Light · Water · Humidity appear only when Grove holds a checked profile
    /// for this species. Broad dry-down fallbacks are useful internal estimates,
    /// not facts to attribute to an arbitrary plant on a result card.
    @ViewBuilder private func careFacts(for result: PlantAnalysisResult) -> some View {
        let profile = PlantCareProfile(
            commonName: result.identification.commonName,
            scientificName: result.identification.scientificName
        )
        if profile.matchedSpecies {
            Divider().overlay(.white.opacity(0.16))

            HStack(alignment: .top, spacing: 0) {
                careFact(label: "Light", value: profile.light, artwork: "ScanCareLight")
                careFact(label: "Water", value: profile.wateringShort, artwork: "ScanCareWater")
                careFact(label: "Humidity", value: profile.humidity, artwork: "ScanCareHumidity")
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func careFact(label: String, value: String, artwork: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(artwork)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)

                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Error

    /// One sentence, one obvious next move.
    ///
    /// The alert glyph and centred text this replaced read as a system dialog
    /// dropped onto a photo, and it offered "Try again" for failures a second
    /// tap could never fix. The mark now sits in its own disc at the head of a
    /// left-ranged sentence — the same shape as the resolved card — and the
    /// actions follow what the failure actually allows.
    private func errorState(message: String, kind: ScanFailureKind) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol(for: kind))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)

                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 8) {
                if kind.isRetryable {
                    Button(action: onRetry) {
                        GroveCTALabel(title: "Try again", systemImage: "arrow.clockwise", onDark: true)
                    }
                    .buttonStyle(GrovePressStyle())
                    .accessibilityIdentifier("scanLiveCardRetry")

                    Button(action: onRetake) {
                        Text("Retake photo")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(.white.opacity(0.75))
                } else if kind == .limit {
                    // Nothing here can succeed today, and the photo is kept, so
                    // the only honest control is one that leaves without
                    // throwing that photo away.
                    Button(action: onKeepForLater) {
                        GroveCTALabel(title: "Keep it for tomorrow", systemImage: "tray.and.arrow.down", onDark: true)
                    }
                    .buttonStyle(GrovePressStyle())
                    .accessibilityIdentifier("scanLiveCardKeepForLater")

                    // Without this, a brand-new guest who meets the ceiling on
                    // their first plant has no route into Grove at all today:
                    // Welcome's primary offers the saved photo back, and that
                    // lands on this exact card again.
                    if let onManualSetup {
                        Button("Set up without a plant", action: onManualSetup)
                            .font(.subheadline.weight(.semibold))
                            .tint(.white.opacity(0.75))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .accessibilityIdentifier("scanLimitManualSetup")
                    }
                } else {
                    Button(action: onRetake) {
                        GroveCTALabel(title: "Retake photo", systemImage: "camera", onDark: true)
                    }
                    .buttonStyle(GrovePressStyle())
                    .accessibilityIdentifier("scanLiveCardRetake")
                }
            }
        }
        .onAppear { Haptics.warning() }
    }

    private func symbol(for kind: ScanFailureKind) -> String {
        switch kind {
        case .connection: "wifi.slash"
        case .service: "arrow.triangle.2.circlepath"
        case .photo: "camera.metering.unknown"
        case .limit: "hourglass"
        }
    }
}

/// The identification card's border doing the progress work: twin white
/// traces leave the top centre together — right above the IDENTIFYING label —
/// walk down both sides of the card as the scan advances, and meet at the
/// bottom the moment the name lands. White is Grove's on-photo progress
/// colour, same as the confidence ring the reveal resolves into.
private struct ScanPerimeterTrace: View {
    /// 0…1, where 1 means both traces have met at the bottom centre.
    let progress: Double
    let visible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GroveTheme.heroRadius, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 3)

            Group {
                halfTrace
                halfTrace.scaleEffect(x: -1)
            }
            // Liveness while the bar holds at its last anchor waiting on the
            // network — the breath says "working", without inventing progress.
            .opacity(breathing ? 0.68 : 1)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                value: breathing
            )
        }
        .opacity(visible ? 1 : 0)
        // On completion the loop closes first, holds a beat, then the light
        // goes out as the card blooms into the result.
        .animation(.easeOut(duration: 0.5).delay(visible ? 0 : 0.45), value: visible)
        .onAppear { breathing = !reduceMotion }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var halfTrace: some View {
        ScanCardHalfPerimeter(cornerRadius: GroveTheme.heroRadius)
            .trim(from: 0, to: progress)
            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }
}

/// The right half of the card's rounded border, drawn top centre → bottom
/// centre, so a trimmed stroke grows along it and its mirror symmetrically.
private struct ScanCardHalfPerimeter: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
            radius: radius,
            startAngle: .degrees(270),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

private func demoScanImage() -> UIImage {
    if let photo = DemoPlantPhotos.sampleScanImage() { return photo }
    let size = CGSize(width: 900, height: 1200)
    return UIGraphicsImageRenderer(size: size).image { context in
        UIColor(red: 0.09, green: 0.34, blue: 0.18, alpha: 1).setFill()
        context.cgContext.fill(CGRect(origin: .zero, size: size))
        UIImage(systemName: "leaf.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
            .draw(in: CGRect(x: 190, y: 340, width: 520, height: 520))
    }
}

private struct ScanChoiceButton: View {
    let artwork: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(artwork)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline.weight(.bold)).foregroundStyle(.white)
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(14)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
        }
        .buttonStyle(GrovePressStyle())
    }
}

struct ScanResultView: View {
    @Environment(ScanSession.self) private var session
    @Environment(GroveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let mode: ScanMode
    var plantID: UUID? = nil

    private var existingPlant: Plant? { plantID.flatMap(store.plant(id:)) }
    private var belongsToActiveSession: Bool {
        session.mode == mode && session.existingPlantID == plantID
    }

    var body: some View {
        Group {
            if belongsToActiveSession {
                switch session.state {
            case .analysing, .saving:
                ScanAnalysingView(image: session.previewImage)
            case .completed:
                if let result = session.result {
                    if mode == .diagnose {
                        DiagnosisResultContent(result: result, plantID: plantID)
                    } else {
                        ResultContent(mode: mode, result: result, plantID: plantID)
                    }
                }
            case .failed(let message, let kind):
                GroveEmptyState(
                    scene: kind == .photo ? .noPhoto : .severed,
                    title: failureTitle(for: kind),
                    message: message
                ) {
                    // Retrying a rejected photo re-reads the same pixels and
                    // fails identically; a ceiling resets tomorrow. Neither
                    // gets a button that pretends otherwise.
                    if kind.isRetryable {
                        GroveInkButton(title: "Try again", systemImage: "arrow.clockwise", size: .compact) {
                            Task { await session.retry(regionCode: store.profile.regionCode, existingPlant: existingPlant) }
                        }
                    } else if kind == .photo {
                        GroveInkButton(title: "Take another photo", systemImage: "camera", size: .compact) {
                            dismiss()
                        }
                    } else {
                        GroveInkButton(title: "Done for today", systemImage: "checkmark", size: .compact) {
                            dismiss()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                GroveEmptyState(
                    scene: .noPhoto,
                    title: "No photo yet",
                    message: "Go back and photograph the plant first."
                ) {
                    GroveCTAButton(title: "Open camera") {
                        dismiss()
                    }
                    .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                GroveEmptyState(
                    scene: .noPhoto,
                    title: "Scan no longer available",
                    message: "This page belongs to an earlier scan. Go back to continue the current one."
                ) {
                    GroveCTAButton(title: "Go back") { dismiss() }
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .groveBackground()
        .modifier(ScanResultChrome(
            title: mode == .diagnose ? "Diagnosis" : "Scan result",
            showsTitle: !showsPhotoSheet
        ))
        .task {
            if belongsToActiveSession, session.state == .ready {
                await session.analyse(regionCode: store.profile.regionCode, existingPlant: existingPlant)
            }
        }
    }

    /// The identification result runs its photo up under the bar, where a
    /// centred title would sit on the picture.
    private var showsPhotoSheet: Bool {
        belongsToActiveSession
            && mode != .diagnose
            && session.state == .completed
            && session.result != nil
    }

    /// Names the failure so the page isn't three different problems wearing the
    /// same "Analysis paused" hat.
    private func failureTitle(for kind: ScanFailureKind) -> String {
        switch kind {
        case .connection: "You're offline"
        case .service: "Can't analyse right now"
        case .photo: "Couldn't read this photo"
        case .limit: "You've used today's scans"
        }
    }
}

/// The result page's bar. Over the photo it keeps the screen's name for Back
/// and VoiceOver but draws nothing in the centre.
private struct ScanResultChrome: ViewModifier {
    let title: String
    let showsTitle: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if showsTitle {
            content.groveEditorialPage(title)
        } else {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityHidden(true)
                    }
                }
        }
    }
}

/// Diagnosis has a different information job from identification.
///
/// The generic result page leads with species and confidence. Here the answer
/// someone came for is instead: what Grove noticed, why it may be happening,
/// and what to do next. The compact evidence card and numbered recovery rail
/// keep that answer readable at a glance while the expandable evidence and
/// follow-up questions preserve the uncertainty a photo-only assessment needs.
private struct DiagnosisResultContent: View {
    @Environment(GroveStore.self) private var store
    @Environment(ScanSession.self) private var session
    @Environment(NotificationService.self) private var notifications
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let result: PlantAnalysisResult
    let plantID: UUID?

    @State private var diagnosisApplied = false
    @State private var reminderEnabled = false
    @State private var isSavingDiagnosis = false
    @State private var saveError: String?
    @State private var showEvidence = false
    @State private var revealed = false
    /// Permission alone was never enough to promise a reminder: with this switch
    /// off, `NotificationService` skips every care task, so the button below sat
    /// on a checkmark saying "Recovery reminder set" while nothing was scheduled.
    @AppStorage(GroveDefaults.careReminders) private var careReminders = true

    private var condition: PlantConditionResult { result.condition }
    private var leadingCondition: PlantConditionCandidate? {
        condition.possibleConditions?.first
    }
    private var isActionable: Bool {
        condition.actionability == nil || condition.actionability == .actionable
    }
    private var assessmentAvailable: Bool { condition.assessmentAvailable != false }
    private var hasVisibleIssue: Bool {
        assessmentAvailable
            && (!condition.concerns.isEmpty
                || !(condition.possibleConditions ?? []).isEmpty
                || condition.healthBand == .attention
                || condition.healthBand == .urgent)
    }
    private var issueTitle: String {
        if !assessmentAvailable { return "A clearer photo is needed" }
        if !hasVisibleIssue { return "No obvious issue in these photos" }
        return leadingCondition?.name ?? condition.healthBand.title
    }
    private var followUpDays: Int {
        min(max(condition.followUpDays ?? GroveStore.defaultFollowUpDays(for: condition.healthBand), 1), 30)
    }
    private var likelihoodLabel: String {
        switch leadingCondition?.confidence ?? condition.confidence {
        case 85...: "Very likely"
        case 65...: "Likely"
        case 45...: "Possible"
        default: "Worth checking"
        }
    }
    private var issueSymbol: String {
        let issue = "\(leadingCondition?.id ?? "") \(issueTitle) \(condition.possibleCauses.joined(separator: " "))"
            .lowercased()
        if issue.contains("moisture") || issue.contains("water") { return "drop.fill" }
        if issue.contains("pest") || issue.contains("mite") || issue.contains("aphid") { return "ladybug.fill" }
        if issue.contains("light") || issue.contains("sun") { return "sun.max.fill" }
        return condition.healthBand.icon
    }
    private var signs: String {
        let visibleSigns = condition.concerns.isEmpty
            ? (leadingCondition?.evidence ?? [])
            : condition.concerns
        return visibleSigns.isEmpty
            ? "No single visible sign is conclusive from this photo."
            : visibleSigns.prefix(3).joined(separator: " · ")
    }
    private var ariSummary: String {
        AriScanTakeaway.twoSentence(
            condition: condition.summary,
            nextAction: condition.nextActions.first,
            nickname: result.identification.commonName,
            healthBand: condition.healthBand
        )
    }
    private var shareText: String {
        let causeConfidence = leadingCondition?.confidence ?? condition.confidence
        var lines = [
            "Grove photo assessment: \(issueTitle)",
            "\(likelihoodLabel) · \(causeConfidence)% cause confidence",
            "Photo evidence: \(condition.confidence)%"
        ]
        if assessmentAvailable, !condition.summary.isEmpty {
            lines.append(ariSummary)
        }
        if !isActionable {
            lines.append("Provisional. This result hasn't changed the plant's care plan.")
        }
        if !condition.nextActions.isEmpty {
            lines.append("Next: \(condition.nextActions.prefix(3).joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                issueCard
                    .revealStep(0, revealed: revealed, reduceMotion: reduceMotion)

                if let flags = condition.urgentFlags, !flags.isEmpty {
                    urgentCard(flags)
                        .revealStep(1, revealed: revealed, reduceMotion: reduceMotion)
                }

                evidenceCard
                    .revealStep(2, revealed: revealed, reduceMotion: reduceMotion)

                questionCard
                    .revealStep(3, revealed: revealed, reduceMotion: reduceMotion)

                recoveryPlan
                    .revealStep(4, revealed: revealed, reduceMotion: reduceMotion)

                diagnosisEvidence
                    .revealStep(5, revealed: revealed, reduceMotion: reduceMotion)

                limitations
                    .revealStep(6, revealed: revealed, reduceMotion: reduceMotion)
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom) { dockedActionBar }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GroveTheme.ink)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Share diagnosis")
            }
        }
        .onAppear {
            guard !revealed else { return }
            revealed = true
            Haptics.arrive()
        }
        .task(id: result) {
            guard session.mode == .diagnose, session.existingPlantID == plantID else { return }
            diagnosisApplied = false
            reminderEnabled = false
            saveError = nil
            guard let draft = session.draft else { return }
            let archivedURL = await session.archivePrimaryForHistory() ?? draft.fileURL
            guard !Task.isCancelled else { return }
            store.recordScan(
                id: session.scanID,
                mode: .diagnose,
                result: result,
                photoURL: archivedURL,
                plantID: plantID
            )
            // A diagnosis about an existing plant is current plant evidence,
            // not an optional bookmark. Apply it as soon as the result lands so
            // the result page, plant page, timeline and care queue cannot tell
            // four different stories. The scan ID makes this safe to repeat
            // when the view is recreated or the result is refined.
            if let plantID {
                diagnosisApplied = store.addDiagnosis(
                    id: session.scanID,
                    plantID: plantID,
                    result: result,
                    photoURL: archivedURL
                ) != nil
                if diagnosisApplied, let updated = store.plant(id: plantID) {
                    await syncEngine.enqueue(
                        .updatePlant(UpdatePlantRequest(
                            plant: updated,
                            clientRequestID: UUID(),
                            diagnoses: store.diagnoses(for: plantID).map(\.withoutLocalPhoto)
                        )),
                        isConnected: connectivity.isConnected
                    )
                }
                if diagnosisApplied && isActionable {
                    await notifications.refreshAuthorization()
                    reminderEnabled = notifications.authorization.canSchedule && careReminders
                } else {
                    saveError = "Grove couldn't update this plant. Try again in a moment."
                }
            }
        }
        .accessibilityIdentifier("diagnosisResult")
    }

    // MARK: Result at a glance

    private var issueCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                GroveEyebrow(text: "What the scan found", color: GroveTheme.warning)
                Spacer()
                Label(
                    !assessmentAvailable
                        ? "More evidence needed"
                        : (!hasVisibleIssue ? "No obvious issue" : (isActionable ? "Issue detected" : "Provisional diagnosis")),
                    systemImage: !assessmentAvailable
                        ? "camera.badge.ellipsis"
                        : (!hasVisibleIssue ? "checkmark.circle.fill" : "viewfinder")
                )
                    .font(.caption.weight(.bold))
                    .foregroundStyle(!hasVisibleIssue && assessmentAvailable ? GroveTheme.accentStrong : GroveTheme.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(GroveTheme.surface.opacity(0.72), in: Capsule())
            }

            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(issueTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(GroveTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Label(
                        leadingCondition.map {
                            "\(likelihoodLabel) · \($0.confidence)% cause confidence"
                        } ?? "Photo evidence · \(condition.confidence)%",
                        systemImage: "seal.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GroveTheme.warning)
                }

                Spacer(minLength: 8)

                Image(systemName: issueSymbol)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(GroveTheme.warning)
                    .frame(width: 58, height: 58)
                    .background(GroveTheme.surface, in: Circle())
                    .overlay { Circle().stroke(GroveTheme.warning.opacity(0.24), lineWidth: 1) }
                    .groveShadow(.resting)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 7) {
                Image(systemName: "leaf.fill")
                    .foregroundStyle(GroveTheme.accentStrong)
                Text(result.identification.commonName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GroveTheme.mutedInk)
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [GroveTheme.warning.opacity(0.17), GroveTheme.warning.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                .strokeBorder(GroveTheme.warning.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("diagnosisIssueCard")
    }

    private func urgentCard(_ flags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Do these first", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(GroveTheme.danger)
            ForEach(flags, id: \.self) { flag in
                Label(flag, systemImage: "circle.fill")
                    .font(.subheadline)
            }
        }
        .groveCard()
    }

    private var evidenceCard: some View {
        VStack(spacing: 0) {
            DiagnosisEvidenceRow(
                title: "Signs",
                detail: signs,
                symbol: "leaf.fill",
                image: session.previewImage,
                imageAlignment: .top
            )

            if assessmentAvailable, !condition.summary.isEmpty {
                Divider().padding(.leading, 18)

                DiagnosisEvidenceRow(
                    title: "Diagnosis",
                    detail: ariSummary,
                    symbol: "allergens.fill",
                    image: session.previewImage,
                    imageAlignment: .bottom
                )
            }
        }
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                .strokeBorder(GroveTheme.separator, lineWidth: 1)
        }
    }

    // MARK: Recovery

    private var recoveryPlan: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                GroveEyebrow(
                    text: isActionable ? "Recovery plan" : "Safe while we narrow this down",
                    color: GroveTheme.accentStrong
                )
                Text(isActionable ? "What to do next" : "Low-risk next checks")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .accessibilityAddTraits(.isHeader)
            }

            if !isActionable {
                Text("This photo assessment is provisional. It's saved for review and hasn't changed the plant's health score, care plan or reminders.")
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
            }

            let actions = condition.nextActions.isEmpty
                ? ["Keep care steady and compare the plant with a fresh photo."]
                : condition.nextActions
            VStack(spacing: 0) {
                ForEach(Array(actions.prefix(5).enumerated()), id: \.offset) { index, action in
                    RecoveryStepRow(
                        number: index + 1,
                        text: action,
                        isLast: index == min(actions.count, 5) - 1
                    )
                }
            }

            if let avoid = condition.actionsToAvoid, !avoid.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Avoid for now", systemImage: "hand.raised.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(GroveTheme.danger)
                    ForEach(avoid.prefix(3), id: \.self) { action in
                        Text(action)
                            .font(.footnote)
                            .foregroundStyle(GroveTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GroveTheme.danger.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                )
            }

            Label(
                "Check again in \(followUpDays) \(followUpDays == 1 ? "day" : "days")",
                systemImage: "calendar.badge.clock"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(GroveTheme.accentStrong)
        }
        .groveCard()
        .accessibilityIdentifier("diagnosisRecoveryPlan")
    }

    // MARK: Sharpen the result

    private var questionCard: some View {
        DiagnosisQuestionsCard(questions: condition.questions ?? [], plantID: plantID)
    }

    @ViewBuilder private var diagnosisEvidence: some View {
        let candidates = condition.possibleConditions ?? []
        if !candidates.isEmpty {
            DisclosureGroup(isExpanded: $showEvidence) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        ConditionCandidateRow(condition: candidate, rank: index + 1)
                        if index < candidates.count - 1 { Divider() }
                    }
                }
                .padding(.top, 14)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Why this is our best match")
                        .font(.headline)
                    Text("Evidence and other possibilities")
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
            }
            .tint(GroveTheme.accentStrong)
            .groveCard()
        }
    }

    private var limitations: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("A photo can point to a cause, not prove it.", systemImage: "info.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GroveTheme.mutedInk)
            ForEach(result.limitations, id: \.self) { limitation in
                Text(limitation)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.subtleInk)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Docked action

    @ViewBuilder private var dockedActionBar: some View {
        VStack(spacing: 9) {
            if plantID != nil {
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.danger)
                }
                if isActionable {
                    Button {
                        enableRecoveryReminder()
                    } label: {
                        GroveCTALabel(
                            title: reminderEnabled
                                ? "Recovery reminder set"
                                : (
                                    isSavingDiagnosis
                                        ? "Setting recovery reminder…"
                                        : (diagnosisApplied ? "Set recovery reminder" : "Updating plant page…")
                                ),
                            systemImage: reminderEnabled ? "checkmark" : "bell.badge.fill"
                        )
                    }
                    .buttonStyle(GrovePressStyle())
                    .disabled(reminderEnabled || isSavingDiagnosis || !diagnosisApplied)
                    .opacity(reminderEnabled || isSavingDiagnosis || !diagnosisApplied ? 0.68 : 1)
                    .accessibilityIdentifier("setRecoveryReminder")
                }
            } else {
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(GroveTheme.danger)
                }
                Button(action: saveRecoveryPlant) {
                    GroveCTALabel(
                        title: isSavingDiagnosis ? "Saving plant…" : "Save plant & track recovery",
                        systemImage: "plus"
                    )
                }
                .buttonStyle(GrovePressStyle())
                .disabled(isSavingDiagnosis)
                .accessibilityIdentifier("trackDiagnosisRecovery")
            }

            Label(
                plantID == nil
                    ? "Diagnosis saved to scan history"
                    : (
                        diagnosisApplied
                            ? (
                                isActionable
                                    ? "Diagnosis saved and plant page updated"
                                    : "Provisional assessment saved; plant plan unchanged"
                            )
                            : "Saving diagnosis to this plant"
                    ),
                systemImage: "checkmark.circle.fill"
            )
            .font(.footnote.weight(.bold))
            .foregroundStyle(GroveTheme.accentStrong)
        }
        .groveActionBar()
    }

    private func saveRecoveryPlant() {
        guard !isSavingDiagnosis else { return }
        guard let adoption = ScanPlantAdoption.prepare(session: session, store: store) else {
            saveError = "Your plant couldn't be saved yet. Try again."
            return
        }
        isSavingDiagnosis = true
        saveError = nil
        Haptics.celebrate()
        IntentRouter.shared.openPlant(adoption.plant.id)
        Task {
            await adoption.persist(session: session, store: store, syncEngine: syncEngine, connectivity: connectivity)
            isSavingDiagnosis = false
        }
    }

    private func enableRecoveryReminder() {
        guard isActionable, !isSavingDiagnosis, diagnosisApplied, !reminderEnabled else { return }
        isSavingDiagnosis = true
        saveError = nil

        Task {
            await notifications.refreshAuthorization()
            if notifications.authorization == .notDetermined {
                await notifications.requestAuthorization()
            }
            if notifications.authorization.canSchedule {
                // Someone who just asked for this specific reminder has answered
                // the question the switch asks. Turning it on for them beats
                // sending them to Settings to find a control they never saw.
                careReminders = true
                reminderEnabled = true
                Haptics.celebrate()
            } else {
                saveError = "Notifications are off. You can enable them for Grove in Settings."
            }
            isSavingDiagnosis = false
        }
    }
}

private struct DiagnosisEvidenceRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let detail: String
    let symbol: String
    let image: UIImage?
    let imageAlignment: Alignment

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) {
                    text
                    photo
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 14) {
                    text
                    photo
                }
            }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(GroveTheme.ink)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var photo: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 104, height: 88, alignment: imageAlignment)
            } else {
                ZStack {
                    GroveTheme.softAccent
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(GroveTheme.accent)
                }
                .frame(width: 104, height: 88)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                .stroke(GroveTheme.separator, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

private struct RecoveryStepRow: View {
    let number: Int
    let text: String
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 0) {
                Text("\(number)")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(GroveTheme.accentStrong)
                    .frame(width: 30, height: 30)
                    .background(GroveTheme.softAccent, in: Circle())

                if !isLast {
                    Rectangle()
                        .fill(GroveTheme.accent.opacity(0.28))
                        .frame(width: 2, height: 34)
                }
            }
            .accessibilityHidden(true)

            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
                .padding(.bottom, isLast ? 0 : 15)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number). \(text)")
    }
}

#if DEBUG
private struct DiagnosisResultPreview: View {
    @State private var result: PlantAnalysisResult?
    private let store = GroveStore(persistenceEnabled: false)
    private let session = ScanSession()
    private let notifications = NotificationService()

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    DiagnosisResultContent(
                        result: result,
                        plantID: store.plants.first?.id
                    )
                } else {
                    ProgressView("Preparing diagnosis")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .groveBackground()
            .groveEditorialPage("Diagnosis")
        }
        .environment(store)
        .environment(session)
        .environment(notifications)
        .task {
            result = try? await LocalPlantAnalysisClient(simulatedDelay: .zero)
                .analyse(imageData: Data([0x01]), mode: .diagnose)
        }
    }
}

#Preview("Diagnosis result") {
    DiagnosisResultPreview()
}
#endif

private struct SpeciesSearchPresentation: Identifiable {
    let id = "species-search"
}

private struct ResultContent: View {
    @Environment(GroveStore.self) private var store
    @Environment(ScanSession.self) private var session
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    let mode: ScanMode
    let result: PlantAnalysisResult
    let plantID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchPresentation: SpeciesSearchPresentation?
    @State private var savedDiagnosis = false
    @State private var isSavingDiagnosis = false
    @State private var diagnosisSaveError: String?
    @State private var isAddingPlant = false
    @State private var adoptionError: String?
    @State private var revealed = false
    @State private var selectedCandidateID: String?

    private var isUnknown: Bool { result.identification.isUnknown == true }
    private var isProvisional: Bool { result.identification.requiresConfirmation == true && !isUnknown }
    /// Unknown and provisional matches both need an explicit identity decision
    /// before species-dependent care can be treated as established.
    private var mustResolveIdentity: Bool { isUnknown || isProvisional }

    private var candidates: [SpeciesCandidate] {
        if result.identification.isUnknown == true {
            return result.identification.candidates ?? []
        }
        return result.identification.candidates ?? [
            SpeciesCandidate(
                id: result.identification.scientificName.lowercased().replacingOccurrences(of: " ", with: "-"),
                commonName: result.identification.commonName,
                scientificName: result.identification.scientificName,
                confidence: result.identification.confidence,
                distinguishingTraits: result.identification.distinguishingTraits,
                regionalFit: nil
            )
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScanResultHero(result: result, image: session.previewImage)
                    .revealStep(0, revealed: revealed, reduceMotion: reduceMotion)

                // The white sheet rises over the photo: identity first, then
                // the facts a plant person checks, then everything else.
                VStack(alignment: .leading, spacing: 0) {
                    identityHeadline
                        .padding(.horizontal, GroveTheme.pagePadding)
                        .revealStep(1, revealed: revealed, reduceMotion: reduceMotion)

                    if !mustResolveIdentity && mode != .diagnose {
                        CaptureStatGrid(stats: careStats)
                            .padding(.horizontal, GroveTheme.pagePadding)
                            .padding(.top, 22)
                            .revealStep(2, revealed: revealed, reduceMotion: reduceMotion)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        if isUnknown {
                            UnknownPlantCard()
                                .revealStep(2, revealed: revealed, reduceMotion: reduceMotion)
                        }

                        if mustResolveIdentity {
                            // Naming the plant is the user's one job here, so it
                            // leads; everything downstream depends on it being right.
                            identityCard
                                .revealStep(3, revealed: revealed, reduceMotion: reduceMotion)
                        } else {
                            otherMatchesCard
                                .revealStep(3, revealed: revealed, reduceMotion: reduceMotion)
                        }

                        conditionCard
                            .revealStep(4, revealed: revealed, reduceMotion: reduceMotion)

                        if mode != .diagnose, plantID == nil {
                            forecastCard
                                .revealStep(5, revealed: revealed, reduceMotion: reduceMotion)
                        }

                        if mode == .diagnose {
                            Group {
                                urgentFlagsCard
                                diagnosisQuestions
                                possibleConditions
                                actionSections
                            }
                            .revealStep(5, revealed: revealed, reduceMotion: reduceMotion)
                        }

                        Label("Saved to scan history", systemImage: "checkmark.circle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(GroveTheme.mutedInk)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 26)
                    .padding(.bottom, 16)
                }
                .padding(.top, 28)
                .captureSheet()
                .padding(.top, -30)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(GroveTheme.surface.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { dockedActionBar }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { shareButton }
        }
        .sheet(item: $searchPresentation) { _ in
            NavigationStack { SpeciesSearchView() }
        }
        .onAppear {
            guard !revealed else { return }
            revealed = true
            // The result landing is the payoff for the wait, so it arrives
            // rather than merely reporting success.
            Haptics.arrive()
        }
        .task(id: result) {
            // This view can survive beneath later scan routes on the same
            // stack (identify → add → diagnose …). Only the layer whose route
            // still matches the live session may record — a stale layer would
            // re-record the newest result under its own mode and plant,
            // corrupting the history entry.
            guard session.mode == mode, session.existingPlantID == plantID else { return }
            // A re-analysis (e.g. "Refine with my answers") is a new result
            // that has not been saved to the timeline yet.
            savedDiagnosis = false
            diagnosisSaveError = nil
            guard let draft = session.draft else { return }
            let archivedURL = await session.archivePrimaryForHistory() ?? draft.fileURL
            guard !Task.isCancelled else { return }
            store.recordScan(id: session.scanID, mode: mode, result: result, photoURL: archivedURL, plantID: plantID)
        }
    }

    // MARK: The reveal

    private var identityHeadline: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptureStatusLine(text: statusText, tint: statusTint)
            Text(result.identification.commonName)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(result.identification.scientificName)
                .font(.body.italic())
                .foregroundStyle(GroveTheme.mutedInk)
        }
    }

    /// The confidence line above the name. A weak or provisional match says
    /// so in amber rather than borrowing the green of a settled one.
    private var statusText: String {
        let confidence = result.identification.confidence
        if isUnknown { return "Not sure yet" }
        if isProvisional { return "Most likely · \(confidence)% match" }
        return "\(confidence)% match"
    }

    private var statusTint: Color {
        mustResolveIdentity ? GroveTheme.warning : GroveTheme.healthThriving
    }

    @ViewBuilder private var shareButton: some View {
        if let image = session.previewImage, !isUnknown {
            ShareLink(
                item: Image(uiImage: image),
                preview: SharePreview(result.identification.commonName, image: Image(uiImage: image))
            ) {
                CaptureGlassChip(systemImage: "square.and.arrow.up")
            }
            .accessibilityLabel("Share this find")
        }
    }

    // MARK: Facts

    /// The checked care profile only speaks for species Grove has reviewed;
    /// safety and the first check-in apply to any named plant.
    private var careStats: [CaptureStat] {
        var stats: [CaptureStat] = []
        let profile = PlantCareProfile(
            commonName: result.identification.commonName,
            scientificName: result.identification.scientificName
        )
        if profile.matchedSpecies {
            stats.append(CaptureStat(label: "Light", value: Self.headline(of: profile.light)))
            stats.append(CaptureStat(label: "Water", value: Self.headline(of: profile.wateringShort)))
            stats.append(CaptureStat(label: "Humidity", value: Self.headline(of: profile.humidity)))
        }
        stats.append(petsStat)
        if result.condition.assessmentAvailable != false {
            stats.append(CaptureStat(
                label: "Looks",
                value: result.condition.healthBand.shortTitle,
                tint: result.condition.healthBand.color
            ))
        }
        stats.append(CaptureStat(label: "First check-in", value: firstCheckInDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))))
        return stats
    }

    /// Care strings read "headline; detail". A stat cell has room for the
    /// headline, and the headline is the part that answers the question.
    private static func headline(of text: String) -> String {
        let head = text.split(separator: ";", maxSplits: 1).first.map(String.init) ?? text
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pets and children share one cell. The label and value match the plant
    /// page, so a scan cannot say "Pets" while the saved plant says "Pets &
    /// children". A photo match never earns a reassuring verdict on its own —
    /// the default confirmation is still `.photoMatch` until the user confirms.
    private var petsStat: CaptureStat {
        let safety = PlantSafety(identification: result.identification)
        let tint: Color
        switch safety.cautionLevel {
        case .none: tint = GroveTheme.ink
        case .caution: tint = GroveTheme.warning
        case .danger: tint = GroveTheme.danger
        }
        return CaptureStat(label: "Pets & children", value: safety.shortLabel, tint: tint)
    }

    /// Mirrors `GroveStore.addPlant`, which books the first check-in early so a
    /// new owner sees a comparison within days.
    private var firstCheckInDays: Int {
        GroveStore.firstCheckInDays(
            analysisDays: result.condition.followUpDays,
            band: result.condition.healthBand
        )
    }

    private var firstCheckInDate: Date {
        Calendar.current.date(byAdding: .day, value: firstCheckInDays, to: .now) ?? .now
    }

    /// The less likely species from the same photo, for a settled match.
    @ViewBuilder private var otherMatchesCard: some View {
        let alternatives = Array(
            (result.identification.candidates ?? [])
                .filter { $0.scientificName != result.identification.scientificName }
                .prefix(3)
        )
        if !alternatives.isEmpty {
            CaptureCard(title: "Other matches", subtitle: "Less likely, from the same photo") {
                VStack(spacing: 0) {
                    ForEach(Array(alternatives.enumerated()), id: \.element.id) { index, candidate in
                        CaptureListRow(
                            title: candidate.commonName,
                            detail: candidate.scientificName,
                            trailing: "\(candidate.confidence)%",
                            isLast: index == alternatives.count - 1
                        )
                    }
                    Button("Choose a different plant") {
                        searchPresentation = SpeciesSearchPresentation()
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(GroveTheme.accentStrong)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .overlay(alignment: .top) {
                        Rectangle().fill(GroveTheme.separator).frame(height: 1)
                    }
                    .accessibilityIdentifier("scanResultChooseDifferent")
                }
            }
        }
    }

    /// What adopting this plant would set in motion, in dates.
    private var forecastCard: some View {
        CaptureCard(title: "If you add it") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your first check-in is \(firstCheckInDate.formatted(.dateTime.weekday(.wide).day().month(.wide))). That photo lines up against this one.")
                    .font(.body)
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if result.condition.assessmentAvailable != false,
                   let action = result.condition.nextActions.first, !action.isEmpty {
                    Text(action)
                        .font(.body)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
    }

    // MARK: Docked call to action

    /// The name already sits in large type directly above, so the button
    /// says what it does rather than repeating it.
    private var primaryCTATitle: String {
        if isAddingPlant { return "Adding to your grove…" }
        if isProvisional { return "Confirm and add plant" }
        if isUnknown { return "Add as an unknown plant" }
        return "Add to my grove"
    }

    /// The conversion moment stays on screen instead of hiding at scroll-end.
    @ViewBuilder private var dockedActionBar: some View {
        VStack(spacing: 10) {
            if let plantID, mode == .diagnose {
                if let diagnosisSaveError {
                    Text(diagnosisSaveError).font(.caption).foregroundStyle(GroveTheme.danger)
                }
                Button {
                    isSavingDiagnosis = true
                    diagnosisSaveError = nil
                    Task {
                        let photoURL = await session.archivePrimaryForHistory()
                        savedDiagnosis = store.addDiagnosis(plantID: plantID, result: result, photoURL: photoURL) != nil
                        if savedDiagnosis, let updated = store.plant(id: plantID) {
                            await syncEngine.enqueue(
                                .updatePlant(UpdatePlantRequest(
                                    plant: updated,
                                    clientRequestID: UUID(),
                                    diagnoses: store.diagnoses(for: plantID).map(\.withoutLocalPhoto)
                                )),
                                isConnected: connectivity.isConnected
                            )
                        }
                        if !savedDiagnosis { diagnosisSaveError = "Grove couldn't add this to the plant's timeline. Try again in a moment." }
                        isSavingDiagnosis = false
                    }
                } label: {
                    GroveCTALabel(
                        title: savedDiagnosis ? "Added to plant timeline" : (isSavingDiagnosis ? "Saving diagnosis…" : "Add to plant timeline"),
                        systemImage: savedDiagnosis ? "checkmark" : "clock.badge.plus"
                    )
                }
                .buttonStyle(GrovePressStyle())
                .disabled(savedDiagnosis || isSavingDiagnosis)
                .opacity(savedDiagnosis || isSavingDiagnosis ? 0.6 : 1)
                .accessibilityIdentifier("addDiagnosisToTimeline")
            } else {
                // The scan is never a dead end: even an unnamed plant can be
                // kept and tracked, with care advice held back until it has a
                // name. Blocking the button here read as "we couldn't do it".
                if let adoptionError {
                    Text(adoptionError)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.danger)
                }
                Button {
                    if isProvisional {
                        confirmSelectedCandidate()
                    } else {
                        adoptPlant()
                    }
                } label: {
                    GroveCTALabel(
                        title: primaryCTATitle,
                        systemImage: isProvisional ? "checkmark" : "arrow.right"
                    )
                }
                .buttonStyle(GrovePressStyle())
                .disabled(isAddingPlant || (isProvisional && candidates.isEmpty))
                .opacity(isAddingPlant || (isProvisional && candidates.isEmpty) ? 0.55 : 1)
                .accessibilityIdentifier(isProvisional ? "confirmIdentityMatch" : "confirmQuickAddPlant")
            }
        }
        .groveActionBar()
    }

    private func adoptPlant() {
        guard !isAddingPlant,
              let adoption = ScanPlantAdoption.prepare(session: session, store: store) else {
            adoptionError = "Grove couldn't add this plant yet. Try again in a moment."
            return
        }
        isAddingPlant = true
        adoptionError = nil
        Haptics.celebrate()
        toasts?.show("\(adoption.plant.nickname) is in your grove", symbol: "leaf.fill")
        IntentRouter.shared.openPlant(adoption.plant.id)
        Task {
            await adoption.persist(
                session: session,
                store: store,
                syncEngine: syncEngine,
                connectivity: connectivity
            )
            isAddingPlant = false
        }
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pick the closest match").font(.headline)
                    Text("Watering and toxicity advice both hang on this being right.")
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                    if let region = result.identification.regionCode {
                        Label("Results adjusted for \(region)", systemImage: "location.fill")
                            .font(.caption)
                            .foregroundStyle(GroveTheme.mutedInk)
                    }
                }
                Spacer()
                Button("Search names") { searchPresentation = SpeciesSearchPresentation() }
                    .font(.subheadline.weight(.semibold))
                    .tint(GroveTheme.accentStrong)
            }

            VStack(spacing: 8) {
                ForEach(Array(candidates.prefix(4).enumerated()), id: \.element.id) { index, candidate in
                    CandidateRow(
                        candidate: candidate,
                        rank: index + 1,
                        isSelected: candidate.id == activeCandidateID
                    ) {
                        selectCandidate(candidate)
                    }
                }
            }

            // An unknown result offers two valid exits: choose one of the
            // candidates here, or keep the plant unknown from the dock. A
            // provisional result has just one next step, so its persistent CTA
            // performs that confirmation without making the user scroll past
            // every alternative first.
            if isUnknown, !candidates.isEmpty {
                GroveInkButton(title: "Confirm and add plant") {
                    confirmSelectedCandidate()
                }
                .accessibilityIdentifier("confirmIdentityMatch")
            }
        }
        .groveCard()
    }

    private var activeCandidateID: String? {
        selectedCandidateID
            ?? candidates.first(where: { $0.scientificName == result.identification.scientificName })?.id
            ?? candidates.first?.id
    }

    private func selectCandidate(_ candidate: SpeciesCandidate) {
        Haptics.selection()
        withAnimation(GroveMotion.snap) { selectedCandidateID = candidate.id }
    }

    private func confirmSelectedCandidate() {
        guard !isAddingPlant else { return }
        guard let candidate = candidates.first(where: { $0.id == activeCandidateID }) ?? candidates.first else { return }
        session.confirmIdentity(candidate)
        adoptPlant()
    }

    private var conditionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroveEyebrow(text: "Scan diagnosis", color: GroveTheme.accentStrong)
            Label(result.condition.healthBand.title, systemImage: result.condition.healthBand.icon)
                .font(.headline)
                .foregroundStyle(result.condition.healthBand.color)
            if result.condition.assessmentAvailable != false, !result.condition.summary.isEmpty {
                Text(
                    AriScanTakeaway.twoSentence(
                        condition: result.condition.summary,
                        nextAction: result.condition.nextActions.first,
                        nickname: result.identification.commonName,
                        healthBand: result.condition.healthBand
                    )
                )
                .font(.subheadline)
            }

            let positives = result.condition.positiveSigns.prefix(3)
            let concerns = result.condition.concerns.prefix(3)
            if !positives.isEmpty || !concerns.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(positives), id: \.self) { sign in
                        Label(sign, systemImage: "arrow.up.right.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(GroveTheme.accentStrong)
                    }
                    ForEach(Array(concerns), id: \.self) { concern in
                        Label(concern, systemImage: "eye.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(GroveTheme.warning)
                    }
                }
                .padding(.top, 2)
            }

            Divider()

            Text("Visual assessment · \(result.condition.confidence)% confidence")
                .font(.caption)
                .foregroundStyle(GroveTheme.mutedInk)
            ForEach(result.limitations, id: \.self) { limitation in
                Label(limitation, systemImage: "info.circle").font(.caption).foregroundStyle(GroveTheme.mutedInk)
            }
        }
        .groveCard()
    }

    @ViewBuilder private var urgentFlagsCard: some View {
        let flags = result.condition.urgentFlags ?? []
        if !flags.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Label("Do these first", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(GroveTheme.danger)
                ForEach(flags, id: \.self) { flag in
                    Label(flag, systemImage: "circle.fill").font(.subheadline)
                }
            }
            .groveCard()
        }
    }

    private var diagnosisQuestions: some View {
        DiagnosisQuestionsCard(questions: result.condition.questions ?? [], plantID: plantID)
    }

    @ViewBuilder private var possibleConditions: some View {
        let conditions = result.condition.possibleConditions ?? []
        if !conditions.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                Text("Possible conditions").font(.headline)
                ForEach(Array(conditions.enumerated()), id: \.element.id) { index, condition in
                    ConditionCandidateRow(condition: condition, rank: index + 1)
                    if index < conditions.count - 1 { Divider() }
                }
            }
            .groveCard()
        }
    }

    private var actionSections: some View {
        VStack(alignment: .leading, spacing: 15) {
            ActionList(title: "What to do", icon: "checkmark.circle.fill", color: GroveTheme.accent, actions: result.condition.nextActions, numbered: true)
            Divider()
            ActionList(title: "What not to do", icon: "xmark.octagon.fill", color: GroveTheme.danger, actions: result.condition.actionsToAvoid ?? [])
        }
        .groveCard()
    }
}

/// The in-flight analysis screen. It is deliberately the *same card* as the
/// result page: identical hero geometry, identical badge slot, and an
/// indeterminate ring sitting exactly where the confidence ring will land — so
/// finishing reads as this screen resolving rather than a new screen arriving.
/// Progress is staged and monotonic; the rail never rewinds, because a bar that
/// goes backwards is the fastest way to make a wait feel broken.
private struct ScanAnalysingView: View {
    let image: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false
    @State private var stage = 0
    @State private var stageFill: CGFloat = 0

    private struct Stage {
        let line: String
        let symbol: String
    }

    private static let stages: [Stage] = [
        Stage(line: "Checking leaf shape, colour and texture", symbol: "leaf.fill"),
        Stage(line: "Ranking the likeliest species", symbol: "list.number"),
        Stage(line: "Looking for signs of trouble", symbol: "magnifyingglass"),
        Stage(line: "Writing your care plan", symbol: "text.badge.checkmark")
    ]
    private static let stageSeconds: Double = 2.8
    /// The last stage holds until the result lands, so it creeps rather than
    /// completes — claiming 100% and then waiting is the lie users notice.
    private static let holdSeconds: Double = 12

    private var isFinalStage: Bool { stage == Self.stages.count - 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroCard

                VStack(alignment: .leading, spacing: 14) {
                    Text("Scanning your plant")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(GroveTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    progressRail
                    stageLine
                }
            }
            .padding(GroveTheme.pagePadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scanning your plant. \(Self.stages[stage].line).")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("scanAnalysingView")
        .task {
            while !Task.isCancelled && !isFinalStage {
                try? await Task.sleep(for: .seconds(Self.stageSeconds))
                guard !Task.isCancelled else { break }
                withAnimation(GroveMotion.settle) { stage += 1 }
            }
        }
        // Restarting the segment sweep needs its own transaction: resetting to
        // zero and animating back up in one synchronous block coalesces into a
        // no-op, and the new segment would snap to full instead of filling.
        .task(id: stage) {
            let target: CGFloat = isFinalStage ? 0.9 : 1
            stageFill = 0
            guard !reduceMotion else {
                stageFill = target
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: isFinalStage ? Self.holdSeconds : Self.stageSeconds)) {
                stageFill = target
            }
        }
    }

    // MARK: Hero

    private var heroCard: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                GroveTheme.softAccent
                Image(systemName: "leaf.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(GroveTheme.accent)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            }
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
        .overlay { if !reduceMotion { scanSweep } }
        .overlay { viewfinderCorners }
        // The same scrim the result hero uses, so the caption sits on identical
        // contrast before and after the swap.
        .overlay {
            LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) { heroCaption }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
        .groveHeroShape()
        .groveShadow(.floating)
        .accessibilityHidden(true)
    }

    private var heroCaption: some View {
        HStack(spacing: 12) {
            IndeterminateRing()
            VStack(alignment: .leading, spacing: 2) {
                Text("Analysing")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.9))
                Text("From the photos you just took")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// Four corner brackets that frame the subject the way a camera reticle
    /// does — the cheapest way to say "something is looking at this".
    private var viewfinderCorners: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 16
            let arm: CGFloat = 26
            ZStack {
                ForEach(0..<4, id: \.self) { corner in
                    ViewfinderCorner()
                        .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: arm, height: arm)
                        .rotationEffect(.degrees(Double(corner) * 90))
                        .position(
                            x: corner == 0 || corner == 3 ? inset + arm / 2 : proxy.size.width - inset - arm / 2,
                            y: corner < 2 ? inset + arm / 2 : proxy.size.height - inset - arm / 2
                        )
                }
            }
            .opacity(sweep || reduceMotion ? 1 : 0.35)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                value: sweep
            )
        }
        .allowsHitTesting(false)
    }

    private var scanSweep: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [
                    GroveTheme.accent.opacity(0),
                    GroveTheme.accent.opacity(0.30),
                    GroveTheme.accent.opacity(0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 110)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(GroveTheme.accent.opacity(0.85))
                    .frame(height: 2)
            }
            .offset(y: sweep ? proxy.size.height - 50 : -60)
            .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: sweep)
        }
        .allowsHitTesting(false)
        .onAppear { sweep = true }
    }

    // MARK: Progress

    private var progressRail: some View {
        HStack(spacing: 5) {
            ForEach(Array(Self.stages.indices), id: \.self) { index in
                Capsule()
                    .fill(GroveTheme.separator)
                    .frame(height: 5)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(GroveTheme.accent)
                                .frame(width: proxy.size.width * width(for: index))
                        }
                    }
            }
        }
        .accessibilityHidden(true)
    }

    private func width(for index: Int) -> CGFloat {
        if index < stage { return 1 }
        if index == stage { return stageFill }
        return 0
    }

    private var stageLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: Self.stages[stage].symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(GroveTheme.accentStrong)
                .frame(width: 18)
            Text(Self.stages[stage].line)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(GroveTheme.mutedInk)
            Spacer(minLength: 0)
        }
        .id(stage)
        .transition(
            .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            )
        )
        // A fixed floor keeps the swap from shunting the layout when one line
        // wraps and the next does not.
        .frame(minHeight: 22, alignment: .top)
        .clipped()
    }
}

/// The corner bracket of a camera reticle, drawn as the top-left arm; callers
/// rotate it into the other three positions.
private struct ViewfinderCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius: CGFloat = 8
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// Stands in for `ConfidenceRing` at the same size and position while the
/// analysis runs, so the badge resolves in place instead of being replaced.
private struct IndeterminateRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.28), lineWidth: 4)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 270 : -90))
                .animation(
                    reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false),
                    value: spinning
                )
        }
        .frame(width: 48, height: 48)
        .onAppear { spinning = true }
        .accessibilityHidden(true)
    }
}

/// The photo you just took, full bleed under the bar. The bottom edge is
/// covered by the result sheet, so only a top scrim is needed to keep the bar
/// readable.
private struct ScanResultHero: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let result: PlantAnalysisResult
    let image: UIImage?

    private var isUnknown: Bool { result.identification.isUnknown == true }
    private var height: CGFloat { dynamicTypeSize.isAccessibilitySize ? 280 : 380 }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(colors: PlantPalette.fern.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.38), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                    .allowsHitTesting(false)
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                isUnknown
                    ? "Photo of your plant. Species unconfirmed."
                    : "Photo of your plant. \(result.identification.confidence) percent match confidence."
            )
    }
}

/// The animated identification-confidence ring that sits on the hero photo.
/// The number is the species-identification confidence, not plant health, so
/// it carries an explicit "ID match" caption and an accessibility label to
/// keep it from being read as a health score. The ring sweep and the rolling
/// number make certainty feel earned rather than asserted — and a short ring
/// is honest about a weak match.
private struct ConfidenceRing: View {
    let value: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(.white.opacity(0.28), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(shown) / 100)
                    .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(shown)%")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText(value: Double(shown)))
            }
            .frame(width: 48, height: 48)
            Text("ID match")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .fixedSize()
        }
        .onAppear {
            if reduceMotion {
                shown = value
            } else {
                withAnimation(.easeOut(duration: 0.9).delay(0.25)) { shown = value }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value)% identification match")
    }
}

/// Staggers the result page's blocks into view so the reveal reads as a
/// sequence — photo, name, then the evidence — instead of a wall of cards.
private struct RevealStep: ViewModifier {
    let index: Int
    let revealed: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : 18)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.2)
                    : GroveMotion.reveal.delay(Double(index) * 0.08),
                value: revealed
            )
    }
}

private extension View {
    func revealStep(_ index: Int, revealed: Bool, reduceMotion: Bool) -> some View {
        modifier(RevealStep(index: index, revealed: revealed, reduceMotion: reduceMotion))
    }
}

/// One selectable species match. Deliberately not a `Button`: the names stay
/// individual accessibility elements (and UI-test static texts), with the tap
/// gesture and a named action layered on top.
private struct CandidateRow: View {
    let candidate: SpeciesCandidate
    let rank: Int
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .stroke(isSelected ? GroveTheme.accent : GroveTheme.separator, lineWidth: 2)
                    .frame(width: 22, height: 22)
                if isSelected {
                    Circle().fill(GroveTheme.accent).frame(width: 12, height: 12)
                }
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.commonName).font(.subheadline.weight(.bold)).foregroundStyle(GroveTheme.ink)
                Text(candidate.scientificName).font(.caption.italic()).foregroundStyle(GroveTheme.mutedInk)
                if !candidate.distinguishingTraits.isEmpty {
                    Text(candidate.distinguishingTraits.prefix(2).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(GroveTheme.subtleInk)
                }
                if let fit = candidate.regionalFit {
                    Text(fit).font(.caption).foregroundStyle(GroveTheme.mutedInk)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(candidate.confidence)%").font(.subheadline.weight(.bold)).foregroundStyle(GroveTheme.ink)
                Text(rank == 1 ? "top match" : "match")
                    .font(.caption2)
                    .foregroundStyle(GroveTheme.subtleInk)
            }
        }
        .padding(12)
        .background(
            isSelected ? GroveTheme.softAccent : GroveTheme.secondarySurface.opacity(0.5),
            in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                .stroke(isSelected ? GroveTheme.accent.opacity(0.65) : GroveTheme.separator, lineWidth: isSelected ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
        .onTapGesture(perform: select)
        .accessibilityAction(named: isSelected ? "Selected match" : "Use this match", select)
    }
}

private struct ConditionCandidateRow: View {
    let condition: PlantConditionCandidate
    let rank: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text("\(rank)")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(GroveTheme.accentStrong)
                    .frame(width: 22, height: 22)
                    .background(GroveTheme.softAccent, in: Circle())
                Text(condition.name).font(.subheadline.weight(.bold))
                Spacer()
                Text("\(condition.confidence)%").font(.caption.bold()).foregroundStyle(GroveTheme.mutedInk)
            }
            Text(condition.explanation).font(.subheadline)
            ForEach(condition.evidence, id: \.self) { evidence in
                Label(evidence, systemImage: "eye").font(.caption).foregroundStyle(GroveTheme.mutedInk)
            }
            if let alternative = condition.alternativeExplanation, !alternative.isEmpty {
                Text("Could also be: \(alternative)").font(.caption).foregroundStyle(GroveTheme.warning)
            }
        }
    }
}

private struct ActionList: View {
    let title: String
    let icon: String
    let color: Color
    let actions: [String]
    var numbered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(color)
            if actions.isEmpty {
                Text("Care guidance stays on hold until the evidence is clearer.").font(.subheadline).foregroundStyle(GroveTheme.mutedInk)
            } else {
                ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if numbered {
                            Text("\(index + 1)")
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(GroveTheme.accentStrong)
                                .frame(width: 22, height: 22)
                                .background(GroveTheme.softAccent, in: Circle())
                        } else {
                            Image(systemName: "minus.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(color.opacity(0.7))
                        }
                        Text(action).font(.subheadline)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct UnknownPlantCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Not enough to name this safely", systemImage: "questionmark.diamond.fill").font(.headline)
            Text("You can still keep it as an unknown plant and track how it changes. There's no watering schedule, toxicity or treatment advice until it's named. Check the soil before you water.")
                .font(.subheadline)
            Label("Until you know what it is, keep it away from children and pets", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(GroveTheme.warning)
        }
        .groveCard()
    }
}

private struct SpeciesSearchView: View {
    var isOnboarding = false
    @Environment(\.dismiss) private var dismiss
    @Environment(ScanSession.self) private var session
    @Environment(GroveStore.self) private var store
    @State private var query = ""
    @State private var results: [SpeciesCandidate] = []
    @State private var isSearching = false
    @State private var searchError: String?

    private var matches: [SpeciesCandidate] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (session.result?.identification.candidates ?? [])
            : results
    }

    var body: some View {
        List(matches) { candidate in
            Button {
                session.confirmIdentity(candidate)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.commonName).font(.headline).foregroundStyle(GroveTheme.ink)
                    Text(candidate.scientificName).font(.subheadline.italic()).foregroundStyle(GroveTheme.mutedInk)
                }
            }
        }
        .groveGroupedContent()
        .searchable(text: $query, prompt: "Common or scientific name")
        .overlay {
            if isSearching {
                ProgressView("Searching plant catalogue…")
            } else if let searchError {
                GroveEmptyState(scene: .severed, title: "Search unavailable", message: searchError, artSize: 108)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GroveTheme.background)
            } else if !query.isEmpty && results.isEmpty {
                GroveEmptyState(
                    scene: .noMatches,
                    title: "No species found",
                    message: "The catalogue has nothing for “\(query)”. Try the common name.",
                    artSize: 108
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(GroveTheme.background)
            }
        }
        .grovePageTitle("Choose species")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .task(id: query) {
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count >= 2 else {
                results = []
                searchError = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isSearching = true
            searchError = nil
            defer { isSearching = false }
            do {
                results = try await session.searchSpecies(
                    query: normalized,
                    regionCode: isOnboarding ? Locale.current.region?.identifier : store.profile.regionCode
                )
            } catch is CancellationError {
                return
            } catch {
                results = []
                searchError = error.localizedDescription
            }
        }
    }
}

struct AddPlantView: View {
    @Environment(GroveStore.self) private var store
    @Environment(ScanSession.self) private var scanSession
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(NotificationService.self) private var notifications
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(GroveDefaults.firstPlantActivationPending) private var firstPlantActivationPending = false
    @AppStorage(GroveDefaults.reminderHour) private var reminderHour = NotificationService.reminderHour
    @State private var nickname = ""
    /// Empty until the user picks: the effective choice is `selectedLocation`,
    /// which follows the plan-aware option list rather than hard-coding a room.
    @State private var location = ""
    @State private var customLocation = ""
    @State private var isNamingCustomLocation = false
    /// Nil until the user answers. See `lightSection` for why this is not
    /// pre-selected the way the location row is.
    @State private var lightPlacement: PlantLightPlacement?
    @State private var addedPlant: Plant?
    @State private var isAddingPlant = false
    @State private var isRequestingNotifications = false
    @State private var heroImage: UIImage?
    @State private var nicknameSelection: TextSelection?
    @State private var hasPreparedNickname = false
    @FocusState private var focusedField: Field?

    private enum Field { case nickname, customLocation }

    private enum AddPlantScrollAnchor: Hashable { case hero }

    /// Sensible fallbacks for where a plant might live, keyed to where the
    /// person said their plants are during onboarding. The picker used to offer
    /// four indoor rooms to everyone — including someone who had just told the
    /// quiz their plants live outdoors.
    private var defaultLocations: [String] {
        switch store.profile.plan?.environment {
        case "outdoor": ["Garden", "Balcony", "Patio", "Porch", "Greenhouse"]
        case "both": ["Living room", "Garden", "Kitchen", "Balcony", "Patio"]
        default: ["Living room", "Bedroom", "Kitchen", "Office", "Balcony"]
        }
    }
    private static let punnyNamePool = [
        "Sproutacus", "Leaf Erikson", "Planty McPlantface", "Root Bader Ginsburg",
        "Morgan Treeman", "Keanu Leaves", "Vincent van Grow", "Sir Plants-a-Lot",
        "Twiggy Stardust", "Harry Pot-ter", "Snoop Logg", "Soil Mate",
        "Leaf Me Alone", "Growgu", "Photosynthesista", "Obi-Wan Can-grow-bi",
        "Bud Lightyear", "Leonardo DiPlantio", "Frond Ferdinand", "Branch Manager",
        "Potrick Swayze", "Soil Goodman", "Steminem", "Chlorophyll Collins",
        "Plant Benatar", "Elton Frond", "Billie Eil-leaf", "Dirt Reynolds",
        "Herb Your Enthusiasm", "Pot Solo", "Leaf Phoenix", "Biggie Sprouts",
        "Notorious P.L.A.N.T.", "Foliage Parton", "Petal Pascal", "Frond Weasley",
        "Captain Plant-It", "Grow With the Flow", "Shrub Hub", "Bud Company",
        "The Codfather", "Pot Twain", "Leafy Wonder", "Spriggy Stardust",
        "Mulch Ado", "Sir Reginald Roots", "Verdant van Gogh", "The Great Catsby",
        "Growzilla", "Bud Spencer", "Plant Damon", "Chris Pine",
        "Aloe Governor", "Botany Spears", "Bark Ruffalo", "Coleus Sprouse",
        "Dieffen-Bach", "Ficus Bueller", "Garden Ramsay", "Hosta La Vista",
        "Judi Drench", "Justin Timberleaf", "Kale Me Maybe", "Katy Peary",
        "Leaf Schreiber", "Leaf Zeppelin", "Lionel Mossy", "Moss Def",
        "Neem Neeson", "Orlando Bloom", "Reese Withersprout", "Sage Against the Machine",
        "Seed Sheeran", "Seedney Poitier", "Shrub Downey Jr.", "Spruce Springsteen",
        "Treeoncé", "Vine Diesel", "Willow Nelson", "Yoko Onoion",
        "Zac Efrond", "Bloom Shakalaka", "Petal to the Metal", "Frond of Mine",
        "Groot Expectations", "Rolling Stems", "Root Awakening", "Mulch Madness",
        "Pot Luck", "Lord of the Sprigs", "Clivia Owen", "Denzel Washingtree",
        "George W. Shrub", "Gwyneth Plantrow", "Halle Berry Bush", "James Frondo",
        "Jennifer Anis-Stem", "Lana Del Fern", "Moss Geller", "Natalie Portree",
        "Ryan Seedcrest", "Dua Leaf"
    ]

    /// Locations the user already keeps plants in, most-used first, padded
    /// with sensible defaults — the grove teaches the picker.
    private var locationOptions: [String] {
        var counts: [String: Int] = [:]
        for plant in store.plants { counts[plant.location, default: 0] += 1 }
        let existing = counts.keys.sorted { lhs, rhs in
            if counts[lhs] != counts[rhs] { return (counts[lhs] ?? 0) > (counts[rhs] ?? 0) }
            return lhs < rhs
        }
        var seen = Set<String>()
        return (existing + defaultLocations).filter { seen.insert($0).inserted }
    }

    /// The pill the form treats as chosen: the user's pick, or the first
    /// plan-aware option before they have touched the row.
    private var selectedLocation: String {
        location.isEmpty ? (locationOptions.first ?? "Living room") : location
    }

    /// Puns that only work for particular plants get first billing.
    private var speciesPuns: [String] {
        let species = (scanSession.result?.identification.commonName ?? "").lowercased()
        var names: [String] = []

        if species.contains("pothos") { names.append("Pothos Malone") }
        if species.contains("monstera") { names.append("Monstera Mash") }
        if species.contains("snake") { names.append("Snake Gyllenhaal") }
        if species.contains("spider") { names.append("Peter Planter") }
        if species.contains("aloe") { names.append("Aloe Vera Wang") }
        if species.contains("fern") {
            names.append("Fernie Sanders")
            if species.contains("asparagus") { names.append("Aspara-Gus") }
        }
        if species.contains("fig") { names.append("Figgy Smalls") }
        if species.contains("cactus") { names.append("Prickle Rick") }
        if species.contains("orchid") { names.append("Orchid You Not") }
        if species.contains("palm") { names.append("Palmela Anderson") }
        if species.contains("ivy") { names.append("Ivy League") }
        if species.contains("rubber") { names.append("Robert Plant") }
        if species.contains("philodendron") { names.append("Phil O'Dendron") }
        if species.contains("calathea") { names.append("Callie Thea") }
        if species.contains("peperomia") { names.append("Pepper O'Mia") }
        if species.contains("begonia") { names.append("Begonia Grande") }
        if species.contains("bonsai") { names.append("Bon-sai Jovi") }
        if species.contains("dracaena") { names.append("Drake-aena") }
        if species.contains("zz plant") || species == "zz" { names.append("ZZ Topsoil") }
        if species.contains("jade") { names.append("Jade the Blade") }
        if species.contains("money") { names.append("Cash Green") }
        if species.contains("prayer") { names.append("Prayoncé") }
        if species.contains("peace lily") { names.append("Lily Tomlin") }
        if species.contains("yucca") { names.append("Yucca Khan") }
        if species.contains("croton") { names.append("Croton John") }
        if species.contains("bamboo") { names.append("Bam Boolé") }
        if species.contains("air plant") { names.append("Air Bud") }
        if species.contains("venus") { names.append("Venus Flytrap Williams") }
        if species.contains("oxalis") { names.append("Oxalis in Chains") }
        if species.contains("anthurium") { names.append("Anthurium Cooper") }
        if species.contains("ponytail") { names.append("Ponytail Swift") }
        if species.contains("succulent") { names.append("Succulent Steve") }
        if species.contains("basil") { names.append("Basil Instinct") }
        if species.contains("rosemary") { names.append("Rosemary Clooney") }
        if species.contains("thyme") { names.append("Thyme After Thyme") }

        return names
    }

    private var availablePunnyNames: [String] {
        var seen = Set<String>()
        return (speciesPuns + Self.punnyNamePool).filter { seen.insert($0).inserted }
    }

    private var isUnknownIdentity: Bool {
        scanSession.result?.identification.isUnknown == true
    }

    private var chosenLocation: String {
        let custom = customLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        return isNamingCustomLocation && !custom.isEmpty ? custom : selectedLocation
    }

    /// What the plant is called when the person types nothing: its own species
    /// name. The fallback used to be the first pun, which meant a quick tap
    /// through named someone's rose "Sproutacus" permanently — charming as an
    /// offer, wrong as a default. Unknown identity stays empty so the store
    /// falls to "Unknown plant".
    private var defaultNickname: String {
        isUnknownIdentity ? "" : (scanSession.result?.identification.commonName ?? "")
    }

    /// The commit button names who it's adding — the same ≤18-character rule as
    /// the result screen's docked CTA. "Surprise me" makes it easy to pick a
    /// name in passing; the button is the last place to notice what you chose.
    private var addCTATitle: String {
        let typed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = typed.isEmpty ? defaultNickname : typed
        return name.isEmpty || name.count > 18 ? "Add to my grove" : "Add \(name)"
    }

    /// Only the first plant stops here, and only for the notification ask.
    /// Every other adoption goes straight to the plant's own page: the
    /// interstitial that used to sit in between said "One of yours now" and
    /// then offered a button to the very page it was standing in front of.
    var body: some View {
        Group {
            if let addedPlant {
                notificationPrimer(for: addedPlant)
            } else {
                formView
            }
        }
        // This route is pushed from the intentionally dark camera stack, but
        // `preferredColorScheme` is a presentation-level preference, so the
        // camera cover can intercept it before it reaches this destination.
        // Override the destination environment as well: Grove's adaptive
        // canvas, surfaces and ink must all resolve to their light variants.
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        .toolbarColorScheme(.light, for: .navigationBar)
    }

    // MARK: - Form

    private var formView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                    heroCard
                        .id(AddPlantScrollAnchor.hero)
                    nameSection
                    locationSection
                    lightSection
                    promiseCard
                    safetyNote
                }
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                Button {
                    addPlant()
                } label: {
                    GroveCTALabel(
                        title: isAddingPlant ? "Planting…" : addCTATitle,
                        systemImage: isAddingPlant ? "hourglass" : "arrow.right"
                    )
                }
                .buttonStyle(GrovePressStyle())
                .disabled(isAddingPlant)
                .opacity(isAddingPlant ? 0.6 : 1)
                .accessibilityIdentifier("confirmAddPlant")
                .groveActionBar()
            }
            .task {
                // `dynamicTypeSize` can still read the default size on the
                // first frame, so check it only after the screen has settled.
                try? await Task.sleep(for: .milliseconds(350))
                releaseNicknameFocusIfAccessibilitySize(proxy)
            }
            .onChange(of: dynamicTypeSize) { _, _ in
                releaseNicknameFocusIfAccessibilitySize(proxy)
            }
        }
        .groveBackground()
        .grovePageTitle("Add to my grove")
        .toolbarBackground(GroveTheme.background, for: .navigationBar)
        .toolbarBackground(.automatic, for: .navigationBar)
        .onAppear(perform: prepareNickname)
        .task {
            if heroImage == nil, let url = scanSession.draft?.fileURL {
                heroImage = await GroveImageLoader.downsampledImage(at: url, maxDimension: 1400)
            }
        }
    }

    /// The plant's own portrait — the photo the user just took — with the
    /// identification laid over a soft scrim.
    private var heroCard: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let heroImage {
                    Image(uiImage: heroImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    PlantArtwork(symbol: isUnknownIdentity ? "questionmark" : "leaf.fill", palette: .fern, height: 300)
                }
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.02), .black.opacity(0.62)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 6) {
                if let confidence = scanSession.result?.identification.confidence, !isUnknownIdentity {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption2.weight(.bold))
                        Text("\(confidence)% match")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.22), in: Capsule())
                }
                GroveDisplayHeading(
                    text: scanSession.result?.identification.commonName ?? "Unknown plant",
                    style: .heading,
                    color: .white
                )
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                Text(scanSession.result?.identification.scientificName ?? "Species unconfirmed")
                    .font(.subheadline.italic())
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(18)
        }
        .groveHeroShape()
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.heroRadius, style: .continuous)
                .stroke(GroveTheme.separator, lineWidth: 1)
        }
        .groveShadow(.floating)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Identified as \(scanSession.result?.identification.commonName ?? "unknown plant")")
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    nameSectionEyebrow
                    Spacer(minLength: 0)
                    surpriseNameButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    nameSectionEyebrow
                    surpriseNameButton
                }
            }
            TextField(
                "Plant nickname",
                text: $nickname,
                selection: $nicknameSelection
            )
                .font(.title2.weight(.bold))
                .foregroundStyle(GroveTheme.ink)
                .focused($focusedField, equals: .nickname)
                .submitLabel(.done)
                .accessibilityIdentifier("plantNickname")
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
                .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                        .stroke(focusedField == .nickname ? GroveTheme.accent.opacity(0.65) : GroveTheme.separator, lineWidth: focusedField == .nickname ? 2 : 1)
                }
                .animation(.easeOut(duration: 0.15), value: focusedField)
        }
    }

    private var nameSectionEyebrow: some View {
        GroveEyebrow(text: "What will you call it?")
    }

    private var surpriseNameButton: some View {
        Button {
            chooseRandomPunnyName()
        } label: {
            GrovePill(text: "Surprise me", systemImage: "dice.fill", style: .softGreen)
                .fixedSize()
        }
        .buttonStyle(GrovePressStyle())
        .accessibilityLabel("Choose a random funny plant name")
        .accessibilityIdentifier("randomPlantNickname")
    }

    /// Put the identified name in the field rather than using it as placeholder
    /// copy, then select it so typing a nickname replaces the suggestion in one
    /// step. Unknown plants still start with an empty, focused field.
    private func prepareNickname() {
        guard !hasPreparedNickname else { return }
        hasPreparedNickname = true

        let suggestedName = defaultNickname
        nickname = suggestedName
        // At accessibility sizes the keyboard and the scroll-to-field it
        // triggers push the plant card under the bar before it is seen; the
        // name is still prefilled and one tap away.
        if !dynamicTypeSize.isAccessibilitySize {
            focusedField = .nickname
        }
        nicknameSelection = suggestedName.isEmpty
            ? nil
            : TextSelection(range: suggestedName.startIndex..<suggestedName.endIndex)
    }

    /// At accessibility sizes the nickname field must not hold the keyboard
    /// on arrival: the keyboard's scroll-to-field pushes the plant card under
    /// the bar before anyone has seen it. The name stays prefilled.
    private func releaseNicknameFocusIfAccessibilitySize(_ proxy: ScrollViewProxy) {
        guard dynamicTypeSize.isAccessibilitySize else { return }
        focusedField = nil
        // The focus can sit in UIKit without `focusedField` ever having been
        // set, so nil alone would change nothing.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        proxy.scrollTo(AddPlantScrollAnchor.hero, anchor: .top)
        Task { @MainActor in
            // Once the keyboard has gone, its inset change can scroll again.
            try? await Task.sleep(for: .milliseconds(400))
            proxy.scrollTo(AddPlantScrollAnchor.hero, anchor: .top)
        }
    }

    private func chooseRandomPunnyName() {
        let currentName = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let choices = availablePunnyNames.filter {
            $0.compare(currentName, options: .caseInsensitive) != .orderedSame
        }
        guard let randomName = choices.randomElement() else { return }

        Haptics.selection()
        withAnimation(GroveMotion.snap) {
            nickname = randomName
            nicknameSelection = TextSelection(range: randomName.startIndex..<randomName.endIndex)
            focusedField = .nickname
        }
    }

    /// The room, as a cloud of chips that wrap.
    ///
    /// This was a horizontal scroll row, which is a filter-bar idiom: fine
    /// above a feed, wrong for a form answer. A form question with six answers
    /// that shows four of them makes the user dig for "Balcony" behind a
    /// gesture nothing advertises — and an option nobody sees is an option
    /// nobody picks. `GroveFlowLayout` shows the whole vocabulary at once;
    /// most-used spots still sort first, so the top-left chip is still the
    /// likeliest answer.
    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroveEyebrow(text: "Where does it live?")
            // The same room chips as first run, so a room looks the same
            // everywhere a plant is given one.
            GroveFlowLayout(spacing: 8) {
                ForEach(locationOptions.filter { $0.caseInsensitiveCompare("Unassigned") != .orderedSame }, id: \.self) { option in
                    GroveRoomChip(title: option, isSelected: !isNamingCustomLocation && selectedLocation == option) {
                        location = option
                        isNamingCustomLocation = false
                    }
                }
                GroveRoomChip(title: "New spot", symbolOverride: "plus", isSelected: isNamingCustomLocation) {
                    isNamingCustomLocation = true
                    focusedField = .customLocation
                }
            }

            if isNamingCustomLocation {
                TextField("Name the spot: Sunroom, Porch…", text: $customLocation)
                    .font(.body.weight(.semibold))
                    .focused($focusedField, equals: .customLocation)
                    .submitLabel(.done)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                            .stroke(GroveTheme.accent.opacity(0.5), lineWidth: 1.5)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Where it stands relative to the light.
    ///
    /// The room name above this is the answer to a different question. "Bedroom"
    /// covers a pane-side sill and a dark corner three metres in, and those two
    /// spots differ by roughly an order of magnitude in the light they deliver —
    /// which is the difference between a plant that grows and one that slowly
    /// stops. Four options, because that is as fine a distinction as anyone can
    /// draw honestly without a light meter.
    ///
    /// The eyebrow asks where it *stands* — the one thing every owner knows
    /// without thinking — and each row answers back with the thing they almost
    /// certainly don't: the share of outdoor daylight that survives to that
    /// spot, drawn as a small gold meter. The fall-off is the entire reason the
    /// question exists, and nobody believes the far side of the room lives on a
    /// twentieth until they see its sliver next to the sill's half. The meters
    /// make the old helper sentence ("a room name doesn't tell Grove much")
    /// redundant, so it is gone.
    ///
    /// Deliberately left unanswered rather than defaulted. A pre-selected row
    /// would be accepted by almost everyone and would fill the record with a
    /// guess Grove could not tell apart from an answer — and every piece of
    /// advice that names a plant leans on this being real.
    ///
    /// A vertical list, not a grid or a scrolling row: this is a closed
    /// four-way question, so all four options stay visible, each has room to
    /// say what choosing it is worth in daylight, and the outdoors inference
    /// stays in view — choose "Garden" above and the Outdoors row checks
    /// itself.
    private var lightSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroveEyebrow(text: "Where does it stand?")

            VStack(spacing: 10) {
                ForEach(PlantLightPlacement.allCases, id: \.self) { option in
                    lightChoiceRow(option)
                }
            }

            if effectiveLightPlacement == nil {
                Text("You can skip this. A spot is only flagged once there's enough evidence.")
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.subtleInk)
                    .transition(.opacity)
            }
        }
    }

    /// One standing spot, in the app's choice-row family: symbol tile, title,
    /// daylight meter, trailing check. Selection is carried the same way
    /// `GroveActionTile` carries it — accent stroke and a popped check — so the
    /// surface never changes colour underneath the gold meter it exists to show.
    private func lightChoiceRow(_ option: PlantLightPlacement) -> some View {
        let isSelected = effectiveLightPlacement == option
        return Button {
            Haptics.selection()
            withAnimation(GroveMotion.snap) {
                lightPlacement = lightPlacement == option ? nil : option
            }
        } label: {
            HStack(spacing: 14) {
                GroveSymbolTile(symbol: option.icon, size: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text(option.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(GroveTheme.ink)
                    HStack(spacing: 8) {
                        GroveProgressBar(
                            fraction: option.outdoorLightShare,
                            tint: GroveTheme.goldDeep,
                            height: 5,
                            minimumFill: 3
                        )
                        .frame(width: 52)
                        Text(daylightCaption(for: option))
                            .font(.caption)
                            .foregroundStyle(GroveTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                ZStack {
                    Circle()
                        .stroke(isSelected ? GroveTheme.accent : GroveTheme.separator, lineWidth: 2)
                        .frame(width: 24, height: 24)
                    if isSelected {
                        Circle().fill(GroveTheme.accent).frame(width: 24, height: 24)
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .groveAnimation(GroveMotion.pop, value: isSelected)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                    .stroke(isSelected ? GroveTheme.accent.opacity(0.6) : GroveTheme.separator, lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.985, haptics: false))
        .accessibilityLabel(option.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("\(option.detail). \(daylightCaption(for: option)).")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The meter's honest order of magnitude, in words. These ride next to a
    /// bar drawn from `outdoorLightShare`, so the numbers and the words can
    /// never disagree.
    private func daylightCaption(for option: PlantLightPlacement) -> String {
        switch option {
        case .sill: "About half the daylight outside"
        case .bright: "About a fifth of it"
        case .shaded: "A twentieth, on a good day"
        case .outdoors: "All the daylight there is"
        }
    }

    /// The user's pick, or `outdoors` when the spot they chose is plainly
    /// outside — nobody should have to say "Balcony" and then say "outdoors".
    private var effectiveLightPlacement: PlantLightPlacement? {
        lightPlacement ?? PlantLightPlacement.inferred(fromLocation: chosenLocation)
    }

    /// What the user gets for adding the plant — the promise that drives them
    /// back: a baseline captured today and a scheduled first check-in.
    private var promiseCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroveEyebrow(text: "What happens next", color: GroveTheme.accentStrong)
            promiseRow(
                symbol: "heart.fill",
                artwork: "PromiseBaseline",
                title: "Baseline captured today",
                detail: "Looks \(scanSession.result?.condition.healthBand.shortTitle.lowercased() ?? "uncertain") from here. Every future photo gets measured against this one."
            )
            promiseRow(
                symbol: "bell.badge.fill",
                artwork: "PromiseCheckIn",
                title: firstCheckInTitle,
                detail: "You'll get a reminder. One new photo and you'll see exactly what changed."
            )
            promiseRow(
                symbol: isUnknownIdentity ? "questionmark.circle.fill" : "book.fill",
                artwork: isUnknownIdentity ? nil : "PromiseCareGuide",
                title: isUnknownIdentity ? "Name it for care guidance" : "Care guidance ready",
                detail: isUnknownIdentity
                    ? "Confirm the species whenever you like to see watering, light and toxicity advice."
                    : "Watering, light and seasonal advice for this species, adjusted to your care history."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groveCard()
    }

    /// The gateway bounds a follow-up to 1–30 days, so "in 1 days" is a real
    /// outcome for a plant in trouble — the one moment this card most needs to
    /// sound like it knows what it is talking about.
    private var firstCheckInTitle: String {
        let days = scanSession.result.map {
            GroveStore.firstCheckInDays(
                analysisDays: $0.condition.followUpDays,
                band: $0.condition.healthBand
            )
        } ?? GroveStore.firstCheckInMaxDays
        return days == 1 ? "First check-in tomorrow" : "First check-in in \(days) days"
    }

    private func promiseRow(
        symbol: String,
        artwork: String? = nil,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let artwork {
                GroveArtworkTile(asset: artwork, size: 38)
            } else {
                GroveSymbolTile(symbol: symbol, size: 38)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.bold)).foregroundStyle(GroveTheme.ink)
                Text(detail).font(.footnote).foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What this plant means for anyone in the house likely to chew it.
    ///
    /// The form used to say this only when the identification *failed*, which
    /// is backwards: an unknown plant got a warning and a confidently
    /// identified monstera got silence, on the screen where someone is deciding
    /// which room to stand it in. Grove holds a curated answer for the common
    /// toxic species — see `PlantSafety` — so the moment it is most useful is
    /// before the pot is put down, not after.
    ///
    /// Deliberately not gated behind asking whether the household has pets or
    /// children. That question would personalise the warning for the people who
    /// answered it and remove it for everyone else, including the person who
    /// did not think to mention the toddler. Telling everyone costs one line.
    @ViewBuilder
    private var safetyNote: some View {
        if isUnknownIdentity {
            safetyLabel(
                "Until you know what it is, keep it away from children and pets",
                tint: GroveTheme.warning
            )
        } else {
            let safety = scanSession.result.map { PlantSafety(identification: $0.identification) }
                ?? PlantSafety(commonName: "", scientificName: "", confirmation: .photoMatch)
            // The reassuring verdict stays silent here. This screen is a form
            // with a commit button at the foot of it, and a green "no known
            // toxicity" line is the plant page's job, where there is room to
            // say what it rests on.
            if safety.warrantsCaution {
                safetyLabel(
                    safety.summary,
                    tint: safety.verdict == .toxic ? GroveTheme.danger : GroveTheme.warning
                )
            }
        }
    }

    private func safetyLabel(_ text: String, tint: Color) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Activation

    private func notificationPrimer(for plant: Plant) -> some View {
        OnboardingNotificationPrimerView(
            plant: plant,
            task: firstReminderTask(for: plant),
            reminderHour: $reminderHour,
            isRequesting: isRequestingNotifications,
            onEnable: { requestFirstPlantNotifications(for: plant) },
            onSkip: { completeFirstPlantActivation(for: plant, outcome: .primerSkipped) }
        )
        .transition(.opacity)
        .onAppear { Haptics.celebrate() }
    }

    private func requestFirstPlantNotifications(for plant: Plant) {
        guard !isRequestingNotifications else { return }
        isRequestingNotifications = true
        Task {
            await notifications.requestAuthorization()
            completeFirstPlantActivation(
                for: plant,
                outcome: .system(authorization: notifications.authorization)
            )
        }
    }

    private func completeFirstPlantActivation(
        for plant: Plant,
        outcome: OnboardingAnalytics.NotificationOutcome
    ) {
        OnboardingAnalytics.notificationsDecision(outcome)
        // Retained only for an activation marker written by an older,
        // quiz-first build; new scan-first onboarding completes in RootView.
        OnboardingAnalytics.completed(route: .manual, notificationOutcome: outcome)
        firstPlantActivationPending = false
        isRequestingNotifications = false
        IntentRouter.shared.openPlant(plant.id)
    }

    private func addPlant() {
        guard !isAddingPlant,
              addedPlant == nil,
              let analysis = scanSession.result,
              let draft = scanSession.draft else { return }
        isAddingPlant = true
        focusedField = nil
        // The field's placeholder is a real suggestion, so leaving it untouched
        // has to produce that name — the species itself, not a pun.
        let typedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedNickname = typedNickname.isEmpty ? defaultNickname : typedNickname
        let isFirstPlant = store.plants.isEmpty
        let usesLegacyPrimer = firstPlantActivationPending
        let newPlant = store.addPlant(
            nickname: resolvedNickname,
            location: chosenLocation,
            lightPlacement: effectiveLightPlacement,
            analysis: analysis
        )
        if firstPlantActivationPending {
            OnboardingAnalytics.firstPlantBaselineSaved()
            withAnimation(GroveMotion.settle) { addedPlant = newPlant }
        } else {
            // The plant page already carries the baseline score and the next
            // check-in, so the adoption is announced on the way there rather
            // than on a page of its own.
            Haptics.celebrate()
            toasts?.show(
                "\(newPlant.nickname) is in your grove",
                symbol: "leaf.fill"
            )
            IntentRouter.shared.openPlant(newPlant.id)
        }
        let scanID = scanSession.scanID
        let request = CreatePlantRequest(
            clientPlantID: newPlant.id,
            nickname: newPlant.nickname,
            location: newPlant.location,
            analysis: analysis,
            mediaDraftID: draft.id,
            plant: newPlant
        )
        Task {
            // Re-record the scan with the new plant's id (the earlier record
            // was written before the plant existed) so history stays linked
            // to the plant this adoption created.
            let archivedURL = await scanSession.archivePrimaryForHistory() ?? draft.fileURL
            store.recordScan(id: scanID, mode: .add, result: analysis, photoURL: archivedURL, plantID: newPlant.id)
            let pendingMedia = PendingMediaUpload(localMediaID: draft.id, fileURL: draft.fileURL, purpose: .scan, mimeType: "image/jpeg", pixelWidth: draft.pixelWidth, pixelHeight: draft.pixelHeight)
            await syncEngine.enqueue(.uploadMedia(pendingMedia), isConnected: connectivity.isConnected)
            await syncEngine.enqueue(.createPlant(request), isConnected: connectivity.isConnected)
            if isFirstPlant && !usesLegacyPrimer {
                UserDefaults.standard.set(newPlant.id.uuidString, forKey: GroveDefaults.firstPlantNotificationPrimerPlantID)
            }
            scanSession.finishKeepingMedia(ifCurrentScanID: scanID)
        }
    }

    private func firstReminderTask(for plant: Plant) -> CareTask? {
        OnboardingReminderPreview.firstTask(for: plant, in: store.tasks)
    }
}

private struct ScanViewPreviewHost: View {
    @State private var path: [AppRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScanView(path: $path, isActive: true).withAppDestinations(path: $path)
        }
    }
}

#Preview {
    ScanViewPreviewHost()
        .environment(GroveStore())
        .environment(ScanSession())
        .environment(SyncEngine())
        .environment(ConnectivityMonitor())
}


// MARK: - Clarifying questions

/// The one round of clarifying questions a diagnosis gets, and the card that
/// takes its place once the read has been updated with the answers.
///
/// One round, by design. Before this, every "Refine" sent the model option ids
/// it could not remember and told it to ask again, so the owner walked into a
/// loop of fresh questions that never reached a verdict. Now the owner answers
/// everything, taps once, and the next result commits: the gateway strips any
/// further questions from an answered scan, and so does the session.
private struct DiagnosisQuestionsCard: View {
    @Environment(GroveStore.self) private var store
    @Environment(ScanSession.self) private var session

    let questions: [DiagnosisQuestion]
    let plantID: UUID?

    var body: some View {
        if !questions.isEmpty {
            questionsCard
        } else if !session.appliedObservations.isEmpty {
            appliedCard
        }
    }

    private var roundDescription: String {
        switch questions.count {
        case 1: "One quick check, then the diagnosis updates."
        case 2: "Two quick checks, then the diagnosis updates."
        default: "Three quick checks, then the diagnosis updates."
        }
    }

    private var questionsCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Help narrow it down")
                    .font(.headline)
                Text(roundDescription)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
            }

            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 9) {
                    Text(question.prompt)
                        .font(.subheadline.weight(.semibold))
                    if let reason = question.reason, !reason.isEmpty {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(GroveTheme.mutedInk)
                    }
                    VStack(spacing: 7) {
                        ForEach(question.options) { option in
                            answerRow(option, for: question)
                        }
                    }
                }
            }

            let answered = session.pendingObservations.count
            if session.allQuestionsAnswered {
                GroveInkButton(title: "Update the diagnosis", systemImage: "arrow.triangle.2.circlepath") {
                    Task {
                        await session.analyse(
                            regionCode: store.profile.regionCode,
                            existingPlant: plantID.flatMap(store.plant(id:))
                        )
                    }
                }
            } else if answered > 0 {
                let remaining = questions.count - answered
                Text(remaining == 1 ? "One more to answer" : "\(remaining) more to answer")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(GroveTheme.mutedInk)
            }
        }
        .groveCard()
    }

    private var appliedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Diagnosis updated with your answers", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(GroveTheme.accentStrong)
            ForEach(session.appliedObservations, id: \.self) { observation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(observation.answer)
                        .font(.subheadline.weight(.semibold))
                    Text(observation.question)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
            }
            Text("Added to the diagnosis above. No more questions for this scan.")
                .font(.caption)
                .foregroundStyle(GroveTheme.mutedInk)
        }
        .groveCard()
    }

    private func answerRow(_ option: DiagnosisAnswerOption, for question: DiagnosisQuestion) -> some View {
        let chosen = session.answers[question.id] == option.id
        return Button {
            session.answer(questionID: question.id, optionID: option.id)
            Haptics.selection()
        } label: {
            HStack {
                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(chosen ? GroveTheme.accentStrong : GroveTheme.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen ? GroveTheme.accent : GroveTheme.subtleInk)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                chosen ? GroveTheme.softAccent : GroveTheme.secondarySurface.opacity(0.55),
                in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                    .stroke(chosen ? GroveTheme.accent.opacity(0.6) : GroveTheme.separator, lineWidth: 1)
            }
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.97, haptics: false))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}