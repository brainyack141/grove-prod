import assert from "node:assert/strict";
import test from "node:test";
import {
  AccountDeletionFailure,
  deleteAccountData
} from "../account-deletion.mjs";

test("account deletion scopes, de-duplicates, and batches every stored object before deleting identity", async () => {
  const accountID = "a0e24564-4cf5-4b9c-a8a1-faae9198cdf6";
  const paths = Array.from({ length: 205 }, (_, index) => `${accountID}/${index}`);
  const batches = [];
  const order = [];

  const result = await deleteAccountData({
    accountID,
    loadStoragePaths: async () => [paths[0], "", ...paths, paths[0]],
    removeStoragePaths: async (batch) => {
      order.push("storage");
      batches.push(batch);
    },
    cleanDetachedData: async () => order.push("database"),
    deleteIdentity: async () => order.push("identity"),
    storageBatchSize: 100
  });

  assert.deepEqual(batches.map((batch) => batch.length), [100, 100, 5]);
  assert.equal(new Set(batches.flat()).size, 205);
  assert.deepEqual(order.slice(-2), ["database", "identity"]);
  assert.equal(order.indexOf("database") > order.lastIndexOf("storage"), true);
  assert.deepEqual(result, { deleted: true, removedObjectCount: 205 });
});

test("account deletion rejects an object outside the authenticated account prefix", async () => {
  let removed = false;
  let identityDeleted = false;

  await assert.rejects(
    deleteAccountData({
      accountID: "account-a",
      loadStoragePaths: async () => ["account-b/private-photo"],
      removeStoragePaths: async () => { removed = true; },
      cleanDetachedData: async () => {},
      deleteIdentity: async () => { identityDeleted = true; }
    }),
    (error) => error instanceof AccountDeletionFailure && error.stage === "storage-scope"
  );

  assert.equal(removed, false);
  assert.equal(identityDeleted, false);
});

test("account deletion never removes the identity after storage or database cleanup fails", async () => {
  for (const failurePoint of ["storage", "database"]) {
    let identityDeleted = false;
    await assert.rejects(
      deleteAccountData({
        accountID: "account-a",
        loadStoragePaths: async () => ["account-a/photo"],
        removeStoragePaths: async () => {
          if (failurePoint === "storage") throw new Error("storage unavailable");
        },
        cleanDetachedData: async () => {
          if (failurePoint === "database") throw new Error("database unavailable");
        },
        deleteIdentity: async () => { identityDeleted = true; }
      }),
      (error) => error instanceof AccountDeletionFailure
        && error.stage === (failurePoint === "storage" ? "storage-remove" : "database")
    );
    assert.equal(identityDeleted, false);
  }
});
