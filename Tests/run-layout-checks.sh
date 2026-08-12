#!/bin/bash
# Checks that no view asks for more width than a window can give it.
#
# A view that demands more width than the window has does not fail loudly — the
# split view simply cannot satisfy it, and the result is columns rendering with
# their content pushed off screen. That is indistinguishable from the data
# failing to load, so it is worth a check that states the real constraint.
#
# NSHostingView reports a fitting size without a window server, so this runs
# anywhere the app compiles.
#
# Usage: Tests/run-layout-checks.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/hyperenv"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -swift-version 6 -o "$OUT/layoutchecks" \
  "$APP"/Core/*.swift \
  "$APP"/Design/*.swift \
  "$APP"/Engine/*.swift \
  "$APP"/Models/*.swift \
  "$APP"/Views/*.swift \
  "$APP/ContentView.swift" \
  "$REPO/Tests/LayoutChecks/main.swift"

"$OUT/layoutchecks"
