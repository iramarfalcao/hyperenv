#!/bin/bash
# Packages HyperEnv.app into a compressed disk image.
#
# Deliberately built with hdiutil alone. The prettier layouts (background image,
# icon positions) are driven by AppleScript against the Finder, which needs a
# logged-in GUI session and fails on a headless CI runner — a release that only
# builds on someone's desk is not a release.
#
# Usage: Scripts/make-dmg.sh <path/to/HyperEnv.app> [version]
# Output: build/HyperEnv-<version>.dmg and a .sha256 next to it

set -euo pipefail

APP="${1:?usage: make-dmg.sh <path/to/HyperEnv.app> [version]}"
VERSION="${2:-${VERSION:-dev}}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${BUILD_DIR:-$REPO/build}"
DMG="$BUILD/HyperEnv-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

[ -d "$APP" ] || { echo "no app bundle at $APP"; exit 1; }
mkdir -p "$BUILD"
rm -f "$DMG"

cp -R "$APP" "$STAGE/HyperEnv.app"
ln -s /Applications "$STAGE/Applications"

# A plain-text reminder in the image itself: the download is not notarised, and
# the first-launch instructions have to be reachable without the README.
cat > "$STAGE/READ ME FIRST.txt" <<'EOF'
HyperEnv
========

1. Drag HyperEnv.app onto the Applications folder in this window.

2. The first launch is blocked by Gatekeeper, because this build is signed
   ad-hoc rather than with a paid Apple Developer ID. To allow it:

     Right-click HyperEnv.app in Applications -> Open -> Open

   or, from Terminal:

     xattr -dr com.apple.quarantine /Applications/HyperEnv.app

3. HyperEnv asks before it touches ~/.zprofile, backs the file up first, and
   writes only between its own markers. Nothing happens until you press
   "Install Hook".

Source, documentation and checksums: https://github.com/iramarfalcao/hyperenv
EOF

ICNS="$REPO/assets/HyperEnv.icns"
RW="$STAGE.rw.dmg"

echo "==> building $DMG"
# Built read-write first so the volume can be branded with the app's own icon,
# then converted to the compressed image that ships. Setting a volume icon
# requires touching the mounted filesystem; there is no hdiutil flag for it.
hdiutil create \
  -volname "HyperEnv $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$RW" >/dev/null

if [ -f "$ICNS" ]; then
  MOUNT="$(mktemp -d)"
  if hdiutil attach "$RW" -nobrowse -mountpoint "$MOUNT" >/dev/null 2>&1; then
    # Cosmetic only — a branding failure must never fail a release.
    cp "$ICNS" "$MOUNT/.VolumeIcon.icns" || true
    if command -v SetFile >/dev/null 2>&1; then
      SetFile -c icnC "$MOUNT/.VolumeIcon.icns" || true
      SetFile -a C "$MOUNT" || true
    else
      echo "note: SetFile unavailable, volume icon left unset"
    fi
    hdiutil detach "$MOUNT" >/dev/null || hdiutil detach "$MOUNT" -force >/dev/null || true
  else
    echo "note: could not mount the staging image, volume icon left unset"
  fi
  rmdir "$MOUNT" 2>/dev/null || true
fi

hdiutil convert "$RW" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$DMG" >/dev/null
rm -f "$RW"

echo "==> verifying"
hdiutil verify "$DMG" >/dev/null

# Run from the build directory so the checksum file names the file the way a
# verifier will have it on disk, not by absolute path.
name="$(basename "$DMG")"
(cd "$BUILD" && shasum -a 256 "$name" > "$name.sha256")

echo "==> done"
ls -lh "$DMG"
cat "$DMG.sha256"
