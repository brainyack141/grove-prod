import Foundation

/// How much grove there is to draw, in one value.
///
/// Today's three signature surfaces — the hero stage, the score slot and the
/// record — each have to render something honest for a person who installed
/// Grove ten minutes ago, and each of them was independently deciding what
/// "new" meant. The hero asked whether a photograph existed, the score asked
/// whether `evidenceWeight` had reached 1, and the record asked whether a
/// plant had two frames. Three different questions, three different thresholds,
/// and no guarantee they agreed: the hero could be treating a grove as
/// established while the score still treated it as empty, which is how a page
/// stops feeling like one object.
///
/// The census answers all three once. It is pure in the shape of `GroveScore`
/// and `WateringRhythm` — state in, facts out — so every branch is testable
/// without a store, and Today switches on a single `stage` rather than on
/// four scattered counts.
struct GroveCensus: Equatable {

    /// The rungs of the ladder, in the order a real grove climbs them.
    ///
    /// Deliberately about *evidence*, not about time since install or plant
    /// count alone. Someone who adds six plants and never photographs one has
    /// not reached `observed`, and should not be shown a page built for
    /// somebody who has.
    enum Stage: Int, Comparable, CaseIterable {
        /// No plants. A page state, not a zero.
        case empty
        /// Plants exist, but nothing has been photographed yet, so there is no
        /// portrait to draw from a real check-in and nothing to compare.
        case planted
        /// At least one photograph, but no plant has a second frame — so there
        /// is a picture to show and still nothing to show it *against*.
        case observed
        /// Some plant has two or more frames: then-and-now is real from here.
        case comparing
        /// The score has enough distinct looking-days to carry full weight.
        case established

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let plantCount: Int
    /// Plants carrying at least one check-in photograph.
    let photographedPlantCount: Int
    /// Frames on the deepest single record. The record surfaces read this
    /// rather than a total, because ten plants with one photo each still
    /// cannot make a time-lapse.
    let deepestRecordFrameCount: Int
    /// Distinct days in the score's window with at least one real look.
    let lookDays: Int
    /// 0…1 confidence in the score's total, mirrored from `GroveScore` so a
    /// caller never has to hold both types to answer one question.
    let evidenceWeight: Double
    /// Looking-days this grove needs before its score carries full weight.
    let fullEvidenceDays: Int

    var stage: Stage {
        guard plantCount > 0 else { return .empty }
        guard photographedPlantCount > 0 else { return .planted }
        guard deepestRecordFrameCount >= 2 else { return .observed }
        return evidenceWeight >= 1 ? .established : .comparing
    }

    /// True when the score is still gathering evidence and must not print a
    /// total. Mirrors `GroveScore.isSettling` for callers holding a census.
    var isSettling: Bool { evidenceWeight < 1 }

    /// Looking-days still owed before the score settles.
    var lookDaysRemaining: Int { max(0, fullEvidenceDays - lookDays) }

    // MARK: - Evidence bar

    /// How many distinct looking-days a grove of this size needs before its
    /// score is treated as fully earned.
    ///
    /// A flat ten days was the right bar for the grove the algorithm was
    /// designed against and the wrong one for the grove most people actually
    /// have on day one. Look-days are *distinct calendar days on which any
    /// plant was looked at*, so the rate a grove can accumulate them is capped
    /// by how many plants there are to look at: someone with five plants can
    /// reach ten days in a fortnight of ordinary use, while someone with one
    /// plant checking in on a sensible weekly rhythm needs over two months to
    /// see their first number. Same bar, wildly different wait, and the person
    /// waiting longest is the one least invested.
    ///
    /// The anti-gaming property the flat bar was protecting is calendar time,
    /// not the count itself — six distinct days still cannot be compressed
    /// into one evening, which is the only thing `fullEvidenceDays` was ever
    /// defending. So the bar scales with the grove and keeps its floor well
    /// above anything a single sitting can produce.
    static func fullEvidenceDays(forPlantCount count: Int) -> Int {
        guard count > 0 else { return GroveScore.Rules.fullEvidenceDays }
        return min(GroveScore.Rules.fullEvidenceDays, 4 + 2 * count)
    }

    // MARK: - Taking the census

    static func take(
        plants: [Plant],
        observations: [PlantObservation],
        score: GroveScore?
    ) -> GroveCensus {
        let plantIDs = Set(plants.map(\.id))

        var framesByPlant: [UUID: Int] = [:]
        for observation in observations
        where plantIDs.contains(observation.plantID) && observation.photoURL != nil {
            framesByPlant[observation.plantID, default: 0] += 1
        }

        return GroveCensus(
            plantCount: plants.count,
            photographedPlantCount: framesByPlant.count,
            deepestRecordFrameCount: framesByPlant.values.max() ?? 0,
            // Mirrored from the reading rather than recomputed. The score
            // already measures itself against this grove's bar, and a census
            // that did its own arithmetic would be a second answer to a
            // question that must only have one.
            lookDays: score?.lookDays ?? 0,
            evidenceWeight: score?.evidenceWeight ?? 0,
            fullEvidenceDays: score?.fullEvidenceDays
                ?? fullEvidenceDays(forPlantCount: plants.count)
        )
    }

    /// The empty grove, for previews and for the moment before a store loads.
    static let empty = GroveCensus(
        plantCount: 0,
        photographedPlantCount: 0,
        deepestRecordFrameCount: 0,
        lookDays: 0,
        evidenceWeight: 0,
        fullEvidenceDays: GroveScore.Rules.fullEvidenceDays
    )
}
