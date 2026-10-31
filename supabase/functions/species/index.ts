// Grove species-name search on Supabase Edge Functions.
//
//   GET /species/search?q=<query>   → ranked GBIF-backed candidates (200)
//
// Mirrors the dev server's /v1/species/search route, using the same shared
// GBIF client module.

import { createGBIFSpeciesSearchClient } from "../_shared/gbif-species-search.mjs";
import { createClient } from "npm:@supabase/supabase-js@2";

const jsonHeaders = { "content-type": "application/json; charset=utf-8" };
const speciesSearchClient = createGBIFSpeciesSearchClient();
const database = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } }
);
const verifiedTokens = new Map<string, number>();
const verifiedTokenLifetime = 5 * 60_000;
const verifiedTokenLimit = 500;

function tokenExpiryMilliseconds(token: string): number {
  try {
    const payload = token.split(".")[1];
    if (!payload) return Number.POSITIVE_INFINITY;
    const normalized = payload.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
    const claims = JSON.parse(atob(padded));
    return typeof claims?.exp === "number" ? claims.exp * 1_000 : Number.POSITIVE_INFINITY;
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

async function hasVerifiedIdentity(request: Request): Promise<boolean> {
  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return false;
  const token = authorization.slice("Bearer ".length).trim();
  const tokenParts = token.split(".");
  // Supabase access credentials are JWTs. Reject obvious garbage locally so
  // an unauthenticated caller cannot turn this proxy into a flood of GoTrue
  // verification requests; structural validation is only a cheap prefilter,
  // and `getUser` remains the authority below.
  if (tokenParts.length !== 3 || tokenParts.some((part) => !part)) return false;
  const cachedUntil = verifiedTokens.get(token);
  if (cachedUntil && cachedUntil > Date.now()) return true;
  verifiedTokens.delete(token);
  const { data, error } = await database.auth.getUser(token);
  if (error || !data.user) return false;
  if (verifiedTokens.size >= verifiedTokenLimit) {
    const oldest = verifiedTokens.keys().next();
    if (!oldest.done) verifiedTokens.delete(oldest.value);
  }
  const expiresAt = Math.min(Date.now() + verifiedTokenLifetime, tokenExpiryMilliseconds(token));
  if (expiresAt > Date.now()) verifiedTokens.set(token, expiresAt);
  return true;
}

Deno.serve(async (request) => {
  const url = new URL(request.url);
  const segments = url.pathname.split("/").filter(Boolean);
  const route = segments.slice(segments.lastIndexOf("species") + 1);

  const appKey = Deno.env.get("GROVE_APP_KEY");
  if (appKey && request.headers.get("x-grove-app-key") !== appKey) {
    return new Response(JSON.stringify({ message: "App identification is missing or invalid." }), {
      status: 401,
      headers: jsonHeaders
    });
  }
  // The app key ships in every binary and is only a caller hint. Verify the
  // Supabase JWT before allowing this function to proxy requests to GBIF;
  // accepting any string after "Bearer" made the catalogue publicly abusable.
  if (!(await hasVerifiedIdentity(request))) {
    return new Response(JSON.stringify({ message: "A bearer token is required." }), {
      status: 401,
      headers: jsonHeaders
    });
  }

  if (request.method !== "GET" || route[0] !== "search") {
    return new Response(JSON.stringify({ message: "Route not found." }), { status: 404, headers: jsonHeaders });
  }

  const query = (url.searchParams.get("q") ?? "").trim();
  if (query.length < 2) {
    return new Response(JSON.stringify([]), { status: 200, headers: jsonHeaders });
  }
  if (query.length > 160) {
    return new Response(JSON.stringify({ message: "Species search must be 160 characters or fewer." }), {
      status: 422,
      headers: jsonHeaders
    });
  }
  try {
    const candidates = await speciesSearchClient.search(query, { limit: 20 });
    return new Response(JSON.stringify(candidates), { status: 200, headers: jsonHeaders });
  } catch {
    return new Response(
      JSON.stringify({ message: "Species search is temporarily unavailable. Try again shortly." }),
      { status: 502, headers: jsonHeaders }
    );
  }
});
