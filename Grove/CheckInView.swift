import PhotosUI
import SwiftUI
import UIKit

/// Why a saved check-in had to use the owner's answers instead of its photo.
///
/// `isEstimated` remains the durable evidence-quality flag; this value exists
/// to stop every upstream failure being presented as a network outage.
enum CheckInAnalysisFallback: Equatable {
    case offline
    case service
    case limit
    case photo

    init(_ error: Error) {
        switch ScanFailureKind(error) {
        case .connection: self = .offline
        case .service: self = .service
        case .limit: self = .limit
        case .photo: self = .photo
        }
    }

    var diagnosticName: String {
        switch self {
        case .offline: "offline"
        case .service: "service"
        case .limit: "limit"
        case .photo: "photo"
        }
    }

    var completionMessage: String {
        switch self {
        case .offline:
            "Saved without photo analysis. This iPhone was offline, so the estimate comes from your answers."
        case .service:
            "Saved without photo analysis. Grove's analysis service couldn't finish, so the estimate comes from your answers."
        case .limit:
            "Saved without photo analysis. Today's analysis allowance has been used, so the estimate comes from your answers."
        case .photo:
            "Saved without photo analysis. The photo couldn't be analysed, so the estimate comes from your answers."
        }
    }
}

struct CheckInView: View {
    @Environment(GroveStore.self) private var store
    @Environment(ScanSession.self) private var scanSession
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(\.dismiss) private var dismiss
    let plantID: UUID

    @State private var step = 0
    /// Unanswered until the owner answers. These are recorded as things the
    /// owner observed, so a default here would be a fact nobody stated: a
    /// tap-through used to file "soil comfortable, new growth" every time.
    @State private var appearance: ObservationAppearance?
    @State private var soil: ObservationSoilMoisture?
    @State private var hasNewGrowth: Bool?
    @State private var observationPhoto: UIImage?
    @State private var photoError: String?
    @State private var isFinishing = false
    @State private var completion: CheckInCompletion?
    @State private var showsAIConsent = false
    @State private var didAgreeToAIConsent = false

    private var mediaStore: ObservationMediaStore {
        ObservationMediaStore(rootURL: store.observationMediaDirectory)
    }

    var body: some View {
        if let completion {
            CheckInCompleteView(completion: completion) { dismiss() }
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
                .transition(.opacity)
        } else if let plant = store.plant(id: plantID) {
            VStack(spacing: 0) {
                HStack {
                    GroveEyebrow(text: "Step \(step + 1) of 4", color: GroveTheme.accentStrong)
                    Spacer()
                    Text(stepTitle)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 10)

                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule()
                            .fill(index <= step ? GroveTheme.ink : GroveTheme.separator)
                            .frame(height: 4)
                    }
                }
                .padding(.horizontal, GroveTheme.pagePadding)
                .animation(GroveMotion.snap, value: step)

                Group {
                    switch step {
                    case 0: CheckInIntro(
                        plant: plant,
                        previousCheckIn: previousCheckIn,
                        latestPhotoURL: store.latestPhotoURL(for: plant.id)
                    )
                    case 1: PhotoStep(
                        plant: plant,
                        // Use the same newest image the plant's thumbnail and
                        // detail page use. The initial scan or a diagnosis is a
                        // valid alignment reference even before the plant has a
                        // photographed check-in.
                        ghostURL: store.latestPhotoURL(for: plant.id),
                        ghostDate: ghostCheckInDate(for: plant.id),
                        image: $observationPhoto,
                        errorMessage: $photoError
                    )
                    case 2: ObservationStep(appearance: $appearance, soil: $soil, hasNewGrowth: $hasNewGrowth)
                    default: CheckInReview(plant: plant, appearance: appearance, soil: soil, hasNewGrowth: hasNewGrowth)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Steps slide rather than cut, so the flow reads as one path
                // forward instead of four unrelated screens.
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

                Button {
                    if step < 3 {
                        // A step advancing is a selection, not an outcome. The
                        // finishing tap gets the firmer commit below.
                        Haptics.selection()
                        withAnimation(GroveMotion.settle) { step += 1 }
                    } else {
                        Haptics.commit()
                        Task { await finish(plant: plant) }
                    }
                } label: {
                    GroveCTALabel(
                        title: isFinishing ? (hasComparisonPhoto ? "Comparing with last time…" : "Saving check-in…") : step == 3 ? "Finish check-in" : nextButtonTitle,
                        systemImage: step == 3 ? "checkmark" : "arrow.right"
                    )
                }
                .buttonStyle(GrovePressStyle())
                .accessibilityIdentifier("checkInNext")
                .disabled(isFinishing || (step == 1 && observationPhoto == nil))
                .opacity(isFinishing || (step == 1 && observationPhoto == nil) ? 0.5 : 1)
                .groveActionBar()
            }
            .groveBackground()
            .groveEditorialPage("Check in on \(plant.nickname)")
            .sheet(isPresented: $showsAIConsent, onDismiss: finishAIConsent) {
                AIProcessingConsentView(
                    onAgree: {
                        didAgreeToAIConsent = true
                        showsAIConsent = false
                    },
                    onDecline: {
                        didAgreeToAIConsent = false
                        showsAIConsent = false
                    }
                )
            }
        } else {
            // Reachable from a Siri shortcut or notification for a plant since
            // deleted, here or on another device. Without this the screen drew
            // nothing at all — the only detail screen in the app that answered
            // a missing record with a blank page.
            GroveEmptyState(
                scene: .vanished,
                title: "This plant is gone",
                message: "It was probably removed from your grove, here or on another device."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .groveBackground()
            .groveEditorialPage("Check in")
        }
    }

    /// Whether there is any earlier photo to compare today's with.
    private var hasComparisonPhoto: Bool {
        previousCheckIn != nil || store.latestPhotoURL(for: plantID) != nil
    }

    private var previousCheckIn: PlantObservation? {
        store.observations(for: plantID).first { $0.photoURL != nil }
    }

    /// The ghost is the newest photo of any kind. It only carries a date when
    /// that photo is the previous check-in's, so the camera never dates a
    /// scan or diagnosis photo as a check-in.
    private func ghostCheckInDate(for plantID: UUID) -> Date? {
        guard let checkIn = previousCheckIn,
              let checkInURL = GroveMediaPath.resolved(checkIn.photoURL),
              let latestURL = GroveMediaPath.resolved(store.latestPhotoURL(for: plantID)),
              checkInURL == latestURL else { return nil }
        return checkIn.createdAt
    }

    private var nextButtonTitle: String {
        switch step {
        case 0: "Take today's photo"
        case 1: "Use this one"
        case 2: "See the comparison"
        default: "Continue"
        }
    }

    private var stepTitle: String {
        switch step {
        case 0: "Overview"
        case 1: "Photo"
        case 2: "Observations"
        default: "Ready"
        }
    }

    /// What the check-in concluded, and where that conclusion came from.
    private struct CheckInAssessment {
        let score: Int
        let band: HealthBand
        let summary: String
        let nextActions: [String]?
        var checks: [PlantCheck]? = nil
        let concerns: [String]?
        let positiveSigns: [String]?
        let followUpDays: Int?
        let confidence: Int
        let actionability: DiagnosisActionability?
        let assessmentAvailable: Bool
        let visualFindings: [PlantVisualIndicatorFinding]
        let growingConditions: PlantGrowingConditions?
        let analysisVersion: String?
        let providerName: String?
        let limitations: [String]
        /// Present when the score came from the on-device estimate instead of
        /// a real comparison, with the actual class of failure retained for UI.
        let fallback: CheckInAnalysisFallback?

        var isEstimated: Bool { fallback != nil }
        var appliesToPlant: Bool {
            !isEstimated
                && assessmentAvailable
                && (actionability == nil || actionability == .actionable)
        }
    }

    /// The on-device estimate. It only nudges the previous score by how the user
    /// described the change, and knows nothing about the photo — which is
    /// exactly why it is the fallback and not the answer.
    private func estimatedAssessment(
        for plant: Plant,
        fallback: CheckInAnalysisFallback
    ) -> CheckInAssessment {
        return CheckInAssessment(
            score: plant.healthScore,
            band: plant.healthBand,
            summary: "Saved without photo analysis. Your answers are recorded, and \(plant.nickname)'s health score is unchanged.",
            nextActions: nil,
            concerns: nil,
            positiveSigns: nil,
            followUpDays: 3,
            confidence: 35,
            actionability: .insufficientEvidence,
            assessmentAvailable: false,
            visualFindings: [],
            growingConditions: nil,
            analysisVersion: nil,
            providerName: nil,
            limitations: ["Photo analysis unavailable"],
            fallback: fallback
        )
    }

    /// The observations the owner actually gave, in the gateway's bounded
    /// answer format. The limit is three answers, so all three is at budget.
    private var observationAnswers: [String: String] {
        var answers: [String: String] = [:]
        if let appearance { answers["checkin-appearance"] = appearance.rawValue }
        if let soil { answers["checkin-soil-moisture"] = soil.rawValue }
        if let hasNewGrowth { answers["checkin-new-growth"] = hasNewGrowth ? "yes" : "no" }
        return answers
    }

    /// Compares today's photo with what Grove already knows about this plant.
    ///
    /// The check-in is the product's retention loop and its central promise —
    /// "Grove compares the new evidence with the plant's baseline and recent
    /// history". It used to do no such thing: the score was arithmetic on the
    /// three form answers and the photo was stored and never looked at.
    private func assess(
        plant: Plant,
        imageData: Data,
        previousImageData: Data?,
        qualityWarnings: [ScanImageQualityWarning]
    ) async -> CheckInAssessment {
        do {
            let result = try await scanSession.analyseCheckIn(
                imageData: imageData,
                previousImageData: previousImageData,
                qualityWarnings: qualityWarnings,
                plant: plant,
                regionCode: store.profile.regionCode,
                answers: observationAnswers
            )
            let condition = result.condition
            let assessmentAvailable = condition.assessmentAvailable != false
            let actionable = assessmentAvailable
                && (condition.actionability == nil || condition.actionability == .actionable)
            let score = actionable ? min(100, max(0, condition.healthScore)) : plant.healthScore
            return CheckInAssessment(
                score: score,
                band: actionable ? HealthBand(score: score) : plant.healthBand,
                summary: condition.summary,
                nextActions: condition.nextActions,
                checks: condition.checks,
                concerns: condition.concerns,
                positiveSigns: condition.positiveSigns,
                followUpDays: condition.followUpDays,
                confidence: condition.confidence,
                actionability: condition.actionability,
                assessmentAvailable: assessmentAvailable,
                visualFindings: PlantHealthIndicators.visualFindings(from: condition),
                growingConditions: result.growingConditions,
                analysisVersion: result.analysisVersion,
                providerName: result.providerName,
                limitations: result.limitations,
                fallback: nil
            )
        } catch {
            // Never lose a check-in to an upstream failure: the photo and the user's
            // observations are still recorded. Retain the real failure class so
            // a provider or account fault is never relabelled as "offline".
            let fallback = CheckInAnalysisFallback(error)
            GroveDiag.log(
                "check-in analysis fallback (\(fallback.diagnosticName)): \(error.localizedDescription)"
            )
            return estimatedAssessment(for: plant, fallback: fallback)
        }
    }

    private struct PreviousAnalysisEvidence {
        let data: Data?
        let observationID: UUID?
    }

    private func previousAnalysisEvidence(for plantID: UUID) async -> PreviousAnalysisEvidence {
        let referenceObservation = store.observations(for: plantID).first { $0.photoURL != nil }
        guard let url = referenceObservation?.photoURL ?? store.latestPhotoURL(for: plantID) else {
            return PreviousAnalysisEvidence(data: nil, observationID: nil)
        }
        // Media reads can involve a protected file waking from disk. Keep that
        // work off MainActor so the completion button and progress state remain
        // responsive while Grove prepares the comparison pair.
        let data: Data?
        if url.isFileURL {
            data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
        } else {
            // A short timeout: the reference photo improves the comparison
            // but must never hold "Finish check-in" for a minute on a weak
            // connection. Without it the check-in still saves and scores.
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            data = try? await URLSession.shared.data(for: request).0
        }
        return PreviousAnalysisEvidence(
            data: data,
            observationID: referenceObservation?.id
        )
    }

    /// Agreeing only resumes a finish the person already asked for. Declining
    /// leaves the check-in unsent, with the photo and answers still in place
    /// so they can go back without losing their work.
    private func finishAIConsent() {
        guard didAgreeToAIConsent else { return }
        didAgreeToAIConsent = false
        guard let plant = store.plant(id: plantID) else { return }
        Task { await finish(plant: plant) }
    }

    private func finish(plant: Plant) async {
        guard !isFinishing, let observationPhoto else { return }
        guard AIProcessingConsent.isGranted() else {
            showsAIConsent = true
            return
        }
        isFinishing = true
        defer { isFinishing = false }

        // The "before" half of the saved screen, read before the check-in
        // replaces any of it.
        let previousPhoto = CheckInIntroPhotoReference(
            previousCheckIn: previousCheckIn,
            latestPhotoURL: store.latestPhotoURL(for: plant.id)
        )
        let previousNextCheckIn = plant.nextCheckIn
        let previousBand = plant.healthBand

        // Bound the evidence exactly as the scan flow does. A raw 12 MP capture
        // at quality 0.86 overshoots the gateway's 2 MB per-image limit, which
        // would have made every real check-in fall back to the estimate.
        let prepared = observationPhoto.preparedForPlantAnalysis()

        // The same gate the scan flow runs, on the flow that produces most of
        // Grove's photos. A check-in photo went to the model ungated while the
        // gateway announced "on-device quality gate found no warning" about it,
        // so a photo taken in a dark hallway was scored as clean evidence. A
        // photo the gate cannot read is sent back rather than scored.
        let quality = ScanImageQualityAnalyzer.assess(prepared)
        if let blockingMessage = quality.blockingMessage {
            Haptics.error()
            photoError = blockingMessage
            withAnimation(GroveMotion.settle) { step = 1 }
            return
        }

        guard let payload = prepared.boundedPlantAnalysisJPEG() else {
            Haptics.error()
            photoError = ScanMediaError.invalidImage.localizedDescription
            withAnimation(GroveMotion.settle) { step = 1 }
            return
        }
        let data = payload.data

        do {
            let media = try await mediaStore.save(
                imageData: data,
                pixelWidth: Int(payload.image.size.width * payload.image.scale),
                pixelHeight: Int(payload.image.size.height * payload.image.scale)
            )
            let previousEvidence = await previousAnalysisEvidence(for: plant.id)
            let assessment = await assess(
                plant: plant,
                imageData: data,
                previousImageData: previousEvidence.data,
                qualityWarnings: quality.warnings
            )
            let score = assessment.score
            let band = assessment.band
            let message = assessment.summary
            let indicatorReadings = PlantHealthIndicators.recordedReadings(
                for: plant,
                soil: soil,
                hasNewGrowth: hasNewGrowth,
                visualFindings: assessment.visualFindings,
                growingConditions: assessment.growingConditions,
                tasks: store.tasks,
                assessmentAvailable: assessment.assessmentAvailable && !assessment.isEstimated,
                analysisVersion: assessment.analysisVersion
            )
            // Observations, not a device preference, are the durable signal
            // that Today's one-off first-comparison card has done its job.
            // Resolve this immediately before the write so a check-in restored
            // by sync while analysis was running wins the race correctly.
            let isFirstCheckIn = store.observations(for: plant.id).isEmpty
            let savedObservation = store.applyCheckIn(
                plantID: plant.id,
                score: score,
                band: band,
                note: message,
                // The stored observation still has non-optional fields. The
                // indicator readings above carry whether each was answered,
                // and the moisture estimate reads those, not these defaults.
                appearance: appearance ?? .same,
                soilMoisture: soil ?? .comfortable,
                hasNewGrowth: hasNewGrowth ?? false,
                photoURL: media.fileURL,
                observationID: media.id,
                followUpDays: assessment.followUpDays,
                nextActions: assessment.nextActions,
                checks: assessment.checks,
                concerns: assessment.concerns,
                positiveSigns: assessment.positiveSigns,
                isEstimated: assessment.isEstimated,
                confidence: assessment.confidence,
                appliesToPlant: assessment.appliesToPlant,
                actionability: assessment.actionability,
                assessmentAvailable: assessment.assessmentAvailable,
                analysisVersion: assessment.analysisVersion,
                providerName: assessment.providerName,
                limitations: assessment.limitations,
                referenceObservationID: previousEvidence.observationID,
                indicatorReadings: indicatorReadings,
                growingConditions: assessment.growingConditions
            )
            if isFirstCheckIn, savedObservation != nil {
                CheckInAnalytics.firstCheckInCompleted(estimated: assessment.isEstimated)
            }
            // Send the window the store actually booked, or the server's own
            // follow-up would move the next check-in back on the next bootstrap.
            let usedFollowUpDays = store.plant(id: plant.id).map { saved in
                GroveStore.checkInFollowUpDays(
                    analysisDays: assessment.followUpDays,
                    band: saved.healthBand,
                    preferredDays: saved.checkInFrequencyDays,
                    latitude: store.profile.location?.latitude
                )
            } ?? assessment.followUpDays
            let request = CreateCheckInRequest(
                plantID: plant.id,
                score: score,
                band: band,
                note: message,
                mediaDraftID: media.id,
                clientRequestID: UUID(),
                appearance: appearance,
                soilMoisture: soil,
                hasNewGrowth: hasNewGrowth,
                isEstimated: assessment.isEstimated,
                appliesToPlant: assessment.appliesToPlant,
                confidence: assessment.confidence,
                actionability: assessment.actionability,
                assessmentAvailable: assessment.assessmentAvailable,
                analysisVersion: assessment.analysisVersion,
                providerName: assessment.providerName,
                limitations: assessment.limitations,
                followUpDays: usedFollowUpDays,
                referenceObservationID: previousEvidence.observationID,
                indicatorReadings: indicatorReadings,
                // `applyCheckIn` names the local feed entry after the
                // observation. Sending it keeps the server's mirrored entry on
                // the same id, so a bootstrap folds them into one.
                activityEventID: media.id
            )
            let pendingMedia = PendingMediaUpload(
                localMediaID: media.id,
                fileURL: media.fileURL,
                purpose: .observation,
                mimeType: "image/jpeg",
                pixelWidth: media.pixelWidth,
                pixelHeight: media.pixelHeight
            )
            await syncEngine.enqueue(.uploadMedia(pendingMedia), isConnected: connectivity.isConnected)
            await syncEngine.enqueue(.createCheckIn(request), isConnected: connectivity.isConnected)
            if let updated = store.plant(id: plant.id) {
                await syncEngine.enqueue(
                    .updatePlant(UpdatePlantRequest(plant: updated, clientRequestID: UUID())),
                    isConnected: connectivity.isConnected
                )
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                completion = CheckInCompletion(
                    nickname: plant.nickname,
                    score: score,
                    previousScore: plant.healthScore,
                    band: band,
                    hasNewGrowth: hasNewGrowth ?? false,
                    streak: store.displayStreak,
                    summary: message,
                    nextActions: Array((assessment.nextActions ?? []).prefix(3)),
                    nextCheckInDays: store.plant(id: plant.id)?.daysUntilCheckIn,
                    isEstimated: assessment.isEstimated,
                    analysisFallback: assessment.fallback,
                    healthWasUpdated: assessment.appliesToPlant,
                    previousPhotoURL: previousPhoto.url,
                    previousPhotoDate: previousPhoto.checkInDate,
                    photo: payload.image,
                    checkInNumber: store.observations(for: plant.id).count,
                    savedAt: .now,
                    newGrowthAnswered: hasNewGrowth != nil,
                    soil: soil,
                    previousBand: previousBand,
                    previousNextCheckIn: previousNextCheckIn,
                    nextCheckIn: store.plant(id: plant.id)?.nextCheckIn,
                    longestStreak: store.gardener.longestStreak,
                    // `plant` is the snapshot taken before `applyCheckIn`, so
                    // this is the pre-check-in reading state.
                    isFirstReading: !plant.hasHealthReading
                )
            }
        } catch {
            // A failed save is the one place in this flow the user must not
            // miss, and it silently bounced them back a step before.
            Haptics.error()
            photoError = error.localizedDescription
            withAnimation(GroveMotion.settle) { step = 1 }
        }
    }
}

@MainActor
private enum CheckInAnalytics {
    static func firstCheckInCompleted(estimated: Bool) {
        Task {
            await GroveAnalytics.shared.record(
                "first_checkin_completed",
                ["estimated": String(estimated)]
            )
        }
    }
}

private struct CheckInIntro: View {
    let plant: Plant
    let previousCheckIn: PlantObservation?
    let latestPhotoURL: URL?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                CheckInIntroThumbnail(
                    plant: plant,
                    observation: previousCheckIn,
                    latestPhotoURL: latestPhotoURL,
                    height: dynamicTypeSize.isAccessibilitySize ? 140 : 220
                )
                    .groveHeroShape()
                VStack(alignment: .leading, spacing: 10) {
                    GroveEyebrow(text: "Check-in", color: GroveTheme.accentStrong)
                    Text("So, how's \(plant.nickname)?")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(GroveTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("One photo and three quick questions, set against last time to show which way \(plant.nickname) is heading.")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Label("Under a minute", systemImage: "clock.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.accentStrong)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.vertical, 22)
        }
    }
}

/// The visual reference for today's check-in: the most recent check-in photo
/// when one exists, then the newest photo attached to the plant (its original
/// scan or a diagnosis), and only then the generated illustration.
private struct CheckInIntroThumbnail: View {
    let plant: Plant
    let observation: PlantObservation?
    let latestPhotoURL: URL?
    let height: CGFloat

    @State private var image: UIImage?

    private var reference: CheckInIntroPhotoReference {
        CheckInIntroPhotoReference(
            previousCheckIn: observation,
            latestPhotoURL: latestPhotoURL
        )
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                PlantPortrait(plant: plant, height: height, breathes: true)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .overlay {
            if image != nil {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.62)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let checkInDate = reference.checkInDate, image != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last check-in")
                        .font(.caption.weight(.heavy))
                        .textCase(.uppercase)
                        .tracking(1)
                    Text(checkInDate.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(16)
            }
        }
        // A compact hero should never decode the original capture at full
        // resolution, whether it came from a check-in or the plant's baseline.
        .task(id: reference.url) {
            image = nil
            guard let photoURL = reference.url else { return }
            let thumbnail = await GroveThumbnailCache.thumbnail(at: photoURL, maxDimension: 1200)
            guard !Task.isCancelled else { return }
            image = thumbnail
        }
        .animation(.easeOut(duration: 0.35), value: image)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard image != nil else { return "Illustration of \(plant.nickname)" }
        if let checkInDate = reference.checkInDate {
            return "Last check-in photo of \(plant.nickname), \(checkInDate.formatted(date: .long, time: .omitted))"
        }
        return "Photo of \(plant.nickname)"
    }
}

/// Chooses the same real plant photography used elsewhere in Grove while
/// retaining whether the selected image is specifically a prior check-in.
/// That distinction keeps the date badge and VoiceOver label honest when the
/// fallback is the original scan or a later diagnosis.
struct CheckInIntroPhotoReference: Equatable {
    let url: URL?
    let checkInDate: Date?

    init(previousCheckIn: PlantObservation?, latestPhotoURL: URL?) {
        if let checkInURL = GroveMediaPath.resolved(previousCheckIn?.photoURL) {
            url = checkInURL
            checkInDate = previousCheckIn?.createdAt
        } else {
            url = GroveMediaPath.resolved(latestPhotoURL)
            checkInDate = nil
        }
    }
}

private struct PhotoStep: View {
    let plant: Plant
    let ghostURL: URL?
    var ghostDate: Date? = nil
    @Binding var image: UIImage?
    @Binding var errorMessage: String?

    @State private var ghost: UIImage?
    @State private var isLoadingGhost = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var presentedSheet: CaptureSheet?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Scrolls because it has to: the framing card, the two photo actions and
        // the guidance line are taller than a small phone's step area, and the
        // step is laid out between a fixed header and a fixed footer button.
        ScrollView {
            stepContent
        }
        .scrollBounceBehavior(.basedOnSize)
        .fullScreenCover(item: $presentedSheet) { _ in
            GroveCameraView(
                stage: .wholePlant,
                onCapture: { capturedImage in
                    // The frame filling with the user's own photo is the most
                    // satisfying instant in the flow; it now lands.
                    Haptics.complete()
                    withAnimation(GroveMotion.reveal) {
                        image = capturedImage
                        errorMessage = nil
                    }
                },
                ghostImage: ghost,
                ghostDate: ghostDate,
                plantName: plant.nickname,
                // The photo is the second of the check-in's four steps.
                stepNumber: 2,
                stepCount: 4
            )
            .ignoresSafeArea()
        }
        .task(id: ghostURL) {
            guard let resolvedURL = GroveMediaPath.resolved(ghostURL) else {
                ghost = nil
                isLoadingGhost = false
                return
            }
            isLoadingGhost = true
            let loadedGhost = await GroveImageLoader.downsampledImage(
                at: resolvedURL,
                maxDimension: 2048
            )
            guard !Task.isCancelled else { return }
            ghost = loadedGhost
            isLoadingGhost = false
        }
        .task(id: selectedPhoto) {
            guard let selectedPhoto else { return }
            do {
                guard let data = try await selectedPhoto.loadTransferable(type: Data.self),
                      let selectedImage = UIImage(data: data) else {
                    throw ScanMediaError.invalidImage
                }
                Haptics.complete()
                withAnimation(GroveMotion.reveal) {
                    image = selectedImage
                    errorMessage = nil
                }
            } catch is CancellationError {
                return
            } catch {
                Haptics.error()
                errorMessage = error.localizedDescription
            }
        }
    }

    private var stepContent: some View {
        VStack(spacing: 18) {
            Text(referenceHeading)
                .font(.title2.weight(.bold))
                .foregroundStyle(GroveTheme.ink)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
            ZStack {
                referenceArtwork

                if image == nil {
                    // The inset is shared by the real reference and the
                    // commissioned empty state. It stays in SwiftUI so the
                    // generated art remains artwork rather than baked-in UI.
                    RoundedRectangle(cornerRadius: GroveTheme.heroRadius, style: .continuous)
                        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(26)
                }

                VStack(spacing: 0) {
                    HStack {
                        Label(frameBadgeTitle, systemImage: frameBadgeIcon)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.58), in: Capsule())
                        Spacer()
                    }
                    .padding(16)

                    Spacer()

                    Label(frameStatusTitle, systemImage: frameStatusIcon)
                        .font(.subheadline.weight(.semibold))
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding()
                        // The status swaps between three states as the step
                        // progresses; cross-fading keeps it from flickering.
                        .contentTransition(.opacity)
                        .id(image != nil)
                }
            }
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 230 : 360)
            .groveHeroShape()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(frameAccessibilityLabel)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { photoActions }
                VStack(spacing: 10) { photoActions }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.danger)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Text("Whole plant in frame, similar light. The closer the two photos match, the clearer the comparison.")
                .font(.footnote)
                .foregroundStyle(GroveTheme.mutedInk)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, GroveTheme.pagePadding)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var referenceArtwork: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if let ghost {
            // The real latest plant image always wins. A restrained wash makes
            // the white alignment marks readable without hiding the detail the
            // user is trying to reproduce.
            Image(uiImage: ghost)
                .resizable()
                .scaledToFill()
                .overlay(.black.opacity(0.16))
        } else {
            // Commissioned specifically for this state. It teaches "whole
            // plant, calm background" without pretending to be the user's
            // plant; an available latest thumbnail replaces it.
            Image("CheckInAlignmentGuide")
                .resizable()
                .scaledToFill()
                .overlay(.black.opacity(0.08))
                .overlay {
                    if isLoadingGhost {
                        ProgressView()
                            .tint(.white)
                            .padding(12)
                            .background(.black.opacity(0.28), in: Circle())
                    }
                }
        }
    }

    private var referenceHeading: String {
        ghost != nil || isLoadingGhost ? "Same angle as last time" : "Frame the whole plant"
    }

    private var frameBadgeTitle: String {
        if image != nil { return "Today" }
        if ghost != nil { return "Latest photo" }
        if isLoadingGhost { return "Loading photo" }
        return "Photo guide"
    }

    private var frameBadgeIcon: String {
        if image != nil { return "camera.fill" }
        if ghost != nil { return "clock.arrow.circlepath" }
        if isLoadingGhost { return "photo" }
        return "viewfinder"
    }

    private var frameStatusTitle: String {
        if image != nil { return "Ready to compare" }
        if ghost != nil { return "Match this framing" }
        if isLoadingGhost { return "Finding the latest photo" }
        return "Take today's photo"
    }

    private var frameStatusIcon: String {
        image != nil ? "checkmark.circle.fill" : "camera.fill"
    }

    private var frameAccessibilityLabel: String {
        if image != nil {
            return "Today's selected plant photo. Ready to compare."
        }
        if ghost != nil {
            return "Latest plant photo. Match this angle and framing for today's photo."
        }
        if isLoadingGhost {
            return "Loading the latest plant photo."
        }
        return "Plant photo guide. Keep the whole plant inside the frame."
    }

    @ViewBuilder
    private var photoActions: some View {
        GroveInkButton(
            title: canUseCamera ? "Camera" : "Demo photo",
            systemImage: "camera.fill"
        ) {
            if canUseCamera {
                presentedSheet = .camera
            } else {
                Haptics.complete()
                withAnimation(GroveMotion.reveal) {
                    image = demoPlantImage()
                    errorMessage = nil
                }
            }
        }

        PhotosPicker(selection: $selectedPhoto, matching: .images) {
            GroveOutlineLabel(title: "Library", systemImage: "photo.on.rectangle")
        }
    }

    private var canUseCamera: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        UIImagePickerController.isSourceTypeAvailable(.camera)
        #endif
    }

    private func demoPlantImage() -> UIImage {
        let size = CGSize(width: 900, height: 1200)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.16, green: 0.42, blue: 0.23, alpha: 1).setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            UIImage(systemName: plant.symbol)?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 190, y: 340, width: 520, height: 520))
        }
    }
}

private struct ObservationStep: View {
    @Binding var appearance: ObservationAppearance?
    @Binding var soil: ObservationSoilMoisture?
    @Binding var hasNewGrowth: Bool?

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(ObservationAppearance.allCases) { value in
                        Text(value.title).tag(Optional(value))
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Next to last time, it looks…")
            }
            Section {
                Picker("Soil, two knuckles down", selection: $soil) {
                    Text("Didn't check").tag(ObservationSoilMoisture?.none)
                    ForEach(ObservationSoilMoisture.allCases) { value in
                        Text(value.title).tag(Optional(value))
                    }
                }
                LabeledContent("New growth") {
                    Picker("New growth", selection: $hasNewGrowth) {
                        Text("Yes").tag(Bool?.some(true))
                        Text("No").tag(Bool?.some(false))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 140)
                }
            } header: {
                Text("Things a photo can't see")
            } footer: {
                Text("Skip anything you didn't check. Only your answers are saved.")
            }
        }
        .groveGroupedContent()
    }
}

/// The pre-flight step: what Grove is about to compare, and nothing more.
///
/// This screen used to display a health score and a "+3 since last time" delta
/// computed on-device *before* anything had been assessed — a number presented
/// as a finding that was really just arithmetic on the three answers above it.
/// The real figure now arrives on the completion screen, once the comparison
/// has actually run.
private struct CheckInReview: View {
    let plant: Plant
    let appearance: ObservationAppearance?
    let soil: ObservationSoilMoisture?
    let hasNewGrowth: Bool?

    private var appearanceDetail: String {
        switch appearance {
        case .better: "Better than last time"
        case .same: "Same as last time"
        case .worse: "Worse than last time"
        case nil: "Not answered"
        }
    }

    private var growthDetail: String {
        switch hasNewGrowth {
        case true?: "You saw some"
        case false?: "None spotted"
        case nil: "Not answered"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(GroveTheme.accent)
                    .padding(22)
                    .background(GroveTheme.accent.opacity(0.12), in: Circle())

                VStack(spacing: 10) {
                    Text("Ready when you are")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(GroveTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                        .multilineTextAlignment(.center)
                    Text("Today's photo is compared with \(plant.nickname)'s baseline and every check-in since, so you can see which way it's going.")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 12) {
                    reviewRow(icon: "photo.fill", title: "Today's photo", detail: "Captured and ready")
                    Divider()
                    reviewRow(icon: "eye.fill", title: "Looks", detail: appearanceDetail)
                    Divider()
                    reviewRow(icon: "drop.fill", title: "Soil", detail: soil?.title ?? "Didn't check")
                    Divider()
                    reviewRow(
                        icon: "leaf.fill",
                        title: "New growth",
                        detail: growthDetail
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .groveCard()

                Text("This score comes from one photo and your answers. It is a best guess, not a diagnosis.")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.vertical, 24)
        }
    }

    private func reviewRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            GroveSymbolTile(symbol: icon, size: 34)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(GroveTheme.ink)
            Spacer(minLength: 8)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mutedInk)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Completion

/// Snapshot of a saved check-in used to drive the celebratory finish screen.
struct CheckInCompletion: Equatable {
    let nickname: String
    let score: Int
    let previousScore: Int
    let band: HealthBand
    let hasNewGrowth: Bool
    let streak: Int
    /// What the comparison actually concluded.
    var summary: String = ""
    /// The next steps it recommended, at most three.
    var nextActions: [String] = []
    /// Days until the follow-up it scheduled.
    var nextCheckInDays: Int? = nil
    /// True when photo analysis did not complete and this came from the
    /// on-device estimate — the user is told, rather than being shown a guess
    /// as a result.
    var isEstimated: Bool = false
    /// The actual reason for the estimate. Optional preserves existing call
    /// sites and old completion fixtures while avoiding a false offline claim.
    var analysisFallback: CheckInAnalysisFallback? = nil
    /// False when the photo or policy gate could not support a new canonical
    /// health assessment. The observations still save, but the previous health
    /// reading remains authoritative.
    var healthWasUpdated: Bool = true
    /// The photo today's is compared with, and its date when it was itself a
    /// check-in (nil for a scan or diagnosis photo).
    var previousPhotoURL: URL? = nil
    var previousPhotoDate: Date? = nil
    /// Today's photo, as it was sent for analysis.
    var photo: UIImage? = nil
    /// Which check-in this was for the plant, counting this one. Zero when
    /// unknown.
    var checkInNumber: Int = 0
    var savedAt: Date = .now
    /// False when the owner skipped the new-growth question.
    var newGrowthAnswered: Bool = true
    var soil: ObservationSoilMoisture? = nil
    var previousBand: HealthBand? = nil
    /// The check-in schedule before and after this one moved it.
    var previousNextCheckIn: Date? = nil
    var nextCheckIn: Date? = nil
    var longestStreak: Int = 0
    /// True when this check-in produced the plant's first real health reading.
    /// There is no previous measurement, so the screen must not show a change.
    var isFirstReading: Bool = false

    var delta: Int { score - previousScore }
    var trend: HealthTrend {
        if isFirstReading { return .baseline }
        return GroveStore.trend(from: previousScore, to: score)
    }

    /// One warm sentence tailored to what the observations showed.
    var takeaway: String {
        if !healthWasUpdated {
            return "Your observations are saved. The previous health score stays, because today's photo wasn't clear enough to replace it."
        }
        if isFirstReading {
            return "This is \(nickname)'s first real reading. Keep checking in so Grove can show you what changes."
        }
        switch trend {
        case .improving:
            return "\(nickname) is better than last time. Your care is helping. Keep the same routine for now."
        case .stable, .baseline:
            return "\(nickname) is holding steady. Keep checking in so you can catch any change early."
        case .declining:
            return "You spotted this early. Follow the new steps and your next check-in will come sooner."
        }
    }
}

/// Full-screen finish screen shown after a check-in saves successfully.
///
/// Read like an arrivals board: last time and today side by side, one line
/// that says which way the plant went, then the numbers, the schedule changes
/// Grove just made, and Ari's read. The screen takes its tone from what the
/// comparison actually found: confetti only for real improvement or a long
/// streak, and a calm haptic for news the owner needs to act on.
private struct CheckInCompleteView: View {
    let completion: CheckInCompletion
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// How far through the arrival the screen has got: photos, numbers, cards.
    @State private var beat = 0

    /// Confetti is earned, not automatic. Throwing it at bad news is how an app
    /// tells a user it was not paying attention.
    private var deservesConfetti: Bool {
        completion.healthWasUpdated && (completion.trend == .improving || completion.streak >= 7)
    }

    private var photoHeight: CGFloat { dynamicTypeSize.isAccessibilitySize ? 260 : 380 }

    var body: some View {
        ZStack(alignment: .top) {
            GroveTheme.surface.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    photoPair

                    VStack(alignment: .leading, spacing: 0) {
                        header
                            .padding(.horizontal, GroveTheme.pagePadding)
                            .padding(.bottom, 24)

                        VStack(alignment: .leading, spacing: 22) {
                            CaptureStatGrid(stats: headlineStats, large: true)
                            CaptureStatGrid(stats: observationStats)
                        }
                        .padding(.horizontal, GroveTheme.pagePadding)
                        .opacity(beat >= 2 ? 1 : 0)
                        .offset(y: beat >= 2 ? 0 : 12)

                        VStack(spacing: 16) {
                            changesCard
                            ariCard
                            streakCard
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 26)
                        .padding(.bottom, 16)
                        .opacity(beat >= 3 ? 1 : 0)
                        .offset(y: beat >= 3 ? 0 : 12)
                    }
                    .padding(.top, 28)
                    .captureSheet()
                    .padding(.top, -40)
                }
            }
            .ignoresSafeArea(edges: .top)
            // Docked rather than floated: as an overlay it covered the last
            // card once the page was scrolled to the end.
            .safeAreaInset(edge: .bottom) { dock }

            if deservesConfetti && beat >= 1 && !reduceMotion {
                ConfettiBurstView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            topChrome
        }
        .task { await choreograph() }
    }

    // MARK: Photos

    @ViewBuilder private var photoPair: some View {
        HStack(spacing: 2) {
            if completion.previousPhotoURL != nil {
                photoPane(tag: beforeTag) {
                    CaptureStoredPhoto(url: completion.previousPhotoURL)
                }
                .accessibilityLabel(beforeAccessibilityLabel)
            }
            photoPane(tag: "Today") {
                if let photo = completion.photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                } else {
                    GroveTheme.mapGround
                }
            }
            .accessibilityLabel("\(completion.nickname) today")
        }
        .frame(height: photoHeight)
        .opacity(beat >= 1 ? 1 : 0)
    }

    private func photoPane<Content: View>(tag: String, @ViewBuilder content: () -> Content) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: photoHeight)
            .overlay { content() }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                CapturePhotoTag(text: tag)
                    .padding(.leading, 12)
                    .padding(.bottom, 52)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isImage)
    }

    private var beforeTag: String {
        completion.previousPhotoDate?.formatted(.dateTime.day().month(.abbreviated)) ?? "Last photo"
    }

    private var beforeAccessibilityLabel: String {
        guard let date = completion.previousPhotoDate else {
            return "The last photo of \(completion.nickname)"
        }
        return "\(completion.nickname) at the last check-in, \(date.formatted(date: .long, time: .omitted))"
    }

    private var topChrome: some View {
        HStack {
            CaptureHintCapsule(
                text: completion.checkInNumber > 0 ? "Check-in \(completion.checkInNumber) saved" : "Check-in saved",
                dot: GroveTheme.mapThriving
            )
            Spacer(minLength: 8)
            Button(action: onClose) {
                CaptureGlassChip(systemImage: "xmark")
            }
            .buttonStyle(GroveTilePressStyle())
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(savedLine.uppercased())
                .font(.footnote.weight(.medium))
                .tracking(0.6)
                .foregroundStyle(GroveTheme.subtleInk)
            Text(headline)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(completion.takeaway)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private var savedLine: String {
        let day = completion.savedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let time = completion.savedAt.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(time)"
    }

    /// Which way the plant went, in the plant's name. Kept apart from
    /// `takeaway`, which sits directly beneath it in its own words.
    private var headline: String {
        let name = completion.nickname
        guard completion.healthWasUpdated else { return "\(name)'s check-in is saved" }
        if completion.isFirstReading { return "First health reading: \(completion.score)" }
        switch completion.trend {
        case .improving:
            let wasStruggling = completion.previousBand == .attention || completion.previousBand == .urgent
            return wasStruggling ? "\(name) is recovering" : "\(name) is looking better"
        case .stable, .baseline:
            return "\(name) is steady"
        case .declining:
            return "\(name) needs attention"
        }
    }

    // MARK: Numbers

    private var headlineStats: [CaptureStat] {
        let health = CaptureStat(
            label: "Health",
            value: "\(completion.score)",
            trend: completion.healthWasUpdated ? completion.trend : nil
        )
        // A first reading has no previous measurement to subtract from, so the
        // change stat would be a delta against the hidden placeholder score.
        if completion.isFirstReading { return [health] }
        return [health, changeStat]
    }

    private var changeStat: CaptureStat {
        guard completion.healthWasUpdated else {
            return CaptureStat(label: "Change", value: "Kept", tint: GroveTheme.mutedInk)
        }
        let delta = completion.delta
        let value = delta > 0 ? "+\(delta)" : delta < 0 ? "\u{2212}\(-delta)" : "0"
        switch completion.trend {
        case .improving:
            return CaptureStat(label: "Change", value: value, tint: GroveTheme.healthThriving)
        case .declining:
            return CaptureStat(label: "Change", value: value, tint: GroveTheme.danger)
        case .stable, .baseline:
            return CaptureStat(label: "Change", value: value)
        }
    }

    private var observationStats: [CaptureStat] {
        var stats: [CaptureStat] = []
        if completion.newGrowthAnswered {
            stats.append(CaptureStat(label: "New growth", value: completion.hasNewGrowth ? "Yes" : "None seen"))
        }
        if let soil = completion.soil {
            let phrase = soil.feltPhrase
            let value = String(phrase.prefix(1)).uppercased() + String(phrase.dropFirst())
            stats.append(CaptureStat(label: "Soil", value: value))
        }
        return stats
    }

    // MARK: Cards

    /// Only the changes this check-in actually made: the follow-up it booked,
    /// and the health reading when the evidence was strong enough to replace it.
    @ViewBuilder private var changesCard: some View {
        let rows = changeRows
        if !rows.isEmpty {
            CaptureCard(title: "What changed") {
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        let row = rows[index]
                        CaptureChangeRow(
                            title: row.title,
                            was: row.was,
                            now: row.now,
                            nowTint: row.tint,
                            isLast: index == rows.count - 1
                        )
                    }
                }
            }
        }
    }

    private struct ChangeRowModel {
        let title: String
        let was: String
        let now: String
        let tint: Color
    }

    private var changeRows: [ChangeRowModel] {
        var rows: [ChangeRowModel] = []
        if let was = completion.previousNextCheckIn, let now = completion.nextCheckIn {
            rows.append(ChangeRowModel(
                title: "Next check-in",
                was: Self.dayText(was),
                now: Self.dayText(now),
                tint: GroveTheme.healthThriving
            ))
        }
        if completion.healthWasUpdated {
            let healthTint: Color
            if completion.isFirstReading {
                healthTint = GroveTheme.healthThriving
            } else {
                healthTint = completion.trend == .declining ? GroveTheme.danger : GroveTheme.healthThriving
            }
            rows.append(ChangeRowModel(
                title: "Health",
                was: completion.isFirstReading ? "None" : "\(completion.previousScore)",
                now: "\(completion.score)",
                tint: healthTint
            ))
            if !completion.isFirstReading,
               let previousBand = completion.previousBand,
               previousBand != completion.band {
                rows.append(ChangeRowModel(
                    title: "Status",
                    was: previousBand.shortTitle,
                    now: completion.band.shortTitle,
                    tint: completion.band.color
                ))
            }
        }
        return rows
    }

    /// "Today", "Tomorrow", a weekday inside the week, a date beyond it.
    private static func dayText(_ date: Date) -> String {
        let calendar = Calendar.current
        let offset = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch offset {
        case ..<0: return date.formatted(.dateTime.day().month(.abbreviated))
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2...6: return date.formatted(.dateTime.weekday(.abbreviated).day())
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    /// What the comparison actually said, and what to do about it.
    @ViewBuilder private var ariCard: some View {
        let showsWarning = completion.isEstimated || !completion.healthWasUpdated
        if !completion.summary.isEmpty || !completion.nextActions.isEmpty || showsWarning {
            CaptureDarkCard(eyebrow: "Diagnosis") {
                if !completion.summary.isEmpty {
                    Text(completion.summary)
                        .font(.body)
                        .foregroundStyle(GroveTheme.mapCode)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(Array(completion.nextActions.enumerated()), id: \.offset) { index, action in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.heavy))
                            .monospacedDigit()
                            .foregroundStyle(GroveTheme.mapGround)
                            .frame(width: 22, height: 22)
                            .background(GroveTheme.mapThriving, in: Circle())
                        Text(action)
                            .font(.subheadline)
                            .foregroundStyle(GroveTheme.mapCode)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }

                if completion.isEstimated {
                    Label(
                        completion.analysisFallback?.completionMessage
                            ?? "Saved without photo analysis. This estimate comes from your answers, not the photo.",
                        systemImage: completion.analysisFallback == .offline
                            ? "wifi.exclamationmark"
                            : "exclamationmark.arrow.triangle.2.circlepath"
                    )
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.warningOnPhoto)
                    .fixedSize(horizontal: false, vertical: true)
                } else if !completion.healthWasUpdated {
                    Label(
                        "No new health score was recorded. Take a clearer, well-aligned photo at the follow-up.",
                        systemImage: "camera.metering.unknown"
                    )
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.warningOnPhoto)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var streakCard: some View {
        if completion.streak > 0 {
            HStack(spacing: 14) {
                Image(systemName: "flame.fill")
                    .font(.title3)
                    .foregroundStyle(GroveTheme.streak)
                    .frame(width: 44, height: 44)
                    .background(GroveTheme.streak.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(completion.streak == 1 ? "1 day" : "\(completion.streak) days")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(GroveTheme.ink)
                    Text(streakNote)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                    .strokeBorder(GroveTheme.separator, lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var streakNote: String {
        if completion.streak > 1, completion.streak >= completion.longestStreak {
            return "Your longest streak yet"
        }
        if completion.longestStreak > completion.streak {
            return completion.longestStreak == 1 ? "Best so far: 1 day" : "Best so far: \(completion.longestStreak) days"
        }
        return "Day streak"
    }

    // MARK: Dock

    private var dock: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            shareButton
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 150)
            Button(action: onClose) {
                GroveCTALabel(title: "Done", systemImage: "checkmark")
            }
            .buttonStyle(GrovePressStyle())
        }
        .groveActionBar()
    }

    @ViewBuilder private var shareButton: some View {
        if let photo = completion.photo {
            ShareLink(
                item: Image(uiImage: photo),
                preview: SharePreview("\(completion.nickname) today", image: Image(uiImage: photo))
            ) {
                GroveOutlineLabel(title: "Share", systemImage: "square.and.arrow.up")
            }
        } else {
            ShareLink(item: shareText) {
                GroveOutlineLabel(title: "Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var shareText: String {
        "\(headline). Health \(completion.score) on Grove."
    }

    // MARK: Arrival

    /// Walks the screen through its beats. One `task` rather than a scatter of
    /// delayed animations, so leaving mid-arrival cancels the rest instead of
    /// firing haptics into an empty room.
    private func choreograph() async {
        guard beat == 0 else { return }

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { beat = 3 }
            Haptics.success()
            return
        }

        Haptics.prepare()
        withAnimation(.easeOut(duration: 0.35)) { beat = 1 }
        // The rhythm matches the tone: a rise for good news, a single warm
        // landing for news the owner needs to act on.
        switch completion.trend {
        case .improving: Haptics.celebrate()
        case .stable, .baseline: Haptics.complete()
        case .declining: Haptics.arrive()
        }

        try? await Task.sleep(nanoseconds: 220_000_000)
        withAnimation(GroveMotion.reveal) { beat = 2 }

        try? await Task.sleep(nanoseconds: 200_000_000)
        withAnimation(GroveMotion.reveal) { beat = 3 }
    }
}
