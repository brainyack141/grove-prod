// The bootstrap response is a *window* over history, not the whole of it.
//
// The old code ordered care history oldest-first and cut it at 500 rows, then
// took the newest 500 check-ins, with no way for the client to tell a complete
// list from a truncated one. The iPhone treats bootstrap as authoritative and
// replaced its local copy, so past the cap every sync deleted the user's older
// check-ins and care from the phone — silently. A generously sized window plus
// an explicit completeness flag lets the client keep local history the server
// simply did not send, while still trusting the server inside the window.
//
// Plain ESM with no Deno or npm imports so it can be unit-tested under Node.

/// Rows of history per kind per bootstrap. Deliberately generous: an account's
/// *open* care is unbounded and always sent in full, so this only bounds the
/// completed history a normal collector would need years to reach.
export const bootstrapHistoryLimit = 2000;

/// Given rows fetched with `limit + 1`, returns the visible slice and whether
/// that slice is the complete set. The extra row is a sentinel: its presence
/// means there is more history than the window, so `complete` is false and the
/// client must merge rather than replace. Order is preserved.
export function windowRows(rows, limit = bootstrapHistoryLimit) {
  return { rows: rows.slice(0, limit), complete: rows.length <= limit };
}
