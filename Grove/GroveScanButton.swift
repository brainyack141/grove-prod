import SwiftUI

/// The raised primary action in the centre of the tab bar.
///
/// This is all that survives of Grove's hand-drawn tab bar. That bar hid the
/// system one and rebuilt it from an `HStack` plus `glassEffect()`, which never
/// looked native and never could: the system bar samples its background
/// differently and carries the scroll-edge and minimize behaviours that make
/// glass read as glass in motion rather than only at rest. The one well-known
/// faithful recreation of it (ryanashcraft/FabBar) gets there by manipulating
/// UIKit's private view hierarchy, with a warning that Apple can break it at
/// any release. The tab bar is the system's now; only this button is ours.
///
/// `AppShellView` reserves an empty native tab item beneath this control. That
/// keeps Today, Ask, Scan, Friends and My Grove on the same five-column rhythm
/// while the control stays an action rather than a destination of its own.
///
/// The disc carries no caption. It used to, and the word was doing two kinds of
/// damage: it sat a line above the system labels' baseline, which is the first
/// thing that reads as unfinished on the one component every user sees on every
/// screen, and it pinned the raised action back into the tab grid it is
/// supposed to have risen out of. Every app that lifts its primary action into
/// the centre of the bar leaves it uncaptioned, because a disc that breaks the
/// bar's edge has already said it is not a tab.
///
/// It is a single action. A short-lived second role made it a scoped check-in
/// camera on a plant page, but the page grew its own docked action bar in the
/// same bottom edge — so the disc rose through that bar while duplicating its
/// primary action. A drill-in page owns its own bottom; this control is the
/// tab roots' scan, and nothing else.
///
/// Its silhouette is a leaf. On a disc, the four reticle brackets read as the
/// system's "go fullscreen" mark, and nothing about the control said plant.
/// Every other control along an iPhone's bottom edge is a circle or a capsule,
/// so a leaf is the one shape in the bar that can only be Grove's, and the
/// reticle inside it still says camera, which the shape alone could not.
struct GrovePrimaryActionButton: View {
    static let accessibilityLabel = "Scan a plant"
    static let accessibilityHint = "Opens the plant camera"
    static let accessibilityIdentifier = "scanButton"

    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isGroveLaunchRevealed) private var isLaunchRevealed
    @State private var focusPhase = GroveScanReticleFocusPhase.rest
    @State private var focusRequest: UUID?
    @State private var isLaunching = false
    @State private var entrance: Entrance
    @State private var isEntered = false
    @State private var showsGlyph: Bool

    /// The leaf unfurls once per launch, the first time it appears. Every
    /// later appearance (a pop back to a tab root, the keyboard going away)
    /// only fades in: the bar comes back dozens of times a session,
    /// and an entrance that replays on every one of them stops being a moment
    /// and becomes noise.
    @MainActor private static var hasUnfurled = false

    private enum Entrance {
        case unfurl
        case fade
    }

    init(action: @escaping () -> Void = {}) {
        self.action = action
        // `State` keeps only the first value per identity, so a parent
        // re-render after the flag flips cannot swap the style mid-unfurl.
        let entrance: Entrance = Self.hasUnfurled ? .fade : .unfurl
        _entrance = State(initialValue: entrance)
        _showsGlyph = State(initialValue: entrance == .fade)
    }

    /// Lifts the disc so it rises through the top edge of the bar, standing in
    /// for the label row the caption used to occupy — a fixed offset now, so the
    /// disc no longer drifts with Dynamic Type. Toasts clear the whole control.
    static let barBottomPadding: CGFloat = 20
    static let toastClearance: CGFloat = 86

    /// A square whose leading-top and trailing-bottom corners are full quarter
    /// circles, leaving the other two as the leaf's stem and tip. Circular, not
    /// continuous: continuous corners at half the side flatten the leaf into a
    /// rounded square. 54 pt carries the same visual weight as the 56 pt disc
    /// it replaced, because the tips fill more of their box than a circle does.
    /// It is a mark rather than a container, so its 8 pt tips sit outside the
    /// four-radius scale on purpose.
    static let side: CGFloat = 54
    static let shape = UnevenRoundedRectangle(
        topLeadingRadius: side / 2,
        bottomLeadingRadius: 8,
        bottomTrailingRadius: side / 2,
        topTrailingRadius: 8,
        style: .circular
    )

    var body: some View {
        Button {
            guard !isLaunching else { return }
            // The app's primary action gets the app's committing tap, and it
            // fires here rather than through `sensoryFeedback` so it honours
            // the haptics preference.
            Haptics.commit()
            guard !reduceMotion else {
                action()
                return
            }

            // The icon answers before the modal does: the first diagonal finds
            // focus, the second confirms it, then those same four brackets open
            // into the live camera reticle. The 125 ms handoff is short enough
            // to keep the camera immediate and long enough for the lock to read.
            isLaunching = true
            focusRequest = UUID()
        } label: {
            ZStack {
                Color.clear

                // Smaller than the disc's 25 pt so the brackets clear the
                // leaf's tips, and drawn a quarter heavier so they keep the
                // weight they had at the larger size.
                GroveScanReticleGlyph(phase: focusPhase, strokeScale: 1.25)
                    .frame(width: 22, height: 22)
                    .opacity(showsGlyph ? 1 : 0)
            }
            .frame(width: Self.side, height: Self.side)
            .modifier(GrovePrimaryActionButtonSurface(usesGlass: isEntered && showsGlyph))
            // The whole square answers, not only the leaf: a thumb that lands
            // just past a tip on the app's primary action is still a scan.
            .contentShape(.rect)
        }
        .buttonStyle(GroveCardPressStyle(scale: GroveFeel.tilePressScale, haptics: false))
        // The blade opens on `drift`, the slowest spring and the only one with
        // no visible bounce; opacity, which only fades, eases rather than
        // springs.
        .modifier(GroveLeafUnfurl(openness: unfurlOpenness))
        .animation(GroveMotion.drift, value: isEntered)
        .opacity(isEntered ? 1 : 0)
        .animation(.easeInOut(duration: unfurls ? 0.35 : 0.25), value: isEntered)
        // Guard duplicate taps without putting the control into SwiftUI's
        // visually dimmed disabled state during its brightest focus moment.
        .allowsHitTesting(!isLaunching)
        .accessibilityLabel(Self.accessibilityLabel)
        .accessibilityHint(Self.accessibilityHint)
        .accessibilityIdentifier(Self.accessibilityIdentifier)
        // Changing the request cancels the entrance before a tap runs the
        // tighter launch sequence; the entrance's own cleanup finishes drawing
        // the leaf so the tap never lands on half a control.
        .task(id: focusTask) {
            switch focusTask {
            case .launch(let request):
                await playLaunchFocus(request: request)
            case .entrance(isVisible: true):
                await playEntrance()
            case .entrance(isVisible: false):
                break
            }
        }
    }

    // MARK: - Entrance

    private enum FocusTask: Equatable {
        /// Visible means the scene is active and the launch curtain has lifted:
        /// an unfurl that plays behind either has happened for no one.
        case entrance(isVisible: Bool)
        case launch(UUID)
    }

    private var focusTask: FocusTask {
        if let focusRequest {
            .launch(focusRequest)
        } else {
            .entrance(isVisible: scenePhase == .active && isLaunchRevealed)
        }
    }

    private var unfurls: Bool {
        entrance == .unfurl && !reduceMotion
    }

    /// Closed to a blade along the midrib, not to nothing, so the first frame
    /// already reads as a leaf seen edge-on.
    private var unfurlOpenness: CGFloat {
        isEntered || !unfurls ? 1 : 0.06
    }

    /// The first appearance in a launch opens the leaf along its midrib and
    /// lets the reticle surface inside it as it finishes: one gesture, no
    /// bounce, no haptic. An earlier cut also grew and lifted the leaf and ran
    /// a two-beat focus lock with a tap on top, and four things moving at once
    /// read as hectic rather than alive. Later appearances, and every
    /// appearance under Reduce Motion, only cross-fade in.
    private func playEntrance() async {
        guard !isEntered else { return }
        defer {
            // A tap, or the scene going inactive, can cut the sequence short.
            // Never leave the app's primary action half drawn.
            if !isEntered || !showsGlyph {
                isEntered = true
                showsGlyph = true
            }
        }

        guard unfurls else {
            Self.hasUnfurled = true
            isEntered = true
            showsGlyph = true
            return
        }

        // Starts while the launch curtain is still half faded, so the leaf
        // finishes opening in clear view rather than after a visible gap.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled, focusRequest == nil else { return }

        Self.hasUnfurled = true
        isEntered = true
        try? await Task.sleep(for: .milliseconds(320))
        guard !Task.isCancelled, focusRequest == nil else { return }

        withAnimation(.easeInOut(duration: 0.3)) { showsGlyph = true }
    }

    private func playLaunchFocus(request: UUID) async {
        defer {
            // `fullScreenCover` leaves the shell alive underneath it. Resetting
            // here means the control is ready, and visually at rest, when the
            // camera is dismissed.
            if focusRequest == request {
                focusPhase = .rest
                isLaunching = false
            }
        }

        withAnimation(GroveMotion.snap) { focusPhase = .firstDiagonal }
        try? await Task.sleep(for: .milliseconds(45))
        guard !Task.isCancelled, focusRequest == request else { return }

        withAnimation(GroveMotion.snap) { focusPhase = .focused }
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled, focusRequest == request else { return }

        action()

        // Keep the source locked while the destination reticle blooms. This
        // happens behind the cover, but prevents a white-frame flash if modal
        // presentation is interrupted or reduced by the system.
        try? await Task.sleep(for: .milliseconds(420))
    }
}

/// Squeezes the leaf across its midrib, the diagonal from the stem at the
/// bottom-leading tip to the top-trailing one, so at zero it is a closed blade
/// and at one the open leaf. `scaleEffect` can only squeeze along the screen's
/// axes, which folds a leaf like a card instead of opening it like one.
private struct GroveLeafUnfurl: GeometryEffect {
    var openness: CGFloat

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Scaling by `openness` along the unit diagonal d = (1, 1) / √2 is
        // I + (openness − 1)·d·dᵀ: symmetric, and the midrib (1, −1) is fixed.
        let squeeze = (openness - 1) / 2
        let across = CGAffineTransform(
            a: 1 + squeeze, b: squeeze,
            c: squeeze, d: 1 + squeeze,
            tx: 0, ty: 0
        )
        let centre = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
        return ProjectionTransform(centre.inverted().concatenating(across).concatenating(centre))
    }
}

private struct GroveLaunchRevealedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the branded launch curtain still covers the app. Motion that
    /// only plays once, like the scan leaf's unfurl, waits for it to lift.
    var isGroveLaunchRevealed: Bool {
        get { self[GroveLaunchRevealedKey.self] }
        set { self[GroveLaunchRevealedKey.self] = newValue }
    }
}

enum GroveScanReticleFocusPhase: Equatable {
    case rest
    case firstDiagonal
    case focused
}

/// The camera's own rounded reticle, drawn proportionally so it is the same
/// instrument at any size: the 22 pt tab glyph, and the 17 pt mark inside a
/// care row's check-in marker. Reusing its geometry makes the scan action an
/// origin for the instrument on the next screen instead of another app wearing
/// the stock viewfinder symbol.
struct GroveScanReticleGlyph: View {
    let phase: GroveScanReticleFocusPhase
    var tint: Color = GroveTheme.onAccent
    /// Multiplies the proportional stroke, for a glyph drawn smaller than its
    /// surroundings would otherwise weight it.
    var strokeScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let arm = side * 0.34

            ZStack {
                ForEach(0..<4, id: \.self) { corner in
                    let focus = focusAmount(for: corner)
                    let inset = side * (0.036 + 0.068 * focus)

                    GroveScanReticleCorner()
                        .stroke(
                            tint.opacity(0.86 + 0.14 * focus),
                            style: StrokeStyle(
                                lineWidth: side * (0.08 + 0.01 * focus) * strokeScale,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        .frame(width: arm, height: arm)
                        .rotationEffect(.degrees(Double(corner) * 90))
                        .position(
                            x: corner == 0 || corner == 3
                                ? inset + arm / 2
                                : proxy.size.width - inset - arm / 2,
                            y: corner < 2
                                ? inset + arm / 2
                                : proxy.size.height - inset - arm / 2
                        )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func focusAmount(for corner: Int) -> CGFloat {
        switch phase {
        case .rest:
            0
        case .firstDiagonal:
            corner == 0 || corner == 2 ? 1 : 0
        case .focused:
            1
        }
    }
}

private struct GrovePrimaryActionButtonSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let usesGlass: Bool

    func body(content: Content) -> some View {
        // Glass waits for the leaf to finish opening. The system draws it
        // outside the button's opacity, so a half-open leaf's squeeze came
        // out as a dark wedge across the screen; plain ink unfurls cleanly.
        if usesGlass, !reduceTransparency, #available(iOS 26.0, *) {
            // Tinted, interactive Liquid Glass — and deliberately no shadow and
            // no background of our own. The system draws both from what is
            // behind the button; the soft drop shadow the first pass hung under
            // it is exactly what made glass read as an opaque disc with a blur.
            //
            // Tinted with `accentStrong` rather than `accent`: the material
            // lightens whatever it is given, and the mid green came back out of
            // it as a flat sage that belonged to no part of the palette. The
            // darker token lands on the leaf green the tab bar's selection uses.
            // Ink, like every primary action (DESIGN.md §16 rule 6).
            content.glassEffect(
                .regular.tint(GroveTheme.ink).interactive(),
                in: GrovePrimaryActionButton.shape
            )
        } else {
            // Pre-26 has no glass to tint, so the button carries its own weight.
            // Its shadow is the same neutral two-layer elevation every raised
            // surface in Grove uses; the tinted green one it used to cast was a
            // bloom, and bloom is how a button announces that its layout is not
            // carrying the emphasis on its own.
            content
                .background(GroveTheme.ink, in: GrovePrimaryActionButton.shape)
                .overlay {
                    GrovePrimaryActionButton.shape
                        .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
                }
                .groveShadow(.floating)
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 12) {
            ForEach(0..<12, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(GroveTheme.surface)
                    .frame(height: 72)
            }
        }
        .padding()
    }
    .groveBackground()
    .overlay(alignment: .bottom) {
        GrovePrimaryActionButton()
            .padding(.bottom, GrovePrimaryActionButton.barBottomPadding)
    }
}
