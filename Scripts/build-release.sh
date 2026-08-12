#!/bin/bash
# Builds a distributable HyperEnv.app.
#
# The archive is universal (arm64 + x86_64) and ad-hoc signed by default, which
# is what a public repository can honestly produce: there is no Developer ID
# certificate in CI, and shipping a *deliberately* ad-hoc signed build is more
# truthful than shipping an unsigned one that macOS refuses to launch on Apple
# silicon at all.
#
# Set SIGN_IDENTITY to a "Developer ID Application: …" identity to produce a
# build that can then be notarised.
#
# Usage: Scripts/build-release.sh [version]
# Output: build/export/HyperEnv.app

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${BUILD_DIR:-$REPO/build}"
ARCHIVE="$BUILD/HyperEnv.xcarchive"
EXPORT="$BUILD/export"

VERSION="${1:-${VERSION:-}}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$BUILD"

version_flags=()
if [ -n "$VERSION" ]; then
  version_flags+=("MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
fi

echo "==> archiving (identity: $SIGN_IDENTITY)"
xcodebuild archive \
  -project "$REPO/hyperenv.xcodeproj" \
  -scheme hyperenv \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  "${version_flags[@]}" \
  | grep -E 'error:|warning:.*\.swift|ARCHIVE|BUILD' || true

APP="$ARCHIVE/Products/Applications/HyperEnv.app"
[ -d "$APP" ] || { echo "archive produced no app at $APP"; exit 1; }

mkdir -p "$EXPORT"
cp -R "$APP" "$EXPORT/HyperEnv.app"

# The archive step signs, but re-signing here is what makes the *whole* bundle
# consistent after the copy, and it is the seam a Developer ID identity plugs
# into without any other change.
echo "==> signing"
codesign --force --options runtime --timestamp=none \
  --sign "$SIGN_IDENTITY" "$EXPORT/HyperEnv.app"
codesign --verify --deep --strict --verbose=2 "$EXPORT/HyperEnv.app"

echo "==> architectures"
lipo -archs "$EXPORT/HyperEnv.app/Contents/MacOS/HyperEnv"

echo "==> done: $EXPORT/HyperEnv.app"
