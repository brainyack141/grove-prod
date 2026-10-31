import ImageIO
import SwiftUI
import UIKit

/// One frame of a plant's Living Record: a check-in photo plus the health
/// context that was captured with it.
struct LivingRecordFrame: Identifiable, Hashable {
    let id: UUID
    let date: Date
    let score: Int
    let previousScore: Int
    let band: HealthBand
    let hasNewGrowth: Bool
    let actorName: String
    let photoURL: URL

    init?(observation: PlantObservation) {
        guard let url = observation.photoURL else { return nil }
        id = observation.id
        date = observation.createdAt
        score = observation.score
        previousScore = observation.previousScore
        band = observation.band
        hasNewGrowth = observation.hasNewGrowth
        actorName = observation.actorName
        photoURL = url
    }

    /// Builds the record oldest → newest from a plant's observations,
    /// keeping only the ones that carry a photo.
    static func frames(from observations: [PlantObservation]) -> [LivingRecordFrame] {
        observations
            .compactMap(LivingRecordFrame.init(observation:))
            .sorted { $0.date < $1.date }
    }
}

/// The Living Record hero: the plant's newest check-in photo, scrubbable
/// through its entire photo history. Press and hold, then drag left to travel
/// back in time — the health arc draws itself under your thumb with a haptic
/// detent per check-in. Release, and the record replays forward to today as a
/// fast time-lapse.
struct LivingRecordHero: View {
    let plant: Plant
    let frames: [LivingRecordFrame]
    /// True while the user is time-travelling (or the release replay is
    /// running). The parent uses this to fade its own chrome out of the way.
    @Binding var isScrubbing: Bool

    @State private var images: [UUID: UIImage] = [:]
    /// 0 = oldest frame, 1 = newest ("now").
    @State private var progress: Double = 1
    @State private var dragAnchor: (x: CGFloat, progress: Double)?
    @State private var lastDetentIndex = -1
    @State private var replayTask: Task<Void, Never>?

    private var canScrub: Bool { frames.count >= 2 }

    private var currentIndex: Int {
        guard frames.count > 1 else { return 0 }
        let position = progress * Double(frames.count - 1)
        return min(frames.count - 1, max(0, Int(position.rounded())))
    }

    private var currentFrame: LivingRecordFrame { frames[currentIndex] }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                photo(size: proxy.size)

                scrubScrim

                if isScrubbing {
                    recordChip
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(16)
                        .transition(.opacity)

                    healthArc
                        .frame(height: 62)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 18)
                        .transition(.opacity)
                } else if canScrub {
                    replayHint
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(14)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: proxy.size.width), including: canScrub ? .all : .subviews)
        }
        .task(id: frames.map(\.id)) { await loadImages() }
        .onDisappear { replayTask?.cancel() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue("\(currentFrame.date.formatted(date: .abbreviated, time: .omitted)), health \(currentFrame.score)")
        .accessibilityAdjustableAction { direction in
            guard frames.count > 1 else { return }
            let step = 1.0 / Double(frames.count - 1)
            switch direction {
            case .increment: progress = min(1, progress + step)
            case .decrement: progress = max(0, progress - step)
            @unknown default: break
            }
        }
    }

    // MARK: - Layers

    private func photo(size: CGSize) -> some View {
        Group {
            if let image = images[currentFrame.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // The drawn portrait, deliberately, rather than the plant's
                // newest photo: while a scrubbed frame decodes, showing a
                // different day's picture in its place would misread as that
                // frame. The portrait is unmistakably not a photograph.
                PlantPortrait(plant: plant, height: size.height, breathes: true)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    /// Extra top-and-bottom darkening so the record chip and health arc stay
    /// readable over any photo while time-travelling.
    private var scrubScrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.5), location: 0),
                .init(color: .clear, location: 0.35),
                .init(color: .clear, location: 0.55),
                .init(color: .black.opacity(0.6), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .opacity(isScrubbing ? 1 : 0)
        .allowsHitTesting(false)
    }

    /// The date / score readout that follows the scrubbed frame.
    private var recordChip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(currentFrame.date.formatted(date: .abbreviated, time: .omitted).uppercased())
                .font(.caption.weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.85))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(currentFrame.score)")
                    .font(GroveTheme.display(46))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(currentFrame.score)))

                let delta = currentFrame.score - currentFrame.previousScore
                if delta != 0 {
                    Label("\(abs(delta))", systemImage: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(delta > 0 ? GroveTheme.onPhotoImproving : GroveTheme.onPhotoDeclining)
                }
            }

            HStack(spacing: 6) {
                if currentFrame.hasNewGrowth {
                    recordTag("New growth", systemImage: "sparkles")
                }
                if currentFrame.actorName != "You", !currentFrame.actorName.isEmpty {
                    recordTag(currentFrame.actorName, systemImage: "person.fill")
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: currentIndex)
    }

    private func recordTag(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.white.opacity(0.18), in: Capsule())
    }

    /// The health line drawing itself under the thumb: a smooth curve through
    /// every check-in score, tinted by each frame's health band, with a mark
    /// per check-in and an accent ring where new growth appeared.
    private var healthArc: some View {
        Canvas { context, size in
            guard frames.count > 1 else { return }
            let scores = frames.map { Double($0.score) }
            let low = (scores.min() ?? 0) - 6
            let high = (scores.max() ?? 100) + 6
            let span = max(1, high - low)
            let points: [CGPoint] = scores.enumerated().map { index, score in
                CGPoint(
                    x: size.width * CGFloat(Double(index) / Double(frames.count - 1)),
                    y: size.height - CGFloat((score - low) / span) * size.height
                )
            }

            var path = Path()
            path.move(to: points[0])
            if points.count == 2 {
                path.addLine(to: points[1])
            } else {
                for index in 1..<(points.count - 1) {
                    let mid = CGPoint(
                        x: (points[index].x + points[index + 1].x) / 2,
                        y: (points[index].y + points[index + 1].y) / 2
                    )
                    path.addQuadCurve(to: mid, control: points[index])
                }
                path.addLine(to: points[points.count - 1])
            }

            // The full route, faint, so the traveller can see where "now" is.
            context.stroke(path, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            let bandStops = frames.enumerated().map { index, frame in
                Gradient.Stop(color: frame.band.color, location: frames.count > 1 ? Double(index) / Double(frames.count - 1) : 0)
            }
            let travelled = path.trimmedPath(from: 0, to: max(0.001, progress))
            context.stroke(
                travelled,
                with: .linearGradient(
                    Gradient(stops: bandStops),
                    startPoint: CGPoint(x: 0, y: size.height / 2),
                    endPoint: CGPoint(x: size.width, y: size.height / 2)
                ),
                style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
            )

            for (index, point) in points.enumerated() {
                let reached = Double(index) / Double(frames.count - 1) <= progress + 0.0001
                let radius: CGFloat = index == currentIndex ? 6 : 3.5
                let dot = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                context.fill(dot, with: .color(.white.opacity(reached ? 1 : 0.4)))
                if reached, frames[index].hasNewGrowth {
                    let ring = Path(ellipseIn: CGRect(x: point.x - radius - 3, y: point.y - radius - 3, width: (radius + 3) * 2, height: (radius + 3) * 2))
                    context.stroke(ring, with: .color(GroveTheme.accent), lineWidth: 1.5)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var replayHint: some View {
        Label("\(frames.count) check-ins · hold to replay", systemImage: "clock.arrow.circlepath")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.black.opacity(0.38), in: Capsule())
            .allowsHitTesting(false)
    }

    private var accessibilitySummary: String {
        guard let first = frames.first, let last = frames.last else {
            return "\(plant.nickname)'s living record"
        }
        return "\(plant.nickname)'s living record. \(frames.count) check-ins from \(first.date.formatted(date: .abbreviated, time: .omitted)) to \(last.date.formatted(date: .abbreviated, time: .omitted)). Health went from \(first.score) to \(last.score). Swipe up or down to move through check-ins."
    }

    // MARK: - Scrubbing

    private func scrubGesture(width: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginScrub()
                case .second(true, let drag):
                    guard let drag else { return }
                    if dragAnchor == nil {
                        dragAnchor = (drag.location.x, progress)
                    }
                    guard let anchor = dragAnchor else { return }
                    let travelled = Double((drag.location.x - anchor.x) / max(1, width))
                    setProgress(anchor.progress + travelled * 1.15)
                default:
                    break
                }
            }
            .onEnded { _ in
                guard isScrubbing else { return }
                releaseScrub()
            }
    }

    private func beginScrub() {
        replayTask?.cancel()
        dragAnchor = nil
        progress = 1
        lastDetentIndex = currentIndex
        Haptics.impact(.rigid, intensity: 0.8)
        withAnimation(.easeOut(duration: 0.25)) { isScrubbing = true }
    }

    private func setProgress(_ newValue: Double) {
        progress = min(1, max(0, newValue))
        if currentIndex != lastDetentIndex {
            lastDetentIndex = currentIndex
            Haptics.selection()
        }
    }

    /// Let go anywhere in the past and the record plays itself forward to
    /// today — the plant's life as a one-second film.
    private func releaseScrub() {
        dragAnchor = nil
        let lastIndex = frames.count - 1
        let startIndex = currentIndex
        guard startIndex < lastIndex else {
            endScrub()
            return
        }
        replayTask = Task {
            let remaining = lastIndex - startIndex
            let stepDuration = min(0.085, max(0.04, 0.9 / Double(remaining)))
            for index in (startIndex + 1)...lastIndex {
                try? await Task.sleep(for: .seconds(stepDuration))
                if Task.isCancelled { return }
                progress = Double(index) / Double(lastIndex)
                lastDetentIndex = index
                Haptics.selection()
            }
            try? await Task.sleep(for: .seconds(0.3))
            if Task.isCancelled { return }
            Haptics.impact(.soft)
            endScrub()
        }
    }

    private func endScrub() {
        progress = 1
        withAnimation(.easeOut(duration: 0.3)) { isScrubbing = false }
    }

    // MARK: - Image loading

    /// Newest first, then outward.
    ///
    /// `frames` is oldest → newest and the hero opens on the *last* one, but
    /// this loop used to walk the array in order — so on a plant with two years
    /// of check-ins the photograph actually on screen was the last thing
    /// fetched, behind two dozen images nobody was looking at. The wait scaled
    /// with how much history a plant had, which made it worst on exactly the
    /// plants people care most about.
    private func loadImages() async {
        let ordered = frames.enumerated()
            .sorted { lhs, rhs in
                abs(lhs.offset - currentIndex) < abs(rhs.offset - currentIndex)
            }
            .map(\.element)
        for frame in ordered where images[frame.id] == nil {
            if let image = await GroveImageLoader.downsampledImage(at: frame.photoURL) {
                images[frame.id] = image
            }
        }
    }
}
