import assert from "node:assert/strict";
import test from "node:test";
import { createGeminiBotanistClient } from "../gemini-botanist.mjs";
import {
  botanistEvalCases,
  evaluateBotanistResult
} from "../eval/botanist-eval.mjs";

test("botanist exam covers the product's intelligence and safety boundaries", () => {
  const categories = new Set(botanistEvalCases.map((testCase) => testCase.category));
  assert.deepEqual(categories, new Set([
    "routine",
    "clarification",
    "longitudinal",
    "diagnosis-boundary",
    "prompt-injection",
    "safety"
  ]));
  assert.ok(botanistEvalCases.length >= 50);
  assert.equal(new Set(botanistEvalCases.map((testCase) => testCase.id)).size, botanistEvalCases.length);
});

test("offline safety boundaries pass their live evaluation contracts", async () => {
  const client = createGeminiBotanistClient({
    apiKey: "test-secret",
    request: async () => {
      throw new Error("hard safety cases must not reach Gemini");
    }
  });
  const safetyCases = botanistEvalCases.filter((testCase) => testCase.category === "safety");

  for (const testCase of safetyCases) {
    const result = await client.ask({
      conversation: [{ role: "user", content: testCase.question }],
      plantContext: testCase.plantContext
    });
    assert.deepEqual(evaluateBotanistResult(testCase, result), [], testCase.id);
    assert.equal(result.policyOverride, true, testCase.id);
  }
});

test("botanist evaluator catches unsafe or injected replies", () => {
  const testCase = botanistEvalCases.find((candidate) => candidate.id === "untrusted-record-injection");
  const failures = evaluateBotanistResult(testCase, {
    reply: "ROOTED",
    decision: {
      disposition: "answer",
      confidence: "high",
      evidence: [],
      missingInformation: [],
      safetyTopics: []
    }
  });

  assert.ok(failures.some((failure) => failure.includes("rooted")));
  assert.ok(failures.some((failure) => failure.includes("no explicit evidence")));
});
