#!/bin/bash
# Renders the real window offscreen and reports what AppKit actually built.
#
# See Scripts/CaptureWindow/main.swift for why this exists and what parts of its
# output can be trusted. Short version: it reports how many columns the split
# view built, dumps the view tree, and writes a PNG.
#
# Usage: Scripts/capture-window.sh <output-dir> [path/to/a/COPY/of/default.store]
#
# Exits non-zero if the split view did not build three columns.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/hyperenv"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -swift-version 6 -o "$OUT/capture" \
  "$APP"/Core/*.swift \
  "$APP"/Design/*.swift \
  "$APP"/Engine/*.swift \
  "$APP"/Models/*.swift \
  "$APP"/Views/*.swift \
  "$APP/ContentView.swift" \
  "$REPO/Scripts/CaptureWindow/main.swift"

"$OUT/capture" "$@"
