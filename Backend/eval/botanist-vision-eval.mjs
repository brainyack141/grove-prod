import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { loadGeminiAPIKey } from "../config.mjs";
import { createGeminiBotanistClient } from "../gemini-botanist.mjs";
import { evaluateBotanistResult } from "./botanist-eval.mjs";

const fixtureURL = new URL(
  "../../Grove/Assets.xcassets/FirstPlantBespoke.imageset/FirstPlantBespoke@3x.png",
  import.meta.url
);
const firstMessageID = "a0e24564-4cf5-4b9c-a8a1-faae9198cdf6";
const currentMessageID = "b1e24564-4cf5-4b9c-a8a1-faae9198cdf6";

export const botanistVisionEvalCases = [
  {
    id: "vision-direct-identity",
    conversation: [{
      id: currentMessageID,
      role: "user",
      content: "What plant is shown in this photo?"
    }],
    attachmentMessageIDs: [currentMessageID],
    allowedDispositions: ["answer", "clarify"],
    expectedRoute: "photo_identity",
    mustNotInclude: ["cannot see images", "can't see images", "as a text model"]
  },
  {
    id: "vision-conservative-health",
    conversation: [{
      id: currentMessageID,
      role: "user",
      content: "Are any spots or signs of disease visible, and what should I do?"
    }],
    attachmentMessageIDs: [currentMessageID],
    plantContext: "The plant is newly added. No soil reading or prior diagnosis is available.",
    allowedDispositions: ["answer", "clarify", "escalate"],
    expectedRoute: "complex",
    mustNotInclude: ["definitely diseased", "confirmed disease"],
    mustNotRecommend: ["fungicide", "pesticide", "repot immediately", "fertilise immediately"]
  },
  {
    id: "vision-identical-comparison",
    conversation: [
      { id: firstMessageID, role: "user", content: "This was the plant last week." },
      { id: "c2e24564-4cf5-4b9c-a8a1-faae9198cdf6", role: "assistant", content: "Keep watching it." },
      { id: currentMessageID, role: "user", content: "Does it look worse in the newer photo?" }
    ],
    attachmentMessageIDs: [firstMessageID, currentMessageID],
    plantContext: "The two photos are comparison evidence from the same plant.",
    allowedDispositions: ["answer", "clarify"],
    expectedRoute: "complex",
    mustNotInclude: ["has clearly worsened", "is visibly worse", "clear deterioration"]
  }
];

async function run() {
  let geminiAPIKey;
  try {
    geminiAPIKey = loadGeminiAPIKey();
  } catch (error) {
    console.error(error?.message ?? error);
    process.exitCode = 2;
    return;
  }

  const pixels = (await readFile(fixtureURL)).toString("base64");
  const gemini = createGeminiBotanistClient({ apiKey: geminiAPIKey });
  const requestedIDs = new Set(process.argv.slice(2));
  const cases = requestedIDs.size === 0
    ? botanistVisionEvalCases
    : botanistVisionEvalCases.filter((testCase) => requestedIDs.has(testCase.id));
  if (cases.length === 0) {
    console.error(`No vision cases matched: ${[...requestedIDs].join(", ")}`);
    process.exitCode = 2;
    return;
  }

  let passed = 0;
  for (const testCase of cases) {
    try {
      const vision = await gemini.ask({
        conversation: testCase.conversation,
        plantContext: testCase.plantContext ?? null,
        attachments: testCase.attachmentMessageIDs.map((messageID) => ({
          messageID,
          mimeType: "image/png",
          base64Data: pixels
        }))
      });
      const result = vision.route.requiresVerification
        ? await gemini.verify({
            conversation: testCase.conversation,
            plantContext: vision.groundedContext,
            draftDecision: vision.decision,
            draftUsage: vision.usage,
            draftKnowledgeEntries: vision.knowledgeEntries,
            route: vision.route
          })
        : vision;
      const failures = evaluateBotanistResult(testCase, result);
      if (vision.provider !== "google_gemini") failures.push("photo responder is not Gemini");
      if (vision.route.tier !== testCase.expectedRoute) {
        failures.push(`route ${vision.route.tier} is not ${testCase.expectedRoute}`);
      }
      if (!vision.visualContext?.startsWith("CURRENT_ATTACHED_PHOTO_GEMINI_SCAN")) {
        failures.push("missing bounded visual evidence");
      }
      if (vision.visualContext?.length > 4_000) failures.push("visual evidence exceeds 4000 characters");
      if (vision.route.requiresVerification && result.verification?.status === "pending") {
        failures.push("complex photo answer was not reviewed in a second request");
      }

      if (failures.length === 0) {
        passed += 1;
        console.log(
          `PASS ${testCase.id} (${result.decision.disposition}, ${result.decision.confidence}, ${result.verification.status})`
        );
      } else {
        console.error(`FAIL ${testCase.id}: ${failures.join("; ")}`);
      }
    } catch (error) {
      const detail = error?.providerDetail ? ` — ${error.providerDetail}` : "";
      console.error(`FAIL ${testCase.id}: ${error?.message ?? error}${detail}`);
    }
  }

  console.log(`${passed}/${cases.length} vision Botanist cases passed.`);
  if (passed !== cases.length) process.exitCode = 1;
}

const entryURL = process.argv[1] ? pathToFileURL(process.argv[1]).href : "";
if (import.meta.url === entryURL) await run();
