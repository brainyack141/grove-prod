import SwiftUI

// MARK: - Ray burst

/// A burst of light behind a celebrated object.
///
/// Badges no longer wear it: a badge is drawn flat, and the Journey's
/// celebrations take their only light from `JourneyTakeover`. It stays for the
/// streak milestone (`StreakCelebration.swift`), which draws it in gold behind
/// the flame.
///
/// Two passes make the bloom: a wide, heavily blurred field that reads as light
/// in the air, and a tighter pass that keeps the individual blades legible.
/// Alternating blade lengths stop the ring reading as a gear.
struct BadgeRayBurst: View {
    var tint: Color
    /// The full width of the burst. Blur radii are derived from it so the
    /// softness holds at any size.
    var diameter: CGFloat
    var rayCount: Int = 28
    /// 0 → blades collapsed at the centre, 1 → full reach.
    var progress: Double = 1
    /// Lighter surfaces need less of it, or the burst eats the copy under it.
    var onDark: Bool = false

    var body: some View {
        ZStack {
            blades
                .blur(radius: diameter * 0.055)
                .opacity(0.6)
            blades
                .blur(radius: diameter * 0.016)
                .opacity(0.85)
        }
        .frame(width: diameter, height: diameter)
        .opacity(onDark ? 0.95 : 0.5)
        .blendMode(onDark ? .plusLighter : .normal)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var blades: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let extent = min(size.width, size.height) / 2
            // Blades start clear of the medallion so the artwork keeps a dark
            // edge to read against.
            let inner = extent * 0.29
            let reach = extent * 0.98

            for index in 0..<rayCount {
                let isLong = index.isMultiple(of: 2)
                let outer = inner + (reach - inner) * (isLong ? 1 : 0.62) * progress
                let heading = (Double(index) / Double(rayCount)) * 2 * .pi
                // Angular half-width, so a blade's base scales with the ring it
                // springs from rather than being a fixed number of points.
                let spread = (isLong ? 0.030 : 0.020) * Double.pi

                var blade = Path()
                blade.move(to: point(from: centre, radius: inner, angle: heading - spread))
                blade.addLine(to: point(from: centre, radius: outer, angle: heading))
                blade.addLine(to: point(from: centre, radius: inner, angle: heading + spread))
                blade.closeSubpath()

                context.fill(blade, with: .color(tint.opacity(isLong ? 0.95 : 0.6)))
            }
        }
    }

    private func point(from centre: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
    }
}

// MARK: - The coin

/// A badge with a struck reverse, rotated about its vertical axis.
///
/// `Animatable` is the whole trick. `rotation3DEffect` alone interpolates
/// inside the render tree without re-running `body`, so a face swap keyed off
/// `angle` would jump straight to the final side and the badge would spin as a
/// mirrored front the entire way. Conforming the view itself means SwiftUI
/// hands us the in-between angle every frame, and the reverse can be shown for
/// the half turn it is genuinely facing us.
private struct JourneyBadgeCoin: View, Animatable {
    let badge: Badge
    let size: CGFloat
    var angle: Double

    // `nonisolated`, because conforming to `View` infers main-actor isolation
    // for the whole type and SwiftUI drives `animatableData` from outside it.
    // The property is a `Double` on a value type, so there is nothing here for
    // the isolation to protect.
    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    private var facingAway: Bool {
        let wrapped = angle.truncatingRemainder(dividingBy: 360)
        let normalised = wrapped < 0 ? wrapped + 360 : wrapped
        return normalised > 90 && normalised < 270
    }

    var body: some View {
        Group {
            if facingAway {
                // Counter-rotated, so the reverse is struck the right way round
                // rather than showing as its own mirror image.
                reverse.rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            } else {
                JourneyBadgeMedallion(badge: badge, state: .earned, size: size)
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.7)
    }

    /// The back of the medal: full-strength palette where the face carries the
    /// artwork, the badge's symbol pressed into it, and a raised rim.
    private var reverse: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: badge.palette.colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .stroke(.white.opacity(0.34), lineWidth: max(1, size * 0.018))
                .padding(size * 0.1)

            Image(systemName: badge.symbol)
                .font(.system(size: size * 0.3, weight: .black))
                .foregroundStyle(.white.opacity(0.78))

            Circle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.26), .clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                )
        }
        .frame(width: size, height: size)
        .overlay {
            Circle().stroke(.white.opacity(0.5), lineWidth: 1.5)
        }
    }
}

// MARK: - The reveal

/// An earned badge, held in the hand.
///
/// Drawn flat: the medallion and nothing behind it, no light of its own and no
/// glow in the badge's colours, so a badge looks the same in a sheet as it does
/// in the celebration that handed it over.
///
/// With `celebrates` on it spins into place: two turns about its vertical axis,
/// braking hard at the end. A badge being looked at again lands flat, because
/// the celebration already happened. Either way, tapping it turns it over,
/// because the first thing anyone does with a medal is turn it over.
struct JourneyBadgeReveal: View {
    let badge: Badge
    var size: CGFloat = 132
    /// Full rotations before it lands flat.
    var turns: Double = 2
    /// Kept so existing call sites compile. The medallion is flat on any
    /// ground now, so there is nothing left to adjust for a dark one.
    var onDark: Bool = false
    /// Off for a badge being re-examined, where the celebration already
    /// happened and a spin on every open would be a lie about the moment.
    var celebrates: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var angle: Double = 0
    /// A celebrating badge rises from small; this flips when it starts to.
    @State private var hasLanded = false
    @State private var squash: CGFloat = 1

    private var scale: CGFloat {
        celebrates && !hasLanded && !reduceMotion ? 0.18 : squash
    }

    /// The square the ray burst used to fill. Held so callers that pull the
    /// surplus back out with negative padding keep their layout.
    private var frameSide: CGFloat { size * 1.94 }

    /// Near-linear through the turns, then a hard brake. An ease-out spends its
    /// speed immediately and reads as a badge that was dropped rather than one
    /// that was spun. `Haptics.medallionLanding` and `medallionSpin` are timed
    /// to this curve's edge-on crossings, so the two move together.
    private var spinCurve: Animation {
        .timingCurve(0.22, 0.36, 0.14, 1, duration: 0.95)
    }

    var body: some View {
        JourneyBadgeCoin(badge: badge, size: size, angle: angle)
            .scaleEffect(scale)
            .frame(width: frameSide, height: frameSide)
            .contentShape(Circle())
            .onTapGesture { turnOver() }
            .onAppear { land() }
            .accessibilityHidden(true)
    }

    // MARK: - Motion

    private func land() {
        guard celebrates else { return }
        guard !reduceMotion else {
            Haptics.celebrate()
            return
        }

        Haptics.medallionLanding()
        withAnimation(spinCurve) { angle += 360 * turns }
        withAnimation(GroveMotion.celebrate) { hasLanded = true }
    }

    private func turnOver() {
        guard !reduceMotion else { return }
        Haptics.medallionSpin()
        withAnimation(spinCurve) { angle += 360 * turns }
        // A short squash under the spin, so the tap has weight of its own.
        withAnimation(GroveMotion.snap) { squash = 0.92 }
        withAnimation(GroveMotion.settle.delay(0.12)) { squash = 1 }
    }
}

#Preview("Badge reveal") {
    JourneyBadgeReveal(
        badge: JourneyLibrary.badge(id: "the-save") ?? JourneyLibrary.badges[0]
    )
}
