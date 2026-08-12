#!/bin/bash
# Checks that an export carries the variables it says it does.
#
# The failure this guards against is silent: a profile whose variables are all
# switched off exported to a file containing only a comment header, which looks
# like a successful export until the file is opened.
#
# Usage: Tests/run-export-checks.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/hyperenv"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -swift-version 6 -o "$OUT/exportchecks" \
  "$APP"/Core/*.swift \
  "$APP"/Design/*.swift \
  "$APP"/Engine/*.swift \
  "$APP"/Models/*.swift \
  "$APP"/Views/*.swift \
  "$APP/ContentView.swift" \
  "$REPO/Tests/ExportChecks/main.swift"

"$OUT/exportchecks"
