// Shared database helpers for the durable-store tests.
//
// Accounts are Supabase Auth identities: `app.accounts.id` is a uuid
// referencing `auth.users`, and the `on_auth_user_created` trigger provisions
// the account, its Grove and its membership. Tests therefore create an auth
// user and let the trigger do the rest, exactly as a real signup does — the
// service itself never mints accounts.
//
// Cleanup is scoped to the accounts a test owns rather than truncating the
// schema: `node --test` runs files in parallel, and a shared `truncate` made
// the suites delete each other's fixtures — passing alone and failing together.

/// Creates an auth user and returns the account uuid the trigger provisioned.
export async function createTestAccount(sql, { email, name = "Test Gardener" } = {}) {
  const address = email ?? `test-${Math.floor(Math.random() * 1e12)}@example.test`;
  const [user] = await sql`
    insert into auth.users (email, raw_user_meta_data)
    values (${address}, ${sql.json({ full_name: name })})
    returning id
  `;
  return user.id;
}

/// Removes every trace of the given accounts, in foreign-key order.
/// `app.groves`, `app.observations` and friends reference `app.accounts` with
/// NO ACTION, so the owning rows have to go before the account itself.
export async function resetAccounts(sql, accountIDs) {
  const ids = accountIDs.filter(Boolean);
  if (!ids.length) return;
  await sql`delete from app.sitting_assignments where owner_account_id = any(${ids}) or sitter_account_id = any(${ids})`;
  await sql`delete from app.activity_events where actor_account_id = any(${ids})`;
  // Cascades to plants, and from there to care actions, observations,
  // health assessments, assignment membership and plant media.
  await sql`delete from app.groves where owner_account_id = any(${ids})`;
  await sql`delete from app.media_assets where owner_account_id = any(${ids})`;
  await sql`delete from app.observations where performed_by_account_id = any(${ids})`;
  await sql`delete from app.care_actions where performed_by_account_id = any(${ids})`;
  // Deleting the auth user cascades app.accounts, and from there friendships,
  // idempotency records, media uploads and memberships.
  await sql`delete from auth.users where id = any(${ids})`;
}
