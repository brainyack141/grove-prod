import Foundation

/// How often a plant should be watered, and the reasons behind it.
///
/// The plant page's one watering number: the board's Water-every cell and the
/// journey bar both read it. It is the sum `SoilDryDown` does for the pot and
/// the season, carried one step further: what the last diagnosis saw in the
/// plant itself. The sheet behind the board cell
/// reads it back as a sentence: the suggestion, then "because", then what the
/// plant needs, the season where it lives, and what its pot and soil are like.
///
/// The steps are the dry-down's own factors applied one at a time, with the
/// same damping, so the season, pot and light part lands where
/// `SoilDryDown.days` does. Each line's effect is the change in the *rounded* running total,
/// which is what makes the lines add up to the suggestion exactly. A
/// condition that moved nothing gets no line, except the season: "it's summer
/// where you are" is a reason the number is what it is, even at no change.
struct PlantWateringEstimate: Equatable {
    struct Step: Identifiable, Equatable {
        enum Effect: Equatable {
            /// The baseline every later line bends. The title already says it.
            case start(days: Int)
            /// Whole days this line moved the gap. Zero shows no figure.
            case change(days: Int)
        }

        let id: String
        /// One plain fact: "It's autumn in the United Kingdom".
        let title: String
        /// Why that fact matters, or what it rests on, when it isn't obvious.
        let note: String?
        let effect: Effect
    }

    /// The one thing that would make the estimate firmer, when there is one.
    enum Sharpen: Equatable {
        /// The pot has never been seen, or most of it couldn't be made out.
        case showPot
        /// Nobody has said where the plant stands.
        case setLight
    }

    let days: Int
    let steps: [Step]
    let sharpen: Sharpen?
    /// A pot water cannot leave. The schedule is the lesser problem there.
    let drainageWarning: String?

    var value: String { "\(days) days" }

    init(
        plant: Plant,
        read: PlantStateRead,
        readAge: String?,
        location: GroveLocation?,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        let profile = PlantCareProfile(plant: plant)
        let dryDown = SoilDryDown(plant: plant, location: location, now: now)
        let conditions = plant.growingConditions

        var running = profile.referenceWateringDays
        var shown = Self.whole(running)
        /// Applies one factor and returns how far the rounded total moved.
        func apply(_ factor: Double, damped: Bool) -> Int {
            running *= damped ? pow(factor, SoilDryDown.damping) : factor
            let next = Self.whole(running)
            defer { shown = next }
            return next - shown
        }

        var steps: [Step] = []
        /// Keeps a condition only when it moved the number.
        func add(_ id: String, _ title: String, note: String? = nil, change: Int) {
            guard change != 0 else { return }
            steps.append(Step(id: id, title: title, note: note, effect: .change(days: change)))
        }

        // What the plant needs. The figure is in the sentence, so the row
        // carries no number of its own.
        let name = PlantIdentityState.isPlaceholderName(plant.species) ? "A typical houseplant" : plant.species
        steps.append(Step(
            id: "species",
            title: "\(name) needs water about every \(shown) days",
            note: profile.matchedSpecies ? nil : "A safe guess. There's no checked care guide for it yet.",
            effect: .start(days: shown)
        ))

        // The season, from the grove's latitude. A guessed hemisphere flips the
        // advice completely, so no location means no season line at all.
        if plant.effectiveLifecycleState == .dormant {
            add(
                "season",
                "You marked it as resting",
                note: "A resting plant drinks less",
                change: apply(Self.seasonFactor(.dormancy), damped: false)
            )
        } else if let location {
            let season = PlantSeasonAdvisory.season(at: location.latitude, on: now, calendar: calendar)
            let change = apply(Self.seasonFactor(season), damped: false)
            steps.append(Step(
                id: "season",
                title: "It's \(Self.seasonName(latitude: location.latitude, on: now, calendar: calendar)) in \(Self.place(location))",
                note: Self.seasonNote(season),
                effect: .change(days: change)
            ))
        }

        // Light the owner never set is counted as a bright window, the
        // neutral factor. That guess is the sharpen action, not a line.
        let lightChange = apply(SoilDryDown.lightFactor(dryDown.light), damped: true)
        if let light = dryDown.light {
            let source = plant.lightPlacement == nil ? "Going by the room it's in" : nil
            let rain = light == .outdoors ? "Rain isn't counted" : nil
            add(
                "light",
                Self.lightTitle(light),
                note: [source, rain].compactMap { $0 }.joined(separator: ". ").nilIfEmpty,
                change: lightChange
            )
        }

        // The pot: size, material, mix, drainage and fit, as one line because
        // they are one object in the photo. An unseen pot applies the neutral
        // factors and moves nothing, so it shows up as the sharpen action.
        let potFactor = SoilDryDown.sizeFactor(conditions?.potSize) *
            SoilDryDown.materialFactor(conditions?.potMaterial) *
            SoilDryDown.substrateFactor(conditions?.substrate) *
            SoilDryDown.drainageFactor(conditions?.drainage) *
            SoilDryDown.fitFactor(conditions?.potFit)
        let potChange = apply(potFactor, damped: true)
        if let conditions {
            add("pot", Self.potTitle(conditions), note: Self.potNote(conditions), change: potChange)
        }

        // The soil surface, by its strongest sign.
        let signs = conditions?.surfaceSigns ?? []
        let surfaceFactor = SoilDryDown.surfaceFactor(signs)
        if surfaceFactor != 1,
           let strongest = signs.max(by: {
               abs(SoilDryDown.surfaceFactor([$0]) - 1) < abs(SoilDryDown.surfaceFactor([$1]) - 1)
           }) {
            add("soil", Self.surfaceTitle(strongest), change: apply(surfaceFactor, damped: true))
        }

        let when = readAge ?? "at its last check-in"
        switch read {
        case .dehydrated:
            add("ari", "It looked thirsty \(when)", change: apply(Self.readFactor(read), damped: false))
        case .waterlogged:
            add("ari", "It looked overwatered \(when)", change: apply(Self.readFactor(read), damped: false))
        case .flourishing, .comfortable, .stressed, .unassessed:
            break
        }

        self.days = shown
        self.steps = steps

        let potUnread = conditions == nil || dryDown.unknownInputs >= 2
        if potUnread {
            self.sharpen = .showPot
        } else if dryDown.light == nil {
            self.sharpen = .setLight
        } else {
            self.sharpen = nil
        }

        switch conditions?.drainage {
        case .cachepot:
            self.drainageWarning = "It sits in a cover. Tip out any water that collects there after watering."
        case .noHoles:
            self.drainageWarning = "Its pot has no drainage holes. Give less water each time until it's repotted."
        default:
            self.drainageWarning = signs.contains(.standingWater)
                ? "Water was standing on the soil in the last photo. Let it drain before you water again."
                : nil
        }
    }

    // MARK: - Factors

    /// Days on the board are whole, and never shorter than three or longer
    /// than forty: the same bounds `SoilDryDown` keeps.
    private static func whole(_ days: Double) -> Int {
        Int(min(40, max(3, days)).rounded())
    }

    /// Species baselines are growing-season advice ("less in winter"), so the
    /// growing season leaves them alone and the rest of the year stretches
    /// them. Not doubled for winter: central heating dries a pot too.
    static func seasonFactor(_ season: PlantSeasonAdvisory.Season) -> Double {
        switch season {
        case .activeGrowth: 1
        case .shoulder: 1.15
        case .dormancy: 1.4
        }
    }

    /// Ari's read nudges rather than steers. Thirst can be one missed watering
    /// as easily as a gap that is too long, so the correction stays small.
    static func readFactor(_ read: PlantStateRead) -> Double {
        switch read {
        case .dehydrated: 0.85
        case .waterlogged: 1.2
        case .flourishing, .comfortable, .stressed, .unassessed: 1
        }
    }

    // MARK: - Copy

    /// The calendar season, by hemisphere. The factor comes from
    /// `PlantSeasonAdvisory`, which groups months by light rather than by
    /// equinox; this is only the word people use for the time of year.
    private static func seasonName(latitude: Double, on date: Date, calendar: Calendar) -> String {
        let month = calendar.component(.month, from: date)
        let northern: String
        switch month {
        case 3...5: northern = "spring"
        case 6...8: northern = "summer"
        case 9...11: northern = "autumn"
        default: northern = "winter"
        }
        guard latitude < 0 else { return northern }
        switch northern {
        case "spring": return "autumn"
        case "summer": return "winter"
        case "autumn": return "spring"
        default: return "summer"
        }
    }

    /// The country, because seasons belong to it rather than to a street.
    /// Falls back to the town when the country can't be named.
    private static func place(_ location: GroveLocation) -> String {
        let fromCode = location.countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) }
        let fromLabel = location.label.contains(",")
            ? location.label.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) }
            : nil
        guard let country = fromCode ?? fromLabel, !country.isEmpty else { return location.shortLabel }
        let needsArticle = country.hasPrefix("United ")
            || country.hasSuffix(" Republic")
            || country.hasSuffix(" Islands")
            || ["Netherlands", "Philippines", "Bahamas", "Gambia", "Maldives"].contains(country)
        return needsArticle ? "the \(country)" : country
    }

    private static func seasonNote(_ season: PlantSeasonAdvisory.Season) -> String {
        switch season {
        case .dormancy: "Shorter, cooler days slow drying"
        case .shoulder: "Soil dries slower than in summer"
        case .activeGrowth: "Soil dries at its usual pace"
        }
    }

    private static func lightTitle(_ light: PlantLightPlacement) -> String {
        switch light {
        case .sill: "It sits on a windowsill"
        case .shaded: "It sits away from the window"
        case .outdoors: "It lives outdoors"
        case .bright: "It sits near a bright window"
        }
    }

    /// The pot as a plain fact: "It's in a plastic pot, 12–20cm across".
    private static func potTitle(_ conditions: PlantGrowingConditions) -> String {
        let material: String
        switch conditions.potMaterial {
        case .unpotted: return "It isn't in a pot"
        case .terracotta: material = "terracotta pot"
        case .plastic: material = "plastic pot"
        case .glazed: material = "glazed pot"
        case .metal: material = "metal pot"
        case .fabric: material = "fabric pot"
        case .concrete: material = "concrete pot"
        case .unknown: material = "pot"
        }
        switch conditions.potSize {
        case .small: return "It's in a \(material), under 12cm across"
        case .medium: return "It's in a \(material), 12–20cm across"
        case .large: return "It's in a \(material), 20–30cm across"
        case .xlarge: return "It's in a \(material), over 30cm across"
        case .unknown: return material == "pot" ? "Its pot, from your photo" : "It's in a \(material)"
        }
    }

    /// The rest of what the photo showed: cover, mix, fit.
    private static func potNote(_ conditions: PlantGrowingConditions) -> String? {
        var parts: [String] = []
        switch conditions.drainage {
        case .cachepot: parts.append("inside a cover")
        case .noHoles: parts.append("no drainage holes")
        case .drains, .unknown: break
        }
        switch conditions.substrate {
        case .gritty: parts.append("gritty mix")
        case .bark: parts.append("chunky bark mix")
        case .dense: parts.append("dense soil")
        case .moss: parts.append("moss")
        case .semiHydro: parts.append("semi-hydro")
        case .standard: parts.append("standard compost")
        case .unknown: break
        }
        switch conditions.potFit {
        case .oversized: parts.append("roomy for the roots")
        case .snug: parts.append("snug around the roots")
        case .balanced, .unknown: break
        }
        guard let first = parts.first else { return nil }
        parts[0] = first.prefix(1).uppercased() + first.dropFirst()
        return parts.joined(separator: ", ")
    }

    private static func surfaceTitle(_ sign: PlantGrowingConditions.SurfaceSign) -> String {
        switch sign {
        case .standingWater: "Water is pooling on the soil"
        case .algae: "There's algae on the soil"
        case .mould: "There's mould on the soil"
        case .fungusGnats: "There are fungus gnats in the soil"
        case .moss: "There's moss on the soil"
        case .compacted: "The soil looks packed down"
        case .topDressed: "It has a top layer of pebbles or bark"
        case .rootsAtSurface: "Roots are showing at the surface"
        case .hydrophobic: "The soil has pulled away from the pot"
        case .saltCrust: "There's a mineral crust on the soil"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
