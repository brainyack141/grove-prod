import Foundation

/// The broad, sourced household-safety lookup behind the plant page.
///
/// The hand-curated records in `PlantSafety` are the plants Grove was built
/// around; everything else used to fall through to "Not verified". This
/// catalogue is a compact, name-keyed extract of the Growli plant-toxicity
/// table (CC-BY 4.0, ASPCA-sourced), so almost any scanned species gets a
/// real, cited verdict.
///
/// It is bundled rather than fetched on purpose. Safety has to answer
/// instantly and offline — a scan in a garden is exactly where a network
/// round trip is least dependable — and the underlying sources change on the
/// order of months. A server refresh can layer on later; it must not be a
/// precondition for showing an answer.
///
/// Matching is by normalised scientific name only. Common names are never
/// keys: "bird of paradise" is two unrelated plants, and that is the case
/// where a confident mistake is most expensive.
enum PlantSafetyCatalogue {
    struct Entry: Hashable {
        let scientificName: String
        let verdict: PlantSafety.Status
        let detail: String
    }

    /// Mirrors `scripts/build-plant-safety.py`. Keep the two in step or a
    /// synonym the builder indexed will silently stop matching here.
    static func normalizedName(_ value: String) -> String {
        var text = value.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        text = text.lowercased(with: Locale(identifier: "en_US_POSIX"))
        // Cultivar names arrive in curly quotes as often as straight ones
        // (Monstera ‘Thai Constellation’, or “double” quotes). Fold them all to
        // one straight quote so the strip below catches every form.
        for quote in ["\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\""] {
            text = text.replacingOccurrences(of: quote, with: "'")
        }
        text = text.replacingOccurrences(of: #"'[^']*'"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"\((?:syn\.?|formerly|was)\s+([^)]+)\)"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"\([^()]*\)"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"\b(?:var|subsp|ssp|cv|f|nothosubsp|nothovar)\."#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: #"\b(?:spp?|sp|hybrid|hybrids)\b"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Human-readable attribution shown in the card's source list.
    static let creditText = "Plant-toxicity reference compiled by Growli (getgrowli.app), CC-BY 4.0, from the ASPCA Toxic and Non-Toxic Plants database and US extension services."

    static let sourceURL = URL(string: "https://www.getgrowli.app/data/plant-toxicity")!

    /// The dataset's own verification date, surfaced next to the source.
    static var reviewedOn: String { loaded.reviewedOn }

    static func entry(scientificName: String) -> Entry? {
        let key = normalizedName(scientificName)
        guard !key.isEmpty else { return nil }
        return loaded.index[key]
    }

    // MARK: - Loading

    private struct Document: Decodable {
        let reviewedOn: String?
        let records: [String: Record]

        struct Record: Decodable {
            let scientificName: String
            let v: String
            let d: String
        }
    }

    private struct Loaded {
        let reviewedOn: String
        let index: [String: Entry]
    }

    /// Decoded once, lazily, and never mutated. The file is read from the app
    /// bundle, so a missing or corrupt resource degrades to "no broad record"
    /// rather than a crash — the curated tier still answers.
    private static let loaded: Loaded = {
        guard let url = Bundle.main.url(forResource: "PlantSafetyCatalogue", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return Loaded(reviewedOn: "unknown", index: [:])
        }
        let index = document.records.compactMapValues { record -> Entry? in
            guard let status = PlantSafety.Status(catalogueCode: record.v) else { return nil }
            return Entry(scientificName: record.scientificName, verdict: status, detail: record.d)
        }
        return Loaded(reviewedOn: document.reviewedOn ?? "unknown", index: index)
    }()
}

private extension PlantSafety.Status {
    init?(catalogueCode: String) {
        switch catalogueCode {
        case "harmful": self = .harmful
        case "irritant": self = .irritant
        case "lowRisk": self = .lowRisk
        case "noKnownToxicity": self = .noKnownToxicity
        default: return nil
        }
    }
}
