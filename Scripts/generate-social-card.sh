#!/bin/bash
# Draws site/assets/og-image.jpg, the card shown when the site is shared.
#
# Usage: Scripts/generate-social-card.sh

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -swift-version 6 -O -o "$OUT/card" "$REPO/Scripts/GenerateSocialCard/main.swift"
"$OUT/card" "$REPO/assets/icon-1024.png" "$REPO/site/assets/og-image.jpg"
