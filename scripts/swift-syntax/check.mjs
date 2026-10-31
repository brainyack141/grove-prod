// Parses Swift sources with tree-sitter and reports syntax errors.
// This is a grammar-level check only — it does not type-check, resolve
// imports, or verify API signatures. It catches unbalanced braces, malformed
// declarations and broken expressions.
import Parser from "tree-sitter";
import Swift from "tree-sitter-swift";
import { readFileSync } from "node:fs";

// Valid Swift the bundled grammar does not model yet. Each entry is a real
// language feature, not a bug being suppressed — without this the gate would be
// permanently red on correct code and get ignored. Re-check when the grammar
// is upgraded.
//
// A gap is matched against the line the ERROR starts on, which is the tightest
// match available. Anything broader — matching the whole unparsed subtree, say
// — forgives every error inside it, and a construct the grammar cannot model
// tends to swallow the entire enclosing type: `switch try await` used to be
// listed here that way, and the entry was wide enough that injecting a real
// syntax error anywhere in the same file went unreported. There is no
// subtree-scoped forgiveness for that reason. When the grammar cannot parse
// valid Swift and no line-tight pattern exists, prefer rewriting the construct
// (`let x = try await …` then `switch x`) over widening the gate.
const GRAMMAR_GAPS = [
  { pattern: /nonisolated\s*\(\s*unsafe\s*\)/, note: "nonisolated(unsafe) — Swift 5.10 concurrency attribute" },
  { pattern: /^#(?:if|elseif|else|endif)\b/, note: "conditional-compilation directives inside declarations" },
  { pattern: /^}\s*catch\s+[A-Za-z_][\w.]*,\s*$/, note: "Swift multi-pattern catch clauses" },
];

const parser = new Parser();
parser.setLanguage(Swift);

const files = process.argv.slice(2);
let bad = 0;
const skipped = new Set();

for (const file of files) {
  const source = readFileSync(file, "utf8");
  const tree = parser.parse(source);
  const problems = [];

  const visit = (node) => {
    if (node.type === "ERROR" || node.isMissing) {
      problems.push({
        type: node.isMissing ? "MISSING" : "ERROR",
        line: node.startPosition.row + 1,
        text: source.split("\n")[node.startPosition.row]?.trim().slice(0, 90) ?? "",
      });
      return; // don't descend into a broken subtree
    }
    for (let i = 0; i < node.childCount; i++) visit(node.child(i));
  };
  visit(tree.rootNode);

  for (let i = problems.length - 1; i >= 0; i--) {
    const gap = GRAMMAR_GAPS.find((entry) => entry.pattern.test(problems[i].text));
    if (gap) {
      skipped.add(gap.note);
      problems.splice(i, 1);
    }
  }

  if (problems.length) {
    bad++;
    console.log(`\n✗ ${file}`);
    for (const p of problems.slice(0, 10)) {
      console.log(`    ${p.type} line ${p.line}: ${p.text}`);
    }
    if (problems.length > 10) console.log(`    …and ${problems.length - 10} more`);
  } else {
    console.log(`✓ ${file}`);
  }
}

console.log(`\n${files.length - bad}/${files.length} files parsed clean`);
for (const note of skipped) {
  console.log(`  (ignored known grammar gap: ${note})`);
}
console.log("  Grammar-level only — xcodebuild remains the authority on types and APIs.");
process.exit(bad ? 1 : 0);
