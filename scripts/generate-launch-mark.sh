#!/usr/bin/env bash
# Regenerates Grove/Assets.xcassets/LaunchMark.imageset from the 1024pt app icon,
# so the launch screen shows the same sculpted `g` the user just tapped.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$root"
swift scripts/generate-launch-mark.swift
