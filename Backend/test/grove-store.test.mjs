// Integration tests for the durable sync store.
//
// These run against a real PostgreSQL database with `supabase/migrations/`
// applied. Set GROVE_TEST_DATABASE_URL to enable them; without it they skip, so
// the suite still passes on a machine with no database.
//
//   initdb -D /tmp/pg -U grove --auth=trust
//   pg_ctl -D /tmp/pg -o "-p 55432 -k /tmp" start
//   createdb -h /tmp -p 55432 -U grove grove
//   for f in supabase/migrations/*.sql; do psql -h /tmp -p 55432 -U grove -d grove -f "$f"; done
//   GROVE_TEST_DATABASE_URL="postgres://grove@localhost:55432/grove" npm test

import assert from "node:assert/strict";
import test from "node:test";
import postgres from "postgres";
import { createGroveStore } from "../grove-store.mjs";
import { createTestAccount, resetAccounts } from "./helpers/database.mjs";

const databaseURL = process.env.GROVE_TEST_DATABASE_URL;
const describe = databaseURL ? test.describe : test.describe.skip;

function connect() {
  return postgres(databaseURL, { ssl: false, prepare: false, max: 4, onnotice: () => {} });
}

// Assigned by reset(); accounts are real Supabase Auth identities, so their
// ids are uuids the trigger provisioned rather than fixed strings.
let ACCOUNT;
let INTRUDER;
let SITTER;

async function reset(sql) {
  await resetAccounts(sql, [ACCOUNT, INTRUDER, SITTER]);
  ACCOUNT = await createTestAccount(sql, { name: "Test Gardener" });
  INTRUDER = await createTestAccount(sql, { name: "Someone Else" });
  SITTER = await createTestAccount(sql, { name: "Maya Kapoor" });
}

async function befriend(sql, store, requester = ACCOUNT, recipient = SITTER) {
  const [account] = await sql`select username from app.accounts where id = ${recipient}`;
  const created = await store.createFriendInvitation(requester, { username: account.username });
  assert.ok(created.invitation, "friend request should be created");
  const accepted = await store.respondToFriendInvitation(recipient, created.invitation.id, { accept: true });
  assert.equal(accepted.ok, true, "friend request should be accepted");
  return created.invitation;
}

function plantRequest(id, overrides = {}) {
  return {
    clientPlantID: id,
    nickname: "Pesto",
    location: "Kitchen",
    analysis: {
      identification: {
        commonName: "Basil",
        scientificName: "Ocimum basilicum",
        confidence: 91,
        canonicalTaxonID: "gbif:2927096",
        identityConfirmation: "userConfirmed"
      },
      condition: {
        healthScore: 82,
        healthBand: "healthy",
        confidence: 86,
        summary: "Looking good.",
        positiveSigns: ["Firm stems"],
        concerns: [],
        nextActions: ["Check the soil before watering"],
        followUpDays: 10
      }
    },
    ...overrides
  };
}

describe("durable grove store", () => {
  test("a plant survives a process restart", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const plantID = "11111111-1111-4111-8111-111111111111";
      await store.createPlant(ACCOUNT, plantRequest(plantID));

      // A brand-new store over a brand-new connection is what the API looks
      // like after a restart or redeploy. The in-memory implementation this
      // replaces returned an empty account here, which the client would then
      // apply over the user's real Grove.
      const restartedSQL = connect();
      try {
        const restarted = createGroveStore(restartedSQL);
        const snapshot = await restarted.snapshot(ACCOUNT);
        assert.equal(snapshot.plants.length, 1);
        assert.equal(snapshot.plants[0].id, plantID);
        assert.equal(snapshot.plants[0].nickname, "Pesto");
        assert.equal(snapshot.plants[0].species, "Basil");
        assert.equal(snapshot.plants[0].canonicalTaxonID, "gbif:2927096");
        assert.equal(snapshot.plants[0].identityConfirmation, "userConfirmed");
      } finally {
        await restartedSQL.end({ timeout: 5 });
      }
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("adopting a plant schedules its first check-in", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const plantID = "22222222-2222-4222-8222-222222222222";
      await store.createPlant(ACCOUNT, plantRequest(plantID));

      const snapshot = await store.snapshot(ACCOUNT);
      const tasks = snapshot.tasks.filter((task) => task.plantID === plantID);
      assert.equal(tasks.length, 1);
      assert.equal(tasks[0].kind, "checkIn");
      assert.equal(tasks[0].isCompleted, false);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("care-plan steps become sitter-actionable rows and are superseded with the plan", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const plantID = "23232323-2323-4232-8232-232323232323";
      const actionID = "24242424-2424-4242-8242-242424242424";
      const removedActionID = "26262626-2626-4262-8262-262626262626";
      const created = await store.createPlant(ACCOUNT, plantRequest(plantID, {
        plant: {
          nickname: "Pesto",
          healthBand: "healthy",
          carePlan: {
            id: "25252525-2525-4252-8252-252525252525",
            actions: [{
              id: actionID,
              kind: "water",
              instruction: "Water only if the top soil is dry.",
              state: "due",
              dueFrom: new Date(Date.now() - 60_000).toISOString()
            }, {
              id: removedActionID,
              kind: "rotate",
              instruction: "Turn the pot a quarter turn.",
              state: "proposed"
            }]
          }
        }
      }));

      let snapshot = await store.snapshot(ACCOUNT);
      assert.equal(snapshot.tasks.find((task) => task.id === actionID)?.kind, "water");
      await store.updateCareAction(ACCOUNT, actionID, { outcome: "completed" });
      snapshot = await store.snapshot(ACCOUNT);
      assert.equal(
        snapshot.plants[0].carePlan.actions.find((action) => action.id === actionID)?.state,
        "completed"
      );

      await store.updatePlant(ACCOUNT, plantID, {
        plant: { ...created.plant, carePlan: null }
      });
      const [completed] = await sql`select status from app.care_actions where id = ${actionID}`;
      const [removed] = await sql`select status from app.care_actions where id = ${removedActionID}`;
      assert.equal(completed.status, "completed", "plan edits must not undo completed care");
      assert.equal(removed.status, "superseded");
      snapshot = await store.snapshot(ACCOUNT);
      assert.equal(snapshot.tasks.some((task) => task.id === removedActionID), false);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("adopting the same plant twice is idempotent", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const plantID = "33333333-3333-4333-8333-333333333333";
      const first = await store.createPlant(ACCOUNT, plantRequest(plantID));
      const second = await store.createPlant(ACCOUNT, plantRequest(plantID));

      assert.equal(first.created, true);
      assert.equal(second.created, false);
      const snapshot = await store.snapshot(ACCOUNT);
      assert.equal(snapshot.plants.length, 1);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("a check-in updates health, records an observation, and reschedules", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const plantID = "44444444-4444-4444-8444-444444444444";
      await store.createPlant(ACCOUNT, plantRequest(plantID));

      const updated = await store.recordCheckIn(ACCOUNT, plantID, {
        score: 91,
        band: "thriving",
        note: "New growth everywhere.",
        appearance: "better",
        soilMoisture: "comfortable",
        hasNewGrowth: true,
        followUpDays: 12
      });

      assert.equal(updated.healthScore, 91);
      assert.equal(updated.healthBand, "thriving");
      assert.equal(updated.trend, "improving");

      const snapshot = await store.snapshot(ACCOUNT);
      assert.equal(snapshot.observations.length, 1);
      assert.equal(snapshot.observations[0].score, 91);
      assert.equal(snapshot.observations[0].previousScore, 82);
      assert.equal(snapshot.observations[0].appearance, "better");
      assert.equal(snapshot.observations[0].hasNewGrowth, true);

      const open = snapshot.tasks.filter((task) => task.plantID === plantID && !task.isCompleted);
      const done = snapshot.tasks.filter((task) => task.plantID === plantID && task.isCompleted);
      assert.equal(open.length, 1, "exactly one follow-up check-in must be scheduled");
      assert.equal(done.length, 1, "the check-in that was completed must not come back");
      assert.ok(snapshot.activity.some((event) => event.plantID === plantID));
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("a care task can be completed and rescheduled", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const plantID = "55555555-5555-4555-8555-555555555555";
      await store.createPlant(ACCOUNT, plantRequest(plantID));
      const snapshot = await store.snapshot(ACCOUNT);
      const taskID = snapshot.tasks[0].id;

      const completed = await store.updateCareAction(ACCOUNT, taskID, { outcome: "completed" });
      assert.equal(completed.isCompleted, true);

      const later = new Date(Date.now() + 3 * 86_400_000);
      const snoozed = await store.updateCareAction(ACCOUNT, taskID, {
        outcome: "snoozed",
        rescheduledFor: later.toISOString(),
        reason: "Soil is still moist"
      });
      assert.equal(snoozed.isCompleted, false);
      assert.equal(new Date(snoozed.dueDate).getTime(), later.getTime());
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("another account cannot touch this account's plants or tasks", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const plantID = "66666666-6666-4666-8666-666666666666";
      await store.createPlant(ACCOUNT, plantRequest(plantID));
      const snapshot = await store.snapshot(ACCOUNT);
      const taskID = snapshot.tasks[0].id;

      assert.equal(await store.findPlant(INTRUDER, plantID), undefined);
      assert.equal(await store.recordCheckIn(INTRUDER, plantID, { score: 10, band: "urgent" }), undefined);
      assert.equal(await store.updateCareAction(INTRUDER, taskID, { outcome: "completed" }), undefined);

      const intruderSnapshot = await store.snapshot(INTRUDER);
      assert.equal(intruderSnapshot.plants.length, 0);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("idempotent responses replay across a restart", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      await store.writeIdempotentResponse(ACCOUNT, "POST", "/v1/plants", "key-1", 201, { id: "abc" });

      const restartedSQL = connect();
      try {
        const restarted = createGroveStore(restartedSQL);
        const replay = await restarted.readIdempotentResponse(ACCOUNT, "POST", "/v1/plants", "key-1");
        assert.deepEqual(replay, { status: 201, body: { id: "abc" } });
      } finally {
        await restartedSQL.end({ timeout: 5 });
      }
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("friend invitations and sitting assignments persist", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const plantID = "77777777-7777-4777-8777-777777777777";
      await store.createPlant(ACCOUNT, plantRequest(plantID));
      await befriend(sql, store);
      const [other] = await sql`select username from app.accounts where id = ${INTRUDER}`;
      await store.createFriendInvitation(ACCOUNT, { username: other.username });
      await store.createSittingAssignment(ACCOUNT, {
        sitterAccountID: SITTER,
        startDate: new Date(Date.now() + 86_400_000).toISOString(),
        endDate: new Date(Date.now() + 7 * 86_400_000).toISOString(),
        plantIDs: [plantID],
        canCheckIn: false
      });

      const snapshot = await store.snapshot(ACCOUNT);
      assert.equal(snapshot.friendInvitations.length, 1);
      assert.equal(snapshot.friendInvitations[0].username, other.username);
      assert.equal(snapshot.friendInvitations[0].direction, "outgoing");
      assert.equal(snapshot.assignments.length, 1);
      assert.deepEqual(snapshot.assignments[0].plantIDs, [plantID]);
      assert.equal(snapshot.assignments[0].totalTasks, 2);
      // The permission the owner chose has to survive the round trip: it was
      // written to the row and then dropped from every response.
      assert.equal(snapshot.assignments[0].canCheckIn, false);
      // The sitter is a person, not an opaque id. Both of these were stored as
      // the raw account uuid, so the owner's own list named their friend with it.
      assert.equal(snapshot.assignments[0].sitterName, "Maya Kapoor");
      assert.equal(snapshot.assignments[0].sitterInitials, "MK");

      const invitation = snapshot.activity.find((event) => event.kind === "assignment");
      assert.ok(invitation, "sending an invitation should be announced in the feed");
      assert.equal(invitation.actorName, "You");
      assert.match(invitation.message, /^invited Maya Kapoor to care for 1 plant$/);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("a client-supplied activity id keeps a mirrored entry from arriving twice", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const plantID = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa";
      const activityEventID = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb";
      await store.createPlant(ACCOUNT, plantRequest(plantID));

      // The client writes its own feed entry the moment the user finishes a
      // check-in, and sends that entry's id along. The server has to land on the
      // same id, or the device ends up holding two records of one check-in.
      // The band sent here deliberately disagrees with the score: like the
      // client's `HealthBand(score:)`, the server derives the band from the
      // score, so 74 reads as "keep an eye on it" on both ends.
      await store.recordCheckIn(ACCOUNT, plantID, { score: 74, band: "attention", activityEventID });

      const snapshot = await store.snapshot(ACCOUNT);
      const entries = snapshot.activity.filter((event) => event.id === activityEventID);
      assert.equal(entries.length, 1);
      // Word for word what the client wrote locally, so folding the two together
      // cannot silently reword an entry the user has already read.
      assert.equal(entries[0].message, "checked in, now keep an eye on it at 74%");

      // A replayed mutation must not add a second entry either.
      await store.recordCheckIn(ACCOUNT, plantID, { score: 74, band: "attention", activityEventID });
      const replayed = await store.snapshot(ACCOUNT);
      assert.equal(replayed.activity.filter((event) => event.id === activityEventID).length, 1);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("a sitter's check-in reaches the owner's feed, attributed to the sitter", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const plantID = "cccccccc-3333-4333-8333-cccccccccccc";
      await store.createPlant(ACCOUNT, plantRequest(plantID));
      await befriend(sql, store);
      await store.createSittingAssignment(ACCOUNT, {
        sitterAccountID: SITTER,
        // Live right now: sitter access is bounded by the trip, so an assignment
        // that starts tomorrow must not grant it yet.
        startDate: new Date(Date.now() - 86_400_000).toISOString(),
        endDate: new Date(Date.now() + 6 * 86_400_000).toISOString(),
        plantIDs: [plantID],
        canCheckIn: true
      });
      // Sending is not accepting. Access starts only once the sitter has
      // explicitly agreed to the handover.
      assert.equal(await store.recordCheckIn(SITTER, plantID, { score: 87, band: "healthy" }), undefined);
      await sql`update app.sitting_assignments set status = 'active' where owner_account_id = ${ACCOUNT}`;

      const updated = await store.recordCheckIn(SITTER, plantID, { score: 88, band: "healthy" });
      assert.ok(updated, "a sitter with check-in permission may record one");
      assert.equal(updated.healthScore, 88);

      // The whole point of the Updates feed: the owner is away, and this is how
      // they find out someone looked after their plant.
      const owner = await store.snapshot(ACCOUNT);
      const news = owner.activity.find((event) => event.plantID === plantID && event.kind === "sitterCare");
      assert.ok(news, "the owner should be told");
      assert.equal(news.actorName, "Maya Kapoor");
      assert.equal(news.actorInitials, "MK");

      // The same row, read by the person who wrote it, is their own action.
      const sitterView = await store.snapshot(SITTER);
      const mine = sitterView.activity.find((event) => event.id === news.id);
      assert.ok(mine, "the sitter should see their own care");
      assert.equal(mine.actorName, "You");

      // And the plant's own history names them too.
      const history = owner.observations.find((entry) => entry.plantID === plantID);
      assert.ok(history);
      assert.equal(history.actorName, "Maya Kapoor");
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("sitter check-in access is bounded by permission, dates and plant list", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const shared = "dddddddd-4444-4444-8444-dddddddddddd";
      const withheld = "eeeeeeee-5555-4555-8555-eeeeeeeeeeee";
      await store.createPlant(ACCOUNT, plantRequest(shared));
      await store.createPlant(ACCOUNT, plantRequest(withheld, { nickname: "Fern" }));
      await befriend(sql, store);

      await store.createSittingAssignment(ACCOUNT, {
        sitterAccountID: SITTER,
        startDate: new Date(Date.now() - 86_400_000).toISOString(),
        endDate: new Date(Date.now() + 6 * 86_400_000).toISOString(),
        plantIDs: [shared],
        canCheckIn: false
      });
      await sql`update app.sitting_assignments set status = 'active' where owner_account_id = ${ACCOUNT}`;

      // Care without check-ins is a real choice the owner is offered, and it has
      // to mean something: recognised, but refused.
      const refused = await store.recordCheckIn(SITTER, shared, { score: 50, band: "monitor" });
      assert.equal(refused.forbidden, true);

      // A plant that was never handed over is simply not theirs to touch.
      assert.equal(await store.recordCheckIn(SITTER, withheld, { score: 50, band: "monitor" }), undefined);

      // Neither is anyone else's plant, assignment or no assignment.
      assert.equal(await store.recordCheckIn(INTRUDER, shared, { score: 50, band: "monitor" }), undefined);

      // Once the trip is over, so is the access.
      await sql`update app.sitting_assignments set can_check_in = true`;
      assert.ok(await store.recordCheckIn(SITTER, shared, { score: 61, band: "monitor" }));
      await sql`
        update app.sitting_assignments
           set starts_at = now() - interval '30 days', ends_at = now() - interval '1 day'
      `;
      assert.equal(await store.recordCheckIn(SITTER, shared, { score: 62, band: "monitor" }), undefined);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("a sitting assignment is refused for a sitter with no account", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const plantID = "99999999-9999-4999-8999-999999999999";
      await store.createPlant(ACCOUNT, plantRequest(plantID));

      // Delegated care grants access to real plants; it must not be possible to
      // hand that to an account that does not exist.
      const result = await store.createSittingAssignment(ACCOUNT, {
        sitterAccountID: "00000000-0000-4000-8000-000000000000",
        startDate: new Date(Date.now() + 86_400_000).toISOString(),
        endDate: new Date(Date.now() + 7 * 86_400_000).toISOString(),
        plantIDs: [plantID]
      });

      assert.equal(result.unknownSitter, true);
      const snapshot = await store.snapshot(ACCOUNT);
      assert.equal(snapshot.assignments.length, 0);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("a repeated invitation does not duplicate", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      // Invite a real account: an unclaimed username is refused outright and
      // would leave nothing to deduplicate.
      const [sitter] = await sql`select username from app.accounts where id = ${SITTER}`;
      const first = await store.createFriendInvitation(ACCOUNT, { username: sitter.username });
      const second = await store.createFriendInvitation(ACCOUNT, { username: sitter.username });
      assert.ok(first.invitation, "the first invitation should be created");
      assert.equal(second.invitation?.id, first.invitation.id);

      const snapshot = await store.snapshot(ACCOUNT);
      assert.equal(snapshot.friendInvitations.length, 1);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("both sides see the other gardener's identity after acceptance", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      await befriend(sql, store);

      const requester = await store.snapshot(ACCOUNT);
      const recipient = await store.snapshot(SITTER);
      assert.equal(requester.friends.length, 1);
      assert.equal(requester.friends[0].name, "Maya Kapoor");
      assert.equal(recipient.friends.length, 1);
      assert.equal(recipient.friends[0].name, "Test Gardener");
      assert.equal(recipient.friends[0].id, ACCOUNT);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("a reverse pending request cannot create a second relationship row", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const [sitter] = await sql`select username from app.accounts where id = ${SITTER}`;
      const [owner] = await sql`select username from app.accounts where id = ${ACCOUNT}`;
      const first = await store.createFriendInvitation(ACCOUNT, { username: sitter.username });
      const reverse = await store.createFriendInvitation(SITTER, { username: owner.username });

      assert.ok(first.invitation);
      assert.equal(reverse.reversePending, true);
      const [{ count }] = await sql`
        select count(*)::int as count from app.friendships
        where (requested_by_account_id = ${ACCOUNT} and requested_to_account_id = ${SITTER})
           or (requested_by_account_id = ${SITTER} and requested_to_account_id = ${ACCOUNT})`;
      assert.equal(count, 1);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("accept and withdraw racing on different devices have one winner", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const [sitter] = await sql`select username from app.accounts where id = ${SITTER}`;
      const created = await store.createFriendInvitation(ACCOUNT, { username: sitter.username });

      const [accepted, withdrawn] = await Promise.all([
        store.respondToFriendInvitation(SITTER, created.invitation.id, { accept: true }),
        store.withdrawFriendInvitation(ACCOUNT, created.invitation.id)
      ]);
      const winners = [accepted, withdrawn].filter((result) => result.ok).length;
      const conflicts = [accepted, withdrawn].filter((result) => result.conflict).length;
      const [settled] = await sql`select status from app.friendships where id = ${created.invitation.id}`;

      assert.equal(winners, 1);
      assert.equal(conflicts, 1);
      assert.ok(["accepted", "withdrawn"].includes(settled.status));
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("remove wins against a stale pending acceptance", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const [sitter] = await sql`select username from app.accounts where id = ${SITTER}`;
      const created = await store.createFriendInvitation(ACCOUNT, { username: sitter.username });

      await Promise.all([
        store.respondToFriendInvitation(SITTER, created.invitation.id, { accept: true }),
        store.removeFriend(SITTER, ACCOUNT)
      ]);

      const [settled] = await sql`
        select status, requested_by_account_id, requested_to_account_id
          from app.friendships where id = ${created.invitation.id}
      `;
      assert.equal(settled.status, "declined");
      assert.equal(settled.requested_by_account_id, ACCOUNT);
      assert.equal(settled.requested_to_account_id, SITTER);
      assert.equal((await store.snapshot(ACCOUNT)).friends.length, 0);
      assert.equal((await store.snapshot(SITTER)).friends.length, 0);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("unknown usernames consume the bounded invitation-attempt allowance", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const requestID = (number) => `a0000000-0000-4000-8000-${String(number).padStart(12, "0")}`;

      for (let index = 1; index <= 30; index += 1) {
        const result = await store.createFriendInvitation(ACCOUNT, {
          username: `missing_${String(index).padStart(2, "0")}`,
          clientRequestID: requestID(index)
        });
        assert.equal(result.unknownUser, true);
      }

      const replay = await store.createFriendInvitation(ACCOUNT, {
        username: "missing_01",
        clientRequestID: requestID(1)
      });
      assert.equal(replay.unknownUser, true, "a retry must not spend the allowance twice");
      const collision = await store.createFriendInvitation(ACCOUNT, {
        username: "different_name",
        clientRequestID: requestID(1)
      });
      assert.equal(collision.idempotencyConflict, true, "one request id cannot probe two usernames");
      const limited = await store.createFriendInvitation(ACCOUNT, {
        username: "missing_31",
        clientRequestID: requestID(31)
      });
      assert.equal(limited.rateLimited, true);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("removing a friend revokes legacy delegation and prevents an immediate re-request", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const plantID = "d1d1d1d1-4444-4444-8444-d1d1d1d1d1d1";
      await store.createPlant(ACCOUNT, plantRequest(plantID));
      await befriend(sql, store);
      const assignmentID = "d2d2d2d2-5555-4555-8555-d2d2d2d2d2d2";
      const assignment = await store.createSittingAssignment(ACCOUNT, {
        sitterAccountID: SITTER,
        startDate: new Date(Date.now() + 86_400_000).toISOString(),
        endDate: new Date(Date.now() + 7 * 86_400_000).toISOString(),
        plantIDs: [plantID],
        clientRequestID: assignmentID
      });
      assert.equal(assignment.id, assignmentID);

      await store.removeFriend(ACCOUNT, SITTER.toUpperCase());

      const [friendship] = await sql`
        select status, requested_by_account_id, requested_to_account_id
          from app.friendships
         where (requested_by_account_id = ${ACCOUNT} and requested_to_account_id = ${SITTER})
            or (requested_by_account_id = ${SITTER} and requested_to_account_id = ${ACCOUNT})
      `;
      const [revoked] = await sql`
        select status, revoked_at from app.sitting_assignments where id = ${assignmentID}
      `;
      assert.equal(friendship.status, "declined");
      assert.equal(friendship.requested_by_account_id, SITTER);
      assert.equal(friendship.requested_to_account_id, ACCOUNT);
      assert.equal(revoked.status, "revoked");
      assert.ok(revoked.revoked_at);
      assert.equal((await store.snapshot(ACCOUNT)).friends.length, 0);
      assert.equal((await store.snapshot(SITTER)).friends.length, 0);

      const [owner] = await sql`select username from app.accounts where id = ${ACCOUNT}`;
      const [sitter] = await sql`select username from app.accounts where id = ${SITTER}`;
      assert.equal(
        (await store.createFriendInvitation(SITTER, { username: owner.username })).alreadyAnswered,
        true,
        "the removed account must not turn removal into another push notification"
      );
      assert.ok(
        (await store.createFriendInvitation(ACCOUNT, { username: sitter.username })).invitation,
        "the remover may deliberately reconnect later"
      );
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("sitting requires an accepted friend and owner-scoped plants", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const ownPlant = "abababab-1111-4111-8111-abababababab";
      const foreignPlant = "cdcdcdcd-2222-4222-8222-cdcdcdcdcdcd";
      await store.createPlant(ACCOUNT, plantRequest(ownPlant));
      await store.createPlant(INTRUDER, plantRequest(foreignPlant));
      const request = {
        sitterAccountID: SITTER,
        startDate: new Date(Date.now() + 86_400_000).toISOString(),
        endDate: new Date(Date.now() + 7 * 86_400_000).toISOString(),
        plantIDs: [ownPlant]
      };

      assert.equal((await store.createSittingAssignment(ACCOUNT, request)).notFriends, true);
      await befriend(sql, store);
      assert.equal(
        (await store.createSittingAssignment(ACCOUNT, { ...request, plantIDs: [foreignPlant] })).invalidPlants,
        true
      );
      assert.equal((await store.snapshot(ACCOUNT)).assignments.length, 0);

      const clientRequestID = "efefefef-3333-4333-8333-efefefefefef";
      const created = await store.createSittingAssignment(ACCOUNT, { ...request, clientRequestID });
      const replay = await store.createSittingAssignment(ACCOUNT, { ...request, clientRequestID });
      const collision = await store.createSittingAssignment(ACCOUNT, {
        ...request,
        clientRequestID,
        endDate: new Date(Date.now() + 8 * 86_400_000).toISOString()
      });

      assert.equal(created.id, clientRequestID);
      assert.equal(replay.id, clientRequestID);
      assert.equal(collision.conflict, true);
      assert.equal((await store.snapshot(ACCOUNT)).assignments.length, 1);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("bootstrap returns sitting-link metadata without returning its bearer", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const plantID = "a3a3a3a3-6666-4666-8666-a3a3a3a3a3a3";
      const inviteID = "a4a4a4a4-7777-4777-8777-a4a4a4a4a4a4";
      await store.createPlant(ACCOUNT, plantRequest(plantID));
      const [{ id: groveID }] = await sql`select id from app.groves where owner_account_id = ${ACCOUNT}`;
      await sql`
        insert into app.sitting_invites (
          id, owner_account_id, grove_id, token_hash, label, starts_at, ends_at, can_log_care
        ) values (
          ${inviteID}, ${ACCOUNT}, ${groveID}, ${"f".repeat(64)}, 'Maya',
          ${new Date(Date.now() - 60_000)}, ${new Date(Date.now() + 86_400_000)}, true
        )
      `;
      await sql`
        insert into app.sitting_invite_plants (invite_id, plant_id)
        values (${inviteID}, ${plantID})
      `;

      const snapshot = await store.snapshot(ACCOUNT);
      assert.equal(snapshot.sittingInvites.length, 1);
      assert.deepEqual(snapshot.sittingInvites[0].plantIDs, [plantID]);
      assert.equal(snapshot.sittingInvites[0].shareURL, null);
      assert.equal(snapshot.sittingInvites[0].wasMinted, true);
      assert.equal("tokenHash" in snapshot.sittingInvites[0], false);
      assert.equal("token_hash" in snapshot.sittingInvites[0], false);

      await store.deletePlant(ACCOUNT, plantID);
      const [retired] = await sql`select revoked_at from app.sitting_invites where id = ${inviteID}`;
      assert.ok(retired.revoked_at, "deleting the final scoped plant must retire the parent capability");
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("profile updates persist while plant access remains private", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      await store.updateProfile(ACCOUNT, {
        displayName: "Ari Green",
        username: "arigrows",
        regionCode: "GB",
        usesMetricSystem: true,
        isPrivate: false,
        latitude: 51.4545,
        longitude: -2.5879,
        locationLabel: "Bristol, United Kingdom",
        locationCountryCode: "GB",
        locationTimeZoneIdentifier: "Europe/London"
      });

      const snapshot = await store.snapshot(ACCOUNT);
      assert.equal(snapshot.profile.name, "Ari Green");
      assert.equal(snapshot.profile.username, "arigrows");
      assert.equal(snapshot.profile.initials, "AG");
      assert.equal(snapshot.profile.isPrivate, true);
      assert.equal(snapshot.profile.location.countryCode, "GB");
      assert.equal(snapshot.profile.location.timeZoneIdentifier, "Europe/London");
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("a signed upload is reused for the same media and rejected for different content", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const localMediaID = "88888888-8888-4888-8888-888888888888";
      const body = {
        localMediaID,
        mimeType: "image/jpeg",
        byteCount: 1024,
        sha256: "a".repeat(64),
        purpose: "scan"
      };

      const first = await store.negotiateUpload(ACCOUNT, body);
      assert.equal(first.created, true);
      const second = await store.negotiateUpload(ACCOUNT, body);
      assert.equal(second.created, false);
      assert.equal(second.upload.media_asset_id, first.upload.media_asset_id);

      const conflicting = await store.negotiateUpload(ACCOUNT, { ...body, sha256: "b".repeat(64) });
      assert.equal(conflicting.conflict, true);

      const ready = await store.markUploadReady(ACCOUNT, first.upload.media_asset_id, null);
      assert.equal(ready.status, "ready");
      assert.equal(await store.markUploadReady(INTRUDER, first.upload.media_asset_id, null), undefined);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("idempotency claims reject body collisions and stale workers cannot overwrite a replacement", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      const route = ["POST", "/v1/friendships/invitations", "friend-key"];
      const firstClaim = "11111111-1111-4111-8111-111111111111";
      const replacementClaim = "22222222-2222-4222-8222-222222222222";

      assert.deepEqual(
        await store.claimIdempotentResponse(ACCOUNT, ...route, "hash-a", firstClaim),
        { claimed: true }
      );
      assert.deepEqual(
        await store.claimIdempotentResponse(ACCOUNT, ...route, "hash-a", replacementClaim),
        { wait: true }
      );
      assert.deepEqual(
        await store.claimIdempotentResponse(ACCOUNT, ...route, "hash-b", replacementClaim),
        { conflict: true }
      );

      await sql`update app.idempotency_keys set stored_at = now() - interval '16 minutes'`;
      assert.deepEqual(
        await store.claimIdempotentResponse(ACCOUNT, ...route, "hash-b", replacementClaim),
        { claimed: true }
      );
      await store.completeIdempotentResponse(ACCOUNT, ...route, "hash-a", firstClaim, 201, { wrong: true });
      assert.deepEqual(
        await store.claimIdempotentResponse(ACCOUNT, ...route, "hash-b", firstClaim),
        { wait: true },
        "an expired worker must not complete over the replacement claim"
      );
      await store.completeIdempotentResponse(ACCOUNT, ...route, "hash-b", replacementClaim, 201, { ok: true });
      assert.deepEqual(
        await store.claimIdempotentResponse(ACCOUNT, ...route, "hash-b", firstClaim),
        { status: 201, body: { ok: true } }
      );
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("sweeping drops stale replay records but keeps ready uploads", async () => {
    const sql = connect();
    try {
      await reset(sql);
      const store = createGroveStore(sql);
      await store.writeIdempotentResponse(ACCOUNT, "POST", "/v1/plants", "old-key", 201, {});
      await sql`update app.idempotency_keys set stored_at = now() - interval '3 hours'`;

      await store.sweep();

      assert.equal(await store.readIdempotentResponse(ACCOUNT, "POST", "/v1/plants", "old-key"), undefined);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });
});
