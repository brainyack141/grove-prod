import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migrationURL = new URL(
  "../../supabase/migrations/20260803000099_social_integrity.sql",
  import.meta.url
);
const apiURL = new URL("../../supabase/functions/api/index.ts", import.meta.url);
const apnsURL = new URL("../../supabase/functions/_shared/apns.ts", import.meta.url);
const devServerURL = new URL("../server.mjs", import.meta.url);
const sittingPageURL = new URL("../../supabase/functions/sit/index.ts", import.meta.url);
const sittingComposerURL = new URL("../../Grove/SittingLinkView.swift", import.meta.url);
const friendsViewURL = new URL("../../Grove/FriendsView.swift", import.meta.url);
const rootViewURL = new URL("../../Grove/RootView.swift", import.meta.url);
const syncEngineURL = new URL("../../Grove/SyncEngine.swift", import.meta.url);
const serviceFactoryURL = new URL("../../Grove/GroveServiceFactory.swift", import.meta.url);
const groveStoreURL = new URL("../../Grove/GroveStore.swift", import.meta.url);
const sittingStateMigrationURL = new URL(
  "../../supabase/migrations/20260830000004_sitting_link_state.sql",
  import.meta.url
);
const friendSafetyMigrationURL = new URL(
  "../../supabase/migrations/20260830000005_friend_safety.sql",
  import.meta.url
);
const associatedDomainsURL = new URL("../../web/.well-known/apple-app-site-association", import.meta.url);

test("social RLS cannot bypass the API state machines", async () => {
  const sql = await readFile(migrationURL, "utf8");
  assert.match(sql, /friendships_unordered_pair_idx/i);
  assert.match(sql, /add column if not exists request_hash text/i);
  assert.match(sql, /add column if not exists claim_id uuid/i);
  assert.match(sql, /alter table app\.idempotency_keys[\s\S]*request_hash text[\s\S]*claim_id uuid/i);
  assert.match(sql, /create table if not exists app\.friend_invitation_attempts/i);
  assert.match(sql, /primary key \(requested_by_account_id, request_id\)/i);
  assert.match(sql, /ranked_live_links[\s\S]*ranked\.position > 100/i);
  assert.match(sql, /least\(requested_by_account_id, requested_to_account_id\)/i);
  assert.match(sql, /drop policy if exists friendships_requester_insert/i);
  assert.match(sql, /drop policy if exists friendships_participant_update/i);
  assert.match(sql, /drop policy if exists assignments_participant_update/i);
  assert.match(sql, /drop policy if exists assignment_plants_owner_write/i);
  assert.match(sql, /drop policy if exists accounts_connected_read/i);
  assert.doesNotMatch(sql, /create policy accounts_connected_read/i);
  assert.match(sql, /create policy assignments_participant_read[\s\S]*revoked_at is null[\s\S]*now\(\) < ends_at/i);
  assert.match(sql, /create policy assignment_plants_participant_read[\s\S]*revoked_at is null[\s\S]*now\(\) < assignment\.ends_at/i);
  assert.match(sql, /A row policy grants[\s\S]*region\/location[\s\S]*checked API/i);
  assert.match(sql, /drop policy if exists sitting_invite_plants_owner_all/i);
  assert.match(sql, /drop policy if exists observations_scoped_insert/i);
  assert.match(sql, /drop policy if exists observation_media_scoped_access/i);
  assert.match(sql, /drop policy if exists health_assessments_scoped_access/i);
  assert.match(sql, /drop policy if exists care_actions_scoped_access/i);
  assert.match(sql, /drop policy if exists activity_actor_insert/i);
  assert.match(sql, /create policy care_actions_scoped_read/i);
  assert.match(sql, /enforce_assignment_plant_scope/i);
  assert.match(sql, /enforce_invite_plant_scope/i);
});

test("friend requests serialize unordered pairs and preserve explicit-access copy", async () => {
  const source = await readFile(apiURL, "utf8");
  const devServer = await readFile(devServerURL, "utf8");
  assert.match(source, /pg_advisory_xact_lock\(hashtextextended\(/i);
  assert.match(source, /They invited you first\. Answer their request instead\./i);
  assert.match(source, /const friendships = await tx`[\s\S]*status in \('accepted', 'pending'\)/i);
  assert.match(source, /wants to connect on Grove/i);
  assert.match(source, /status = 'pending'::app\.friendship_status[\s\S]*requested_by_account_id = \$\{me\}/i);
  assert.match(source, /explicit plant-sitting link/i);
  assert.match(source, /Plant access still happens only through an explicit sitting link\./i);
  assert.match(source, /60 \* 60 \* 1000/);
  assert.match(source, /friend-invite-rate:\$\{me\}/i);
  assert.match(source, /from app\.friend_invitation_attempts[\s\S]*Number\(recentCount\) >= 30/i);
  assert.doesNotMatch(source, /from app\.friendships[\s\S]{0,180}created_at >= now\(\) - interval '24 hours'/i);
  assert.match(source, /where id = \$\{invitationID\} and status = 'pending'/i);
  assert.match(source, /!row\.request_hash \|\| row\.request_hash !== requestHash/i);
  assert.match(source, /status = 102[\s\S]*claim_id = \$\{claimID\}/i);
  assert.match(source, /operation: \(\) => Promise<Response>/i);
  assert.match(source, /claimIdempotency[\s\S]*status, body, request_hash, claim_id/i);
  assert.match(source, /claim\.claimID[\s\S]*await operation\(\)/i);
  assert.match(devServer, /claimIdempotentResponse[\s\S]*requestHash[\s\S]*candidateClaimID/i);
  assert.match(devServer, /existing\.requestHash !== requestHash/i);
  assert.match(devServer, /res\.once\("finish"[\s\S]*abandonClaim/i);
  assert.match(source, /offset 1000/i);
  assert.match(source, /async function boundedRequestText/i);
  assert.match(source, /byteCount > maximumBytes/i);
  assert.match(source, /Request body must be a JSON object/i);
  assert.match(source, /async function removeFriend/i);
  assert.match(source, /update app\.friendships[\s\S]*status = 'declined'::app\.friendship_status[\s\S]*where status in \('accepted', 'pending'\)/i);
  assert.match(source, /requested_by_account_id = \$\{friendID\}[\s\S]*requested_to_account_id = \$\{me\}/i);
  assert.match(source, /status = 'revoked'::app\.assignment_status/i);
});

test("friend safety reports are server-mediated, bounded, and atomically block access", async () => {
  const [source, migration, composer] = await Promise.all([
    readFile(apiURL, "utf8"),
    readFile(friendSafetyMigrationURL, "utf8"),
    readFile(sittingComposerURL, "utf8")
  ]);
  assert.match(migration, /create table if not exists app\.friend_reports/i);
  assert.match(migration, /unique \(reporter_account_id, client_request_id\)/i);
  assert.match(migration, /revoke all on table app\.friend_reports from public, anon, authenticated/i);
  assert.match(migration, /recipient_account_id uuid references app\.accounts/i);
  assert.match(source, /async function blockFriend/i);
  assert.match(source, /async function reportFriend/i);
  assert.match(source, /status = 'blocked'::app\.friendship_status/i);
  assert.match(source, /insert into app\.friend_reports/i);
  assert.match(source, /recipient_account_id = \$\{friendID\}[\s\S]*revoked_at is null/i);
  assert.match(source, /containsBlockedProfileLanguage\(displayName\)/i);
  assert.match(composer, /recipientAccountID: nil/i);
  assert.match(composer, /sitterAccountID: friend\.id/i);
});

test("shared friend invitations have an actionable web fallback for device builds", async () => {
  const [friends, association, fallback, router] = await Promise.all([
    readFile(friendsViewURL, "utf8"),
    readFile(associatedDomainsURL, "utf8"),
    readFile(new URL("../../web/friends.js", import.meta.url), "utf8"),
    readFile(new URL("../../Grove/IntentRouter.swift", import.meta.url), "utf8")
  ]);
  assert.match(friends, /https:\/\/www\.downloadgrove\.com\/friends/i);
  assert.match(friends, /ShareLink\([\s\S]*item: inviteURL/i);
  const parsed = JSON.parse(association);
  assert.deepEqual(parsed.applinks.details[0].appIDs, ["Q5688GHWHJ.nz.co.thinkingai.Grove"]);
  assert.match(fallback, /nz\.co\.thinkingai\.grove:\/\/friends/i);
  assert.match(fallback, /searchParams\.set\("username", rawUsername\)/);
  assert.match(router, /requestedRoute = \.inviteFriend\(username\)/);
});

test("account handovers are friend-only, bounded, scoped and replay-consistent", async () => {
  const [source, devStore, apns] = await Promise.all([
    readFile(apiURL, "utf8"),
    readFile(new URL("../grove-store.mjs", import.meta.url), "utf8"),
    readFile(apnsURL, "utf8")
  ]);
  assert.match(source, /Only a trusted person can receive an in-app handover\./i);
  assert.match(source, /status = 'accepted'[\s\S]*requested_by_account_id/i);
  assert.match(source, /A sitting assignment can cover at most six months\./i);
  assert.match(source, /Only plants from your own Grove can be included\./i);
  assert.match(source, /sameRequest[\s\S]*existing\.sitter_account_id[\s\S]*existingPlantIDs/i);
  assert.match(source, /sitting-assignment:\$\{assignmentID\}/i);
  assert.match(source, /insert into app\.activity_events[\s\S]*activityEventID/i);
  assert.match(devStore, /sitting-assignment:\$\{assignmentID\}/i);
  assert.match(devStore, /const sameRequest = existing\.sitter_account_id/i);
  // The sitter's push names the invitation screen as well as the Friends tab.
  // The tab stays on the payload so a build that predates `openRoute` still
  // lands somewhere useful.
  assert.match(
    source,
    /asked you to sit their plants[\s\S]{0,600}openTab: "friends",[\s\S]{0,40}openRoute: "sitting"/i
  );
  assert.match(apns, /openRoute\?: "sitting"/i);
  assert.match(apns, /openRoute === undefined \? \{\} : \{ openRoute: payload\.openRoute \}/i);
});

test("public sitting links enforce both dates and attribute external care", async () => {
  const api = await readFile(apiURL, "utf8");
  const source = await readFile(sittingPageURL, "utf8");
  assert.match(api, /const tokenHash = await sha256Hex\(token\)/i);
  assert.match(api, /typeof value === "string" \? new TextEncoder\(\)\.encode\(value\) : value/i);
  assert.match(source, /const hasStarted = Date\.now\(\) >= new Date\(invite\.starts_at\)\.getTime\(\)/i);
  assert.match(source, /if \(!hasStarted\)[\s\S]*upcomingPage\(invite\)/i);
  assert.match(source, /Nothing about their plants is shown before then\./i);
  assert.match(source, /now > new Date\(invite\.ends_at\)\.getTime\(\)/i);
  assert.doesNotMatch(source, /graceMilliseconds/);
  assert.match(source, /actor_name, actor_initials/i);
  assert.match(source, /A bearer proves possession of the URL, not the opener's identity/i);
  assert.match(source, /\$\{"A plant sitter"\}[\s\S]*\$\{"PS"\}/i);
  assert.match(source, /cache-control": "no-store/i);
  assert.match(source, /frame-ancestors 'none'/i);
  assert.match(source, /headers: \{ \.\.\.htmlHeaders, location: url\.pathname \}/i);
  assert.match(source, /uuidPattern\.test\(careActionID\)/i);
  assert.match(source, /action\.kind not in \('checkIn', 'check_in'\)/i);
  assert.match(source, /coalesce\(action\.due_from, now\(\)\) <= now\(\)/i);
  assert.match(source, /coalesce\(action\.due_from, now\(\)\) <= \$\{invite\.ends_at\}/i);
  assert.match(source, /canLogCare && !isGuidedCheckIn/i);
  assert.match(source, /canLogCare && !isGuidedCheckIn && isDue/i);
  assert.match(api, /sittingInvites: \(snapshot\.sittingInvites as Row\[\]\)\.map\(clientSittingInvite\)/i);
  assert.match(api, /shareURL: null[\s\S]*wasMinted: true/i);
  assert.match(api, /sitting-invite-rate:\$\{me\}[\s\S]*Number\(outstandingCount\) >= 100/i);
  assert.match(api, /created_at >= now\(\) - interval '24 hours'[\s\S]*Number\(recentCount\) >= 100/i);
  assert.match(api, /lastOpenedAt:[\s\S]*openCount:/i);
  assert.match(source, /time_zone_identifier/i);
  assert.match(source, /aria-label="Mark \$\{title\} for \$\{escapeHTML\(plantNickname\)\} done"/i);
  assert.match(source, /notifyOwner\(invite\.owner_account_id/i);
  assert.match(source, /sitting_updates_enabled = true/i);
});

test("sitting care plans, final-plant deletion, and timezone state share durable contracts", async () => {
  const api = await readFile(apiURL, "utf8");
  const migration = await readFile(sittingStateMigrationURL, "utf8");
  assert.match(api, /async function syncCarePlanActions/i);
  assert.match(api, /insert into app\.care_actions \([\s\S]*id, plant_id, kind, instructions/i);
  assert.match(api, /syncCarePlanActions\(tx, plantID, null, client\.carePlan\)/i);
  assert.match(api, /jsonbValue\(existing\.presentation\)\.carePlan[\s\S]*client\.carePlan/i);
  assert.match(api, /update app\.sitting_invites invite[\s\S]*not exists \([\s\S]*from app\.sitting_invite_plants scope/i);
  assert.match(api, /const isSittingTask = row\.is_sitting_task === true \|\| row\.completed_via_sitting_link === true/i);
  assert.match(migration, /app\.sitting_invites[\s\S]*time_zone_identifier/i);
  assert.match(migration, /app\.sitting_assignments[\s\S]*time_zone_identifier/i);
});

test("the visible friend handover uses the account-bound acceptance lifecycle", async () => {
  const source = await readFile(sittingComposerURL, "utf8");
  const api = await readFile(apiURL, "utf8");
  const localStore = await readFile(groveStoreURL, "utf8");
  assert.match(source, /account-bound invitation[\s\S]*case friend/i);
  assert.match(source, /case \.link: createLink\(\)[\s\S]*case \.friend: createAssignment\(\)/i);
  assert.match(source, /syncEngine\.createSittingAssignment\(request\)/i);
  assert.match(source, /They must accept before the selected plants and tasks appear\./i);
  assert.match(api, /finish\(\(\) => createSittingAssignment\(me, body\)\)/i);
  assert.match(api, /async function respondToSittingAssignment/i);
  assert.match(api, /async function revokeSittingAssignment/i);
  assert.doesNotMatch(localStore, /sharedPlantCount: [1-9]/i);
  assert.match(localStore, /friendCount: 3\)/i);
});

test("friend state reconciles from other devices on foreground and manual refresh", async () => {
  const root = await readFile(rootViewURL, "utf8");
  const friends = await readFile(friendsViewURL, "utf8");
  assert.match(
    root,
    /onChange\(of: scenePhase\)[\s\S]*syncEngine\.synchronize\(store: store, isConnected: connectivity\.isConnected\)/i
  );
  assert.match(
    root,
    /onChange\(of: connectivity\.isConnected\)[\s\S]*syncEngine\.synchronize\(store: store, isConnected: true\)/i
  );
  assert.match(
    friends,
    /refreshable[\s\S]*syncEngine\.synchronize\(store: store, isConnected: connectivity\.isConnected\)/i
  );
  assert.match(
    friends,
    /struct FriendInvitationsView[\s\S]*GroveOutlineButton\(title: "Cancel"[\s\S]*withdrawFriendInvitation/i
  );
  const durableOfflineResponses = friends.match(
    /guard connectivity\.isConnected else \{[\s\S]{0,1200}guard await syncEngine\.enqueue\(\.respondToFriendInvitation\(request\), isConnected: false\)[\s\S]{0,1200}commitResponseLocally/g
  ) ?? [];
  const durableOfflineWithdrawals = friends.match(
    /guard connectivity\.isConnected else \{[\s\S]{0,1200}guard await syncEngine\.enqueue\(\.withdrawFriendInvitation\(request\), isConnected: false\)[\s\S]{0,1200}commitWithdrawalLocally/g
  ) ?? [];
  assert.equal(durableOfflineResponses.length, 2, "both invitation screens persist an offline answer before rendering it");
  assert.equal(durableOfflineWithdrawals.length, 2, "both invitation screens persist an offline cancellation before rendering it");
});

test("sync requests and snapshots remain scoped across account switches", async () => {
  const sync = await readFile(syncEngineURL, "utf8");
  const factory = await readFile(serviceFactoryURL, "utf8");
  assert.match(sync, /GroveAPIRequestScope\.\$expectedAccountID\.withValue\(expectedAccountID\)/i);
  assert.match(sync, /generation == accountGeneration[\s\S]*store\.activeAccountID == expectedAccountID/i);
  assert.match(sync, /from scopedQueueStore/i);
  assert.match(sync, /if isSynchronizing[\s\S]*needsAnotherSynchronization = true/i);
  assert.match(sync, /guard revision == serverStateRevision[\s\S]*needsAnotherSynchronization = true/i);
  assert.match(sync, /Do not hand that success to A's old view[\s\S]*throw CancellationError\(\)/i);
  assert.match(factory, /expected == nil \|\| session\.currentSession\?\.accountID == expected/i);
});
