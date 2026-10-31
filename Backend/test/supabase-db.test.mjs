import assert from "node:assert/strict";
import test from "node:test";
import { createGroveServer } from "../server.mjs";
import { DatabaseNotConfiguredError, createGroveDatabase, loadDatabaseURL } from "../supabase-db.mjs";

async function health(database) {
  const app = createGroveServer({ port: 0, database });
  const address = await app.listen();
  try {
    const response = await fetch(`http://127.0.0.1:${address.port}/health`);
    return { status: response.status, body: await response.json() };
  } finally {
    await app.close();
  }
}

test("SUPABASE_DB_URL is preferred over a generic DATABASE_URL", () => {
  assert.equal(
    loadDatabaseURL({ environment: { SUPABASE_DB_URL: "postgresql://supabase", DATABASE_URL: "postgresql://other" } }),
    "postgresql://supabase"
  );
  assert.equal(loadDatabaseURL({ environment: { DATABASE_URL: "postgresql://other" } }), "postgresql://other");
});

test("a blank connection string is treated as unconfigured rather than valid", () => {
  assert.equal(loadDatabaseURL({ environment: { SUPABASE_DB_URL: "   " } }), undefined);
  assert.throws(() => createGroveDatabase({ url: undefined }), DatabaseNotConfiguredError);
});

test("an account-scoped transaction requires a Supabase Auth user uuid", async () => {
  const database = createGroveDatabase({ url: "postgresql://grove:secret@127.0.0.1:6543/postgres" });
  try {
    for (const rejected of ["", "demo-local-account", "not-a-uuid", undefined]) {
      await assert.rejects(() => database.withAccount(rejected, async () => {}), TypeError);
    }
  } finally {
    await database.close({ timeout: 0 });
  }
});

test("health reports the relational layer as not configured when no database is wired", async () => {
  const { status, body } = await health(undefined);
  assert.equal(status, 200);
  assert.equal(body.status, "ok");
  assert.equal(body.database, "not_configured");
  assert.equal(body.signupCompletionReady, false);
});

test("health surfaces a connected database with its applied table count", async () => {
  const { status, body } = await health({
    check: async () => ({
      serverTime: "2026-07-23T22:00:00Z",
      appTableCount: 16,
      signupCompletionReady: true
    })
  });
  assert.equal(status, 200);
  assert.equal(body.database, "connected");
  assert.equal(body.appTableCount, 16);
  assert.equal(body.signupCompletionReady, true);
  assert.equal(body.databaseTime, "2026-07-23T22:00:00Z");
});

test("an unreachable database degrades health without failing the platform check", async () => {
  const { status, body } = await health({
    check: async () => {
      throw new Error("connection refused");
    }
  });
  assert.equal(status, 200);
  assert.equal(body.status, "ok");
  assert.equal(body.database, "unavailable");
  assert.equal(body.signupCompletionReady, false);
});
