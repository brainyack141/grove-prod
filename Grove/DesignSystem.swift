import SwiftUI
import UIKit

/// Grove's visual language. An editorial system on a cool bone canvas: white
/// cards, deep forest ink, quiet sage signals, living green pill
/// call-to-actions, and soft rounded cards. Light and dark are both
/// first-class; the light appearance is the hero.
///
/// The ground was warm parchment until it wasn't — see `background` for what
/// that cost and what replacing it gave up. The warmth did not leave the
/// product, only the page: it is still in the icon, the illustrations and the
/// Journey artwork, where it is a colour someone chose rather than a tint
/// applied to everything at once.
enum GroveTheme {

    // MARK: - Adaptive color helper

    /// Builds a `Color` that resolves differently in light and dark appearances.
    static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    /// A colour that stays put in both appearances. Reserved for surfaces that
    /// set their own lighting — a full-bleed hero scene has to know exactly how
    /// dark it is for the type on top of it to be legible.
    static func fixed(_ hex: UInt) -> Color {
        Color(uiColor: UIColor(hex: hex))
    }

    // MARK: - Canvas & surfaces

    /// The canvas: cool bone, the light inside a greenhouse.
    ///
    /// This was #F4EDDF for most of Grove's life — a warm parchment lifted
    /// straight from the app icon, and genuinely ours. It was also 92%
    /// lightness at ~49% HSL saturation, which is dark and *chromatic* for a
    /// ground, and it cost more than it returned: every white card had to fight
    /// 6.4 points of lightness to look raised, photographs of green leaves sat
    /// on a yellow field that pulled them olive, and the whole app read a little
    /// dim next to anything else on the phone.
    ///
    /// Bone keeps a ground that is not white — the page is still a surface, not
    /// an absence — while giving that ground almost no hue of its own. What it
    /// gives up is the icon's warmth. That was a real thing to lose, and it is
    /// lost knowingly: the parchment survives where it was always doing work,
    /// in the icon, the illustrations and the Journey artwork, rather than
    /// underneath every screen at once.
    ///
    /// Lightened again — from bone to paper — when the page stopped being a
    /// tray of floating cards. Bone at 95% lightness existed to make white
    /// cards read as *raised*; once the shadows came off (see
    /// `GroveCardModifier`) that 6-point gap stopped buying elevation and
    /// started buying stripes, because a flat white block on a visibly darker
    /// ground is a rectangle rather than a card. At 98% the ground and the
    /// content share one paper, and grouping falls to the hairline and the
    /// section heading, which is where it belongs.
    static let background = adaptive(light: 0xFAFBF8, dark: 0x14130F)
    /// Card / raised surface. Plain white now — against bone it needs no warmth
    /// of its own to separate, and a warm white on a cool ground reads as two
    /// different papers rather than as a card on a page.
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x201E18)
    /// A step below the canvas, for insets, tiles, and quiet fills.
    static let secondarySurface = adaptive(light: 0xE8ECE7, dark: 0x2A2820)

    // MARK: - Ink (text)

    /// Primary text — a forest near-black that avoids the harshness of pure #000.
    static let ink = adaptive(light: 0x1C261C, dark: 0xF4F2EC)
    /// Secondary text.
    static let mutedInk = adaptive(light: 0x5F685D, dark: 0xA6A296)
    /// Tertiary / hint text.
    ///
    /// Darkened from #898E84, which measured 3.35:1 on `surface` — under AA,
    /// and it carried the app's uncertainty copy: the condition confidence line,
    /// the drivers caveat, the care-guide disclaimer and the chart axes. The
    /// principle is that uncertainty must stay visible; for a low-vision reader
    /// it was the least visible text on the page.
    static let subtleInk = adaptive(light: 0x6B7067, dark: 0x9A968A)

    // MARK: - Accent (icon sage)

    /// The app icon's living sage. Used for signals, dots, checks, and small
    /// marks; its restrained chroma lets plant photography stay in the lead.
    static let accent = adaptive(light: 0x4F7650, dark: 0x76B47B)
    /// A deeper green for green-on-cream text where more contrast is needed.
    static let accentStrong = adaptive(light: 0x31593A, dark: 0x95CA98)

    /// The two greens again, but sorted by *brightness* rather than by role.
    ///
    /// `accentStrong` means "the one with more contrast against the canvas",
    /// which is the darker green on cream and the lighter green on near-black —
    /// so a gradient written `[accent, accentStrong]` runs light-to-dark in one
    /// appearance and dark-to-light in the other, and every green disc in the
    /// app quietly relit itself from below after dark. These two are ordered by
    /// luminance in both appearances, so `accentGradient` can keep the highlight
    /// where the rest of the app's light comes from.
    static let accentLit = adaptive(light: 0x5F855F, dark: 0x95CA98)
    static let accentShade = adaptive(light: 0x31593A, dark: 0x76B47B)

    /// A green fill lit from the same place as everything else in Grove.
    static func accentGradient(
        startPoint: UnitPoint = .topLeading,
        endPoint: UnitPoint = .bottomTrailing
    ) -> LinearGradient {
        LinearGradient(
            colors: [accentLit, accentShade],
            startPoint: startPoint,
            endPoint: endPoint
        )
    }
    /// Very soft green wash for tile backgrounds and selected states.
    static let softAccent = adaptive(light: 0xE1E8DD, dark: 0x1E2A16)

    // MARK: - Lines & signals

    /// Cooled to travel with the ground. A warm #DED6C9 hairline was invisible
    /// on parchment and obvious on bone — it was the one line in the app that
    /// would have announced the canvas had changed underneath it.
    static let separator = adaptive(light: 0xDDE3DC, dark: 0x322F28)
    /// Amber. Darkened for light mode: at its old value it measured 3.3:1 on the
    /// cream canvas, and it is set as `.caption` text in half the places it
    /// appears ("Today" on a due row, the free-question count).
    static let warning = adaptive(light: 0x996410, dark: 0xE0A94C)
    static let danger = adaptive(light: 0xC0392B, dark: 0xE8695A)
    static let purple = adaptive(light: 0x5C35AE, dark: 0xB49BEE)
    /// Water's colour: soil moisture, watering, hydration. The one blue in a
    /// palette that is otherwise green, amber and ink.
    static let hydration = adaptive(light: 0x2F6FB5, dark: 0x6FA8E0)

    // MARK: - Celebration & progression

    /// The single celebration gold: crowns, reward pucks, the journey's gold
    /// road, XP sparks. Never used for warnings — that's `warning`'s job.
    static let gold = adaptive(light: 0xF0BC33, dark: 0xE6B02E)
    /// Deep gold partner for gradients, filled bars, and gold-on-material
    /// contexts where `gold` alone would wash out.
    ///
    /// Darkened from #D98F1F, which measured 2.66:1 set as text and carried the
    /// sky strip's one number on a light surface.
    static let goldDeep = adaptive(light: 0x8A5A0C, dark: 0xE6B02E)
    /// The streak flame. Warmer than `gold`, hotter than `warning`; every
    /// flame in the app burns this colour.
    static let streak = adaptive(light: 0xE8720C, dark: 0xF08A2E)
    /// The flame's outer edge — the one colour in the palette hotter than
    /// `streak`, and only ever the deep stop of a flame gradient.
    ///
    /// Fixed rather than adaptive, like `inkOnLight`: the flame is drawn
    /// artwork that lights itself, so its gradient has to hold its shape in
    /// both appearances instead of being re-lit by the canvas behind it.
    static let ember = fixed(0xB63A05)
    /// Scorched ink, for the run length set inside the flame's gold heart.
    /// Fixed for the same reason `ember` is: adaptive ink would turn cream on
    /// a gold ground after dark and the numeral would vanish.
    static let emberInk = fixed(0x3B1503)

    // MARK: - Health bands

    /// The health-band signal colours. Two are defined here; `monitor` and
    /// `urgent` reuse `warning`/`danger` so "needs me" always speaks with one
    /// voice, which is why this is three constants for a five-step scale.
    ///
    /// The two greens used to be #0C6F32 and #1A672D — a CIEDE2000 difference of
    /// **2.8**, which is to say the same colour. The top two rungs of the scale
    /// were doing no work, and in the two places the band is the *only* signal
    /// (the Living Record's timeline gradient, the dot on a friend's plant) a
    /// plant sliding from thriving to healthy was invisible. They are now split
    /// along hue rather than lightness — a jewel emerald against a grass green —
    /// so both keep 4.5:1 on the canvas while reading as two distinct states.
    /// Every adjacent pair in the scale now clears ΔE 13.
    static let healthThriving = adaptive(light: 0x057D4E, dark: 0x3CD79A)
    static let healthHealthy = adaptive(light: 0x4E7016, dark: 0x96BC68)
    static let healthAttention = adaptive(light: 0x983E00, dark: 0xE0873D)

    // MARK: - On-photo signals

    /// Score-change colours legible over user photos and dark scrims, where
    /// the on-canvas greens and ambers would vanish.
    /// Late work over a photograph.
    ///
    /// `warning` is a deep amber tuned for 4.5:1 on the cream canvas, and it
    /// disappears into a night-lit hero. This is the same caution lit for a dark
    /// ground — the dark-appearance twin, held fixed, because the hero is dark in
    /// both appearances. It carries `inkOnLight`, never white: white on this
    /// amber measures 1.9:1.
    static let warningOnPhoto = fixed(0xE0A94C)
    static let onPhotoImproving = Color(red: 0.62, green: 0.90, blue: 0.45)
    static let onPhotoDeclining = Color(red: 0.98, green: 0.75, blue: 0.45)

    // MARK: - Atmosphere (time-of-day tints)

    /// The Today hero's window tints: a cool blue ramp into morning, a quiet
    /// green middle of the day, then amber and violet into night. Blend-mode
    /// overlays, never used as UI chrome.
    static let midnightTint = Color(red: 0.11, green: 0.17, blue: 0.35)
    static let preDawnTint = Color(red: 0.28, green: 0.34, blue: 0.70)
    static let dawnTint = Color(red: 1.00, green: 0.68, blue: 0.36)
    static let morningTint = Color(red: 1.00, green: 0.76, blue: 0.42)
    static let afternoonTint = Color(red: 0.95, green: 0.77, blue: 0.36)
    static let goldenHourTint = Color(red: 1.00, green: 0.48, blue: 0.18)
    static let duskTint = Color(red: 0.52, green: 0.42, blue: 0.88)
    static let nightTint = Color(red: 0.16, green: 0.22, blue: 0.52)

    /// Night, restated light enough to survive an overlay blend.
    ///
    /// `nightTint` is a deep navy, which is right over a photograph — there is
    /// dark in the image for it to sit in. The canvas has none. Overlay keeps
    /// the base's luminosity and pushes its chroma, so a dark tint over a light
    /// ground has nowhere useful to go: on bone it drags #F1F3F0 to #ECF0F0,
    /// which is not evening, it is the screen looking dirty. This is the same
    /// blue held at the canvas's own lightness, so it reads as air rather than
    /// as a dimmer switch. Dawn and dusk need no such twin — both are already
    /// light enough to tint upward.
    static let nightCanvasTint = Color(red: 0.45, green: 0.58, blue: 0.95)
    static let preDawnCanvasTint = Color(red: 0.43, green: 0.52, blue: 0.90)

    /// The canvas's own light — the bloom in the upper-right corner the rest of
    /// the app is lit from.
    ///
    /// It cannot be white. `overlay` holds the base's luminosity and pushes its
    /// chroma, and the ground is already 98% white, so a white light has no
    /// room to lift: it would spend a whole gradient and change nothing. The
    /// light therefore arrives as *warmth* — the paper's own cast turned up —
    /// which is the one thing a near-white ground can still be given.
    static let canvasLight = adaptive(light: 0xFFF3DC, dark: 0xFFE9C4)

    /// What the ground falls to at the bottom of a page: the horizon that gives
    /// the canvas near and far without a card having to draw an edge to say so.
    ///
    /// Warm rather than black. A neutral shadow on this paper is a desaturation
    /// — the bottom of every screen would drift grey while the top stayed cream,
    /// which is the exact fault the hour wash spent three revisions escaping.
    /// Dark mode goes to true black, where depth is the only thing that reads.
    static let canvasDepth = adaptive(light: 0x6B5F49, dark: 0x000000)

    /// Deep forest used for compact selected controls and contrast tokens.
    /// Primary action pills use `accentGradient()` instead.
    static let onCanvasButton = adaptive(light: 0x233F2B, dark: 0xF4F2EC)
    static let onCanvasButtonLabel = adaptive(light: 0xFFFCF5, dark: 0x14130F)

    /// Ink for content on a fixed-white surface — share cards and chips on
    /// photos. Deliberately *not* adaptive: the camera and photo-review screens
    /// force the dark appearance, where `ink` flips to cream and would disappear
    /// against white.
    static let inkOnLight = Color(uiColor: UIColor(hex: 0x1C261C))

    // MARK: - The rooms map (Today's board)

    /// Today opens on a map of the home, the way a departures board opens on
    /// the world: night-green ground, hairline rooms, one lit dot per plant.
    /// Fixed in both appearances because the map sets its own lighting.
    static let mapGround = fixed(0x0C1510)
    static let mapRoom = fixed(0x2A3D2F)
    static let mapLabel = fixed(0x7F9884)
    static let mapCode = fixed(0xC9D6CC)
    static let mapCaption = fixed(0x9DB3A2)
    /// Status on the map. Brighter than the paper versions, which are tuned
    /// for contrast on white and go muddy on night green.
    static let mapThriving = fixed(0x34C27A)
    static let mapDue = fixed(0xF0A81C)
    static let mapTrouble = fixed(0xF0574B)

    /// Content sitting *on* an `accent` fill — the glyph in a green disc, the
    /// label in a green capsule.
    ///
    /// This has to flip with the appearance because `accent` itself does. Light
    /// mode's sage carries warm white comfortably; dark mode lifts it to a
    /// brighter green where pale glyphs lose definition. Every green disc in the
    /// app therefore resolves its content colour alongside the surface.
    static let onAccent = adaptive(light: 0xFFFCF5, dark: 0x14130F)

    /// The ambient shadow: the soft, wide one that says a surface is somewhere
    /// above the page.
    static let shadow = Color(uiColor: UIColor { traits in
        UIColor.black.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.28 : 0.06)
    })

    /// The contact shadow: tight, dark and directly under the surface.
    ///
    /// A single soft shadow is what a card looks like in a diagram of a card.
    /// Real objects cast two — a hard one where they nearly touch the ground and
    /// a diffuse one further out — and having both is most of the difference
    /// between a surface that is floating and one that has simply been drawn a
    /// bit lighter than its background.
    static let contactShadow = Color(uiColor: UIColor { traits in
        UIColor.black.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.34 : 0.055)
    })

    /// The light that catches the top edge of a raised surface.
    ///
    /// Grove's cards were outlined in one flat `separator` all the way round,
    /// which is the outline of a shape rather than the edge of an object. Light
    /// in this app comes from above — the plant portraits are all lit from the
    /// upper right — so the top of a card should be brighter than its bottom.
    static let edgeLight = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.12)
            : UIColor.white.withAlphaComponent(0.90)
    })

    // MARK: - Geometry

    /// The four corner radii. Nothing in the app should invent a fifth:
    /// compact (chips, small fields) → inset (tiles and rows nested inside
    /// cards) → card → hero.
    static let compactRadius: CGFloat = 12
    static let insetRadius: CGFloat = 16
    static let cardRadius: CGFloat = 22
    static let heroRadius: CGFloat = 28
    static let pillRadius: CGFloat = 999
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 28
    /// Scroll pages breathe the same way everywhere: this much air above the
    /// first element and below the last (pages with a pinned bottom action bar
    /// keep their own tighter bottom inset).
    static let pageTopPadding: CGFloat = 8
    static let pageBottomPadding: CGFloat = 40

    // MARK: - Display type

    /// Grove's display voice: SF Pro Rounded, paired with standard SF Pro for
    /// interface and reading text.
    ///
    /// Rounded is reserved for branded headings. It gives Grove the clean,
    /// friendly, highly legible hierarchy used by the best data-dense native
    /// apps without making controls or care guidance feel soft or decorative.
    ///
    /// The system face brings optical sizing and complete language coverage.
    /// `UIFontMetrics` keeps display type responsive to Dynamic Type, with a cap
    /// so a hero heading still fits its card at the largest accessibility sizes.
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        // One voice: the same SF Pro the rest of the interface reads in.
        // Rounded was a second personality the board screens never spoke,
        // so every heading set in it marked a screen as from another app.
        let face = UIFont.systemFont(ofSize: size, weight: uiWeight(weight))

        return Font(
            UIFontMetrics(forTextStyle: .largeTitle)
                .scaledFont(for: face, maximumPointSize: size * 1.4)
        )
    }

    private static func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

private extension UIColor {
    convenience init(hex: UInt) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Motion

/// Grove's motion vocabulary. Interface animation picks from these springs so
/// the whole app moves with one physicality.
///
/// The values live on `Token` so a `GROVE_DIALS` build can tune them live on
/// the phone (shake to open; see GroveMotionDials.swift). Every other build
/// returns exactly the shipped spring.
enum GroveMotion {
    enum Token: String, CaseIterable, Sendable {
        case press, snap, settle, reveal, celebrate, drift, pop

        var shipped: (response: Double, dampingFraction: Double) {
            switch self {
            case .press: (0.28, 0.7)
            case .snap: (0.34, 0.82)
            case .settle: (0.45, 0.85)
            case .reveal: (0.55, 0.85)
            case .celebrate: (0.55, 0.7)
            case .drift: (0.9, 0.9)
            case .pop: (0.34, 0.55)
            }
        }
    }

    /// Touch feedback on buttons and pressable cards.
    static var press: Animation { animation(.press) }
    /// Selection changes: tabs, filters, chips, steppers.
    static var snap: Animation { animation(.snap) }
    /// Content settling into place: expanding sections, inserted rows.
    static var settle: Animation { animation(.settle) }
    /// Big reveals: results appearing, celebration cards.
    static var reveal: Animation { animation(.reveal) }
    /// Celebratory pops — deliberately bouncier than everything else.
    static var celebrate: Animation { animation(.celebrate) }
    /// The slowest step: atmosphere, ambient drift, a hero settling behind
    /// content. Nothing the user is waiting on should use it.
    static var drift: Animation { animation(.drift) }
    /// A single overshooting pop for a mark that lands — a tick, a badge, a
    /// number that just changed. Bouncier than `celebrate` and much shorter,
    /// because it decorates one element rather than a whole screen.
    static var pop: Animation { animation(.pop) }

    static func animation(_ token: Token) -> Animation {
        #if GROVE_DIALS
        if let tuned = GroveMotionDials.tuned(token) { return tuned }
        #endif
        let spring = token.shipped
        return .spring(response: spring.response, dampingFraction: spring.dampingFraction)
    }
}

// MARK: - Elevation

/// Grove's three shadow levels. Every drop shadow on the canvas is one of
/// these; decorative glows (celebration gold, on-photo scrims) are the only
/// exceptions.
enum GroveElevation {
    /// Cards resting in grids and rows.
    case resting
    /// Prominent standalone cards — the `groveCard` default.
    case floating
    /// Hero surfaces at the top of a page.
    case hero

    var radius: CGFloat {
        switch self {
        case .resting: 5
        case .floating: 14
        case .hero: 18
        }
    }

    var y: CGFloat {
        switch self {
        case .resting: 2
        case .floating: 6
        case .hero: 10
        }
    }

    /// The tight shadow directly beneath the surface.
    var contactRadius: CGFloat {
        switch self {
        case .resting: 1
        case .floating: 2
        case .hero: 3
        }
    }

    var contactY: CGFloat {
        switch self {
        case .resting: 1
        case .floating: 1
        case .hero: 2
        }
    }
}

extension View {
    /// Grove's elevation: a contact shadow under an ambient one. Still three
    /// levels and still one spelling — there are now two shadows inside each
    /// level rather than two ways to write a shadow.
    func groveShadow(_ level: GroveElevation = .floating) -> some View {
        shadow(color: GroveTheme.contactShadow, radius: level.contactRadius, y: level.contactY)
            .shadow(color: GroveTheme.shadow, radius: level.radius, y: level.y)
    }

    /// The lit top edge of a raised surface, for anything that isn't already
    /// using `groveCard()`.
    func groveEdgeLight(radius: CGFloat = GroveTheme.cardRadius) -> some View {
        overlay {
            // One card edge in the whole app: the same flat hairline
            // `groveCard()` draws. A lit edge on some cards and a plain one on
            // others made two kinds of object out of one.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(GroveTheme.separator, lineWidth: 1)
        }
    }
}

// MARK: - Domain presentation

// Colour belongs to the design system, not the data model: these extensions
// keep `DomainModels` presentation-free while every screen resolves the same
// band, trend, and palette colours.

extension HealthBand {
    var color: Color {
        switch self {
        case .thriving: GroveTheme.healthThriving
        case .healthy: GroveTheme.healthHealthy
        case .monitor: GroveTheme.warning
        case .attention: GroveTheme.healthAttention
        case .urgent: GroveTheme.danger
        }
    }

    /// The band over a photograph or a dark scrim, where the on-canvas colours
    /// stop working: `healthHealthy` is a #4E7016 olive picked for 4.5:1 on
    /// bone, and on a scrim it is a dark smudge. These are the dark-appearance
    /// twins, held fixed rather than adaptive — the scrim is black in both
    /// appearances, so the dot must not flip with the system.
    var onPhotoColor: Color {
        switch self {
        case .thriving: Color(uiColor: UIColor(hex: 0x3CD79A))
        case .healthy: Color(uiColor: UIColor(hex: 0x96BC68))
        case .monitor: Color(uiColor: UIColor(hex: 0xE0A94C))
        case .attention: Color(uiColor: UIColor(hex: 0xE0873D))
        case .urgent: Color(uiColor: UIColor(hex: 0xE8695A))
        }
    }
}

extension HealthTrend {
    var color: Color {
        switch self {
        case .improving: GroveTheme.accent
        case .stable, .baseline: GroveTheme.mutedInk
        case .declining: GroveTheme.warning
        }
    }

    /// The trend over a photograph, on the same rule as `HealthBand.onPhotoColor`:
    /// `mutedInk` is a grey-green picked to sit quietly on bone, and on a dark
    /// scrim it reads as a smudge rather than as "holding steady".
    var onPhotoColor: Color {
        switch self {
        case .improving: GroveTheme.onPhotoImproving
        case .stable, .baseline: Color.white.opacity(0.7)
        case .declining: GroveTheme.onPhotoDeclining
        }
    }
}

extension PlantPalette {
    /// Artwork gradient for plants, collections, and badges. Slightly lifted
    /// in dark mode so the gradients keep their depth on the near-black canvas.
    var colors: [Color] {
        switch self {
        case .fern: [
            GroveTheme.adaptive(light: 0x094020, dark: 0x0E5230),
            GroveTheme.adaptive(light: 0x1A6E34, dark: 0x268A47)
        ]
        case .lime: [
            GroveTheme.adaptive(light: 0x305A12, dark: 0x3E721A),
            GroveTheme.adaptive(light: 0x49771A, dark: 0x5C9426)
        ]
        case .sage: [
            GroveTheme.adaptive(light: 0x2E4F3F, dark: 0x3A644F),
            GroveTheme.adaptive(light: 0x527658, dark: 0x679270)
        ]
        case .sunset: [
            GroveTheme.adaptive(light: 0x62271A, dark: 0x7A3320),
            GroveTheme.adaptive(light: 0x9E491B, dark: 0xBA5A24)
        ]
        case .moss: [
            GroveTheme.adaptive(light: 0x203811, dark: 0x2A4A17),
            GroveTheme.adaptive(light: 0x445E1E, dark: 0x577828)
        ]
        // The five below are collection-only. They sit at the same depth and
        // muted saturation as the botanical five deliberately: a collection
        // cover in a clean 100%-saturation pink would read as a different app's
        // component sitting inside Grove.
        case .bloom: [
            GroveTheme.adaptive(light: 0x611F33, dark: 0x7B2942),
            GroveTheme.adaptive(light: 0x9C4159, dark: 0xB85870)
        ]
        case .lavender: [
            GroveTheme.adaptive(light: 0x372C52, dark: 0x483A6B),
            GroveTheme.adaptive(light: 0x5D4C85, dark: 0x76639F)
        ]
        case .rain: [
            GroveTheme.adaptive(light: 0x1B3A4E, dark: 0x244C66),
            GroveTheme.adaptive(light: 0x336080, dark: 0x437C9F)
        ]
        case .honey: [
            GroveTheme.adaptive(light: 0x67400F, dark: 0x7E521D),
            GroveTheme.adaptive(light: 0xA26D1B, dark: 0xBE8628)
        ]
        case .bark: [
            GroveTheme.adaptive(light: 0x38281C, dark: 0x483424),
            GroveTheme.adaptive(light: 0x64472F, dark: 0x7C5A3E)
        ]
        }
    }

    /// Display name for pickers and VoiceOver.
    var label: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

// MARK: - Backgrounds & cards

// `GroveBackground` — the page ground — lives in `GroveAtmosphere.swift`, with
// the time-of-day model it now carries.

/// A content group on the page — **not** a floating object.
///
/// This used to be `surface` + `groveEdgeLight` + `.floating`, and the cost of
/// that was only visible once you looked at a whole screen instead of one
/// component. Today ran four blocks down the fold — the hero, the all-clear
/// row, the camera row, the week — and every one of them was the same width,
/// the same 22pt radius, the same white, and the same 14pt shadow at the same
/// 28pt interval. Nothing on the page was larger, quieter, or nearer than
/// anything else, so the eye had no route through it: a tray of equal bricks,
/// which is what a dashboard looks like and not what a home screen looks like.
///
/// Elevation is a *scarce* signal. It now means "this object is in front of the
/// page" — sheets, toasts, the scan button, the Today hero — and those call
/// `groveShadow` themselves. Everything else is content lying on the paper,
/// grouped by a hairline and a heading. The shape and the padding are unchanged,
/// so no screen re-lays-out; they simply stop shouting in unison.
struct GroveCardModifier: ViewModifier {
    let padding: CGFloat
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(GroveTheme.separator, lineWidth: 1)
            }
    }
}

/// `groveCard()` for views that are sometimes standalone and sometimes nested
/// inside another card. Two sets of card chrome around one piece of content
/// reads as a bug, so the inner one has to be able to stand down.
struct GroveConditionalCard: ViewModifier {
    let enabled: Bool
    var padding: CGFloat = 18
    var radius: CGFloat = GroveTheme.cardRadius

    func body(content: Content) -> some View {
        if enabled {
            content.modifier(GroveCardModifier(padding: padding, radius: radius))
        } else {
            content
        }
    }
}

struct GroveGroupedContent: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(GroveTheme.background)
            .tint(GroveTheme.accent)
    }
}

/// Root tabs sit directly on the canvas. They used to open with a raised
/// white sheet under a fixed 302pt header plane — a shape three of the four
/// tabs drew and Today did not, at three different heights, on top of a paper
/// that was already 98% white. The sheet was the single loudest reason the
/// tabs read as four apps: it moved the first line of type by up to 80pt from
/// one tab to the next and put a second white under the white cards. Every
/// root now starts at `pageTopPadding` like every other scroll page.
extension View {
    /// Grove's page ground. `paper` is the fill the hour, the light and the
    /// depth ramp are all spent on; it defaults to the shared bone, and Today
    /// passes its own warmer editorial paper rather than being re-hued.
    func groveBackground(paper: Color = GroveTheme.background) -> some View {
        modifier(GroveBackground(paper: paper))
    }

    func groveCard(padding: CGFloat = 18, radius: CGFloat = GroveTheme.cardRadius) -> some View {
        modifier(GroveCardModifier(padding: padding, radius: radius))
    }

    func groveGroupedContent() -> some View {
        modifier(GroveGroupedContent())
    }

    func groveCard(if enabled: Bool, padding: CGFloat = 18, radius: CGFloat = GroveTheme.cardRadius) -> some View {
        modifier(GroveConditionalCard(enabled: enabled, padding: padding, radius: radius))
    }

    func groveHeroShape() -> some View {
        clipShape(RoundedRectangle(cornerRadius: GroveTheme.heroRadius, style: .continuous))
    }
}

// MARK: - Display heading

/// The five sizes of Grove's display voice. Every editorial heading picks a
/// step from this scale — never an ad-hoc point size — so any two headings in
/// the app automatically rhyme.
enum GroveDisplayStyle {
    /// Tab-root identities and full-bleed heroes ("Hey, Alex.", "Learn.").
    case hero
    /// Page and sheet headers ("Invite a friend", a scan result's name).
    case title
    /// Overlay moments and banner titles inside large imagery.
    case heading
    /// Section headings within a page, and card-hero titles.
    case section
    /// Titles inside cards and tiles.
    case card

    /// The scale keeps a clear jump between page identity, section hierarchy,
    /// and compact card titles while preserving comfortable line lengths.
    var points: CGFloat {
        switch self {
        case .hero: 34
        case .title: 30
        case .heading: 26
        case .section: 20
        case .card: 17
        }
    }
}

/// A prominent heading in Grove's rounded display voice ("Hey, Alex.").
///
/// Set in title case: the sentence is the design. The small-caps voice remains
/// reserved for `GroveEyebrow`, keeping hierarchy without turning headings into
/// labels.
struct GroveDisplayHeading: View {
    let text: String
    var size: CGFloat
    var color: Color

    init(text: String, style: GroveDisplayStyle = .title, color: Color = GroveTheme.ink) {
        self.text = text
        self.size = style.points
        self.color = color
    }

    /// Escape hatch for measured one-offs (e.g. type that must fit a fixed
    /// artwork). New screens use `style:`.
    init(text: String, size: CGFloat, color: Color = GroveTheme.ink) {
        self.text = text
        self.size = size
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(GroveTheme.display(size, weight: size <= 20 ? .semibold : .bold))
            .tracking(size >= 26 ? -0.4 : 0)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The small tracked-caps label above sections and headings.
///
/// This is the app's *only* uppercase voice. Keeping that emphasis here lets
/// rounded headlines stay in title case without the page losing structure.
struct GroveEyebrow: View {
    let text: String
    var color: Color = GroveTheme.mutedInk

    var body: some View {
        // The same small caps as a board stat label, so a label reads the
        // same whether it sits over a number or over a card.
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(color)
    }
}

// MARK: - Primary actions

/// How much room a branded button takes. Regular actions fill their container;
/// compact actions hug their label when they share a row with another control.
enum GroveButtonSize {
    case regular
    case compact

    var horizontalPadding: CGFloat {
        switch self {
        case .regular: 22
        case .compact: 16
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .regular: 15
        case .compact: 9
        }
    }

    var fillsWidth: Bool { self == .regular }

    var minimumHeight: CGFloat {
        switch self {
        case .regular: 56
        case .compact: 44
        }
    }
}

/// The shared chrome for Grove's branded actions. The reference treatment is
/// the living green `Add to grove` capsule: a centred icon-and-title lockup,
/// warm-white content, and a left-to-right leaf gradient.
private struct GrovePrimaryPillModifier: ViewModifier {
    let size: GroveButtonSize

    func body(content: Content) -> some View {
        content
            .font(.headline.weight(.semibold))
            .foregroundStyle(GroveTheme.background)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .frame(
                maxWidth: size.fillsWidth ? CGFloat.infinity : nil,
                minHeight: size.minimumHeight
            )
            // Ink, like every primary action on the board screens. Green is
            // the colour of a plant doing well; a button is not a plant.
            .background(GroveTheme.ink, in: Capsule())
            .contentShape(Capsule())
    }
}

extension View {
    /// The one surface Ari speaks from: night green, the map's ground, with
    /// the content inside resolved in the dark appearance. Anywhere Ari has a
    /// read, a question or an answer card, it sits on this, so the botanist
    /// looks like the same person on every screen.
    func groveAriSurface() -> some View {
        self
            .background(GroveTheme.mapGround, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func grovePrimaryPill(size: GroveButtonSize = .regular) -> some View {
        modifier(GrovePrimaryPillModifier(size: size))
    }
}

/// The label body of Grove's signature CTA. Every primary action uses the same
/// centred green capsule; the symbol explains the action without changing the
/// button's hierarchy or geometry.
struct GroveCTALabel: View {
    let title: String
    var systemImage: String = "arrow.right"
    /// Over a dark or photographic ground the pill resolves in the dark
    /// appearance, where ink is the light capsule. Without this the signed-in
    /// app (forced light) drew a near-black pill on the near-black celebration
    /// grounds, and only the label was visible.
    var onDark: Bool = false

    var body: some View {
        // Text only, like the board's buttons. `systemImage` stays for
        // source compatibility with existing call sites.
        Text(title)
            .multilineTextAlignment(.center)
            .grovePrimaryPill()
            .environment(\.colorScheme, onDark ? .dark : colorScheme)
    }

    @Environment(\.colorScheme) private var colorScheme
}

struct GroveCTAButton: View {
    let title: String
    var systemImage: String = "arrow.right"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GroveCTALabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(GrovePressStyle())
        .accessibilityLabel(title)
    }
}

/// A press style that gives the primary pill a subtle scale on touch, and answers
/// the finger on contact rather than on release.
///
/// The haptic fires on touch-*down*. That ordering is the whole point: a tap
/// confirmed when the finger lifts is a receipt for something already decided,
/// while a tap confirmed the instant the finger lands is the button telling you
/// it heard you — and it makes a slow action (a save, an upload) feel
/// responsive even before it has finished.
struct GrovePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration)
    }

    /// `makeBody` is not a view body, so Reduce Motion is only readable from
    /// inside a nested `View`.
    private struct PressBody: View {
        let configuration: Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
                .opacity(configuration.isPressed ? 0.92 : 1)
                .animation(GroveMotion.press, value: configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, isPressed in
                    guard isPressed else { return }
                    Haptics.press()
                }
        }
    }
}

// MARK: - Pills & chips

/// A soft rounded chip used for the wordmark badge, rewards, and status.
struct GrovePill: View {
    enum Style { case solidInk, softGreen, outline, plain }

    let text: String
    var systemImage: String?
    var style: Style = .plain

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption.weight(.bold))
            }
            Text(text).font(.subheadline.weight(.bold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(foreground)
        .background(background, in: Capsule())
        .overlay {
            if style == .outline {
                Capsule().stroke(GroveTheme.separator, lineWidth: 1.5)
            }
        }
    }

    private var foreground: Color {
        switch style {
        case .solidInk: GroveTheme.onCanvasButtonLabel
        case .softGreen: GroveTheme.accentStrong
        case .outline, .plain: GroveTheme.ink
        }
    }

    private var background: Color {
        switch style {
        case .solidInk: GroveTheme.onCanvasButton
        case .softGreen: GroveTheme.softAccent
        case .outline: .clear
        case .plain: GroveTheme.surface
        }
    }
}

// MARK: - Action tile (Store / Pick up / Delivery style)

/// A soft rounded tile with an illustrative icon and a label, plus an optional
/// green check when selected. Used for Home quick actions and segmented picks.
///
/// Sized so four tiles still fit across the narrowest supported screen
/// (375 pt): a wider icon well made the Home row overflow its own margins.
struct GroveActionTile: View {
    let title: String
    var symbol: String? = nil
    var artwork: String? = nil
    var selected: Bool = false
    var tint: Color = GroveTheme.accent

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 52 * 0.34, style: .continuous)
                        .fill(GroveTheme.softAccent)

                    if let artwork {
                        Image(artwork)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 48, height: 48)
                    } else if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 52 * 0.40, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, GroveTheme.accent)
                        .background(Circle().fill(GroveTheme.surface).padding(2))
                        .offset(x: 8, y: -8)
                        // The tick pops in rather than blinking on, so picking
                        // a tile has a visible moment of confirmation.
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .groveAnimation(GroveMotion.pop, value: selected)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(GroveTheme.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                .stroke(selected ? GroveTheme.accent.opacity(0.6) : GroveTheme.separator, lineWidth: selected ? 2 : 1)
        }
        .accessibilityLabel(title.replacingOccurrences(of: "\n", with: " "))
    }
}



// MARK: - Avatars & tiles

struct AvatarView: View {
    /// `initials` and `seed` no longer pick the picture. They stay on the view so
    /// call sites keep their identity context for a future text-initials fallback.
    let initials: String
    var seed: String? = nil
    var size: CGFloat = 42
    var assetName: String? = nil
    var photoURL: URL? = nil
    @State private var photo: UIImage?
    @Environment(\.grovePremiumActive) private var hasPremium
    @Environment(\.grovePremiumAvatarsUnlocked) private var avatarsUnlocked

    /// Everyone starts as the monstera mascot. One shared starting point means a
    /// new Grove looks the same in every screenshot, and picking your own plant
    /// stays a deliberate choice rather than a correction of a random assignment.
    static let defaultImageName = "GroveAvatarMascotMonstera"

    static let premiumImageNames = [
        "GroveAvatarPremiumMoonlitMonstera",
        "GroveAvatarPremiumOrchid",
        "GroveAvatarPremiumVelvetCalathea",
        "GroveAvatarPremiumStarlightStringOfHearts",
        "GroveAvatarPremiumRosewaterHoya",
        "GroveAvatarPremiumSilverMoonAlocasia",
        "GroveAvatarPremiumEmberBegonia",
        "GroveAvatarPremiumGildedGinkgo",
        "GroveAvatarPremiumSunsetBirdOfParadise",
        "GroveAvatarPremiumFrostedAnthurium"
    ]

    static let imagePages = [
        [
            "GroveAvatarPothos",
            "GroveAvatarIvy",
            "GroveAvatarFern",
            "GroveAvatarGinkgo",
            "GroveAvatarPilea",
            "GroveAvatarRosemary",
            "GroveAvatarEucalyptus",
            "GroveAvatarCalathea"
        ],
        [
            "GroveAvatarSnakePlant",
            "GroveAvatarHoya",
            "GroveAvatarLavender",
            "GroveAvatarMaidenhair",
            "GroveAvatarPeperomia",
            "GroveAvatarRubberPlant",
            "GroveAvatarCyclamen",
            "GroveAvatarOlive"
        ],
        [
            "GroveAvatarSilverFern",
            "GroveAvatarJuniper",
            "GroveAvatarAlocasia",
            "GroveAvatarStringOfHearts",
            "GroveAvatarMaranta",
            "GroveAvatarOrchid",
            "GroveAvatarLemon",
            "GroveAvatarFiddleLeafFig"
        ],
        [
            "GroveAvatarBegonia",
            "GroveAvatarAnthurium",
            "GroveAvatarBayLaurel",
            "GroveAvatarBirdOfParadise",
            "GroveAvatarTradescantia",
            "GroveAvatarHeather",
            "GroveAvatarZZPlant",
            "GroveAvatarMonstera"
        ],
        [
            "GroveAvatarMascotMonstera",
            "GroveAvatarMascotCactus",
            "GroveAvatarMascotPothos",
            "GroveAvatarMascotFern",
            "GroveAvatarMascotCalathea",
            "GroveAvatarMascotSucculent",
            "GroveAvatarMascotSnakePlant",
            "GroveAvatarMascotAnthurium"
        ],
        premiumImageNames
    ]

    static let imageNames = imagePages.flatMap { $0 }

    static var premiumPageIndex: Int { imagePages.count - 1 }

    static func isPremiumAsset(_ assetName: String) -> Bool {
        premiumImageNames.contains(assetName)
    }

    static func pageIndex(for assetName: String?) -> Int {
        guard let assetName,
              let pageIndex = imagePages.firstIndex(where: { $0.contains(assetName) })
        else { return 0 }
        return pageIndex
    }

    private var fallbackImageName: String {
        guard let assetName,
              !(Self.isPremiumAsset(assetName) && !(hasPremium || avatarsUnlocked))
        else {
            return Self.defaultImageName
        }
        return assetName
    }

    var body: some View {
        Group {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(fallbackImageName)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().stroke(GroveTheme.separator, lineWidth: 1) }
        .accessibilityHidden(true)
        .task(id: photoURL) {
            guard let resolvedURL = GroveMediaPath.resolved(photoURL) else {
                photo = nil
                return
            }
            photo = await GroveImageLoader.downsampledImage(
                at: resolvedURL,
                maxDimension: max(size * 3, 180)
            )
        }
    }
}

struct GroveSymbolTile: View {
    let symbol: String
    var tint: Color = GroveTheme.accent
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.40, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(GroveTheme.softAccent, in: RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A bespoke full-colour companion to `GroveSymbolTile`.
///
/// Artwork is intentionally inset inside the same tile geometry, so generated
/// illustrations and SF Symbols can sit in one list without changing its rhythm.
struct GroveArtworkTile: View {
    let asset: String
    var size: CGFloat = 44

    var body: some View {
        Image(asset)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size * 0.82, height: size * 0.82)
            .frame(width: size, height: size)
            .background(GroveTheme.softAccent, in: RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A small stat: a coloured glyph followed by its value — "+3 XP", "5-day
/// streak". Takes its size from the surrounding `.font`.
///
/// The tint stays on the *symbol* and the words are set in ink, because the
/// celebration colours are light by construction. A gold that still reads as
/// gold measures about 2.4:1 on the cream canvas, and darkening it far enough
/// to carry caption text turns it into `warning` — which is the one thing gold
/// is documented never to be. The glyph is decorative here (the words repeat
/// what it means), so it is the half that can afford the colour.
struct GroveStatLabel: View {
    let text: String
    let symbol: String
    var tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).foregroundStyle(GroveTheme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

struct HealthBadge: View {
    let band: HealthBand

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(band.color).frame(width: 7, height: 7)
            Text(band.shortTitle)
                .font(.caption.weight(.bold))
                .foregroundStyle(GroveTheme.ink)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(GroveTheme.surface, in: Capsule())
        .overlay { Capsule().stroke(GroveTheme.separator, lineWidth: 1) }
    }
}

/// The stand-in for a plant Grove does not have yet: a scan still resolving, a
/// match it could not identify. A glyph is the honest drawing here, because
/// there is no plant to draw a portrait of.
///
/// Anywhere a real `Plant` exists, use `PlantThumbnail` — it shows the plant's
/// own photograph, and falls back to `PlantPortrait` rather than to a glyph. A
/// symbol on a gradient used to stand in for every plant in the app, and that
/// is exactly the habit that left the product's own subject looking like
/// everyone else's.
struct PlantArtwork: View {
    let symbol: String
    let palette: PlantPalette
    var height: CGFloat = 180

    var body: some View {
        ZStack {
            LinearGradient(
                colors: palette.colors.map { $0.opacity(0.92) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: height * 0.78)
                .offset(x: height * 0.36, y: -height * 0.28)
            Image(systemName: symbol)
                .font(.system(size: height * 0.34, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(0.95))
        }
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: - Clean top bar (transparent, dark content on cream)

/// Grove's editorial top bar: a transparent navigation bar that lets the cream
/// canvas show through, with dark, appearance-following content. Replaces the
/// old solid forest band. Pair with a `.toolbar { … }` using the `GroveHeader*`
/// helpers, which now render in ink.
struct GroveHeaderBar: ViewModifier {
    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

/// The root tabs' bar: transparent, with nothing in its centre.
///
/// The brand mark used to stand in the principal slot of all four tabs. A logo
/// repeated on every root, above a page that already opens with its own name
/// in the display face, is a header saying the same thing twice — and it held
/// the bar's centre so the leading and trailing chips had to shrink around it.
/// The best-designed consumer apps keep the bar for controls and let the page
/// title carry identity; the `g` now lives where a mark belongs: the icon, the
/// launch screen and the My Grove tab glyph. One modifier rather than three
/// modifiers copied into four files, because a header rule that has to be
/// re-typed per screen is a header rule that drifts.
///
/// Root tabs only. A pushed screen needs its own name in the bar and gets
/// `grovePageTitle` instead.
struct GroveRootHeaderBar: ViewModifier {
    /// The tab's name, shown in the bar's centre once its own heading has
    /// scrolled away beneath it.
    var title: String?

    /// True once the white sheet sits under the bar. The bar belongs to
    /// whatever is beneath it: light glyphs on the dark hero, ink on paper.
    @State private var isOnPaper = false
    /// The page's own appearance. Read here, below the bar, because inside a
    /// toolbar item it reports the bar's forced scheme instead.
    @Environment(\.colorScheme) private var pageScheme

    /// Light glyphs over the hero; the page's own scheme over paper. Set
    /// explicitly rather than cleared to nil: a cleared scheme leaves the
    /// bar's items in the dark one they last had.
    private var barScheme: ColorScheme { isOnPaper ? pageScheme : .dark }

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(GroveBoardSheetAtTopKey.self) { atTop in
                withAnimation(.easeInOut(duration: 0.2)) { isOnPaper = atTop }
            }
            .navigationBarTitleDisplayMode(.inline)
            // A clear background marked visible is what lets the colour scheme
            // reach the status bar; a hidden background leaves it in the
            // page's own scheme.
            .toolbarBackground(Color.clear, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(barScheme, for: .navigationBar)
            .environment(\.groveHeaderUsesLightContent, !isOnPaper)
            .environment(\.groveHeaderChipScheme, barScheme)
            .toolbar {
                // Empty over the hero, where the sheet carries the tab's name;
                // the name moves up here once that heading has gone under.
                ToolbarItem(placement: .principal) {
                    if let title, isOnPaper {
                        // Same scheme as the chips beside it, so the ink
                        // resolves against the page under the bar rather than
                        // the dark scheme the bar held over the hero. Set
                        // here: this toolbar sits outside the chip-scheme
                        // environment above.
                        GroveHeaderTitle(text: title)
                            .environment(\.colorScheme, barScheme)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    } else {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityHidden(true)
                    }
                }
            }
    }
}

/// Puts a root-tab header chip in the scheme of whatever is under the bar.
private struct GroveHeaderChipScheme: ViewModifier {
    @Environment(\.groveHeaderChipScheme) private var chipScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if let chipScheme {
            content.environment(\.colorScheme, chipScheme)
        } else {
            content
        }
    }
}

private struct GroveHeaderChipSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme? = nil
}

extension EnvironmentValues {
    /// The scheme a root-tab header chip draws in, set by the root header bar.
    var groveHeaderChipScheme: ColorScheme? {
        get { self[GroveHeaderChipSchemeKey.self] }
        set { self[GroveHeaderChipSchemeKey.self] = newValue }
    }
}

extension View {
    /// Applies Grove's transparent top bar. Provide the bar's content with a
    /// standard `.toolbar { … }` using the `GroveHeader*` helpers.
    func groveHeaderBar() -> some View {
        modifier(GroveHeaderBar())
    }

    /// Grove's root-tab header: the transparent bar, streak leading and up to
    /// two `GroveHeaderIcon` actions trailing, added by each tab's own
    /// `.toolbar { … }`.
    ///
    /// Apply it after the tab's `.toolbar { … }` so the chips inside can see
    /// whether the bar is over the hero or over paper.
    func groveRootHeaderBar(title: String? = nil) -> some View {
        modifier(GroveRootHeaderBar(title: title))
    }

    /// A root-tab header chip: light over the hero, the page's own scheme
    /// once the sheet is under the bar.
    func groveHeaderChip() -> some View {
        modifier(GroveHeaderChipScheme())
    }
}

/// The one inline page-title treatment: an ink `GroveHeaderTitle` in the
/// bar's principal slot. `navigationTitle` is still set so back buttons and
/// accessibility keep the screen's name.
private struct GrovePageTitleModifier: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { GroveHeaderTitle(text: title) }
            }
    }
}

extension View {
    /// Grove's page title for native-context screens (Lists, Forms): the
    /// branded ink title, with the system's own bar background behavior.
    func grovePageTitle(_ title: String) -> some View {
        modifier(GrovePageTitleModifier(title: title))
    }

    /// Grove's full branded chrome for scroll pages: the ink page title on
    /// a transparent bar so the cream canvas runs edge to edge.
    func groveEditorialPage(_ title: String) -> some View {
        grovePageTitle(title)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

/// The page title in a navigation bar's principal slot.
///
/// Set in the rounded display face rather than the standard interface design:
/// the bar is the one piece of type that follows you from screen to screen, so
/// switching voice on the way in would quietly tell the user they had left the
/// app. It is the smallest setting of the display face in the product.
struct GroveHeaderTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(GroveTheme.display(17, weight: .semibold))
            .foregroundStyle(GroveTheme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Grove's compact brand mark for a root-tab navigation bar.
///
/// The sculpted `g` alone, standing on the cream canvas with nothing behind it.
/// It used to be the app icon: the whole tile, beige ground and rounded corners
/// and a hairline border. On a home screen full of other tiles that is right,
/// but in Grove's own transparent header it arrived as a sticker — the icon's
/// ground is a warmer beige than the canvas, so the square was faintly visible
/// around the mark, and the border drew a box around the one element that
/// should feel printed onto the page.
///
/// `GroveBrandMark` is that same artwork with the tile keyed out by
/// `scripts/generate-brand-mark.swift`, so the mark keeps its shape and the
/// header keeps its emptiness.
///
/// Drawn as a template in one flat forest, not as the icon's sculpted artwork.
/// The icon is modelled — gradients, a lit top edge, a shadowed underside —
/// which is legible at 60pt on a home screen and turns to mush at a third of
/// that. Flattened, the same silhouette reads instantly, and the leaf still
/// shows because it floats inside the `g`'s open counter rather than being
/// painted onto it. It also follows the appearance, which a baked raster
/// never could.
///
/// Both dimensions are explicit. The bar's principal slot can propose a zero
/// width, and a resizable image left to find its own width from an aspect ratio
/// takes the proposal at its word and disappears — so the frame states the
/// artwork's own 108:165 ratio instead of asking for it.
private struct GroveHeaderUsesLightContentKey: EnvironmentKey {
    static let defaultValue = false
}

private struct GroveHeaderClusteredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Presentation-only header styling for screens that place the transparent
    /// navigation bar over a dark masthead.
    var groveHeaderUsesLightContent: Bool {
        get { self[GroveHeaderUsesLightContentKey.self] }
        set { self[GroveHeaderUsesLightContentKey.self] = newValue }
    }

    /// True when a header control is nested inside a custom multi-control
    /// toolbar capsule and must not draw its own fallback surface.
    var groveHeaderClustered: Bool {
        get { self[GroveHeaderClusteredKey.self] }
        set { self[GroveHeaderClusteredKey.self] = newValue }
    }
}

private struct GrovePremiumActiveKey: EnvironmentKey {
    static let defaultValue = false
}

/// Premium mascots follow the same rule as Ask and Friends: unlocked whenever
/// limits do not apply (`GrovePremiumStore.isUnmetered`), which includes early
/// access while nothing is on sale. Kept apart from `grovePremiumActive`, which
/// also drives the Premium header mark and must stay a real entitlement.
private struct GrovePremiumAvatarsUnlockedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var grovePremiumAvatarsUnlocked: Bool {
        get { self[GrovePremiumAvatarsUnlockedKey.self] }
        set { self[GrovePremiumAvatarsUnlockedKey.self] = newValue }
    }
}

extension EnvironmentValues {
    /// A presentation-only reading of the live entitlement. Keeping the default
    /// here makes standalone screen previews honest free accounts without
    /// requiring RevenueCat's store in the design system.
    var grovePremiumActive: Bool {
        get { self[GrovePremiumActiveKey.self] }
        set { self[GrovePremiumActiveKey.self] = newValue }
    }
}

struct GroveHeaderLogo: View {
    @Environment(\.grovePremiumActive) private var isPremium
    @Environment(\.groveHeaderUsesLightContent) private var usesLightContent

    /// The mark's rendered height. Taller than the 32pt tile it replaced,
    /// because the tile counted its own padding: the `g` inside it stood about
    /// 20pt, and a mark with no plate has to carry the header on its own weight.
    private static let height: CGFloat = 34
    private static let width: CGFloat = (height * 108 / 165).rounded()

    var body: some View {
        ZStack {
            Image("GroveBrandMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: Self.width, height: Self.height)
                .foregroundStyle(usesLightContent ? Color.white : GroveTheme.accentStrong)

            if isPremium {
                Image("GrovePremiumSpark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .offset(x: 7, y: -2)
                    .transition(.scale(scale: 0.45).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        // The spark deliberately overhangs this stable frame. The sculpted `g`
        // remains geometrically centred as entitlement changes; only the badge
        // blooms beyond its upper-right leaf.
        .frame(width: Self.width, height: Self.height)
        .groveAnimation(GroveMotion.pop, value: isPremium)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPremium ? "Grove Premium" : "Grove")
        .accessibilityAddTraits(.isHeader)
    }
}

/// Tappable location label with a disclosure chevron, in ink.
///
/// The glyph is a house rather than a map pin: this control names the place the
/// grove *lives*, and a pin reads as "where you are right now", which is the
/// one thing it never means — a user reading their grove's forecast from an
/// airport is exactly the case Grove's travel handling exists for.
///
/// The `caption` exists because that reasoning is invisible to the person
/// holding the phone. A place name they are not currently standing in reads as
/// a bug — the app looks like it failed to notice they moved — and no amount of
/// choosing a house glyph over a pin says otherwise. So when Grove knows the
/// phone is elsewhere, the label stops relying on the icon to explain itself and
/// says out loud whose location this is.
///
/// `isSet` is the other half of the same control. Before a grove has a
/// location this used to read "Home" with a switcher chevron, which is a
/// placeholder wearing the clothes of a real value: the app looked as though it
/// already knew, while a separate card lower down asked the question for real.
/// One control now holds both states — a tinted chip that asks, and the plain
/// ink label that answers — so the thing you tap to set the location is the
/// same thing you later tap to change it.
struct GroveHeaderLocation: View {
    let label: String
    var symbol: String = "house.fill"
    /// False until a grove has a location, which turns the label into the ask.
    var isSet: Bool = true
    /// Shown under the label when there is something about it to explain.
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: isSet ? 2 : 6) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.accent)
                Text(label)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(GroveTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                // A grove with no location has nothing to switch between, so
                // the chevron points where the tap actually goes.
                Image(systemName: isSet ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GroveTheme.accent)
            }
            .padding(.horizontal, isSet ? 0 : 13)
            .padding(.vertical, isSet ? 0 : 9)
            .background {
                if !isSet {
                    Capsule().fill(GroveTheme.softAccent)
                }
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A bare label and two small glyphs come to about 22pt tall; the header
        // has room, and a 44pt target costs nothing here.
        .frame(minHeight: 30)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Grove's one search field: its words and the colour they are set in.
///
/// The system draws a search placeholder in `.placeholderText` — a grey held at
/// 30% opacity, which lands near 2:1 against the near-white top of the root
/// masthead. It was the one piece of type in the app you had to lean towards,
/// and the field it labels is how a grove past a dozen plants is used at all.
/// UIKit exposes no colour for it, only the whole attributed string, which is
/// why the wording lives here beside the appearance that renders it rather than
/// at the two call sites.
enum GroveSearchField {
    static let prompt = "Name, species or room"

    /// Install during launch. `UIAppearance` is read when a view moves into a
    /// window, so anything later misses the field already on screen.
    static func installAppearance() {
        let field = UISearchTextField.appearance(whenContainedInInstancesOf: [UISearchBar.self])
        field.attributedPlaceholder = NSAttributedString(
            string: prompt,
            attributes: [.foregroundColor: UIColor(GroveTheme.mutedInk)]
        )
        field.textColor = UIColor(GroveTheme.ink)
        // The magnifier fades with the placeholder and has to come back with it,
        // or the field reads as a stray capsule with a word in it.
        UIImageView.appearance(whenContainedInInstancesOf: [UISearchTextField.self])
            .tintColor = UIColor(GroveTheme.mutedInk)
    }
}

/// Ink header action icon with an optional notification dot.
///
/// Only ever used inside a `.toolbar`, and that is what decides how it is drawn.
/// On iOS 26 the bar wraps its own items in Liquid Glass and merges adjacent
/// ones into a single capsule; drawing a disc underneath the glyph as well left
/// two outlined circles sitting inside that capsule — chrome inside chrome, with
/// the header reading as three competing objects instead of one. So on 26 the
/// glyph is bare and the bar supplies the material. Earlier releases have no
/// such container, and there the warm-white disc is the whole chip.
struct GroveHeaderIcon: View {
    let symbol: String
    var showsBadge: Bool = false
    @Environment(\.groveHeaderClustered) private var isClustered

    private var usesBareChrome: Bool {
        if #available(iOS 26.0, *) { return true }
        return isClustered
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(GroveTheme.ink)
    }

    @ViewBuilder
    private var badge: some View {
        if showsBadge {
            Circle()
                .fill(GroveTheme.accent)
                .frame(width: 9, height: 9)
                .overlay { Circle().stroke(GroveTheme.background, lineWidth: 1.5) }
        }
    }

    var body: some View {
        if usesBareChrome {
            glyph
                .frame(width: 24, height: 24)
                .overlay(alignment: .topTrailing) {
                    badge.offset(x: 4, y: -2)
                }
        } else {
            glyph
                .frame(width: 38, height: 38)
                .background(GroveTheme.surface, in: Circle())
                .overlay { Circle().stroke(GroveTheme.separator, lineWidth: 1) }
                .overlay(alignment: .topTrailing) {
                    badge.offset(x: 1, y: -1)
                }
        }
    }
}

/// Compact avatar sized for the header's trailing slot.
struct GroveHeaderAvatar: View {
    let initials: String
    let seed: String
    var size: CGFloat = 38
    var assetName: String? = nil
    var photoURL: URL? = nil

    var body: some View {
        AvatarView(
            initials: initials,
            seed: seed,
            size: size,
            assetName: assetName,
            photoURL: photoURL
        )
    }
}

// MARK: - Gallery

/// One screen holding the whole system, so a token can be changed and judged
/// against everything it touches rather than against the one card it was
/// changed for.
///
/// The palette is the reason this exists. A colour read as a swatch is a
/// colour read out of context, and most of the decisions recorded in the
/// comments above — the two greens split along hue, amber darkened for the
/// canvas, the flame's fixed ember — are decisions about how a colour behaves
/// *next to its neighbours* at the size it is actually used. So the swatches
/// are laid out in their role groups, and the components sit underneath on the
/// same page: change `accent` and the pill, the tile, the tick and the stat
/// row all move at once, in the canvas, before a build.
private struct GroveSystemGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                section("Canvas") {
                    swatches([
                        ("background", GroveTheme.background),
                        ("surface", GroveTheme.surface),
                        ("secondarySurface", GroveTheme.secondarySurface),
                        ("separator", GroveTheme.separator)
                    ])
                }

                section("Ink") {
                    swatches([
                        ("ink", GroveTheme.ink),
                        ("mutedInk", GroveTheme.mutedInk),
                        ("subtleInk", GroveTheme.subtleInk)
                    ])
                }

                section("Accent") {
                    swatches([
                        ("accent", GroveTheme.accent),
                        ("accentStrong", GroveTheme.accentStrong),
                        ("softAccent", GroveTheme.softAccent)
                    ])
                    RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                        .fill(GroveTheme.accentGradient())
                        .frame(height: 44)
                        .overlay(alignment: .leading) {
                            Text("accentGradient")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.leading, 12)
                        }
                }

                section("Signals") {
                    swatches([
                        ("warning", GroveTheme.warning),
                        ("danger", GroveTheme.danger),
                        ("hydration", GroveTheme.hydration),
                        ("purple", GroveTheme.purple)
                    ])
                }

                section("Celebration") {
                    swatches([
                        ("gold", GroveTheme.gold),
                        ("goldDeep", GroveTheme.goldDeep),
                        ("streak", GroveTheme.streak),
                        ("ember", GroveTheme.ember)
                    ])
                }

                // The five-step scale is the one place adjacent colours have to
                // be told apart with nothing but the colour, so they are shown
                // touching — as they appear in the Living Record's timeline.
                section("Health bands") {
                    HStack(spacing: 0) {
                        ForEach(HealthBand.allCases, id: \.self) { band in
                            Rectangle().fill(band.color).frame(height: 40)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))

                    GroveFlowLayout(spacing: 8) {
                        ForEach(HealthBand.allCases, id: \.self) { HealthBadge(band: $0) }
                    }
                }

                section("Display type") {
                    ForEach(displaySizes, id: \.label) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            GroveDisplayHeading(text: "Hey, Alex.", style: entry.style)
                            Text("\(entry.label) · \(Int(entry.style.points))")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(GroveTheme.subtleInk)
                        }
                    }
                    GroveEyebrow(text: "Eyebrow")
                }

                section("Corner radii") {
                    HStack(spacing: 12) {
                        radius("compact", GroveTheme.compactRadius)
                        radius("inset", GroveTheme.insetRadius)
                        radius("card", GroveTheme.cardRadius)
                        radius("hero", GroveTheme.heroRadius)
                    }
                }

                // Shown on the real ground: elevation is a relationship between
                // a surface and the paper behind it, and a shadow judged on
                // white is not judged at all.
                section("Elevation") {
                    HStack(spacing: 16) {
                        elevation("resting", .resting)
                        elevation("floating", .floating)
                        elevation("hero", .hero)
                    }
                }

                section("Pills") {
                    GroveFlowLayout(spacing: 8) {
                        GrovePill(text: "Solid ink", style: .solidInk)
                        GrovePill(text: "Soft green", systemImage: "leaf.fill", style: .softGreen)
                        GrovePill(text: "Outline", style: .outline)
                        GrovePill(text: "Plain", style: .plain)
                    }
                }

                section("Action tiles") {
                    HStack(spacing: 10) {
                        GroveActionTile(title: "Water", symbol: "drop.fill")
                        GroveActionTile(title: "Feed", symbol: "leaf.fill", selected: true)
                        GroveActionTile(title: "Repot", symbol: "arrow.up.bin.fill")
                        GroveActionTile(title: "Prune", symbol: "scissors")
                    }
                }

                section("Stats") {
                    HStack(spacing: 18) {
                        GroveStatLabel(text: "12 plants", symbol: "leaf.fill", tint: GroveTheme.accent)
                        GroveStatLabel(text: "4 day streak", symbol: "flame.fill", tint: GroveTheme.streak)
                        GroveStatLabel(text: "2 due", symbol: "drop.fill", tint: GroveTheme.hydration)
                    }
                    .font(.subheadline.weight(.semibold))
                }

                section("Call to action") {
                    GroveCTAButton(title: "Add your first plant") {}
                }

                section("Card") {
                    VStack(alignment: .leading, spacing: 6) {
                        GroveDisplayHeading(text: "Monstera", style: .card)
                        Text("Checked in this morning. Soil still damp, so this one can wait.")
                            .font(.subheadline)
                            .foregroundStyle(GroveTheme.mutedInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .groveCard()
                }
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, GroveTheme.pageTopPadding)
            .padding(.bottom, GroveTheme.pageBottomPadding)
        }
        .groveBackground()
    }

    private var displaySizes: [(label: String, style: GroveDisplayStyle)] {
        [("hero", .hero), ("title", .title), ("heading", .heading), ("section", .section), ("card", .card)]
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GroveEyebrow(text: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func swatches(_ entries: [(String, Color)]) -> some View {
        GroveFlowLayout(spacing: 10) {
            ForEach(entries, id: \.0) { name, color in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                        .fill(color)
                        .frame(width: 92, height: 56)
                        .overlay {
                            RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                                .strokeBorder(GroveTheme.separator, lineWidth: 1)
                        }
                    Text(name)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(GroveTheme.mutedInk)
                }
            }
        }
    }

    private func radius(_ name: String, _ value: CGFloat) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: value, style: .continuous)
                .fill(GroveTheme.secondarySurface)
                .frame(height: 62)
            Text("\(name) · \(Int(value))")
                .font(.caption2.weight(.medium))
                .foregroundStyle(GroveTheme.mutedInk)
        }
    }

    private func elevation(_ name: String, _ level: GroveElevation) -> some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                .fill(GroveTheme.surface)
                .frame(height: 62)
                .groveShadow(level)
            Text(name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(GroveTheme.mutedInk)
        }
    }
}

#Preview("System gallery") {
    GroveSystemGallery()
}

#Preview("System gallery · dark") {
    GroveSystemGallery()
        .preferredColorScheme(.dark)
}
