#!/bin/bash
# Builds the `hyperenv` command-line tool: universal, from the same Core,
# Engine and Models the app is built from.
#
# Usage: Scripts/build-cli.sh [version] [output-path]
# Output: build/hyperenv (or output-path)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/hyperenv"
VERSION="${1:-dev}"
OUTPUT="${2:-$REPO/build/hyperenv}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TARGET_OS="$(grep -m1 MACOSX_DEPLOYMENT_TARGET "$REPO/hyperenv.xcodeproj/project.pbxproj" | sed -E 's/.*= ([0-9.]+);/\1/')"

# The version is stamped at build time rather than kept in a source file, so
# a checkout never claims a version it is not.
printf 'nonisolated enum CLIVersion { static let string = "%s" }\n' "$VERSION" > "$WORK/Version.swift"

build() { # build <arch>
  xcrun swiftc -swift-version 6 -O \
    -target "$1-apple-macos$TARGET_OS" \
    -o "$WORK/hyperenv-$1" \
    "$APP"/Core/*.swift "$APP"/Engine/*.swift "$APP"/Models/*.swift \
    "$REPO"/cli/*.swift "$WORK/Version.swift"
}

echo "==> building hyperenv $VERSION for macOS $TARGET_OS"
build arm64
build x86_64

mkdir -p "$(dirname "$OUTPUT")"
lipo -create "$WORK/hyperenv-arm64" "$WORK/hyperenv-x86_64" -output "$OUTPUT"
chmod 755 "$OUTPUT"
echo "==> $OUTPUT  ($(lipo -archs "$OUTPUT"))"
