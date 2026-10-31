#!/usr/bin/env python3
"""Build Grove's bundled plant-safety catalogue from an open, licensed source.

Grove can only show a safety answer it can cite. The hand-curated records in
`PlantSafety.swift` cover the plants the app was built around, but a scan of
almost any other houseplant used to fall through to "Not verified". This script
turns the Growli plant-toxicity table (CC-BY 4.0, ASPCA-sourced) into a compact
name-keyed lookup that ships in the app bundle, so a scanned plant gets a real,
sourced verdict offline and without a round trip.

The output is intentionally dumb: a normalised scientific name mapped to a
verdict and a short cited detail. Matching is by scientific name only — common
names are ambiguous exactly where a confident mistake is expensive.

Usage:
    python3 scripts/build-plant-safety.py [--input plant-toxicity.json]

Without --input the Growli table is downloaded. The result is committed so the
app build never needs the network.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
import unicodedata
import urllib.request
from pathlib import Path

SOURCE_URL = "https://www.getgrowli.app/data/plant-toxicity/plant-toxicity.json"
OUTPUT_PATH = Path("Grove/Resources/PlantSafetyCatalogue.json")

# Severity order is the whole safety contract: when the same normalised name
# carries more than one verdict, the most severe one wins. A source that
# disagrees with itself must never resolve to the reassuring answer.
SEVERITY = {
    "Pet-safe (no ASPCA toxic principle listed)": 0,
    "Mildly toxic": 1,
    "Toxic": 2,
}

VERDICT = {
    "Pet-safe (no ASPCA toxic principle listed)": "noKnownToxicity",
    "Mildly toxic": "irritant",
    "Toxic": "harmful",
}

VERDICT_DETAIL = {
    "noKnownToxicity": "No toxic principle is listed for cats or dogs in the checked ASPCA records.",
    "irritant": "Listed as mildly toxic — chewing usually causes mouth or stomach irritation.",
    "harmful": "Listed as toxic to cats or dogs in the checked ASPCA records.",
}

# A parenthetical may name a synonym the app's identification can return instead
# of the accepted name. Keep both keys so a syn. resolves to the same record.
SYNONYM = re.compile(r"\((?:syn\.?|formerly|was)\s+([^)]+)\)", re.IGNORECASE)
PARENTHETICAL = re.compile(r"\((?:[^()]*)\)")
# Curly and double quotes fold to a straight apostrophe first, matching
# PlantSafetyCatalogue.normalizedName, so 'Hope' and ‘Hope’ strip alike.
QUOTES = re.compile(r"[\u2018\u2019\u201C\u201D\"]")
CULTIVAR = re.compile(r"'[^']*'")
RANK = re.compile(r"\b(?:var|subsp|ssp|cv|f|nothosubsp|nothovar)\.", re.IGNORECASE)
SPECIES_QUALIFIER = re.compile(r"\b(?:spp?|sp|hybrid|hybrids)\b", re.IGNORECASE)
WHITESPACE = re.compile(r"\s+")
SENTENCE = re.compile(r"(?<=[.!?])\s+")


def normalise(name: str) -> str:
    """Mirror of PlantSafetyCatalogue's Swift normaliser. Keep the two in step."""
    text = QUOTES.sub("'", name or "")
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    text = CULTIVAR.sub(" ", text)
    text = SYNONYM.sub(" ", text)
    text = PARENTHETICAL.sub(" ", text)
    text = RANK.sub(" ", text)
    text = SPECIES_QUALIFIER.sub(" ", text)
    text = re.sub(r"[^a-z0-9 ]+", " ", text.lower())
    return WHITESPACE.sub(" ", text).strip()


def short_detail(detail: str, fallback: str, limit: int = 220) -> str:
    text = WHITESPACE.sub(" ", (detail or "").strip())
    if not text:
        return fallback
    # First sentence, unless it is a stub, then a bounded prefix. The card shows
    # one line; a paragraph of toxicology would push the audience chips off the
    # fold and never get read.
    first = SENTENCE.split(text)[0].strip()
    if 40 <= len(first) <= limit:
        return first
    if len(text) <= limit:
        return text
    clipped = text[:limit].rsplit(" ", 1)[0].rstrip(",;:")
    return f"{clipped}…"


def keys_for(botanical_name: str):
    keys = set()
    primary = normalise(botanical_name)
    if primary:
        keys.add(primary)
    for match in SYNONYM.finditer(botanical_name or ""):
        synonym = normalise(match.group(1))
        if synonym:
            keys.add(synonym)
    return keys


def friendly_date(value: str | None) -> str:
    """Match the hand-curated sources' "4 September 2026" wording."""
    if not value:
        return "unknown"
    try:
        parsed = datetime.date.fromisoformat(str(value)[:10])
    except ValueError:
        return "unknown"
    return f"{parsed.day} {parsed.strftime('%B')} {parsed.year}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", help="Local plant-toxicity.json (downloads when omitted)")
    arguments = parser.parse_args()

    if arguments.input:
        raw = Path(arguments.input).read_bytes()
    else:
        print(f"▸ Downloading {SOURCE_URL}")
        request = urllib.request.Request(
            SOURCE_URL, headers={"user-agent": "Grove build script; https://grove.app"}
        )
        with urllib.request.urlopen(request, timeout=120) as response:
            raw = response.read()

    payload = json.loads(raw)
    rows = payload["data"] if isinstance(payload, dict) else payload

    records: dict[str, dict] = {}
    for row in rows:
        toxicity = row.get("toxicity") or ""
        if toxicity not in SEVERITY:
            continue
        verdict = VERDICT[toxicity]
        severity = SEVERITY[toxicity]
        detail = short_detail(row.get("toxicityDetail", ""), VERDICT_DETAIL[verdict])
        for key in keys_for(row.get("botanicalName", "")):
            existing = records.get(key)
            if existing is None or severity > existing["severity"]:
                records[key] = {
                    "scientificName": row.get("botanicalName", "").strip(),
                    "v": verdict,
                    "d": detail,
                    "severity": severity,
                }

    ordered = {
        key: {"scientificName": record["scientificName"], "v": record["v"], "d": record["d"]}
        for key, record in sorted(records.items())
    }
    document = {
        "license": "CC-BY 4.0",
        "creditText": (
            "Plant-toxicity reference compiled by Growli (getgrowli.app), CC-BY 4.0, "
            "from the ASPCA Toxic and Non-Toxic Plants database and US extension services."
        ),
        "sourceURL": "https://www.getgrowli.app/data/plant-toxicity",
        "reviewedOn": friendly_date(
            payload.get("lastVerified") if isinstance(payload, dict) else None
        ),
        "recordCount": len(ordered),
        "records": ordered,
    }

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    # No pretty printing: this file ships in the binary, and the reader is
    # Swift, not a person.
    OUTPUT_PATH.write_text(json.dumps(document, separators=(",", ":"), ensure_ascii=False))
    size_kb = OUTPUT_PATH.stat().st_size / 1024
    counts: dict[str, int] = {}
    for record in ordered.values():
        counts[record["v"]] = counts.get(record["v"], 0) + 1
    print(f"▸ Wrote {len(ordered)} records ({size_kb:.0f} KB) to {OUTPUT_PATH}")
    for verdict, count in sorted(counts.items()):
        print(f"    {verdict}: {count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
