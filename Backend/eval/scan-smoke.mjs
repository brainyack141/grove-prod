// Runs the production scan prompt against real photos and prints what the
// owner would see, plus the checks a prompt or schema change most often breaks:
// the provider accepting the schema at all, the order the model writes its
// fields in, em dashes in owner-facing text, and how long the scan took.
//
// This is a smoke test, not an accuracy eval: it tells you a change is safe to
// deploy, not that it is better. Run it before deploying any change to
// supabase/functions/_shared/gemini-plant-analysis.mjs or analysis-safety.mjs.
//
// Usage:
//   node eval/scan-smoke.mjs <photo> [more photos…] [--mode add|identify|diagnose] [--region NZ]
//
// The first photo is the whole-plant view; with --mode diagnose a second photo
// is the symptom close-up. GEMINI_API_KEY comes from the environment or
// Backend/.env.local. HEIC and oversized photos are converted with `sips`.

import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createGeminiPlantAnalysisClient } from "../gemini-plant-analysis.mjs";
import { sanitizePlantAnalysis } from "../analysis-safety.mjs";

const here = dirname(fileURLToPath(import.meta.url));

function apiKey() {
  if (process.env.GEMINI_API_KEY) return process.env.GEMINI_API_KEY;
  const envFile = join(here, "..", ".env.local");
  if (!existsSync(envFile)) return undefined;
  const line = readFileSync(envFile, "utf8").split("\n").find((entry) => entry.startsWith("GEMINI_API_KEY="));
  return line?.slice("GEMINI_API_KEY=".length).trim().replace(/^"|"$/g, "") || undefined;
}

function argument(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  return index === -1 ? fallback : process.argv[index + 1];
}

// The gateway accepts JPEG or PNG up to 2 MB; phone photos are often HEIC and
// larger, so convert the way the app's own capture pipeline would.
function preparedImage(path) {
  const isSmallJPEG = /\.jpe?g$/i.test(path) && statSync(path).size <= 1_900_000;
  let file = path;
  if (!isSmallJPEG) {
    const out = join(mkdtempSync(join(tmpdir(), "scan-smoke-")), `${basename(path)}.jpg`);
    execFileSync("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "80", "-Z", "2048", path, "--out", out], { stdio: "ignore" });
    file = out;
  }
  return { mimeType: "image/jpeg", base64Data: readFileSync(file).toString("base64") };
}

const optionValues = new Set([argument("mode"), argument("region")].filter(Boolean));
const photos = process.argv.slice(2).filter((value) => !value.startsWith("--") && !optionValues.has(value));
const mode = argument("mode", "add");
const regionCode = argument("region", "NZ");
const key = apiKey();

if (photos.length === 0 || !key) {
  console.error(photos.length === 0
    ? "Pass at least one photo: node eval/scan-smoke.mjs ~/Desktop/plant.jpg"
    : "Set GEMINI_API_KEY in the environment or Backend/.env.local.");
  process.exit(1);
}

const stages = mode === "diagnose" ? ["wholePlant", "symptom"] : ["wholePlant"];
const request = {
  mode,
  regionCode,
  images: photos.slice(0, stages.length).map((path, index) => ({ stage: stages[index], ...preparedImage(path) })),
  answers: {}
};

const client = createGeminiPlantAnalysisClient({ apiKey: key });
const started = Date.now();
const raw = await client.analyse(request);
const seconds = ((Date.now() - started) / 1_000).toFixed(1);
const result = sanitizePlantAnalysis(raw, request);

// JSON.parse keeps keys in the order they appear in the text, which is the
// order the model wrote them.
const firstCandidate = raw.identification?.candidates?.[0] ?? {};
const rawText = JSON.stringify(raw);
const owner = result.condition;
const id = result.identification;

console.log(`\n${mode} scan, region ${regionCode}, ${request.images.length} photo(s), ${seconds}s, model ${process.env.GEMINI_MODEL || "default"}`);
console.log(`\nWritten in order`);
console.log(`  top level:   ${Object.keys(raw).join(" → ")}`);
console.log(`  candidate:   ${Object.keys(firstCandidate).join(" → ")}`);
console.log(`  condition:   ${Object.keys(raw.condition ?? {}).join(" → ")}`);
console.log(`\nEm dashes in raw model output: ${(rawText.match(/—/g) ?? []).length} (owner sees ${(JSON.stringify(result).match(/—/g) ?? []).length})`);
console.log(`\nIdentity: ${id.commonName} (${id.scientificName}), ${id.confidence}%${id.requiresConfirmation ? ", asks to confirm" : ""}${id.isUnknown ? ", unknown" : ""}`);
for (const candidate of id.candidates.slice(1)) console.log(`  also: ${candidate.commonName} (${candidate.scientificName}) ${candidate.confidence}%`);
console.log(`  traits: ${id.distinguishingTraits.join("; ")}`);
console.log(`\nHealth: ${owner.healthScore} ${owner.healthBand}, ${owner.actionability}, condition confidence ${owner.confidence}`);
console.log(`  summary: ${owner.summary}`);
console.log(`  good: ${owner.positiveSigns.join("; ") || "none"}`);
console.log(`  concerns: ${owner.concerns.join("; ") || "none"}`);
console.log(`  next: ${owner.nextActions.join("; ")}`);
console.log(`  follow up in ${owner.followUpDays} days`);
for (const finding of owner.indicatorFindings) console.log(`  ${finding.kind}: ${finding.state} ${finding.evidence.join("; ")}`);
if (owner.questions.length) console.log(`  questions: ${owner.questions.map((question) => question.prompt).join(" | ")}`);
const pot = result.growingConditions;
console.log(`\nPot: ${pot.potMaterial}, ${pot.potSize}, ${pot.drainage}, ${pot.substrate}, surface ${pot.soilSurface}, fit ${pot.potFit}, signs [${pot.surfaceSigns.join(", ")}], confidence ${pot.confidence}`);
console.log(`Evidence: ${result.evidenceQuality.subjectKind} ×${result.evidenceQuality.subjectCount}, quality ${result.evidenceQuality.qualityScore}${result.evidenceQuality.retakeStage !== "none" ? `, retake ${result.evidenceQuality.retakeStage}: ${result.evidenceQuality.retakeReason}` : ""}`);
console.log(`Limitations: ${result.limitations.join("; ")}\n`);
