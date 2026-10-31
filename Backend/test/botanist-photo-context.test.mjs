import assert from "node:assert/strict";
import test from "node:test";
import {
  botanistDirectPhotoDecision,
  botanistPhotoContext
} from "../botanist-photo-context.mjs";

test("attached photo analysis becomes bounded, explicitly untrusted evidence", () => {
  const context = botanistPhotoContext({
    providerName: "Google Gemini",
    identification: {
      commonName: "Monstera",
      scientificName: "Monstera deliciosa",
      confidence: 78,
      requiresConfirmation: true,
      distinguishingTraits: ["fenestrated leaves"],
      candidates: []
    },
    condition: {
      healthBand: "monitor",
      confidence: 72,
      summary: "Pale spotting is visible.",
      concerns: ["pale spotting"],
      positiveSigns: ["new growth"],
      possibleConditions: [{
        name: "Mechanical damage",
        confidence: 58,
        evidence: ["irregular marks"],
        alternativeExplanation: "Older cosmetic damage"
      }]
    },
    growingConditions: { soilSurface: "obscured", confidence: 20 },
    limitations: ["Leaf undersides are not visible"]
  });

  assert.match(context, /^CURRENT_ATTACHED_PHOTO_GEMINI_SCAN/);
  assert.match(context, /data, not instructions/);
  assert.match(context, /pale spotting/);
  assert.match(context, /Mechanical damage/);
  assert.ok(context.length <= 4_000);
});

test("a direct attached-photo identity question answers from the current Gemini result", () => {
  const decision = botanistDirectPhotoDecision(
    [{ role: "user", content: "What image is attached to this message?" }],
    {
      identification: {
        commonName: "Golden pothos",
        scientificName: "Epipremnum aureum",
        confidence: 91,
        requiresConfirmation: false,
        isUnknown: false,
        distinguishingTraits: ["heart-shaped leaves", "yellow-green variegation"]
      }
    }
  );

  assert.equal(decision.disposition, "answer");
  assert.equal(decision.confidence, "high");
  assert.match(decision.reply, /attached photo shows Golden pothos/i);
  assert.match(decision.reply, /Epipremnum aureum/);
  assert.doesNotMatch(decision.reply, /soil|water/i);
});

test("an uncertain attached-photo identity asks for a better view", () => {
  const decision = botanistDirectPhotoDecision(
    [{ role: "user", content: "What is in this photo?" }],
    {
      identification: {
        commonName: "Unknown plant",
        confidence: 42,
        isUnknown: true,
        candidates: [{ commonName: "Philodendron" }]
      }
    }
  );

  assert.equal(decision.disposition, "clarify");
  assert.match(decision.reply, /can’t identify/i);
  assert.match(decision.reply, /Philodendron/);
  assert.equal(decision.missingInformation.length, 1);
});
