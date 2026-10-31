import SwiftUI

/// Grove's interaction feel: how surfaces answer a finger, how content arrives,
/// and how numbers change.
///
/// The design system already owned *colour*, *type* and *elevation*, and
/// `GroveMotion` already owned the springs. What it did not own was the layer
/// between them — the part a user cannot name but immediately notices. Before
/// this file, roughly thirty tappable surfaces across the app were wrapped in
/// `.buttonStyle(.plain)`, which is SwiftUI's way of saying "render this and
/// respond to nothing": plant cards, collection tiles, care rows, the Today
/// hero and every quick action sat completely inert under a fingertip while the
/// three capsule buttons had a spring. Content appeared instantly and all at
/// once. Numbers cut from one value to another.
///
/// Everything here is opt-in per call site but consistent by construction: one
/// press response, one entrance, one way a number moves — and all three fall
/// back gracefully when Reduce Motion is on.
enum GroveFeel {
    /// How far a pressed card sinks. Small on purpose: cards are large, and a
    /// large surface scaling the way a small button does reads as a glitch.
    static let cardPressScale: CGFloat = 0.975
    /// How far a pressed tile sinks. Tiles are small, so they can take more.
    static let tilePressScale: CGFloat = 0.955
    /// The gap between consecutive items in a staggered entrance. Long enough
    /// to read as a sequence, short enough that the last item is not late.
    static let stagger: Double = 0.055
    /// How far a revealing element travels. Beyond about 20 pt an entrance
    /// stops feeling like settling and starts feeling like flying.
    static let revealOffset: CGFloat = 16
}

// MARK: - Reduce Motion

/// Runs an animation only when the user has not asked for less motion.
///
/// Reduce Motion was honoured in exactly two files before this. It is not an
/// accessibility footnote — for users with vestibular sensitivity a spring that
/// overshoots is the difference between an app that is pleasant and one that is
/// unusable — so it belongs in the shared layer where it cannot be forgotten.
private struct GroveAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeInOut(duration: 0.15) : animation, value: value)
    }
}

extension View {
    /// Animates on `value`, degrading to a short cross-fade under Reduce
    /// Motion. Prefer this to a bare `.animation(_:value:)` for anything that
    /// moves, scales or springs.
    func groveAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(GroveAnimationModifier(animation: animation, value: value))
    }
}

// MARK: - Press styles

/// The press response for large surfaces: cards, heroes, rows, list items.
///
/// Three things happen together, which is what makes it read as a physical
/// press rather than an effect: the surface sinks slightly, its shadow tightens
/// as if it moved closer to the page, and the Taptic Engine confirms contact on
/// touch-*down* — not on release. Confirming on release is a report; confirming
/// on contact is a response.
struct GroveCardPressStyle: ButtonStyle {
    var scale: CGFloat = GroveFeel.cardPressScale
    /// Set false for surfaces that already speak (a card whose own content
    /// reacts), so a single tap never fires two taps.
    var haptics: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, scale: scale, haptics: haptics)
    }

    /// A nested `View` rather than styling `configuration.label` directly:
    /// `makeBody` is not a view body, so `@Environment` — and therefore Reduce
    /// Motion — is only readable from inside one.
    private struct PressBody: View {
        let configuration: Configuration
        let scale: CGFloat
        let haptics: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? scale : 1))
                .brightness(configuration.isPressed ? -0.015 : 0)
                .animation(GroveMotion.press, value: configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, isPressed in
                    guard haptics, isPressed else { return }
                    Haptics.press()
                }
        }
    }
}

/// The press response for small surfaces: quick-action tiles, chips, symbol
/// buttons. Same physics, more travel, because a 70 pt tile needs a larger
/// percentage to register the same amount of movement on screen.
struct GroveTilePressStyle: ButtonStyle {
    /// Set false where the tile's own action answers with a haptic of its own,
    /// so a single press never fires two.
    var haptics: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        GroveCardPressStyle(scale: GroveFeel.tilePressScale, haptics: haptics)
            .makeBody(configuration: configuration)
    }
}

// MARK: - Entrance

/// Staggers an element into view: it fades up into place a beat after the one
/// before it.
///
/// The scan result page already did this, but the modifier was private to
/// `ScanView`, so every other screen in the app appeared as a single flat
/// block. Reading order is a design decision — this is how a screen states it.
private struct GroveRevealModifier: ViewModifier {
    let index: Int
    /// Extra delay before the whole sequence starts, for content that should
    /// wait on something else (a hero image, a sheet's own presentation).
    let baseDelay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : GroveFeel.revealOffset)
            .scaleEffect(revealed || reduceMotion ? 1 : 0.98, anchor: .top)
            .onAppear {
                guard !revealed else { return }
                withAnimation(
                    reduceMotion
                        ? .easeOut(duration: 0.2)
                        : GroveMotion.reveal.delay(baseDelay + Double(index) * GroveFeel.stagger)
                ) {
                    revealed = true
                }
            }
    }
}

extension View {
    /// Fades and lifts this element into place, `index` beats after the first.
    /// Number the blocks of a screen in reading order.
    func groveReveal(_ index: Int, baseDelay: Double = 0) -> some View {
        modifier(GroveRevealModifier(index: index, baseDelay: baseDelay))
    }
}

// MARK: - Departure

/// How a row joins and leaves a list.
///
/// The entrance had a shared answer — `groveReveal` — and the exit had none, so
/// a task the user had just ticked off, or a plant they had just deleted, simply
/// stopped existing between two frames while the rows below jumped up to fill
/// the hole. A list that only animates arrivals is a list that tells you what it
/// gained and never what it spent.
///
/// The removal is deliberately quicker than the arrival: something leaving
/// should get out of the way, not perform on the way out.
private struct GroveRowTransitionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -GroveFeel.revealOffset)),
                    removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
                )
        )
    }
}

extension View {
    /// Gives this row an entrance and, more importantly, an exit. Apply to the
    /// row itself, and wrap whatever removes it from the model in
    /// `withAnimation(GroveMotion.settle)`.
    func groveRowTransition() -> some View {
        modifier(GroveRowTransitionModifier())
    }
}

extension View {
    /// Retained as a source-compatible no-op. Per-frame blur and scale on every
    /// lazy row made fast scrolling visibly hitch on physical devices.
    func groveScrollReveal() -> some View {
        self
    }
}

// MARK: - Numbers

/// A number that rolls to its new value instead of cutting to it.
///
/// Health scores, streaks, task counts and XP are the app's evidence that
/// something changed; a value that simply swaps has no before, so there is
/// nothing to notice. This rolls the digits, and optionally plays a rising
/// texture under them so the change is felt as well as seen.
struct GroveRollingNumber: View {
    let value: Int
    var font: Font = .title3.weight(.bold)
    var color: Color = GroveTheme.ink
    /// A trailing unit rendered at a quieter weight ("%", "/100", "d").
    var suffix: String?
    /// Shows a leading "+" for positive values — deltas want it, totals do not.
    var signed: Bool = false
    /// How long the roll takes when the view first appears.
    var duration: Double = 0.85
    /// Plays `Haptics.climb` under an increase. Reserve it for one number per
    /// screen: several rolling at once is noise, not texture.
    var hapticOnIncrease: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0
    @State private var hasAppeared = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(text(for: shown))
                .font(font)
                .foregroundStyle(color)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(shown)))
            if let suffix {
                Text(suffix)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GroveTheme.mutedInk)
            }
        }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            roll(to: value, from: 0)
        }
        .onChange(of: value) { previous, next in
            roll(to: next, from: previous)
        }
        // VoiceOver reads the destination, never the rolling intermediate:
        // without `children: .ignore` the label would be dropped in favour of
        // the two child texts, and the digits mid-roll are meaningless.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text(for: value) + (suffix ?? ""))
    }

    private func text(for number: Int) -> String {
        signed && number > 0 ? "+\(number)" : "\(number)"
    }

    private func roll(to target: Int, from previous: Int) {
        guard !reduceMotion else {
            shown = target
            return
        }
        withAnimation(.easeOut(duration: duration)) { shown = target }
        if hapticOnIncrease, target > previous {
            Haptics.climb(steps: max(1, (target - previous) / 4))
        }
    }
}

// MARK: - Success mark

/// The checkmark that draws itself when something completes.
///
/// A tick that is simply *there* states a fact. A tick that draws, inside a
/// ring that pops and a wash that blooms outward, reads as the moment the thing
/// finished — which is the moment worth marking in a care app, because
/// finishing is the whole loop.
struct GroveSuccessMark: View {
    var size: CGFloat = 72
    var tint: Color = GroveTheme.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trim: CGFloat = 0
    @State private var ring: CGFloat = 0.6
    @State private var bloom: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.35), lineWidth: 2)
                .scaleEffect(1 + bloom * 0.5)
                .opacity(1 - bloom)

            Circle().fill(tint.opacity(0.14))

            CheckmarkPath()
                .trim(from: 0, to: trim)
                .stroke(tint, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round, lineJoin: .round))
                .padding(size * 0.28)
        }
        .frame(width: size, height: size)
        .scaleEffect(ring)
        .onAppear(perform: animate)
        .accessibilityHidden(true)
    }

    private func animate() {
        guard !reduceMotion else {
            trim = 1
            ring = 1
            return
        }
        withAnimation(GroveMotion.celebrate) { ring = 1 }
        withAnimation(.easeOut(duration: 0.35).delay(0.08)) { trim = 1 }
        withAnimation(.easeOut(duration: 0.7).delay(0.08)) { bloom = 1 }
    }
}

/// The tick itself, drawn as a path so it can be trimmed. An SF Symbol cannot
/// be: symbols are glyphs, and a glyph has no stroke to animate along.
private struct CheckmarkPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.04))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY - rect.height * 0.06))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.10))
        return path
    }
}

// MARK: - Shimmer

/// A light sweeping across placeholder content while it loads.
///
/// Grove already redacts loading content, which greys it out and then stops
/// telling you anything. A slow sweep is the difference between "this is
/// broken" and "this is coming" — and it costs one gradient.
private struct GroveShimmerModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content
                // The sweep is an overlay clipped to the view's own bounds
                // rather than a second copy of the content used as a mask:
                // instantiating `Content` twice would run every child's
                // lifecycle twice for a decorative highlight.
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.45), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.6)
                        .blendMode(.plusLighter)
                    }
                    .allowsHitTesting(false)
                }
                .clipped()
                .onAppear {
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    /// Sweeps a soft highlight across this view while `active`. Pair with
    /// `.redacted(reason: .placeholder)`.
    func groveShimmer(active: Bool = true) -> some View {
        modifier(GroveShimmerModifier(active: active))
    }
}

// MARK: - Attention

/// A one-shot nudge for an element that just became important: it swells and
/// settles. Used when a value the user is watching updates underneath them.
private struct GrovePulseModifier<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pulse && !reduceMotion ? 1.06 : 1)
            .onChange(of: value) { _, _ in
                guard !reduceMotion else { return }
                withAnimation(GroveMotion.celebrate) { pulse = true }
                withAnimation(GroveMotion.settle.delay(0.16)) { pulse = false }
            }
    }
}

extension View {
    /// Swells this view once whenever `value` changes.
    func grovePulse<Value: Equatable>(on value: Value) -> some View {
        modifier(GrovePulseModifier(value: value))
    }
}
