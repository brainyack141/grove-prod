// Sending a push to an iPhone, and knowing when to stop.
//
// Token-based APNs auth, so there is no certificate to rotate and no p12 to
// keep in a secret. The provider token is a short ES256 JWT signed with the p8
// key from the Apple Developer portal; Apple accepts one for an hour and
// rate-limits *minting* them to roughly one per twenty minutes, so the cache
// below is a requirement rather than an optimisation — a function that signed a
// fresh token per request would start getting 429s under any real load.
//
// Every send is best-effort. A push that fails must never fail the mutation
// that triggered it: somebody accepting a friend request has done the thing
// they came to do, and Apple being unreachable is not their problem. Callers
// fire these through `scheduleBackground`.

const APNS_HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com"
} as const;

export type PushEnvironment = keyof typeof APNS_HOSTS;

export interface PushPayload {
  title: string;
  body: string;
  /// Routed by the client's notification delegate. Matches the local reminders'
  /// `openTab` so a pushed friend request and a tapped local one land the same
  /// way.
  openTab?: "today" | "ask" | "friends" | "profile";
  /// A deeper destination than the tab. Apps that predate this key ignore it
  /// and fall back to `openTab`, so both are sent when the screen matters.
  openRoute?: "sitting";
  plantID?: string;
  /// Drives the app icon badge. Omitted rather than zeroed: sending 0 would
  /// clear a badge that local reminders may legitimately have set.
  badge?: number;
  threadID?: string;
}

export interface DeviceRow {
  token: string;
  environment: string;
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/// Turns the PEM in `APNS_PRIVATE_KEY` into a signing key.
///
/// Secrets set through the Supabase dashboard keep their newlines, but ones set
/// through a shell often arrive with them escaped, so both spellings are
/// accepted — an unreadable key would otherwise present as "push silently does
/// nothing", which is the single hardest failure here to diagnose.
async function importSigningKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (character) => character.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
}

let cachedToken: { value: string; mintedAt: number } | undefined;

/// Apple honours a provider token for an hour. Renewing at fifty minutes stays
/// clear of both the expiry and the minting rate limit.
const TOKEN_TTL_MS = 50 * 60 * 1000;

async function providerToken(): Promise<string | undefined> {
  const keyID = Deno.env.get("APNS_KEY_ID");
  const teamID = Deno.env.get("APNS_TEAM_ID");
  const privateKey = Deno.env.get("APNS_PRIVATE_KEY");
  if (!keyID || !teamID || !privateKey) return undefined;

  const now = Date.now();
  if (cachedToken && now - cachedToken.mintedAt < TOKEN_TTL_MS) {
    return cachedToken.value;
  }

  try {
    const header = base64url(
      new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: keyID }))
    );
    const claims = base64url(
      new TextEncoder().encode(
        JSON.stringify({ iss: teamID, iat: Math.floor(now / 1000) })
      )
    );
    const signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      await importSigningKey(privateKey),
      new TextEncoder().encode(`${header}.${claims}`)
    );
    const value = `${header}.${claims}.${base64url(new Uint8Array(signature))}`;
    cachedToken = { value, mintedAt: now };
    return value;
  } catch (caught) {
    console.error("apns: could not sign provider token", caught);
    return undefined;
  }
}

/// Whether Apple's answer means this token is dead rather than this send having
/// failed. These are the two responses that mean the app is gone from the
/// device — anything else (a 429, a 503, a timeout) is worth keeping the row
/// for.
function isTokenDead(status: number, reason: string | undefined): boolean {
  if (status === 410) return true;
  return status === 400 && reason === "BadDeviceToken";
}

/// Sends one payload to every device on the list.
///
/// Returns the tokens Apple says no longer exist, for the caller to delete. The
/// prune is the caller's job because this module has no database handle, and
/// giving it one would make a push failure able to touch account data.
export async function sendPush(
  devices: DeviceRow[],
  payload: PushPayload
): Promise<string[]> {
  if (devices.length === 0) return [];
  const bundleID = Deno.env.get("APNS_BUNDLE_ID");
  const token = await providerToken();
  if (!bundleID || !token) {
    console.error("apns: not configured (needs APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID, APNS_PRIVATE_KEY)");
    return [];
  }

  const body = JSON.stringify({
    aps: {
      alert: { title: payload.title, body: payload.body },
      sound: "default",
      ...(payload.badge === undefined ? {} : { badge: payload.badge }),
      ...(payload.threadID === undefined ? {} : { "thread-id": payload.threadID })
    },
    ...(payload.openTab === undefined ? {} : { openTab: payload.openTab }),
    ...(payload.openRoute === undefined ? {} : { openRoute: payload.openRoute }),
    ...(payload.plantID === undefined ? {} : { plantID: payload.plantID })
  });

  const dead: string[] = [];
  await Promise.all(
    devices.map(async (device) => {
      const host = APNS_HOSTS[device.environment as PushEnvironment] ?? APNS_HOSTS.production;
      try {
        const response = await fetch(`${host}/3/device/${device.token}`, {
          method: "POST",
          headers: {
            authorization: `bearer ${token}`,
            "apns-topic": bundleID,
            "apns-push-type": "alert",
            // Grove has nothing worth waking a phone at 3am for. Apple may hold
            // these until the device is next in use.
            "apns-priority": "5",
            "content-type": "application/json"
          },
          body
        });
        if (response.ok) return;
        const text = await response.text();
        let reason: string | undefined;
        try {
          reason = JSON.parse(text)?.reason;
        } catch {
          reason = undefined;
        }
        if (isTokenDead(response.status, reason)) {
          dead.push(device.token);
          return;
        }
        console.error(`apns: send failed ${response.status} ${reason ?? text}`);
      } catch (caught) {
        console.error("apns: send threw", caught);
      }
    })
  );
  return dead;
}
