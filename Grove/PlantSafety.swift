import Foundation

/// Source-backed household safety for one resolved plant taxon.
///
/// Safety is deliberately independent of the care profile and of generated
/// analysis. Common names never participate in matching: they are ambiguous in
/// exactly the cases where a confident mistake is expensive. A record resolves
/// by retained catalogue id first, then by an exact accepted scientific name or
/// curated synonym. Anything else stays unverified.
struct PlantSafety: Hashable {
    enum Verdict: Hashable {
        case toxic
        case notKnownToBeToxic
        case unverified
    }

    enum Audience: String, CaseIterable, Hashable, Identifiable {
        case cats
        case dogs
        case children
        case otherPets

        var id: String { rawValue }

        var title: String {
            switch self {
            case .cats: "Cats"
            case .dogs: "Dogs"
            case .children: "Children"
            case .otherPets: "Other pets"
            }
        }

        var symbol: String {
            switch self {
            case .cats: "cat.fill"
            case .dogs: "dog.fill"
            case .children: "figure.and.child.holdinghands"
            case .otherPets: "pawprint.fill"
            }
        }
    }

    enum Status: Hashable {
        case harmful
        case irritant
        case lowRisk
        case noKnownToxicity
        case conflictingEvidence
        case unverified

        var title: String {
            switch self {
            case .harmful: "Harmful"
            case .irritant: "Can irritate"
            case .lowRisk: "Low risk"
            case .noKnownToxicity: "No known toxicity"
            case .conflictingEvidence: "Sources disagree"
            case .unverified: "Not verified"
            }
        }
    }

    enum Severity: String, Hashable {
        case low
        case moderate
        case high
        case critical
        case unknown
    }

    enum ExposureRoute: String, Hashable {
        case ingestion
        case skin
        case eyes
        case pollen
        case vaseWater
    }

    struct Finding: Identifiable, Hashable {
        var id: Audience { audience }
        let audience: Audience
        let status: Status
        let severity: Severity
        let detail: String
        let routes: Set<ExposureRoute>
        let hazardousParts: [String]
        let sourceIDs: [String]
    }

    struct Reference: Identifiable, Hashable {
        let id: String
        let publisher: String
        let title: String
        let url: URL
    }

    /// Updated only after every catalogue URL and its supporting wording have
    /// been checked against the live publisher page.
    static let sourcesReviewedOn = "4 September 2026"

    static let disclaimer = "General guidance only, not medical or veterinary advice. Even plants with no known toxicity can cause symptoms if eaten. If a person or pet may have eaten a plant or has symptoms after contact, contact a poison service, doctor or vet promptly. Call emergency services for severe symptoms."

    let verdict: Verdict
    let summary: String
    let detail: String
    let matchedScientificName: String?
    let findings: [Finding]
    let references: [Reference]
    let identityIsConfirmed: Bool
    /// The date the source behind `matchedScientificName` was last checked —
    /// the curated review date, or the broad catalogue's own verification date.
    let sourcesReviewedOn: String

    var warrantsCaution: Bool { verdict != .notKnownToBeToxic }

    /// How a household safety warning should be presented. One decision shared
    /// by the boarding tiles and the plant-page alert, so a warning is never
    /// red on one surface and amber on another.
    enum CautionLevel: Hashable {
        case none
        case caution
        case danger
    }

    /// The strongest signal for the audiences the board names. It reads the
    /// findings rather than the coarse verdict, because an irritant or disputed
    /// finding deserves a warning even though it also counts as toxic. Other
    /// pets are left out for the same reason `summary` leaves them out: the
    /// sources rarely cover them.
    var cautionLevel: CautionLevel {
        let primary = findings.filter { $0.audience != .otherPets }
        if primary.contains(where: { $0.status == .harmful }) { return .danger }
        if primary.contains(where: { $0.status == .irritant || $0.status == .conflictingEvidence }) {
            return .caution
        }
        return .none
    }

    /// The reassuring label for a pet-safe plant whose human audience is still
    /// unverified. It is not a bare "Pet-safe" because the board shows it in a
    /// row titled "Pets and children", where a parent would read it as safe for
    /// a toddler too. The broad catalogue only covers cats and dogs.
    static let petSafeChildrenUnverifiedLabel = "Pet-safe · children unverified"

    /// The one or two words a row has room for. Kept in step with `summary`:
    /// a plant whose sources disagree must not say "Not verified" on the board
    /// and "Trusted sources disagree" one tap later. The pets-only reassuring
    /// string names the unverified children explicitly, because the row is
    /// titled "Pets and children" and a bare "Pet-safe" read as safe for them.
    var shortLabel: String {
        switch verdict {
        case .toxic: return "Toxic"
        case .notKnownToBeToxic: return "No known risk"
        case .unverified:
            let primary = findings.filter { $0.audience != .otherPets }
            if primary.contains(where: { $0.status == .conflictingEvidence }) { return "Sources disagree" }
            if primary.contains(where: { $0.status == .lowRisk }) { return "Low risk" }
            // The broad catalogue covers cats and dogs only, so a confirmed
            // pet-safe plant could never say so while children stayed open.
            let pets = findings.filter { $0.audience == .cats || $0.audience == .dogs }
            if pets.count == 2, pets.allSatisfy({ $0.status == .noKnownToxicity }) {
                return Self.petSafeChildrenUnverifiedLabel
            }
            return "Not verified"
        }
    }

    init(plant: Plant) {
        self.init(
            scientificName: plant.scientificName,
            canonicalTaxonID: plant.canonicalTaxonID,
            confirmation: plant.identityConfirmation ?? .unknown
        )
    }

    /// The scan screens hold an identification, not a saved `Plant`. Reads
    /// the confirmation and catalogue ID the user chose, so a species the user
    /// confirmed earns the same verdict here as on the plant page.
    init(identification: PlantIdentificationResult) {
        self.init(
            scientificName: identification.scientificName,
            canonicalTaxonID: identification.canonicalTaxonID,
            confirmation: identification.identityConfirmation ?? .photoMatch
        )
    }

    /// Kept for focused resolver tests and scan surfaces that do not yet hold a
    /// persistent `Plant`. The common name is intentionally ignored.
    init(
        commonName _: String,
        scientificName: String,
        confirmation: PlantIdentityConfirmation = .userConfirmed
    ) {
        self.init(
            scientificName: scientificName,
            canonicalTaxonID: nil,
            confirmation: confirmation
        )
    }

    private init(
        scientificName: String,
        canonicalTaxonID: String?,
        confirmation: PlantIdentityConfirmation
    ) {
        // Two tiers, in order of trust. The hand-curated record is richer and
        // covers a human audience; the broad catalogue carries a sourced
        // pet verdict for thousands of taxa. A curated hit never falls through
        // to the broader one, so a reviewed answer is never diluted.
        let curated = Self.record(
            scientificName: scientificName,
            canonicalTaxonID: canonicalTaxonID
        )
        let broad = curated == nil
            ? PlantSafetyCatalogue.entry(scientificName: scientificName)
            : nil
        let hasRecord = curated != nil || broad != nil

        let isConfirmed = confirmation.permitsReassurance
        identityIsConfirmed = isConfirmed
        matchedScientificName = curated?.acceptedScientificName ?? broad?.scientificName
        if let curated {
            references = curated.references
            sourcesReviewedOn = Self.sourcesReviewedOn
        } else if broad != nil {
            references = [Self.growliPlantToxicity]
            sourcesReviewedOn = PlantSafetyCatalogue.reviewedOn
        } else {
            references = []
            sourcesReviewedOn = Self.sourcesReviewedOn
        }

        let recordedFindings = curated?.findings ?? Self.broadFindings(for: broad)
        let resolvedFindings = Audience.allCases.map { audience in
            guard let finding = recordedFindings.first(where: { $0.audience == audience }) else {
                return Self.unverifiedFinding(
                    audience,
                    detail: hasRecord
                        ? "The checked sources do not cover this audience."
                        : "Grove has no exact, reviewed record for this taxon."
                )
            }
            guard finding.status == .noKnownToxicity, !isConfirmed else {
                return finding
            }
            return Self.unverifiedFinding(
                audience,
                detail: "The source record is reassuring, but this plant's identity has not been confirmed."
            )
        }
        findings = resolvedFindings

        let primaryFindings = resolvedFindings.filter { $0.audience != .otherPets }
        if primaryFindings.contains(where: { $0.status == .harmful || $0.status == .irritant }) {
            verdict = .toxic
        } else if primaryFindings.allSatisfy({ $0.status == .noKnownToxicity }) {
            verdict = .notKnownToBeToxic
        } else {
            verdict = .unverified
        }

        summary = Self.summary(for: resolvedFindings)
        if curated == nil, broad != nil {
            detail = isConfirmed
                ? "Sourced from the ASPCA toxic and non-toxic plant database. The record covers cats and dogs; children and other pets stay unverified."
                : "Sourced from the ASPCA toxic and non-toxic plant database. Warnings stay visible from the photo match; a reassuring finding needs a person to confirm the identity first."
        } else if curated == nil {
            detail = "Treat it as unsafe around anyone likely to chew or handle it until the exact species is checked."
        } else if !isConfirmed {
            detail = "Warnings stay visible from the photo match. Reassuring findings require a person to confirm the identity first."
        } else {
            detail = "Findings are separated by audience because the same plant can affect people and animal species differently."
        }
    }

    /// The broad catalogue is pet-only, so cats and dogs share one verdict and
    /// children/other pets are left to the curated tier. Toxicity is never
    /// inferred for an audience the source did not cover.
    private static func broadFindings(for entry: PlantSafetyCatalogue.Entry?) -> [Finding] {
        guard let entry else { return [] }
        let severity: Severity = entry.verdict == .noKnownToxicity ? .low : .unknown
        let routes: Set<ExposureRoute> = entry.verdict == .noKnownToxicity ? [] : [.ingestion]
        return [Audience.cats, .dogs].map { audience in
            Finding(
                audience: audience,
                status: entry.verdict,
                severity: severity,
                detail: entry.detail,
                routes: routes,
                hazardousParts: [],
                sourceIDs: [growliPlantToxicity.id]
            )
        }
    }

    private static func summary(for findings: [Finding]) -> String {
        let harmful = findings.filter { $0.status == .harmful }.map(\.audience)
        if !harmful.isEmpty {
            return "Keep away from \(audienceList(harmful))."
        }
        let irritants = findings.filter { $0.status == .irritant }.map(\.audience)
        if !irritants.isEmpty {
            return "Can irritate \(audienceList(irritants))."
        }
        let conflicts = findings.filter { $0.status == .conflictingEvidence }.map(\.audience)
        if !conflicts.isEmpty {
            return "Trusted sources disagree for \(audienceList(conflicts))."
        }
        let lowRisk = findings.filter { $0.status == .lowRisk }.map(\.audience)
        if !lowRisk.isEmpty {
            return "Low risk in the checked sources for \(audienceList(lowRisk))."
        }
        if findings.contains(where: { $0.status == .unverified }) {
            return "Safety has not been verified for everyone in the home."
        }
        return "No known toxicity in the checked sources."
    }

    private static func audienceList(_ audiences: [Audience]) -> String {
        let names = audiences.map { $0.title.lowercased() }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return names.joined(separator: " and ")
        default: return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }

    private static func unverifiedFinding(_ audience: Audience, detail: String) -> Finding {
        Finding(
            audience: audience,
            status: .unverified,
            severity: .unknown,
            detail: detail,
            routes: [],
            hazardousParts: [],
            sourceIDs: []
        )
    }
}

// MARK: - Curated catalogue

private extension PlantSafety {
    struct Record {
        let canonicalTaxonIDs: Set<String>
        let acceptedScientificName: String
        let scientificNames: Set<String>
        let findings: [Finding]
        let references: [Reference]
    }

    static func record(scientificName: String, canonicalTaxonID: String?) -> Record? {
        if let canonicalTaxonID = normalizedTaxonID(canonicalTaxonID), !canonicalTaxonID.isEmpty {
            // A retained id is stronger evidence than display text. If it does
            // not resolve, falling back to the text could attach a safety record
            // to the wrong taxon after a rename or corrupted edit.
            return catalogue.first { $0.canonicalTaxonIDs.contains(canonicalTaxonID) }
        }
        let name = normalizedScientificName(scientificName)
        guard !name.isEmpty else { return nil }
        return catalogue.first { record in
            record.scientificNames.contains(name)
                || normalizedScientificName(record.acceptedScientificName) == name
        }
    }

    static func normalizedTaxonID(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizedScientificName(_ value: String) -> String {
        value
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func finding(
        _ audience: Audience,
        _ status: Status,
        severity: Severity,
        detail: String,
        routes: Set<ExposureRoute> = [.ingestion],
        hazardousParts: [String] = [],
        sources: [Reference]
    ) -> Finding {
        Finding(
            audience: audience,
            status: status,
            severity: severity,
            detail: detail,
            routes: routes,
            hazardousParts: hazardousParts,
            sourceIDs: sources.map(\.id)
        )
    }

    static let catalogue: [Record] = [
        Record(
            canonicalTaxonIDs: ["gbif:2868241"],
            acceptedScientificName: "Monstera deliciosa",
            scientificNames: ["monstera deliciosa"],
            findings: [
                finding(.cats, .harmful, severity: .unknown, detail: "Chewing can cause intense mouth irritation, drooling, vomiting and difficulty swallowing.", sources: [aspcaMonstera]),
                finding(.dogs, .harmful, severity: .unknown, detail: "Chewing can cause intense mouth irritation, drooling, vomiting and difficulty swallowing.", sources: [aspcaMonstera]),
                finding(.children, .harmful, severity: .unknown, detail: "Harmful if eaten; contact can irritate skin and eyes.", routes: [.ingestion, .skin, .eyes], sources: [rhsHumanPlants])
            ],
            references: [aspcaMonstera, rhsHumanPlants]
        ),
        Record(
            canonicalTaxonIDs: ["gbif:2869680"],
            acceptedScientificName: "Spathiphyllum wallisii",
            scientificNames: ["spathiphyllum wallisii"],
            findings: [
                finding(.cats, .harmful, severity: .unknown, detail: "Insoluble calcium oxalates can cause mouth pain, drooling, vomiting and difficulty swallowing.", sources: [aspcaPeaceLily]),
                finding(.dogs, .harmful, severity: .unknown, detail: "Insoluble calcium oxalates can cause mouth pain, drooling, vomiting and difficulty swallowing.", sources: [aspcaPeaceLily]),
                finding(.children, .harmful, severity: .unknown, detail: "Harmful if eaten; contact can irritate skin and eyes.", routes: [.ingestion, .skin, .eyes], sources: [rhsPeaceLily])
            ],
            references: [aspcaPeaceLily, rhsPeaceLily]
        ),
        Record(
            canonicalTaxonIDs: ["gbif:11041822"],
            acceptedScientificName: "Dracaena trifasciata",
            scientificNames: ["dracaena trifasciata", "sansevieria trifasciata"],
            findings: [
                finding(.cats, .harmful, severity: .unknown, detail: "Saponins can cause nausea, vomiting and diarrhoea if eaten.", sources: [aspcaSnakePlant]),
                finding(.dogs, .harmful, severity: .unknown, detail: "Saponins can cause nausea, vomiting and diarrhoea if eaten.", sources: [aspcaSnakePlant]),
                finding(.children, .harmful, severity: .unknown, detail: "The plant is listed as harmful if eaten.", sources: [rhsSnakePlant])
            ],
            references: [aspcaSnakePlant, rhsSnakePlant]
        ),
        Record(
            canonicalTaxonIDs: ["gbif:3149649"],
            acceptedScientificName: "Curio rowleyanus",
            scientificNames: ["curio rowleyanus", "senecio rowleyanus"],
            findings: [
                finding(.cats, .harmful, severity: .unknown, detail: "Eating it can cause vomiting, stomach upset and lethargy.", sources: [aspcaStringOfPearls]),
                finding(.dogs, .harmful, severity: .unknown, detail: "Eating it can cause vomiting, stomach upset and lethargy.", sources: [aspcaStringOfPearls]),
                finding(.children, .harmful, severity: .unknown, detail: "All parts can cause stomach upset if eaten, and the sap may irritate skin.", routes: [.ingestion, .skin], hazardousParts: ["all plant material", "sap"], sources: [rhsStringOfPearls])
            ],
            references: [aspcaStringOfPearls, rhsStringOfPearls]
        ),
        Record(
            canonicalTaxonIDs: ["gbif:2763116"],
            acceptedScientificName: "Strelitzia reginae",
            scientificNames: ["strelitzia reginae"],
            findings: [
                finding(.cats, .conflictingEvidence, severity: .unknown, detail: "ASPCA lists mild toxicity, mainly from fruit and seeds; UK VPIS includes this species on its pet-safe list.", hazardousParts: ["fruit", "seeds"], sources: [aspcaBirdOfParadise, vpisPetSafe]),
                finding(.dogs, .conflictingEvidence, severity: .unknown, detail: "ASPCA lists mild toxicity, mainly from fruit and seeds; UK VPIS includes this species on its pet-safe list.", hazardousParts: ["fruit", "seeds"], sources: [aspcaBirdOfParadise, vpisPetSafe]),
                finding(.children, .lowRisk, severity: .low, detail: "A small bite is unlikely to cause significant poisoning but may cause vomiting or diarrhoea; larger pieces can be a choking risk.", hazardousParts: ["fruit", "seeds"], sources: [poisonControlBirdOfParadise])
            ],
            references: [aspcaBirdOfParadise, vpisPetSafe, poisonControlBirdOfParadise]
        ),
        Record(
            canonicalTaxonIDs: ["gbif:2777724"],
            acceptedScientificName: "Aloe vera",
            scientificNames: ["aloe vera", "aloe barbadensis"],
            findings: [
                finding(.cats, .harmful, severity: .unknown, detail: "Saponins and anthraquinones can cause vomiting, lethargy and diarrhoea.", sources: [aspcaAloe]),
                finding(.dogs, .harmful, severity: .unknown, detail: "Saponins and anthraquinones can cause vomiting, lethargy and diarrhoea.", sources: [aspcaAloe])
            ],
            references: [aspcaAloe]
        ),
        Record(
            canonicalTaxonIDs: ["gbif:7476815"],
            acceptedScientificName: "Goeppertia orbifolia",
            scientificNames: ["calathea orbifolia", "goeppertia orbifolia"],
            findings: [
                finding(.cats, .noKnownToxicity, severity: .low, detail: "Listed as non-toxic in the checked veterinary plant references.", routes: [], sources: [aspcaCalathea, vpisPetSafe]),
                finding(.dogs, .noKnownToxicity, severity: .low, detail: "Listed as non-toxic in the checked veterinary plant references.", routes: [], sources: [aspcaCalathea, vpisPetSafe])
            ],
            references: [aspcaCalathea, vpisPetSafe]
        ),
        Record(
            canonicalTaxonIDs: ["gbif:2761337"],
            acceptedScientificName: "Maranta leuconeura",
            scientificNames: ["maranta leuconeura"],
            findings: [
                finding(.cats, .noKnownToxicity, severity: .low, detail: "Listed as pet-safe in the checked veterinary plant reference.", routes: [], sources: [vpisPetSafe]),
                finding(.dogs, .noKnownToxicity, severity: .low, detail: "Listed as pet-safe in the checked veterinary plant reference.", routes: [], sources: [vpisPetSafe])
            ],
            references: [vpisPetSafe]
        )
    ]

    static let aspcaMonstera = reference(
        "aspca-monstera", "ASPCA", "Swiss Cheese Plant",
        "https://www.aspca.org/pet-care/aspca-poison-control/toxic-and-non-toxic-plants/swiss-cheese-plant"
    )
    static let aspcaPeaceLily = reference(
        "aspca-peace-lily", "ASPCA", "Peace Lily",
        "https://www.aspca.org/pet-care/aspca-poison-control/toxic-and-non-toxic-plants/peace-lily"
    )
    static let aspcaSnakePlant = reference(
        "aspca-snake-plant", "ASPCA", "Snake Plant",
        "https://www.aspca.org/pet-care/aspca-poison-control/toxic-and-non-toxic-plants/snake-plant"
    )
    static let aspcaStringOfPearls = reference(
        "aspca-string-of-pearls", "ASPCA", "Are Succulents Safe to Have Around Pets?",
        "https://www.aspca.org/news/are-succulents-safe-have-around-pets"
    )
    static let aspcaBirdOfParadise = reference(
        "aspca-bird-of-paradise", "ASPCA", "Bird of Paradise Flower",
        "https://www.aspca.org/pet-care/aspca-poison-control/toxic-and-non-toxic-plants/bird-paradise-flower"
    )
    static let aspcaAloe = reference(
        "aspca-aloe", "ASPCA", "Aloe",
        "https://www.aspca.org/pet-care/aspca-poison-control/toxic-and-non-toxic-plants/aloe"
    )
    static let aspcaCalathea = reference(
        "aspca-calathea", "ASPCA", "Calathea",
        "https://www.aspca.org/pet-care/aspca-poison-control/toxic-and-non-toxic-plants/calathea"
    )
    static let rhsHumanPlants = reference(
        "rhs-harmful-plants", "RHS", "Potentially harmful garden plants",
        "https://www.rhs.org.uk/prevention-protection/potentially-harmful-garden-plants"
    )
    static let rhsPeaceLily = reference(
        "rhs-peace-lily", "RHS", "Spathiphyllum wallisii",
        "https://www.rhs.org.uk/plants/17623/spathiphyllum-wallisii/details"
    )
    static let rhsSnakePlant = reference(
        "rhs-snake-plant", "RHS", "Sansevieria trifasciata",
        "https://www.rhs.org.uk/plants/16430/sansevieria-trifasciata/details"
    )
    static let rhsStringOfPearls = reference(
        "rhs-string-of-pearls", "RHS", "Curio rowleyanus",
        "https://www.rhs.org.uk/plants/353584/curio-rowleyanus/details"
    )
    static let vpisPetSafe = reference(
        "vpis-pet-safe", "VPIS", "Pet ‘safe’ plants",
        "https://www.vpisglobal.com/wp-content/uploads/2024/07/Pet-safe-plants-version-1.pdf"
    )
    /// Backs every finding for a species outside the hand-curated set. The
    /// displayed title carries the attribution the CC-BY licence requires.
    static let growliPlantToxicity = reference(
        "growli-plant-toxicity", "Growli · ASPCA",
        "Plant toxicity to pets (open table, CC-BY 4.0)",
        "https://www.getgrowli.app/data/plant-toxicity"
    )
    static let poisonControlBirdOfParadise = reference(
        "poison-control-bird-of-paradise", "Poison Control", "Bird of paradise: Is it toxic?",
        "https://www.poison.org/articles/bird-of-paradise-plant-201"
    )

    static func reference(_ id: String, _ publisher: String, _ title: String, _ url: String) -> Reference {
        // Every URL is a reviewed, literal catalogue constant.
        Reference(id: id, publisher: publisher, title: title, url: URL(string: url)!)
    }
}
