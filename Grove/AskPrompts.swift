import Foundation

/// A ready-made question, generated from real grove state.
struct AskPrompt: Identifiable, Hashable, Sendable {
    /// Stable across a day for the same underlying situation, so the daily
    /// question does not reshuffle between launches.
    let id: String
    /// The question sent to the botanist, in the user's voice.
    let text: String
    /// Short label for a chip or card, when the full question is too long.
    let label: String
    let symbol: String
    /// The plant whose record grounds the answer, or nil for the whole grove.
    let plantID: UUID?
    /// A factual explanation of why this question is relevant now.
    var reason: String? = nil
}

/// Turning recorded text into something that reads as a row.
///
/// Concerns, planned actions and locations are all written elsewhere — by an
/// assessment model, by the care planner, by the user — at whatever length and
/// in whatever casing suited where they came from. Dropped into a label
/// unchanged they produce four-line rows and sentences like "Is Living room a
/// good spot?", so every one of them passes through here first.
enum AskPhrase {
    /// The most a row can carry before it stops being scannable. Two of these
    /// wrap to a second line at the widest text sizes, which is the ceiling.
    static let labelLimit = 40

    /// A recorded sentence cut down to a phrase, at a word boundary.
    ///
    /// Cuts at the first clause break when there is one — an assessment's
    /// opening clause is nearly always the finding, and the rest is its
    /// qualification — and hard-truncates only when that is still too long.
    static func short(_ sentence: String, limit: Int = labelLimit) -> String {
        var text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if let clause = text.firstIndex(where: { $0 == "," || $0 == ";" }), text.count > limit {
            text = String(text[..<clause])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .;,"))
        guard text.count > limit else { return text }

        let cut = text.prefix(limit)
        let trimmed = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " .;,")) + "…"
    }

    /// A location as it reads mid-sentence: "the living room", "Alex's Office".
    ///
    /// Locations are sentence-cased in the picker ("Living room", "Kitchen")
    /// but the Add flow takes free text, so a name that carries its own capital
    /// past the first letter is treated as a proper noun and left exactly as it
    /// was typed — including going without the article that would read as wrong
    /// in front of it.
    static func inSentence(_ location: String) -> String {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        let rest = trimmed.dropFirst()
        guard first.isUppercase, !rest.contains(where: \.isUppercase) else { return trimmed }
        return "the " + first.lowercased() + rest
    }

    /// A care kind as a bare noun: `loggedTitle` carries an article ("a soil
    /// check") that reads as broken once a sentence supplies its own.
    static func careNoun(_ kind: CareKind) -> String {
        let logged = kind.loggedTitle
        return logged.hasPrefix("a ") ? String(logged.dropFirst(2)) : logged
    }
}

/// Species names as they read inside a sentence.
///
/// Both halves of this are things a user sees in the question that gets sent,
/// so both are worth getting right: "a Aloe vera" and "a boston fern" each read
/// as a bug in a product whose whole pitch is that it knows the plant.
enum SpeciesPhrase {
    /// "a Monstera", "an Aloe vera", "an umbrella plant".
    ///
    /// The stored casing is kept rather than lowercased. Species names arrive
    /// from identification as proper nouns, and lowercasing them mangles the
    /// ones that legitimately carry a capital ("Boston fern", "Swiss cheese
    /// plant") to avoid a mid-sentence capital that reads as merely formal.
    static func indefinite(_ species: String) -> String {
        "\(article(for: species)) \(species)"
    }

    /// Chosen on the opening *sound*, not the opening letter: "Euphorbia" and
    /// "Yucca" both open on a consonantal "y" whatever their spelling says.
    static func article(for word: String) -> String {
        let lower = word.lowercased()
        guard let first = lower.first else { return "a" }
        if lower.hasPrefix("eu") || lower.hasPrefix("uni") || lower.hasPrefix("use") { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }
}

/// Turns a grove into questions worth asking.
///
/// Two kinds of suggestion live here, and the difference matters:
///
/// **Grounded** prompts are generated from something Grove already observed — a
/// band, a trend, a concern from the last assessment, soil that was still wet,
/// care that has gone overdue. They name the plant and they lead the list,
/// because they are the questions only Grove can ask.
///
/// **Evergreen** prompts are the standing repertoire, and they are phrased as
/// questions rather than claims: a person browsing "White fuzz on the soil" out
/// of curiosity must not have "There's white fuzz on my soil" sent on their
/// behalf. The botanist is handed the real grove alongside the question, so a
/// false premise there does not merely waste an answer — it invites the coach
/// to pin an invented symptom on a named plant that is perfectly fine.
enum AskPrompts {

    // MARK: - Per plant

    static func suggestions(
        for plant: Plant,
        tasks: [CareTask] = [],
        observations: [PlantObservation] = [],
        now: Date = .now
    ) -> [AskPrompt] {
        var prompts: [AskPrompt] = []

        let bandPrompt: AskPrompt
        switch plant.healthBand {
        case .urgent, .attention:
            bandPrompt = AskPrompt(
                id: "\(plant.id)-band",
                text: "\(plant.nickname), my \(plant.species), is showing as “\(plant.healthBand.title)”. What should I do first?",
                label: "What do I do first?",
                symbol: "exclamationmark.triangle.fill",
                plantID: plant.id,
                reason: "\(plant.nickname) · \(plant.healthBand.title)"
            )
        case .thriving, .healthy:
            // The band's own word, not a synonym for it. COPY.md fixes the
            // health vocabulary at thriving / healthy / keep an eye on it /
            // needs attention / urgent and allows no other wording "ever" —
            // "doing well" was a sixth way of saying one of five things.
            let band = plant.healthBand.title.lowercased()
            bandPrompt = AskPrompt(
                id: "\(plant.id)-thriving",
                text: "\(plant.nickname) is \(band). What's the most useful thing I can do to keep it that way?",
                label: "How do I keep it \(band)?",
                symbol: "sparkles",
                plantID: plant.id,
                reason: "\(plant.nickname) · \(plant.healthBand.title)"
            )
        case .monitor:
            bandPrompt = AskPrompt(
                id: "\(plant.id)-monitor",
                text: "\(plant.nickname) is marked to keep an eye on. What exactly should I be watching for?",
                label: "What should I watch for?",
                symbol: "eye.fill",
                plantID: plant.id,
                reason: "\(plant.nickname) · \(plant.healthBand.title)"
            )
        }

        // Neither the row nor the question carries the whole finding, and
        // neither needs to: `BotanistContext` already sends every concern
        // verbatim under "Current concerns", so quoting all of it here only
        // repeated it — at four lines in the row, and as a 200-character
        // headline in the prompt rail.
        // A plant adopted by scan carries concerns from that first assessment
        // and has no check-in at all, so naming one asserted an event that had
        // never happened — to the very user least equipped to notice, on day
        // zero, about the word the whole product turns on.
        let hasCheckedIn = observations.contains { $0.plantID == plant.id }
        let concernSource = hasCheckedIn ? "last check-in" : "first scan"
        let concernPrompt = plant.concerns.first.map { concern in
            AskPrompt(
                id: "\(plant.id)-concern",
                text: "\(plant.nickname)'s \(concernSource) flagged “\(AskPhrase.short(concern, limit: 80))”. What causes that, and how do I put it right?",
                label: "What about “\(AskPhrase.short(concern, limit: 30))”?",
                symbol: "stethoscope",
                plantID: plant.id,
                reason: "\(plant.nickname) · Concern in its plant record"
            )
        }

        let latest = observations
            .filter { $0.plantID == plant.id }
            .max { $0.createdAt < $1.createdAt }

        // Something the user themselves recorded, which the band cannot know.
        let wetPrompt: AskPrompt? = latest?.answeredSoilMoisture == .wet
            ? AskPrompt(
                id: "\(plant.id)-wet",
                text: "\(plant.nickname)'s soil was still wet at the last check-in. How long should I leave it before watering again?",
                label: "Soil's still wet, do I wait?",
                symbol: "drop.fill",
                plantID: plant.id,
                reason: "\(plant.nickname) · Wet soil at the last check-in"
            )
            : nil

        let gapPrompt: AskPrompt? = plant.daysUntilCheckIn < 0
            ? AskPrompt(
                id: "\(plant.id)-overdue",
                text: "I haven't checked in on \(plant.nickname) in a while. What should I look at when I do?",
                label: "What should I look for after a gap?",
                symbol: "clock.badge.exclamationmark",
                plantID: plant.id,
                reason: "\(plant.nickname) · Check-in overdue"
            )
            : nil

        let decliningPrompt: AskPrompt? = plant.trend == .declining
            ? AskPrompt(
                id: "\(plant.id)-declining",
                text: "\(plant.nickname) has been trending downwards across its last few check-ins. What's most likely going on?",
                label: "Why is it declining?",
                symbol: "arrow.down.right",
                plantID: plant.id,
                reason: "\(plant.nickname) · Declining health trend"
            )
            : nil

        // A good band does not outrank a live finding. "How do I keep it
        // healthy?" reading above "Some leaves show minor yellowing" is the tab
        // telling the user everything is fine directly above the evidence that
        // it is not — and the plant page shows only the first of these, so
        // anything the band outranks there is unreachable rather than merely
        // demoted. That made the wet-soil question invisible to the overwaterer
        // whose soil was wet, and the after-a-gap question invisible to the
        // user who had been away for six weeks.
        //
        // The one band that genuinely leads is a bad one: when a plant is
        // showing as needs-attention or urgent, "what do I do first?" *is* the
        // live finding.
        let bandLeads = plant.healthBand == .urgent || plant.healthBand == .attention
        if bandLeads { prompts.append(bandPrompt) }

        // Ordered by how directly the user observed it: soil is a fact they
        // entered, a gap is a fact about them, a concern is the assessment's
        // prose, and a trend is an inference across readings.
        if let wetPrompt { prompts.append(wetPrompt) }
        if let gapPrompt { prompts.append(gapPrompt) }
        if let concernPrompt { prompts.append(concernPrompt) }
        if let decliningPrompt { prompts.append(decliningPrompt) }

        if !bandLeads { prompts.append(bandPrompt) }

        // Care the user has let slip. Asking about it is more useful than being
        // reminded again: usually the reason it slipped is that it wasn't clear
        // why it mattered.
        if let overdue = tasks.first(where: { $0.plantID == plant.id && !$0.isCompleted && $0.dueDate < now && $0.kind != .checkIn }) {
            prompts.append(
                AskPrompt(
                    id: "\(plant.id)-overdue-task",
                    text: "“\(overdue.kind.title)” is overdue for \(plant.nickname). Does it still matter, and what happens if I skip it?",
                    label: "Does the overdue \(AskPhrase.careNoun(overdue.kind)) matter?",
                    symbol: "calendar.badge.exclamationmark",
                    plantID: plant.id,
                    reason: "\(plant.nickname) · Care task overdue"
                )
            )
        }

        // "How do I do that?" was the label here, which named nothing: the row
        // sat in a list of questions with no antecedent for "that", so the only
        // way to find out what it meant was to tap it. Planned actions are
        // imperatives ("Move away from the radiator"), so prefixing "Why" turns
        // one straight into the question worth asking — for an action this
        // plain, *why it matters* is the part the user does not already know.
        if let action = plant.nextActions.first {
            prompts.append(
                AskPrompt(
                    id: "\(plant.id)-action",
                    text: "Grove suggested I “\(action.lowercased())” for \(plant.nickname). Why does that matter, and how do I do it properly?",
                    label: "Why \(AskPhrase.short(action.lowercased(), limit: 34))?",
                    symbol: "list.bullet.clipboard.fill",
                    plantID: plant.id,
                    reason: "\(plant.nickname) · Suggested in its care plan"
                )
            )
        }

        // Always available, so a healthy plant with a clean record still offers
        // somewhere to start. Deep enough that refreshing the list keeps finding
        // something new to ask about a plant whose record has gone quiet.
        //
        // Everything below is phrased as a question about the species or about
        // a hypothetical symptom, never as a claim that the symptom is present:
        // the record decides what is wrong with this plant, not the browse list.
        let species = SpeciesPhrase.indefinite(plant.species)
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-light",
                text: "How much light does \(species) actually want, and how would I know it's wrong?",
                label: "How much light?",
                symbol: "sun.max.fill",
                plantID: plant.id
            )
        )
        if !plant.location.isEmpty {
            let place = AskPhrase.inSentence(plant.location)
            prompts.append(
                AskPrompt(
                    id: "\(plant.id)-location",
                    text: "\(plant.nickname) lives in \(place). Is that a good spot for \(species)?",
                    label: "Is \(AskPhrase.short(place, limit: 24)) a good spot?",
                    symbol: "house.fill",
                    plantID: plant.id
                )
            )
        }
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-water",
                text: "How often does \(species) really want watering, and how do I tell when it's thirsty?",
                label: "How often should I water?",
                symbol: "drop.fill",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-repot",
                text: "How do I tell when \(plant.nickname) needs repotting?",
                label: "Does it need repotting?",
                symbol: "arrow.up.bin.fill",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-feed",
                text: "Does \(plant.nickname) need feeding, and what should I use?",
                label: "Should I be feeding it?",
                symbol: "bolt.fill",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-humidity",
                text: "Does \(species) want more humidity than an ordinary room gives it?",
                label: "Does it want humidity?",
                symbol: "humidity.fill",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-pests",
                text: "What are the first signs of pests on \(species), and where should I look?",
                label: "What do pests look like?",
                symbol: "ladybug.fill",
                plantID: plant.id
            )
        )
        // "Where would I cut" is deliberately "how do I decide where to cut":
        // the botanist gets the record, not a photograph, so it can teach the
        // rule but cannot point at a stem.
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-prune",
                text: "Should I be pruning \(plant.nickname), and how do I decide where to cut?",
                label: "Should I prune it?",
                symbol: "scissors",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-propagate",
                text: "Can I propagate \(plant.nickname), and when's the right time to try?",
                label: "Can I propagate it?",
                symbol: "arrow.branch",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-season",
                text: "What changes for \(species) as the seasons turn?",
                label: "What changes by season?",
                symbol: "calendar",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-safety",
                text: "Is \(species) safe to keep around pets and children?",
                label: "Is it safe around pets?",
                symbol: "pawprint.fill",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-yellow",
                text: "What do yellow leaves usually mean on \(species)?",
                label: "Why would leaves yellow?",
                symbol: "leaf.fill",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-brown-tips",
                text: "If \(plant.nickname) gets brown, crispy tips, what's usually behind it?",
                label: "What causes crispy tips?",
                symbol: "flame.fill",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-drooping",
                text: "When \(species) droops, is that usually thirst or too much water?",
                label: "Is drooping thirst or too much?",
                symbol: "arrow.down.to.line",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-soil",
                text: "What potting mix does \(species) actually want?",
                label: "What mix does it want?",
                symbol: "square.stack.3d.down.right.fill",
                plantID: plant.id
            )
        )
        // Grove has no record of the pot, so this asks for the rule rather than
        // a verdict on this plant's pot — a verdict would only be guesswork.
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-pot",
                text: "How do I tell if a pot is too big or too small, and what goes wrong either way?",
                label: "Does pot size matter?",
                symbol: "arrow.up.left.and.arrow.down.right",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-temperature",
                text: "What temperature suits \(species), and does it mind draughts or a radiator nearby?",
                label: "Too hot or too cold?",
                symbol: "thermometer.medium",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-growth",
                text: "How big will \(plant.nickname) get, and how fast should I expect it to grow?",
                label: "How big will it get?",
                symbol: "chart.line.uptrend.xyaxis",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-mistake",
                text: "Which changes in \(plant.nickname) mean I should act now, and which are safe to watch until the next check-in?",
                label: "Which changes need action?",
                symbol: "checklist",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-recovery",
                text: "If \(plant.nickname) has a setback, what would recovery look like over the next few check-ins?",
                label: "How would I know it's recovering?",
                symbol: "heart.fill",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-rotate",
                text: "Should I rotate \(plant.nickname), and how often should I do it?",
                label: "Should I rotate it?",
                symbol: "rotate.right.fill",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-damaged-leaves",
                text: "When should I remove a damaged or yellow leaf from \(plant.nickname), and when should I leave it alone?",
                label: "Should I remove damaged leaves?",
                symbol: "leaf.arrow.triangle.circlepath",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-nursery-pot",
                text: "Can \(plant.nickname) stay in its nursery pot, and what signs mean it needs a different one?",
                label: "Can it stay in its nursery pot?",
                symbol: "shippingbox.fill",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-clean-leaves",
                text: "Do \(plant.nickname)'s leaves need cleaning, and what's the safest way to do it?",
                label: "Should I clean its leaves?",
                symbol: "sparkles",
                plantID: plant.id
            )
        )
        prompts.append(
            AskPrompt(
                id: "\(plant.id)-new-growth",
                text: "What should healthy new growth look like on \(species), and which changes would be a warning sign?",
                label: "Does its new growth look right?",
                symbol: "leaf.fill",
                plantID: plant.id
            )
        )

        return prompts
    }

    // MARK: - Whole grove

    /// - Parameter profile: the onboarding plan is used to order the evergreen
    ///   tail. A user who told Grove that watering is the thing they get wrong
    ///   should not have to page past pot drainage to find it.
    static func groveSuggestions(
        plants: [Plant],
        tasks: [CareTask] = [],
        observations: [PlantObservation] = [],
        profile: UserProfile? = nil,
        now: Date = .now
    ) -> [AskPrompt] {
        guard !plants.isEmpty else {
            return prioritised(beginnerPrompts(), for: profile, using: beginnerFocusMap)
        }

        var grounded: [AskPrompt] = []

        // MARK: Grounded — questions only this grove could ask

        let struggling = plants.filter { $0.healthBand == .urgent || $0.healthBand == .attention }
        if struggling.count > 1 {
            grounded.append(
                AskPrompt(
                    id: "grove-struggling",
                    text: "\(struggling.count) of my plants need attention at once. Where should I start, and could they share a cause?",
                    label: "Which of the \(struggling.count) do I start with?",
                    symbol: "exclamationmark.triangle.fill",
                    plantID: nil,
                    reason: "Recorded health across your grove"
                )
            )
        } else if let only = struggling.first {
            // One plant in trouble used to produce nothing at all here, so the
            // grove list opened on a seasonal reminder while a plant was dying.
            grounded.append(
                AskPrompt(
                    id: "grove-struggling",
                    text: "\(only.nickname) needs attention while the rest of my plants are fine. What should I look at first?",
                    label: "What's wrong with \(only.nickname)?",
                    symbol: "exclamationmark.triangle.fill",
                    plantID: nil,
                    reason: "Recorded health across your grove"
                )
            )
        }

        // Two struggling plants sharing a windowsill is the classic case a
        // per-plant view can never see: the room is the patient, not the plant.
        let strugglingByLocation = Dictionary(grouping: struggling.filter { !$0.location.isEmpty }, by: \.location)
        if let (location, together) = strugglingByLocation
            .filter({ $0.value.count > 1 })
            .min(by: { $0.key < $1.key }) {
            let place = AskPhrase.inSentence(location)
            grounded.append(
                AskPrompt(
                    id: "grove-shared-location",
                    text: "\(together.count) of my plants in \(place) need attention at the same time. Could the spot itself be the problem?",
                    label: "Is \(AskPhrase.short(place, limit: 24)) the problem?",
                    symbol: "house.fill",
                    plantID: nil,
                    reason: "Shared location in your plant records"
                )
            )
        }

        // The same words turning up on two assessments is a pattern; matched
        // case-insensitively because the phrasing comes back from a model.
        let concernCounts = Dictionary(
            grouping: plants.flatMap { $0.concerns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
                .filter { !$0.isEmpty },
            by: { $0.lowercased() }
        )
        if let repeated = concernCounts.filter({ $0.value.count > 1 }).min(by: { $0.key < $1.key })?.value.first {
            grounded.append(
                AskPrompt(
                    id: "grove-repeat-concern",
                    text: "More than one of my plants has the same thing noted: “\(AskPhrase.short(repeated, limit: 80))”. What tends to link that across a grove?",
                    label: "Why “\(AskPhrase.short(repeated, limit: 24))” on two plants?",
                    symbol: "doc.on.doc.fill",
                    plantID: nil,
                    reason: "The same concern appears in several records"
                )
            )
        }

        let declining = plants.filter { $0.trend == .declining }
        if declining.count > 1 {
            grounded.append(
                AskPrompt(
                    id: "grove-declining",
                    text: "\(declining.count) of my plants have been trending downwards. Is that likely to be something I'm doing, or something about my home?",
                    label: "Why are several slipping at once?",
                    symbol: "arrow.down.right",
                    plantID: nil,
                    reason: "Recorded health trends across your grove"
                )
            )
        }

        let overdue = tasks.filter { !$0.isCompleted && $0.dueDate < now && $0.kind != .checkIn }
        if overdue.count > 1 {
            grounded.append(
                AskPrompt(
                    id: "grove-overdue",
                    text: "I've let \(overdue.count) care jobs go overdue across my plants. Which of them actually matter, and which can wait?",
                    label: "Which overdue jobs actually matter?",
                    symbol: "calendar.badge.exclamationmark",
                    plantID: nil,
                    reason: "Unfinished care in your grove"
                )
            )
        }

        // A plant whose record only starts a few weeks ago is a plant that was
        // recently brought home — the settling-in question is real for it, and
        // is left out entirely rather than asserted when nothing qualifies.
        let settledIn = plants.first { plant in
            guard let earliest = observations.filter({ $0.plantID == plant.id }).map(\.createdAt).min() else { return false }
            let age = now.timeIntervalSince(earliest)
            return age >= 0 && age < 21 * 24 * 60 * 60
        }
        if let settledIn {
            grounded.append(
                AskPrompt(
                    id: "grove-settle-in",
                    text: "I brought \(settledIn.nickname) home recently. What should I be doing for it over its first few weeks?",
                    label: "How is \(settledIn.nickname) settling in?",
                    symbol: "bag.fill",
                    plantID: nil,
                    reason: "A plant with recent first check-ins"
                )
            )
        }

        // MARK: Evergreen — the standing repertoire

        var evergreen = evergreenGrovePrompts()
        if settledIn != nil {
            evergreen.removeAll { $0.id == "grove-new-plant" }
        }

        return grounded + prioritised(evergreen, for: profile, using: groveFocusMap)
    }

    /// The standing whole-grove repertoire, ordered so that the questions Grove
    /// can answer better than a search engine — the ones that read the user's
    /// own plant list — come first, followed by the symptoms a keeper is most
    /// likely to be looking at while they hold the phone.
    private static func evergreenGrovePrompts() -> [AskPrompt] {
        [
            AskPrompt(
                id: "grove-priority",
                text: "Looking at my plants' health, recent check-ins and care due, which plant should I check first, and what should I look at?",
                label: "Which plant should I check first?",
                symbol: "checklist",
                plantID: nil,
                    reason: "Your plants’ health, check-ins and care due"
            ),
            AskPrompt(
                id: "grove-water-rhythm",
                text: "Based on each plant's species and recent check-ins and watering, which ones are most at risk of too much or too little water?",
                label: "Which watering needs attention?",
                symbol: "drop.fill",
                plantID: nil,
                    reason: "Species and recent moisture readings"
            ),
            AskPrompt(
                id: "grove-light-move",
                text: "Looking at where each plant lives, which one is most likely to be in the wrong light?",
                label: "Is any plant in the wrong light?",
                symbol: "sun.max.fill",
                plantID: nil,
                    reason: "Locations saved in your plant records"
            ),
            AskPrompt(
                id: "grove-pets",
                text: "Which of my plants are unsafe around pets or children?",
                label: "Which of mine are unsafe for pets?",
                symbol: "pawprint.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-yellow-leaves",
                text: "If one of my plants gets yellow leaves, how would I narrow down the cause from its care and check-ins?",
                label: "How do I read yellow leaves?",
                symbol: "leaf.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-drooping",
                text: "When one of my plants droops, how do I tell whether it is thirsty or its roots are staying wet?",
                label: "Is drooping thirst or drowning?",
                symbol: "arrow.down.to.line",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-brown-tips",
                text: "If one of my plants gets brown, crispy tips, what should I check before changing its care?",
                label: "What should I check for brown tips?",
                symbol: "flame.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-growth",
                text: "Which of my plants has slowed down unexpectedly, and when is a pause in growth normal?",
                label: "Has any plant stopped growing?",
                symbol: "chart.line.uptrend.xyaxis",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-pests",
                text: "Which of my plants should I inspect first for pests, where should I look, and how do I stop them spreading?",
                label: "Where should I look for pests?",
                symbol: "ladybug.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-gnats",
                text: "What are the little flies that rise from potting mix after watering, and how do I break their life cycle?",
                label: "How do I get rid of fungus gnats?",
                symbol: "ant.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-soil-mould",
                text: "What is the white growth that can appear on potting mix, and when does it need action?",
                label: "Does white growth on soil matter?",
                symbol: "circle.hexagongrid.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-repot-season",
                text: "Which of my plants is most likely to need repotting next, and what signs should I confirm first?",
                label: "Which plant needs repotting next?",
                symbol: "arrow.up.bin.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-feed",
                text: "Which of my plants are likely to need feeding now, and which should I leave alone?",
                label: "Which plants should I feed?",
                symbol: "bolt.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-drainage",
                text: "Which of my plants is most at risk from a pot without drainage, and what is the safest fix?",
                label: "Which pots need better drainage?",
                symbol: "circle.grid.3x3.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-soil",
                text: "Do any of my plants need a different potting mix from the others, and what should each mix do?",
                label: "Which plants need different soil?",
                symbol: "square.stack.3d.down.right.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-temperature",
                text: "Which of my plants are most sensitive to a cold window, draught or radiator?",
                label: "Which plants mind heat or cold?",
                symbol: "thermometer.medium",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-humidity",
                text: "Is the air in my home too dry for any of my plants, and what would make a useful difference?",
                label: "Which plants need more humidity?",
                symbol: "humidity.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-water-quality",
                text: "Which of my plants are sensitive to tap water, and when is filtered or rainwater worth using?",
                label: "Which plants mind tap water?",
                symbol: "spigot.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-prune-all",
                text: "Which of my plants would benefit from pruning, and what would I be trying to improve?",
                label: "Which plants need pruning?",
                symbol: "scissors",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-propagate-all",
                text: "Which of my plants can I propagate reliably, and what is the simplest method for each?",
                label: "Which plants can I propagate?",
                symbol: "arrow.branch",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-season",
                text: "What should change in my plants' care at this time of year, and what should stay the same?",
                label: "What care changes this season?",
                symbol: "calendar",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-grow-lights",
                text: "Which of my plants would genuinely benefit from a grow light, and how should I position it?",
                label: "Which plants need a grow light?",
                symbol: "lightbulb.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-away",
                text: "If I leave my plants for a fortnight, which ones need help and which can manage on their own?",
                label: "Which plants need care while away?",
                symbol: "suitcase.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-new-plant",
                text: "How should I settle a new plant in without bringing pests into the rest of my grove?",
                label: "How do I settle a new plant in?",
                symbol: "bag.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-next",
                text: "Given the plants I already keep and the conditions in my home, what would be a good plant to add next?",
                label: "Which plant fits my grove next?",
                symbol: "plus.circle.fill",
                plantID: nil
            )
        ]
    }

    private static func beginnerPrompts() -> [AskPrompt] {
        [
            AskPrompt(
                id: "grove-first-water",
                text: "How do I check whether a plant's soil is ready for water instead of watering on a schedule?",
                label: "How do I know when to water?",
                symbol: "drop.triangle.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first",
                text: "Which houseplants suit the light in my home and the amount of care I can give?",
                label: "Which plant fits my home?",
                symbol: "leaf.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-light-basics",
                text: "How do I judge the usable light in a spot from its window direction, distance and hours of sun?",
                label: "How much light does this spot get?",
                symbol: "sun.max.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-buying",
                text: "What should I check on the leaves, stems, soil and roots before buying a plant?",
                label: "How do I choose a healthy plant?",
                symbol: "cart.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-pets",
                text: "Which easy houseplants are safe around pets or children, and which common ones should I avoid?",
                label: "Which plants are safe around pets?",
                symbol: "pawprint.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-arrival",
                text: "What should I do with a new plant during its first week at home?",
                label: "What should I do in the first week?",
                symbol: "bag.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-water-basics",
                text: "What are the clearest signs that I am watering too often, and what should I do first?",
                label: "How can I spot overwatering?",
                symbol: "drop.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-water-method",
                text: "How do I water a pot thoroughly without leaving the roots sitting wet?",
                label: "What's the right way to water?",
                symbol: "drop.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-drainage",
                text: "Why does a pot need drainage, and what can I do if the decorative pot has no hole?",
                label: "Why does drainage matter?",
                symbol: "circle.grid.3x3.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-light-signs",
                text: "What does too little or too much light look like on a plant?",
                label: "How does wrong light show up?",
                symbol: "sun.min.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-soil",
                text: "How do I tell whether potting mix holds too much water for a plant?",
                label: "Is the potting mix staying too wet?",
                symbol: "square.stack.3d.down.right.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-feed",
                text: "When does a houseplant need feeding, and when can fertiliser make things worse?",
                label: "When should I feed a plant?",
                symbol: "bolt.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-humidity",
                text: "Which plants need extra humidity, and does misting actually help?",
                label: "Does misting actually help?",
                symbol: "humidity.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-yellow",
                text: "When a leaf turns yellow, what should I check before changing the plant's care?",
                label: "What should I check for yellow leaves?",
                symbol: "leaf.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-droop",
                text: "How do I tell whether a drooping plant is thirsty or has stayed wet for too long?",
                label: "Is drooping thirst or wet roots?",
                symbol: "arrow.down.to.line",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-brown",
                text: "What causes brown, crispy leaf tips, and what should I check first?",
                label: "What causes crispy leaf tips?",
                symbol: "flame.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-root-rot",
                text: "What are the early signs of root rot, and what should I do before repotting?",
                label: "How do I spot root rot early?",
                symbol: "stethoscope",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-pests",
                text: "Where should I check a new plant for pests, and how long should I keep it apart from the others?",
                label: "How do I check a new plant for pests?",
                symbol: "ladybug.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-growth",
                text: "When is slow or stopped growth normal, and which other signs mean something is wrong?",
                label: "When is slow growth a problem?",
                symbol: "chart.line.uptrend.xyaxis",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-repot",
                text: "Should I repot a plant as soon as I bring it home, and what signs mean it cannot wait?",
                label: "Should I repot it straight away?",
                symbol: "arrow.up.bin.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-spot",
                text: "How close to a window should I put a plant without scorching or starving it of light?",
                label: "How close to the window?",
                symbol: "house.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-dark-room",
                text: "Which plants genuinely cope with low light, and what does low light do to their watering needs?",
                label: "What genuinely copes with low light?",
                symbol: "moon.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-winter",
                text: "What should change in a houseplant's care when winter brings less light and slower growth?",
                label: "What care changes in winter?",
                symbol: "snowflake",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-effort",
                text: "How often should I check a houseplant, and what should I look at each time?",
                label: "How often should I check a plant?",
                symbol: "clock.fill",
                plantID: nil
            ),
            AskPrompt(
                id: "grove-first-away",
                text: "How should I prepare a houseplant to manage without me for a fortnight?",
                label: "How do I leave a plant for a fortnight?",
                symbol: "suitcase.fill",
                plantID: nil
            )
        ]
    }

    // MARK: - The plan the user built

    /// Onboarding makes the user name their three worst problems and their main
    /// challenge. Asking for that and then ignoring it is worse than not asking:
    /// the questions they said they needed should be the ones on the first page.
    private static let groveFocusMap: [String: [String]] = [
        "watering": ["grove-water-rhythm", "grove-drooping", "grove-water-quality"],
        "pests": ["grove-pests", "grove-gnats"],
        "leaves": ["grove-yellow-leaves", "grove-brown-tips", "grove-drooping"],
        "light": ["grove-light-move", "grove-grow-lights"],
        "away": ["grove-away"],
        "repot": ["grove-repot-season", "grove-soil", "grove-drainage"],
        "slow-death": ["grove-growth", "grove-yellow-leaves"],
        "unknown-needs": ["grove-pets", "grove-feed"],
        "revive": ["grove-yellow-leaves", "grove-growth"],
        "forget": ["grove-water-rhythm", "grove-season"],
        "id": ["grove-pets", "grove-next"]
    ]

    private static let beginnerFocusMap: [String: [String]] = [
        "watering": ["grove-water-basics", "grove-first-water"],
        "light": ["grove-light-basics", "grove-first-dark-room", "grove-first-spot"],
        "pests": ["grove-first-pests"],
        "leaves": ["grove-first-yellow", "grove-first-droop", "grove-first-brown"],
        "repot": ["grove-first-repot"],
        "id": ["grove-first-pets", "grove-first"],
        "unknown-needs": ["grove-first", "grove-first-water", "grove-light-basics"],
        "slow-death": ["grove-first-growth", "grove-first-root-rot"],
        "revive": ["grove-first-root-rot", "grove-first-yellow"],
        "away": ["grove-first-away"],
        "forget": ["grove-first-effort"]
    ]

    /// Stable partition: prompts the user's plan points at keep their relative
    /// order and move to the front, everything else keeps its order behind them.
    /// Rotation still reaches the whole pool — this only decides what page one is.
    private static func prioritised(
        _ prompts: [AskPrompt],
        for profile: UserProfile?,
        using map: [String: [String]]
    ) -> [AskPrompt] {
        guard let plan = profile?.plan, !plan.isEmpty else { return prompts }
        var keys = plan.focuses
        if let challenge = plan.challenge { keys.append(challenge) }
        let preferred = Set(keys.flatMap { map[$0] ?? [] })
        guard !preferred.isEmpty else { return prompts }
        return prompts.filter { preferred.contains($0.id) } + prompts.filter { !preferred.contains($0.id) }
    }

    // MARK: - The four-page catalogue

    /// How many suggestions the Ask tab shows at once.
    static let pageSize = 6

    /// Four small pages are deep enough to cover diagnosis, everyday care,
    /// environment and longer-term growth without turning Ask into an endless
    /// directory. Grounded and plan-matched questions keep their priority because
    /// this trims only the tail of the already-ranked pool.
    static let pageCount = 4
    static let suggestionLimit = pageSize * pageCount

    /// The exact question catalogue shown under "Worth asking".
    ///
    /// An optional excluded prompt lets another surface reserve a question
    /// before the 24-question limit is applied. Stable de-duplication protects the
    /// four pages if two future grounding rules happen to produce the same id.
    static func curated(_ prompts: [AskPrompt], excluding excludedID: String? = nil) -> [AskPrompt] {
        var seen = Set<String>()
        var result: [AskPrompt] = []
        for prompt in prompts where prompt.id != excludedID {
            guard seen.insert(prompt.id).inserted else { continue }
            result.append(prompt)
            if result.count == suggestionLimit { break }
        }
        return result
    }

    /// One page of a suggestion pool, wrapping round at the end.
    ///
    /// Refresh rotates rather than reshuffles. The pool is ordered by how much
    /// the plant needs the answer, so rotating keeps that order intact within a
    /// page, never shows a short final page, and always comes back round to the
    /// question the tab opened on.
    static func page(_ prompts: [AskPrompt], page: Int, size: Int = pageSize) -> [AskPrompt] {
        guard !prompts.isEmpty, size > 0 else { return [] }
        guard prompts.count > size else { return prompts }
        let stride = page * size
        // `%` keeps the sign of its left operand in Swift, so a negative page
        // would otherwise index backwards off the front.
        let start = ((stride % prompts.count) + prompts.count) % prompts.count
        return Array((prompts[start...] + prompts[..<start]).prefix(size))
    }

    // MARK: - The daily question

    /// The one question offered on the Ask tab each day.
    ///
    /// Stable within a calendar day so the card does not change under the user
    /// between launches, and priority-ordered so a plant in trouble always beats
    /// a rotation pick — the daily habit should point at whatever most needs a
    /// person to look at it.
    static func daily(
        plants: [Plant],
        tasks: [CareTask] = [],
        observations: [PlantObservation] = [],
        profile: UserProfile? = nil,
        now: Date = .now,
        selectionDay: Date? = nil,
        timeZone: TimeZone = .current
    ) -> AskPrompt {
        // `selectionDay` is observable UI state supplied by the store. `now`
        // remains the real instant used to decide whether care is overdue.
        let day = dayIndex(selectionDay ?? now, timeZone: timeZone)
        guard !plants.isEmpty else {
            let general = groveSuggestions(plants: [], profile: profile, now: now)
            return general[wrappedIndex(day, count: general.count)]
        }

        let bandOrder: [HealthBand: Int] = [.urgent: 0, .attention: 1, .monitor: 2, .healthy: 3, .thriving: 4]
        func priority(of plant: Plant) -> Int {
            // Band is the primary signal. A declining trend breaks a tie inside
            // the same band without allowing a healthy-but-declining plant to
            // displace one whose current band is already urgent.
            (bandOrder[plant.healthBand] ?? 5) * 2 + (plant.trend == .declining ? 0 : 1)
        }

        // Plants that need a person, worst situation first. Only equally urgent
        // situations rotate with one another: a lingering urgent plant should
        // not disappear from the card merely because an attention plant also
        // exists. When nothing needs intervention, the whole grove rotates.
        let ranked = plants.sorted { lhs, rhs in
            let lhsRank = priority(of: lhs)
            let rhsRank = priority(of: rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let needsAttention = ranked.filter { $0.healthBand == .urgent || $0.healthBand == .attention || $0.trend == .declining }
        let pool: [Plant]
        if let mostPressing = needsAttention.first {
            let highestPriority = priority(of: mostPressing)
            pool = needsAttention.filter { priority(of: $0) == highestPriority }
        } else {
            pool = ranked
        }

        let plant = pool[wrappedIndex(day, count: pool.count)]
        let prompts = suggestions(for: plant, tasks: tasks, observations: observations, now: now)
        // Advance the prompt only after every plant in the current cohort has
        // had a turn. Using `day` for both indexes coupled the two rotations:
        // with two plants and an even prompt count, each plant could see only
        // half its questions forever.
        let promptCycle = floorDivision(day, by: pool.count)
        return prompts[wrappedIndex(promptCycle, count: prompts.count)]
    }

    /// An absolute local Gregorian day, stable across DST and consecutive across
    /// leap days and year boundaries. The old `year * 366 + ordinalDay` skipped
    /// an index after every non-leap year and inherited non-Gregorian calendars.
    private static func dayIndex(_ date: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let epoch = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1)) else {
            return 0
        }
        return calendar.dateComponents(
            [.day],
            from: epoch,
            to: calendar.startOfDay(for: date)
        ).day ?? 0
    }

    /// Swift's remainder keeps the sign of the dividend. Normalising it keeps
    /// the selector valid for dates before the reference epoch as well.
    private static func wrappedIndex(_ value: Int, count: Int) -> Int {
        precondition(count > 0)
        return ((value % count) + count) % count
    }

    /// Mathematical floor division, paired with `wrappedIndex` for pre-epoch
    /// dates where Swift's integer division would otherwise round toward zero.
    private static func floorDivision(_ value: Int, by divisor: Int) -> Int {
        precondition(divisor > 0)
        let quotient = value / divisor
        let remainder = value % divisor
        return remainder < 0 ? quotient - 1 : quotient
    }
}
