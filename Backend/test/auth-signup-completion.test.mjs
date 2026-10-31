import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import postgres from "postgres";
import { createTestAccount, resetAccounts } from "./helpers/database.mjs";

const databaseURL = process.env.GROVE_TEST_DATABASE_URL;
const describe = databaseURL ? test.describe : test.describe.skip;

test("signup completion is server-owned, caller-scoped, and rollout-safe", async () => {
  const [migration, api, nodeDatabase, releaseGate, authConfig, authPreflight] = await Promise.all([
    readFile(new URL("../../supabase/migrations/20260803000100_auth_signup_completion.sql", import.meta.url), "utf8"),
    readFile(new URL("../../supabase/functions/api/index.ts", import.meta.url), "utf8"),
    readFile(new URL("../supabase-db.mjs", import.meta.url), "utf8"),
    readFile(new URL("../../scripts/check-production-gateway.sh", import.meta.url), "utf8"),
    readFile(new URL("../../supabase/config.toml", import.meta.url), "utf8"),
    readFile(new URL("../../scripts/apply-auth-email.py", import.meta.url), "utf8")
  ]);
  assert.match(migration, /add column if not exists signup_completed_at/);
  assert.match(migration, /add column if not exists signup_completion_claim_id uuid/);
  assert.match(migration, /where account\.id = auth\.uid\(\)/);
  assert.match(migration, /where id = auth\.uid\(\)/);
  assert.match(migration, /and signup_completed_at is null/);
  assert.match(migration, /return false/);
  assert.match(migration, /revoke select, insert, update, delete on table app\.accounts from authenticated/);
  assert.match(migration, /grant select \(id, username, display_name, avatar_storage_key\)/);
  assert.match(migration, /create policy accounts_self_read on app\.accounts\s+for select/);
  assert.match(migration, /check \(username ~ '\^\[a-z0-9_\]\{3,24\}\$'\)/);
  assert.match(migration, /new\.is_anonymous is not false/);
  assert.match(migration, /left\(replace\(new\.id::text, '-', ''\), 16\)/);
  assert.match(migration, /signup_completion_claim_id = p_claim_id/);
  assert.match(migration, /return coalesce\(claimed_by_caller, false\)/);
  assert.match(migration, /revoke all on function public\.grove_complete_signup\(uuid\) from anon/);
  assert.match(migration, /grant execute on function public\.grove_complete_signup\(uuid\) to authenticated/);
  assert.match(api, /set signup_completed_at = coalesce\(signup_completed_at, now\(\)\)/);
  assert.match(api, /signupCompletionReady: row\.signup_completion_ready === true/);
  assert.match(api, /\[\.\.\.displayName\]\.length > 80/);
  assert.match(api, /\\u202a-\\u202e/);
  assert.match(nodeDatabase, /to_regprocedure\('public\.grove_complete_signup\(uuid\)'\)/);
  assert.match(releaseGate, /SYNC_HEALTH="\$\{SYNC_V1_BASE%v1\/\}health"/);
  assert.doesNotMatch(releaseGate, /SYNC_HEALTH="\$\{SYNC_(?:V1_)?BASE\}health"/);
  assert.match(authConfig, /\[auth\.email\][\s\S]*?enable_signup = false/);
  assert.match(authPreflight, /PUBLIC_EMAIL_SIGNUP_ENABLED = False/);
  assert.match(authPreflight, /"external_email_enabled": PUBLIC_EMAIL_SIGNUP_ENABLED/);
  assert.match(authPreflight, /public email signup is enabled while Grove hides it in the app/);
});

function connect() {
  return postgres(databaseURL, { ssl: false, prepare: false, max: 1, onnotice: () => {} });
}

async function asAccount(sql, accountID, work) {
  return sql.begin(async (tx) => {
    await tx`select set_config('app.account_id', ${accountID}, true)`;
    return work(tx);
  });
}

describe("auth signup completion boundary", () => {
  test("new identities stay incomplete until explicit acceptance", async () => {
    const sql = connect();
    let accountID;
    try {
      accountID = await createTestAccount(sql, { name: "Pending Gardener" });

      const before = await asAccount(sql, accountID, async (tx) => {
        const [row] = await tx`select public.grove_signup_completed() as completed`;
        return row.completed;
      });
      assert.equal(before, false);

      const winningClaim = "10cfbf88-6881-4396-8d91-2b694914eb0c";
      const losingClaim = "20cfbf88-6881-4396-8d91-2b694914eb0c";

      const accepted = await asAccount(sql, accountID, async (tx) => {
        const [row] = await tx`select public.grove_complete_signup(${winningClaim}::uuid) as completed`;
        return row.completed;
      });
      assert.equal(accepted, true);

      const replay = await asAccount(sql, accountID, async (tx) => {
        const [row] = await tx`select public.grove_complete_signup(${winningClaim}::uuid) as completed`;
        return row.completed;
      });
      assert.equal(replay, true, "A lost response must be safely retryable by the winning claim");

      const competitor = await asAccount(sql, accountID, async (tx) => {
        const [row] = await tx`select public.grove_complete_signup(${losingClaim}::uuid) as completed`;
        return row.completed;
      });
      assert.equal(competitor, false, "A different device must not claim the winner's onboarding data");

      const [account] = await sql`
        select signup_completed_at from app.accounts where id = ${accountID}::uuid`;
      assert.ok(account.signup_completed_at instanceof Date);

      const after = await asAccount(sql, accountID, async (tx) => {
        const [row] = await tx`select public.grove_signup_completed() as completed`;
        return row.completed;
      });
      assert.equal(after, true);
    } finally {
      await resetAccounts(sql, [accountID]);
      await sql.end({ timeout: 5 });
    }
  });

  test("anonymous Auth identities cannot complete a Grove signup", async () => {
    const sql = connect();
    let anonymousID;
    try {
      const [user] = await sql`
        insert into auth.users (is_anonymous, raw_user_meta_data)
        values (true, ${sql.json({ purpose: "onboarding_scan" })})
        returning id`;
      anonymousID = user.id;

      const result = await asAccount(sql, anonymousID, async (tx) => {
        const [row] = await tx`
          select
            public.grove_signup_completed() as completed,
            public.grove_complete_signup('10cfbf88-6881-4396-8d91-2b694914eb0c'::uuid) as accepted`;
        return row;
      });
      assert.equal(result.completed, false);
      assert.equal(result.accepted, null);

      const accounts = await sql`
        select id from app.accounts where id = ${anonymousID}::uuid`;
      assert.equal(accounts.length, 0);
    } finally {
      await resetAccounts(sql, [anonymousID]);
      await sql.end({ timeout: 5 });
    }
  });

  test("only authenticated callers can execute completion functions", async () => {
    const sql = connect();
    try {
      const [privileges] = await sql`
        select
          has_function_privilege('public', 'public.grove_signup_completed()', 'EXECUTE') as public_status,
          has_function_privilege('anon', 'public.grove_signup_completed()', 'EXECUTE') as anon_status,
          has_function_privilege('authenticated', 'public.grove_signup_completed()', 'EXECUTE') as authenticated_status,
          has_function_privilege('public', 'public.grove_complete_signup(uuid)', 'EXECUTE') as public_complete,
          has_function_privilege('anon', 'public.grove_complete_signup(uuid)', 'EXECUTE') as anon_complete,
          has_function_privilege('authenticated', 'public.grove_complete_signup(uuid)', 'EXECUTE') as authenticated_complete`;
      assert.equal(privileges.public_status, false);
      assert.equal(privileges.anon_status, false);
      assert.equal(privileges.authenticated_status, true);
      assert.equal(privileges.public_complete, false);
      assert.equal(privileges.anon_complete, false);
      assert.equal(privileges.authenticated_complete, true);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });

  test("authenticated clients cannot mutate account rows directly", async () => {
    const sql = connect();
    try {
      const [privileges] = await sql`
        select
          has_table_privilege('authenticated', 'app.accounts', 'SELECT') as can_select_everything,
          has_column_privilege('authenticated', 'app.accounts', 'display_name', 'SELECT') as can_select_name,
          has_column_privilege('authenticated', 'app.accounts', 'signup_completion_claim_id', 'SELECT') as can_select_claim,
          has_table_privilege('authenticated', 'app.accounts', 'INSERT') as can_insert,
          has_table_privilege('authenticated', 'app.accounts', 'UPDATE') as can_update,
          has_table_privilege('authenticated', 'app.accounts', 'DELETE') as can_delete`;
      assert.equal(privileges.can_select_everything, false);
      assert.equal(privileges.can_select_name, true);
      assert.equal(privileges.can_select_claim, false);
      assert.equal(privileges.can_insert, false);
      assert.equal(privileges.can_update, false);
      assert.equal(privileges.can_delete, false);
    } finally {
      await sql.end({ timeout: 5 });
    }
  });
});
