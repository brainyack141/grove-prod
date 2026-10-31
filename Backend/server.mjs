import { createHash, randomUUID } from "node:crypto";
import { createServer } from "node:http";
import { pathToFileURL } from "node:url";
import { loadGeminiAPIKey } from "./config.mjs";
import {
  createGeminiPlantAnalysisClient,
  GeminiProviderError,
  GeminiRequestTimeoutError
} from "./gemini-plant-analysis.mjs";
import { createGBIFSpeciesSearchClient } from "./gbif-species-search.mjs";
import { createGroveDatabase, loadDatabaseURL } from "./supabase-db.mjs";
import { createGroveStore, UnknownAccountError } from "./grove-store.mjs";
import { sanitizePlantAnalysis } from "./analysis-safety.mjs";
import { AnalysisRequestValidationError, validatePlantAnalysisRequest } from "./analysis-request-validation.mjs";

const jsonHeaders = { "content-type": "application/json; charset=utf-8" };
const requestBodyCache = Symbol("groveRequestBody");
const blockedProfileWords = new Set([
  "cunt", "faggot", "fag", "kike", "nigger", "nigga", "retard", "whore"
]);

function containsBlockedProfileLanguage(value) {
  const words = String(value ?? "").normalize("NFKC").toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
  return words.some((word) => blockedProfileWords.has(word));
}

function validGardenerProgress(value) {
  if (!value || Array.isArray(value) || typeof value !== "object") return false;
  const integerFields = [
    "xp", "currentStreak", "longestStreak", "streakShields", "lastShieldStreak",
    "questCheckIns", "questCareLogged", "questLessons", "questPlantsAdded"
  ];
  if (integerFields.some((field) => {
    const candidate = Number(value[field] ?? 0);
    return !Number.isSafeInteger(candidate) || candidate < 0 || candidate > 1_000_000_000;
  })) return false;
  const setFields = [
    "completedMilestoneIDs", "completedInteractiveIDs", "unlockedBadgeIDs",
    "openedChestIDs", "keepsakeIDs", "discoveredLandmarkIDs", "claimedQuestIDs"
  ];
  if (!setFields.every((field) => {
    const values = value[field] ?? [];
    return Array.isArray(values) && values.length <= 5_000
      && values.every((item) => typeof item === "string" && item.length <= 160);
  })) return false;
  for (const field of ["lastTendDay", "lastRefresherXPDay", "questDay"]) {
    if (value[field] != null && Number.isNaN(new Date(value[field]).valueOf())) return false;
  }
  const badgeDates = value.unlockedBadgeDates ?? {};
  return badgeDates && !Array.isArray(badgeDates) && typeof badgeDates === "object"
    && Object.keys(badgeDates).length <= 5_000
    && Object.entries(badgeDates).every(([key, date]) =>
      key.length <= 160 && !Number.isNaN(new Date(String(date)).valueOf()));
}

function iso(date = new Date()) {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

// Server-generated ids (randomUUID) are lowercase, but Apple's UUID.uuidString is
// uppercase, so clients round-trip ids back in uppercase. Normalize client-supplied
// ids before any case-sensitive Map lookup so media/job routes match regardless of case.
function normalizeID(id) {
  return typeof id === "string" ? id.toLowerCase() : id;
}

function emptyAccount(accountID) {
  const demo = accountID === "demo-local-account";
  return {
    profile: {
      name: demo ? "Alex Rivera" : "Development Gardener",
      username: demo ? "alexgrows" : `dev_${accountID.slice(-8).replace(/[^a-z0-9]/gi, "").toLowerCase() || "gardener"}`,
      initials: demo ? "AR" : "DG",
      friendCount: 0,
      regionCode: "GB",
      usesMetricSystem: true,
      isPrivate: true
    },
    plants: [],
    tasks: [],
    activity: [],
    assignments: [],
    observations: [],
    friends: [],
    friendInvitations: [],
    gardener: undefined,
    gardenerUpdatedAt: undefined,
    media: new Map()
  };
}

function json(res, status, value) {
  res.writeHead(status, jsonHeaders);
  res.end(JSON.stringify(value));
}

function error(res, status, message) {
  json(res, status, { message });
}

class RequestBodyTooLargeError extends Error {}

function publicAnalysisFailure(analysisError) {
  if (analysisError instanceof GeminiRequestTimeoutError) {
    return "Plant analysis timed out. Try again with the saved photos.";
  }
  return "Plant analysis is temporarily unavailable. Try again with the saved photos.";
}

function publicAnalysisJob(job) {
  return {
    id: job.id,
    status: job.status,
    createdAt: job.createdAt,
    updatedAt: job.updatedAt,
    result: job.result,
    message: job.message
  };
}

async function readBody(req, limit = 12 * 1024 * 1024) {
  const cached = req[requestBodyCache];
  if (cached) {
    if (cached.data.length > limit) throw new RequestBodyTooLargeError("Request body is too large.");
    return cached.value;
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) throw new RequestBodyTooLargeError("Request body is too large.");
    chunks.push(chunk);
  }
  const data = Buffer.concat(chunks);
  const value = data.length ? JSON.parse(data.toString("utf8")) : {};
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new SyntaxError("Request body must be a JSON object.");
  }
  req[requestBodyCache] = { data, value };
  return value;
}

function authenticatedAccountID(req) {
  const authorization = req.headers.authorization ?? "";
  if (!authorization.startsWith("Bearer ")) return undefined;
  const token = authorization.slice("Bearer ".length);
  const accountID = token.startsWith("dev:") ? token.slice(4) : token;
  return accountID || undefined;
}

function authenticatedAccount(req, accounts) {
  const accountID = authenticatedAccountID(req);
  if (!accountID) return undefined;
  if (!accounts.has(accountID)) accounts.set(accountID, emptyAccount(accountID));
  return { id: accountID, data: accounts.get(accountID) };
}

function plantFromRequest(body) {
  const identification = body.analysis?.identification ?? {};
  const condition = body.analysis?.condition ?? {};
  return {
    id: body.clientPlantID ?? randomUUID(),
    nickname: body.nickname || "New plant",
    species: identification.commonName ?? "Unknown plant",
    scientificName: identification.scientificName ?? "Species uncertain",
    location: body.location || "Unassigned",
    healthScore: condition.healthScore ?? 70,
    healthBand: condition.healthBand ?? "monitor",
    trend: "baseline",
    confidence: condition.confidence ?? identification.confidence ?? 0,
    nextCheckIn: iso(new Date(Date.now() + 14 * 86_400_000)),
    symbol: "leaf.fill",
    palette: "fern",
    summary: condition.summary ?? "Baseline saved.",
    positiveSigns: condition.positiveSigns ?? [],
    concerns: condition.concerns ?? [],
    nextActions: condition.nextActions ?? [],
    checkInFrequencyDays: body.plant?.checkInFrequencyDays ?? body.checkInFrequencyDays ?? null
  };
}

// Absolute origin the CLIENT should use to reach this server — for media upload URLs.
// Behind a hosting platform's TLS proxy the request arrives as https with the public
// host, so derive it from the forwarded headers; PUBLIC_BASE_URL forces a fixed value.
function originFor(req, { publicBaseURL, host, port }) {
  if (publicBaseURL) return publicBaseURL.replace(/\/+$/, "");
  const forwardedProto = String(req.headers["x-forwarded-proto"] ?? "").split(",")[0].trim();
  const proto = forwardedProto || "http";
  const hostHeader = req.headers["x-forwarded-host"] || req.headers.host;
  return hostHeader ? `${proto}://${hostHeader}` : `http://${host}:${port}`;
}

// Reports whether the Supabase relational layer is reachable, and — more importantly —
// whether app data is durable at all. `storage: "memory"` means this instance loses every
// account on restart and must never serve a user-facing build (see DEPLOY.md).
// The probe stays advisory so a database blip cannot cycle an otherwise-serving instance.
async function databaseHealth(database) {
  if (!database) return { database: "not_configured", storage: "memory", signupCompletionReady: false };
  try {
    const { serverTime, appTableCount, signupCompletionReady } = await database.check();
    return {
      database: "connected",
      storage: "postgres",
      databaseTime: serverTime,
      appTableCount,
      signupCompletionReady: signupCompletionReady === true
    };
  } catch {
    return { database: "unavailable", storage: "postgres", signupCompletionReady: false };
  }
}

export function createGroveServer({
  port = 8080,
  host = "127.0.0.1",
  publicBaseURL,
  appKey,
  analysisClient,
  database,
  speciesSearchClient = createGBIFSpeciesSearchClient()
} = {}) {
  // When a database is configured, every account-scoped read and write goes
  // through the durable store instead of the Maps below. The in-memory path
  // remains for local development with no database — it is explicitly not a
  // production persistence substitute, and `DEPLOY.md` blocks pointing a
  // user-facing build at a server running without `SUPABASE_DB_URL`.
  const store = database?.sql ? createGroveStore(database.sql) : undefined;

  const accounts = new Map();
  const idempotency = new Map();
  const uploads = new Map();
  const uploadKeys = new Map();
  const analysisJobs = new Map();
  const analysisJobKeys = new Map();

  // Everything above is in memory, so it must be bounded: expired uploads (which hold
  // image buffers), settled jobs, and idempotency replays are swept periodically, and
  // a job that somehow never settles is failed rather than left polling forever.
  const retentionMilliseconds = 60 * 60_000;
  const stuckJobMilliseconds = 4 * 60_000;

  function sweepExpiredState(now = Date.now()) {
    for (const [key, entry] of idempotency) {
      if (now - entry.storedAt > retentionMilliseconds) idempotency.delete(key);
    }
    for (const [id, upload] of uploads) {
      if (now > upload.expiresAt + retentionMilliseconds) {
        uploads.delete(id);
        uploadKeys.delete(`${upload.ownerAccountID}:${upload.localMediaID}`);
      }
    }
    for (const [id, job] of analysisJobs) {
      const age = now - job.createdAtMs;
      if ((job.status === "queued" || job.status === "analysing") && age > stuckJobMilliseconds) {
        job.status = "failed";
        job.message = "Plant analysis timed out. Try again with the saved photos.";
        job.request = undefined;
        job.updatedAt = iso();
      } else if (job.status !== "queued" && job.status !== "analysing" && age > retentionMilliseconds) {
        analysisJobs.delete(id);
        if (analysisJobKeys.get(job.key) === id) analysisJobKeys.delete(job.key);
      }
    }
  }

  const maintenance = setInterval(sweepExpiredState, 60_000);
  maintenance.unref?.();

  function materializeAnalysisEvidence(body, account) {
    if (!body || !Array.isArray(body.images)) return body;
    return {
      ...body,
      images: body.images.map((image, index) => {
        if (!image?.mediaAssetID) return image;
        const mediaAssetID = normalizeID(image.mediaAssetID);
        const upload = uploads.get(mediaAssetID);
        const media = account.data.media.get(mediaAssetID);
        if (!upload || upload.ownerAccountID !== account.id || media?.status !== "ready" || !upload.data) {
          throw new AnalysisRequestValidationError(`Image ${index + 1} media is unavailable or not ready.`);
        }
        if (image.mimeType !== upload.mimeType) {
          throw new AnalysisRequestValidationError(`Image ${index + 1} media type does not match its upload.`);
        }
        return {
          stage: image.stage,
          mimeType: image.mimeType,
          base64Data: upload.data.toString("base64")
        };
      })
    };
  }

  function signedUploadResponse(upload, origin) {
    return {
      mediaAssetID: upload.mediaAssetID,
      uploadURL: `${origin}/uploads/${upload.mediaAssetID}`,
      headers: { "X-Grove-Upload-Token": upload.token },
      expiresAt: iso(new Date(upload.expiresAt))
    };
  }

  function startAnalysisJob(job) {
    void Promise.resolve().then(async () => {
      if (job.status === "cancelled") return;
      job.status = "analysing";
      job.updatedAt = iso();
      try {
        const result = await analysisClient.analyse(job.request);
        if (job.status !== "analysing") return;
        job.result = sanitizePlantAnalysis(result, job.request);
        job.status = "completed";
      } catch (analysisError) {
        if (job.status !== "analysing") return;
        job.message = publicAnalysisFailure(analysisError);
        job.status = "failed";
      } finally {
        job.request = undefined;
        job.updatedAt = iso();
      }
    });
  }

  const server = createServer(async (req, res) => {
    const requestURL = new URL(req.url ?? "/", `http://${req.headers.host ?? `${host}:${port}`}`);
    const path = requestURL.pathname;

    try {
      if (req.method === "GET" && path === "/health") {
        return json(res, 200, { status: "ok", service: "grove-api", ...(await databaseHealth(database)) });
      }

      const uploadMatch = path.match(/^\/uploads\/([0-9a-f-]+)$/i);
      if (req.method === "PUT" && uploadMatch) {
        const upload = uploads.get(normalizeID(uploadMatch[1]));
        if (!upload || req.headers["x-grove-upload-token"] !== upload.token) {
          return error(res, 403, "Upload permission is invalid or expired.");
        }
        if (Date.now() > upload.expiresAt) return error(res, 403, "Upload permission is invalid or expired.");
        if ((req.headers["content-type"] ?? "").split(";", 1)[0] !== upload.mimeType) {
          return error(res, 415, "Uploaded media type does not match the signed request.");
        }
        const chunks = [];
        let uploadSize = 0;
        for await (const chunk of req) {
          uploadSize += chunk.length;
          if (uploadSize > upload.byteCount) return error(res, 413, "Uploaded media exceeds the signed byte count.");
          chunks.push(chunk);
        }
        upload.data = Buffer.concat(chunks);
        upload.actualSHA256 = createHash("sha256").update(upload.data).digest("hex");
        res.writeHead(204);
        return res.end();
      }

      if (!path.startsWith("/v1/")) return error(res, 404, "Route not found.");
      // Optional shared app secret: when GROVE_APP_KEY is configured, every /v1 request
      // must present it, so a public URL can't be pointed at your Gemini quota by anyone.
      if (appKey && req.headers["x-grove-app-key"] !== appKey) {
        return error(res, 401, "App identification is missing or invalid.");
      }
      const accountID = authenticatedAccountID(req);
      if (!accountID) return error(res, 401, "A bearer token is required.");
      // Analysis jobs and signed uploads still use the in-memory account record
      // (they are short-lived and swept); durable app data goes through `store`.
      const account = authenticatedAccount(req, accounts);
      // Resolves against Supabase Auth identity; unknown bearers 401 below.
      if (store) await store.requireAccount(accountID);
      const origin = originFor(req, { publicBaseURL, host, port });

      // Only replay-protect mutating requests: caching GETs (each sent with a fresh
      // key) would grow the map on every analysis-job poll without ever replaying.
      const rawHeader = req.method === "GET" ? undefined : req.headers["idempotency-key"];
      const rawIdempotencyKey = typeof rawHeader === "string" ? rawHeader.trim() : rawHeader;
      if (rawIdempotencyKey && !/^[a-z0-9._:-]{1,128}$/i.test(rawIdempotencyKey)) {
        return error(res, 422, "Idempotency key is invalid.");
      }
      const idempotencyKey = rawIdempotencyKey;
      const cacheKey = idempotencyKey ? `${account.id}:${req.method}:${path}:${idempotencyKey}` : undefined;
      let requestHash;
      let claimID;
      if (cacheKey) {
        await readBody(req);
        requestHash = createHash("sha256").update(req[requestBodyCache].data).digest("hex");
        for (let attempt = 0; attempt < 21; attempt += 1) {
          const candidateClaimID = randomUUID();
          let claim;
          if (store) {
            claim = await store.claimIdempotentResponse(
              accountID,
              req.method,
              path,
              idempotencyKey,
              requestHash,
              candidateClaimID
            );
          } else {
            const existing = idempotency.get(cacheKey);
            if (!existing) {
              idempotency.set(cacheKey, {
                status: 102,
                body: {},
                requestHash,
                claimID: candidateClaimID,
                storedAt: Date.now()
              });
              claim = { claimed: true };
            } else if (existing.status === 102 && Date.now() - existing.storedAt > 15 * 60_000) {
              idempotency.set(cacheKey, {
                status: 102,
                body: {},
                requestHash,
                claimID: candidateClaimID,
                storedAt: Date.now()
              });
              claim = { claimed: true };
            } else if (!existing.requestHash || existing.requestHash !== requestHash) {
              claim = { conflict: true };
            } else if (existing.status === 102) {
              claim = { wait: true };
            } else {
              claim = { status: existing.status, body: existing.body };
            }
          }

          if (claim.conflict) {
            return error(res, 409, "That request key was already used for different details.");
          }
          if (claim.status !== undefined) return json(res, claim.status, claim.body);
          if (claim.claimed) {
            claimID = candidateClaimID;
            break;
          }
          if (attempt < 20) await new Promise((resolve) => setTimeout(resolve, 250));
        }
        if (!claimID) {
          return error(res, 503, "That change is still being saved. Grove will retry it shortly.");
        }
      }

      let idempotencySettled = !cacheKey;
      const abandonClaim = async () => {
        if (!cacheKey || !claimID || idempotencySettled) return;
        if (store) {
          await store.abandonIdempotentResponse(
            accountID,
            req.method,
            path,
            idempotencyKey,
            requestHash,
            claimID
          );
        } else if (idempotency.get(cacheKey)?.claimID === claimID) {
          idempotency.delete(cacheKey);
        }
      };
      res.once("finish", () => {
        if (!idempotencySettled) {
          void abandonClaim().catch((claimError) => {
            console.warn("Could not abandon idempotency claim:", claimError.message);
          });
        }
      });
      const send = async (status, body) => {
        if (cacheKey && claimID) {
          try {
            if (store) {
              await store.completeIdempotentResponse(
                accountID,
                req.method,
                path,
                idempotencyKey,
                requestHash,
                claimID,
                status,
                body
              );
            } else if (idempotency.get(cacheKey)?.claimID === claimID) {
              if (status >= 200 && status < 300) {
                idempotency.set(cacheKey, { status, body, requestHash, claimID, storedAt: Date.now() });
              } else {
                idempotency.delete(cacheKey);
              }
              const accountEntries = [...idempotency.entries()]
                .filter(([key]) => key.startsWith(`${account.id}:`))
                .sort((left, right) => right[1].storedAt - left[1].storedAt);
              for (const [key] of accountEntries.slice(1000)) idempotency.delete(key);
            }
            idempotencySettled = true;
          } catch (replayError) {
            // The mutation already succeeded. Return it and leave the claim as
            // a short lease; manufacturing a failure guarantees an unsafe retry.
            idempotencySettled = true;
            console.warn("Could not complete idempotency claim:", replayError.message);
          }
        }
        return json(res, status, body);
      };

      if (req.method === "GET" && path === "/v1/bootstrap") {
        if (store) {
          return send(200, { ...(await store.snapshot(accountID)), serverTime: iso(), storage: "postgres" });
        }
        // The client refuses to apply a snapshot from a server that cannot keep
        // it, because it applies bootstraps wholesale — see SyncEngine.
        const { media: _, ...snapshot } = account.data;
        return send(200, { ...snapshot, serverTime: iso(), storage: "memory" });
      }

      if (req.method === "POST" && path === "/v1/analysis/jobs") {
        if (!analysisClient) return error(res, 503, "Plant analysis is not configured.");
        let body;
        try {
          body = validatePlantAnalysisRequest(materializeAnalysisEvidence(await readBody(req), account));
        } catch (validationError) {
          if (validationError instanceof AnalysisRequestValidationError) {
            return error(res, 422, validationError.message);
          }
          throw validationError;
        }
        if (!body.clientRequestID) return error(res, 422, "Client request id is required for an analysis job.");

        const fingerprint = createHash("sha256").update(JSON.stringify(body)).digest("hex");
        const jobKey = `${account.id}:${body.clientRequestID}:${fingerprint}`;
        const existingJobID = analysisJobKeys.get(jobKey);
        if (existingJobID) {
          const existingJob = analysisJobs.get(existingJobID);
          // A settled failure must not pin this scan to that failure forever —
          // an identical retry should start a fresh attempt.
          if (existingJob && existingJob.status !== "failed" && existingJob.status !== "cancelled") {
            return json(res, existingJob.status === "completed" ? 200 : 202, publicAnalysisJob(existingJob));
          }
        }

        const timestamp = iso();
        const job = {
          id: randomUUID(),
          ownerAccountID: account.id,
          clientRequestID: body.clientRequestID,
          key: jobKey,
          status: "queued",
          createdAt: timestamp,
          createdAtMs: Date.now(),
          updatedAt: timestamp,
          request: body,
          result: undefined,
          message: undefined
        };
        analysisJobs.set(job.id, job);
        analysisJobKeys.set(jobKey, job.id);
        startAnalysisJob(job);
        return json(res, 202, publicAnalysisJob(job));
      }

      const analysisJobMatch = path.match(/^\/v1\/analysis\/jobs\/([0-9a-f-]+)$/i);
      if (analysisJobMatch) {
        const job = analysisJobs.get(normalizeID(analysisJobMatch[1]));
        if (!job || job.ownerAccountID !== account.id) return error(res, 404, "Analysis job not found.");
        if (req.method === "GET") {
          return json(res, job.status === "completed" ? 200 : 202, publicAnalysisJob(job));
        }
        if (req.method === "DELETE") {
          if (job.status === "queued" || job.status === "analysing") {
            job.status = "cancelled";
            job.updatedAt = iso();
            job.request = undefined;
          }
          return json(res, 200, publicAnalysisJob(job));
        }
      }

      if (req.method === "POST" && path === "/v1/analysis") {
        if (!analysisClient) return error(res, 503, "Plant analysis is not configured.");
        let body;
        try {
          body = validatePlantAnalysisRequest(materializeAnalysisEvidence(await readBody(req), account));
        } catch (validationError) {
          if (validationError instanceof AnalysisRequestValidationError) {
            return error(res, 422, validationError.message);
          }
          throw validationError;
        }
        try {
          const result = await analysisClient.analyse(body);
          return send(200, sanitizePlantAnalysis(result, body));
        } catch (analysisError) {
          if (analysisError instanceof GeminiRequestTimeoutError) {
            return error(res, 504, publicAnalysisFailure(analysisError));
          }
          if (analysisError instanceof GeminiProviderError) {
            const status = [429, 500, 502, 503].includes(analysisError.status) ? 503 : 502;
            return error(res, status, publicAnalysisFailure(analysisError));
          }
          return error(
            res,
            502,
            publicAnalysisFailure(analysisError)
          );
        }
      }

      if (req.method === "GET" && path === "/v1/species/search") {
        const query = requestURL.searchParams.get("q") ?? "";
        if (query.trim().length < 2) return send(200, []);
        try {
          return send(200, await speciesSearchClient.search(query, { limit: 20 }));
        } catch {
          return error(res, 502, "Species search is temporarily unavailable. Try again shortly.");
        }
      }

      if (req.method === "PATCH" && path === "/v1/profile") {
        const body = await readBody(req);
        if (!/^[a-z0-9_]{3,24}$/.test(body.username ?? "")) {
          return error(res, 422, "Username must contain 3–24 lowercase letters, numbers, or underscores.");
        }
        const displayName = String(body.displayName ?? "").trim();
        if (!displayName || [...displayName].length > 80) {
          return error(res, 422, "Display name must be between 1 and 80 characters.");
        }
        if (containsBlockedProfileLanguage(displayName)) {
          return error(res, 422, "Choose a display name that is respectful to other gardeners.");
        }
        if (store) return send(200, await store.updateProfile(accountID, body));
        account.data.profile = {
          ...account.data.profile,
          name: body.displayName,
          username: body.username,
          initials: body.displayName.split(/\s+/).slice(0, 2).map((part) => part[0]).join("").toUpperCase(),
          regionCode: body.regionCode,
          usesMetricSystem: body.usesMetricSystem,
          isPrivate: true
        };
        return send(200, account.data.profile);
      }

      if (req.method === "PATCH" && path === "/v1/journey-progress") {
        const body = await readBody(req);
        const updatedAt = new Date(body.updatedAt);
        if (!validGardenerProgress(body.gardener) || Number.isNaN(updatedAt.valueOf())) {
          return error(res, 422, "That Journey progress could not be read.");
        }
        if (store) return send(200, await store.updateGardenerProgress(accountID, body));
        const currentDate = account.data.gardenerUpdatedAt == null
          ? undefined
          : new Date(account.data.gardenerUpdatedAt);
        if (!currentDate || currentDate <= updatedAt) {
          account.data.gardener = body.gardener;
          account.data.gardenerUpdatedAt = iso(updatedAt);
        }
        return send(200, {
          gardener: account.data.gardener,
          updatedAt: account.data.gardenerUpdatedAt
        });
      }

      if (req.method === "POST" && path === "/v1/plants") {
        const body = await readBody(req);
        if (!body.clientPlantID || !body.nickname) return error(res, 422, "Plant ID and nickname are required.");
        if (store) {
          const { created, plant } = await store.createPlant(accountID, body);
          return send(created ? 201 : 200, plant);
        }
        const existing = account.data.plants.find((plant) => plant.id === body.clientPlantID);
        if (existing) return send(200, existing);
        const plant = plantFromRequest(body);
        account.data.plants.unshift(plant);
        return send(201, plant);
      }

      const updatePlantMatch = path.match(/^\/v1\/plants\/([0-9a-f-]+)$/i);
      if (req.method === "PATCH" && updatePlantMatch) {
        const body = await readBody(req);
        if (!body.plant || String(body.plant.id).toLowerCase() !== updatePlantMatch[1].toLowerCase()) {
          return error(res, 422, "The plant record does not match the requested plant.");
        }
        if (store) {
          const updated = await store.updatePlant(accountID, updatePlantMatch[1], body);
          if (!updated) return error(res, 404, "Plant not found.");
          if (updated.conflict) return error(res, 409, "The plant record does not match the requested plant.");
          return send(200, updated);
        }
        const index = account.data.plants.findIndex(
          (candidate) => String(candidate.id).toLowerCase() === updatePlantMatch[1].toLowerCase()
        );
        if (index < 0) return error(res, 404, "Plant not found.");
        account.data.plants[index] = body.plant;
        return send(200, account.data.plants[index]);
      }

      const deletePlantMatch = path.match(/^\/v1\/plants\/([0-9a-f-]+)\/delete$/i);
      if (req.method === "POST" && deletePlantMatch) {
        await readBody(req);
        if (store) {
          await store.deletePlant(accountID, deletePlantMatch[1]);
          return send(200, {});
        }
        const plantID = deletePlantMatch[1].toLowerCase();
        account.data.plants = account.data.plants.filter(
          (plant) => String(plant.id).toLowerCase() !== plantID
        );
        account.data.tasks = account.data.tasks.filter(
          (task) => String(task.plantID).toLowerCase() !== plantID
        );
        account.data.observations = account.data.observations.filter(
          (observation) => String(observation.plantID).toLowerCase() !== plantID
        );
        account.data.activity = account.data.activity.filter(
          (event) => String(event.plantID ?? "").toLowerCase() !== plantID
        );
        return send(200, {});
      }

      const checkInMatch = path.match(/^\/v1\/plants\/([0-9a-f-]+)\/check-ins$/i);
      if (req.method === "POST" && checkInMatch) {
        const body = await readBody(req);
        if (store) {
          const updated = await store.recordCheckIn(accountID, checkInMatch[1], body);
          if (!updated) return error(res, 404, "Plant not found.");
          // A sitter who was given care but not check-ins can see this plant, so
          // 404 would be a lie about why the request failed.
          if (updated.forbidden === true) {
            return error(res, 403, "This plant's owner has not enabled check-ins for you.");
          }
          return send(200, updated);
        }
        const plant = account.data.plants.find((candidate) => candidate.id === checkInMatch[1]);
        if (!plant) return error(res, 404, "Plant not found.");
        const previousScore = plant.healthScore;
        const appliesToPlant = body.appliesToPlant !== false
          && body.isEstimated !== true
          && body.assessmentAvailable !== false
          && (body.actionability == null || body.actionability === "actionable");
        if (appliesToPlant) {
          plant.healthScore = body.score;
          plant.healthBand = body.score >= 90 ? "thriving"
            : body.score >= 75 ? "healthy"
              : body.score >= 55 ? "monitor"
                : body.score >= 30 ? "attention" : "urgent";
          plant.summary = body.note;
          const change = body.score - previousScore;
          plant.trend = Math.abs(change) < 3 ? "stable" : change > 0 ? "improving" : "declining";
        }
        plant.healthIndicatorReadings = body.indicatorReadings ?? [];
        plant.nextCheckIn = iso(new Date(Date.now() + (body.followUpDays ?? (appliesToPlant ? 14 : 3)) * 86_400_000));
        return send(200, plant);
      }

      if (req.method === "POST" && path === "/v1/friendships/invitations") {
        const body = await readBody(req);
        if (store) {
          const result = await store.createFriendInvitation(accountID, body);
          if (result.unknownUser) {
            return error(res, 422, "No gardener with that username has joined Grove yet.");
          }
          if (result.self) return error(res, 422, "You cannot invite yourself.");
          if (result.invalid) return error(res, 422, "Enter a valid username to invite.");
          if (result.alreadyFriends) return error(res, 422, "You two are already connected.");
          if (result.blocked) return error(res, 422, "That invitation could not be sent.");
          if (result.reversePending) return error(res, 422, "They invited you first. Answer their request instead.");
          if (result.alreadyAnswered) return error(res, 422, "That invitation has already been answered.");
          if (result.idempotencyConflict) {
            return error(res, 409, "That request id was already used for a different invitation.");
          }
          if (result.rateLimited) return error(res, 429, "That's a lot of invitations. Try again later.");
          return send(201, result.invitation);
        }
        const invitation = {
          id: body.clientRequestID ?? randomUUID(),
          accountID: null,
          name: `@${body.username}`,
          username: body.username,
          initials: body.username.slice(0, 2).toUpperCase(),
          direction: "outgoing",
          createdAt: iso()
        };
        account.data.friendInvitations.unshift(invitation);
        return send(201, invitation);
      }

      const respondMatch = path.match(/^\/v1\/friendships\/([^/]+)\/respond$/);
      if (req.method === "POST" && respondMatch) {
        const body = await readBody(req);
        if (typeof body.accept !== "boolean") {
          return error(res, 422, "Choose whether to accept or decline this invitation.");
        }
        if (store) {
          const result = await store.respondToFriendInvitation(accountID, respondMatch[1], body);
          if (result.missing) return error(res, 404, "That invitation no longer exists.");
          if (result.notRecipient) {
            return error(res, 403, "Only the gardener who received an invitation can answer it.");
          }
          if (result.conflict) {
            return error(res, 409, "This invitation was already answered on another device.");
          }
          return send(200, {});
        }
        const index = account.data.friendInvitations.findIndex(
          (candidate) => candidate.id === respondMatch[1]
        );
        if (index < 0) return error(res, 404, "That invitation no longer exists.");
        const [invitation] = account.data.friendInvitations.splice(index, 1);
        if (invitation.direction !== "incoming") {
          account.data.friendInvitations.splice(index, 0, invitation);
          return error(res, 403, "Only the gardener who received an invitation can answer it.");
        }
        if (body.accept === true) {
          account.data.friends.push({
            id: invitation.accountID ?? `local-${invitation.username}`,
            name: invitation.name,
            username: invitation.username,
            initials: invitation.initials,
            sharedPlantCount: 0,
            lastActiveAt: iso()
          });
        }
        return send(200, {});
      }

      const removeFriendMatch = path.match(/^\/v1\/friendships\/([^/]+)\/remove$/);
      if (req.method === "POST" && removeFriendMatch) {
        if (!store) {
          return error(res, 503, "Removing a friend needs a durable Grove account.");
        }
        await store.removeFriend(accountID, removeFriendMatch[1]);
        return send(200, {});
      }

      const blockFriendMatch = path.match(/^\/v1\/friendships\/([^/]+)\/block$/);
      if (req.method === "POST" && blockFriendMatch) {
        if (store) {
          const result = await store.blockFriend(accountID, blockFriendMatch[1]);
          if (result.missing) return error(res, 404, "That account no longer exists.");
          return send(200, {});
        }
        account.data.friends = account.data.friends.filter((friend) => friend.id !== blockFriendMatch[1]);
        account.data.friendInvitations = account.data.friendInvitations.filter(
          (invitation) => invitation.accountID !== blockFriendMatch[1]
        );
        account.data.profile.friendCount = account.data.friends.length;
        return send(200, {});
      }

      const reportFriendMatch = path.match(/^\/v1\/friendships\/([^/]+)\/report$/);
      if (req.method === "POST" && reportFriendMatch) {
        const body = await readBody(req);
        const reasons = new Set(["harassment", "impersonation", "spam", "inappropriateProfile", "other"]);
        if (!reasons.has(body.reason) || typeof body.details !== "string" || [...body.details].length > 1000) {
          return error(res, 422, "Choose a valid report reason and keep details under 1,000 characters.");
        }
        if (store) {
          const result = await store.reportFriend(accountID, reportFriendMatch[1], body);
          if (result.invalid) return error(res, 422, "That report could not be submitted as written.");
          if (result.missing) return error(res, 404, "That account no longer exists.");
          return send(200, {});
        }
        account.data.friends = account.data.friends.filter((friend) => friend.id !== reportFriendMatch[1]);
        account.data.friendInvitations = account.data.friendInvitations.filter(
          (invitation) => invitation.accountID !== reportFriendMatch[1]
        );
        account.data.profile.friendCount = account.data.friends.length;
        return send(200, {});
      }

      const withdrawMatch = path.match(/^\/v1\/friendships\/([^/]+)\/withdraw$/);
      if (req.method === "POST" && withdrawMatch) {
        if (store) {
          const result = await store.withdrawFriendInvitation(accountID, withdrawMatch[1]);
          if (result.missing) return error(res, 404, "That invitation no longer exists.");
          if (result.notSender) {
            return error(res, 403, "Only the gardener who sent an invitation can take it back.");
          }
          if (result.conflict) {
            return error(res, 409, "That invitation was already answered on another device.");
          }
          return send(200, {});
        }
        const index = account.data.friendInvitations.findIndex(
          (candidate) => candidate.id === withdrawMatch[1]
        );
        if (index < 0) return error(res, 404, "That invitation no longer exists.");
        if (account.data.friendInvitations[index].direction !== "outgoing") {
          return error(res, 403, "Only the gardener who sent an invitation can take it back.");
        }
        account.data.friendInvitations.splice(index, 1);
        return send(200, {});
      }

      if (req.method === "POST" && path === "/v1/sitting-assignments") {
        const body = await readBody(req);
        if (store) {
          const created = await store.createSittingAssignment(accountID, body);
          if (created.unknownSitter) return error(res, 422, "That person does not have a Grove account yet.");
          if (created.notFriends) return error(res, 422, "Only a trusted person can receive an in-app handover.");
          if (created.invalidPlants) return error(res, 422, "Choose valid plants from your own Grove.");
          if (created.invalidDates) return error(res, 422, "Choose a valid sitting window of six months or less.");
          if (created.conflict) return error(res, 409, "That handover id was already used for different details.");
          return send(201, created);
        }
        const friend = account.data.friends.find((candidate) => candidate.id === body.sitterAccountID);
        if (!friend) return error(res, 422, "Only a trusted person can receive an in-app handover.");
        const plantIDs = [...new Set(Array.isArray(body.plantIDs) ? body.plantIDs : [])];
        if (!plantIDs.length || plantIDs.some((id) => !account.data.plants.some((plant) => plant.id === id))) {
          return error(res, 422, "Choose valid plants from your own Grove.");
        }
        const starts = new Date(body.startDate);
        const ends = new Date(body.endDate);
        if (!Number.isFinite(starts.getTime()) || !Number.isFinite(ends.getTime()) || starts >= ends) {
          return error(res, 422, "Choose a valid sitting window.");
        }
        const id = body.clientRequestID ?? randomUUID();
        const assignment = {
          id,
          sitterName: friend.name,
          sitterInitials: friend.initials,
          startDate: starts.toISOString(),
          endDate: ends.toISOString(),
          plantIDs,
          status: "invited",
          completedTasks: 0,
          totalTasks: Math.max(1, plantIDs.length * 2),
          canCheckIn: body.canCheckIn !== false,
          canLogCare: body.canLogCare !== false,
          ownerNotes: body.ownerNotes || undefined,
          timeZoneIdentifier: body.timeZoneIdentifier,
          isIncoming: false
        };
        account.data.assignments.unshift(assignment);
        if (!accounts.has(body.sitterAccountID)) accounts.set(body.sitterAccountID, emptyAccount(body.sitterAccountID));
        accounts.get(body.sitterAccountID).assignments.unshift({
          ...assignment,
          ownerName: account.data.profile.name,
          isIncoming: true
        });
        return send(201, assignment);
      }

      const sittingRespondMatch = path.match(/^\/v1\/sitting-assignments\/([0-9a-f-]+)\/respond$/i);
      if (req.method === "POST" && sittingRespondMatch) {
        const body = await readBody(req);
        if (store) {
          const updated = await store.respondToSittingAssignment(accountID, sittingRespondMatch[1], body.accept);
          if (updated.invalid) return error(res, 422, "Choose whether to accept or decline this invitation.");
          if (updated.missing) return error(res, 404, "That sitting invitation no longer exists.");
          if (updated.conflict) return error(res, 409, "That sitting invitation has already changed.");
          return send(200, updated);
        }
        const assignment = account.data.assignments.find(
          (candidate) => candidate.id === sittingRespondMatch[1] && candidate.isIncoming
        );
        if (!assignment) return error(res, 404, "That sitting invitation no longer exists.");
        assignment.status = body.accept
          ? (new Date(assignment.startDate) <= new Date() ? "active" : "upcoming")
          : "declined";
        return send(200, assignment);
      }

      const sittingRevokeMatch = path.match(/^\/v1\/sitting-assignments\/([0-9a-f-]+)\/revoke$/i);
      if (req.method === "POST" && sittingRevokeMatch) {
        if (store) {
          const updated = await store.revokeSittingAssignment(accountID, sittingRevokeMatch[1]);
          if (updated.invalid) return error(res, 422, "That handover could not be identified.");
          if (updated.missing) return error(res, 404, "That sitting handover no longer exists.");
          return send(200, updated);
        }
        const assignment = account.data.assignments.find(
          (candidate) => candidate.id === sittingRevokeMatch[1] && !candidate.isIncoming
        );
        if (!assignment) return error(res, 404, "That sitting handover no longer exists.");
        assignment.status = "revoked";
        return send(200, assignment);
      }

      const careMatch = path.match(/^\/v1\/care-actions\/([0-9a-f-]+)$/i);
      if (req.method === "PATCH" && careMatch) {
        const body = await readBody(req);
        if (store) {
          const updated = await store.updateCareAction(accountID, careMatch[1], body);
          if (!updated) return error(res, 404, "Care task not found.");
          if (updated.forbidden) return error(res, 403, "Only the plant owner can move this task to another day.");
          return send(200, updated);
        }
        const index = account.data.tasks.findIndex((task) => task.id === careMatch[1]);
        if (index < 0) return error(res, 404, "Care task not found.");
        const task = account.data.tasks[index];
        task.isCompleted = body.outcome === "completed";
        task.completedAt = task.isCompleted ? (body.occurredAt ?? iso()) : null;
        if (body.rescheduledFor) task.dueDate = body.rescheduledFor;
        return send(200, task);
      }

      if (req.method === "POST" && path === "/v1/care-actions") {
        const body = await readBody(req);
        if (!body.task?.id || !body.task?.plantID || body.task?.kind === "checkIn") {
          return error(res, 422, "The care event is invalid.");
        }
        if (store) {
          const created = await store.createCareEvent(accountID, body);
          if (!created) return error(res, 404, "Plant not found.");
          if (created.invalid) return error(res, 422, "The care event is invalid.");
          if (created.conflict) return error(res, 409, "That care event belongs to another plant.");
          return send(201, created);
        }
        const plantExists = account.data.plants.some((plant) => plant.id === body.task.plantID);
        if (!plantExists) return error(res, 404, "Plant not found.");
        const existing = account.data.tasks.find((task) => task.id === body.task.id);
        if (existing) return send(200, existing);
        account.data.tasks.push(body.task);
        return send(201, body.task);
      }

      const deleteCareMatch = path.match(/^\/v1\/care-actions\/([0-9a-f-]+)\/delete$/i);
      if (req.method === "POST" && deleteCareMatch) {
        await readBody(req);
        if (store) {
          await store.deleteCareEvent(accountID, deleteCareMatch[1]);
          return send(200, {});
        }
        account.data.tasks = account.data.tasks.filter((task) => task.id !== deleteCareMatch[1]);
        return send(200, {});
      }

      if (req.method === "POST" && path === "/v1/media/uploads") {
        const body = await readBody(req);
        if (!/^[0-9a-f-]{36}$/i.test(body.localMediaID ?? "")) return error(res, 422, "Local media id must be a UUID.");
        if (!["image/jpeg", "image/png"].includes(body.mimeType)) return error(res, 422, "Media must be JPEG or PNG.");
        if (!Number.isInteger(body.byteCount) || body.byteCount < 1 || body.byteCount > 8 * 1024 * 1024) {
          return error(res, 422, "Media byte count is outside the supported range.");
        }
        if (!/^[0-9a-f]{64}$/i.test(body.sha256 ?? "")) return error(res, 422, "Media checksum is invalid.");
        const uploadKey = `${account.id}:${body.localMediaID}`;
        const existingUploadID = uploadKeys.get(uploadKey);
        if (existingUploadID) {
          const existingUpload = uploads.get(existingUploadID);
          if (existingUpload.sha256 !== body.sha256 || existingUpload.byteCount !== body.byteCount || existingUpload.mimeType !== body.mimeType) {
            return error(res, 409, "Local media id was already used for different content.");
          }
          existingUpload.token = randomUUID();
          existingUpload.expiresAt = Date.now() + 15 * 60_000;
          return send(200, signedUploadResponse(existingUpload, origin));
        }
        const mediaAssetID = randomUUID();
        const token = randomUUID();
        const upload = {
          ...body,
          mediaAssetID,
          token,
          ownerAccountID: account.id,
          expiresAt: Date.now() + 15 * 60_000
        };
        uploads.set(mediaAssetID, upload);
        uploadKeys.set(uploadKey, mediaAssetID);
        account.data.media.set(mediaAssetID, { status: "pending", ...body });
        return send(201, signedUploadResponse(upload, origin));
      }

      const completeMediaMatch = path.match(/^\/v1\/media\/([0-9a-f-]+)\/complete$/i);
      if (req.method === "POST" && completeMediaMatch) {
        const body = await readBody(req);
        const mediaAssetID = normalizeID(completeMediaMatch[1]);
        const upload = uploads.get(mediaAssetID);
        if (!upload || upload.ownerAccountID !== account.id) return error(res, 404, "Media upload not found.");
        if (!upload.data || upload.data.length !== upload.byteCount || upload.actualSHA256 !== body.sha256 || upload.sha256 !== body.sha256) {
          return error(res, 422, "Uploaded media checksum does not match.");
        }
        account.data.media.set(mediaAssetID, { ...account.data.media.get(mediaAssetID), status: "ready" });
        return send(200, { mediaAssetID, status: "ready" });
      }

      return error(res, 404, "Route not found.");
    } catch (caught) {
      if (caught instanceof RequestBodyTooLargeError) {
        return error(res, 413, caught.message);
      }
      if (caught instanceof UnknownAccountError) {
        // Identity belongs to Supabase Auth; the service never mints an
        // account for a bearer it has not seen.
        return error(res, 401, "This account is not registered with Grove.");
      }
      return error(res, 400, caught instanceof Error ? caught.message : "Invalid request.");
    }
  });

  return {
    accounts,
    analysisJobs,
    server,
    sweepExpiredState,
    async listen() {
      await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, host, resolve);
      });
      return server.address();
    },
    async close() {
      clearInterval(maintenance);
      if (!server.listening) return;
      await new Promise((resolve, reject) => server.close((err) => err ? reject(err) : resolve()));
    }
  };
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.env.PORT ?? 8080);
  // HOST is the bind address. Defaults to 0.0.0.0 so a container / any host accepts
  // connections on all interfaces. For local device testing over Wi-Fi you can still
  // pin it (e.g. HOST="$(scutil --get LocalHostName).local"); see scripts/dev-phone.sh.
  const host = process.env.HOST ?? "0.0.0.0";
  // PUBLIC_BASE_URL is the HTTPS origin clients should use (e.g. https://<your-app>.fly.dev).
  // Set it in production so media upload URLs are absolute and reachable; without it the
  // server derives the origin from the incoming request's forwarded headers.
  const publicBaseURL = process.env.PUBLIC_BASE_URL;
  // Optional shared app secret enforced on every /v1 request (see createGroveServer).
  const appKey = process.env.GROVE_APP_KEY;
  const geminiAPIKey = loadGeminiAPIKey();
  const analysisClient = createGeminiPlantAnalysisClient({ apiKey: geminiAPIKey });
  // Optional while app data is still in memory: without SUPABASE_DB_URL the server runs
  // exactly as before, and /health reports the relational layer as not configured.
  const databaseURL = loadDatabaseURL();
  const database = databaseURL ? createGroveDatabase({ url: databaseURL }) : undefined;
  const app = createGroveServer({ port, host, publicBaseURL, appKey, analysisClient, database });
  await app.listen();
  process.stdout.write(
    `Grove API listening on ${host}:${port}` +
      `${publicBaseURL ? ` (public ${publicBaseURL})` : ""}` +
      `${database ? " — Supabase connected" : " — Supabase not configured"}\n`
  );
}
