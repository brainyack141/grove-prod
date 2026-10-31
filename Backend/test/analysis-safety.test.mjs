import assert from "node:assert/strict";
import test from "node:test";
import { sanitizePlantAnalysis } from "../analysis-safety.mjs";

function result(overrides = {}) {
  return {
    evidenceQuality: {
      subjectKind: "plant",
      subjectCount: 1,
      sameSubject: true,
      usableForIdentification: true,
      usableForCondition: true,
      qualityScore: 82,
      retakeStage: "none",
      retakeReason: "",
      ...overrides.evidenceQuality
    },
    identification: {
      commonName: "Plausible plant",
      scientificName: "Planta probabilis",
      confidence: 42,
      alternatives: [],
      distinguishingTraits: ["A trait"],
      candidates: [],
      isUnknown: false,
      requiresConfirmation: false,
      regionCode: "",
      imageQualityWarnings: [],
      ...overrides.identification
    },
    condition: {
      healthScore: 64,
      healthBand: "monitor",
      confidence: 63,
      summary: "Uncertain",
      positiveSigns: [],
      concerns: [],
      possibleCauses: [],
      nextActions: ["Apply fertiliser"],
      possibleConditions: [],
      questions: [],
      actionsToAvoid: [],
      urgentFlags: [],
      followUpDays: 7,
      ...overrides.condition
    },
    growingConditions: overrides.growingConditions,
    providerName: "Test",
    limitations: []
  };
}

test("low-confidence identity becomes an unknown profile with bounded guidance", () => {
  const sanitized = sanitizePlantAnalysis(result(), { mode: "add", regionCode: "GB" });
  assert.equal(sanitized.identification.isUnknown, true);
  assert.equal(sanitized.identification.commonName, "Unknown plant");
  assert.equal(sanitized.identification.requiresConfirmation, true);
  assert.equal(sanitized.identification.regionCode, "GB");
  assert.equal(sanitized.condition.nextActions.some((action) => action.includes("fertiliser")), false);
  assert.equal(sanitized.condition.actionsToAvoid.some((action) => action.includes("Do not ingest")), true);
});

test("ranked candidates and conditions are sorted, and a decisive match is stated rather than queried", () => {
  const sanitized = sanitizePlantAnalysis(result({
    identification: {
      confidence: 80,
      candidates: [
        { id: "second", commonName: "Second", scientificName: "Second plant", confidence: 62, distinguishingTraits: [], regionalFit: "GB" },
        {
          id: "first", commonName: "First", scientificName: "First plant", confidence: 88,
          distinguishingTraits: ["Trait one", "Trait two"], regionalFit: "GB"
        }
      ]
    },
    condition: {
      possibleConditions: [
        { id: "low", name: "Low", confidence: 20, explanation: "", evidence: ["Sign L"], alternativeExplanation: "Benign L" },
        { id: "high", name: "High", confidence: 76, explanation: "", evidence: ["Sign H"], alternativeExplanation: "Benign H" }
      ]
    }
  }), { mode: "diagnose", regionCode: "GB" });

  assert.deepEqual(sanitized.identification.candidates.map((candidate) => candidate.id), ["first", "second"]);
  assert.deepEqual(sanitized.condition.possibleConditions.map((condition) => condition.id), ["high", "low"]);
  assert.equal(sanitized.identification.commonName, "First");
  assert.equal(sanitized.identification.scientificName, "First plant");
  assert.equal(sanitized.identification.confidence, 88);
  // 88% with 26 points of daylight over the runner-up is stated as fact; the
  // app still lists the alternatives one tap away.
  assert.equal(sanitized.identification.requiresConfirmation, false);
});

test("a close call still asks the user to confirm the identity", () => {
  const closeRunnerUp = sanitizePlantAnalysis(result({
    identification: {
      confidence: 88,
      candidates: [
        { id: "first", commonName: "First", scientificName: "First plant", confidence: 88, distinguishingTraits: [], regionalFit: "GB" },
        { id: "second", commonName: "Second", scientificName: "Second plant", confidence: 84, distinguishingTraits: [], regionalFit: "GB" }
      ]
    }
  }), { mode: "identify", regionCode: "GB" });

  const lukewarmTopMatch = sanitizePlantAnalysis(result({
    identification: {
      confidence: 72,
      candidates: [
        { id: "first", commonName: "First", scientificName: "First plant", confidence: 72, distinguishingTraits: [], regionalFit: "GB" }
      ]
    }
  }), { mode: "identify", regionCode: "GB" });

  assert.equal(closeRunnerUp.identification.isUnknown, false);
  assert.equal(closeRunnerUp.identification.requiresConfirmation, true);
  assert.equal(lukewarmTopMatch.identification.isUnknown, false);
  assert.equal(lukewarmTopMatch.identification.requiresConfirmation, true);
});

test("follow-up intervals are constrained to a safe scheduling range", () => {
  const tooSoon = sanitizePlantAnalysis(result({ condition: { followUpDays: -12 } }), { mode: "diagnose" });
  const tooLate = sanitizePlantAnalysis(result({ condition: { followUpDays: 365 } }), { mode: "diagnose" });

  assert.equal(tooSoon.condition.followUpDays, 3);
  assert.equal(tooLate.condition.followUpDays, 14);
});

test("health band is derived from score and cause confidence cannot exceed the evidence", () => {
  const sanitized = sanitizePlantAnalysis(result({
    identification: {
      candidates: [{
        id: "basil", commonName: "Basil", scientificName: "Ocimum basilicum",
        confidence: 92, distinguishingTraits: [], regionalFit: "GB"
      }]
    },
    condition: {
      healthScore: 94,
      healthBand: "urgent",
      confidence: 61,
      possibleConditions: [{
        id: "rot", name: "Root rot", confidence: 99,
        explanation: "Uncertain", evidence: ["Collapsed lower leaf"], alternativeExplanation: "Dry roots"
      }],
      urgentFlags: ["Act immediately"]
    }
  }), { mode: "diagnose", regionCode: "GB" });

  assert.equal(sanitized.condition.healthBand, "thriving");
  assert.equal(sanitized.condition.possibleConditions[0].confidence, 61);
  assert.deepEqual(sanitized.condition.urgentFlags, []);
});

test("visual indicator findings are complete, bounded, and fail closed", () => {
  const sanitized = sanitizePlantAnalysis(result({
    condition: {
      indicatorFindings: [
        {
          kind: "foliage",
          state: "watch",
          severity: 99,
          confidence: 130,
          evidence: ["Brown edge is visible", "Brown edge is visible"]
        },
        {
          kind: "posture",
          state: "good",
          severity: 2,
          confidence: 84,
          evidence: ["Stems are upright"]
        }
      ]
    }
  }), { mode: "diagnose" });

  assert.deepEqual(sanitized.condition.indicatorFindings.map(({ kind }) => kind), [
    "foliage", "posture", "growth"
  ]);
  assert.equal(sanitized.condition.indicatorFindings[0].severity, 3);
  assert.equal(
    sanitized.condition.indicatorFindings[0].confidence,
    63,
    "A visual sub-finding cannot be more certain than the condition assessment."
  );
  assert.deepEqual(sanitized.condition.indicatorFindings[0].evidence, ["Brown edge is visible"]);
  assert.equal(sanitized.condition.indicatorFindings[1].severity, 0);
  assert.equal(sanitized.condition.indicatorFindings[2].state, "unavailable");
  assert.equal(sanitized.condition.indicatorFindings[2].confidence, 0);
  assert.deepEqual(sanitized.condition.indicatorFindings[2].evidence, []);
});

test("provisional evidence withholds consequential treatment and cannot become actionable", () => {
  const sanitized = sanitizePlantAnalysis(result({
    identification: {
      candidates: [{
        id: "plant", commonName: "Plant", scientificName: "Planta probabilis",
        confidence: 72, distinguishingTraits: [], regionalFit: "GB"
      }]
    },
    condition: {
      confidence: 58,
      nextActions: ["Apply fungicide", "Repot immediately", "Check the soil moisture"],
      possibleConditions: [{
        id: "spots", name: "Leaf spotting", confidence: 50,
        explanation: "Possible", evidence: ["spots"], alternativeExplanation: "Old damage"
      }]
    }
  }), { mode: "diagnose", regionCode: "GB" });

  assert.equal(sanitized.condition.actionability, "provisional");
  assert.deepEqual(sanitized.condition.nextActions, ["Check the soil moisture"]);
});

test("an existing record only confirms a matching visual identity", () => {
  const request = {
    mode: "diagnose",
    existingPlant: {
      commonName: "Basil",
      scientificName: "Ocimum basilicum"
    }
  };
  const matching = sanitizePlantAnalysis(result({
    identification: {
      candidates: [{
        id: "basil", commonName: "Basil", scientificName: "Ocimum basilicum",
        confidence: 76, distinguishingTraits: []
      }]
    }
  }), request);
  const conflicting = sanitizePlantAnalysis(result({
    identification: {
      candidates: [{
        id: "mint", commonName: "Mint", scientificName: "Mentha spicata",
        confidence: 76, distinguishingTraits: []
      }]
    }
  }), request);

  assert.equal(matching.identification.requiresConfirmation, false);
  assert.equal(conflicting.identification.requiresConfirmation, true);
});

test("identify mode cannot leak a diagnosis differential or questions", () => {
  const sanitized = sanitizePlantAnalysis(result({
    identification: {
      candidates: [{
        id: "basil", commonName: "Basil", scientificName: "Ocimum basilicum",
        confidence: 91, distinguishingTraits: []
      }]
    },
    condition: {
      possibleConditions: [{
        id: "rot", name: "Root rot", confidence: 90,
        explanation: "Claim", evidence: [], alternativeExplanation: "None"
      }],
      questions: [{
        id: "soil", prompt: "Wet?", reason: "Cause",
        options: [{ id: "yes", title: "Yes" }, { id: "no", title: "No" }]
      }]
    }
  }), { mode: "identify", regionCode: "GB" });

  assert.deepEqual(sanitized.condition.possibleConditions, []);
  assert.deepEqual(sanitized.condition.questions, []);
});

test("non-plants and mixed subjects fail closed without an urgent health claim", () => {
  for (const evidenceQuality of [
    { subjectKind: "nonPlant", subjectCount: 1, sameSubject: true },
    { subjectKind: "multiplePlants", subjectCount: 2, sameSubject: false }
  ]) {
    const sanitized = sanitizePlantAnalysis(result({
      evidenceQuality,
      identification: {
        confidence: 99,
        candidates: [{
          id: "fiction", commonName: "Fiction plant", scientificName: "Ficta artificialis",
          confidence: 99, distinguishingTraits: ["green", "leaf-like"]
        }]
      },
      condition: { healthScore: 0, healthBand: "urgent", confidence: 95 }
    }), { mode: "diagnose" });

    assert.equal(sanitized.identification.isUnknown, true);
    assert.equal(sanitized.condition.assessmentAvailable, false);
    assert.equal(sanitized.condition.healthBand, "monitor");
    assert.equal(sanitized.condition.actionability, "insufficientEvidence");
    assert.deepEqual(sanitized.condition.urgentFlags, []);
  }
});

test("a shared common name cannot confirm a conflicting scientific identity", () => {
  const sanitized = sanitizePlantAnalysis(result({
    identification: {
      candidates: [{
        id: "poison-ivy", commonName: "Ivy", scientificName: "Toxicodendron radicans",
        confidence: 78, distinguishingTraits: ["three leaflets", "woody vine"]
      }]
    }
  }), {
    mode: "diagnose",
    existingPlant: { commonName: "Ivy", scientificName: "Hedera helix" }
  });

  assert.equal(sanitized.identification.requiresConfirmation, true);
  assert.notEqual(sanitized.condition.actionability, "actionable");
});

test("one blurry unsupported candidate is never treated as decisive", () => {
  const sanitized = sanitizePlantAnalysis(result({
    evidenceQuality: { qualityScore: 40 },
    identification: {
      imageQualityWarnings: ["soft focus"],
      candidates: [{
        id: "guess", commonName: "Guess", scientificName: "Planta guessii",
        confidence: 99, distinguishingTraits: []
      }]
    }
  }), { mode: "identify" });

  assert.equal(sanitized.identification.isUnknown, false);
  assert.equal(sanitized.identification.requiresConfirmation, true);
});

test("unsupported disease claims cannot make a diagnosis actionable", () => {
  const sanitized = sanitizePlantAnalysis(result({
    identification: {
      candidates: [{
        id: "basil", commonName: "Basil", scientificName: "Ocimum basilicum",
        confidence: 94, distinguishingTraits: ["opposite leaves", "square stem"]
      }]
    },
    condition: {
      healthScore: 42,
      confidence: 91,
      possibleConditions: [{
        id: "root-rot", name: "Root rot", confidence: 91,
        explanation: "Certain root rot", evidence: [], alternativeExplanation: ""
      }]
    }
  }), { mode: "diagnose" });

  assert.deepEqual(sanitized.condition.possibleConditions, []);
  assert.equal(sanitized.condition.actionability, "provisional");
});

test("unsafe generated instructions are removed across actionable result fields", () => {
  const sanitized = sanitizePlantAnalysis(result({
    identification: {
      candidates: [{
        id: "basil", commonName: "Basil", scientificName: "Ocimum basilicum",
        confidence: 95, distinguishingTraits: ["opposite leaves", "square stem"]
      }]
    },
    condition: {
      healthScore: 25,
      confidence: 92,
      summary: "Mix bleach with ammonia and pour it into the pot.",
      possibleCauses: ["Use hydrogen peroxide"],
      nextActions: ["Apply fungicide", "Mix bleach with ammonia", "Isolate the plant"],
      possibleConditions: [{
        id: "pest", name: "Visible pest", confidence: 88,
        explanation: "Spray it with bleach", evidence: ["visible insects"],
        alternativeExplanation: "Harmless soil insect"
      }],
      urgentFlags: ["Use peroxide immediately", "Keep it away from other plants"],
      questions: []
    }
  }), { mode: "diagnose" });

  assert.equal(sanitized.condition.actionability, "actionable");
  assert.equal(sanitized.condition.summary, "Visual evidence is inconclusive.");
  assert.deepEqual(sanitized.condition.possibleCauses, []);
  assert.deepEqual(sanitized.condition.nextActions, ["Isolate the plant"]);
  assert.equal(sanitized.condition.possibleConditions[0].explanation.includes("bleach"), false);
  assert.deepEqual(sanitized.condition.urgentFlags, ["Keep it away from other plants"]);
});

test("provider strings, enums, arrays, and nested questions are normalized for the app contract", () => {
  const sanitized = sanitizePlantAnalysis(result({
    identification: {
      confidence: 90,
      candidates: [{
        id: "Unsafe Candidate!!",
        commonName: "A".repeat(200),
        scientificName: "Safe species",
        confidence: 120,
        distinguishingTraits: Array.from({ length: 20 }, (_, index) => `Trait ${index}`),
        regionalFit: "GB"
      }],
      imageQualityWarnings: Array.from({ length: 10 }, (_, index) => `Warning ${index}`),
      injectedField: "must not escape"
    },
    condition: {
      healthBand: "catastrophic",
      summary: "S".repeat(2_000),
      questions: [{
        id: "soil moisture",
        prompt: "How wet?",
        options: [{ id: "wet", title: "Wet" }],
        reason: "Distinguishes moisture stress"
      }]
    }
  }), { mode: "identify", regionCode: "GB" });

  assert.equal(sanitized.identification.candidates[0].id, "unsafe-candidate");
  assert.equal(sanitized.identification.candidates[0].commonName.length, 120);
  assert.equal(sanitized.identification.candidates[0].confidence, 100);
  assert.equal(sanitized.identification.candidates[0].distinguishingTraits.length, 5);
  assert.equal(sanitized.identification.imageQualityWarnings.length, 6);
  assert.equal("injectedField" in sanitized.identification, false);
  assert.equal(sanitized.condition.healthBand, "monitor");
  assert.equal(sanitized.condition.summary.length, 1_000);
  assert.deepEqual(sanitized.condition.questions, []);
});

test("provider ids are unique and iterative question ids fit the answer contract", () => {
  const question = (id, optionIDs = ["same", "same"]) => ({
    id,
    prompt: "What changed?",
    options: optionIDs.map((optionID, index) => ({ id: optionID, title: `Option ${index + 1}` })),
    reason: "Separates the likely causes"
  });
  const sanitized = sanitizePlantAnalysis(result({
    identification: {
      confidence: 90,
      candidates: [
        { id: "same", commonName: "One", scientificName: "Plant one", confidence: 90, distinguishingTraits: [] },
        { id: "same", commonName: "Two", scientificName: "Plant two", confidence: 70, distinguishingTraits: [] }
      ]
    },
    condition: {
      possibleConditions: [
        { id: "same", name: "One", confidence: 80, explanation: "", evidence: ["One sign"], alternativeExplanation: "One alternative" },
        { id: "same", name: "Two", confidence: 60, explanation: "", evidence: ["Two sign"], alternativeExplanation: "Two alternative" }
      ],
      questions: [
        question("invalid", ["only-one"]),
        question("q".repeat(90)),
        question("q".repeat(90)),
        question("third-valid")
      ]
    }
  }), { mode: "diagnose" });

  assert.equal(new Set(sanitized.identification.candidates.map(({ id }) => id)).size, 2);
  assert.equal(new Set(sanitized.condition.possibleConditions.map(({ id }) => id)).size, 2);
  assert.equal(sanitized.condition.questions.length, 3, "An invalid first question must not crowd out a valid later one.");
  assert.equal(new Set(sanitized.condition.questions.map(({ id }) => id)).size, 3);
  assert.equal(sanitized.condition.questions.every(({ id }) => id.length <= 64), true);
  assert.equal(
    sanitized.condition.questions.every(({ options }) => new Set(options.map(({ id }) => id)).size === options.length),
    true
  );
});

test("growing conditions default to unknown when the model omits them", () => {
  const sanitized = sanitizePlantAnalysis(result(), {});

  assert.deepEqual(sanitized.growingConditions, {
    potMaterial: "unknown",
    potSize: "unknown",
    drainage: "unknown",
    substrate: "unknown",
    soilSurface: "unknown",
    potFit: "unknown",
    surfaceSigns: [],
    confidence: 0
  });
});

test("growing conditions keep the allowed vocabulary and drop everything else", () => {
  const sanitized = sanitizePlantAnalysis(
    result({
      growingConditions: {
        potMaterial: "terracotta",
        potSize: "enormous",
        drainage: "cachepot",
        substrate: "standard",
        soilSurface: "damp",
        surfaceSigns: ["algae", "algae", "haunted", "fungusGnats"],
        potFit: "oversized",
        confidence: 140
      }
    }),
    {}
  );

  assert.equal(sanitized.growingConditions.potMaterial, "terracotta");
  // Off-vocabulary becomes unknown rather than reaching the client as prose:
  // the dry-down estimate reads these by arithmetic, not by eye.
  assert.equal(sanitized.growingConditions.potSize, "unknown");
  assert.equal(sanitized.growingConditions.drainage, "cachepot");
  assert.deepEqual(sanitized.growingConditions.surfaceSigns, ["algae", "fungusGnats"]);
  assert.equal(sanitized.growingConditions.confidence, 100);
});

test("a growing-conditions read that saw nothing cannot claim confidence", () => {
  const sanitized = sanitizePlantAnalysis(
    result({ growingConditions: { potMaterial: "unknown", surfaceSigns: [], confidence: 85 } }),
    {}
  );

  assert.equal(sanitized.growingConditions.confidence, 0);
});

test("an unanswered diagnose scan keeps its clarifying questions", () => {
  const sanitized = sanitizePlantAnalysis(
    result({
      condition: {
        questions: [{
          id: "soil-feel",
          prompt: "How does the soil feel a few centimetres down?",
          options: [{ id: "dry", title: "Dry" }, { id: "wet", title: "Wet" }],
          reason: "Separates root stress from ageing."
        }]
      }
    }),
    { mode: "diagnose", answers: {} }
  );

  assert.equal(sanitized.condition.questions.length, 1);
  assert.equal(sanitized.condition.questions[0].id, "soil-feel");
});

test("a scan the owner has already answered concludes instead of asking again", () => {
  const sanitized = sanitizePlantAnalysis(
    result({
      identification: {
        candidates: [{
          id: "pothos", commonName: "Pothos", scientificName: "Epipremnum aureum",
          confidence: 95, distinguishingTraits: ["heart-shaped leaves", "trailing vines"]
        }]
      },
      condition: {
        confidence: 80,
        possibleConditions: [{
          id: "excess-moisture",
          name: "Excess moisture stress",
          confidence: 72,
          explanation: "Wet soil confirmed by the owner.",
          evidence: ["Lower-leaf yellowing"],
          alternativeExplanation: "One old leaf can yellow on its own."
        }],
        nextActions: ["Let the top few centimetres dry before watering again"],
        // The provider ignored the rule and asked a second round anyway.
        questions: [{
          id: "watered-when",
          prompt: "When did you last water?",
          options: [{ id: "today", title: "Today" }, { id: "week", title: "Over a week ago" }],
          reason: "Timing matters."
        }]
      }
    }),
    { mode: "diagnose", answers: { "soil-feel": "Wet or soggy · asked: How does the soil feel a few centimetres down?" } }
  );

  assert.deepEqual(sanitized.condition.questions, []);
  // With the questions gone, nothing else in this result holds it back.
  assert.equal(sanitized.condition.actionability, "actionable");
});

test("em dashes never reach the owner, but number ranges survive", () => {
  const sanitized = sanitizePlantAnalysis(result({
    identification: {
      candidates: [{
        id: "epipremnum-aureum",
        commonName: "Golden pothos",
        scientificName: "Epipremnum aureum",
        confidence: 91,
        distinguishingTraits: ["Heart-shaped leaves — glossy, with gold streaks", "Aerial roots at each node"],
        regionalFit: "Common houseplant"
      }]
    },
    condition: {
      healthScore: 82,
      confidence: 80,
      summary: "Healthy overall — two lower leaves are yellowing. Water when the top 2–3cm are dry — not before.",
      concerns: ["Two yellow lower leaves —"],
      nextActions: ["Check the soil 3cm down — then water if dry"]
    }
  }), { mode: "add", regionCode: "GB" });

  assert.equal(
    sanitized.condition.summary,
    "Healthy overall, two lower leaves are yellowing. Water when the top 2–3cm are dry, not before."
  );
  assert.deepEqual(sanitized.condition.concerns, ["Two yellow lower leaves"]);
  assert.deepEqual(sanitized.condition.nextActions, ["Check the soil 3cm down, then water if dry"]);
  assert.equal(sanitized.identification.distinguishingTraits[0], "Heart-shaped leaves, glossy, with gold streaks");
  assert.equal(JSON.stringify(sanitized).includes("—"), false);
});

test("checks carry tappable outcomes only for actions the owner will see", () => {
  const sanitized = sanitizePlantAnalysis(result({
    identification: {
      candidates: [{
        id: "plant", commonName: "Plant", scientificName: "Planta probabilis",
        confidence: 72, distinguishingTraits: [], regionalFit: "GB"
      }]
    },
    condition: {
      possibleConditions: [{
        id: "dry", name: "Drought stress", confidence: 50,
        explanation: "Possible", evidence: ["bare branches"], alternativeExplanation: "Winter drop"
      }],
      confidence: 58,
      nextActions: [
        "Scratch the lower trunk with a fingernail",
        "Repot immediately",
        "Water the soil until it drains"
      ],
      checks: [
        {
          action: "Scratch the lower trunk with a fingernail.",
          outcomes: [
            { id: "Green", title: "Green under the bark", meaning: "The trunk is alive.", nextStep: "Water deeply once" },
            { id: "brown", title: "Brown and dry", meaning: "This part has died.", nextStep: "Repot it into fresh mix" },
            { id: "brown", title: "  ", meaning: "Dropped: no title.", nextStep: "" }
          ]
        },
        {
          action: "Repot immediately",
          outcomes: [
            { id: "a", title: "Roots white", meaning: "Fine.", nextStep: "" },
            { id: "b", title: "Roots mushy", meaning: "Rot.", nextStep: "" }
          ]
        },
        {
          action: "Water the soil until it drains",
          outcomes: [{ id: "only", title: "One option", meaning: "Not a choice.", nextStep: "" }]
        }
      ]
    }
  }), { mode: "diagnose", regionCode: "GB" });

  assert.equal(sanitized.condition.actionability, "provisional");
  assert.deepEqual(sanitized.condition.checks, [{
    action: "Scratch the lower trunk with a fingernail",
    outcomes: [
      { id: "green", title: "Green under the bark", meaning: "The trunk is alive.", nextStep: "Water deeply once" },
      // A provisional read withholds repotting from the plan, so an outcome
      // cannot reintroduce it.
      { id: "brown", title: "Brown and dry", meaning: "This part has died.", nextStep: "" }
    ]
  }]);
});

test("a result without checks still returns an empty checks array", () => {
  const sanitized = sanitizePlantAnalysis(result(), { mode: "add", regionCode: "GB" });
  assert.deepEqual(sanitized.condition.checks, []);
});
