import SwiftUI
import UIKit

/// The signed-out wrapper around Grove's existing capture experience. Camera
/// and analysis lifetime remain in `ScanView` / `ScanSession`; this view owns
/// only the onboarding handoff and its explicit fallbacks.
struct OnboardingFirstPlantScanView: View {
    let model: OnboardingModel

    @Environment(ScanSession.self) private var scanSession
    @Environment(SessionService.self) private var session
    @State private var path: [AppRoute] = []
    @State private var isScanScopeReady = false
    @State private var stagingState: StagingState = .idle
    @State private var pendingOutcome: FirstPlantScanOutcome?
    @State private var hasRecordedCapture = false
    @State private var hasRecordedAnalysisResult = false
    @State private var showsRecoveryNotice = false
    @State private var recoveryNoticeText = ""

    private enum StagingState: Equatable {
        case idle
        case saving
        case failed(String)
    }

    private struct FirstPlantScanOutcome: Hashable {
        let result: PlantAnalysisResult
        let mediaDraft: ScanMediaDraft
        let scanID: UUID
    }

    var body: some View {
        Group {
            if isScanScopeReady {
                NavigationStack(path: $path) {
                    ScanView(
                        path: $path,
                        isActive: true,
                        presetMode: .add,
                        onFirstPlantResolved: resolved,
                        onFirstPlantPhotoCaptured: photoCaptured,
                        onOnboardingCancel: cancel,
                        onOnboardingKeepForLater: keepForLater,
                        onManualSetup: useManualSetup
                    )
                }
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView().controlSize(.large).tint(.white)
                }
                .accessibilityLabel("Preparing the first plant scan")
            }
        }
        .overlay { stagingOverlay }
        // When the account gate has to send someone back here because the plant
        // they were saving is gone, this is the only place that can tell them
        // why. The account screen's error is cleared by the step change and was
        // never rendered on this screen.
        .onChange(of: model.scanRecoveryNotice, initial: true) { _, notice in
            if let notice {
                recoveryNoticeText = notice
                showsRecoveryNotice = true
            } else {
                showsRecoveryNotice = false
            }
        }
        .alert("Scan your plant again", isPresented: $showsRecoveryNotice) {
            Button("OK", role: .cancel) { model.clearScanRecoveryNotice() }
        } message: {
            Text(recoveryNoticeText)
        }
        .task {
            await scanSession.activateForOnboarding()
            guard !Task.isCancelled else { return }
            // `stage` writes the handoff before advancing the model. If the
            // process dies in that tiny interval, the durable handoff is the
            // source of truth and relaunch resumes at the account gate instead
            // of asking for (and charging for) the same plant again.
            if (try? await PendingFirstPlantStore.shared.loadUnclaimed()) != nil {
                await scanSession.discard()
                model.advance()
                return
            }
            isScanScopeReady = true
            OnboardingAnalytics.scanStarted()
        }
        .onChange(of: scanSession.state, initial: true) { _, state in
            switch state {
            case .completed:
                guard !hasRecordedAnalysisResult else { return }
                OnboardingAnalytics.analysisResultViewed(identification: scanSession.result?.identification)
                hasRecordedAnalysisResult = true
            case .failed(_, let kind):
                OnboardingAnalytics.analysisFailed(kind: kind)
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var stagingOverlay: some View {
        switch stagingState {
        case .idle:
            EmptyView()
        case .saving:
            ZStack {
                Color.black.opacity(0.48).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Keeping this baseline safe…")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .padding(28)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Saving your first plant baseline")
        case .failed(let message):
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.title)
                    Text("This baseline isn't saved yet")
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.78))
                    Button(action: retryStaging) {
                        GroveCTALabel(title: "Try saving again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(GrovePressStyle())
                    .accessibilityIdentifier("retryFirstPlantStaging")

                    // Two of the failures here (a handoff already claimed by
                    // another account, or a protected write that cannot land)
                    // are not fixed by retrying. This overlay covers the scan
                    // screen's own back control, so without an explicit exit
                    // the only way out of onboarding is force-quitting.
                    Button("Start over", action: startOverAfterStagingFailure)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("restartFirstPlantStaging")
                }
                .foregroundStyle(.white)
                .padding(26)
                .frame(maxWidth: 330)
                .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            }
        }
    }

    private func resolved(result: PlantAnalysisResult, mediaDraft: ScanMediaDraft, scanID: UUID) {
        guard stagingState != .saving else { return }
        let outcome = FirstPlantScanOutcome(result: result, mediaDraft: mediaDraft, scanID: scanID)
        pendingOutcome = outcome
        OnboardingAnalytics.analysisResultAccepted(identification: result.identification)
        stage(outcome)
    }

    private func photoCaptured() {
        guard !hasRecordedCapture else { return }
        OnboardingAnalytics.photoCaptured()
        hasRecordedCapture = true
    }

    private func retryStaging() {
        guard let pendingOutcome else {
            stagingState = .idle
            return
        }
        stage(pendingOutcome)
    }

    /// The explicit way out of an inescapable save failure: throw away this
    /// attempt's draft and credential and return to the front door, where the
    /// person can scan again. `discardUnclaimed` is allowed to fail — a handoff
    /// already claimed by another account is protected on purpose — because the
    /// point is to leave, not to delete somebody else's receipt.
    private func startOverAfterStagingFailure() {
        guard stagingState != .saving else { return }
        stagingState = .saving
        Task {
            await scanSession.discard()
            try? await PendingFirstPlantStore.shared.discardUnclaimed()
            session.clearOnboardingGuestCredential()
            pendingOutcome = nil
            stagingState = .idle
            model.clearScanRecoveryNotice()
            model.back()
        }
    }

    private func stage(_ outcome: FirstPlantScanOutcome) {
        stagingState = .saving
        Task {
            do {
                _ = try await PendingFirstPlantStore.shared.stage(
                    scanID: outcome.scanID,
                    mediaDraft: outcome.mediaDraft,
                    analysis: outcome.result
                )
                OnboardingAnalytics.firstPlantDraftSaved()
                model.clearScanRecoveryNotice()
                // Persist the next onboarding step before cleaning the source
                // draft. Either side of a process kill now has a recoverable
                // copy of the same stable scan.
                model.advance()
                await scanSession.discard()
            } catch {
                stagingState = .failed(error.localizedDescription)
            }
        }
    }

    private func cancel() {
        Task {
            await scanSession.discard()
            try? await PendingFirstPlantStore.shared.discardUnclaimed()
            session.clearOnboardingGuestCredential()
            model.back()
        }
    }

    /// A daily ceiling is not cancellation. Leave the neutral scan and its
    /// quota-bearing guest credential untouched so starting again tomorrow
    /// restores this exact photo and request instead of charging for another.
    private func keepForLater() {
        model.back()
    }

    private func useManualSetup() {
        Task {
            await scanSession.discard()
            try? await PendingFirstPlantStore.shared.discardUnclaimed()
            session.clearOnboardingGuestCredential()
            model.beginManualSetup()
        }
    }
}

/// The payoff after the scan: the plant's own photo with Sprout cheering at
/// its edge, the name as the headline, and three facts the scan settled
/// (health, the first check-in, and whether it is safe around pets).
struct OnboardingFirstPlantResultView: View {
    let model: OnboardingModel

    @Environment(ScanSession.self) private var scanSession
    @Environment(SessionService.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var plant: OnboardingFirstPlantPresentation?
    @State private var isLeaving = false

    var body: some View {
        OnboardingSproutPage(step: 1, isBackEnabled: !isLeaving, onBack: abandonAndReturnToScan) {
            if let plant {
                VStack(alignment: .leading, spacing: 18) {
                    title(plant)
                    photo(plant)
                    facts(plant)
                    careBasics(plant)
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("Restoring your plant…")
                        .font(.headline)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            }
        } footer: {
            VStack(spacing: 4) {
                OnboardingPrimaryButton(title: "Keep this plant", isEnabled: plant != nil && !isLeaving) {
                    Haptics.commit()
                    model.advance()
                }
                .accessibilityIdentifier("onboardingKeepFirstPlant")
                OnboardingQuietButton(title: "Scan a different plant", action: abandonAndReturnToScan)
                    .disabled(isLeaving)
            }
        }
        .task { await restore() }
    }

    @ViewBuilder
    private func title(_ plant: OnboardingFirstPlantPresentation) -> some View {
        if plant.isUnknownIdentity {
            OnboardingQuestionTitle(
                lead: "Your ",
                accent: "plant",
                trail: " is saved.",
                subtitle: "The species isn’t certain yet. You can confirm it from its page later."
            )
        } else if plant.identificationIsProvisional {
            // "an Aloe", "a Monstera": the article follows the name's sound.
            OnboardingQuestionTitle(
                lead: "Possibly \(SpeciesPhrase.article(for: plant.displayName)) ",
                accent: plant.displayName,
                trail: ".",
                subtitle: "You can confirm the species from its page later."
            )
        } else {
            OnboardingQuestionTitle(
                lead: "It’s \(SpeciesPhrase.article(for: plant.displayName)) ",
                accent: plant.displayName,
                trail: ".",
                subtitle: healthLine(plant)
            )
        }
    }

    private func healthLine(_ plant: OnboardingFirstPlantPresentation) -> String {
        if !plant.assessmentAvailable {
            return "Grove couldn’t read its health from this photo. Its next check-in will."
        }
        switch plant.healthBand {
        case .attention, .urgent: return "It needs some care. Its page shows what to do first."
        case .monitor: return "Mostly healthy, with one or two things worth watching."
        case .thriving: return "It looks like it’s thriving."
        default: return "It looks healthy."
        }
    }

    private func photo(_ plant: OnboardingFirstPlantPresentation) -> some View {
        Color.clear
            .frame(height: 290)
            .overlay {
                if let image = plant.image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    PlantArtwork(symbol: "leaf.fill", palette: .fern, height: 290)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            .overlay(alignment: .topLeading) {
                if let line = plant.cardLine {
                    Text(line)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GroveTheme.inkOnLight)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.92), in: Capsule())
                        .padding(12)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                SproutImage(pose: .cheer, size: 116)
                    .offset(x: 6, y: 14)
            }
            .accessibilityElement()
            .accessibilityLabel(plant.accessibilityDescription)
    }

    private func facts(_ plant: OnboardingFirstPlantPresentation) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        return layout {
            factTiles(plant)
        }
    }

    @ViewBuilder
    private func factTiles(_ plant: OnboardingFirstPlantPresentation) -> some View {
        if let score = plant.healthScore, let band = plant.healthBand {
            OnboardingFactTile(label: "Health", value: "\(score)", valueColor: band.color)
        }
        OnboardingFactTile(
            label: "Check-in",
            value: plant.firstCheckInDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        )
        if let safety = plant.safety {
            OnboardingFactTile(
                label: "Pets & children",
                value: safety.shortLabel,
                valueColor: Self.tileColor(for: safety.cautionLevel)
            )
        }
    }

    private static func tileColor(for level: PlantSafety.CautionLevel) -> Color {
        switch level {
        case .none: return GroveTheme.ink
        case .caution: return GroveTheme.warning
        case .danger: return GroveTheme.danger
        }
    }

    /// The useful part of the scan, before any account is asked for: checked
    /// species care where earned, the scan's own first actions, and the next
    /// check-in. Unknown or provisional plants get honest generic watering.
    private func careBasics(_ plant: OnboardingFirstPlantPresentation) -> some View {
        RaisedPlate {
            VStack(alignment: .leading, spacing: 10) {
                GroveEyebrow(text: "Care basics")
                ForEach(OnboardingCareBasics.make(for: plant).lines, id: \.self) { line in
                    careBasicRow(line)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboardingCareBasics")
    }

    @ViewBuilder
    private func careBasicRow(_ line: OnboardingCareBasics.Line) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                careBasicLabel(line)
                careBasicText(line)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                careBasicLabel(line)
                    .frame(width: 68, alignment: .leading)
                careBasicText(line)
            }
        }
    }

    private func careBasicLabel(_ line: OnboardingCareBasics.Line) -> some View {
        Text(line.label)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(GroveTheme.mutedInk)
    }

    private func careBasicText(_ line: OnboardingCareBasics.Line) -> some View {
        Text(line.text)
            .font(.subheadline)
            .foregroundStyle(GroveTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func restore() async {
        guard let loaded = await OnboardingFirstPlantPresentation.load() else {
            model.recoverMissingFirstPlant()
            return
        }
        plant = loaded
        // The pending handoff now owns a protected copy of the same JPEG.
        // Cleaning the scanner only after that copy exists closes both crash
        // windows: a relaunch can restore this screen, and this screen then
        // removes any source draft left by a kill between advance/discard.
        await scanSession.activateForOnboarding()
        await scanSession.discard()
    }

    /// "Scan a different plant" discards both copies of the abandoned
    /// pre-account plant and its short-lived guest credential before the
    /// scanner can mint a new stable capture.
    private func abandonAndReturnToScan() {
        guard !isLeaving else { return }
        isLeaving = true
        Task {
            try? await PendingFirstPlantStore.shared.discardUnclaimed()
            await scanSession.discard()
            session.clearOnboardingGuestCredential()
            model.restartFirstPlantScan()
        }
    }
}
