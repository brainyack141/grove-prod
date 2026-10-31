import Foundation

/// Compact, offline care baselines for species Grove has checked.
///
/// Ten species currently have curated display guidance. Broad family
/// fallbacks still give `SoilDryDown` a deliberately uncertain starting point,
/// but `matchedSpecies` keeps those estimates from being presented as a checked
/// care guide for the species in front of the owner.
///
/// Lives on its own because two screens read it now: the plant page's care
/// guide and the scan card's Light · Water · Humidity row — which needs a
/// baseline the instant a name lands, before any server round-trip.
struct PlantCareProfile {
    struct Reference: Identifiable, Hashable {
        let id: String
        let publisher: String
        let title: String
        let url: URL
    }

    enum LightPreference: Hashable {
        /// Bright light filtered by glass or distance from the window.
        case brightIndirect
        /// As much indoor light as practical, with protection from harsh heat.
        case veryBright
        /// Grows best with good light, while remaining healthy in a dimmer spot.
        case adaptablePrefersBright
        /// No checked species-specific light requirement is held.
        case unknown
    }

    let light: String
    let lightPreference: LightPreference
    let temperature: String
    let humidity: String
    private(set) var watering: String
    /// The watering fact at card size — same advice, fewer words.
    private(set) var wateringShort: String
    private(set) var fertilising: String
    private(set) var repotting: String
    /// The accepted taxon this copy was reviewed for. Nil means the values are
    /// internal dry-down estimates and must never be presented as species care.
    let reviewedScientificName: String?
    let references: [Reference]
    /// Days this family goes between waterings **in a reference pot**: a 12–20cm
    /// plastic pot of standard compost that drains freely, a step back from a
    /// bright window.
    ///
    /// The strings above are the advice; this is the arithmetic behind
    /// `SoilDryDown`, which bends it by what the scan saw of the actual pot. Both
    /// come from one place so the care guide and the watering card can never
    /// quote different intervals for the same plant.
    let referenceWateringDays: Double
    /// False when this is a broad-family estimate rather than a checked profile
    /// for the species in front of the owner.
    ///
    /// Other Ficus species, anthurium, philodendron, alocasia and most of what
    /// a collector owns still need the fallback for cautious dry-down
    /// arithmetic. The care guide must not turn that arithmetic into attributed
    /// species advice.
    var matchedSpecies: Bool = true

    /// The light guidance at a glance: the first segment of `light`, with the
    /// one phrase beginners most often have to decode spelled out.
    var lightHeadline: String {
        let headline = light
            .components(separatedBy: ";")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? light
        switch headline {
        case "Bright, indirect":
            return "Near a bright window, out of direct sun"
        default:
            return headline
        }
    }

    /// Updated only after every care URL and every displayed claim have been
    /// checked against the live publisher page.
    static let sourcesReviewedOn = "4 September 2026"

    init(plant: Plant) {
        self.init(commonName: plant.species, scientificName: plant.scientificName)
    }

    init(commonName: String, scientificName: String) {
        let scientificIdentity = Self.normalizedScientificName(scientificName)
        let fallbackIdentity = "\(commonName) \(scientificName)".lowercased()

        if Self.snakePlantScientificNames.contains(scientificIdentity) {
            self = .snakePlant
        } else if Self.stringOfPearlsScientificNames.contains(scientificIdentity) {
            self = .stringOfPearls
        } else if Self.birdOfParadiseScientificNames.contains(scientificIdentity) {
            self = .birdOfParadise
        } else if Self.monsteraScientificNames.contains(scientificIdentity) {
            self = .monstera
        } else if Self.pothosScientificNames.contains(scientificIdentity) {
            self = .goldenPothos
        } else if Self.fiddleLeafFigScientificNames.contains(scientificIdentity) {
            self = .fiddleLeafFig
        } else if Self.peaceLilyScientificNames.contains(scientificIdentity) {
            self = .peaceLily
        } else if Self.aloeVeraScientificNames.contains(scientificIdentity) {
            self = .aloeVera
        } else if Self.roundLeafCalatheaScientificNames.contains(scientificIdentity) {
            self = .roundLeafCalathea
        } else if Self.prayerPlantScientificNames.contains(scientificIdentity) {
            self = .prayerPlant
        } else if Self.isForestCactus(fallbackIdentity) {
            // Christmas, Easter and Thanksgiving cacti are rainforest
            // epiphytes that want the top of the soil just dry. Matching
            // "cactus" put them on the desert profile: a gap three times too
            // long. The everyday houseplant gap is the honest fallback.
            self = .generalHouseplant
        } else if fallbackIdentity.contains("cactus")
                    || fallbackIdentity.contains("succulent")
                    || fallbackIdentity.contains("aloe")
                    || fallbackIdentity.contains("echeveria")
                    || fallbackIdentity.contains("haworthia") {
            self = .generalSucculent
        } else if fallbackIdentity.contains("fern")
                    || fallbackIdentity.contains("calathea")
                    || fallbackIdentity.contains("maranta")
                    || fallbackIdentity.contains("peace lily")
                    || fallbackIdentity.contains("spathiphyllum") {
            self = .generalHumidityLover
        } else {
            self = .generalHouseplant
        }
    }

    /// A stable light-fit score must come from structured care data, never from
    /// searching words in the user-facing copy. In particular, a snake plant
    /// *tolerates* low light; that does not make a dark corner its best spot.
    func lightFitScore(for placement: PlantLightPlacement) -> Int? {
        switch lightPreference {
        case .brightIndirect:
            switch placement {
            case .bright: 92
            case .sill: 78
            case .outdoors: 72
            case .shaded: 52
            }
        case .veryBright:
            switch placement {
            case .sill, .outdoors: 92
            case .bright: 84
            case .shaded: 48
            }
        case .adaptablePrefersBright:
            switch placement {
            case .bright: 92
            case .sill: 86
            case .outdoors: 78
            case .shaded: 68
            }
        case .unknown:
            nil
        }
    }

    // RHS: How to grow Swiss cheese plants.
    private static let monstera = PlantCareProfile(
        light: "Bright, indirect; avoid harsh sun",
        lightPreference: .brightIndirect,
        temperature: "18–25°C; avoid draughts",
        humidity: "Moderate; dry air can brown edges",
        watering: "Almost dry; soak; less in winter",
        wateringShort: "Almost dry; then soak",
        fertilising: "Balanced feed, April–September",
        repotting: "When root-bound; use a stable pot",
        reviewedScientificName: "Monstera deliciosa",
        references: [rhsMonstera],
        referenceWateringDays: 9
    )

    // RHS: How to grow strelitzia.
    private static let birdOfParadise = PlantCareProfile(
        light: "Very bright; shade hot midday sun",
        lightPreference: .veryBright,
        temperature: "Warm; never below 10–12°C",
        humidity: "Humid; give airflow when hot",
        watering: "Moist, not sodden; drier in winter",
        wateringShort: "Moist, not sodden",
        fertilising: "Liquid feed fortnightly in growth",
        repotting: "Spring when root-filled; size up",
        reviewedScientificName: "Strelitzia reginae",
        references: [rhsBirdOfParadise],
        referenceWateringDays: 9
    )

    // RHS: How to grow sansevierias.
    private static let snakePlant = PlantCareProfile(
        light: "Bright shade; low light is tolerated",
        lightPreference: .adaptablePrefersBright,
        temperature: "15–24°C; avoid cold draughts",
        humidity: "Low; never mist",
        watering: "Dry fully; barely water in winter",
        wateringShort: "Dry fully; less in winter",
        fertilising: "Monthly, April–September",
        repotting: "Only when pot is full or buckling",
        reviewedScientificName: "Dracaena trifasciata",
        references: [rhsSnakePlant],
        referenceWateringDays: 26
    )

    // RHS and University of Wisconsin Extension: String of pearls.
    private static let stringOfPearls = PlantCareProfile(
        light: "Bright; several hours of direct sun",
        lightPreference: .veryBright,
        temperature: "10–25°C; avoid cold draughts",
        humidity: "Low; avoid damp air",
        watering: "Dry fully; winter only if shrivelling",
        wateringShort: "Dry fully; watch for shrivelling",
        fertilising: "Feed lightly once in spring",
        repotting: "Spring if crowded; use a shallow pot",
        reviewedScientificName: "Curio rowleyanus",
        references: [rhsStringOfPearls, wisconsinStringOfPearls],
        referenceWateringDays: 30
    )

    // RHS and University of Wisconsin Extension: Epipremnum aureum.
    private static let goldenPothos = PlantCareProfile(
        light: "Bright, indirect; shade slows growth",
        lightPreference: .brightIndirect,
        temperature: "21–32°C preferred; avoid draughts",
        humidity: "High preferred; avoid dry air",
        watering: "Top 2cm dry, then soak; less in winter",
        wateringShort: "Water when top 2cm is dry",
        fertilising: "Every 2 months in active growth",
        repotting: "When roots crowd; one size up",
        reviewedScientificName: "Epipremnum aureum",
        references: [rhsGoldenPothos, wisconsinGoldenPothos],
        referenceWateringDays: 9
    )

    // RHS: How to grow ornamental figs.
    private static let fiddleLeafFig = PlantCareProfile(
        light: "Bright, indirect; only gentle direct sun",
        lightPreference: .brightIndirect,
        temperature: "Warm and stable; keep above 13°C",
        humidity: "Medium–high; avoid dry air",
        watering: "Top 2cm dry; keep just moist in winter",
        wateringShort: "Water when top 2cm is dry",
        fertilising: "High-nitrogen feed, spring–late summer",
        repotting: "Spring when crowded; one size up",
        reviewedScientificName: "Ficus lyrata",
        references: [rhsFiddleLeafFig],
        referenceWateringDays: 8
    )

    // RHS: How to grow peace lilies.
    private static let peaceLily = PlantCareProfile(
        light: "Bright, indirect; deep shade limits flowers",
        lightPreference: .brightIndirect,
        temperature: "12–24°C; avoid heat and draughts",
        humidity: "Moderate; dry air can brown tips",
        watering: "Top few cm dry; reduce in winter",
        wateringShort: "Water when top few cm are dry",
        fertilising: "Every few weeks, April–October",
        repotting: "Spring when roots are densely packed",
        reviewedScientificName: "Spathiphyllum wallisii",
        references: [rhsPeaceLily],
        referenceWateringDays: 6
    )

    // RHS and UF/IFAS Extension: Aloe vera.
    private static let aloeVera = PlantCareProfile(
        light: "Bright light; acclimatise to direct sun",
        lightPreference: .veryBright,
        temperature: "13–27°C; protect from cold",
        humidity: "Low–average; do not mist",
        watering: "Dry fully, then soak; minimal in winter",
        wateringShort: "Dry fully; then soak",
        fertilising: "Half-strength feed sparingly in growth",
        repotting: "When crowded; at most 2 sizes up",
        reviewedScientificName: "Aloe vera",
        references: [rhsAloeVera, floridaAloeVera],
        referenceWateringDays: 24
    )

    // RHS and NC State Extension: Goeppertia orbifolia.
    private static let roundLeafCalathea = PlantCareProfile(
        light: "Bright, indirect; direct sun can scorch",
        lightPreference: .brightIndirect,
        temperature: "18–24°C; keep conditions stable",
        humidity: "High; aim for at least 60%",
        watering: "Keep evenly moist, never soggy; less in winter",
        wateringShort: "Evenly moist; never soggy",
        fertilising: "Monthly during active growth",
        repotting: "Spring when the clump fills its pot",
        reviewedScientificName: "Goeppertia orbifolia",
        references: [rhsCalatheas, ncStateRoundLeafCalathea],
        referenceWateringDays: 5
    )

    // RHS: Maranta leuconeura.
    private static let prayerPlant = PlantCareProfile(
        light: "Bright, filtered or indirect",
        lightPreference: .brightIndirect,
        temperature: "Warm; avoid cold draughts",
        humidity: "High at all times",
        watering: "Evenly moist in growth; reduce in winter",
        wateringShort: "Evenly moist; less in winter",
        fertilising: "Monthly during active growth",
        repotting: "Spring when roots fill the pot",
        reviewedScientificName: "Maranta leuconeura",
        references: [rhsPrayerPlant],
        referenceWateringDays: 6
    )

    /// Broad estimates below are retained only for conservative soil dry-down
    /// arithmetic. The scan and plant-page care guides do not display them as
    /// if they were checked facts for an individual species.
    private static let generalHouseplant = PlantCareProfile(
        light: "Bright, indirect",
        lightPreference: .unknown,
        temperature: "Typical room warmth",
        humidity: "Typical room humidity",
        watering: "Check the soil, not a calendar",
        wateringShort: "Check the soil",
        fertilising: "Only during active growth",
        repotting: "Only when root-bound",
        reviewedScientificName: nil,
        references: [],
        referenceWateringDays: 9,
        matchedSpecies: false
    )

    private static let generalSucculent = PlantCareProfile(
        light: "Bright light",
        lightPreference: .unknown,
        temperature: "Typical room warmth",
        humidity: "Low humidity",
        watering: "Let the soil dry",
        wateringShort: "Let the soil dry",
        fertilising: "Only during active growth",
        repotting: "Only when root-bound",
        reviewedScientificName: nil,
        references: [],
        referenceWateringDays: 30,
        matchedSpecies: false
    )

    private static let generalHumidityLover = PlantCareProfile(
        light: "Medium, indirect",
        lightPreference: .unknown,
        temperature: "Typical room warmth",
        humidity: "Higher humidity",
        watering: "Check the soil regularly",
        wateringShort: "Check regularly",
        fertilising: "Only during active growth",
        repotting: "Only when root-bound",
        reviewedScientificName: nil,
        references: [],
        referenceWateringDays: 5,
        matchedSpecies: false
    )

    private init(
        light: String,
        lightPreference: LightPreference,
        temperature: String,
        humidity: String,
        watering: String,
        wateringShort: String,
        fertilising: String,
        repotting: String,
        reviewedScientificName: String?,
        references: [Reference],
        referenceWateringDays: Double,
        matchedSpecies: Bool = true
    ) {
        self.light = light
        self.lightPreference = lightPreference
        self.temperature = temperature
        self.humidity = humidity
        self.watering = watering
        self.wateringShort = wateringShort
        self.fertilising = fertilising
        self.repotting = repotting
        self.reviewedScientificName = reviewedScientificName
        self.references = references
        self.referenceWateringDays = referenceWateringDays
        self.matchedSpecies = matchedSpecies
    }
}

// MARK: - Reviewed identities and sources

private extension PlantCareProfile {
    static let monsteraScientificNames: Set<String> = [
        "monstera deliciosa",
        "monstera deliciosa var. borsigiana"
    ]
    static let birdOfParadiseScientificNames: Set<String> = ["strelitzia reginae"]
    static let snakePlantScientificNames: Set<String> = [
        "dracaena trifasciata",
        "sansevieria trifasciata"
    ]
    static let stringOfPearlsScientificNames: Set<String> = [
        "curio rowleyanus",
        "senecio rowleyanus"
    ]
    static let pothosScientificNames: Set<String> = [
        "epipremnum aureum",
        "epipremnum pinnatum 'aureum'",
        "scindapsus aureus"
    ]
    static let fiddleLeafFigScientificNames: Set<String> = [
        "ficus lyrata",
        "ficus pandurata"
    ]
    static let peaceLilyScientificNames: Set<String> = ["spathiphyllum wallisii"]
    static let aloeVeraScientificNames: Set<String> = [
        "aloe vera",
        "aloe barbadensis"
    ]
    static let roundLeafCalatheaScientificNames: Set<String> = [
        "goeppertia orbifolia",
        "calathea orbifolia"
    ]
    static let prayerPlantScientificNames: Set<String> = ["maranta leuconeura"]

    private static func isForestCactus(_ identity: String) -> Bool {
        ["christmas cactus", "easter cactus", "thanksgiving cactus", "holiday cactus", "schlumbergera", "hatiora", "rhipsalidopsis"]
            .contains { identity.contains($0) }
    }

    static func normalizedScientificName(_ value: String) -> String {
        value
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static let rhsMonstera = reference(
        "rhs-monstera", "RHS", "How to grow Swiss cheese plants",
        "https://www.rhs.org.uk/plants/swiss-cheese-plants/how-to-grow-swiss-cheese-plants"
    )
    static let rhsBirdOfParadise = reference(
        "rhs-strelitzia", "RHS", "How to grow strelitzia",
        "https://www.rhs.org.uk/plants/strelitzia/how-to-grow-strelitzia"
    )
    static let rhsSnakePlant = reference(
        "rhs-snake-plant", "RHS", "How to grow sansevierias",
        "https://www.rhs.org.uk/plants/sansevieria/growing-guide"
    )
    static let rhsStringOfPearls = reference(
        "rhs-string-of-pearls", "RHS", "String of beads and its relatives",
        "https://www.rhs.org.uk/plants/string-of-beads"
    )
    static let wisconsinStringOfPearls = reference(
        "wisconsin-string-of-pearls", "UW–Madison Extension", "String of Pearls",
        "https://hort.extension.wisc.edu/articles/string-of-pearls-senecio-rowleyanus/"
    )
    static let rhsGoldenPothos = reference(
        "rhs-golden-pothos", "RHS", "Epipremnum",
        "https://www.rhs.org.uk/plants/epipremnum"
    )
    static let wisconsinGoldenPothos = reference(
        "wisconsin-golden-pothos", "UW–Madison Extension", "Pothos",
        "https://hort.extension.wisc.edu/articles/pothos-epipremmum-aureum/"
    )
    static let rhsFiddleLeafFig = reference(
        "rhs-fiddle-leaf-fig", "RHS", "How to grow ornamental figs",
        "https://www.rhs.org.uk/plants/ornamental-figs/growing-guide"
    )
    static let rhsPeaceLily = reference(
        "rhs-peace-lily-care", "RHS", "How to grow peace lilies",
        "https://www.rhs.org.uk/plants/peace-lilies/how-to-grow-peace-lilies"
    )
    static let rhsAloeVera = reference(
        "rhs-aloe-vera", "RHS", "Care tips for light-loving houseplants",
        "https://www.rhs.org.uk/shows-events/rhs-urban-show/houseplant-profiles/houseplants-for-sunlight"
    )
    static let floridaAloeVera = reference(
        "florida-aloe-vera", "UF/IFAS Extension", "Aloe Vera",
        "https://gardeningsolutions.ifas.ufl.edu/plants/ornamentals/aloe-vera/"
    )
    static let rhsCalatheas = reference(
        "rhs-calatheas", "RHS", "How to grow calatheas",
        "https://www.rhs.org.uk/plants/calathea/growing-guide"
    )
    static let ncStateRoundLeafCalathea = reference(
        "nc-state-round-leaf-calathea", "NC State Extension", "Goeppertia orbifolia",
        "https://plants.ces.ncsu.edu/plants/goeppertia-orbifolia/"
    )
    static let rhsPrayerPlant = reference(
        "rhs-prayer-plant", "RHS", "Maranta leuconeura",
        "https://www.rhs.org.uk/plants/119598/maranta-leuconeura/details"
    )

    static func reference(
        _ id: String,
        _ publisher: String,
        _ title: String,
        _ url: String
    ) -> Reference {
        // Every URL is a reviewed, literal catalogue constant.
        Reference(id: id, publisher: publisher, title: title, url: URL(string: url)!)
    }
}

// MARK: - Hemisphere

extension PlantCareProfile {
    /// Countries that sit mostly south of the equator, for a grove with no
    /// location set. Near-equatorial countries are left out: their months
    /// barely move the advice either way.
    private static let southernRegions: Set<String> = [
        "NZ", "AU", "ZA", "AR", "CL", "UY", "PY", "BO", "PE", "BR",
        "NA", "BW", "ZW", "MZ", "MG", "LS", "SZ", "ZM", "MW", "AO",
        "FJ", "PG", "NC", "SB", "VU", "WS", "TO", "MU", "RE", "FK"
    ]

    /// The grove's latitude when it has one, then the region on the profile,
    /// then the device's own region.
    static func isSouthernHemisphere(
        latitude: Double?,
        regionCode: String? = nil,
        locale: Locale = .current
    ) -> Bool {
        if let latitude { return latitude < 0 }
        guard let region = (regionCode ?? locale.region?.identifier)?.uppercased() else { return false }
        return southernRegions.contains(region)
    }

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December"
    ]

    /// The care copy names northern months ("April–September"). South of the
    /// equator the same season is six months on, so every month name is moved
    /// by six. Season words ("spring", "in winter") already travel.
    static func localizingMonths(_ text: String, southern: Bool) -> String {
        guard southern else { return text }
        var result = ""
        var word = ""
        func flush() {
            if let index = monthNames.firstIndex(of: word) {
                result += monthNames[(index + 6) % 12]
            } else {
                result += word
            }
            word = ""
        }
        for character in text {
            if character.isLetter {
                word.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    /// This profile with its month ranges set for the hemisphere.
    func localized(southern: Bool) -> PlantCareProfile {
        guard southern else { return self }
        var copy = self
        copy.watering = Self.localizingMonths(watering, southern: true)
        copy.wateringShort = Self.localizingMonths(wateringShort, southern: true)
        copy.fertilising = Self.localizingMonths(fertilising, southern: true)
        copy.repotting = Self.localizingMonths(repotting, southern: true)
        return copy
    }
}
