#!/bin/bash
# Runs the pure-Core verification suite.
#
# The Core layer has no I/O, so it can be compiled and exercised directly with
# swiftc — no simulator, no app bundle, no test host. Everything here operates
# on fixture strings.
#
# Usage: Tests/run-core-checks.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/hyperenv/Core"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

> "$OUT/sources"
for file in "$SRC"/*.swift; do echo "$file" >> "$OUT/sources"; done

xcrun swiftc -swift-version 6 -o "$OUT/corechecks" \
  $(cat "$OUT/sources") \
  "$REPO/Tests/CoreChecks/main.swift"

"$OUT/corechecks"
