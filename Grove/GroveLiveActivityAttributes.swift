import ActivityKit
import Foundation

// The wire contract between the app (which starts, updates and ends the
// activities) and the GroveLiveActivity extension (which draws them). Compiled
// into both targets from this one file, the same way GroveWatchShared is, so
// the two sides cannot drift apart silently.
//
// Everything here is a recorded fact or arithmetic on one — the last logged
// watering, the median gap between waterings, the dates of a handover. Nothing
// is guessed to fill a slot: if Grove cannot say it, no activity is started.

/// "<Plant> · soil check": the drying track from the last watering to the
/// day the owner's own rhythm says the soil is due to be dry again.
struct GroveWateringActivityAttributes: ActivityAttributes, Hashable, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var plantName: String
        /// The most recent completed watering, as logged.
        var wateredAt: Date
        /// `wateredAt` plus the owner's typical interval, in whole days. A day,
        /// not a clock time — the rhythm is measured in days, so the views
        /// never present it as anything more precise.
        var dryAt: Date
        /// The median gap between waterings, for the "Usually every N days" line.
        var typicalDays: Int
        /// True once the watering has been logged, so the ended activity can
        /// close on a confirmation instead of a stale "soil check".
        var isDone: Bool = false
    }

    /// Stable per plant, so the controller can tell "same plant, new numbers"
    /// (update) from "different plant" (end and start again).
    var plantID: String
}

/// "<Sitter> is plant-sitting": an owner's active handover, from the day it
/// started to the day the owner is home.
struct GroveSittingActivityAttributes: ActivityAttributes, Hashable, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var completedTasks: Int
        var totalTasks: Int
        /// Plants the sitter has logged care for most recently, newest first.
        /// Empty when nothing has been logged yet.
        var recentPlantNames: [String]
    }

    var assignmentID: String
    var sitterName: String
    var sitterInitials: String
    var startDate: Date
    var endDate: Date
}
