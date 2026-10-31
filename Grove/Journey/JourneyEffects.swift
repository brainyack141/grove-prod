import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Grove's haptic vocabulary used to live here, sized for the Journey's
// celebrations alone. It now lives in `GroveHaptics.swift` and speaks for the
// whole app.

// MARK: - Mascot

/// Sprout, the Grove buddy. Its authored reactions preserve character identity
/// across the Journey while the view supplies the gentle live motion.
struct SproutMascot: View {
    enum Expression: Hashable {
        case idle, happy, cheer
        case curious, watering, sleepy, surprised

        /// The authored artwork for each reaction.
        var artworkName: String {
            switch self {
            case .idle: "JourneySproutIdle"
            case .happy: "JourneySproutHappy"
            case .cheer: "JourneySproutCheer"
            case .curious: "JourneySproutCurious"
            case .watering: "JourneySproutWatering"
            case .sleepy: "JourneySproutSleepy"
            case .surprised: "JourneySproutSurprised"
            }
        }
    }

    var expression: Expression = .idle
    var size: CGFloat = 72

    @State private var bob = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var artworkName: String { expression.artworkName }

    var body: some View {
        Image(artworkName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .offset(y: bob ? -2 : 2)
            .rotationEffect(.degrees(bob ? 1.5 : -1.5), anchor: .bottom)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { bob = true }
            }
    }
}

// MARK: - Celebration atmosphere

/// A quiet, deterministic celebration field shared by the Journey's full-screen
/// rewards. The previous rotating ray wheels and continuous particle systems
/// could dominate the content (and captured as overlapping ghost frames during
/// animation). This keeps the warm glow and sparkle without obscuring the
/// mascot, reward, copy, or action.
struct JourneyCelebrationGlow: View {
    var tint: Color = GroveTheme.gold
    var focalY: CGFloat = 0.38
    var sparkleCount = 24

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RadialGradient(
                    colors: [tint.opacity(0.26), tint.opacity(0.08), .clear],
                    center: UnitPoint(x: 0.5, y: focalY),
                    startRadius: 8,
                    endRadius: min(proxy.size.width, proxy.size.height) * 0.54
                )

                ForEach(0..<sparkleCount, id: \.self) { index in
                    let x = CGFloat((index * 37 + 11) % 101) / 100
                    let y = CGFloat((index * 53 + 17) % 97) / 100
                    let diameter = CGFloat(2 + (index % 3) * 2)

                    Circle()
                        .fill(tint.opacity(index.isMultiple(of: 4) ? 0.9 : 0.56))
                        .frame(width: diameter, height: diameter)
                        .shadow(color: tint.opacity(0.65), radius: diameter * 1.8)
                        .position(x: proxy.size.width * x, y: proxy.size.height * y)
                }
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - The celebration frame

/// The one room every Journey celebration happens in: night green, gold as the
/// only light, the reward in the middle, its facts as small caps over values,
/// and one light pill docked at the bottom.
///
/// A finished step, a badge, a chest and a new level are four kinds of the same
/// moment, so they share the frame and differ only in the object on the table.
/// It is the Journey hero's own ground, so stepping from the rings into a
/// celebration and back never changes the lighting.
struct JourneyTakeover<Art: View, Details: View>: View {
    let eyebrow: String
    let title: String
    var message: String?
    let primaryTitle: String
    let onPrimary: () -> Void
    var secondaryTitle: String?
    var onSecondary: (() -> Void)?
    /// Off when the caller times its own haptic, such as a chest that answers
    /// the tap that opens it.
    var playsSuccessHaptic = true
    @ViewBuilder var art: Art
    @ViewBuilder var details: Details

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appear = false

    var body: some View {
        ZStack {
            GroveTheme.mapGround.ignoresSafeArea()

            // The only light in the room, and it is gold: a reward is the one
            // thing gold means anywhere in Grove.
            RadialGradient(
                colors: [GroveTheme.gold.opacity(0.20), GroveTheme.gold.opacity(0.05), .clear],
                center: UnitPoint(x: 0.5, y: 0.3),
                startRadius: 10,
                endRadius: 300
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            ScrollView {
                VStack(spacing: 24) {
                    art
                        .frame(maxWidth: .infinity)
                        .frame(height: 188)
                        .scaleEffect(appear || reduceMotion ? 1 : 0.88)
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        GroveEyebrow(text: eyebrow, color: GroveTheme.gold)
                        Text(title)
                            .font(GroveTheme.display(GroveDisplayStyle.title.points))
                            .tracking(-0.4)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        if let message {
                            Text(message)
                                .font(.body)
                                .foregroundStyle(GroveTheme.mapCaption)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    details
                }
                .padding(.horizontal, 28)
                .padding(.top, 64)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
                .opacity(appear ? 1 : 0)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 4) {
                    GroveCTAButton(title: primaryTitle, action: onPrimary)
                    if let secondaryTitle, let onSecondary {
                        Button(secondaryTitle, action: onSecondary)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GroveTheme.mapCaption)
                            .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(GroveTheme.mapGround.opacity(0.94).ignoresSafeArea())
            }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            if playsSuccessHaptic { Haptics.success() }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : GroveMotion.celebrate) {
                appear = true
            }
        }
    }
}

extension JourneyTakeover where Details == EmptyView {
    init(
        eyebrow: String,
        title: String,
        message: String? = nil,
        primaryTitle: String,
        onPrimary: @escaping () -> Void,
        secondaryTitle: String? = nil,
        onSecondary: (() -> Void)? = nil,
        playsSuccessHaptic: Bool = true,
        @ViewBuilder art: () -> Art
    ) {
        self.init(
            eyebrow: eyebrow,
            title: title,
            message: message,
            primaryTitle: primaryTitle,
            onPrimary: onPrimary,
            secondaryTitle: secondaryTitle,
            onSecondary: onSecondary,
            playsSuccessHaptic: playsSuccessHaptic,
            art: art,
            details: { EmptyView() }
        )
    }
}

/// The facts under a celebration: small caps over values, centred, split by
/// the map's hairline. Resolves in whatever appearance it is placed in, so it
/// reads on the night-green takeover and on a white sheet alike.
struct JourneyFactRow: View {
    struct Fact: Identifiable {
        let label: String
        let value: String
        var tint: Color?
        var id: String { label }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let facts: [Fact]

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) { cells(facts) }
            } else if dynamicTypeSize >= .xLarge, facts.count > 2 {
                // Three or four across stop fitting a level name like "Grove
                // Keeper" before the text is large enough to stack.
                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 14) {
                    ForEach(Array(stride(from: 0, to: facts.count, by: 2)), id: \.self) { start in
                        GridRow { cells(Array(facts[start..<min(start + 2, facts.count)])) }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 10) { cells(facts) }
            }
        }
        .padding(.top, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(GroveTheme.separator).frame(height: 1)
        }
    }

    private func cells(_ facts: [Fact]) -> some View {
        ForEach(facts) { fact in
            GroveStatCell(label: fact.label, value: fact.value, tint: fact.tint ?? GroveTheme.ink)
        }
    }
}

/// A small growth ring, fully travelled, for celebrating a finished step: the
/// Journey hero's own drawing, at the size of the object on the table.
struct JourneyRingMark: View {
    var size: CGFloat = 168

    var body: some View {
        Canvas { context, canvasSize in
            let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let outer = min(canvasSize.width, canvasSize.height) / 2 - 2
            for (index, fraction) in [1.0, 0.86, 0.73, 0.61].enumerated() {
                let r = outer * fraction
                context.stroke(
                    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                    with: .color(index == 0 ? JourneyWorld.ringLine : JourneyWorld.ringGrain),
                    lineWidth: 1
                )
            }
            let active = outer * 0.46
            context.stroke(
                Path(ellipseIn: CGRect(x: c.x - active, y: c.y - active, width: active * 2, height: active * 2)),
                with: .color(GroveTheme.mapThriving),
                lineWidth: 3
            )
            let pith = outer * 0.28
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - pith, y: c.y - pith, width: pith * 2, height: pith * 2)),
                with: .color(JourneyWorld.ringPith)
            )
        }
        .frame(width: size, height: size)
        .overlay {
            Image(systemName: "checkmark")
                .font(.title.weight(.bold))
                .foregroundStyle(GroveTheme.gold)
        }
        .accessibilityHidden(true)
    }
}

/// The square that stands for a step wherever a list names one: its short
/// verb in the board's code style, gold for a chest.
struct JourneyMilestoneTile: View {
    let milestone: JourneyMilestone
    var size: CGFloat = 48

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
        Group {
            if milestone.isChest {
                Image(systemName: "shippingbox.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(GroveTheme.goldDeep)
                    .frame(width: size, height: size)
                    .background(GroveTheme.gold.opacity(0.22), in: shape)
            } else {
                Text(JourneyNextSteps.tileCode(for: milestone))
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(GroveTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: size, height: size)
                    .background(GroveTheme.secondarySurface, in: shape)
            }
        }
        .accessibilityHidden(true)
    }
}
