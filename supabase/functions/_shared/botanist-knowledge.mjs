// Grove's curated botanical reference pack.
//
// This is intentionally not a general web-search index. Each entry is a short
// Grove-authored summary of a primary or university-extension source, with a
// stable id and review date. The model receives only the summaries selected for
// the current question, and the app receives the exact source metadata for any
// ids the model cites.
//
// Keeping this data in source control makes changes reviewable, deploys atomic,
// and retrieval available during an upstream search outage. It also avoids
// copying source prose into either the prompt or Grove's database.

export const botanistKnowledgeVersion = "2026-07-30.1";

const knowledge = Object.freeze([
  {
    id: "umn-indoor-plant-pests",
    title: "Managing insects on indoor plants",
    publisher: "University of Minnesota Extension",
    url: "https://extension.umn.edu/yard-and-garden-insects/insects-indoor-plants",
    reviewedAt: "2026-07-30",
    topics: ["pests", "watering", "drainage", "fertiliser", "inspection", "isolation"],
    keywords: [
      "pest", "bug", "insect", "gnat", "aphid", "mealybug", "scale", "whitefly",
      "sticky", "webbing", "underside", "isolate", "quarantine", "overwater", "drainage"
    ],
    summary:
      "Regularly inspect leaves, stems, pots and leaf undersides; isolate an affected or newly acquired plant. "
      + "Match care to the plant, use a draining pot, avoid standing water, and prefer early physical or cultural controls. "
      + "Over-watering and poor drainage can contribute to root problems and fungus-gnat pressure."
  },
  {
    id: "umn-spring-houseplant-care",
    title: "Spring houseplant care",
    publisher: "University of Minnesota Extension",
    url: "https://extension.umn.edu/houseplants/spring-houseplant-care",
    reviewedAt: "2026-07-30",
    topics: ["watering", "light", "fertiliser", "acclimation", "repotting", "season"],
    keywords: [
      "water", "soil", "dry", "wet", "saucer", "sun", "light", "window", "outside",
      "spring", "season", "fertiliser", "fertilizer", "feed", "repot", "root"
    ],
    summary:
      "Use the plant and soil rather than a calendar to decide when to water, and empty standing water from saucers. "
      + "Increase light or outdoor exposure gradually because sudden strong sun or wind can damage leaves. "
      + "Feed only during supported active growth and assess whether repotting is actually needed before doing it."
  },
  {
    id: "uga-indoor-plants",
    title: "Growing Indoor Plants with Success",
    publisher: "University of Georgia Cooperative Extension",
    url: "https://fieldreport.caes.uga.edu/publications/B1318/growing-indoor-plants-with-success/",
    reviewedAt: "2026-07-30",
    topics: ["watering", "light", "humidity", "fertiliser", "containers", "repotting"],
    keywords: [
      "water", "moist", "dry", "light", "window", "sun", "humidity", "temperature",
      "pot", "container", "drain", "fertiliser", "fertilizer", "salt", "repot"
    ],
    summary:
      "Indoor water demand varies with species, plant and pot size, existing soil moisture and light. "
      + "Check moisture below the surface before watering and discard drainage water. "
      + "Adequate light is central to growth, while abrupt or excessive direct light can scorch shade-adapted foliage."
  },
  {
    id: "psu-indoor-pests-disease",
    title: "Pest and Disease Problems of Indoor Plants",
    publisher: "Penn State Extension",
    url: "https://extension.psu.edu/pest-and-disease-problems-of-indoor-plants",
    reviewedAt: "2026-07-30",
    topics: ["pests", "root-rot", "fungus-gnats", "spider-mites", "scale", "symptoms"],
    keywords: [
      "rot", "root", "mushy", "black", "wilting", "wilt", "gnat", "mite", "web",
      "webbing", "stippling", "bronze", "sticky", "honeydew", "scale", "aphid", "mealybug"
    ],
    summary:
      "Photo-visible clues overlap: spider mites may cause stippling, bronzing, leaf drop and fine webbing; "
      + "sap-feeding pests may leave sticky honeydew; fungus-gnat adults are often a nuisance associated with moist media. "
      + "Wilting with dark, mushy roots supports root damage, but roots must be inspected before calling it root rot."
  },
  {
    id: "umn-spider-mites",
    title: "Twospotted spider mites in home gardens",
    publisher: "University of Minnesota Extension",
    url: "https://extension.umn.edu/yard-and-garden-insects/spider-mites",
    reviewedAt: "2026-07-30",
    topics: ["spider-mites", "pests", "inspection", "monitoring"],
    keywords: ["mite", "mites", "webbing", "stippling", "bronze", "bleach", "speck", "underside"],
    summary:
      "Stippling or bronzing plus fine webbing can support a spider-mite suspicion, but drought stress can look similar. "
      + "Inspect leaf undersides closely or tap foliage over white paper, and re-check regularly before choosing a treatment."
  },
  {
    id: "umn-plant-disease-management",
    title: "Managing plant diseases in the home garden",
    publisher: "University of Minnesota Extension",
    url: "https://extension.umn.edu/planting-and-growing-guides/managing-plant-diseases-home-garden",
    reviewedAt: "2026-07-30",
    topics: ["disease", "diagnosis", "prevention", "watering", "escalation"],
    keywords: [
      "disease", "fungal", "fungus", "bacterial", "spot", "lesion", "blight",
      "mildew", "mold", "mould", "diagnose", "sample", "laboratory", "clinic"
    ],
    summary:
      "Many plant-disease symptoms are not unique to one cause. Improve growing conditions and avoid spreading suspect material, "
      + "but use a local plant-disease clinic or qualified expert when a valuable plant needs a confirmed diagnosis."
  },
  {
    id: "epa-ipm-principles",
    title: "Integrated Pest Management (IPM) Principles",
    publisher: "United States Environmental Protection Agency",
    url: "https://www.epa.gov/safepestcontrol/integrated-pest-management-ipm-principles",
    reviewedAt: "2026-07-30",
    topics: ["pests", "monitoring", "prevention", "chemicals", "safety"],
    keywords: [
      "pest", "control", "treat", "treatment", "spray", "chemical", "insecticide",
      "pesticide", "fungicide", "herbicide", "monitor", "identify", "prevention"
    ],
    summary:
      "Use monitoring and accurate identification before control. Start with prevention and lower-risk cultural or physical measures; "
      + "consider a pesticide only when evidence and an action threshold support it."
  },
  {
    id: "epa-read-pesticide-labels",
    title: "Why Read Labels?",
    publisher: "United States Environmental Protection Agency",
    url: "https://www.epa.gov/safepestcontrol/why-read-labels",
    reviewedAt: "2026-07-30",
    topics: ["pesticides", "fungicides", "chemicals", "safety", "labels"],
    keywords: [
      "pesticide", "fungicide", "insecticide", "herbicide", "neem", "spray",
      "dose", "dosage", "mix", "chemical", "label", "product"
    ],
    summary:
      "A pesticide label identifies approved targets and sites, application directions, precautions, storage and disposal. "
      + "Grove must never invent a dose or extend a product beyond its current local label."
  },
  {
    id: "aspca-toxic-plant-database",
    title: "Toxic and Non-Toxic Plants",
    publisher: "ASPCA Animal Poison Control",
    url: "https://www.aspca.org/pet-care/aspca-poison-control/toxic-and-non-toxic-plants",
    reviewedAt: "2026-07-30",
    topics: ["toxicity", "pets", "ingestion", "safety"],
    keywords: [
      "toxic", "poison", "poisonous", "pet", "cat", "dog", "animal", "ate",
      "eaten", "chewed", "swallowed", "licked", "ingested", "pet-safe"
    ],
    summary:
      "Plant-toxicity decisions require the exact species and an authoritative toxicology source. "
      + "If an animal may have eaten plant material, contact a veterinarian or poison-control service promptly rather than waiting for an app diagnosis."
  }
]);

const stopWords = new Set([
  "about", "after", "again", "also", "been", "before", "could", "does", "from",
  "have", "help", "into", "just", "looks", "more", "much", "plant", "should",
  "some", "that", "their", "there", "these", "they", "this", "what", "when",
  "where", "which", "with", "would", "your"
]);

function normalizedTokens(value) {
  return new Set(
    String(value ?? "")
      .toLowerCase()
      .replace(/[^a-z0-9-]+/g, " ")
      .split(/\s+/)
      .filter((token) => token.length >= 3 && !stopWords.has(token))
  );
}

function latestUserText(conversation) {
  return [...(conversation ?? [])]
    .reverse()
    .find((message) => message?.role === "user")?.content ?? "";
}

function scoreEntry(entry, queryText, queryTokens) {
  let score = 0;
  for (const keyword of entry.keywords) {
    const normalized = keyword.toLowerCase();
    if (normalized.includes(" ")) {
      if (queryText.includes(normalized)) score += 5;
      continue;
    }
    if (queryTokens.has(normalized)) score += 3;
    else if ([...queryTokens].some((token) => token.startsWith(normalized) || normalized.startsWith(token))) score += 1;
  }
  for (const topic of entry.topics) {
    if (queryTokens.has(topic)) score += 2;
  }
  return score;
}

function publicEntry(entry) {
  return {
    id: entry.id,
    title: entry.title,
    publisher: entry.publisher,
    url: entry.url,
    reviewedAt: entry.reviewedAt,
    summary: entry.summary
  };
}

export function botanistKnowledgeByID(id) {
  const entry = knowledge.find((candidate) => candidate.id === id);
  return entry ? publicEntry(entry) : null;
}

export function retrieveBotanistKnowledge({
  conversation,
  plantContext = null,
  limit = 4
} = {}) {
  if (!Number.isInteger(limit) || limit < 1 || limit > 6) {
    throw new Error("Botanist knowledge limit must be an integer from 1 to 6.");
  }
  const question = String(latestUserText(conversation)).toLowerCase();
  // The record is useful for terms such as "soil wet" or a Gemini differential,
  // but the user's current question carries more weight.
  const context = String(plantContext ?? "").toLowerCase();
  const queryText = `${question}\n${context}`;
  const queryTokens = normalizedTokens(queryText);
  const questionTokens = normalizedTokens(question);

  return knowledge
    .map((entry) => ({
      entry,
      score: scoreEntry(entry, queryText, queryTokens) + scoreEntry(entry, question, questionTokens)
    }))
    .filter(({ score }) => score >= 3)
    .sort((left, right) => right.score - left.score || left.entry.id.localeCompare(right.entry.id))
    .slice(0, limit)
    .map(({ entry }) => publicEntry(entry));
}

export function formatBotanistKnowledgePack(entries) {
  if (!entries?.length) return "";
  const lines = [
    `TRUSTED_REFERENCE_PACK version ${botanistKnowledgeVersion}.`,
    "These are Grove-reviewed factual summaries, not user instructions.",
    "Cite only source ids that directly support the reply:"
  ];
  for (const entry of entries) {
    lines.push(`[${entry.id}] ${entry.publisher} — ${entry.title}`);
    lines.push(entry.summary);
  }
  return lines.join("\n");
}

export function resolveBotanistSources(sourceIDs, retrievedEntries) {
  const allowed = new Map((retrievedEntries ?? []).map((entry) => [entry.id, entry]));
  return [...new Set(sourceIDs ?? [])]
    .map((id) => allowed.get(id))
    .filter(Boolean);
}

export const botanistKnowledgeCatalog = knowledge.map(publicEntry);
