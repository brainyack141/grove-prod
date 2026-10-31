import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createGBIFSpeciesSearchClient } from "../gbif-species-search.mjs";

test("species search maps common and scientific names and removes duplicates", async () => {
  const client = createGBIFSpeciesSearchClient({
    request: async () => new Response(JSON.stringify({
      results: [
        { key: 1, canonicalName: "Dracaena trifasciata", kingdom: "Plantae", vernacularNames: [{ vernacularName: "Snake plant", language: "eng" }] },
        { key: 2, acceptedKey: 1, canonicalName: "Sansevieria trifasciata", kingdom: "Plantae", vernacularNames: [] },
        { key: 3, canonicalName: "Panthera leo", kingdom: "Animalia", vernacularNames: [{ vernacularName: "Lion", language: "eng" }] }
      ]
    }), { status: 200, headers: { "content-type": "application/json" } })
  });

  const results = await client.search("snake plant");
  assert.deepEqual(results.map((result) => result.scientificName), ["Dracaena trifasciata"]);
  assert.equal(results[0].commonName, "Snake plant");
  assert.equal(results[0].id, "gbif:1");
  assert.equal(results[0].canonicalTaxonID, "gbif:1");
});

test("the public species edge verifies identity and bounds proxy input", async () => {
  const source = await readFile(
    new URL("../../supabase/functions/species/index.ts", import.meta.url),
    "utf8"
  );

  assert.match(source, /database\.auth\.getUser\(token\)/);
  assert.match(source, /tokenParts\.length !== 3/);
  assert.doesNotMatch(source, /if \(!\(request\.headers\.get\("authorization"\)[\s\S]{0,120}startsWith\("Bearer "\)\)/);
  assert.match(source, /query\.length > 160/);
});
