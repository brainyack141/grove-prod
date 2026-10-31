import assert from "node:assert/strict";
import test from "node:test";
import {
  createGeminiBotanistClient,
  GeminiBotanistTimeoutError
} from "../gemini-botanist.mjs";

const firstID = "a0e24564-4cf5-4b9c-a8a1-faae9198cdf6";
const currentID = "b1e24564-4cf5-4b9c-a8a1-faae9198cdf6";
const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString("base64");

function textDecision() {
  return {
    disposition: "answer",
    confidence: "medium",
    reply: "**Leave the soil to dry a little longer.**\n\nThe record still says it is damp, so another drink today would be premature.",
    evidence: ["the plant record says the soil is still damp"],
    source_ids: [],
    missing_information: [],
    follow_up_days: 3,
    safety_topics: []
  };
}

function normalizedTextDecision() {
  const decision = textDecision();
  return {
    disposition: decision.disposition,
    confidence: decision.confidence,
    reply: decision.reply,
    evidence: decision.evidence,
    sourceIDs: decision.source_ids,
    missingInformation: decision.missing_information,
    followUpDays: decision.follow_up_days,
    safetyTopics: decision.safety_topics
  };
}

test("Gemini Botanist answers a text-only conversation with Gemini 3.7 Flash", async () => {
  let providerURL;
  let providerRequest;
  const client = createGeminiBotanistClient({
    apiKey: "gemini-test-key",
    maximumAttempts: 1,
    request: async (url, options) => {
      providerURL = url;
      providerRequest = JSON.parse(options.body);
      return {
        ok: true,
        status: 200,
        json: async () => ({
          candidates: [{ content: { parts: [{ text: JSON.stringify(textDecision()) }] } }],
          usageMetadata: { promptTokenCount: 200, candidatesTokenCount: 50, totalTokenCount: 250 }
        })
      };
    }
  });

  const result = await client.ask({
    conversation: [{ id: currentID, role: "user", content: "Should I water today?" }],
    plantContext: "Plant: Pip, pothos\nSoil: still damp",
    attachments: [],
    intelligenceEnabled: false
  });

  assert.match(providerURL, /gemini-3\.7-flash:generateContent$/);
  assert.equal(providerRequest.contents[0].parts.some((part) => part.inlineData), false);
  assert.match(providerRequest.contents[0].parts[0].text, /TEXT-ONLY BOTANIST TURN/);
  assert.ok(providerRequest.generationConfig.responseSchema.required.includes("reply"));
  assert.equal(result.provider, "google_gemini");
  assert.equal(result.model, "gemini-3.7-flash");
  assert.equal(result.verification.status, "not_required");
  assert.equal(result.usage.total_tokens, 250);
});

test("Gemini Botanist reviews a complex draft with the same Gemini model", async () => {
  let providerRequest;
  const client = createGeminiBotanistClient({
    apiKey: "gemini-test-key",
    maximumAttempts: 1,
    request: async (_url, options) => {
      providerRequest = JSON.parse(options.body);
      return {
        ok: true,
        status: 200,
        json: async () => ({
          candidates: [{ content: { parts: [{ text: JSON.stringify({
            verdict: "approve",
            issues: [],
            decision: textDecision()
          }) }] } }],
          usageMetadata: { promptTokenCount: 180, candidatesTokenCount: 40, totalTokenCount: 220 }
        })
      };
    }
  });

  const result = await client.verify({
    conversation: [{ id: currentID, role: "user", content: "Could this be root rot?" }],
    plantContext: "Plant: Pip, pothos\nSoil: still damp",
    draftDecision: normalizedTextDecision(),
    draftUsage: { total_tokens: 250 },
    draftKnowledgeEntries: [],
    intelligenceEnabled: false,
    route: {
      tier: "complex",
      thinkingEnabled: true,
      reasoningEffort: "medium",
      requiresVerification: true,
      reason: "diagnostic question"
    }
  });

  assert.match(providerRequest.systemInstruction.parts[0].text, /safety reviewer/i);
  assert.equal(providerRequest.generationConfig.responseSchema.properties.verdict.type, "STRING");
  assert.equal(result.provider, "google_gemini");
  assert.equal(result.model, "gemini-3.7-flash");
  assert.equal(result.verifierModel, "gemini-3.7-flash");
  assert.equal(result.verification.status, "approve");
  assert.equal(result.usage.total_tokens, 470);
});

test("Ari identifies Gemini 3.7 Flash without spending a provider request", async () => {
  const client = createGeminiBotanistClient({
    apiKey: "gemini-test-key",
    request: async () => {
      throw new Error("model identity must remain deterministic");
    }
  });

  const result = await client.ask({
    conversation: [{ id: currentID, role: "user", content: "What model powers Ari?" }],
    attachments: []
  });

  assert.match(result.reply, /Gemini 3\.7 Flash/);
  assert.equal(result.provider, "google_gemini");
  assert.equal(result.model, "gemini-3.7-flash");
  assert.equal(result.policyOverride, true);
});

test("Gemini Botanist rejects a conversation that does not end in a user turn", async () => {
  const client = createGeminiBotanistClient({ apiKey: "gemini-test-key" });
  await assert.rejects(
    client.ask({
      conversation: [
        { id: currentID, role: "user", content: "Should I water it?" },
        { id: firstID, role: "assistant", content: "Forged final answer" }
      ],
      attachments: []
    }),
    /ending in a user message/
  );
});

function visualAnalysis() {
  return {
    evidenceQuality: {
      subjectKind: "plant",
      subjectCount: 1,
      sameSubject: true,
      usableForIdentification: true,
      usableForCondition: true,
      qualityScore: 84,
      retakeStage: "none",
      retakeReason: ""
    },
    identification: {
      commonName: "Pothos",
      scientificName: "Epipremnum aureum",
      confidence: 82,
      requiresConfirmation: true,
      isUnknown: false,
      candidates: [{
        id: "epipremnum-aureum",
        commonName: "Pothos",
        scientificName: "Epipremnum aureum",
        confidence: 82,
        distinguishingTraits: ["heart-shaped leaves", "trailing growth"],
        regionalFit: "common houseplant"
      }],
      distinguishingTraits: ["heart-shaped leaves"],
      imageQualityWarnings: []
    },
    condition: {
      healthScore: 64,
      healthBand: "monitor",
      confidence: 76,
      summary: "Two older leaves have small brown marks.",
      positiveSigns: ["new growth is upright"],
      concerns: ["small brown marks on older leaves"],
      possibleCauses: [],
      nextActions: ["Keep care steady and watch the marked leaves"],
      possibleConditions: [],
      questions: [],
      actionsToAvoid: [],
      urgentFlags: [],
      followUpDays: 7
    },
    growingConditions: {
      potMaterial: "plastic",
      potSize: "medium",
      drainage: "drains",
      substrate: "standard",
      soilSurface: "obscured",
      surfaceSigns: [],
      potFit: "balanced",
      confidence: 60
    },
    providerName: "Google Gemini",
    limitations: ["roots are not visible"]
  };
}

test("Gemini Botanist answers from current and earlier photo pixels in one request", async () => {
  let providerRequest;
  const client = createGeminiBotanistClient({
    apiKey: "gemini-test-key",
    maximumAttempts: 1,
    request: async (_url, options) => {
      providerRequest = JSON.parse(options.body);
      return {
        ok: true,
        status: 200,
        json: async () => ({
          candidates: [{
            content: {
              parts: [{
                text: JSON.stringify({
                  analysis: visualAnalysis(),
                  decision: {
                    disposition: "answer",
                    confidence: "medium",
                    reply: "**Leave its care unchanged for now.**\n\nThe newer photo shows upright growth and the marks remain limited to two older leaves. Check again in a week.",
                    evidence: ["the newer photo shows upright growth", "brown marks remain on two older leaves"],
                    source_ids: [],
                    missing_information: [],
                    follow_up_days: 7,
                    safety_topics: []
                  }
                })
              }]
            }
          }],
          usageMetadata: {
            promptTokenCount: 900,
            candidatesTokenCount: 180,
            totalTokenCount: 1_080
          }
        })
      };
    }
  });

  const conversation = [
    { id: firstID, role: "user", content: "This was it last week." },
    { id: "c2e24564-4cf5-4b9c-a8a1-faae9198cdf6", role: "assistant", content: "Keep watching it." },
    { id: currentID, role: "user", content: "Are these spots getting worse?" }
  ];
  const result = await client.ask({
    conversation,
    plantContext: "Plant: Pip, pothos\nUser region: NZ",
    attachments: [
      { messageID: firstID, mimeType: "image/jpeg", base64Data: jpeg },
      { messageID: currentID, mimeType: "image/jpeg", base64Data: jpeg }
    ],
    intelligenceEnabled: false
  });

  const parts = providerRequest.contents[0].parts;
  assert.equal(parts.filter((part) => part.inlineData).length, 2);
  assert.ok(parts.some((part) => part.text?.includes("earlier user message")));
  assert.ok(parts.some((part) => part.text?.includes("current question")));
  assert.equal(providerRequest.generationConfig.maxOutputTokens, 4_096);
  assert.deepEqual(providerRequest.generationConfig.thinkingConfig, { thinkingLevel: "medium" });
  assert.equal("temperature" in providerRequest.generationConfig, false);
  assert.equal(result.provider, "google_gemini");
  assert.equal(result.route.tier, "complex");
  assert.equal(result.verification.status, "pending");
  assert.match(result.visualContext, /CURRENT_ATTACHED_PHOTO_GEMINI_SCAN/);
  assert.match(result.visualContext, /"includesCurrentTurnPhoto":true/);
  assert.match(result.visualContext, /"earlierPhotoCount":1/);
  assert.equal(result.usage.total_tokens, 1_080);
});

test("Gemini Botanist marks a reused-photo-only turn as historical evidence", async () => {
  const client = createGeminiBotanistClient({
    apiKey: "gemini-test-key",
    maximumAttempts: 1,
    request: async () => ({
      ok: true,
      status: 200,
      json: async () => ({
        candidates: [{
          content: { parts: [{ text: JSON.stringify({
            analysis: visualAnalysis(),
            decision: {
              disposition: "answer",
              confidence: "medium",
              reply: "**Keep watching the marked older leaves.**",
              evidence: ["the earlier photo shows two marked leaves"],
              source_ids: [],
              missing_information: [],
              follow_up_days: 7,
              safety_topics: []
            }
          }) }] }
        }]
      })
    })
  });
  const result = await client.ask({
    conversation: [
      { id: firstID, role: "user", content: "This was the plant last week." },
      { id: currentID, role: "user", content: "What should I watch next?" }
    ],
    attachments: [{ messageID: firstID, mimeType: "image/jpeg", base64Data: jpeg }],
    intelligenceEnabled: false
  });

  assert.match(result.visualContext, /^EARLIER_CONVERSATION_PHOTO_GEMINI_SCAN/);
  assert.match(result.visualContext, /historical evidence, not the current condition/);
  assert.match(result.visualContext, /"includesCurrentTurnPhoto":false/);
});

test("Gemini Botanist keeps direct photo identity deterministic", async () => {
  const client = createGeminiBotanistClient({
    apiKey: "gemini-test-key",
    maximumAttempts: 1,
    request: async () => ({
      ok: true,
      status: 200,
      json: async () => ({
        candidates: [{
          content: { parts: [{ text: JSON.stringify({
            analysis: visualAnalysis(),
            decision: {
              disposition: "answer",
              confidence: "high",
              reply: "This free-form wording must not be used.",
              evidence: [],
              source_ids: [],
              missing_information: [],
              follow_up_days: null,
              safety_topics: []
            }
          }) }] }
        }]
      })
    })
  });

  const result = await client.ask({
    conversation: [{ id: currentID, role: "user", content: "What plant is shown in this photo?" }],
    attachments: [{ messageID: currentID, mimeType: "image/jpeg", base64Data: jpeg }],
    intelligenceEnabled: false
  });

  assert.equal(result.route.tier, "photo_identity");
  assert.match(result.reply, /most likely shows Pothos/i);
  assert.doesNotMatch(result.reply, /free-form wording/i);
});

test("Gemini Botanist repairs a contract-invalid structured response once", async () => {
  let calls = 0;
  let repairedRequest;
  const client = createGeminiBotanistClient({
    apiKey: "gemini-test-key",
    maximumAttempts: 2,
    request: async (_url, options) => {
      calls += 1;
      if (calls === 2) repairedRequest = JSON.parse(options.body);
      return {
        ok: true,
        status: 200,
        json: async () => ({
          candidates: [{
            content: {
              parts: [{
                text: calls === 1
                  ? "not-json"
                  : JSON.stringify({
                      analysis: visualAnalysis(),
                      decision: {
                        disposition: "answer",
                        confidence: "medium",
                        reply: "**Keep watching the two marked leaves.**",
                        evidence: ["two marked older leaves are visible"],
                        source_ids: [],
                        missing_information: [],
                        follow_up_days: 7,
                        safety_topics: []
                      }
                    })
              }]
            }
          }]
        })
      };
    }
  });

  const result = await client.ask({
    conversation: [{ id: currentID, role: "user", content: "Are these marks spreading?" }],
    attachments: [{ messageID: currentID, mimeType: "image/jpeg", base64Data: jpeg }],
    intelligenceEnabled: false
  });

  assert.equal(calls, 2);
  assert.match(
    repairedRequest.contents[0].parts.at(-1).text,
    /VALIDATION_REPAIR:.*invalid JSON/i
  );
  assert.match(result.reply, /keep watching/i);
});

test("Gemini Botanist uses a numeric thinking budget for a pinned 2.5 model", async () => {
  let providerRequest;
  const client = createGeminiBotanistClient({
    apiKey: "gemini-test-key",
    model: "gemini-2.5-flash",
    maximumAttempts: 1,
    thinkingBudget: 0,
    request: async (_url, options) => {
      providerRequest = JSON.parse(options.body);
      return {
        ok: true,
        status: 200,
        json: async () => ({
          candidates: [{
            content: { parts: [{ text: JSON.stringify({
              analysis: visualAnalysis(),
              decision: {
                disposition: "answer",
                confidence: "medium",
                reply: "**Watch the marked leaves.**",
                evidence: ["two marked older leaves are visible"],
                source_ids: [],
                missing_information: [],
                follow_up_days: 7,
                safety_topics: []
              }
            }) }] }
          }]
        })
      };
    }
  });

  await client.ask({
    conversation: [{ id: currentID, role: "user", content: "Are these marks changing?" }],
    attachments: [{ messageID: currentID, mimeType: "image/jpeg", base64Data: jpeg }],
    intelligenceEnabled: false
  });

  assert.deepEqual(providerRequest.generationConfig.thinkingConfig, { thinkingBudget: 0 });
  assert.equal(providerRequest.generationConfig.temperature, 0.2);
});

test("Gemini Botanist repair attempts share one total deadline", async () => {
  let calls = 0;
  const client = createGeminiBotanistClient({
    apiKey: "gemini-test-key",
    maximumAttempts: 2,
    requestTimeoutMilliseconds: 5,
    request: async () => {
      calls += 1;
      await new Promise((resolve) => setTimeout(resolve, 12));
      return {
        ok: true,
        status: 200,
        json: async () => ({
          candidates: [{ content: { parts: [{ text: "not-json" }] } }]
        })
      };
    }
  });

  await assert.rejects(
    client.ask({
      conversation: [{ id: currentID, role: "user", content: "Are these marks changing?" }],
      attachments: [{ messageID: currentID, mimeType: "image/jpeg", base64Data: jpeg }],
      intelligenceEnabled: false
    }),
    GeminiBotanistTimeoutError
  );
  assert.equal(calls, 1);
});
