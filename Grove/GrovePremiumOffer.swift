import Foundation
import SwiftUI
import UIKit

/// What Grove's Premium offer is about, written from a plant the person
/// already keeps.
///
/// The offer used to be a step inside onboarding, where the only thing it
/// could describe was a baseline that had not been saved yet. It now names a
/// real plant in a real grove, so every line here comes from the store rather
/// than from a funnel's memory of what was answered.
struct GrovePremiumOfferSubject: Identifiable {
    let id = UUID()
    /// The bare name, for the outcome headline.
    let displayName: String
    /// Name and species together, when they differ.
    let identityLine: String
    /// One true, checkable fact about this plant right now.
    let supportingLine: String
    /// The size of the grove, in its own words.
    let eyebrowLine: String
    let image: UIImage?

    init(plant: Plant, plantCount: Int, image: UIImage?) {
        displayName = Self.nonEmpty(plant.nickname, fallback: "your plant")
        let species = Self.nonEmpty(plant.species, fallback: "")
        identityLine = species.isEmpty || species.caseInsensitiveCompare(displayName) == .orderedSame
            ? displayName
            : "\(displayName) · \(species)"
        supportingLine = Self.checkInLine(days: plant.daysUntilCheckIn)
        eyebrowLine = plantCount == 1
            ? "1 plant in your grove."
            : "\(plantCount) plants in your grove."
        self.image = image
    }

    private static func checkInLine(days: Int) -> String {
        switch days {
        case ..<0: "Check-in overdue"
        case 0: "Check-in due today"
        case 1: "Next check-in tomorrow"
        default: "Next check-in in \(days) days"
        }
    }

    private static func nonEmpty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

/// Decides when Grove asks for money.
///
/// The rule is one sentence: not until the person has done something useful
/// twice. Grove used to present the offer between the finished setup and
/// account creation, which meant asking someone who had seen a single screen,
/// on behalf of a plant whose baseline was not saved yet, while their way to
/// Today ran through the price. A trial started there is bought on impulse and
/// cancelled on day seven. Two actions from the care loop — two guided
/// check-ins, or a guided check-in and a second plant — are concrete evidence
/// that Grove has joined the person's routine; reopening the app is not. The
/// presenter adds the final context guard: Today must be at rest.
@MainActor
enum GrovePremiumOffer {
    /// Onboarding finished. The offer remains dormant until useful work lands.
    static func arm(in storage: UserDefaults = .standard) {
        // Never overwrite an existing arming. A second account on the same
        // phone must not erase useful actions the first one already earned.
        guard !storage.bool(forKey: GroveDefaults.premiumOfferPending) else { return }
        storage.set(true, forKey: GroveDefaults.premiumOfferPending)
        storage.set(0, forKey: GroveDefaults.premiumOfferMeaningfulUseCount)
    }

    /// Records an action that exercises Grove's actual care loop. Callers own
    /// the definition of the action; this type only keeps the count and the
    /// one-time gate.
    static func recordMeaningfulUse(in storage: UserDefaults = .standard) {
        guard storage.bool(forKey: GroveDefaults.premiumOfferPending) else { return }
        let count = storage.integer(forKey: GroveDefaults.premiumOfferMeaningfulUseCount)
        storage.set(count + 1, forKey: GroveDefaults.premiumOfferMeaningfulUseCount)
    }

    /// Callers add the remaining presentation context: no entitlement, a
    /// loaded catalogue, a real plant, and an idle Today root.
    static func isDue(in storage: UserDefaults = .standard) -> Bool {
        guard storage.bool(forKey: GroveDefaults.premiumOfferPending) else { return false }
        return storage.integer(forKey: GroveDefaults.premiumOfferMeaningfulUseCount) >= 2
    }

    /// Shown, and answered either way. The offer is a one-time moment; Settings
    /// and the daily question limit carry it from here.
    static func complete(in storage: UserDefaults = .standard) {
        storage.set(false, forKey: GroveDefaults.premiumOfferPending)
    }
}
