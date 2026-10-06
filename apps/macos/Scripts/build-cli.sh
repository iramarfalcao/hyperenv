#!/bin/bash
# Builds the `hyperenv` command (crates/cli, HyperEnv's Rust core) as one
# universal binary. It ships inside the app at Contents/Helpers/hyperenv —
# the editor plugins' door — and runs the same core as the window.
#
# Usage: Scripts/build-cli.sh [version] [output-path]
# Output: build/hyperenv (or output-path). The version comes from Cargo.toml;
# the argument is accepted for compatibility and only echoed.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$REPO/../.." && pwd)"
VERSION="${1:-dev}"
OUTPUT="${2:-$REPO/build/hyperenv}"

export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET="$(grep -m1 MACOSX_DEPLOYMENT_TARGET "$REPO/hyperenv.xcodeproj/project.pbxproj" | sed -E 's/.*= ([0-9.]+);/\1/')"

echo "==> building hyperenv ($VERSION) for macOS $MACOSX_DEPLOYMENT_TARGET"
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  rustup target list --installed 2>/dev/null | grep -qx "$target" || rustup target add "$target" >/dev/null
  cargo build --release -p hyperenv-cli --target "$target" --manifest-path "$ROOT/Cargo.toml"
done

mkdir -p "$(dirname "$OUTPUT")"
lipo -create -output "$OUTPUT" \
  "$ROOT/target/aarch64-apple-darwin/release/hyperenv" \
  "$ROOT/target/x86_64-apple-darwin/release/hyperenv"
chmod 755 "$OUTPUT"
echo "==> $OUTPUT  ($(lipo -archs "$OUTPUT"), $("$OUTPUT" version))"
