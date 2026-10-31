import SwiftUI

/// Grove draws its own plants.
///
/// Until now the subject of the app — the plant — had no form of its own. Every
/// place a photograph was missing, `PlantArtwork` drew a gradient with an SF
/// Symbol floating on it, which is what a well-built app looks like rather than
/// what a designed one looks like: the same six glyphs Apple ships to everyone,
/// standing in for the one thing that is supposed to be ours.
///
/// `PlantPortrait` replaces that with a botanical drawn in `Canvas` from the
/// plant's own record. It is:
///
/// - **Deterministic.** The silhouette is seeded from the plant's `id`, so a
///   plant looks like itself on every launch, in every grid, forever. Two
///   plants of the same species are visibly siblings but never twins.
/// - **Diagnostic.** Growth habit comes from the species palette and posture
///   comes from health: a thriving plant holds its leaves up and carries a full
///   crown; a struggling one droops, thins out, and loses its lift. The artwork
///   is telling the user something before they have read a single word.
/// - **Free.** It is geometry, so it costs no asset weight, re-tints itself for
///   dark mode, and is sharp at any size from a 40 pt row icon to a full-bleed
///   hero.
struct PlantPortrait: View {
    let seed: UInt64
    let palette: PlantPalette
    /// 0…1. Drives lift, fullness and colour: 1 is a plant holding itself up.
    let vitality: Double
    /// Gentle ambient sway. Worth it on a hero; not worth a timeline per cell
    /// in a scrolling grid, so it stays off by default.
    var breathes: Bool = false
    /// Draws the palette gradient behind the foliage.
    ///
    /// Off for the canopy on My Grove, where seven portraits stand side by side
    /// on one shared wash: seven gradient rectangles in a row is a colour chart,
    /// not a grove. Everywhere else a portrait is its own object and keeps its
    /// ground.
    var showsGround: Bool = true
    /// Fixes the portrait's height and crops it, matching how `PlantArtwork`
    /// was called everywhere it used to stand in for a plant. Leave `nil` to
    /// let the portrait fill whatever it is given.
    var height: CGFloat?
    /// Lets foliage cross the portrait's own bounds instead of being cropped at
    /// them. On for the canopy on My Grove, where seven plants share one strip
    /// and a leaf reaching into its neighbour's column is the entire point of a
    /// canopy. Everywhere else a portrait is a framed picture and stays inside
    /// its frame.
    var bleeds: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        if bleeds {
            drawing
        } else {
            drawing.clipped()
        }
    }

    private var drawing: some View {
        ZStack {
            if showsGround { ground }
            if breathes && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                    foliage(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                foliage(at: 0)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    // MARK: - Layers

    /// The ground the plant is drawn on: the plant's own palette, pushed back
    /// so the foliage reads in front of it rather than against it.
    private var ground: some View {
        LinearGradient(
            colors: palette.colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            // A single soft light source, high and to the right. Every portrait
            // in the app is lit from the same place, which is most of why a
            // grid of them looks like one set rather than five drawings.
            RadialGradient(
                colors: [.white.opacity(Botanical.lightStrength), .clear],
                center: .init(x: 0.82, y: 0.12),
                startRadius: 0,
                endRadius: 220
            )
        }
    }

    private func foliage(at time: TimeInterval) -> some View {
        Canvas { context, size in
            var rng = SeededGenerator(seed: seed)
            let plan = Botanical.plan(for: palette, vitality: vitality, rng: &rng)
            draw(plan, in: &context, size: size, time: time, showsGround: showsGround)
        }
    }

    // MARK: - Drawing

    private func draw(
        _ plan: Botanical.Plan,
        in context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        showsGround: Bool
    ) {
        // The plant grows from just below the frame: a portrait is cropped at
        // the bottom like any other portrait, not a specimen floating in a box.
        //
        // The tiniest frames are avatar rings clipped to a circle, which cuts
        // away the bottom corners where the lowest leaves used to hang. There
        // the plant stands upright inside the circle on a shorter stem, so its
        // crown sits in the middle of the ring rather than off its edge.
        let isTiny = size.height < Botanical.tinyFrameHeight
        let base: CGPoint
        let apex: CGPoint
        if isTiny {
            base = CGPoint(x: size.width * (0.5 + plan.lean * 0.04), y: size.height * Botanical.tinyFrameBase)
            apex = CGPoint(
                x: size.width * (0.5 + plan.lean * 0.08),
                y: size.height * min(max(1 - plan.reach, Botanical.tinyFrameApexRange.lowerBound),
                                     Botanical.tinyFrameApexRange.upperBound)
            )
        } else {
            base = CGPoint(x: size.width * (0.5 + plan.lean * 0.16), y: size.height * 1.04)
            apex = CGPoint(
                x: size.width * (0.5 + plan.lean * 0.34),
                y: size.height * (1 - plan.reach)
            )
        }
        let stemLength = base.y - apex.y

        // The whole plant sways as one body, hinged at the base, so leaves keep
        // their relationship to the stem instead of shimmering independently.
        let sway = sin(time * Botanical.swaySpeed) * Botanical.swayRadians * plan.vitality
        context.translateBy(x: base.x, y: base.y)
        context.rotate(by: .radians(sway))
        context.translateBy(x: -base.x, y: -base.y)

        var stem = Path()
        stem.move(to: base)
        stem.addQuadCurve(
            to: apex,
            control: CGPoint(x: base.x + (apex.x - base.x) * plan.arch, y: base.y - stemLength * 0.55)
        )
        let stemWidth: CGFloat
        if isTiny {
            stemWidth = max(Botanical.tinyFrameStemWidth, size.width * Botanical.tinyFrameStemWidthRatio)
        } else if size.height < 80 {
            stemWidth = max(2, size.width * 0.03)
        } else {
            stemWidth = max(1.5, size.width * 0.016)
        }
        context.stroke(
            stem,
            with: .color(.black.opacity(Botanical.stemShade)),
            style: StrokeStyle(lineWidth: stemWidth, lineCap: .round)
        )

        // Small frames get a little more leaf length. The optical size pass
        // thins the crown, but a 40 pt avatar still needs a plant that reads as
        // a plant rather than three short strokes. The tiniest rings get a
        // stronger boost still, so the leaves fill the circle.
        let leafBoost: CGFloat
        if isTiny {
            leafBoost = Botanical.tinyFrameLeafBoost
        } else if size.height < 80 {
            leafBoost = Botanical.smallFrameLeafBoost
        } else if size.height < 140 {
            leafBoost = Botanical.compactFrameLeafBoost
        } else {
            leafBoost = 1
        }

        for var leaf in Botanical.leaves(plan.leaves, fitting: size) {
            var length = stemLength * leaf.length * leafBoost
            if isTiny {
                // Hang the crown from the upper part of the stem, the part
                // inside the circle, and keep every blade broad and short
                // enough to stay within the ring.
                leaf.position = Botanical.tinyFrameLeafSpan.lowerBound
                    + leaf.position * (Botanical.tinyFrameLeafSpan.upperBound - Botanical.tinyFrameLeafSpan.lowerBound)
                leaf.width = max(leaf.width, Botanical.tinyFrameMinLeafWidth)
                length = min(length, size.width * Botanical.tinyFrameMaxLeafLength)
            }
            // Leaves are hung along the stem's actual curve, not a straight
            // line, so an arching habit carries its foliage around with it.
            let anchor = pointOnStem(base: base, apex: apex, arch: plan.arch, t: leaf.position)
            drawLeaf(leaf, from: anchor, length: length, in: &context, showsGround: showsGround)
        }
    }

    private func drawLeaf(
        _ leaf: Botanical.Leaf,
        from anchor: CGPoint,
        length: CGFloat,
        in context: inout GraphicsContext,
        showsGround: Bool
    ) {
        let angle = leaf.angle
        let tip = CGPoint(
            x: anchor.x + cos(angle) * length,
            y: anchor.y + sin(angle) * length
        )
        let mid = CGPoint(x: (anchor.x + tip.x) / 2, y: (anchor.y + tip.y) / 2)
        // Perpendicular to the leaf's spine, scaled by how broad this species is.
        let half = length * leaf.width / 2
        let perp = CGPoint(x: -sin(angle) * half, y: cos(angle) * half)

        var blade = Path()
        blade.move(to: anchor)
        blade.addQuadCurve(to: tip, control: CGPoint(x: mid.x + perp.x, y: mid.y + perp.y))
        blade.addQuadCurve(to: anchor, control: CGPoint(x: mid.x - perp.x, y: mid.y - perp.y))

        // The blade is the palette's own mid-tone, then lifted toward white or
        // pushed toward shadow depending on which side of the stem it grew on.
        // That is the entire lighting model, and it is enough: it reuses the
        // governed palette rather than minting a second green.
        //
        // On a portrait with its own ground, the foliage must separate from
        // that ground: the ground's gradient runs through the same palette
        // mid-tone, so a leaf filled with it vanished. Ground-backed leaves are
        // therefore lifted clearly toward white on both sides — brighter on the
        // lit side — and given a hairline dark edge. The canopy keeps the
        // original, subtler model because it stands on a shared wash.
        context.fill(blade, with: .color(palette.colors[1]))
        if showsGround {
            context.fill(
                blade,
                with: .color(.white.opacity(leaf.lit
                    ? Botanical.groundLeafLift
                    : Botanical.groundLeafShade))
            )
            context.stroke(
                blade,
                with: .color(.black.opacity(Botanical.leafEdgeShade)),
                style: StrokeStyle(lineWidth: max(0.6, length * 0.02), lineCap: .round)
            )
        } else {
            context.fill(
                blade,
                with: .color(leaf.lit
                    ? .white.opacity(Botanical.litLift * leaf.exposure)
                    : .black.opacity(Botanical.shadeDepth * leaf.exposure))
            )
        }

        // A midrib. It is one hairline and it is the difference between a green
        // shape and a leaf.
        var rib = Path()
        rib.move(to: anchor)
        rib.addQuadCurve(
            to: tip,
            control: CGPoint(x: mid.x + perp.x * Botanical.ribBow, y: mid.y + perp.y * Botanical.ribBow)
        )
        context.stroke(
            rib,
            with: .color(.black.opacity(Botanical.ribShade)),
            style: StrokeStyle(lineWidth: max(0.5, length * 0.012), lineCap: .round)
        )
    }

    /// Where a leaf meets the stem, `t` of the way up its quadratic curve.
    private func pointOnStem(base: CGPoint, apex: CGPoint, arch: CGFloat, t: CGFloat) -> CGPoint {
        let control = CGPoint(
            x: base.x + (apex.x - base.x) * arch,
            y: base.y - (base.y - apex.y) * 0.55
        )
        let inv = 1 - t
        return CGPoint(
            x: inv * inv * base.x + 2 * inv * t * control.x + t * t * apex.x,
            y: inv * inv * base.y + 2 * inv * t * control.y + t * t * apex.y
        )
    }
}

// MARK: - Convenience inits

extension PlantPortrait {
    init(
        plant: Plant,
        height: CGFloat? = nil,
        breathes: Bool = false,
        showsGround: Bool = true,
        bleeds: Bool = false
    ) {
        self.init(
            seed: Botanical.seed(from: plant.id),
            palette: plant.palette,
            vitality: Double(plant.healthScore) / 100,
            breathes: breathes,
            showsGround: showsGround,
            height: height,
            bleeds: bleeds
        )
    }

    /// A friend's plant is shared without its score, so posture comes from the
    /// band alone.
    init(friendPlant: FriendPlant, height: CGFloat? = nil, breathes: Bool = false) {
        self.init(
            seed: Botanical.seed(from: friendPlant.id),
            palette: friendPlant.palette,
            vitality: friendPlant.healthBand.vitality,
            breathes: breathes,
            height: height
        )
    }
}

extension HealthBand {
    /// How upright this band should stand in a portrait.
    var vitality: Double {
        switch self {
        case .thriving: 1.0
        case .healthy: 0.82
        case .monitor: 0.62
        case .attention: 0.42
        case .urgent: 0.22
        }
    }
}

// MARK: - The governed botanical

/// The illustration constants for Grove's plant portraits.
///
/// Storybook art is welcome in Grove, but never improvised inline — the same
/// rule that gave the Journey its `JourneyWorld`. Everything the portraits are
/// drawn from lives here: growth habits, lighting strengths, and the parameters
/// that turn a health score into a posture. The one thing this enum deliberately
/// does *not* hold is colour, because the portraits are drawn entirely from
/// `PlantPalette.colors` lifted toward white or pushed toward black. A leaf can
/// therefore never drift out of the family its card's gradient belongs to.
enum Botanical {

    // MARK: Light

    /// The soft highlight in the upper right of every portrait.
    static let lightStrength: Double = 0.16
    /// How far a lit leaf is lifted toward white on a canopy portrait, where
    /// the foliage shares one wash instead of sitting on its own ground.
    static let litLift: Double = 0.34
    /// How far a shaded leaf is pushed toward black on a canopy portrait.
    static let shadeDepth: Double = 0.22
    /// How far a lit leaf on a ground-backed portrait is lifted toward white.
    /// Higher than `litLift` because it has to separate from a gradient drawn
    /// in the same palette mid-tone.
    static let groundLeafLift: Double = 0.45
    /// How far a shaded leaf on a ground-backed portrait is lifted toward
    /// white: still clearly lighter than the ground, just less than the lit side.
    static let groundLeafShade: Double = 0.25
    /// A hairline dark edge that keeps a lightened leaf from dissolving into a
    /// light ground.
    static let leafEdgeShade: Double = 0.18
    /// Frames shorter than this are the very smallest (hero avatar rings,
    /// about 34 pt), drawn clipped to a circle.
    static let tinyFrameHeight: CGFloat = 48
    /// Leaf-length boost for the very smallest frames (hero avatar rings),
    /// where the plant has to fill the circle rather than read as a bare stem.
    static let tinyFrameLeafBoost: CGFloat = 1.9
    /// Where the stem starts in a tiny frame, as a fraction of its height:
    /// inside the circle, not below it.
    static let tinyFrameBase: CGFloat = 0.9
    /// The band the stem's tip is held within in a tiny frame, so a short
    /// habit still has a crown and a tall one does not leave the ring.
    static let tinyFrameApexRange: ClosedRange<CGFloat> = 0.14...0.4
    /// The stretch of the stem a tiny frame hangs its leaves on.
    static let tinyFrameLeafSpan: ClosedRange<CGFloat> = 0.28...0.95
    /// A tiny frame's leaves are at least this broad, so a fern's fronds read
    /// as leaves rather than hairlines.
    static let tinyFrameMinLeafWidth: CGFloat = 0.5
    /// The longest a tiny frame's leaf may be, as a fraction of frame width.
    static let tinyFrameMaxLeafLength: CGFloat = 0.4
    /// The stem's minimum width in those tiny frames, and its width as a
    /// fraction of the frame width.
    static let tinyFrameStemWidth: CGFloat = 2.5
    static let tinyFrameStemWidthRatio: CGFloat = 0.05
    /// Leaf-length boost for the smallest frames, where only a few leaves
    /// survive the optical-size pass and the plant needs to stay legible.
    static let smallFrameLeafBoost: CGFloat = 1.45
    /// Leaf-length boost for compact frames (row thumbnails and small tiles).
    static let compactFrameLeafBoost: CGFloat = 1.2
    /// The stem, and the midrib, read as the same shadow at two strengths.
    static let stemShade: Double = 0.26
    static let ribShade: Double = 0.14
    /// How much the midrib bows away from the leaf's spine toward its lit edge.
    static let ribBow: CGFloat = 0.34

    // MARK: Motion

    /// Ambient sway. Slow enough to be weather rather than animation — a plant
    /// in a room with a window, not a plant in a cartoon.
    static let swaySpeed: Double = 0.55
    static let swayRadians: Double = 0.018

    // MARK: Habit

    /// How a species carries itself. The palette is Grove's only species-level
    /// signal, so it is what growth habit is derived from — which has the happy
    /// effect of making the habit and the colour agree by construction.
    struct Habit {
        /// How far up the frame the plant reaches, as a fraction of its height.
        var reach: CGFloat
        /// How far the stem bows out on its way up. 0 is a ramrod.
        var arch: CGFloat
        /// Leaves on a plant at full vitality.
        var leafCount: Int
        /// Leaf breadth as a fraction of leaf length.
        var width: CGFloat
        /// Leaf length as a fraction of stem length, at the plant's fullest point.
        var length: CGFloat
        /// How far above horizontal a leaf is held at full vitality, in radians.
        var lift: Double
    }

    static func habit(for palette: PlantPalette) -> Habit {
        switch palette {
        // Many fine fronds held high and close.
        case .fern: Habit(reach: 0.80, arch: 0.10, leafCount: 14, width: 0.26, length: 0.42, lift: 0.62)
        // Few broad round leaves on a short stem.
        case .lime: Habit(reach: 0.68, arch: 0.16, leafCount: 6, width: 0.78, length: 0.52, lift: 0.28)
        // Upright, narrow, architectural.
        case .sage: Habit(reach: 0.88, arch: 0.06, leafCount: 9, width: 0.32, length: 0.40, lift: 0.86)
        // Arching and trailing — this one hangs on purpose, not from neglect.
        case .sunset: Habit(reach: 0.62, arch: 0.42, leafCount: 7, width: 0.46, length: 0.58, lift: -0.22)
        // Low, dense and clustered.
        case .moss: Habit(reach: 0.48, arch: 0.14, leafCount: 12, width: 0.60, length: 0.44, lift: 0.34)
        // Collection-only colourways (see `allBotanicalCases`). No plant is ever
        // drawn in these, but the switch still owes an answer; the sage habit is
        // the neutral one to give it.
        case .bloom, .lavender, .rain, .honey, .bark:
            Habit(reach: 0.88, arch: 0.06, leafCount: 9, width: 0.32, length: 0.40, lift: 0.86)
        }
    }

    // MARK: Plan

    struct Leaf {
        /// 0…1 up the stem.
        var position: CGFloat
        var angle: Double
        var length: CGFloat
        var width: CGFloat
        var lit: Bool
        /// How strongly this leaf takes the light — the ones nearer the top and
        /// the front catch more of it.
        var exposure: Double
    }

    struct Plan {
        var lean: CGFloat
        var reach: CGFloat
        var arch: CGFloat
        var vitality: Double
        var leaves: [Leaf]
    }

    /// Turns a plant into a drawing.
    ///
    /// Health enters in three places at once, because one signal read three ways
    /// is what makes a wilting plant look wilted rather than recoloured: a
    /// struggling plant reaches less far, carries fewer leaves, and lets the
    /// ones it has fall toward the ground.
    static func plan(for palette: PlantPalette, vitality: Double, rng: inout SeededGenerator) -> Plan {
        let habit = habit(for: palette)
        let health = min(max(vitality, 0), 1)
        let droop = (1 - health) * .pi * 0.42

        let count = max(3, Int((Double(habit.leafCount) * (0.55 + 0.45 * health)).rounded()))
        let lean = CGFloat(rng.range(-1, 1))

        var leaves: [Leaf] = []
        for index in 0..<count {
            let t = CGFloat(index + 1) / CGFloat(count + 1)
            let lit = index.isMultiple(of: 2)
            // Alternating sides, mirrored around straight up (-π/2).
            let side: Double = lit ? 1 : -1
            let spread = habit.lift * (0.45 + 0.55 * health)
            let angle = -.pi / 2 + side * (.pi / 2 - spread) + side * droop * 0.7 + rng.range(-0.10, 0.10)

            // Leaves taper toward the growing tip, which is what stops the
            // silhouette reading as a diagram of a plant.
            let taper = 1 - pow(Double(t), 1.6) * 0.45
            leaves.append(
                Leaf(
                    position: t,
                    angle: angle,
                    length: habit.length * CGFloat(taper) * CGFloat(rng.range(0.86, 1.12)),
                    width: habit.width * CGFloat(rng.range(0.9, 1.1)),
                    lit: lit,
                    exposure: 0.55 + 0.45 * Double(t)
                )
            )
        }

        return Plan(
            lean: lean,
            reach: habit.reach * CGFloat(0.72 + 0.28 * health),
            arch: habit.arch + CGFloat((1 - health) * 0.12),
            vitality: health,
            leaves: leaves
        )
    }

    // MARK: Optical sizing

    /// Thins the crown for small frames.
    ///
    /// A fourteen-frond fern is a fern at 220 pt and a smudge at 30 pt, where
    /// the drawing appears as a row thumbnail. Dropping leaves — rather than
    /// scaling the whole plant down — keeps the silhouette readable at every
    /// size the app draws it, which is the illustration equivalent of an
    /// optical size.
    static func leaves(_ leaves: [Leaf], fitting size: CGSize) -> [Leaf] {
        let budget: Int
        switch size.height {
        // The avatar ring keeps a fuller crown than its size suggests: with
        // three leaves it read as a bare stem.
        case ..<tinyFrameHeight: budget = 6
        case 48..<80: budget = 5
        case 80..<140: budget = 8
        default: return leaves
        }
        guard leaves.count > budget else { return leaves }
        // Keep an even spread up the stem rather than the first N, so a thinned
        // plant is still a whole plant and not a bare tip.
        let stride = Double(leaves.count - 1) / Double(budget - 1)
        return (0..<budget).map { leaves[Int((Double($0) * stride).rounded())] }
    }

    // MARK: Seed

    /// A stable seed from a plant's identity.
    ///
    /// Deliberately not `hashValue`: Swift seeds its hasher per process, so a
    /// plant drawn from `id.hashValue` would quietly become a different plant on
    /// every launch. FNV-1a over the UUID's own bytes does not move.
    static func seed(from id: UUID) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01B3
            }
        }
        return hash
    }
}

/// A tiny xorshift generator. `SystemRandomNumberGenerator` would give a plant a
/// new shape every time its cell scrolled back into view; this gives the same
/// shape every time from the same seed.
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func unit() -> Double {
        Double(next() % 100_000) / 100_000
    }

    mutating func range(_ lower: Double, _ upper: Double) -> Double {
        lower + (upper - lower) * unit()
    }
}

#Preview("Portraits") {
    let bands: [HealthBand] = [.thriving, .healthy, .monitor, .attention, .urgent]
    return ScrollView {
        VStack(spacing: 16) {
            ForEach(PlantPalette.allBotanicalCases, id: \.self) { palette in
                HStack(spacing: 8) {
                    ForEach(bands, id: \.self) { band in
                        PlantPortrait(
                            seed: UInt64(abs(palette.rawValue.count &* 7717 &+ band.rawValue.count &* 104_729)),
                            palette: palette,
                            vitality: band.vitality
                        )
                        .frame(height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
                    }
                }
            }
        }
        .padding()
    }
    .groveBackground()
}

extension PlantPalette {
    /// Every palette, for previews and pickers.
    static var allBotanicalCases: [PlantPalette] { [.fern, .lime, .sage, .sunset, .moss] }
}
