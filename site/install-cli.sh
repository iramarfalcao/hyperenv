#!/bin/sh
#
# hyperenv command installer (macOS, Linux) — https://hyperenv.falcaosl.com
#
#   curl -fsSL https://hyperenv.falcaosl.com/install-cli.sh | sh
#
# Installs the `hyperenv` command from HyperEnv 2 (pre-release). For the macOS
# app, use install.sh instead.
#
# What it does, in order:
#   1. picks the build for this system and processor
#   2. finds the newest `cli-v*` release on GitHub (or HYPERENV_VERSION)
#   3. downloads it and checks it against the published SHA256SUMS
#   4. puts the binary in ~/.local/bin (or HYPERENV_BIN_DIR)
#
# It never uses sudo, writes nowhere else, and running it twice is harmless.
# Read it first if you like:
#
#   curl -fsSL https://hyperenv.falcaosl.com/install-cli.sh -o install-cli.sh
#   less install-cli.sh
#   sh install-cli.sh

set -eu

REPO="iramarfalcao/hyperenv"
BIN_DIR="${HYPERENV_BIN_DIR:-$HOME/.local/bin}"

step() { printf '==> %s\n' "$1"; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "this installer needs '$1'."; }

need curl
need tar
need uname

# --- 1. Which build? -----------------------------------------------------------

os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Darwin) target="universal-apple-darwin" ;;
  Linux)
    case "$arch" in
      x86_64 | amd64) target="x86_64-unknown-linux-musl" ;;
      aarch64 | arm64) target="aarch64-unknown-linux-musl" ;;
      *) die "no Linux build for $arch yet." ;;
    esac
    ;;
  *) die "this installer is for macOS and Linux. On Windows, use install.ps1." ;;
esac

# --- 2. Which version? ---------------------------------------------------------

if [ -n "${HYPERENV_VERSION:-}" ]; then
  tag="cli-v${HYPERENV_VERSION#cli-v}"
else
  step "Looking up the newest release"
  # The releases list includes pre-releases, newest first; the command's tags
  # start with cli-v (the app's own releases use v*).
  tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30" |
    grep -o '"tag_name": *"cli-v[^"]*"' | head -n 1 | sed 's/.*"\(cli-v[^"]*\)"/\1/')"
  [ -n "$tag" ] || die "no release of the hyperenv command was found."
fi
version="${tag#cli-v}"
name="hyperenv-$version-$target"
base="https://github.com/$REPO/releases/download/$tag"

# --- 3. Download and verify ----------------------------------------------------

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

step "Downloading $name"
curl -fsSL "$base/$name.tar.gz" -o "$tmp/$name.tar.gz" || die "download failed: $base/$name.tar.gz"
curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS" || die "could not download the checksums."

step "Checking the SHA-256"
expected="$(grep " $name.tar.gz\$" "$tmp/SHA256SUMS" | cut -d ' ' -f 1)"
[ -n "$expected" ] || die "$name.tar.gz is not listed in SHA256SUMS."
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$tmp/$name.tar.gz" | cut -d ' ' -f 1)"
else
  actual="$(shasum -a 256 "$tmp/$name.tar.gz" | cut -d ' ' -f 1)"
fi
[ "$expected" = "$actual" ] || die "checksum mismatch — the download was not installed."

# --- 4. Install ----------------------------------------------------------------

tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
mkdir -p "$BIN_DIR"
install -m 0755 "$tmp/$name/hyperenv" "$BIN_DIR/hyperenv"
# Downloaded with curl there is no quarantine flag, but clear it if a browser
# put one there, so macOS does not block the first run.
[ "$os" = "Darwin" ] && xattr -d com.apple.quarantine "$BIN_DIR/hyperenv" 2>/dev/null || true

step "Installed hyperenv $version in $BIN_DIR"
case ":$PATH:" in
  *":$BIN_DIR:"*) "$BIN_DIR/hyperenv" version ;;
  *)
    printf '\n%s is not on your PATH. Add this line to your shell startup file:\n\n' "$BIN_DIR"
    # shellcheck disable=SC2016 # the literal $PATH is what the user should paste
    printf '    export PATH="%s:$PATH"\n\n' "$BIN_DIR"
    ;;
esac
printf 'Next: hyperenv profile create dev && hyperenv var set dev API_URL=http://localhost:8080 && hyperenv apply dev\n'
