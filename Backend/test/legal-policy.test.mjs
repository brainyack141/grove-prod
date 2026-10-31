import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const legalURL = new URL("../../supabase/functions/legal/index.ts", import.meta.url);
const webURL = new URL("../../web/privacy.html", import.meta.url);
const builderURL = new URL("../../web/build-privacy.mjs", import.meta.url);
const appLegalURL = new URL("../../Grove/GroveLegal.swift", import.meta.url);

test("the app-linked privacy page matches the photo Botanist provider boundary", async () => {
  const [legal, web, builder, appLegal] = await Promise.all([
    readFile(legalURL, "utf8"),
    readFile(webURL, "utf8"),
    readFile(builderURL, "utf8"),
    readFile(appLegalURL, "utf8")
  ]);
  const effectiveDate = legal.match(/const effectiveDate = "([^"]+)"/)?.[1];
  assert.ok(effectiveDate);
  assert.match(web, new RegExp(`Effective ${effectiveDate}`));
  assert.match(appLegal, /https:\/\/www\.downloadgrove\.com\/privacy/);
  assert.ok(builder.includes('"supabase", "functions", "legal", "index.ts"'));

  for (const source of [legal, web]) {
    assert.match(source, /Sent for Scan and check-ins:[\s\S]*up to four plant photos/i);
    assert.match(source, /earlier photo[\s\S]*comparison/i);
    assert.match(source, /bounded observation[\s\S]*answers/i);
    assert.match(source, /up to two chosen plant photos/i);
    assert.match(source, /recent Ask messages/i);
    assert.match(source, /second bounded Gemini request[\s\S]*safety review/i);
    assert.doesNotMatch(source, /DeepSeek/i);
    assert.match(source, /bounded (?:text description of the )?visible evidence/i);
    assert.doesNotMatch(source, /under your account or local guest identifier/i);
    assert.match(source, /Apple Push Notification service \(APNs\)/i);
    assert.match(source, /device token Apple issued for Grove/i);
    assert.match(source, /display name[\s\S]*connection request/i);
    assert.match(source, /Connecting does not reveal either\s+grove/i);
    assert.match(source, /safety reports/i);
  }
});
