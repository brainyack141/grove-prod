import CoreMotion
import SwiftUI
import UIKit

/// The time of day, as Grove renders it.
///
/// The Today hero already knew this trick — it tinted the user's photograph
/// warm at dawn and deep blue at night, which is most of why it read as a
/// window rather than a stored image. But it knew it privately, inside one
/// 260 pt card, so the rest of the app sat on a cream that was the same colour
/// at 6am and 11pm. The best idea in the product was locked in a drawer.
///
/// Atmosphere is a property of the whole canvas now. The nine beats are
/// deliberately small steps rather than one abrupt day/night flip, so a
/// person can open Grove at 5am, 8am, 3pm, or 7pm and still feel the scene
/// moving with the real day.
///
/// The strengths are
/// deliberately asymmetric: a photograph can take a real wash of colour, while
/// the cream ground can take almost none before it stops being *the* cream and
/// starts being a different background per hour — which is exactly the drift
/// the design system exists to prevent. What is left is small enough that you
/// would struggle to name it in a screenshot, and unmistakable when you open
/// the app twice in one day.
enum GroveAtmosphere: CaseIterable {
    case midnight
    case preDawn
    case dawn
    case morning
    case day
    case afternoon
    case goldenHour
    case dusk
    case night

    static var current: GroveAtmosphere { at(.now) }

    /// Resolves the hour in the Grove's local timezone, not necessarily the
    /// phone's timezone. This keeps the hero, its date line, and the weather
    /// strip telling the same story when someone is travelling.
    static func at(_ date: Date, timeZone: TimeZone = .current) -> GroveAtmosphere {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        switch calendar.component(.hour, from: date) {
        case 0..<4: return .midnight
        case 4..<6: return .preDawn
        case 6..<8: return .dawn
        case 8..<11: return .morning
        case 11..<15: return .day
        case 15..<17: return .afternoon
        case 17: return .goldenHour
        case 18..<20: return .dusk
        case 20..<24: return .night
        default: return .night
        }
    }

    /// Over a photograph, where the image supplies its own darks.
    var tint: Color {
        switch self {
        case .midnight: GroveTheme.midnightTint
        case .preDawn: GroveTheme.preDawnTint
        case .dawn: GroveTheme.dawnTint
        case .morning: GroveTheme.morningTint
        case .day: .clear
        case .afternoon: GroveTheme.afternoonTint
        case .goldenHour: GroveTheme.goldenHourTint
        case .dusk: GroveTheme.duskTint
        case .night: GroveTheme.nightTint
        }
    }

    /// Over the cream, which supplies none. The darker blue phases use their
    /// light-held canvas counterparts so the page does not turn grey under an
    /// overlay blend.
    var canvasTint: Color {
        switch self {
        case .midnight, .night: GroveTheme.nightCanvasTint
        case .preDawn: GroveTheme.preDawnCanvasTint
        default: tint
        }
    }

    /// Over a photograph, where colour has somewhere to sit.
    var photoStrength: Double {
        switch self {
        case .midnight: 0.20
        case .preDawn: 0.18
        case .dawn: 0.12
        case .morning: 0.08
        case .day: 0
        case .afternoon: 0.06
        case .goldenHour: 0.12
        case .dusk: 0.14
        case .night: 0.20
        }
    }

    /// Over the cream canvas, and it falls away down the page so the top of a
    /// screen carries the light and the bottom stays the ground everything else
    /// was designed against.
    ///
    /// These read high next to `photoStrength` but land far softer, because
    /// they are spent through an overlay blend that holds the canvas's
    /// luminosity. The original values — 0.030/0.034/0.048 — were calibrated
    /// against a straight alpha mix, where the tint was averaged into the ground
    /// and every point of strength cost lightness. 3.4% of violet was enough to
    /// pull the old #F4EDDF to #F0E9DF at dusk and 4.8% of navy took it to
    /// #EAE4DB at night: not a tint, a grey. The ceiling was low because the
    /// mistake got expensive fast. Blending properly removes the cost, so the
    /// strength can buy what it was always meant to buy — chroma, at constant
    /// lightness.
    ///
    /// They rose again when the ground went from cream to bone. Overlay's reach
    /// scales with how far the base sits from white, and bone is three points
    /// lighter and already neutral, so the same strengths that tinted parchment
    /// left dusk and night landing on the identical colour — the app had two
    /// evenings that looked the same. Roughly double buys back the separation.
    var canvasStrength: Double {
        switch self {
        case .midnight: 0.50
        case .preDawn: 0.46
        case .dawn: 0.42
        case .morning: 0.20
        case .day: 0
        case .afternoon: 0.16
        case .goldenHour: 0.34
        case .dusk: 0.50
        case .night: 0.50
        }
    }

    /// The colour of the canvas's own light.
    ///
    /// The wash above is *chroma by hour*, and it is `.clear` at midday — which
    /// is correct over a photograph and useless over a page. The light is the
    /// other half: it is never clear, because a page has a direction whether or
    /// not the hour has a colour. `.day` gets the warm cream because that is the
    /// hour the ground was barest and `overlay` cannot lift a near-white ground
    /// with white.
    var canvasLightTint: Color {
        switch self {
        case .day: GroveTheme.canvasLight
        case .midnight, .night: GroveTheme.nightCanvasTint
        case .preDawn: GroveTheme.preDawnCanvasTint
        default: tint
        }
    }

    /// The light's strength over the paper. Deliberately never zero, and held in
    /// the same range as `canvasStrength` because it is spent the same way —
    /// through `overlay`, where a few percent of a light tint is a few percent
    /// of nothing.
    var canvasLightStrength: Double {
        switch self {
        case .day: 0.34
        case .morning, .afternoon: 0.28
        case .dawn, .goldenHour: 0.34
        case .dusk: 0.40
        case .preDawn: 0.38
        case .midnight, .night: 0.40
        }
    }

    /// The wash to lay over a user's photograph.
    var photoWash: some View {
        tint.opacity(photoStrength)
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }
}

// MARK: - Canvas

/// Grove's page ground: the signature paper, carrying the hour, lit from the
/// corner the rest of the app is lit from, and falling away toward the bottom.
///
/// This used to be a flat fill plus, at some hours, a wash. Two things were
/// wrong with that. The wash is *chroma*, and it is zero at midday, so for four
/// hours of every day the ground had no treatment at all — the plainest
/// screenshot Grove could take was the one taken at noon. And chroma cannot give
/// a page near and far: the ground was the same distance from the reader at the
/// top of the screen as at the bottom, so the only thing separating the two was
/// the content that happened to be there.
///
/// The canvas carries three things now. The hour wash, unchanged, which tints.
/// A light in the upper-right — the corner `GroveLivingScene` and the hero are
/// lit from — which never falls to zero, so the page has a direction at every
/// hour. And a depth ramp to the bottom, hour-independent because a page has a
/// horizon at midnight too. Together they are the difference between a fill and
/// a ground.
struct GroveBackground: ViewModifier {
    /// The paper this page is set on. Bone by default; Today hands in the warmer
    /// editorial paper it was drawn against rather than being re-hued to match
    /// the rest of the app.
    var paper: Color = GroveTheme.background

    /// Held in state rather than read inline so the app can catch up with the
    /// clock when it comes back to the foreground — someone who opens Grove at
    /// dusk, puts the phone down and picks it up at night should not still be
    /// looking at the afternoon.
    @State private var atmosphere = GroveAtmosphere.current

    /// Written out rather than synthesized: `atmosphere` is private, and one
    /// private stored property is enough to suppress the memberwise initializer
    /// entirely — `GroveBackground(paper:)` would not exist.
    init(paper: Color = GroveTheme.background) {
        self.paper = paper
        _atmosphere = State(initialValue: GroveAtmosphere.current)
    }

    func body(content: Content) -> some View {
        content
            .background {
                paper
                    .overlay { hourWash }
                    .overlay { windowLight }
                    .overlay { depth }
                    // Seals the blends to the layers above them. Without the
                    // group a blend mode reaches past the background modifier
                    // and mixes with whatever the window puts behind the view,
                    // which is a different colour per presentation context —
                    // the sheet, the zoom transition and the plain push would
                    // each land on their own paper.
                    .compositingGroup()
                    .ignoresSafeArea()
            }
            .animation(.easeInOut(duration: 1.2), value: atmosphere)
            .onReceive(
                NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            ) { _ in
                atmosphere = GroveAtmosphere.current
            }
    }

    /// The hour, spent as chroma. Unchanged.
    ///
    /// `.overlay` the blend mode, not just the modifier — this gradient laid
    /// itself over the cream as a plain alpha mix for as long as the canvas has
    /// carried the hour, which meant it averaged toward the tint instead of
    /// tinting. Violet and navy are darker than any canvas Grove has had, so the
    /// average was always a step toward grey: the top of every screen went dusty
    /// after 5pm while the bottom, where the gradient had faded out, stayed
    /// cream. It read as a rendering fault rather than as evening.
    private var hourWash: some View {
        LinearGradient(
            colors: [
                atmosphere.canvasTint.opacity(atmosphere.canvasStrength),
                atmosphere.canvasTint.opacity(atmosphere.canvasStrength * 0.15)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .blendMode(.overlay)
    }

    /// The canvas's own light: a bloom in the upper-right, the corner the living
    /// scene and the hero are lit from, so the ground and the picture on it
    /// agree about where the sun is.
    ///
    /// It is what the hour wash could not be. Kept at the same corner as
    /// `GroveLivingAtmosphereLayer` rather than centred, because light that
    /// comes from everywhere is light that comes from nowhere.
    private var windowLight: some View {
        GeometryReader { proxy in
            RadialGradient(
                colors: [
                    atmosphere.canvasLightTint.opacity(atmosphere.canvasLightStrength),
                    atmosphere.canvasLightTint.opacity(0)
                ],
                center: .init(x: 0.84, y: 0.02),
                startRadius: 0,
                endRadius: max(proxy.size.width, proxy.size.height) * 0.78
            )
        }
        .blendMode(.overlay)
    }

    /// The page's horizon. Top-weighted so the light above reads and the ground
    /// below settles, which is the one thing a single flat value can never say.
    ///
    /// Both stops are the same colour at different alphas rather than `.clear`
    /// at the top: SwiftUI interpolates a transparent black, and a gradient that
    /// fades through grey is a gradient that fades through dirty.
    private var depth: some View {
        LinearGradient(
            colors: [
                GroveTheme.canvasDepth.opacity(0),
                GroveTheme.canvasDepth.opacity(0.05)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Parallax

/// One device-tilt source for the whole app.
///
/// The Today hero owned a `CMMotionManager` outright, which was fine while it
/// was the only surface that drifted. Now that a plant's own page and the
/// living record are windows too, a manager each would mean three subscriptions
/// to the same gyroscope. This keeps one, reference-counted, and stops it the
/// moment the last window goes away — parallax should cost nothing on a screen
/// that isn't using it.
@MainActor
@Observable
final class GroveTilt {
    static let shared = GroveTilt()

    var x: CGFloat = 0
    var y: CGFloat = 0

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var subscribers = 0

    /// Neutral pitch for a phone held in-hand (~40°); tilt is measured from here.
    private static let restingPitch = 0.7

    private init() {}

    func subscribe() {
        subscribers += 1
        guard subscribers == 1, manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            MainActor.assumeIsolated {
                let targetX = CGFloat(max(-1, min(1, motion.attitude.roll / 0.9)))
                let targetY = CGFloat(max(-1, min(1, (motion.attitude.pitch - Self.restingPitch) / 0.9)))
                // Low-pass filter keeps the drift dreamy rather than jittery.
                self.x = self.x * 0.88 + targetX * 0.12
                self.y = self.y * 0.88 + targetY * 0.12
            }
        }
    }

    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        manager.stopDeviceMotionUpdates()
        x = 0
        y = 0
    }
}

/// Makes a photographic surface drift with the device, like a scene behind
/// glass. `depth` is how many points it travels at full tilt — heroes take
/// more than inset cards, so the page keeps a sense of near and far.
private struct GroveParallaxModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let depth: CGFloat

    private var tilt: GroveTilt { GroveTilt.shared }

    func body(content: Content) -> some View {
        content
            .offset(
                x: reduceMotion ? 0 : tilt.x * depth,
                y: reduceMotion ? 0 : tilt.y * depth * 0.78
            )
            .onAppear { if !reduceMotion { tilt.subscribe() } }
            .onDisappear { if !reduceMotion { tilt.unsubscribe() } }
    }
}

extension View {
    /// Drifts this view with the device's tilt.
    func groveParallax(depth: CGFloat = 9) -> some View {
        modifier(GroveParallaxModifier(depth: depth))
    }
}

// MARK: - Living grove

/// The visual signature shared by Grove's most emotional surfaces.
///
/// A plant portrait on its own is an illustration. The same portrait lit from
/// Grove's upper-right light source, breathing behind near and far foliage and
/// carrying the hour's colour becomes a place. Today uses it as a window, My
/// Grove uses it as the user's canopy, and Journey plants it beside the road.
enum GroveLivingSceneStyle {
    case hero
    case canopy

    var foregroundOpacity: Double {
        switch self {
        case .hero: 0.34
        case .canopy: 0.46
        }
    }
}

struct GroveLivingScene: View {
    let plants: [Plant]
    var style: GroveLivingSceneStyle = .hero
    var atmosphere: GroveAtmosphere = .current

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifting = false

    private var palette: [Color] {
        plants.first?.palette.colors ?? PlantPalette.fern.colors
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        palette[0],
                        palette[1],
                        palette[0].opacity(0.94)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                GroveLivingAtmosphereLayer(
                    atmosphere: atmosphere,
                    intensity: style == .hero ? 1.0 : 0.82
                )

                farFoliage(in: proxy.size)

                ForEach(Array(plants.prefix(7).enumerated()), id: \.element.id) { index, plant in
                    livingPlant(plant, index: index, count: min(plants.count, 7), in: proxy.size)
                }

                foregroundFoliage(in: proxy.size)

                LinearGradient(
                    colors: [.clear, palette[0].opacity(0.32)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .saturation(1.16)
            .contrast(1.04)
            .clipped()
            .onAppear { drifting = true }
        }
        .accessibilityHidden(true)
    }

    private func livingPlant(
        _ plant: Plant,
        index: Int,
        count: Int,
        in size: CGSize
    ) -> some View {
        let width = plantWidth(count: count, in: size)
        let height = size.height * (style == .hero ? 1.26 : 1.18) * stature(at: index)

        return GroveLivingPlant(plant: plant, breathes: style == .hero || count <= 3)
            .frame(width: width, height: height)
            .scaleEffect(
                style == .canopy && count == 1 ? 1.42 : (style == .hero ? 1.12 : 1),
                anchor: .bottom
            )
            .position(
                x: plantX(index: index, count: count, in: size),
                y: size.height * (style == .hero ? 0.58 : 0.61)
            )
            .offset(
                x: reduceMotion ? 0 : (drifting ? 3 : -3) * direction(at: index),
                y: reduceMotion ? 0 : (drifting ? -2 : 2)
            )
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 7.5 + Double(index) * 0.7)
                        .repeatForever(autoreverses: true),
                value: drifting
            )
    }

    private func plantWidth(count: Int, in size: CGSize) -> CGFloat {
        guard style == .canopy else { return size.width * 0.78 }
        if count <= 1 { return size.width * 0.82 }
        if count == 2 { return size.width * 0.58 }
        return max(size.width * 0.32, size.width * 1.62 / CGFloat(count))
    }

    private func plantX(index: Int, count: Int, in size: CGSize) -> CGFloat {
        guard style == .canopy else { return size.width * 0.75 }
        guard count > 1 else { return size.width * 0.66 }
        let step = size.width / CGFloat(count)
        return step * (CGFloat(index) + 0.5)
    }

    private func stature(at index: Int) -> CGFloat {
        let steps: [CGFloat] = [0.82, 1.0, 0.72, 0.94, 0.78, 1.02, 0.84]
        return steps[index % steps.count]
    }

    private func direction(at index: Int) -> CGFloat {
        index.isMultiple(of: 2) ? 1 : -1
    }

    private func farFoliage(in size: CGSize) -> some View {
        ZStack {
            GroveLivingLeaf()
                .fill(palette[1].opacity(0.20))
                .frame(width: size.width * 0.46, height: size.height * 0.82)
                .rotationEffect(.degrees(-34))
                .offset(x: -size.width * 0.38, y: -size.height * 0.19)
                .blur(radius: 2)

            GroveLivingLeaf()
                .fill(.black.opacity(0.07))
                .frame(width: size.width * 0.34, height: size.height * 0.70)
                .rotationEffect(.degrees(38))
                .offset(x: size.width * 0.42, y: -size.height * 0.22)
                .blur(radius: 1.5)
        }
        .groveParallax(depth: 3)
    }

    private func foregroundFoliage(in size: CGSize) -> some View {
        ZStack {
            GroveLivingLeaf()
                .fill(palette[0].opacity(style.foregroundOpacity))
                .frame(width: size.width * 0.40, height: size.height * 0.88)
                .rotationEffect(.degrees(30))
                .offset(x: -size.width * 0.43, y: size.height * 0.33)
                .blur(radius: 0.8)

            GroveLivingLeaf()
                .fill(.black.opacity(style.foregroundOpacity * 0.46))
                .frame(width: size.width * 0.34, height: size.height * 0.76)
                .rotationEffect(.degrees(-30))
                .offset(x: size.width * 0.44, y: size.height * 0.34)
                .blur(radius: 1.2)
        }
        .groveParallax(depth: 12)
    }
}

/// One of the user's plants with Grove's shared rim light. This is deliberately
/// public to the feature module: Journey uses the same object without the
/// full-bleed scene around it.
struct GroveLivingPlant: View {
    let plant: Plant
    var breathes = true
    var showsPot = false

    var body: some View {
        ZStack(alignment: .bottom) {
            RadialGradient(
                colors: [
                    .white.opacity(0.20),
                    plant.palette.colors[1].opacity(0.24),
                    .clear
                ],
                center: .init(x: 0.72, y: 0.28),
                startRadius: 0,
                endRadius: 110
            )
            .blur(radius: 8)

            PlantPortrait(
                plant: plant,
                breathes: breathes,
                showsGround: false,
                bleeds: true
            )
            .saturation(1.28)
            .contrast(1.08)
            .brightness(0.04)
            .shadow(color: .black.opacity(0.20), radius: 8, y: 5)

            if showsPot {
                GroveLivingPot(palette: plant.palette)
                    .frame(width: 34, height: 24)
                    .padding(.bottom, 1)
            }
        }
        .groveParallax(depth: 7)
        .accessibilityHidden(true)
    }
}

private struct GroveLivingPot: View {
    let palette: PlantPalette

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 10,
                bottomTrailingRadius: 10,
                topTrailingRadius: 4,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.66, green: 0.36, blue: 0.19),
                        Color(red: 0.38, green: 0.19, blue: 0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .padding(.top, 4)

            Capsule()
                .fill(Color(red: 0.78, green: 0.47, blue: 0.27))
                .frame(height: 7)
                .overlay { Capsule().stroke(.white.opacity(0.18), lineWidth: 1) }
                .overlay { Capsule().fill(palette.colors[1].opacity(0.10)) }
        }
        .shadow(color: .black.opacity(0.22), radius: 3, y: 2)
        .accessibilityHidden(true)
    }
}

/// Light and pollen that can also be laid over photography and the Journey
/// viewport. It is intentionally quiet: the scene should feel alive before it
/// reads as animated.
struct GroveLivingAtmosphereLayer: View {
    var atmosphere: GroveAtmosphere = .current
    var intensity: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifting = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RadialGradient(
                    colors: [
                        lightColor.opacity(0.34 * intensity),
                        .clear
                    ],
                    center: .init(x: 0.84, y: 0.04),
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.82
                )

                ForEach(0..<10, id: \.self) { index in
                    Circle()
                        .fill(moteColor.opacity(moteOpacity(index)))
                        .frame(width: moteSize(index), height: moteSize(index))
                        .position(
                            x: proxy.size.width * moteX(index),
                            y: proxy.size.height * moteY(index)
                        )
                        .offset(
                            x: reduceMotion ? 0 : (drifting ? 5 : -4) * (index.isMultiple(of: 2) ? 1 : -1),
                            y: reduceMotion ? 0 : (drifting ? -9 : 7)
                        )
                        .blur(radius: index.isMultiple(of: 3) ? 0.8 : 0)
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeInOut(duration: 5.5 + Double(index % 4))
                                    .repeatForever(autoreverses: true),
                            value: drifting
                        )
                }
            }
            .onAppear { drifting = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var lightColor: Color {
        switch atmosphere {
        case .midnight: GroveTheme.midnightTint
        case .preDawn: GroveTheme.preDawnTint
        case .dawn: GroveTheme.dawnTint
        case .morning: GroveTheme.morningTint
        case .day: .white
        case .afternoon: GroveTheme.afternoonTint
        case .goldenHour: GroveTheme.goldenHourTint
        case .dusk: GroveTheme.duskTint
        case .night: GroveTheme.nightTint
        }
    }

    private var moteColor: Color {
        switch atmosphere {
        case .midnight, .night: Color(red: 0.78, green: 0.95, blue: 0.55)
        default: .white
        }
    }

    private func moteSize(_ index: Int) -> CGFloat {
        [2.0, 3.0, 2.5, 4.0][index % 4]
    }

    private func moteOpacity(_ index: Int) -> Double {
        (index.isMultiple(of: 3) ? 0.42 : 0.24) * intensity
    }

    private func moteX(_ index: Int) -> CGFloat {
        let values: [CGFloat] = [0.12, 0.24, 0.38, 0.52, 0.64, 0.76, 0.88, 0.31, 0.69, 0.93]
        return values[index % values.count]
    }

    private func moteY(_ index: Int) -> CGFloat {
        let values: [CGFloat] = [0.18, 0.72, 0.36, 0.82, 0.24, 0.60, 0.44, 0.10, 0.90, 0.68]
        return values[index % values.count]
    }
}

/// A proper botanical blade rather than an SF Symbol used as decoration.
private struct GroveLivingLeaf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let base = CGPoint(x: rect.midX, y: rect.maxY)
        let tip = CGPoint(x: rect.midX * 0.82, y: rect.minY)
        path.move(to: base)
        path.addCurve(
            to: tip,
            control1: CGPoint(x: rect.minX - rect.width * 0.08, y: rect.height * 0.66),
            control2: CGPoint(x: rect.minX + rect.width * 0.04, y: rect.height * 0.12)
        )
        path.addCurve(
            to: base,
            control1: CGPoint(x: rect.maxX - rect.width * 0.04, y: rect.height * 0.16),
            control2: CGPoint(x: rect.maxX + rect.width * 0.10, y: rect.height * 0.72)
        )
        return path
    }
}
