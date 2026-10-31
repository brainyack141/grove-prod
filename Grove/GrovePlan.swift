import Foundation

/// The personalization a user builds during onboarding: how experienced they
/// are, how many plants they keep, where those plants live, the problems they
/// asked Grove to solve, and the one thing to fix first.
///
/// This used to exist only inside `OnboardingModel`. It was rendered once on
/// the plan-reveal screen — under a button labelled "Save my plan" — and then
/// deleted by `clearDraft()` before `completeOnboarding` handed anything over.
/// Six questions were asked, a plan was promised, and every user landed on an
/// identical Today. The plan now lives on `UserProfile`, so it survives
/// onboarding, persists with the account snapshot, and stays editable from
/// My Grove — which is what "Change any of it whenever you like" already
/// promised on the reveal screen.
///
/// Answers are stored as the catalogue's stable string IDs rather than as
/// display copy: the wording is free to change without invalidating a saved
/// plan, and `GrovePlanCatalog` is the single place that maps ID to label.
struct GrovePlan: Codable, Hashable, Sendable {
    var experience: String?
    var collectionSize: String?
    var environment: String?
    /// The problems chosen on the pick-3 step. Held sorted so the render order
    /// and equality are both stable regardless of the order they were tapped.
    var focuses: [String]
    var challenge: String?

    init(
        experience: String? = nil,
        collectionSize: String? = nil,
        environment: String? = nil,
        focuses: [String] = [],
        challenge: String? = nil
    ) {
        self.experience = experience
        self.collectionSize = collectionSize
        self.environment = environment
        self.focuses = focuses.sorted()
        self.challenge = challenge
    }

    /// True when the user answered nothing at all. A plan in this state is not
    /// worth persisting or rendering — the caller shows the "build one" prompt
    /// instead of an empty card.
    var isEmpty: Bool {
        experience == nil
            && collectionSize == nil
            && environment == nil
            && focuses.isEmpty
            && challenge == nil
    }

    /// Keeps `focuses` sorted and inside the pick limit however it is mutated —
    /// including by the edit screen, which toggles entries directly.
    mutating func toggleFocus(_ id: String) {
        if let index = focuses.firstIndex(of: id) {
            focuses.remove(at: index)
        } else if focuses.count < GrovePlanCatalog.focusPickLimit {
            focuses.append(id)
            focuses.sort()
        }
    }
}

// MARK: - Plan copy

extension GrovePlan {
    /// How often Grove will ask for a round of check-ins, in the user's terms.
    /// Shared by the onboarding reveal and the editable plan screen so the two
    /// can never describe the same answer differently.
    var cadenceText: String {
        switch collectionSize {
        case "10+": "Two short rounds a week, so a big grove never piles up."
        case "4-10": "One walk round your plants a week. Ten minutes, tops."
        case "0": "Nothing until you add your first plant. No pressure before that."
        default: "One check-in per plant, every couple of weeks."
        }
    }

    var environmentIcon: String {
        switch environment {
        case "outdoor": "sun.max.fill"
        case "both": "square.split.2x1.fill"
        default: "house.fill"
        }
    }

    var environmentText: String {
        switch environment {
        case "outdoor": "Advice that moves with your local weather and the season."
        case "both": "Indoors and outdoors get different answers. You'll get both."
        default: "Light and watering advice for life on a windowsill."
        }
    }

    /// The chosen problems echoed back as plan focus areas. Falls back to a
    /// single habit-building chip so the section is never blank.
    var focusChips: [String] {
        let chosen = focuses.compactMap { id in
            GrovePlanCatalog.focus(id).map { "\($0.emoji) \($0.planLabel)" }
        }
        return chosen.isEmpty ? ["🌱 Building the habit"] : chosen
    }

    /// One-line summary for the My Grove row, so the plan is legible without
    /// opening it.
    var summaryLine: String {
        let parts = [
            GrovePlanCatalog.title(for: experience, in: GrovePlanCatalog.experience),
            GrovePlanCatalog.title(for: environment, in: GrovePlanCatalog.environment),
            GrovePlanCatalog.title(for: challenge, in: GrovePlanCatalog.challenge).map { "fixing \($0.lowercased())" }
        ].compactMap { $0 }
        return parts.isEmpty ? "Tell Grove how you garden" : parts.joined(separator: " · ")
    }
}

// MARK: - Catalogue

/// The single source of truth for every plan question, its options, and their
/// stable IDs. Onboarding renders from this, the editable plan screen renders
/// from this, and `GrovePlan` resolves stored IDs back to labels through it —
/// so a wording change lands everywhere at once and an ID can never drift out
/// from under a saved plan.
enum GrovePlanCatalog {
    struct Choice: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        var detail: String?
        let symbol: String
    }

    struct Focus: Identifiable, Hashable, Sendable {
        let id: String
        let emoji: String
        /// Wording used when asking the question ("What keeps going wrong?").
        let title: String
        /// Wording used when reflecting the answer back as a plan focus.
        let planLabel: String
    }

    /// How many problems the pick step requires.
    static let focusPickLimit = 3

    static let experience: [Choice] = [
        Choice(id: "new", title: "Total beginner", detail: "I've killed a few", symbol: "sparkles"),
        Choice(id: "hobbyist", title: "Getting the hang of it", detail: "Most of mine are doing fine", symbol: "leaf.fill"),
        Choice(id: "experienced", title: "I know my stuff", detail: "Skip the basics", symbol: "trophy.fill")
    ]

    static let collectionSize: [Choice] = [
        Choice(id: "0", title: "None yet", detail: "Starting from scratch", symbol: "circle"),
        Choice(id: "1-3", title: "1–3", detail: "The ones I'd miss", symbol: "circle.grid.2x1.fill"),
        Choice(id: "4-10", title: "4–10", detail: "A proper little grove", symbol: "circle.grid.2x2.fill"),
        Choice(id: "10+", title: "More than 10", detail: "I've lost count", symbol: "circle.grid.3x3.fill")
    ]

    static let environment: [Choice] = [
        Choice(id: "indoor", title: "Indoors", detail: "Windowsills and shelves", symbol: "house.fill"),
        Choice(id: "outdoor", title: "Outdoors", detail: "Garden, balcony, doorstep", symbol: "sun.max.fill"),
        Choice(id: "both", title: "A bit of both", detail: "Some in, some out", symbol: "square.split.2x1.fill")
    ]

    static let challenge: [Choice] = [
        Choice(id: "watering", title: "Watering", detail: "How much, how often, when to stop", symbol: "drop.fill"),
        Choice(id: "light", title: "Light", detail: "Where each plant actually belongs", symbol: "sun.max.fill"),
        Choice(id: "pests", title: "Pests and disease", detail: "Catching them in week one", symbol: "ladybug.fill"),
        Choice(id: "id", title: "Knowing what I've got", detail: "Names, needs, and what's toxic", symbol: "questionmark.circle.fill")
    ]

    static let focuses: [Focus] = [
        Focus(id: "slow-death", emoji: "🥀", title: "They die slowly and I don't know why", planLabel: "Spotting decline early"),
        Focus(id: "watering", emoji: "💧", title: "I never know when to water", planLabel: "Watering the right amount"),
        Focus(id: "pests", emoji: "🐛", title: "I spot pests far too late", planLabel: "Catching pests in week one"),
        Focus(id: "leaves", emoji: "🍂", title: "Yellow, drooping leaves", planLabel: "Reading the leaves"),
        Focus(id: "unknown-needs", emoji: "❓", title: "I don't know what it needs", planLabel: "What each plant actually needs"),
        Focus(id: "light", emoji: "☀️", title: "I'm guessing at the right spot", planLabel: "Finding the right spot"),
        Focus(id: "away", emoji: "✈️", title: "They suffer while I'm away", planLabel: "Cover while you're away"),
        Focus(id: "revive", emoji: "🌱", title: "I can't rescue a sick one", planLabel: "Bringing sick plants back"),
        Focus(id: "forget", emoji: "📅", title: "I forget they exist", planLabel: "Remembering, so you don't have to"),
        Focus(id: "repot", emoji: "🪴", title: "I repot at the wrong time", planLabel: "Repotting at the right time")
    ]

    static func title(for id: String?, in choices: [Choice]) -> String? {
        guard let id else { return nil }
        return choices.first { $0.id == id }?.title
    }

    static func focus(_ id: String) -> Focus? {
        focuses.first { $0.id == id }
    }
}
