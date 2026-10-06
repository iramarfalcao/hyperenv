#!/bin/bash
#
# Builds HyperEnv 2's Rust core (crates/ffi) as one universal static library
# for the macOS app, and puts it with its header and module map in
# build/core/, where the Xcode project looks for them.
#
# Run by Xcode as a build phase, and by build-release.sh. Cheap when nothing
# changed: cargo rebuilds only what did.
#
# Usage: Scripts/build-core.sh [debug|release]

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$REPO/../.." && pwd)"
PROFILE="${1:-${CONFIGURATION:-release}}"
case "$(echo "$PROFILE" | tr '[:upper:]' '[:lower:]')" in
  debug) FLAG=""; DIR=debug ;;
  *) FLAG="--release"; DIR=release ;;
esac
OUT="$REPO/build/core"

# Xcode runs build phases with a minimal PATH.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v cargo >/dev/null || { echo "error: cargo not found — install Rust from https://rustup.rs"; exit 1; }

# Same floor as the app, so the linker does not warn about newer objects.
export MACOSX_DEPLOYMENT_TARGET="$(grep -m1 MACOSX_DEPLOYMENT_TARGET "$REPO/hyperenv.xcodeproj/project.pbxproj" | sed -E 's/.*= ([0-9.]+);/\1/')"

for target in aarch64-apple-darwin x86_64-apple-darwin; do
  rustup target list --installed 2>/dev/null | grep -qx "$target" || rustup target add "$target" >/dev/null
  cargo build $FLAG -p hyperenv-ffi --target "$target" --manifest-path "$ROOT/Cargo.toml"
done

mkdir -p "$OUT/include"
lipo -create -output "$OUT/libhyperenv_ffi.a" \
  "$ROOT/target/aarch64-apple-darwin/$DIR/libhyperenv_ffi.a" \
  "$ROOT/target/x86_64-apple-darwin/$DIR/libhyperenv_ffi.a"
cp "$ROOT/crates/ffi/include/hyperenv.h" "$ROOT/crates/ffi/include/module.modulemap" "$OUT/include/"
echo "core: $OUT/libhyperenv_ffi.a ($(lipo -archs "$OUT/libhyperenv_ffi.a"))"
