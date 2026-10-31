import SwiftUI

// MARK: - Model

/// A cosmetic the player earns and keeps, shown on the Badges page beside the
/// badges. Every one stands for something the player actually did, so each
/// blurb says only what its step really checks. Nothing here is bought,
/// rolled, or randomised — Grove has no spendable currency by design (see
/// `GROVE.md`).
struct Keepsake: Identifiable, Hashable {
    let id: String
    let name: String
    /// What the player did to earn it, in Grove's voice. It must not promise
    /// more than the step that awards it checks.
    let blurb: String
    let sprite: KeepsakeSprite
    /// The chapter whose step awards it.
    let chapterID: String
    /// Where it stood on the retired illustrated map. Nothing draws it now;
    /// it stays only because `JourneyProgressionTests` still pins it.
    let spot: UnitPoint
}

/// The authored visual form of a keepsake.
enum KeepsakeSprite: String, Hashable, Codable {
    case pond
    case bench
    case lantern
    case beehive
    case mushrooms
    case sunflowers
    case birdhouse
    case greenhouse
    case well
    case fox
    case owl
    case archway
    case standingStone
    case windmill

    var artworkName: String {
        switch self {
        case .pond: "JourneyKeepsakePond"
        case .bench: "JourneyKeepsakeBench"
        case .lantern: "JourneyKeepsakeLantern"
        case .beehive: "JourneyKeepsakeBeehive"
        case .mushrooms: "JourneyKeepsakeMushrooms"
        case .sunflowers: "JourneyKeepsakeSunflowers"
        case .birdhouse: "JourneyKeepsakeBirdhouse"
        case .greenhouse: "JourneyKeepsakeGreenhouse"
        case .well: "JourneyKeepsakeWell"
        case .fox: "JourneyKeepsakeFox"
        case .owl: "JourneyKeepsakeOwl"
        case .archway: "JourneyKeepsakeArchway"
        case .standingStone: "JourneyKeepsakeStandingStone"
        case .windmill: "JourneyKeepsakeWindmill"
        }
    }
}

// MARK: - Catalogue

enum KeepsakeLibrary {
    /// Every keepsake in the game, in the order they can be earned. The step
    /// that awards each one is named beside it.
    static let all: [Keepsake] = [
        // Chapter 1, First Roots
        Keepsake(
            id: "ks-pond",
            name: "The Pond",
            blurb: "For the first plant in your grove.", // fr-first-plant
            sprite: .pond,
            chapterID: "first-roots",
            spot: UnitPoint(x: 0.14, y: 0.30)
        ),
        Keepsake(
            id: "ks-mushrooms",
            name: "Ring of Mushrooms",
            blurb: "For the first thing you did and wrote down.", // fr-first-care
            sprite: .mushrooms,
            chapterID: "first-roots",
            spot: UnitPoint(x: 0.88, y: 0.44)
        ),
        Keepsake(
            id: "ks-bench",
            name: "The Bench",
            blurb: "For your first check-in. Going back is the whole habit.", // fr-first-checkin
            sprite: .bench,
            chapterID: "first-roots",
            spot: UnitPoint(x: 0.12, y: 0.62)
        ),
        Keepsake(
            id: "ks-sunflowers",
            name: "Sunflowers",
            blurb: "For the first plant you got to Healthy.", // fr-keep-healthy
            sprite: .sunflowers,
            chapterID: "first-roots",
            spot: UnitPoint(x: 0.87, y: 0.78)
        ),

        // Chapter 2, Steady Hands
        Keepsake(
            id: "ks-lantern",
            name: "The Lantern",
            blurb: "For seven days running. It stays lit.", // sh-streak-7
            sprite: .lantern,
            chapterID: "steady-hands",
            spot: UnitPoint(x: 0.13, y: 0.22)
        ),
        Keepsake(
            id: "ks-birdhouse",
            name: "The Birdhouse",
            blurb: "For three plants in your grove.", // sh-three-plants
            sprite: .birdhouse,
            chapterID: "steady-hands",
            spot: UnitPoint(x: 0.89, y: 0.40)
        ),
        Keepsake(
            id: "ks-fox",
            name: "The Fox",
            blurb: "For logging five things you really did for your plants.", // sh-care-5
            sprite: .fox,
            chapterID: "steady-hands",
            spot: UnitPoint(x: 0.11, y: 0.68)
        ),
        Keepsake(
            id: "ks-beehive",
            name: "The Hive",
            blurb: "For five check-ins. Now there's history to read.", // sh-checkins-5
            sprite: .beehive,
            chapterID: "steady-hands",
            spot: UnitPoint(x: 0.88, y: 0.85)
        ),

        // Chapter 3, Reading the Room
        Keepsake(
            id: "ks-well",
            name: "The Well",
            blurb: "For finishing four Academy lessons.", // rt-lessons-4
            sprite: .well,
            chapterID: "reading-the-room",
            spot: UnitPoint(x: 0.12, y: 0.25)
        ),
        Keepsake(
            id: "ks-archway",
            name: "Wisteria Arch",
            blurb: "For plants in three different rooms.", // rt-locations
            sprite: .archway,
            chapterID: "reading-the-room",
            spot: UnitPoint(x: 0.87, y: 0.48)
        ),
        Keepsake(
            id: "ks-greenhouse",
            name: "The Greenhouse",
            blurb: "For bringing one back from Needs attention. That was you.", // rt-recovery
            sprite: .greenhouse,
            chapterID: "reading-the-room",
            spot: UnitPoint(x: 0.13, y: 0.76)
        ),

        // Chapter 4, The Canopy
        Keepsake(
            id: "ks-standing-stone",
            name: "Standing Stone",
            blurb: "Thirty days running. Somebody carved the date in.", // tc-streak-30
            sprite: .standingStone,
            chapterID: "the-canopy",
            spot: UnitPoint(x: 0.88, y: 0.26)
        ),
        Keepsake(
            id: "ks-owl",
            name: "The Owl",
            blurb: "For asking someone to sit for your plants.", // tc-sitter
            sprite: .owl,
            chapterID: "the-canopy",
            spot: UnitPoint(x: 0.12, y: 0.52)
        ),
        Keepsake(
            id: "ks-windmill",
            name: "The Windmill",
            blurb: "For five plants at Healthy at the same time.", // tc-healthy-5
            sprite: .windmill,
            chapterID: "the-canopy",
            spot: UnitPoint(x: 0.87, y: 0.80)
        ),

        // Chapter 5, Old Growth
        Keepsake(
            id: "ks-old-pond",
            name: "The Deep Pool",
            blurb: "A hundred check-ins. This water has been here a while.", // og-checkins-100
            sprite: .pond,
            chapterID: "old-growth",
            spot: UnitPoint(x: 0.13, y: 0.34)
        ),
        Keepsake(
            id: "ks-old-arch",
            name: "The Old Arch",
            blurb: "A hundred days running. Nobody does this by accident.", // og-streak-100
            sprite: .archway,
            chapterID: "old-growth",
            spot: UnitPoint(x: 0.87, y: 0.66)
        )
    ]

    static func keepsake(id: String) -> Keepsake? {
        all.first { $0.id == id }
    }

    static func inChapter(_ chapterID: String) -> [Keepsake] {
        all.filter { $0.chapterID == chapterID }
    }
}

// MARK: - Sprites

/// Draws a keepsake. Sized against `unit`, so one number scales the whole
/// object and every sprite stays in proportion with the others. Drawn flat,
/// with no shadow under it, on any ground.
struct KeepsakeSpriteView: View {
    let sprite: KeepsakeSprite
    var unit: CGFloat = 46
    /// Kept so call sites on night green still compile. The art is drawn the
    /// same way on either ground now that it carries no shadow.
    var dark: Bool = false

    var body: some View {
        Image(sprite.artworkName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: unit * 1.6, height: unit * 1.6)
            .accessibilityHidden(true)
    }
}
