// Renders web/privacy.html from the policy that the app itself serves.
//
// There is exactly one source for the privacy policy, and it lives in
// supabase/functions/legal/index.ts. The app links this website, while the Edge
// Function can serve the same canonical text directly. Generating the page
// rather than re-typing it is the whole point: two public policies that quietly
// drift apart are a compliance problem, not a copywriting one.
//
//   node web/build-privacy.mjs        # rebuild, then commit the result
//
// Run it whenever the policy text changes, in the same commit.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, "..", "supabase", "functions", "legal", "index.ts"), "utf8");

// ------------------------------------------------------------------ extract

function constant(name) {
  const match = source.match(new RegExp(`const ${name} =[\\s\\S]*?"([^"]*)"`));
  if (!match) throw new Error(`Could not read ${name} from the legal function.`);
  return match[1];
}

const effectiveDate = constant("effectiveDate");

// The function prefers GROVE_LEGAL_CONTACT at runtime; the literal after the
// `||` is the published fallback, and that is the address this page prints.
const contactMatch = source.match(/const contactAddress =[\s\S]*?\|\|\s*"([^"]+)"/);
if (!contactMatch) throw new Error("Could not read the contact address fallback.");
const contactAddress = contactMatch[1];

const literal = source.match(/const privacyPolicy = `([\s\S]*?)\n`;/);
if (!literal) throw new Error("Could not find the privacyPolicy template literal.");

const policy = literal[1]
  .replace(/\$\{effectiveDate\}/g, effectiveDate)
  .replace(/\$\{contactAddress\}/g, contactAddress)
  .replace(/\\`/g, "`");

if (policy.includes("${")) {
  throw new Error("Unresolved template expression in the policy text.");
}

// -------------------------------------------------------------------- parse

const escape = (text) =>
  text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");

// The source is hand-wrapped at 76 columns because plain text has no reflow.
// The web does, so paragraphs are unwrapped back into single lines.
const unwrap = (lines) => lines.map((line) => line.trim()).join(" ").replace(/\s+/g, " ").trim();

const inline = (text) => {
  // The source is plain text, so its quotes and apostrophes are typewriter
  // marks. On a page that can set them properly, it should.
  let html = escape(text)
    .replace(/"([^"]+)"/g, "“$1”")
    .replace(/(?<=\w)'(?=\w)/g, "’")
    .replace(/(\S+@\S+\.\S+?)(?=[.,)]?(?:\s|$))/g, '<a href="mailto:$1">$1</a>')
    .replace(/\bprivacy\.org\.nz\b/g, '<a href="https://www.privacy.org.nz">privacy.org.nz</a>');
  return html;
};

const blocks = policy.split(/\n{2,}/).filter((block) => block.trim().length > 0);

const isHeading = (block) =>
  !block.includes("\n") && /^[A-Z][A-Z ,'\-—&]+$/.test(block.trim()) && block.trim().length > 3;

const html = [];
let seenFirstParagraph = false;

// Block 0 is the title and the effective date; the page renders those itself.
for (const block of blocks.slice(1)) {
  const lines = block.split("\n");
  const trimmed = block.trim();

  if (/^Effective /.test(trimmed)) continue;

  if (isHeading(block)) {
    html.push(`<h2>${escape(trimmed)}</h2>`);
    continue;
  }

  // The closing line, set apart from the policy proper.
  if (trimmed.startsWith("— Grove")) {
    html.push(`<p class="colophon">${inline(unwrap(lines))}</p>`);
    continue;
  }

  const indented = lines.every((line) => /^\s{2,}/.test(line));

  if (indented && lines.every((line) => /^\s*\*/.test(line) || /^\s{4,}/.test(line))) {
    // A bullet list. Items begin with "*"; deeper indents continue the item.
    const items = [];
    for (const line of lines) {
      if (/^\s*\*/.test(line)) items.push([line.replace(/^\s*\*\s?/, "")]);
      else if (items.length) items.at(-1).push(line);
    }
    html.push(`<ul>${items.map((item) => `<li>${inline(unwrap(item))}</li>`).join("")}</ul>`);
    continue;
  }

  if (indented) {
    // The postal block: short lines that mean their own line breaks.
    if (trimmed.includes("@") && /Limited/.test(trimmed)) {
      html.push(`<address>${lines.map((line) => inline(line.trim())).join("<br>")}</address>`);
      continue;
    }

    const nested = lines.some((line) => /^\s{4,}\S/.test(line));

    if (nested) {
      // A named processor: a title line, then labelled "Sent:"/"Why:" details.
      const entries = [];
      for (const line of lines) {
        if (/^\s{2}\S/.test(line)) entries.push({ title: line.trim(), body: [] });
        else if (entries.length) entries.at(-1).body.push(line);
      }
      for (const entry of entries) {
        const paragraphs = [];
        for (const line of entry.body) {
          if (/^\s*[A-Z][^:\n]{0,60}:/.test(line)) paragraphs.push([line]);
          else if (paragraphs.length) paragraphs.at(-1).push(line);
        }
        const rendered = paragraphs
          .map((paragraph) =>
            `<p>${inline(unwrap(paragraph)).replace(/^([A-Z][^:\n]{0,60}:)/, "<b>$1</b>")}</p>`
          )
          .join("");
        html.push(
          `<div class="entry"><p class="entry-title">${inline(entry.title)}</p>${rendered}</div>`
        );
      }
      continue;
    }

    // A jurisdiction: one indented paragraph opening with the place it covers.
    const text = inline(unwrap(lines)).replace(
      /^((?:New Zealand|UK and EU)\.)/,
      '<b>$1</b>'
    );
    html.push(`<div class="entry"><p>${text}</p></div>`);
    continue;
  }

  const text = inline(unwrap(lines));
  html.push(`<p${seenFirstParagraph ? "" : ' class="lead"'}>${text}</p>`);
  seenFirstParagraph = true;
}

// --------------------------------------------------------------------- page

const page = `<!DOCTYPE html>
<html lang="en-NZ">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Privacy policy — Grove</title>
<meta name="description" content="What Grove collects, where it goes, and how to get it back or have it deleted. ThinkingAI Limited, Auckland, New Zealand.">
<meta name="robots" content="index, follow">
<link rel="icon" href="/assets/favicon.png" type="image/png">
<link rel="apple-touch-icon" href="/assets/grove-icon.png">
<meta name="theme-color" content="#FAFBF8" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#14130F" media="(prefers-color-scheme: dark)">
<link rel="stylesheet" href="/styles.css">
</head>
<body>

<header class="masthead">
  <div class="wrap masthead-inner">
    <a class="brand" href="/">
      <img src="/assets/grove-mark.png" alt="Grove" width="30">
    </a>
    <nav>
      <a href="/">The app</a>
      <a href="mailto:${contactAddress}">Contact</a>
    </nav>
    <a class="cta cta--small" href="/">Back to Grove</a>
  </div>
</header>

<div class="wrap">
  <main class="policy">
    <div class="policy-head">
      <h1>Privacy policy</h1>
      <p class="effective">Effective ${effectiveDate}</p>
    </div>
${html.map((line) => `    ${line}`).join("\n")}
  </main>
</div>

<footer>
  <div class="wrap footer-inner">
    <div>
      <a class="brand" href="/">
        <img src="/assets/grove-mark.png" alt="Grove" width="26">
      </a>
      <p class="footer-org">Made by ThinkingAI&nbsp;Limited<br>Auckland, New Zealand</p>
    </div>
    <div class="footer-links">
      <a href="/">The app</a>
      <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">Terms</a>
      <a href="mailto:${contactAddress}">${contactAddress}</a>
    </div>
  </div>
</footer>

</body>
</html>
`;

writeFileSync(join(here, "privacy.html"), page);
console.log(`privacy.html — ${blocks.length} blocks, effective ${effectiveDate}, contact ${contactAddress}`);
