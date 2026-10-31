import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  bootstrapHistoryLimit,
  windowRows
} from "../../supabase/functions/_shared/bootstrap-history.mjs";

const apiURL = new URL("../../supabase/functions/api/index.ts", import.meta.url);

test("windowRows returns the slice and whether it is complete", () => {
  for (const count of [0, 1999, 2000]) {
    const rows = Array.from({ length: count }, (_, index) => ({ id: index }));
    const window = windowRows(rows);
    assert.equal(window.rows.length, count);
    assert.equal(window.complete, true);
    assert.deepEqual(window.rows.map((row) => row.id), rows.map((row) => row.id));
  }

  for (const count of [2001, 3000]) {
    const rows = Array.from({ length: count }, (_, index) => ({ id: index }));
    const window = windowRows(rows);
    assert.equal(window.rows.length, bootstrapHistoryLimit);
    assert.equal(window.complete, false);
    // Order is preserved; the first (newest, as the server queries it) rows stay.
    assert.deepEqual(window.rows[0], { id: 0 });
    assert.deepEqual(window.rows.at(-1), { id: 1999 });
  }
});

test("a 1000-row history is complete while a 2500-row one is the newest window", () => {
  // Newest first, the order the observations bootstrap query returns.
  const thousand = Array.from({ length: 1000 }, (_, index) => ({ id: index }));
  const small = windowRows(thousand.slice(0, bootstrapHistoryLimit + 1));
  assert.equal(small.rows.length, 1000);
  assert.equal(small.complete, true);
  assert.deepEqual(small.rows.map((row) => row.id), thousand.map((row) => row.id));

  const thousands = Array.from({ length: 2500 }, (_, index) => ({ id: index }));
  const large = windowRows(thousands.slice(0, bootstrapHistoryLimit + 1));
  assert.equal(large.rows.length, 2000);
  assert.equal(large.complete, false);
  assert.deepEqual(large.rows.map((row) => row.id), thousands.slice(0, 2000).map((row) => row.id));
});

test("bootstrap windows completed care and observations instead of dropping them", async () => {
  const source = await readFile(apiURL, "utf8");

  assert.match(source, /from "\.\.\/_shared\/bootstrap-history\.mjs"/);
  assert.match(source, /status = 'completed'[\s\S]*order by coalesce\(action\.performed_at, action\.due_from\) desc nulls last/);
  assert.doesNotMatch(source, /order by action\.due_from asc nulls last\s*\n\s*limit 500/);
  assert.match(source, /const tasks = \[\.\.\.openTasks, \.\.\.completedTasks\.rows\]/);
  assert.match(source, /limit \$\{bootstrapHistoryLimit \+ 1\}/);
  assert.match(source, /windowRows\(observationRows\)/);
  assert.match(source, /tasksComplete: snapshot\.tasksComplete/);
  assert.match(source, /observationsComplete: snapshot\.observationsComplete/);
});
