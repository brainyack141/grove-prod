function bounded(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.max(0, Math.min(100, Math.round(number))) : fallback;
}

function boundedFollowUpDays(value, fallback = 14) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.max(1, Math.min(30, Math.round(number))) : fallback;
}

function healthBandForScore(score) {
  if (score >= 90) return "thriving";
  if (score >= 75) return "healthy";
  if (score >= 55) return "monitor";
  if (score >= 30) return "attention";
  return "urgent";
}

function followUpDaysForBand(value, band) {
  const boundedDays = boundedFollowUpDays(value);
  const ranges = {
    thriving: [14, 30],
    healthy: [7, 30],
    monitor: [3, 14],
    attention: [1, 7],
    urgent: [1, 3]
  };
  const [minimum, maximum] = ranges[band] ?? [1, 30];
  return Math.max(minimum, Math.min(maximum, boundedDays));
}

// VOICE.md bans em dashes from anything the owner reads, and the scan summary
// lands on the plant page word for word. The prompt asks for none; this is the
// backstop for when the model reaches for one anyway. A comma reads correctly
// in nearly every place a dash lands (a pause, a lead-in, either side of an
// aside), and an unspaced en dash is left alone because it is a number range.
function withoutDashes(value) {
  return value
    .replace(/\s*—\s*/g, ", ")
    .replace(/\s+–\s+/g, ", ")
    .replace(/,\s*([,.;:!?)])/g, "$1")
    .replace(/^,\s*/, "")
    .replace(/,\s*$/, "");
}

function safeText(value, fallback = "", maximumLength = 600) {
  if (typeof value !== "string") return fallback;
  const trimmed = withoutDashes(value.trim()).trim();
  return trimmed ? trimmed.slice(0, maximumLength) : fallback;
}

function safeIdentifier(value, fallback, maximumLength = 80) {
  const identifier = safeText(value, fallback, maximumLength)
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return identifier || fallback;
}

function uniqueIdentifier(value, fallback, used, maximumLength = 80) {
  const base = safeIdentifier(value, fallback, maximumLength);
  if (!used.has(base)) {
    used.add(base);
    return base;
  }
  for (let index = 2; ; index += 1) {
    const suffix = `-${index}`;
    const stem = base.slice(0, Math.max(1, maximumLength - suffix.length)).replace(/-+$/g, "") || fallback;
    const candidate = `${stem}${suffix}`.slice(0, maximumLength);
    if (!used.has(candidate)) {
      used.add(candidate);
      return candidate;
    }
  }
}

function safeStringArray(values, maximum, maximumLength = 220) {
  return [...new Set((Array.isArray(values) ? values : [])
    .map((value) => safeText(value, "", maximumLength))
    .filter(Boolean))]
    .slice(0, maximum);
}

function comparableName(value) {
  return safeText(value, "", 180)
    .normalize("NFKD")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

// Consequential treatment cannot be made safe merely by trimming the model's
// sentence. When the evidence is provisional, keep observation/checking steps
// and withhold anything that changes tissue, soil chemistry, pest exposure, or
// a person/pet's behaviour around a potentially toxic plant.
const consequentialActionPattern = new RegExp([
  "pesticid", "insecticid", "fungicid", "herbicid", "miticid",
  "fertili[sz]", "\\bfeed(?:ing)?\\b", "\\bdose\\b", "\\bdilut",
  "\\bspray\\b", "neem", "horticultural oil", "chemical treatment",
  "\\brepot", "root wash", "bare root", "root prun", "hard prun",
  "\\bprun", "\\bcut (?:back|off|away)", "remove (?:the )?(?:roots|stem|leaves)",
  "\\bingest", "\\beat(?:en|ing)?\\b", "\\bedible\\b", "\\btoxic",
  "safe for (?:children|kids|pets|cats|dogs|people|humans)"
].join("|"), "i");

const unsupportedSafetyActionPattern = new RegExp([
  "pesticid", "insecticid", "fungicid", "herbicid", "miticid",
  "\\bdose\\b", "\\bdilut", "chemical treatment",
  "\\bbleach\\b", "\\bammonia\\b", "hydrogen peroxide", "\\bperoxide\\b",
  "rubbing alcohol", "isopropyl", "\\bvinegar\\b", "dish soap", "home remed",
  "\\bmix(?:ing)?\\b.{0,80}\\b(?:bleach|ammonia|peroxide|alcohol|vinegar|soap)\\b",
  "\\b(?:bleach|ammonia|peroxide|alcohol|vinegar|soap)\\b.{0,80}\\bmix",
  "\\bingest", "\\beat(?:en|ing)?\\b", "\\bedible\\b", "\\btoxic",
  "safe for (?:children|kids|pets|cats|dogs|people|humans)"
].join("|"), "i");

function isConsequentialAction(value) {
  return consequentialActionPattern.test(String(value ?? ""));
}

function conservativeActions(values) {
  return safeStringArray(values, 5, 300).filter((action) => !isConsequentialAction(action));
}

function evidenceBackedActions(values) {
  return safeStringArray(values, 5, 300)
    .filter((action) => !unsupportedSafetyActionPattern.test(action));
}

function safeGeneratedStatement(value, fallback, maximumLength = 600) {
  const statement = safeText(value, fallback, maximumLength);
  return unsupportedSafetyActionPattern.test(statement) ? fallback : statement;
}

function safeAvoidActions(values) {
  return safeStringArray(values, 5, 300).filter((action) => {
    if (!unsupportedSafetyActionPattern.test(action)) return true;
    return /^(?:do not|don't|never|avoid|hold off|keep away|stop)\b/i.test(action);
  });
}

const provisionalFallbackActions = Object.freeze([
  "Check the soil moisture a few centimetres below the surface before changing watering",
  "Keep light and routine care steady while you gather clearer evidence",
  "Take a sharp close-up of the affected area and the stem-soil line"
]);

function sortedByConfidence(values, maximum, transform) {
  return [...(Array.isArray(values) ? values : [])]
    .filter((value) => value && typeof value === "object" && !Array.isArray(value))
    .map(transform)
    .sort((left, right) => right.confidence - left.confidence)
    .slice(0, maximum);
}

function safeCandidates(values) {
  const used = new Set();
  return sortedByConfidence(values, 5, (value, index) => ({
    id: uniqueIdentifier(value.id, `candidate-${index + 1}`, used),
    commonName: safeText(value.commonName, "Unknown plant", 120),
    scientificName: safeText(value.scientificName, "Identity uncertain", 160),
    confidence: bounded(value.confidence),
    distinguishingTraits: safeStringArray(value.distinguishingTraits, 5, 180),
    regionalFit: safeText(value.regionalFit, "", 180)
  }));
}

function safeConditions(values) {
  const used = new Set();
  return sortedByConfidence(values, 5, (value, index) => ({
    id: uniqueIdentifier(value.id, `condition-${index + 1}`, used),
    name: safeText(value.name, "Uncertain condition", 120),
    confidence: bounded(value.confidence),
    explanation: safeText(value.explanation, "Visual evidence is inconclusive.", 600),
    evidence: safeStringArray(value.evidence, 5, 220),
    alternativeExplanation: safeText(value.alternativeExplanation, "", 400)
  }));
}

function safeIndicatorFindings(values, conditionConfidence, assessmentAvailable) {
  const kinds = ["foliage", "posture", "growth"];
  const states = new Set(["good", "watch", "neutral", "unavailable"]);
  const byKind = new Map();
  for (const value of Array.isArray(values) ? values.slice(0, 12) : []) {
    if (!value || typeof value !== "object" || !kinds.includes(value.kind)) continue;
    const evidence = safeStringArray(value.evidence, 5, 220);
    let state = states.has(value.state) ? value.state : "unavailable";
    if (!assessmentAvailable || evidence.length === 0) state = "unavailable";
    const confidence = Math.min(conditionConfidence, bounded(value.confidence));
    const severity = state === "watch"
      ? Math.max(1, Math.min(3, Math.round(Number(value.severity) || 1)))
      : 0;
    const finding = {
      kind: value.kind,
      state,
      severity,
      confidence: state === "unavailable" ? 0 : confidence,
      evidence: state === "unavailable" ? [] : evidence
    };
    const existing = byKind.get(value.kind);
    if (!existing || finding.confidence > existing.confidence) byKind.set(value.kind, finding);
  }
  return kinds.map((kind) => byKind.get(kind) ?? ({
    kind,
    state: "unavailable",
    severity: 0,
    confidence: 0,
    evidence: []
  }));
}

function safeQuestions(values) {
  const usedQuestionIDs = new Set();
  return (Array.isArray(values) ? values : [])
    .filter((value) => value && typeof value === "object" && !Array.isArray(value))
    // Inspect a bounded surplus before taking three: malformed one-option
    // questions at the front must not crowd valid later questions out.
    .slice(0, 12)
    .map((value, index) => {
      const usedOptionIDs = new Set();
      return {
        // Answer ids return to request validation, whose key ceiling is 64.
        id: uniqueIdentifier(value.id, `question-${index + 1}`, usedQuestionIDs, 64),
        prompt: safeText(value.prompt, "Add another clear observation.", 240),
        options: (Array.isArray(value.options) ? value.options : [])
          .filter((option) => option && typeof option === "object" && !Array.isArray(option))
          .slice(0, 4)
          .map((option, optionIndex) => ({
            id: uniqueIdentifier(option.id, `option-${optionIndex + 1}`, usedOptionIDs),
            title: safeText(option.title, `Option ${optionIndex + 1}`, 120)
          })),
        reason: safeText(value.reason, "", 300)
      };
    })
    .filter((question) => question.options.length >= 2)
    .slice(0, 3);
}

// A check ("scratch the trunk", "push a skewer into the rootball") is only
// worth ticking if the owner can say what it turned up. Each check carries the
// results it could plausibly show, with what each means and the step it leads
// to, so the plant page can answer the owner instead of leaving them holding a
// finding. A check is kept only when it names an action that survived the
// filters above, and every next step passes the same action filter the plan
// itself does: an outcome is not a side door for a treatment the plan withheld.
function safeChecks(values, nextActions, keepStep) {
  const actionByKey = new Map(nextActions.map((action) => [comparableName(action), action]));
  const seen = new Set();
  return (Array.isArray(values) ? values : [])
    .filter((value) => value && typeof value === "object" && !Array.isArray(value))
    .slice(0, 10)
    .flatMap((value) => {
      const key = comparableName(value.action);
      const action = actionByKey.get(key);
      if (!action || seen.has(key)) return [];
      const usedOutcomeIDs = new Set();
      const outcomes = (Array.isArray(value.outcomes) ? value.outcomes : [])
        .filter((outcome) => outcome && typeof outcome === "object" && !Array.isArray(outcome))
        .slice(0, 3)
        .map((outcome, index) => {
          const nextStep = safeText(outcome.nextStep, "", 300);
          return {
            id: uniqueIdentifier(outcome.id, `outcome-${index + 1}`, usedOutcomeIDs, 64),
            title: safeText(outcome.title, "", 80),
            meaning: safeGeneratedStatement(outcome.meaning, "", 300),
            nextStep: nextStep && keepStep(nextStep) ? nextStep : ""
          };
        })
        .filter((outcome) => outcome.title && outcome.meaning);
      if (outcomes.length < 2) return [];
      seen.add(key);
      return [{ action, outcomes }];
    })
    .slice(0, 5);
}

// Growing conditions are read by arithmetic, not by a person, so anything off
// the allowed list has to become "unknown" rather than reach the client as prose.
// The dry-down estimate treats "unknown" as a reason to widen its uncertainty,
// which is the honest outcome for a pot nobody could see.
const growingConditionVocabulary = Object.freeze({
  potMaterial: ["terracotta", "plastic", "glazed", "metal", "fabric", "concrete", "unpotted", "unknown"],
  potSize: ["small", "medium", "large", "xlarge", "unknown"],
  drainage: ["drains", "cachepot", "noHoles", "unknown"],
  substrate: ["gritty", "standard", "dense", "bark", "moss", "semiHydro", "unknown"],
  soilSurface: ["dry", "damp", "wet", "obscured", "unknown"],
  potFit: ["snug", "balanced", "oversized", "unknown"]
});

const allowedSurfaceSigns = new Set([
  "saltCrust", "algae", "mould", "fungusGnats", "moss",
  "hydrophobic", "standingWater", "compacted", "rootsAtSurface", "topDressed"
]);

function safeEnum(value, allowed, fallback = "unknown") {
  return typeof value === "string" && allowed.includes(value) ? value : fallback;
}

function safeGrowingConditions(values) {
  const source = values && typeof values === "object" && !Array.isArray(values) ? values : {};
  const conditions = {};
  for (const [field, allowed] of Object.entries(growingConditionVocabulary)) {
    conditions[field] = safeEnum(source[field], allowed);
  }
  conditions.surfaceSigns = [...new Set(
    (Array.isArray(source.surfaceSigns) ? source.surfaceSigns : []).filter((sign) => allowedSurfaceSigns.has(sign))
  )].slice(0, 6);
  conditions.confidence = bounded(source.confidence);
  // A model that saw nothing sometimes still reports a confidence. If every
  // field came back unknown there was nothing to be confident about.
  const sawSomething = Object.entries(growingConditionVocabulary)
    .some(([field]) => conditions[field] !== "unknown") || conditions.surfaceSigns.length > 0;
  if (!sawSomething) conditions.confidence = 0;
  return conditions;
}

const evidenceSubjectKinds = ["plant", "nonPlant", "multiplePlants", "uncertain"];
const retakeStages = ["wholePlant", "leaf", "stem", "symptom", "none"];

function safeEvidenceQuality(values) {
  const source = values && typeof values === "object" && !Array.isArray(values) ? values : {};
  return {
    subjectKind: safeEnum(source.subjectKind, evidenceSubjectKinds, "uncertain"),
    subjectCount: Math.max(0, Math.min(10, Math.round(Number(source.subjectCount) || 0))),
    sameSubject: source.sameSubject === true,
    usableForIdentification: source.usableForIdentification === true,
    usableForCondition: source.usableForCondition === true,
    qualityScore: bounded(source.qualityScore),
    retakeStage: safeEnum(source.retakeStage, retakeStages, "wholePlant"),
    retakeReason: safeText(source.retakeReason, "The photos do not show one readable plant clearly enough.", 240)
  };
}

export function sanitizePlantAnalysis(result, request) {
  if (!result?.identification || !result?.condition) {
    throw new Error("Plant analysis is missing required identity or condition data.");
  }

  const evidenceQuality = safeEvidenceQuality(result.evidenceQuality);
  const hasOneUsablePlant = evidenceQuality.subjectKind === "plant"
    && evidenceQuality.subjectCount === 1
    && evidenceQuality.sameSubject
    && evidenceQuality.usableForIdentification;
  const candidates = safeCandidates(result.identification.candidates);
  const imageQualityWarnings = safeStringArray([
    ...(Array.isArray(result.identification.imageQualityWarnings)
      ? result.identification.imageQualityWarnings
      : []),
    ...((Array.isArray(request?.images) ? request.images : [])
      .flatMap((image) => Array.isArray(image?.qualityWarnings) ? image.qualityWarnings : []))
  ], 6, 220);
  const topConfidence = candidates[0]?.confidence ?? bounded(result.identification.confidence);
  const isUnknown = result.identification.isUnknown === true
    || topConfidence < 60
    || candidates.length === 0
    || !hasOneUsablePlant;
  // A strong top match with daylight over the runner-up is stated as fact; the
  // app still offers the alternatives. Asking the user to confirm every single
  // scan reads as "we don't actually know", so reserve it for close calls.
  const runnerUpConfidence = candidates[1]?.confidence ?? 0;
  const isDecisive = !isUnknown
    && topConfidence >= 85
    && topConfidence - runnerUpConfidence >= 12
    && candidates[0].distinguishingTraits.length >= 2
    && evidenceQuality.qualityScore >= 65
    && imageQualityWarnings.length === 0;
  const existing = request?.mode === "diagnose" ? request?.existingPlant : undefined;
  const topCandidate = candidates[0];
  // Common names are display labels, not identifiers: poison ivy and English
  // ivy can both arrive as "ivy" while being unrelated plants. Until canonical
  // taxon ids are stored, only an exact scientific-name match can ground the
  // existing record.
  const identityMatchesExisting = Boolean(existing && topCandidate)
    && comparableName(topCandidate.scientificName) === comparableName(existing.scientificName);
  // A prior plant record is evidence, not authority over the pixels. It can
  // keep a matching known identity stable, but it can never suppress a visual
  // conflict or turn a failed plant detection into a confirmed diagnosis.
  const identityIsGrounded = isDecisive
    || (!isUnknown && identityMatchesExisting && topConfidence >= 60);

  const identification = {
    // Candidate zero is the canonical identity. Keeping separate model-written
    // top fields allowed the app to display one species with another species'
    // confidence and decisiveness calculation.
    commonName: topCandidate?.commonName ?? "Unknown plant",
    scientificName: topCandidate?.scientificName ?? "Identity uncertain",
    confidence: topConfidence,
    candidates,
    isUnknown,
    requiresConfirmation: !identityIsGrounded,
    // Region is request metadata. Echoing the model's copy made provenance
    // mutable and let an output inconsistency escape into user-facing copy.
    regionCode: safeText(request?.regionCode, "unknown", 8),
    alternatives: candidates.slice(1).map((candidate) => candidate.commonName || candidate.scientificName),
    distinguishingTraits: topCandidate?.distinguishingTraits
      ?? safeStringArray(result.identification.distinguishingTraits, 5, 180),
    imageQualityWarnings
  };

  const reportedHealthScore = bounded(result.condition.healthScore, 50);
  const conditionConfidence = bounded(result.condition.confidence);
  let possibleConditions = safeConditions(result.condition.possibleConditions)
    .map((candidate) => ({
      ...candidate,
      // A cause cannot be more certain than the visual assessment supporting
      // it. This also stops a readable-photo score from masquerading as cause
      // likelihood in downstream surfaces.
      confidence: Math.min(candidate.confidence, conditionConfidence),
      explanation: safeGeneratedStatement(
        candidate.explanation,
        "The visible evidence is not specific enough to support treatment.",
        600
      )
    }))
    // A named disease/cause with no photo-grounded sign and no benign
    // alternative is a guess, not a differential. Do not let confidence alone
    // promote it into the user's plan.
    .filter((candidate) => candidate.evidence.length > 0 && Boolean(candidate.alternativeExplanation));
  // One round of questions, then a verdict. Once the owner has answered, a
  // further set of questions is not evidence gathering; it is the loop the
  // owner walked into where every "Refine" returned three fresh questions
  // and never a conclusion. Answered scans conclude.
  const ownerHasAnswered = Object.keys(request?.answers ?? {}).length > 0;
  let questions = request?.mode === "diagnose" && !ownerHasAnswered
    ? safeQuestions(result.condition.questions)
    : [];
  const hasStrongCause = possibleConditions.length === 0
    ? reportedHealthScore >= 75 && safeStringArray(result.condition.concerns, 5, 220).length === 0
    : possibleConditions[0].confidence >= 55;
  const assessmentAvailable = hasOneUsablePlant
    && evidenceQuality.usableForCondition
    && conditionConfidence >= 45;
  // A missing/unreadable condition must not turn an arbitrary provider score
  // into "urgent". A neutral monitor value keeps the transport contract intact
  // while assessmentAvailable/actionability drive the actual UX and storage.
  const healthScore = assessmentAvailable ? reportedHealthScore : 60;
  const healthBand = healthBandForScore(healthScore);
  const evidenceIsInsufficient = isUnknown || !assessmentAvailable;
  const evidenceIsProvisional = !identityIsGrounded
    || conditionConfidence < 70
    || identification.imageQualityWarnings.length > 0
    || questions.length > 0
    || !hasStrongCause;
  const actionability = evidenceIsInsufficient
    ? "insufficientEvidence"
    : evidenceIsProvisional ? "provisional" : "actionable";
  const modelActions = actionability === "actionable"
    ? evidenceBackedActions(result.condition.nextActions)
    : conservativeActions(result.condition.nextActions);
  const condition = {
    healthScore,
    // Score owns the band. Accepting both independently allowed impossible
    // states such as a 90/100 plant marked urgent.
    healthBand,
    confidence: conditionConfidence,
    summary: safeGeneratedStatement(
      result.condition.summary,
      "Visual evidence is inconclusive.",
      1_000
    ),
    positiveSigns: safeStringArray(result.condition.positiveSigns, 5, 220),
    concerns: safeStringArray(result.condition.concerns, 5, 220),
    possibleCauses: safeStringArray(result.condition.possibleCauses, 5, 220)
      .filter((cause) => !unsupportedSafetyActionPattern.test(cause)),
    nextActions: modelActions.length > 0 ? modelActions : [...provisionalFallbackActions],
    possibleConditions,
    questions,
    actionsToAvoid: safeAvoidActions(result.condition.actionsToAvoid),
    urgentFlags: healthBand === "urgent" || healthBand === "attention"
      ? safeStringArray(result.condition.urgentFlags, 4, 300)
        .filter((flag) => !unsupportedSafetyActionPattern.test(flag))
      : [],
    followUpDays: followUpDaysForBand(result.condition.followUpDays, healthBand),
    actionability,
    assessmentAvailable,
    indicatorFindings: safeIndicatorFindings(
      result.condition.indicatorFindings,
      conditionConfidence,
      assessmentAvailable
    )
  };

  if (isUnknown) {
    identification.commonName = "Unknown plant";
    identification.scientificName = "Identity uncertain";
    identification.distinguishingTraits = [];
    identification.requiresConfirmation = true;
    condition.nextActions = [
      "Take a clear whole-plant, leaf and stem photo before changing care",
      "Track visible changes and soil moisture for the next 7 days",
      "Keep it separate from edible plants until its identity is confirmed"
    ];
    condition.actionsToAvoid = [
      "Do not ingest it or use it as medicine",
      "Do not assume it is safe for children or pets",
      "Do not apply pesticide, fertiliser or chemical treatment while identity is uncertain"
    ];
  }

  if (!assessmentAvailable) {
    condition.summary = "These photos do not support a reliable condition assessment yet.";
    condition.possibleCauses = [];
    condition.possibleConditions = [];
    condition.urgentFlags = [];
  }

  if (request?.mode !== "diagnose") {
    // Identification and baseline scans must never accidentally grow a disease
    // differential or a clarification workflow because the provider ignored
    // the mode instruction.
    condition.possibleConditions = [];
    condition.questions = [];
  }

  // Last, so the checks match the actions the owner will actually see after
  // the unknown-identity and unavailable-assessment overrides above.
  condition.checks = safeChecks(
    result.condition.checks,
    condition.nextActions,
    actionability === "actionable"
      ? (step) => !unsupportedSafetyActionPattern.test(step)
      : (step) => !unsupportedSafetyActionPattern.test(step) && !isConsequentialAction(step)
  );

  return {
    identification,
    condition,
    evidenceQuality,
    growingConditions: safeGrowingConditions(result.growingConditions),
    providerName: safeText(result.providerName, "Plant analysis provider", 120),
    analysisVersion: "2026-10-04.v5",
    limitations: [...new Set([
      ...safeStringArray(result.limitations, 4, 240),
      ...(!hasOneUsablePlant ? [evidenceQuality.retakeReason] : []),
      "Visual assessment only",
      "Confidence values are estimates, not certainty"
    ])].slice(0, 6)
  };
}
