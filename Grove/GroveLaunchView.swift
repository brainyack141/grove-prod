import SwiftUI

/// The branded launch state, shown while Grove's account, store and sync
/// services come up.
///
/// The storyboard still owns the first frame: it shows the same mark at the
/// same size on the same ground. Once SwiftUI takes over, the mark makes one
/// quiet dimensional turn before the app cross-fades in.
struct GroveLaunchView: View {
    private static let captionDelay: Duration = .milliseconds(1_500)
    private static let handoffHold: Duration = .milliseconds(120)
    private static let turnDuration = 0.82
    private static let turnLiftDuration = 0.30
    private static let turnSettleDuration = 0.52
    private static let settleDelay: Duration = .milliseconds(120)

    /// These dimensions are shared with LaunchScreen.storyboard. The static
    /// image is pinned to the mathematical centre, with this optical lift.
    private static let markWidth: CGFloat = 91
    private static let markHeight: CGFloat = 132
    private static let markLift: CGFloat = -24

    /// The launch ground is fixed because the storyboard cannot animate or
    /// adapt.
    private static let ground = Color(red: 0xF4 / 255, green: 0xED / 255, blue: 0xDF / 255)
    private static let captionInk = Color(red: 0x5F / 255, green: 0x68 / 255, blue: 0x5D / 255)

    private let playsReveal: Bool
    private let onRevealCompleted: () -> Void

    @State private var showsCaption = false
    @State private var turnDegrees = 0.0
    @State private var markScale: CGFloat = 1
    @State private var markFloat: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        playsReveal: Bool = true,
        onRevealCompleted: @escaping () -> Void = {}
    ) {
        self.playsReveal = playsReveal
        self.onRevealCompleted = onRevealCompleted
    }

    var body: some View {
        ZStack {
            Self.ground.ignoresSafeArea()

            launchMark
                .offset(y: Self.markLift)

            // Explanatory copy only appears when bootstrap outlasts the
            // branded moment. It stays separate from the mark so it cannot
            // shift the storyboard-to-SwiftUI handoff.
            Text("Checking on your plants…")
                .font(.footnote)
                .foregroundStyle(Self.captionInk)
                .offset(y: Self.markLift + Self.markHeight / 2 + 72)
                .opacity(showsCaption ? 1 : 0)
                .animation(.easeOut(duration: 0.35), value: showsCaption)
        }
        // Match the storyboard's view-centred layout instead of the safe-area
        // centre, which would make the handoff visibly jump on tall phones.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel("Grove is opening")
        .task {
            await playOpening()
        }
    }

    private var launchMark: some View {
        Image("LaunchMark")
            .resizable()
            .scaledToFit()
            .frame(width: Self.markWidth, height: Self.markHeight)
            .frame(width: 220, height: 220)
            .rotation3DEffect(
                .degrees(turnDegrees),
                axis: (x: 0.035, y: 1, z: 0),
                perspective: 0.58
            )
            .scaleEffect(markScale)
            .offset(y: markFloat)
    }

    @MainActor
    private func playOpening() async {
        guard playsReveal else {
            await revealCaptionAfterDelay()
            return
        }

        do {
            // Hold the first live frame long enough for the system launch
            // storyboard to hand off without a visible jump.
            try await Task.sleep(for: Self.handoffHold)

            guard !reduceMotion else {
                try await Task.sleep(for: Self.settleDelay)
                onRevealCompleted()
                return
            }

            // A single full turn keeps the artwork itself intact: SwiftUI
            // supplies the perspective, so no generated in-between frames are
            // needed. The tiny lift stops the motion reading like a flat card.
            withAnimation(
                .timingCurve(
                    0.22,
                    0.72,
                    0.18,
                    1,
                    duration: Self.turnDuration
                )
            ) {
                turnDegrees = 360
            }
            withAnimation(.easeOut(duration: Self.turnLiftDuration)) {
                markScale = 1.022
                markFloat = -3
            }

            try await Task.sleep(for: .milliseconds(300))

            withAnimation(.easeInOut(duration: Self.turnSettleDuration)) {
                markScale = 1
                markFloat = 0
            }

            try await Task.sleep(for: .milliseconds(520) + Self.settleDelay)
            onRevealCompleted()
        } catch {
            // Cancellation means the launch view left the hierarchy; there is
            // no completion to deliver to an owner that is no longer visible.
        }
    }

    @MainActor
    private func revealCaptionAfterDelay() async {
        do {
            try await Task.sleep(for: Self.captionDelay)
            showsCaption = true
        } catch {
            // The app became ready before explanatory loading copy was needed.
        }
    }
}

#Preview {
    GroveLaunchView()
}
