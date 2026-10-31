// Grove's hosted legal pages.
//
//   GET  /legal/privacy   the privacy policy
//   GET  /legal/health    unauthenticated probe
//
// App Review requires a privacy policy reachable from a plain URL, with no
// account and no app installed, so this function is public and stateless: it
// touches no database, sets no cookies, and reads nothing about whoever asked.
//
// **Why plain text and not HTML.** Supabase's edge gateway rewrites every
// response on the shared `*.supabase.co/functions/v1/` origin to
// `content-type: text/plain` with `x-content-type-options: nosniff` and a
// `default-src 'none'; sandbox` CSP — an anti-phishing measure on a domain
// anyone can deploy to. An HTML page served from here reaches the reader as a
// wall of visible tags. Plain text is therefore not a shortcut; it is the only
// thing this origin can render. Put a custom domain in front of the function
// and this can become HTML again — until then, text that reads well beats
// markup that does not render.
//
// The policy below describes what the code in this repository actually does. If
// you change where data goes — a new model provider, a new analytics sink, a
// retention change — change this page in the same commit. A policy that has
// drifted from the code is worse than no policy at all.
//
// `GROVE_LEGAL_CONTACT` overrides the published contact address without a
// redeploy, for the day the alias below changes hands:
//   supabase secrets set GROVE_LEGAL_CONTACT=someone@thinkingai.co.nz
// It must stay a monitored mailbox — access and deletion requests arrive here,
// and both the Privacy Act 2020 and the GDPR put a clock on answering them.

const textHeaders = { "content-type": "text/plain; charset=utf-8" };

// Last substantive change to the policy text below. Bump it whenever the text
// changes so returning readers can see whether anything moved.
const effectiveDate = "4 September 2026";

const contactAddress =
  (Deno.env.get("GROVE_LEGAL_CONTACT") ?? "").trim() || "privacy@thinkingai.co.nz";

// Wrapped by hand at ~76 columns. Plain text has no reflow, so the line breaks
// here are the layout — keep them if you edit the copy.
const privacyPolicy = `GROVE — PRIVACY POLICY
Effective ${effectiveDate}

Grove is a companion for looking after houseplants. This page explains, in
plain terms, what it collects and where that goes.

Grove is made by ThinkingAI Limited, a company registered in New Zealand and
based in Auckland. ThinkingAI Limited decides what Grove collects and why,
which makes it the agency responsible for your information under New
Zealand's Privacy Act 2020, and the data controller under the UK and EU
GDPR. "We" below means ThinkingAI Limited.


THE SHORT VERSION

  * Grove works offline. Before sign-in, your setup answers stay on your
    iPhone. Grove sends privacy-minimised setup diagnostics. If you choose to
    scan a first plant, Grove creates a random guest security identifier and
    sends only that chosen photo for identification.
  * We do not sell your data, and we do not use it for advertising.
  * There are no third-party advertising or tracking SDKs in the app.
  * Your plant photos are used to answer your question about that plant,
    and are not used to train anyone's models.


WHAT GROVE STORES ON YOUR DEVICE

Plant photos, nicknames, rooms, check-ins, care history, reminders, and the
answers you gave during setup are written to your iPhone's app storage,
protected by iOS file encryption. Deleting the app removes that app storage;
on a later reinstall Grove clears any orphaned sign-in credential that iOS
Keychain retained, including a credential used to secure a first scan.


WHAT GROVE SENDS TO ITS OWN SERVERS

If you sign in with Apple, Google, or an email code, Grove creates an account
so your grove can sync between your devices and survive a lost phone. That
account holds your display name, username, region and unit preference,
an optional location label you choose, your trusted-person connections and
invitations, the plant records above, and Journey progress such as your streak,
XP, badges, rewards and daily quests. It is stored in a Supabase-hosted
PostgreSQL database and object store in the EU (Ireland).

If you enable notifications, Grove stores the device token Apple gives this
installation, the production or sandbox environment it belongs to, whether
you want plant-sitting updates, and when the token was last seen. If you report
an account, Grove stores who reported whom, the reason and optional details,
the related connection, review status, and the time of the report. Reporting
also blocks that account.

If you choose "This iPhone only", no account is created and nothing in this
paragraph applies.

Before account creation—and later if a device-only Grove chooses another
server-backed scan—a plant scan uses a random anonymous Supabase Auth
identifier. This lets Grove verify the request, keep one person's scan private
from another, resume the same scan safely, and enforce a strict usage limit
without trusting an identifier supplied by the app. The identifier is not an
account and receives no Grove, profile, plants, email address, or name. Grove
stores only its security purpose, small job-status records, and usage counters;
the scan photo is passed through in memory and is not stored on Grove's server.

When you are signed in and ask Ari, Grove's botanist, a question, Grove keeps a
privacy-minimised advice record under your account. Anonymous first-scan and
device-only identifiers cannot use Ari. The record contains the answer, its
confidence and bounded evidence labels, the answering provider and model,
source ids, review status, follow-up date, and any "helpful" or
plant-improvement result you choose to send. For a photo question it may also
retain a bounded text description of the visible evidence so an interrupted
response can be replayed safely; it never contains the photo itself. Grove does
not store the raw Ask conversation or the plant-context summary in that server
record. Results are used to make later advice about the same plant more useful
and to measure whether Ari is helping.


WHAT GROVE SENDS TO OTHER COMPANIES

  Google (Gemini API)
    Sent for Scan and check-ins: up to four plant photos you chose, which may
    include today's whole-plant and symptom/detail views and one earlier photo
    for comparison; the scan purpose, broad region, bounded observation
    answers, and the plant identity, room and recent summary when you scan a
    plant already in your grove.
    Sent for Ask: your question and recent Ask messages, plus the plant-record
    and reviewed-reference summaries needed to answer it. If you attach or
    reuse photos in that conversation, up to two chosen plant photos are also
    sent. For complex advice, a second bounded Gemini request receives the same
    text context, visual findings and proposed answer for a safety review.
    Why: to inspect chosen photos, identify or assess the plant, compare a
    check-in when an earlier photo exists, write Ari's text or photo-aware
    answer, and review complex advice before Grove shows it. Photos are passed
    through — Grove's server does not keep a copy.

  GBIF
    Sent: a species name you search for.
    Why: to look up scientific names. No personal data is attached.

  Open-Meteo
    Sent: the coordinates of the location you pinned for your grove.
    Why: to show local daylight and weather. Requested by your iPhone
    directly, without an account or identifier.

  Apple / Google sign-in
    Sent: what their sign-in screens send when you choose to use them.
    Why: to verify who you are.

  Apple Push Notification service (APNs)
    Sent: the device token Apple issued for Grove and the notification payload.
    A trusted-person notification can contain a gardener's display name and
    the fact that they sent or accepted a connection request. Plant-sitting
    notifications can contain a sitter or plant name and the relevant event.
    Why: to deliver the notifications you enabled to this iPhone.

These companies receive only what is listed beside them, for the purpose
described and under their own terms. Grove does not send them the rest of your
grove.


WHERE YOUR DATA IS HELD, AND WHERE IT TRAVELS

Your account and your grove are stored in the EU (Ireland). ThinkingAI
Limited runs Grove from New Zealand, which the European Commission has
formally recognised as providing an adequate level of data protection, so
that access needs no further safeguard.

The processors above receive only what is listed beside their name, and they
receive it wherever they operate. Google processes the photos you scan and the
questions you ask Ari on its global infrastructure. If you would rather
nothing of yours were processed there, do not use Scan or Ask — every other
part of Grove works without them.


LOCATION

Location is optional and off until you pin a spot for your grove. It is used
for daylight and weather only. You can remove it at any time in My Grove, and
iOS's own location permission can be withdrawn in Settings.


PHOTOS AND THE CAMERA

Grove asks for the camera to scan plants, and for the photo library only when
you pick an image. It does not read your library in the background, and it
does not upload photos you have not chosen to scan.


TRUSTED PEOPLE AND PLANT-SITTING

If you invite another gardener or accept their invitation, each of you can see
the other's display name and username. Connecting does not reveal either
grove. Plant access exists only when an owner creates a separate plant-sitting
link for specific plants, dates and permissions. Anyone holding that bearer
link can use it until it expires or is revoked — no account required, which is
the point of it. A link created for a connected account is also revoked if the
owner blocks or reports that account.

You can remove or block a connected account. A blocked account cannot start a
new connection with you. Reports are sent to ThinkingAI Limited for safety
review and include the reason and any details you chose to write.


DIAGNOSTICS

Grove records which setup screens were reached and how long they took, so the
first-run experience can be improved. These events carry a random identifier
for the install, not your name or email, and they are stored alongside the
rest of Grove's data in the EU. They are not shared with anyone.


CHILDREN

Grove is not directed at children under 13, and we do not knowingly collect
data from them. If you believe a child has given us information, write to
the address at the end of this page and we will delete it.


HOW GROVE IS PROTECTED

Everything Grove sends travels over TLS. The database and the photo store
encrypt what they hold at rest, and row-level rules inside the database mean
a signed-in account can read its own grove and whatever has deliberately
been shared with it, and nothing else. Access to production is limited to
the people at ThinkingAI Limited who need it.

No system is perfect. If a breach ever puts you at risk of serious harm, we
will tell you and notify the Office of the Privacy Commissioner, as the
Privacy Act 2020 requires, and the relevant supervisory authority where the
GDPR applies.


HOW LONG WE KEEP THINGS

Account data, including safety reports, is kept until you ask us to delete it.
Device tokens are removed when you sign out, delete the account, or Apple says
the token is no longer valid. Diagnostic events are deleted after 12 months.
Completed scan-job status is normally deleted after
one hour and every scan job after one day. Scan usage counters are deleted
after 60 days. An anonymous scan identity is scheduled for deletion once it is
30 days old, together with its guest usage record. Deleting the app removes its
app storage; Grove also clears any orphaned Keychain credential if the app is
installed and opened again.


YOUR RIGHTS

Wherever you live, you can ask for a copy of the information Grove holds
about you, ask us to correct it, or ask us to delete it. You do not have to
write to us for the last one: Settings › Delete account removes the account
and everything in it, and the app can export your grove to a file on your
iPhone at any time.

  New Zealand. Principles 6 and 7 of the Privacy Act 2020 give you the
  right to see your information and to have it corrected. We answer within
  20 working days. If you are not satisfied with how we handled a request,
  you can complain to the Office of the Privacy Commissioner — privacy.org.nz.

  UK and EU. You also have rights to erasure, portability, restriction, and
  objection, and we answer within one month. The legal bases we rely on are
  performance of a contract (running the account you asked for), consent
  (location, camera, and photo library — each withdrawable in iOS Settings),
  and legitimate interests (keeping the service working, keeping it secure,
  and improving first-run setup). You can complain to your national
  supervisory authority, or to the Information Commissioner's Office in the
  UK.

We do not sell personal information, and we do not share it for advertising
or profiling of any kind.


CHANGES

If this policy changes materially, the date at the top changes and the app
will point at the updated page. Grove does not quietly widen what it
collects.


CONTACT

  ThinkingAI Limited
  Auckland, New Zealand
  ${contactAddress}

Write to us about anything on this page. We answer every message from a
person about their own data.

This policy is governed by New Zealand law, and nothing in it takes away a
right you have under the law where you live.


— Grove. This page sets no cookies and loads no advertising or tracking code.
`;

Deno.serve((request) => {
  const url = new URL(request.url);
  const segments = url.pathname.split("/").filter(Boolean);
  const route = segments.slice(segments.lastIndexOf("legal") + 1);

  if (request.method === "GET" && route[0] === "health") {
    return new Response(JSON.stringify({ status: "ok", service: "grove-legal" }), {
      status: 200,
      headers: { "content-type": "application/json; charset=utf-8" }
    });
  }

  if (request.method === "GET" && (route[0] === "privacy" || route.length === 0)) {
    return new Response(privacyPolicy, { status: 200, headers: textHeaders });
  }

  return new Response("Not found. There is nothing at this address.\n", {
    status: 404,
    headers: textHeaders
  });
});
