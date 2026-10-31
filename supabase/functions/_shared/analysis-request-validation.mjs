// node:buffer resolves in both Node and Deno, keeping this module runtime-neutral.
import { Buffer } from "node:buffer";

const allowedModes = new Set(["identify", "add", "diagnose"]);
const allowedStages = new Set(["wholePlant", "leaf", "stem", "symptom", "reference"]);
const allowedMimeTypes = new Set(["image/jpeg", "image/png"]);
const allowedQualityWarnings = new Set([
  "lowLight", "overexposed", "softFocus", "lowContrast", "possibleObstruction"
]);
// Every scan works from a single whole-plant photo; extra views stay optional.
const requiredStages = Object.freeze({
  identify: ["wholePlant"],
  add: ["wholePlant"],
  diagnose: ["wholePlant"]
});

export const analysisRequestLimits = Object.freeze({
  maximumImages: 4,
  maximumImageBytes: 2 * 1024 * 1024,
  maximumTotalImageBytes: 8 * 1024 * 1024,
  maximumAnswers: 3
});

export class AnalysisRequestValidationError extends Error {}

function invalid(message) {
  throw new AnalysisRequestValidationError(message);
}

function boundedText(value, name, maximumLength, { optional = false } = {}) {
  if (optional && (value === undefined || value === null || value === "")) return undefined;
  if (typeof value !== "string") invalid(`${name} must be text.`);
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > maximumLength) {
    invalid(`${name} must contain 1–${maximumLength} characters.`);
  }
  return trimmed;
}

function decodedImage(image, index) {
  if (!image || typeof image !== "object" || Array.isArray(image)) {
    invalid(`Image ${index + 1} is invalid.`);
  }
  if (!allowedStages.has(image.stage)) invalid(`Image ${index + 1} has an unsupported capture stage.`);
  if (!allowedMimeTypes.has(image.mimeType)) invalid(`Image ${index + 1} must be JPEG or PNG.`);
  if (typeof image.base64Data !== "string" || image.base64Data.length === 0) {
    invalid(`Image ${index + 1} has no image data.`);
  }
  if (image.base64Data.length > Math.ceil(analysisRequestLimits.maximumImageBytes / 3) * 4 + 4) {
    invalid(`Image ${index + 1} exceeds the 2 MB analysis limit.`);
  }
  if (image.base64Data.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(image.base64Data)) {
    invalid(`Image ${index + 1} is not valid base64 data.`);
  }

  const bytes = Buffer.from(image.base64Data, "base64");
  if (!bytes.length || bytes.length > analysisRequestLimits.maximumImageBytes) {
    invalid(`Image ${index + 1} exceeds the 2 MB analysis limit.`);
  }
  const isJPEG = bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const isPNG = bytes.length >= 8
    && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47
    && bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a;
  if ((image.mimeType === "image/jpeg" && !isJPEG) || (image.mimeType === "image/png" && !isPNG)) {
    invalid(`Image ${index + 1} data does not match its MIME type.`);
  }
  return bytes;
}

function validatedQualityWarnings(values, index) {
  if (values === undefined || values === null) return [];
  if (!Array.isArray(values) || values.length > allowedQualityWarnings.size) {
    invalid(`Image ${index + 1} quality warnings are invalid.`);
  }
  const warnings = [...new Set(values)];
  if (warnings.some((warning) => typeof warning !== "string" || !allowedQualityWarnings.has(warning))) {
    invalid(`Image ${index + 1} quality warnings are invalid.`);
  }
  return warnings;
}

function validatedAnswers(answers) {
  if (answers === undefined || answers === null) return {};
  if (typeof answers !== "object" || Array.isArray(answers)) invalid("Analysis answers must be an object.");
  const entries = Object.entries(answers);
  if (entries.length > analysisRequestLimits.maximumAnswers) invalid("At most three analysis answers are allowed.");
  const normalized = entries.map(([key, value]) => [
    boundedText(key, "Answer id", 64),
    boundedText(value, "Answer value", 120)
  ]);
  if (new Set(normalized.map(([key]) => key)).size !== normalized.length) {
    invalid("Analysis answer ids must be unique after trimming.");
  }
  // The stable request fingerprint hashes this validated object. Canonical key
  // order makes a dictionary replay the same scan regardless of JSON insertion
  // order, so retries cannot become extra jobs or quota reservations.
  normalized.sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0);
  return Object.fromEntries(normalized);
}

function validatedExistingPlant(existingPlant) {
  if (existingPlant === undefined || existingPlant === null) return undefined;
  if (typeof existingPlant !== "object" || Array.isArray(existingPlant)) invalid("Existing plant context is invalid.");
  return {
    id: boundedText(existingPlant.id, "Existing plant id", 64),
    commonName: boundedText(existingPlant.commonName, "Existing plant common name", 120),
    scientificName: boundedText(existingPlant.scientificName, "Existing plant scientific name", 160),
    location: boundedText(existingPlant.location, "Existing plant location", 120),
    recentSummary: boundedText(existingPlant.recentSummary, "Existing plant summary", 600)
  };
}

function validatedClientRequestID(value) {
  if (value === undefined || value === null) return undefined;
  const id = boundedText(value, "Client request id", 36);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) {
    invalid("Client request id must be a UUID.");
  }
  return id.toLowerCase();
}

export function validatePlantAnalysisRequest(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) invalid("Plant analysis request is invalid.");
  if (!allowedModes.has(input.mode)) invalid("Plant analysis mode is invalid.");
  if (!Array.isArray(input.images) || input.images.length === 0 || input.images.length > analysisRequestLimits.maximumImages) {
    invalid("Plant analysis requires between one and four images.");
  }

  let totalImageBytes = 0;
  const seenStages = new Set();
  const images = input.images.map((image, index) => {
    const bytes = decodedImage(image, index);
    totalImageBytes += bytes.length;
    if (seenStages.has(image.stage)) invalid(`Capture stage ${image.stage} was supplied more than once.`);
    seenStages.add(image.stage);
    return {
      stage: image.stage,
      mimeType: image.mimeType,
      base64Data: image.base64Data,
      qualityWarnings: validatedQualityWarnings(image.qualityWarnings, index)
    };
  });
  if (totalImageBytes > analysisRequestLimits.maximumTotalImageBytes) {
    invalid("Combined analysis images exceed the 8 MB limit.");
  }
  for (const requiredStage of requiredStages[input.mode]) {
    if (!seenStages.has(requiredStage)) invalid(`${input.mode} analysis requires a ${requiredStage} image.`);
  }

  const regionCode = boundedText(input.regionCode, "Region code", 8, { optional: true });
  return {
    clientRequestID: validatedClientRequestID(input.clientRequestID),
    mode: input.mode,
    images,
    regionCode,
    existingPlant: validatedExistingPlant(input.existingPlant),
    answers: validatedAnswers(input.answers)
  };
}
