#!/bin/bash
# Drives the real ApplyEngine through apply / re-apply / un-apply / remove-hook
# against an in-memory filesystem and a scripted probe.
#
# Nothing under $HOME is read or written: the filesystem is a fake and the
# advisory lock is taken on a temporary file. This is the suite that proves
# the journal, the once-only backup and the once-only hook install — the
# promises the shell suite has to take on trust.
#
# Usage: Tests/run-engine-checks.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/hyperenv"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -swift-version 6 -o "$OUT/enginechecks" \
  "$APP"/Core/*.swift \
  "$APP"/Engine/*.swift \
  "$APP"/Models/*.swift \
  "$REPO/Tests/EngineChecks/main.swift"

"$OUT/enginechecks"
