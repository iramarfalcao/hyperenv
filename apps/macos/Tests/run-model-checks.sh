#!/bin/bash
# Proves the create / duplicate / import rules and the profile -> snapshot
# mapping against an in-memory SwiftData store.
#
# This is the same `Authoring` code the New Project, New Profile, Duplicate,
# Add Variable and Import buttons run — the suite exists so those rules are
# proven by a script rather than by clicking.
#
# Usage: Tests/run-model-checks.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/hyperenv"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -swift-version 6 -o "$OUT/modelchecks" \
  "$APP"/Core/*.swift \
  "$APP"/Models/*.swift \
  "$REPO/Tests/ModelChecks/main.swift"

"$OUT/modelchecks"
