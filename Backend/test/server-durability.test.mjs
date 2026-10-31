// End-to-end HTTP tests for the durable sync path.
//
// The point of these is the restart: they start a server, write through the
// real API, stop it, start a *new* one, and assert the account is still there.
// The in-memory implementation these replace failed exactly here — and because
// the iOS client replaces local state with whatever `/v1/bootstrap` returns,
// that failure deleted the user's Grove rather than merely losing the server's.
//
// Requires GROVE_TEST_DATABASE_URL with `supabase/migrations/` applied; skips
// without it so the suite still passes on a machine with no database.

import assert from "node:assert/strict";
import test from "node:test";
import postgres from "postgres";
import { createGroveServer } from "../server.mjs";
import { createTestAccount, resetAccounts } from "./helpers/database.mjs";

const databaseURL = process.env.GROVE_TEST_DATABASE_URL;
const describe = databaseURL ? test.describe : test.describe.skip;

let ACCOUNT;
let OTHER;
const authFor = (id) => ({ Authorization: `Bearer dev:${id}`, "Content-Type": "application/json" });
let AUTH;

function connect() {
  return postgres(databaseURL, { ssl: false, prepare: false, max: 4, onnotice: () => {} });
}

async function reset(sql) {
  await resetAccounts(sql, [ACCOUNT, OTHER]);
  ACCOUNT = await createTestAccount(sql, { name: "Durable Gardener" });
  OTHER = await createTestAccount(sql, { name: "Someone Else" });
  AUTH = authFor(ACCOUNT);
}

/// Starts an API instance backed by its own connection, mirroring how a fresh
/// container comes up after a deploy.
async function startServer(sql) {
  const app = createGroveServer({ port: 0, host: "127.0.0.1", database: { sql } });
  const address = await app.listen();
  return { app, origin: `http://127.0.0.1:${address.port}` };
}

const PLANT_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

function plantBody() {
  return JSON.stringify({
    clientPlantID: PLANT_ID,
    nickname: "Pesto",
    location: "Kitchen",
    analysis: {
      identification: { commonName: "Basil", scientificName: "Ocimum basilicum", confidence: 91 },
      condition: { healthScore: 82, healthBand: "healthy", confidence: 86, summary: "Good.", followUpDays: 10 }
    }
  });
}

describe("durable sync API", () => {
  test("an account survives a full server restart", async () => {
    const sql = connect();
    try {
      await reset(sql);

      const first = await startServer(sql);
      try {
        const created = await fetch(`${first.origin}/v1/plants`, {
          method: "POST",
          headers: AUTH,
          body: plantBody()
        });
        assert.equal(created.status, 201);
      } finally {
        await first.app.close();
      }

      // A brand-new process, exactly as a redeploy produces.
      const second = await startServer(sql);
      try {
        const response = await fetch(`${second.origin}/v1/bootstrap`, { headers: AUTH });
        assert.equal(response.status, 200);
        const snapshot = await response.json();
        assert.equal(snapshot.plants.length, 1, "the Grove must survive a restart");
        assert.equal(snapshot.plants[0].nickname, "Pesto");
        assert.equal(snapshot.tasks.length, 1);
      } finally {
        await second.app.close();
      }
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("bootstrap never returns an empty Grove for an account that has plants", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const { app, origin } = await startServer(sql);
      try {
        await fetch(`${origin}/v1/plants`, { method: "POST", headers: AUTH, body: plantBody() });
        // Three separate bootstraps: the client applies each one wholesale, so
        // any of them coming back empty would wipe the device.
        for (let attempt = 0; attempt < 3; attempt++) {
          const snapshot = await (await fetch(`${origin}/v1/bootstrap`, { headers: AUTH })).json();
          assert.equal(snapshot.plants.length, 1);
        }
      } finally {
        await app.close();
      }
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("a retried mutation replays instead of applying twice across a restart", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const key = "idem-key-1";

      const first = await startServer(sql);
      try {
        const response = await fetch(`${first.origin}/v1/plants`, {
          method: "POST",
          headers: { ...AUTH, "Idempotency-Key": key },
          body: plantBody()
        });
        assert.equal(response.status, 201);
      } finally {
        await first.app.close();
      }

      const second = await startServer(sql);
      try {
        const replay = await fetch(`${second.origin}/v1/plants`, {
          method: "POST",
          headers: { ...AUTH, "Idempotency-Key": key },
          body: plantBody()
        });
        assert.equal(replay.status, 201, "the original response must replay, not re-run");

        const snapshot = await (await fetch(`${second.origin}/v1/bootstrap`, { headers: AUTH })).json();
        assert.equal(snapshot.plants.length, 1);
      } finally {
        await second.app.close();
      }
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("a check-in persists health, history and the next task", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const { app, origin } = await startServer(sql);
      try {
        await fetch(`${origin}/v1/plants`, { method: "POST", headers: AUTH, body: plantBody() });
        const checkIn = await fetch(`${origin}/v1/plants/${PLANT_ID}/check-ins`, {
          method: "POST",
          headers: AUTH,
          body: JSON.stringify({ score: 90, band: "thriving", note: "Thriving.", hasNewGrowth: true })
        });
        assert.equal(checkIn.status, 200);

        const snapshot = await (await fetch(`${origin}/v1/bootstrap`, { headers: AUTH })).json();
        assert.equal(snapshot.plants[0].healthScore, 90);
        assert.equal(snapshot.plants[0].trend, "improving");
        assert.equal(snapshot.observations.length, 1);
        assert.equal(snapshot.tasks.filter((task) => !task.isCompleted).length, 1);
      } finally {
        await app.close();
      }
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("one account's bootstrap never contains another account's plants", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const { app, origin } = await startServer(sql);
      try {
        await fetch(`${origin}/v1/plants`, { method: "POST", headers: AUTH, body: plantBody() });

        const otherAuth = authFor(OTHER);
        const snapshot = await (await fetch(`${origin}/v1/bootstrap`, { headers: otherAuth })).json();
        assert.equal(snapshot.plants.length, 0);

        const stolen = await fetch(`${origin}/v1/plants/${PLANT_ID}/check-ins`, {
          method: "POST",
          headers: otherAuth,
          body: JSON.stringify({ score: 5, band: "urgent", note: "Not yours." })
        });
        assert.equal(stolen.status, 404);
      } finally {
        await app.close();
      }
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("bootstrap tells the client whether the server can keep its data", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const { app, origin } = await startServer(sql);
      try {
        const snapshot = await (await fetch(`${origin}/v1/bootstrap`, { headers: AUTH })).json();
        assert.equal(snapshot.storage, "postgres");
      } finally {
        await app.close();
      }

      // Without a database the snapshot must declare itself non-durable, so the
      // client refuses to apply it over a real Grove.
      const memoryApp = createGroveServer({ port: 0, host: "127.0.0.1" });
      const address = await memoryApp.listen();
      try {
        const snapshot = await (
          await fetch(`http://127.0.0.1:${address.port}/v1/bootstrap`, { headers: AUTH })
        ).json();
        assert.equal(snapshot.storage, "memory");
      } finally {
        await memoryApp.close();
      }
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("health reports whether storage is durable", async () => {
    const sql = connect();
    try {
      const durable = await startServer(sql);
      try {
        const body = await (await fetch(`${durable.origin}/health`)).json();
        assert.equal(body.storage, "postgres");
      } finally {
        await durable.app.close();
      }

      // Without a database the service is explicitly non-durable, and says so.
      const app = createGroveServer({ port: 0, host: "127.0.0.1" });
      const address = await app.listen();
      try {
        const body = await (await fetch(`http://127.0.0.1:${address.port}/health`)).json();
        assert.equal(body.storage, "memory");
      } finally {
        await app.close();
      }
    } finally {
      await sql.end({ timeout: 5 });
    }
  });
});
