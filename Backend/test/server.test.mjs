import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import test from "node:test";
import { createGroveServer } from "../server.mjs";
import { GeminiProviderError, GeminiRequestTimeoutError } from "../gemini-plant-analysis.mjs";

const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString("base64");

async function withServer(run) {
  const app = createGroveServer({ port: 0 });
  const address = await app.listen();
  try {
    await run(`http://127.0.0.1:${address.port}`, app);
  } finally {
    await app.close();
  }
}

async function withConfiguredServer(analysisClient, run) {
  const app = createGroveServer({ port: 0, analysisClient });
  const address = await app.listen();
  try {
    await run(`http://127.0.0.1:${address.port}`, app);
  } finally {
    await app.close();
  }
}

async function withSpeciesSearchServer(speciesSearchClient, run) {
  const app = createGroveServer({ port: 0, speciesSearchClient });
  const address = await app.listen();
  try {
    await run(`http://127.0.0.1:${address.port}`, app);
  } finally {
    await app.close();
  }
}

function api(baseURL, path, { method = "GET", token = "dev:account-a", body, key = randomUUID() } = {}) {
  return fetch(`${baseURL}/v1/${path}`, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      "idempotency-key": key
    },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
}

test("app key gates /v1 while leaving health open, and public base URL is used for uploads", async () => {
  const app = createGroveServer({ port: 0, appKey: "secret123", publicBaseURL: "https://grove-api.example.com/" });
  const address = await app.listen();
  const baseURL = `http://127.0.0.1:${address.port}`;
  try {
    // Health stays open for platform health checks.
    assert.equal((await fetch(`${baseURL}/health`)).status, 200);

    // /v1 requires the app key.
    const missing = await fetch(`${baseURL}/v1/bootstrap`, { headers: { authorization: "Bearer account-a" } });
    assert.equal(missing.status, 401);
    const wrong = await fetch(`${baseURL}/v1/bootstrap`, { headers: { authorization: "Bearer account-a", "x-grove-app-key": "nope" } });
    assert.equal(wrong.status, 401);
    const ok = await fetch(`${baseURL}/v1/bootstrap`, { headers: { authorization: "Bearer account-a", "x-grove-app-key": "secret123" } });
    assert.equal(ok.status, 200);

    // Signed upload URL uses the forced public origin, not the bind host.
    const upload = await fetch(`${baseURL}/v1/media/uploads`, {
      method: "POST",
      headers: { authorization: "Bearer account-a", "x-grove-app-key": "secret123", "content-type": "application/json" },
      body: JSON.stringify({ localMediaID: randomUUID(), mimeType: "image/jpeg", byteCount: 1024, sha256: "a".repeat(64) })
    });
    assert.equal(upload.status, 201);
    assert.match((await upload.json()).uploadURL, /^https:\/\/grove-api\.example\.com\/uploads\//);
  } finally {
    await app.close();
  }
});

test("health and authenticated bootstrap are available", async () => withServer(async (baseURL) => {
  const health = await fetch(`${baseURL}/health`);
  assert.equal(health.status, 200);
  assert.equal((await health.json()).status, "ok");

  const unauthorised = await fetch(`${baseURL}/v1/bootstrap`);
  assert.equal(unauthorised.status, 401);

  const bootstrap = await api(baseURL, "bootstrap");
  assert.equal(bootstrap.status, 200);
  const snapshot = await bootstrap.json();
  assert.deepEqual(snapshot.plants, []);
  assert.equal(snapshot.profile.isPrivate, true);
}));

test("Journey progress follows the account and rejects an older device snapshot", async () => withServer(async (baseURL) => {
  const newerAt = "2026-09-04T12:00:00Z";
  const newer = { xp: 420, currentStreak: 12, longestStreak: 18, lastTendDay: "2026-09-04T12:00:00Z" };
  const saved = await api(baseURL, "journey-progress", {
    method: "PATCH",
    body: { gardener: newer, updatedAt: newerAt, clientRequestID: randomUUID() }
  });
  assert.equal(saved.status, 200);

  const stale = await api(baseURL, "journey-progress", {
    method: "PATCH",
    body: {
      gardener: { xp: 10, currentStreak: 1, longestStreak: 1 },
      updatedAt: "2026-09-03T12:00:00Z",
      clientRequestID: randomUUID()
    }
  });
  assert.equal(stale.status, 200);
  assert.deepEqual((await stale.json()).gardener, newer);

  const snapshot = await (await api(baseURL, "bootstrap")).json();
  assert.deepEqual(snapshot.gardener, newer);
  assert.equal(snapshot.gardenerUpdatedAt, newerAt);
}));

test("profiles filter abusive names and reports validate their safety contract", async () => withServer(async (baseURL) => {
  const profile = await api(baseURL, "profile", {
    method: "PATCH",
    body: {
      displayName: "spam nigger",
      username: "respectful_name",
      regionCode: "GB",
      usesMetricSystem: true,
      isPrivate: false,
      clientRequestID: randomUUID()
    }
  });
  assert.equal(profile.status, 422);

  const invalidReport = await api(baseURL, `friendships/${randomUUID()}/report`, {
    method: "POST",
    body: { reason: "madeUp", details: "", clientRequestID: randomUUID() }
  });
  assert.equal(invalidReport.status, 422);

  const report = await api(baseURL, `friendships/${randomUUID()}/report`, {
    method: "POST",
    body: { reason: "spam", details: "Repeated unwanted contact", clientRequestID: randomUUID() }
  });
  assert.equal(report.status, 200);
}));

test("accounts and idempotent plant writes are isolated", async () => withServer(async (baseURL) => {
  const clientPlantID = randomUUID();
  const request = {
    clientPlantID,
    nickname: "Pesto",
    location: "Kitchen",
    mediaDraftID: randomUUID(),
    analysis: {
      identification: { commonName: "Basil", scientificName: "Ocimum basilicum", confidence: 93 },
      condition: { healthScore: 84, healthBand: "healthy", confidence: 86, summary: "Healthy", positiveSigns: [], concerns: [], nextActions: [] }
    }
  };
  const key = randomUUID();
  const first = await api(baseURL, "plants", { method: "POST", body: request, key });
  assert.equal(first.status, 201);
  const firstBody = await first.json();
  const replay = await api(baseURL, "plants", { method: "POST", body: request, key });
  assert.deepEqual(await replay.json(), firstBody);
  const collision = await api(baseURL, "plants", { method: "POST", body: { ...request, nickname: "Changed" }, key });
  assert.equal(collision.status, 409, "one replay key cannot stand for different request details");

  const accountA = await (await api(baseURL, "bootstrap")).json();
  const accountB = await (await api(baseURL, "bootstrap", { token: "dev:account-b" })).json();
  assert.equal(accountA.plants.length, 1);
  assert.equal(accountB.plants.length, 0);
}));

test("direct care survives bootstrap, undo removes it, and plant deletion is durable", async () => withServer(async (baseURL) => {
  const plantID = randomUUID();
  const adopted = await api(baseURL, "plants", {
    method: "POST",
    body: {
      clientPlantID: plantID,
      nickname: "Pesto",
      location: "Kitchen",
      mediaDraftID: randomUUID(),
      analysis: {
        identification: { commonName: "Basil", scientificName: "Ocimum basilicum", confidence: 93 },
        condition: { healthScore: 84, healthBand: "healthy", confidence: 86, summary: "Healthy", positiveSigns: [], concerns: [], nextActions: [] }
      }
    }
  });
  assert.equal(adopted.status, 201);

  const taskID = randomUUID();
  const occurredAt = new Date().toISOString();
  const logged = await api(baseURL, "care-actions", {
    method: "POST",
    body: {
      clientRequestID: randomUUID(),
      task: {
        id: taskID,
        plantID,
        kind: "inspectSoil",
        dueDate: occurredAt,
        detail: "Soil felt damp.",
        isCompleted: true,
        isSittingTask: false,
        ownerName: null,
        soilMoisture: "comfortable",
        completedAt: occurredAt
      }
    }
  });
  assert.equal(logged.status, 201);

  let snapshot = await (await api(baseURL, "bootstrap")).json();
  assert.equal(snapshot.tasks.find((task) => task.id === taskID)?.soilMoisture, "comfortable");
  assert.equal(snapshot.tasks.find((task) => task.id === taskID)?.completedAt, occurredAt);

  const undone = await api(baseURL, `care-actions/${taskID}/delete`, {
    method: "POST",
    body: { taskID, clientRequestID: randomUUID() }
  });
  assert.equal(undone.status, 200);
  snapshot = await (await api(baseURL, "bootstrap")).json();
  assert.equal(snapshot.tasks.some((task) => task.id === taskID), false);

  const removed = await api(baseURL, `plants/${plantID}/delete`, {
    method: "POST",
    body: { plantID, clientRequestID: randomUUID() }
  });
  assert.equal(removed.status, 200);
  snapshot = await (await api(baseURL, "bootstrap")).json();
  assert.equal(snapshot.plants.some((plant) => plant.id === plantID), false);
  assert.equal(snapshot.tasks.some((task) => task.plantID === plantID), false);
}));

test("simultaneous friend requests cannot execute two bodies under one replay key", async () => withServer(async (baseURL) => {
  const key = randomUUID();
  const [first, second] = await Promise.all([
    api(baseURL, "friendships/invitations", {
      method: "POST",
      key,
      body: { username: "alice_grows", clientRequestID: randomUUID() }
    }),
    api(baseURL, "friendships/invitations", {
      method: "POST",
      key,
      body: { username: "bob_grows", clientRequestID: randomUUID() }
    })
  ]);
  assert.deepEqual([first.status, second.status].sort(), [201, 409]);

  const snapshot = await (await api(baseURL, "bootstrap")).json();
  assert.equal(snapshot.friendInvitations.length, 1);
}));

test("signed media upload verifies content integrity", async () => withServer(async (baseURL) => {
  const bytes = Buffer.from("grove-photo-evidence");
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  const localMediaID = randomUUID();
  const uploadRequest = { localMediaID, purpose: "observation", mimeType: "image/jpeg", byteCount: bytes.length, pixelWidth: 900, pixelHeight: 1200, sha256 };
  const created = await api(baseURL, "media/uploads", {
    method: "POST",
    body: uploadRequest
  });
  assert.equal(created.status, 201);
  const signed = await created.json();

  const uploaded = await fetch(signed.uploadURL, { method: "PUT", headers: { ...signed.headers, "content-type": "image/jpeg" }, body: bytes });
  assert.equal(uploaded.status, 204);

  const completed = await api(baseURL, `media/${signed.mediaAssetID}/complete`, {
    method: "POST",
    body: { localMediaID, sha256 }
  });
  assert.equal(completed.status, 200);
  assert.equal((await completed.json()).status, "ready");

  const resumed = await api(baseURL, "media/uploads", { method: "POST", body: uploadRequest });
  assert.equal((await resumed.json()).mediaAssetID, signed.mediaAssetID);
  const conflicting = await api(baseURL, "media/uploads", {
    method: "POST",
    body: { ...uploadRequest, sha256: "a".repeat(64) }
  });
  assert.equal(conflicting.status, 409);
}));

test("analysis jobs resolve completed account-owned media evidence", async () => {
  const received = [];
  const expected = {
    identification: { commonName: "Unknown", scientificName: "Species uncertain", confidence: 0, alternatives: [], distinguishingTraits: [] },
    condition: { healthScore: 70, healthBand: "monitor", confidence: 40, summary: "More evidence needed", positiveSigns: [], concerns: [], possibleCauses: [], nextActions: [] },
    providerName: "Test provider",
    limitations: []
  };
  await withConfiguredServer({ analyse: async (request) => { received.push(request); return expected; } }, async (baseURL) => {
    const bytes = Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
    const sha256 = createHash("sha256").update(bytes).digest("hex");
    const localMediaID = randomUUID();
    const created = await api(baseURL, "media/uploads", {
      method: "POST",
      body: { localMediaID, purpose: "scan", mimeType: "image/jpeg", byteCount: bytes.length, pixelWidth: 900, pixelHeight: 1200, sha256 }
    });
    const signed = await created.json();
    const uploaded = await fetch(signed.uploadURL, {
      method: "PUT",
      headers: { ...signed.headers, "content-type": "image/jpeg" },
      body: bytes
    });
    assert.equal(uploaded.status, 204);
    await api(baseURL, `media/${signed.mediaAssetID}/complete`, {
      method: "POST",
      body: { localMediaID, sha256 }
    });

    const jobResponse = await api(baseURL, "analysis/jobs", {
      method: "POST",
      body: {
        clientRequestID: randomUUID(),
        mode: "identify",
        images: [{ stage: "wholePlant", mimeType: "image/jpeg", mediaAssetID: signed.mediaAssetID }],
        answers: {}
      }
    });
    let job = await jobResponse.json();
    for (let attempt = 0; attempt < 10 && job.status !== "completed"; attempt += 1) {
      await new Promise((resolve) => setImmediate(resolve));
      job = await (await api(baseURL, `analysis/jobs/${job.id}`)).json();
    }
    assert.equal(job.status, "completed");
    assert.equal(received[0].images[0].base64Data, bytes.toString("base64"));
    assert.equal(received[0].images[0].mediaAssetID, undefined);

    const crossAccount = await api(baseURL, "analysis/jobs", {
      method: "POST",
      token: "dev:account-b",
      body: {
        clientRequestID: randomUUID(),
        mode: "identify",
        images: [{ stage: "wholePlant", mimeType: "image/jpeg", mediaAssetID: signed.mediaAssetID }],
        answers: {}
      }
    });
    assert.equal(crossAccount.status, 422);
    assert.match((await crossAccount.json()).message, /unavailable or not ready/);
  });
});

test("authenticated analysis delegates to the configured provider", async () => {
  const expected = {
    identification: { commonName: "Basil", scientificName: "Ocimum basilicum", confidence: 91, alternatives: [], distinguishingTraits: [] },
    condition: { healthScore: 80, healthBand: "healthy", confidence: 75, summary: "Looks healthy", positiveSigns: [], concerns: [], possibleCauses: [], nextActions: [] },
    providerName: "Test provider",
    limitations: []
  };
  const received = [];
  await withConfiguredServer({ analyse: async (body) => { received.push(body); return expected; } }, async (baseURL) => {
    const response = await api(baseURL, "analysis", {
      method: "POST",
      body: {
        mode: "identify",
        regionCode: "GB",
        images: [{ stage: "wholePlant", mimeType: "image/jpeg", base64Data: jpeg }],
        answers: {}
      }
    });

    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.providerName, "Test provider");
    assert.equal(body.identification.isUnknown, true);
    assert.equal(body.identification.requiresConfirmation, true);
    assert.equal(received[0].regionCode, "GB");
  });
});

test("analysis jobs are resumable, idempotent, and account scoped", async () => {
  const expected = {
    identification: { commonName: "Basil", scientificName: "Ocimum basilicum", confidence: 91, alternatives: [], distinguishingTraits: [] },
    condition: { healthScore: 80, healthBand: "healthy", confidence: 75, summary: "Looks healthy", positiveSigns: [], concerns: [], possibleCauses: [], nextActions: [] },
    providerName: "Test provider",
    limitations: []
  };
  let calls = 0;
  await withConfiguredServer({ analyse: async () => { calls += 1; return expected; } }, async (baseURL) => {
    const request = {
      clientRequestID: "a1000000-0000-4000-8000-000000000001",
      mode: "identify",
      regionCode: "GB",
      images: [{ stage: "wholePlant", mimeType: "image/jpeg", base64Data: jpeg }],
      answers: {}
    };
    const created = await api(baseURL, "analysis/jobs", { method: "POST", body: request });
    assert.equal(created.status, 202);
    let job = await created.json();
    assert.match(job.id, /^[0-9a-f-]{36}$/i);

    for (let attempt = 0; attempt < 10 && job.status !== "completed"; attempt += 1) {
      await new Promise((resolve) => setImmediate(resolve));
      const polled = await api(baseURL, `analysis/jobs/${job.id}`);
      job = await polled.json();
    }
    assert.equal(job.status, "completed");
    assert.equal(job.result.providerName, "Test provider");

    const resumed = await api(baseURL, "analysis/jobs", { method: "POST", body: request });
    const resumedJob = await resumed.json();
    assert.equal(resumedJob.id, job.id);
    assert.equal(resumedJob.status, "completed");
    assert.equal(calls, 1);

    const otherAccount = await api(baseURL, `analysis/jobs/${job.id}`, { token: "dev:account-b" });
    assert.equal(otherAccount.status, 404);
  });
});

test("analysis jobs expose safe failures and can be cancelled", async () => {
  let releaseProvider;
  const providerGate = new Promise((resolve) => { releaseProvider = resolve; });
  await withConfiguredServer({
    analyse: async () => {
      await providerGate;
      throw new GeminiProviderError(429, "prepayment credits depleted");
    }
  }, async (baseURL) => {
    const request = {
      clientRequestID: "a1000000-0000-4000-8000-000000000002",
      mode: "identify",
      images: [{ stage: "wholePlant", mimeType: "image/jpeg", base64Data: jpeg }],
      answers: {}
    };
    const created = await api(baseURL, "analysis/jobs", { method: "POST", body: request });
    const job = await created.json();
    const cancelled = await api(baseURL, `analysis/jobs/${job.id}`, { method: "DELETE" });
    assert.equal((await cancelled.json()).status, "cancelled");
    releaseProvider();

    const failedRequest = { ...request, clientRequestID: "a1000000-0000-4000-8000-000000000003" };
    const failedCreated = await api(baseURL, "analysis/jobs", { method: "POST", body: failedRequest });
    let failedJob = await failedCreated.json();
    for (let attempt = 0; attempt < 10 && failedJob.status !== "failed"; attempt += 1) {
      await new Promise((resolve) => setImmediate(resolve));
      failedJob = await (await api(baseURL, `analysis/jobs/${failedJob.id}`)).json();
    }
    assert.equal(failedJob.status, "failed");
    assert.equal(failedJob.message, "Plant analysis is temporarily unavailable. Try again with the saved photos.");
    assert.doesNotMatch(JSON.stringify(failedJob), /prepayment|billing/i);
  });
});

test("retrying an identical request after a failure starts a fresh job", async () => {
  let calls = 0;
  await withConfiguredServer({
    analyse: async () => {
      calls += 1;
      if (calls === 1) throw new GeminiProviderError(503, "transient outage");
      return {
        identification: { commonName: "Basil", scientificName: "Ocimum basilicum", confidence: 91, alternatives: [], distinguishingTraits: [] },
        condition: { healthScore: 80, healthBand: "healthy", confidence: 75, summary: "Looks healthy", positiveSigns: [], concerns: [], possibleCauses: [], nextActions: [] },
        providerName: "Test provider",
        limitations: []
      };
    }
  }, async (baseURL) => {
    const request = {
      clientRequestID: "a1000000-0000-4000-8000-000000000004",
      mode: "identify",
      images: [{ stage: "wholePlant", mimeType: "image/jpeg", base64Data: jpeg }],
      answers: {}
    };
    const created = await api(baseURL, "analysis/jobs", { method: "POST", body: request });
    let job = await created.json();
    for (let attempt = 0; attempt < 10 && job.status !== "failed"; attempt += 1) {
      await new Promise((resolve) => setImmediate(resolve));
      job = await (await api(baseURL, `analysis/jobs/${job.id}`)).json();
    }
    assert.equal(job.status, "failed");

    // The same scan retried must not be pinned to the settled failure.
    const retried = await api(baseURL, "analysis/jobs", { method: "POST", body: request });
    let retriedJob = await retried.json();
    assert.notEqual(retriedJob.id, job.id);
    for (let attempt = 0; attempt < 10 && retriedJob.status !== "completed"; attempt += 1) {
      await new Promise((resolve) => setImmediate(resolve));
      retriedJob = await (await api(baseURL, `analysis/jobs/${retriedJob.id}`)).json();
    }
    assert.equal(retriedJob.status, "completed");
    assert.equal(calls, 2);
  });
});

test("maintenance sweep fails stuck jobs, then clears settled state and expired uploads", async () => {
  let releaseProvider;
  const providerGate = new Promise((resolve) => { releaseProvider = resolve; });
  await withConfiguredServer({ analyse: () => providerGate }, async (baseURL, app) => {
    const request = {
      clientRequestID: "a1000000-0000-4000-8000-000000000005",
      mode: "identify",
      images: [{ stage: "wholePlant", mimeType: "image/jpeg", base64Data: jpeg }],
      answers: {}
    };
    const created = await api(baseURL, "analysis/jobs", { method: "POST", body: request });
    const job = await created.json();

    // A job hanging in "analysing" is failed by the watchdog rather than polling forever.
    app.sweepExpiredState(Date.now() + 5 * 60_000);
    const watched = await (await api(baseURL, `analysis/jobs/${job.id}`)).json();
    assert.equal(watched.status, "failed");
    assert.equal(watched.message, "Plant analysis timed out. Try again with the saved photos.");

    // Well past retention, the settled job and its idempotency replays are dropped.
    app.sweepExpiredState(Date.now() + 2 * 60 * 60_000);
    assert.equal(app.analysisJobs.size, 0);
    releaseProvider();
  });
});

test("polling an analysis job is never served from the idempotency replay cache", async () => {
  let releaseProvider;
  const providerGate = new Promise((resolve) => { releaseProvider = resolve; });
  const expected = {
    identification: { commonName: "Basil", scientificName: "Ocimum basilicum", confidence: 91, alternatives: [], distinguishingTraits: [] },
    condition: { healthScore: 80, healthBand: "healthy", confidence: 75, summary: "Looks healthy", positiveSigns: [], concerns: [], possibleCauses: [], nextActions: [] },
    providerName: "Test provider",
    limitations: []
  };
  await withConfiguredServer({ analyse: async () => { await providerGate; return expected; } }, async (baseURL) => {
    const request = {
      clientRequestID: "a1000000-0000-4000-8000-000000000006",
      mode: "identify",
      images: [{ stage: "wholePlant", mimeType: "image/jpeg", base64Data: jpeg }],
      answers: {}
    };
    const job = await (await api(baseURL, "analysis/jobs", { method: "POST", body: request })).json();

    // Same idempotency key on every poll — a replayed GET would freeze the job in "analysing".
    const sharedKey = "11111111-2222-4333-8444-555555555555";
    const before = await (await api(baseURL, `analysis/jobs/${job.id}`, { key: sharedKey })).json();
    assert.equal(before.status, "analysing");
    releaseProvider();
    let after = before;
    for (let attempt = 0; attempt < 10 && after.status !== "completed"; attempt += 1) {
      await new Promise((resolve) => setImmediate(resolve));
      after = await (await api(baseURL, `analysis/jobs/${job.id}`, { key: sharedKey })).json();
    }
    assert.equal(after.status, "completed");
  });
});

test("analysis fails closed when no provider is configured", async () => withServer(async (baseURL) => {
  const response = await api(baseURL, "analysis", {
    method: "POST",
    body: { mode: "identify", images: [{ stage: "wholePlant", mimeType: "image/jpeg", base64Data: jpeg }], answers: {} }
  });
  assert.equal(response.status, 503);
}));

test("analysis rejects invalid evidence before calling the provider", async () => {
  let calls = 0;
  await withConfiguredServer({ analyse: async () => { calls += 1; } }, async (baseURL) => {
    const response = await api(baseURL, "analysis", {
      method: "POST",
      body: {
        mode: "add",
        images: [{ stage: "leaf", mimeType: "image/jpeg", base64Data: jpeg }],
        answers: {}
      }
    });

    assert.equal(response.status, 422);
    assert.match((await response.json()).message, /wholePlant image/);
    assert.equal(calls, 0);
  });
});

test("analysis reports provider deadlines as gateway timeouts", async () => {
  await withConfiguredServer({
    analyse: async () => { throw new GeminiRequestTimeoutError("Provider detail"); }
  }, async (baseURL) => {
    const response = await api(baseURL, "analysis", {
      method: "POST",
      body: {
        mode: "identify",
        images: [{ stage: "wholePlant", mimeType: "image/jpeg", base64Data: jpeg }],
        answers: {}
      }
    });

    assert.equal(response.status, 504);
    assert.equal((await response.json()).message, "Plant analysis timed out. Try again with the saved photos.");
  });
});

test("analysis does not expose provider billing details to clients", async () => {
  await withConfiguredServer({
    analyse: async () => { throw new GeminiProviderError(429, "prepayment credits depleted"); }
  }, async (baseURL) => {
    const response = await api(baseURL, "analysis", {
      method: "POST",
      body: {
        mode: "identify",
        images: [{ stage: "wholePlant", mimeType: "image/jpeg", base64Data: jpeg }],
        answers: {}
      }
    });

    assert.equal(response.status, 503);
    const body = await response.json();
    assert.equal(body.message, "Plant analysis is temporarily unavailable. Try again with the saved photos.");
    assert.doesNotMatch(JSON.stringify(body), /prepayment|billing/i);
  });
});

test("analysis does not expose unexpected provider errors to clients", async () => {
  await withConfiguredServer({
    analyse: async () => { throw new Error("internal host api.private.example secret-token-123"); }
  }, async (baseURL) => {
    const response = await api(baseURL, "analysis", {
      method: "POST",
      body: {
        mode: "identify",
        images: [{ stage: "wholePlant", mimeType: "image/jpeg", base64Data: jpeg }],
        answers: {}
      }
    });

    assert.equal(response.status, 502);
    const body = await response.json();
    assert.equal(body.message, "Plant analysis is temporarily unavailable. Try again with the saved photos.");
    assert.doesNotMatch(JSON.stringify(body), /api\.private|secret-token/i);
  });
});

test("manual species search is authenticated and delegates the query", async () => {
  const queries = [];
  await withSpeciesSearchServer({
    search: async (query) => {
      queries.push(query);
      return [{ id: "gbif:1", commonName: "Snake plant", scientificName: "Dracaena trifasciata", confidence: 100, distinguishingTraits: [], regionalFit: "GBIF" }];
    }
  }, async (baseURL) => {
    const response = await api(baseURL, "species/search?q=snake%20plant");
    assert.equal(response.status, 200);
    assert.equal((await response.json())[0].scientificName, "Dracaena trifasciata");
    assert.deepEqual(queries, ["snake plant"]);
  });
});
