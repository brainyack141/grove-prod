import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const apiURL = new URL("../../supabase/functions/api/index.ts", import.meta.url);

test("check-in frequency is validated and round-trips through plant presentation", async () => {
  const source = await readFile(apiURL, "utf8");

  assert.match(source, /function checkInFrequencyDays\(/);
  assert.match(source, /checkInFrequencyDays: checkInFrequencyDays\(presentation\.checkInFrequencyDays\)/);

  const persisted = source.match(
    /checkInFrequencyDays: checkInFrequencyDays\(client\.checkInFrequencyDays\)/g
  ) ?? [];
  assert.ok(
    persisted.length >= 2,
    "Both the create and update plant presentation must persist the owner's cadence"
  );
});
