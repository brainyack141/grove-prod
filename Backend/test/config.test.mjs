import assert from "node:assert/strict";
import test from "node:test";
import { loadGeminiAPIKey } from "../config.mjs";

test("deployment secret takes precedence over the local keychain", () => {
  const value = loadGeminiAPIKey({
    environment: { GEMINI_API_KEY: "deployed-secret" },
    platform: "darwin",
    readLocalKeychain: () => "local-secret"
  });

  assert.equal(value, "deployed-secret");
});

test("local development can read the macOS Keychain", () => {
  const value = loadGeminiAPIKey({
    environment: { NODE_ENV: "development" },
    platform: "darwin",
    readLocalKeychain: () => "local-secret"
  });

  assert.equal(value, "local-secret");
});

test("production fails closed when the deployment secret is missing", () => {
  assert.throws(
    () => loadGeminiAPIKey({
      environment: { NODE_ENV: "production" },
      platform: "darwin",
      readLocalKeychain: () => "local-secret"
    }),
    /GEMINI_API_KEY is not configured/
  );
});
