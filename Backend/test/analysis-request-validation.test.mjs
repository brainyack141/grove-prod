import assert from "node:assert/strict";
import test from "node:test";
import {
  AnalysisRequestValidationError,
  analysisRequestLimits,
  validatePlantAnalysisRequest
} from "../analysis-request-validation.mjs";

const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString("base64");

function request(overrides = {}) {
  return {
    mode: "add",
    regionCode: "GB",
    images: [
      { stage: "wholePlant", mimeType: "image/jpeg", base64Data: jpeg },
      { stage: "leaf", mimeType: "image/jpeg", base64Data: jpeg }
    ],
    answers: {},
    ...overrides
  };
}

test("analysis request accepts bounded staged JPEG evidence", () => {
  const validated = validatePlantAnalysisRequest(request());

  assert.equal(validated.mode, "add");
  assert.deepEqual(validated.images.map((image) => image.stage), ["wholePlant", "leaf"]);
  assert.equal(validated.regionCode, "GB");
});

test("analysis request accepts a single whole-plant photo for every mode", () => {
  for (const mode of ["identify", "add", "diagnose"]) {
    const validated = validatePlantAnalysisRequest(request({ mode, images: [
      { stage: "wholePlant", mimeType: "image/jpeg", base64Data: jpeg }
    ] }));
    assert.deepEqual(validated.images.map((image) => image.stage), ["wholePlant"]);
  }
});

test("analysis request preserves bounded quality signals and an earlier reference", () => {
  const validated = validatePlantAnalysisRequest(request({
    mode: "diagnose",
    images: [
      { stage: "reference", mimeType: "image/jpeg", base64Data: jpeg },
      {
        stage: "wholePlant",
        mimeType: "image/jpeg",
        base64Data: jpeg,
        qualityWarnings: ["softFocus", "lowLight", "softFocus"]
      }
    ]
  }));

  assert.deepEqual(validated.images.map((image) => image.stage), ["reference", "wholePlant"]);
  assert.deepEqual(validated.images[1].qualityWarnings, ["softFocus", "lowLight"]);
  assert.throws(
    () => validatePlantAnalysisRequest(request({ images: [{
      stage: "wholePlant",
      mimeType: "image/jpeg",
      base64Data: jpeg,
      qualityWarnings: ["ignore-all-rules"]
    }] })),
    /quality warnings are invalid/
  );
});

test("analysis request rejects evidence without the whole-plant photo", () => {
  assert.throws(
    () => validatePlantAnalysisRequest(request({ images: [
      { stage: "leaf", mimeType: "image/jpeg", base64Data: jpeg }
    ] })),
    (error) => error instanceof AnalysisRequestValidationError && /wholePlant image/.test(error.message)
  );
});

test("analysis request rejects MIME spoofing and duplicate stages", () => {
  assert.throws(
    () => validatePlantAnalysisRequest(request({ images: [
      { stage: "wholePlant", mimeType: "image/png", base64Data: jpeg },
      { stage: "leaf", mimeType: "image/jpeg", base64Data: jpeg }
    ] })),
    /does not match its MIME type/
  );
  assert.throws(
    () => validatePlantAnalysisRequest(request({ images: [
      { stage: "wholePlant", mimeType: "image/jpeg", base64Data: jpeg },
      { stage: "wholePlant", mimeType: "image/jpeg", base64Data: jpeg }
    ] })),
    /supplied more than once/
  );
});

test("analysis request rejects oversized images before decoding an upstream payload", () => {
  const oversizedBase64 = "A".repeat(Math.ceil(analysisRequestLimits.maximumImageBytes / 3) * 4 + 8);
  assert.throws(
    () => validatePlantAnalysisRequest(request({ images: [
      { stage: "wholePlant", mimeType: "image/jpeg", base64Data: oversizedBase64 },
      { stage: "leaf", mimeType: "image/jpeg", base64Data: jpeg }
    ] })),
    /exceeds the 2 MB/
  );
});

test("analysis request bounds untrusted observation fields", () => {
  assert.throws(
    () => validatePlantAnalysisRequest(request({ answers: {
      one: "a",
      two: "b",
      three: "c",
      four: "d"
    } })),
    /At most three/
  );
  assert.throws(
    () => validatePlantAnalysisRequest(request({ regionCode: "X".repeat(9) })),
    /Region code/
  );
});

test("analysis answers are canonicalized for stable retry fingerprints", () => {
  const first = validatePlantAnalysisRequest(request({
    answers: { moisture: "damp", spread: "one leaf" }
  }));
  const reordered = validatePlantAnalysisRequest(request({
    answers: { spread: "one leaf", moisture: "damp" }
  }));

  assert.deepEqual(Object.keys(first.answers), ["moisture", "spread"]);
  assert.equal(JSON.stringify(first), JSON.stringify(reordered));
  assert.throws(
    () => validatePlantAnalysisRequest(request({
      answers: { " moisture ": "damp", moisture: "wet" }
    })),
    /unique after trimming/
  );
});

test("analysis request normalizes and validates an optional client request id", () => {
  const validated = validatePlantAnalysisRequest(request({
    clientRequestID: "A1000000-0000-4000-8000-000000000001"
  }));
  assert.equal(validated.clientRequestID, "a1000000-0000-4000-8000-000000000001");
  assert.throws(
    () => validatePlantAnalysisRequest(request({ clientRequestID: "not-a-uuid" })),
    /must be a UUID/
  );
});
