// Orchestrates the irreversible parts of account deletion without depending on
// Deno, Supabase, or Postgres directly. Keeping the order here makes the edge
// route testable: storage must be scoped and removed in bounded batches before
// detached database rows are cleaned and the Auth identity is finally deleted.

export class AccountDeletionFailure extends Error {
  constructor(stage, cause) {
    super(`Account deletion failed during ${stage}.`);
    this.name = "AccountDeletionFailure";
    this.stage = stage;
    this.cause = cause;
  }
}

function scopedUniquePaths(accountID, rawPaths) {
  const prefix = `${accountID}/`;
  const paths = [];
  const seen = new Set();

  for (const rawPath of rawPaths ?? []) {
    const path = String(rawPath ?? "").trim();
    if (!path) continue;
    if (!path.startsWith(prefix) || path === prefix || path.includes("..")) {
      throw new AccountDeletionFailure("storage-scope", new Error("Storage path escaped the account prefix."));
    }
    if (!seen.has(path)) {
      seen.add(path);
      paths.push(path);
    }
  }
  return paths;
}

export async function deleteAccountData({
  accountID,
  loadStoragePaths,
  removeStoragePaths,
  cleanDetachedData,
  deleteIdentity,
  storageBatchSize = 100
}) {
  if (!accountID) throw new AccountDeletionFailure("identity", new Error("Missing account id."));
  if (!Number.isInteger(storageBatchSize) || storageBatchSize < 1 || storageBatchSize > 1_000) {
    throw new AccountDeletionFailure("storage-scope", new Error("Invalid storage batch size."));
  }

  let storagePaths;
  try {
    storagePaths = scopedUniquePaths(accountID, await loadStoragePaths(accountID));
  } catch (error) {
    if (error instanceof AccountDeletionFailure) throw error;
    throw new AccountDeletionFailure("storage-list", error);
  }

  for (let index = 0; index < storagePaths.length; index += storageBatchSize) {
    try {
      await removeStoragePaths(storagePaths.slice(index, index + storageBatchSize));
    } catch (error) {
      throw new AccountDeletionFailure("storage-remove", error);
    }
  }

  try {
    await cleanDetachedData(accountID);
  } catch (error) {
    throw new AccountDeletionFailure("database", error);
  }

  try {
    await deleteIdentity(accountID);
  } catch (error) {
    throw new AccountDeletionFailure("identity", error);
  }

  return { deleted: true, removedObjectCount: storagePaths.length };
}
