import AVFoundation
import CoreVideo
import SwiftUI
import Vision

// MARK: - Reading

/// One frame's worth of live scan intelligence, produced off-main and folded
/// into `LiveScanModel` on the main actor. Everything here is *measured*: the
/// HUD never claims a signal it didn't compute.
struct LiveScanReading: Sendable {
    /// Confidence that a plant-family subject is in frame (0–1), from the
    /// on-device Vision classifier's botanical labels.
    let plantConfidence: Double
    /// The strongest matching classifier label ("fern", "cactus", …), when one
    /// is specific enough to say out loud.
    let plantLabel: String?
    /// Mean luminance of the frame, 0–255.
    let luminance: Double
    /// Average Laplacian magnitude — the same sharpness measure the still
    /// quality gate uses, so live coaching and capture rejection agree.
    let sharpness: Double
    /// Fraction of the frame the salient subject occupies (0–1), or nil when
    /// saliency found nothing this pass.
    let subjectFill: Double?
}

// MARK: - Analyzer

/// Consumes preview frames on the camera's frame queue and turns them into
/// `LiveScanReading`s. All Vision work happens synchronously on that queue;
/// `alwaysDiscardsLateVideoFrames` provides the backpressure, and a time gate
/// keeps the duty cycle low enough for an all-day camera.
final class LiveFrameAnalyzer: @unchecked Sendable {
    private let onReading: @Sendable (LiveScanReading) -> Void
    private var lastProcessed: TimeInterval = 0
    private var passIndex = 0
    /// Saliency's subject box, remembered between the alternating passes so
    /// the fill signal doesn't blink off every other reading.
    private var lastSubjectFill: Double?

    private let classifyRequest = VNClassifyImageRequest()
    private let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()

    /// Minimum spacing between processed frames. ~4 readings a second is
    /// plenty for a human-facing readout and keeps thermals invisible.
    private static let interval: TimeInterval = 0.24

    init(onReading: @escaping @Sendable (LiveScanReading) -> Void) {
        self.onReading = onReading
    }

    /// Called on the camera frame queue. Synchronous by design: while a frame
    /// is being analysed here, AVFoundation discards the frames behind it.
    func submit(_ buffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastProcessed >= Self.interval else { return }
        lastProcessed = now
        passIndex += 1

        guard let metrics = Self.lumaMetrics(from: buffer) else { return }

        var plantConfidence = 0.0
        var plantLabel: String?
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])

        // Saliency is the heavier request; alternating it against the
        // classifier halves the sustained cost without the HUD noticing.
        let runSaliency = passIndex.isMultiple(of: 2)
        let requests: [VNRequest] = runSaliency ? [classifyRequest, saliencyRequest] : [classifyRequest]
        try? handler.perform(requests)

        if let observations = classifyRequest.results {
            for observation in observations.prefix(60) {
                guard let score = Self.botanicalScore(for: observation.identifier) else { continue }
                let weighted = Double(observation.confidence) * score
                if weighted > plantConfidence {
                    plantConfidence = weighted
                    plantLabel = Self.friendlyLabels[observation.identifier]
                }
            }
        }

        if runSaliency {
            if let salient = saliencyRequest.results?.first?.salientObjects, !salient.isEmpty {
                let fill = salient.reduce(0.0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
                lastSubjectFill = min(1, fill)
            } else {
                lastSubjectFill = nil
            }
        }

        onReading(
            LiveScanReading(
                plantConfidence: min(1, plantConfidence),
                plantLabel: plantLabel,
                luminance: metrics.mean,
                sharpness: metrics.sharpness,
                subjectFill: lastSubjectFill
            )
        )
    }

    // MARK: Botanical lexicon

    /// Labels in Vision's on-device taxonomy that mean "this is plant matter",
    /// with a weight for how strongly. Exact matches only — substring matching
    /// would let "plantation_shutter"-style labels through.
    private static let botanicalWeights: [String: Double] = [
        "plant": 1.0, "houseplant": 1.0, "flower": 1.0, "foliage": 1.0,
        "leaf": 1.0, "tree": 0.9, "shrub": 1.0, "herb": 0.9, "vine": 1.0,
        "fern": 1.0, "cactus": 1.0, "succulent": 1.0, "moss": 0.9,
        "palm_tree": 1.0, "bamboo": 1.0, "bonsai": 1.0, "ivy": 1.0,
        "orchid": 1.0, "rose": 1.0, "tulip": 1.0, "sunflower": 1.0,
        "lily": 1.0, "daisy": 1.0, "lavender": 1.0, "hydrangea": 1.0,
        "flower_arrangement": 0.8, "bouquet": 0.8, "vegetation": 0.9,
        "grass": 0.7, "flowerpot": 0.8, "garden": 0.7, "greenhouse": 0.7,
        "petal": 1.0, "blossom": 1.0, "branch": 0.7, "aloe": 1.0
    ]

    private static func botanicalScore(for identifier: String) -> Double? {
        botanicalWeights[identifier]
    }

    /// The subset of labels specific enough to be worth saying to the user.
    /// "Looks like a fern" is delightful when true; "looks like vegetation"
    /// is a robot talking.
    private static let friendlyLabels: [String: String] = [
        "fern": "a fern", "cactus": "a cactus", "succulent": "a succulent",
        "orchid": "an orchid", "palm_tree": "a palm", "bamboo": "bamboo",
        "bonsai": "a bonsai", "ivy": "an ivy", "moss": "moss",
        "rose": "a rose", "tulip": "a tulip", "sunflower": "a sunflower",
        "lily": "a lily", "lavender": "lavender", "aloe": "an aloe",
        "hydrangea": "a hydrangea", "flower": "a flowering plant"
    ]

    // MARK: Luma metrics

    /// Mean luminance and Laplacian sharpness from a sparse sample of the BGRA
    /// buffer — a few thousand pixels, cheap enough to run on every pass.
    private static func lumaMetrics(from buffer: CVPixelBuffer) -> (mean: Double, sharpness: Double)? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 8, height > 8 else { return nil }

        let gridW = 72
        let gridH = max(8, gridW * height / width)
        let stepX = max(1, width / gridW)
        let stepY = max(1, height / gridH)
        let sampledW = width / stepX
        let sampledH = height / stepY
        var luma = [UInt8](repeating: 0, count: sampledW * sampledH)

        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var total = 0.0
        for row in 0..<sampledH {
            let rowStart = row * stepY * bytesPerRow
            for col in 0..<sampledW {
                let offset = rowStart + col * stepX * 4
                let b = Double(pixels[offset])
                let g = Double(pixels[offset + 1])
                let r = Double(pixels[offset + 2])
                let value = 0.114 * b + 0.587 * g + 0.299 * r
                luma[row * sampledW + col] = UInt8(clamping: Int(value))
                total += value
            }
        }
        let mean = total / Double(sampledW * sampledH)

        var laplacianTotal = 0.0
        var samples = 0
        for row in 1..<(sampledH - 1) {
            for col in 1..<(sampledW - 1) {
                let index = row * sampledW + col
                let centre = Int(luma[index]) * 4
                let neighbours = Int(luma[index - 1]) + Int(luma[index + 1])
                    + Int(luma[index - sampledW]) + Int(luma[index + sampledW])
                laplacianTotal += Double(abs(centre - neighbours))
                samples += 1
            }
        }
        let sharpness = samples == 0 ? 0 : laplacianTotal / Double(samples)
        return (mean, sharpness)
    }
}

// MARK: - Model

/// The scan HUD's brain: folds readings into smoothed signals and a small,
/// deliberately sticky state machine. Sticky because a reticle that flickers
/// between "found" and "lost" four times a second reads as broken — locking
/// takes sustained evidence, and unlocking takes sustained absence.
@MainActor
@Observable
final class LiveScanModel {
    enum Phase: Equatable {
        case searching
        case sighted
        case locked
    }

    enum Hint: Equatable {
        case light, glare, closer, steady

        var line: String {
            switch self {
            case .light: "More light on the leaves"
            case .glare: "Too bright. Step out of the glare"
            case .closer: "Move closer so it fills the frame"
            case .steady: "Hold steady"
            }
        }

        var symbol: String {
            switch self {
            case .light: "sun.min"
            case .glare: "sun.max.fill"
            case .closer: "arrow.down.left.and.arrow.up.right"
            case .steady: "hand.raised"
            }
        }
    }

    private(set) var phase: Phase = .searching
    private(set) var hint: Hint?
    /// "a fern", "an orchid" — only set when the classifier is specific.
    private(set) var friendlyLabel: String?
    /// 0–1 meter values for the telemetry row.
    private(set) var lightScore: Double = 0
    private(set) var focusScore: Double = 0
    private(set) var frameScore: Double = 0

    var isLocked: Bool { phase == .locked }

    private var presence = 0.0
    private var luminance = 0.0
    private var sharpness = 0.0
    private var fill = 0.0
    private var goodStreak = 0
    private var lostStreak = 0
    private var analyzer: LiveFrameAnalyzer?

    // Thresholds tuned against the still-photo quality gate's scale.
    private static let presenceFound = 0.30
    private static let presenceLost = 0.18
    private static let sharpEnough = 3.6
    private static let fillEnough = 0.14

    func attach(to engine: CameraEngine) {
        guard analyzer == nil else { return }
        let analyzer = LiveFrameAnalyzer { [weak self] reading in
            Task { @MainActor [weak self] in
                self?.ingest(reading)
            }
        }
        self.analyzer = analyzer
        engine.installFrameTap { buffer in
            analyzer.submit(buffer)
        }
    }

    func detach(from engine: CameraEngine) {
        engine.removeFrameTap()
        analyzer = nil
        reset()
    }

    private func reset() {
        phase = .searching
        hint = nil
        friendlyLabel = nil
        presence = 0
        goodStreak = 0
        lostStreak = 0
        lightScore = 0
        focusScore = 0
        frameScore = 0
    }

    private func ingest(_ reading: LiveScanReading) {
        // Exponential smoothing: fast enough to feel live, slow enough that a
        // single bad frame can't yank the HUD around.
        let alpha = 0.42
        presence += (reading.plantConfidence - presence) * alpha
        luminance += (reading.luminance - luminance) * alpha
        sharpness += (reading.sharpness - sharpness) * alpha
        if let subjectFill = reading.subjectFill {
            fill += (subjectFill - fill) * alpha
        }
        if let label = reading.plantLabel {
            friendlyLabel = label
        } else if presence < Self.presenceLost {
            friendlyLabel = nil
        }

        lightScore = Self.bandScore(luminance, goodLow: 70, goodHigh: 190, floorLow: 22, ceilingHigh: 242)
        focusScore = min(1, sharpness / 8.5)
        frameScore = min(1, fill / 0.32)

        let present = presence >= Self.presenceFound
        let tooDark = luminance < 45
        let tooBright = luminance > 215
        let soft = sharpness < Self.sharpEnough
        let small = fill < Self.fillEnough
        let qualityGood = !tooDark && !tooBright && !soft

        switch phase {
        case .locked:
            if presence < Self.presenceLost {
                lostStreak += 1
                if lostStreak >= 4 {
                    phase = .searching
                    goodStreak = 0
                    lostStreak = 0
                }
            } else {
                lostStreak = 0
            }
            hint = nil

        case .searching, .sighted:
            lostStreak = 0
            if present {
                phase = .sighted
                hint = tooDark ? .light : (tooBright ? .glare : (small ? .closer : (soft ? .steady : nil)))
                if qualityGood && !small {
                    goodStreak += 1
                    if goodStreak >= 3 {
                        phase = .locked
                        hint = nil
                        Haptics.selection()
                    }
                } else {
                    goodStreak = 0
                }
            } else {
                phase = .searching
                hint = nil
                goodStreak = 0
            }
        }
    }

    /// 1 inside the good band, easing to 0 at the hard limits.
    private static func bandScore(
        _ value: Double,
        goodLow: Double,
        goodHigh: Double,
        floorLow: Double,
        ceilingHigh: Double
    ) -> Double {
        if value >= goodLow && value <= goodHigh { return 1 }
        if value < goodLow {
            return max(0, (value - floorLow) / (goodLow - floorLow))
        }
        return max(0, (ceilingHigh - value) / (ceilingHigh - goodHigh))
    }
}

// MARK: - Reticle

/// Four corner brackets that live on the camera preview. Searching, they
/// breathe at the frame's edge; on lock they draw in around the subject and
/// take the accent — the screen's one unmistakable "Grove can see it".
struct LiveScanReticle: View {
    let phase: LiveScanModel.Phase
    /// Smoothed subject-fill score (0–1); a fuller subject pulls the brackets
    /// in tighter.
    let frameScore: Double
    /// True only when the camera came from the raised tab-bar action. Captured
    /// into local state so a parent marking the one-shot handoff consumed does
    /// not interrupt the animation already in flight.
    @State private var performsEntryAnimation: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasEntered = false

    init(phase: LiveScanModel.Phase, frameScore: Double, animatesEntry: Bool = false) {
        self.phase = phase
        self.frameScore = frameScore
        _performsEntryAnimation = State(initialValue: animatesEntry)
    }

    private var lockedScale: CGFloat {
        // 0.96 down to 0.84 as the subject fills the frame.
        0.96 - 0.12 * min(1, max(0, frameScore))
    }

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 0
            let arm: CGFloat = 28
            ZStack {
                ForEach(0..<4, id: \.self) { corner in
                    GroveScanReticleCorner()
                        .stroke(
                            phase == .locked ? GroveTheme.accent : .white.opacity(phase == .sighted ? 0.9 : 0.6),
                            style: StrokeStyle(lineWidth: phase == .locked ? 2 : 1.5, lineCap: .round)
                        )
                        .frame(width: arm, height: arm)
                        .rotationEffect(.degrees(Double(corner) * 90))
                        .position(
                            x: corner == 0 || corner == 3 ? inset + arm / 2 : proxy.size.width - inset - arm / 2,
                            y: corner < 2 ? inset + arm / 2 : proxy.size.height - inset - arm / 2
                        )
                }
            }
            // The miniature tab glyph becomes this instrument: it begins as a
            // cluster near the button's former bottom-centre position, then the
            // four corners open into the camera frame. Scaling the geometry—not
            // fading between two symbols—is what makes the handoff continuous.
            .scaleEffect(scale * entryScale, anchor: .center)
            .offset(y: entryOffset(in: proxy.size.height))
            .opacity(entryOpacity)
            .animation(GroveMotion.snap, value: phase)
            .animation(GroveMotion.settle, value: lockedScale)
        }
        .task {
            guard performsEntryAnimation, !reduceMotion else {
                hasEntered = true
                return
            }
            // Give the cover one render pass to establish the collapsed source
            // before animating it. Without the yield SwiftUI can coalesce both
            // values and the reticle simply appears at full size.
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(GroveMotion.reveal) { hasEntered = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var entryProgress: CGFloat {
        guard performsEntryAnimation, !reduceMotion else { return 1 }
        return hasEntered ? 1 : 0
    }

    private var entryScale: CGFloat { 0.085 + 0.915 * entryProgress }

    private var entryOpacity: Double { 0.28 + 0.72 * entryProgress }

    private func entryOffset(in height: CGFloat) -> CGFloat {
        height * 0.46 * (1 - entryProgress)
    }

    private var scale: CGFloat {
        switch phase {
        case .locked: lockedScale
        case .sighted: 0.99
        case .searching: 1
        }
    }
}

/// Top-left corner arm shared by the tab glyph and live camera reticle; callers
/// rotate it into the other three positions. Its bend is proportional at icon
/// size and capped at the camera reticle's original 10 pt radius.
struct GroveScanReticleCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(10, min(rect.width, rect.height) * 0.3)
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

// MARK: - Status card

/// One contextual instruction beneath the viewfinder. Quality readings stay
/// in the analyzer; only an actionable hint or capture readiness is surfaced.
struct LiveScanStatusCard: View {
    let model: LiveScanModel
    /// What to say before anything has been sighted — the mode's own line.
    let idleInstruction: String
    let idleSymbol: String

    private var statusLine: String {
        switch model.phase {
        case .searching:
            return idleInstruction
        case .sighted:
            if let hint = model.hint { return hint.line }
            return "Hold it there…"
        case .locked:
            if let label = model.friendlyLabel {
                return "Looks like \(label). Take the photo"
            }
            return "Plant in frame. Take the photo"
        }
    }

    private var statusSymbol: String {
        switch model.phase {
        case .searching: idleSymbol
        case .sighted: model.hint?.symbol ?? "viewfinder"
        case .locked: "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if model.phase != .searching {
                Image(systemName: statusSymbol)
                    .foregroundStyle(model.isLocked ? GroveTheme.accent : .white)
                    .accessibilityHidden(true)
            }
            Text(statusLine)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusLine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
