#!/usr/bin/env bash
# Parses the app's Swift sources and fails on syntax errors.
#
# This is a grammar-level check only: it does not type-check, resolve imports or
# verify API signatures — `xcodebuild` remains the authority. It exists because
# Linux CI and cloud dev environments have no Swift toolchain, so an unbalanced
# brace or malformed declaration would otherwise reach a macOS runner (or a
# reviewer) before anything noticed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root/scripts/swift-syntax"

if [ ! -d node_modules ]; then
  npm install --silent --no-audit --no-fund
fi

source_roots=(
  "$root/Grove"
  "$root/GroveWatch"
  "$root/GroveWatchShared"
  "$root/GroveWatchWidget"
  "$root/GroveTests"
  "$root/GroveWatchTests"
  "$root/GroveUITests"
)

files=()
while IFS= read -r file; do
  files+=("$file")
done < <(find "${source_roots[@]}" -name '*.swift' | sort)
node check.mjs "${files[@]}"
