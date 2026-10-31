import postgres from "postgres";

// Connection to the Grove Supabase Postgres database (the project named by SUPABASE_DB_URL).
//
// The relational schema lives in `supabase/migrations/` at the repo root and is applied
// with `supabase db push`. This module only owns the runtime connection: pooling, the
// per-request account scope that `app.current_account_id()` reads, and a health probe.

const ACCOUNT_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class DatabaseNotConfiguredError extends Error {
  constructor() {
    super(
      "SUPABASE_DB_URL is not configured. Copy Backend/.env.example to Backend/.env.local " +
        "and set the Supabase connection string (Dashboard → Connect → Transaction pooler)."
    );
  }
}

export function loadDatabaseURL({ environment = process.env } = {}) {
  const configured = environment.SUPABASE_DB_URL?.trim() || environment.DATABASE_URL?.trim();
  return configured || undefined;
}

// Supabase exposes three connection modes. The transaction pooler (port 6543) is the right
// default for a container that may scale to several instances, but it cannot serve prepared
// statements — hence `prepare: false`, which is safe on the direct connection too.
export function createGroveDatabase({ url = loadDatabaseURL(), ...options } = {}) {
  if (!url) throw new DatabaseNotConfiguredError();

  const sql = postgres(url, {
    ssl: "require",
    prepare: false,
    max: 8,
    idle_timeout: 20,
    connect_timeout: 10,
    ...options
  });

  return {
    sql,

    // Runs `work` inside a transaction whose `app.account_id` setting is the caller's
    // account, so every RLS policy in the schema resolves against the right actor. The
    // setting is transaction-local (`true`), so a pooled connection can never leak one
    // request's account scope into the next.
    async withAccount(accountID, work) {
      // An account id is a Supabase Auth user uuid. Rejecting anything else here keeps a
      // malformed id from reaching `app.current_account_id()`, where a failed cast would
      // silently resolve to null and make every policy deny instead of erroring.
      if (typeof accountID !== "string" || !ACCOUNT_ID_PATTERN.test(accountID)) {
        throw new TypeError("An account-scoped transaction requires a Supabase Auth user uuid.");
      }
      return sql.begin(async (tx) => {
        await tx`select set_config('app.account_id', ${accountID}, true)`;
        return work(tx);
      });
    },

    // Cheap liveness probe used by /health. Confirms both that the connection works and
    // that the migration has been applied, since an empty `app` schema is a silent failure.
    async check() {
      const [row] = await sql`
        select
          now() as server_time,
          (select count(*) from information_schema.tables where table_schema = 'app') as app_table_count,
          exists (
            select 1 from information_schema.columns
            where table_schema = 'app'
              and table_name = 'accounts'
              and column_name = 'signup_completed_at'
          )
          and exists (
            select 1 from information_schema.columns
            where table_schema = 'app'
              and table_name = 'accounts'
              and column_name = 'signup_completion_claim_id'
          )
          and to_regprocedure('public.grove_signup_completed()') is not null
          and to_regprocedure('public.grove_complete_signup(uuid)') is not null
            as signup_completion_ready
      `;
      return {
        serverTime: row.server_time.toISOString(),
        appTableCount: Number(row.app_table_count),
        signupCompletionReady: row.signup_completion_ready === true
      };
    },

    // `timeout` is how long in-flight queries get to finish before sockets are destroyed.
    async close({ timeout = 5 } = {}) {
      await sql.end({ timeout });
    }
  };
}
