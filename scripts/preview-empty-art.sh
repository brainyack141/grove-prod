#!/usr/bin/env bash
# Renders every empty-state scene into build/empty-art/ as a light and a dark
# contact sheet, so the artwork can be reviewed as one set.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$(mktemp -d)/preview-empty-art"

swiftc -O -parse-as-library \
  "$root/scripts/preview-empty-art.swift" \
  "$root/scripts/preview-empty-art-stub.swift" \
  "$root/Grove/GroveEmptyArt.swift" \
  -o "$binary"

"$binary"
