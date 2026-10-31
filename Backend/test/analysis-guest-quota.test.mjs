import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test from "node:test";
import postgres from "postgres";

const databaseURL = process.env.GROVE_TEST_DATABASE_URL;
const describe = databaseURL ? test.describe : test.describe.skip;

function connect() {
  return postgres(databaseURL, { ssl: false, prepare: false, max: 4, onnotice: () => {} });
}

async function resetGlobalUsage(sql) {
  await sql`
    delete from public.analysis_guest_global_usage
    where day = (now() at time zone 'utc')::date
  `;
}

async function createAnonymousUser(sql, purpose, createdAt = new Date()) {
  const [user] = await sql`
    insert into auth.users (raw_user_meta_data, is_anonymous, created_at)
    values (${sql.json({ purpose })}, true, ${createdAt})
    returning id
  `;
  return user.id;
}

async function createGuestJob(sql, accountID, requestID, fingerprint, {
  dailyLimit = 3,
  attempts = 3,
  globalLimit = 250
} = {}) {
  const [row] = await sql`
    select public.analysis_create_guest_job(
      ${accountID}::uuid,
      ${requestID}::uuid,
      ${fingerprint},
      ${dailyLimit},
      ${attempts},
      ${globalLimit}
    ) as result
  `;
  return row.result;
}

async function cleanupUsers(sql, userIDs) {
  const ids = userIDs.filter(Boolean);
  if (ids.length) {
    await sql`delete from public.analysis_jobs where owner_account_id = any(${ids.map(String)})`;
    await sql`delete from auth.users where id = any(${ids})`;
  }
  await resetGlobalUsage(sql);
}

describe("onboarding guest analysis", { concurrency: false }, () => {
  test("the Auth trigger records an immutable purpose without provisioning a Grove account", async () => {
    const sql = connect();
    let userID;
    try {
      userID = await createAnonymousUser(sql, "onboarding_scan");
      const [registration] = await sql`
        select purpose from public.anonymous_auth_purposes where user_id = ${userID}::uuid
      `;
      const accounts = await sql`select id from app.accounts where id = ${userID}::uuid`;
      assert.equal(registration.purpose, "onboarding_scan");
      assert.equal(accounts.length, 0);

      // `raw_user_meta_data` is user-editable. Changing it after creation must
      // not promote the server-owned registration to the Botanist surface.
      await sql`
        update auth.users
        set raw_user_meta_data = ${sql.json({ purpose: "botanist" })}
        where id = ${userID}::uuid
      `;
      const [unchanged] = await sql`
        select purpose from public.anonymous_auth_purposes where user_id = ${userID}::uuid
      `;
      assert.equal(unchanged.purpose, "onboarding_scan");
    } finally {
      await cleanupUsers(sql, [userID]);
      await sql.end({ timeout: 5 });
    }
  });

  test("a caller-declared Botanist identity is unclassified and keeps the guest scan budget", async () => {
    const sql = connect();
    let userID;
    try {
      await resetGlobalUsage(sql);
      userID = await createAnonymousUser(sql, "botanist");
      const [registration] = await sql`
        select purpose from public.anonymous_auth_purposes where user_id = ${userID}::uuid
      `;
      assert.equal(registration.purpose, "unclassified");
      const [identity] = await sql`
        select public.analysis_identity_class(${userID}::uuid) as class
      `;
      assert.equal(identity.class, "anonymous");

      for (const fingerprint of ["a", "b", "c"]) {
        const allowed = await createGuestJob(
          sql, userID, randomUUID(), fingerprint.repeat(64)
        );
        assert.equal(allowed.decision, "created");
      }
      const fourth = await createGuestJob(sql, userID, randomUUID(), "d".repeat(64));
      assert.equal(fourth.decision, "daily_limited");
    } finally {
      await cleanupUsers(sql, [userID]);
      await sql.end({ timeout: 5 });
    }
  });

  test("only a non-anonymous user with a provisioned app account receives account class", async () => {
    const sql = connect();
    let providerUserID;
    let strippedUserID;
    try {
      const [provider] = await sql`
        insert into auth.users (email, raw_user_meta_data, is_anonymous)
        values ('provider@example.test', ${sql.json({ username: "provider" })}, false)
        returning id
      `;
      providerUserID = provider.id;
      const [providerClass] = await sql`
        select public.analysis_identity_class(${providerUserID}::uuid) as class
      `;
      assert.equal(providerClass.class, "account");

      const [stripped] = await sql`
        insert into auth.users (email, raw_user_meta_data, is_anonymous)
        values ('stripped@example.test', ${sql.json({ username: "stripped" })}, false)
        returning id
      `;
      strippedUserID = stripped.id;
      await sql`delete from app.accounts where id = ${strippedUserID}::uuid`;
      const [strippedClass] = await sql`
        select public.analysis_identity_class(${strippedUserID}::uuid) as class
      `;
      assert.equal(strippedClass.class, "unclassified");
    } finally {
      await cleanupUsers(sql, [providerUserID, strippedUserID]);
      await sql.end({ timeout: 5 });
    }
  });

  test("duplicate concurrent POSTs return one job and consume one attempt", async () => {
    const sql = connect();
    let userID;
    try {
      await resetGlobalUsage(sql);
      userID = await createAnonymousUser(sql, "onboarding_scan");
      const requestID = randomUUID();
      const fingerprint = "e".repeat(64);
      const results = await Promise.all([
        createGuestJob(sql, userID, requestID, fingerprint),
        createGuestJob(sql, userID, requestID, fingerprint)
      ]);
      assert.deepEqual(results.map((value) => value.decision).sort(), ["created", "existing"]);
      assert.equal(results[0].job.id, results[1].job.id);

      const [reservation] = await sql`
        select attempts from public.analysis_guest_scans
        where account_id = ${userID}::uuid
      `;
      const [global] = await sql`
        select reserved_provider_attempts from public.analysis_guest_global_usage
        where day = (now() at time zone 'utc')::date
      `;
      const jobs = await sql`
        select id from public.analysis_jobs where owner_account_id = ${String(userID)}
      `;
      assert.equal(reservation.attempts, 1);
      assert.equal(global.reserved_provider_attempts, 1);
      assert.equal(jobs.length, 1);
    } finally {
      await cleanupUsers(sql, [userID]);
      await sql.end({ timeout: 5 });
    }
  });

  test("a failed logical scan can retry up to its bounded provider-attempt allowance", async () => {
    const sql = connect();
    let userID;
    try {
      await resetGlobalUsage(sql);
      userID = await createAnonymousUser(sql, "onboarding_scan");
      const requestID = randomUUID();
      const fingerprint = "f".repeat(64);

      for (let expectedAttempt = 1; expectedAttempt <= 3; expectedAttempt += 1) {
        const result = await createGuestJob(sql, userID, requestID, fingerprint);
        assert.equal(result.decision, "created");
        await sql`
          update public.analysis_jobs set status = 'failed'
          where id = ${result.job.id}::uuid
        `;
        const [reservation] = await sql`
          select attempts from public.analysis_guest_scans
          where account_id = ${userID}::uuid
            and client_request_id = ${requestID}::uuid
            and fingerprint = ${fingerprint}
        `;
        assert.equal(reservation.attempts, expectedAttempt);
      }

      const exhausted = await createGuestJob(sql, userID, requestID, fingerprint);
      const anotherPhoto = await createGuestJob(sql, userID, randomUUID(), "0".repeat(64));
      assert.equal(exhausted.decision, "attempts_limited");
      assert.equal(anotherPhoto.decision, "created");
    } finally {
      await cleanupUsers(sql, [userID]);
      await sql.end({ timeout: 5 });
    }
  });

  test("concurrent photos cannot both claim a one-scan guest allowance", async () => {
    const sql = connect();
    let userID;
    try {
      await resetGlobalUsage(sql);
      userID = await createAnonymousUser(sql, "onboarding_scan");
      const results = await Promise.all([
        createGuestJob(sql, userID, randomUUID(), "1".repeat(64), { dailyLimit: 1 }),
        createGuestJob(sql, userID, randomUUID(), "2".repeat(64), { dailyLimit: 1 })
      ]);
      assert.deepEqual(results.map((value) => value.decision).sort(), ["created", "daily_limited"]);
    } finally {
      await cleanupUsers(sql, [userID]);
      await sql.end({ timeout: 5 });
    }
  });

  test("the global guest ceiling spans separately minted anonymous identities", async () => {
    const sql = connect();
    const userIDs = [];
    try {
      await resetGlobalUsage(sql);
      userIDs.push(await createAnonymousUser(sql, "onboarding_scan"));
      userIDs.push(await createAnonymousUser(sql, "onboarding_scan"));
      const first = await createGuestJob(
        sql, userIDs[0], randomUUID(), "3".repeat(64), { globalLimit: 1 }
      );
      const second = await createGuestJob(
        sql, userIDs[1], randomUUID(), "4".repeat(64), { globalLimit: 1 }
      );
      assert.equal(first.decision, "created");
      assert.equal(second.decision, "global_limited");

      const reservations = await sql`
        select account_id from public.analysis_guest_scans
        where account_id = any(${userIDs})
      `;
      assert.equal(reservations.length, 1);
      assert.equal(String(reservations[0].account_id), String(userIDs[0]));
    } finally {
      await cleanupUsers(sql, userIDs);
      await sql.end({ timeout: 5 });
    }
  });

  test("guest job creation rejects null limits and malformed fingerprints", async () => {
    const sql = connect();
    let userID;
    try {
      userID = await createAnonymousUser(sql, "onboarding_scan");
      await assert.rejects(
        sql`
          select public.analysis_create_guest_job(
            ${userID}::uuid,
            ${randomUUID()}::uuid,
            ${"a".repeat(64)},
            ${null}::integer,
            3,
            250
          )
        `,
        /invalid guest analysis job request/
      );
      await assert.rejects(
        createGuestJob(sql, userID, randomUUID(), "not-a-fingerprint"),
        /invalid guest analysis job request/
      );
    } finally {
      await cleanupUsers(sql, [userID]);
      await sql.end({ timeout: 5 });
    }
  });

  test("paid runtime RPCs and tables have explicit service-role access only", async () => {
    const sql = connect();
    try {
      const [privileges] = await sql`
        select
          has_function_privilege(
            'service_role',
            'public.analysis_identity_class(uuid)',
            'EXECUTE'
          ) as service_identity,
          has_function_privilege(
            'service_role',
            'public.analysis_create_guest_job(uuid,uuid,text,integer,integer,integer)',
            'EXECUTE'
          ) as service_guest_job,
          has_function_privilege(
            'service_role',
            'public.botanist_record_ask(text,integer)',
            'EXECUTE'
          ) as service_botanist_counter,
          has_function_privilege(
            'authenticated',
            'public.analysis_identity_class(uuid)',
            'EXECUTE'
          ) as client_identity,
          has_function_privilege(
            'authenticated',
            'public.analysis_create_guest_job(uuid,uuid,text,integer,integer,integer)',
            'EXECUTE'
          ) as client_guest_job,
          has_function_privilege(
            'authenticated',
            'public.botanist_record_ask(text,integer)',
            'EXECUTE'
          ) as client_botanist_counter,
          has_table_privilege('service_role', 'public.analysis_jobs', 'SELECT')
            and has_table_privilege('service_role', 'public.analysis_jobs', 'INSERT')
            and has_table_privilege('service_role', 'public.analysis_jobs', 'UPDATE')
            and has_table_privilege('service_role', 'public.analysis_jobs', 'DELETE')
            as service_analysis_jobs,
          has_table_privilege('service_role', 'public.botanist_advice', 'SELECT')
            and has_table_privilege('service_role', 'public.botanist_advice', 'INSERT')
            and has_table_privilege('service_role', 'public.botanist_advice', 'UPDATE')
            and has_table_privilege('service_role', 'public.botanist_advice', 'DELETE')
            as service_botanist_advice,
          has_table_privilege('service_role', 'public.botanist_usage', 'DELETE')
            as service_botanist_usage,
          has_table_privilege('service_role', 'public.anonymous_auth_purposes', 'SELECT')
            as service_anonymous_purposes
      `;
      assert.equal(privileges.service_identity, true);
      assert.equal(privileges.service_guest_job, true);
      assert.equal(privileges.service_botanist_counter, true);
      assert.equal(privileges.client_identity, false);
      assert.equal(privileges.client_guest_job, false);
      assert.equal(privileges.client_botanist_counter, false);
      assert.equal(privileges.service_analysis_jobs, true);
      assert.equal(privileges.service_botanist_advice, true);
      assert.equal(privileges.service_botanist_usage, true);
      assert.equal(privileges.service_anonymous_purposes, true);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("the analysis sweep removes abandoned onboarding Auth identities after 30 days", async () => {
    const sql = connect();
    let userID;
    try {
      userID = await createAnonymousUser(
        sql,
        "onboarding_scan",
        new Date(Date.now() - 31 * 24 * 60 * 60_000)
      );
      await sql`select public.sweep_analysis_jobs()`;
      const users = await sql`select id from auth.users where id = ${userID}::uuid`;
      assert.equal(users.length, 0);
      userID = undefined;
    } finally {
      await cleanupUsers(sql, [userID]);
      await sql.end({ timeout: 5 });
    }
  });

  test("the 30-day cleanup job is an active migration invariant", async () => {
    const sql = connect();
    try {
      const [job] = await sql`
        select schedule, command, active
        from cron.job
        where jobname = 'grove-sweep-analysis-jobs'
      `;
      assert.equal(job.active, true);
      assert.equal(job.schedule, "*/15 * * * *");
      assert.match(job.command, /public\.sweep_analysis_jobs\(\)/);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });
});
