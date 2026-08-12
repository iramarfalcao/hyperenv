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

# An unversioned build (CI on a branch) leaves this empty, and /bin/bash on
# macOS is 3.2, where expanding an empty array under `set -u` is an error — so
# the expansion below is guarded rather than plain "${version_flags[@]}".
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
  ${version_flags[@]+"${version_flags[@]}"} \
  | grep -E 'error:|warning:.*\.swift|ARCHIVE|BUILD' || true

APP="$ARCHIVE/Products/Applications/HyperEnv.app"
[ -d "$APP" ] || { echo "archive produced no app at $APP"; exit 1; }

mkdir -p "$EXPORT"
cp -R "$APP" "$EXPORT/HyperEnv.app"

# The archive step signs, but re-signing here is what makes the *whole* bundle
# consistent after the copy, and it is the seam a Developer ID identity plugs
# into without any other change.
#
# The timestamp is the part that matters for distribution. Apple's notary
# service rejects a signature without a secure timestamp, so `--timestamp=none`
# — which is right for ad-hoc, where no timestamp authority is involved and the
# request would only slow the build — must not be used with a real identity.
if [ "$SIGN_IDENTITY" = "-" ]; then
  timestamp_flag="--timestamp=none"
else
  timestamp_flag="--timestamp"
fi

echo "==> signing (timestamp: ${timestamp_flag#--timestamp})"
codesign --force --options runtime "$timestamp_flag" \
  --sign "$SIGN_IDENTITY" "$EXPORT/HyperEnv.app"
codesign --verify --strict --verbose=2 "$EXPORT/HyperEnv.app"

# Catches the failure that otherwise only surfaces at the notary service.
if [ "$SIGN_IDENTITY" != "-" ]; then
  echo "==> checking the signature is distributable"
  codesign --display --verbose=4 "$EXPORT/HyperEnv.app" 2>&1 | grep -q "^Timestamp=" || {
    echo "signature carries no secure timestamp; notarization would reject it"
    exit 1
  }
  codesign --test-requirement="=notarized" --verify --verbose=2 \
    "$EXPORT/HyperEnv.app" 2>/dev/null \
    && echo "already notarized" \
    || echo "not yet notarized (expected before the notary step)"
fi

echo "==> architectures"
lipo -archs "$EXPORT/HyperEnv.app/Contents/MacOS/HyperEnv"

echo "==> done: $EXPORT/HyperEnv.app"
