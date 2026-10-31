import SwiftUI

// MARK: - Chapter growth

/// How far a chapter has grown. It used to decide how much scenery the
/// illustrated map drew. The map is gone and nothing on screen reads it now,
/// but `JourneyProgressionTests` still pins the thresholds, so the type stays
/// until those tests go.
enum JourneyWorldPhase: String, CaseIterable, Hashable {
    case veiled
    case seedling
    case growing
    case blooming
}

extension ResolvedChapter {
    var worldPhase: JourneyWorldPhase {
        guard isUnlocked else { return .veiled }
        switch fraction {
        case ..<0.34: return .seedling
        case ..<0.78: return .growing
        default: return .blooming
        }
    }
}

// MARK: - Landmarks (persisted, never shown)

/// A landmark was a discovery on the illustrated map. The map is gone, nothing
/// awards one any more and nothing draws one, but found ids are still stored
/// in `GardenerProgress.discoveredLandmarkIDs` and `GroveStore` validates
/// against this list, so the data stays exactly as it was. Never change an id.
struct JourneyLandmark: Identifiable, Hashable {
    let id: String
    let name: String
    let blurb: String
    let chapterID: String
    let assetName: String
    let spot: UnitPoint
    let revealFraction: Double
}

enum JourneyLandmarkLibrary {
    static let all: [JourneyLandmark] = [
        JourneyLandmark(
            id: "landmark-meadow-gate",
            name: "Clover Gate",
            blurb: "A little doorway for the first brave step into the meadow.",
            chapterID: "first-roots",
            assetName: "JourneyLandmarkMeadow",
            spot: UnitPoint(x: 0.82, y: 0.34),
            revealFraction: 0.34
        ),
        JourneyLandmark(
            id: "landmark-woodland-hollow",
            name: "The Lantern Hollow",
            blurb: "A warm light tucked into an old tree, found by keeping watch.",
            chapterID: "steady-hands",
            assetName: "JourneyLandmarkWoodland",
            spot: UnitPoint(x: 0.18, y: 0.34),
            revealFraction: 0.34
        ),
        JourneyLandmark(
            id: "landmark-orchard-sundial",
            name: "Apple Sundial",
            blurb: "A blossom-covered marker for learning to read the room.",
            chapterID: "reading-the-room",
            assetName: "JourneyLandmarkOrchard",
            spot: UnitPoint(x: 0.82, y: 0.58),
            revealFraction: 0.34
        ),
        JourneyLandmark(
            id: "landmark-highland-cairn",
            name: "Blue Pennant Cairn",
            blurb: "A small summit marker for the days you kept showing up.",
            chapterID: "the-canopy",
            assetName: "JourneyLandmarkHighland",
            spot: UnitPoint(x: 0.18, y: 0.64),
            revealFraction: 0.34
        ),
        JourneyLandmark(
            id: "landmark-canopy-gate",
            name: "The Hidden Gate",
            blurb: "A living doorway into the oldest, greenest part of the grove.",
            chapterID: "old-growth",
            assetName: "JourneyLandmarkCanopy",
            spot: UnitPoint(x: 0.82, y: 0.38),
            revealFraction: 0.34
        )
    ]

    static func landmark(id: String) -> JourneyLandmark? {
        all.first { $0.id == id }
    }
}
