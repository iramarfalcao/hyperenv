#!/bin/bash
#
# HyperEnv installer — https://hyperenv.falcaosl.com
#
#   curl -fsSL https://hyperenv.falcaosl.com/install.sh | bash
#
# Uses Homebrew when it is present, and falls back to downloading the disk image
# when it is not, so the same command works either way.
#
# What it does, in order:
#   1. checks you are on a macOS new enough to run the app
#   2. installs, either through Homebrew or from the published disk image
#   3. verifies the download against the SHA-256 published with the release
#   4. removes the quarantine attribute, which is what otherwise blocks the
#      first launch of a build signed ad-hoc rather than with a Developer ID
#
# It never uses sudo, never writes outside /Applications and Homebrew's own
# directories, and prints every step it takes. Running it twice is harmless.
#
# If you would rather read it before running it — which is a reasonable thing to
# want of any script piped into a shell:
#
#   curl -fsSL https://hyperenv.falcaosl.com/install.sh -o install.sh
#   less install.sh
#   bash install.sh
#

set -euo pipefail

REPO="iramarfalcao/hyperenv"
TAP="iramarfalcao/hyperenv"
APP_NAME="HyperEnv.app"
APPDIR="${HYPERENV_APPDIR:-/Applications}"
DMG_URL="https://github.com/$REPO/releases/latest/download/HyperEnv.dmg"
SUM_URL="https://github.com/$REPO/releases/latest/download/HyperEnv.dmg.sha256"
MIN_MAJOR=26
MIN_MINOR=5

bold=$(tput bold 2>/dev/null || true)
dim=$(tput dim 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true)
green=$(tput setaf 2 2>/dev/null || true)
reset=$(tput sgr0 2>/dev/null || true)

step() { printf '%s==>%s %s\n' "$green$bold" "$reset$bold" "$1$reset"; }
info() { printf '    %s%s%s\n' "$dim" "$1" "$reset"; }
die()  { printf '%serror:%s %s\n' "$red$bold" "$reset" "$1" >&2; exit 1; }

# --- 1. Is this machine able to run it? --------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "HyperEnv is a macOS app; this is $(uname -s)."

os="$(sw_vers -productVersion)"
os_major="${os%%.*}"
os_rest="${os#*.}"
os_minor="${os_rest%%.*}"
[ "$os_minor" = "$os" ] && os_minor=0

if [ "$os_major" -lt "$MIN_MAJOR" ] ||
   { [ "$os_major" -eq "$MIN_MAJOR" ] && [ "$os_minor" -lt "$MIN_MINOR" ]; }; then
  die "HyperEnv needs macOS $MIN_MAJOR.$MIN_MINOR or later. This is $os."
fi

step "macOS $os on $(uname -m)"

# --- 2. Install ---------------------------------------------------------------

install_with_homebrew() {
  step "Installing with Homebrew"

  if brew tap | grep -qx "$TAP"; then
    info "tap already present"
  else
    info "tapping $TAP"
    brew tap "$TAP" "https://github.com/$REPO"
  fi

  # Homebrew refuses to load a cask from a third-party tap until it is trusted,
  # and refuses with an error rather than a prompt — so this is not optional.
  info "trusting the tap"
  brew trust "$TAP" >/dev/null 2>&1 || true

  if brew list --cask hyperenv >/dev/null 2>&1; then
    info "already installed — upgrading if there is anything newer"
    brew upgrade --cask hyperenv || true
  else
    brew install --cask hyperenv
  fi
}

install_from_disk_image() {
  step "Installing from the published disk image"
  info "Homebrew was not found, so this downloads the release directly"

  work="$(mktemp -d)"
  trap 'rm -rf "$work"; [ -n "${mount:-}" ] && hdiutil detach "$mount" -quiet 2>/dev/null || true' EXIT

  info "downloading HyperEnv.dmg"
  curl -fsSL "$DMG_URL" -o "$work/HyperEnv.dmg" || die "download failed"

  # Verify before mounting. A checksum checked after the fact is decoration.
  info "verifying the checksum published with the release"
  curl -fsSL "$SUM_URL" -o "$work/HyperEnv.dmg.sha256" 2>/dev/null \
    || die "could not fetch the published checksum; refusing to install unverified"

  # First field of the first line only, then checked for shape. Without this a
  # server returning something that is not a checksum file at all — an error
  # page, a redirect notice — gets spliced into the comparison and the failure
  # reads as gibberish instead of as "that was not a checksum".
  expected="$(head -n 1 "$work/HyperEnv.dmg.sha256" | awk '{print $1}')"
  case "$expected" in
    [0-9a-f]|[0-9a-f][0-9a-f]*)
      [ "${#expected}" -eq 64 ] || die "the published checksum is not a SHA-256; refusing to install" ;;
    *) die "the published checksum could not be read; refusing to install" ;;
  esac

  actual="$(shasum -a 256 "$work/HyperEnv.dmg" | awk '{print $1}')"
  if [ "$expected" != "$actual" ]; then
    die "checksum mismatch — refusing to install
    expected $expected
    actual   $actual"
  fi
  info "checksum ok"

  mount="$work/mnt"
  mkdir -p "$mount"
  info "mounting"
  hdiutil attach "$work/HyperEnv.dmg" -nobrowse -readonly -mountpoint "$mount" -quiet

  [ -d "$mount/$APP_NAME" ] || die "the disk image does not contain $APP_NAME"

  info "copying to $APPDIR"
  rm -rf "${APPDIR:?}/$APP_NAME"
  cp -R "$mount/$APP_NAME" "$APPDIR/$APP_NAME"

  hdiutil detach "$mount" -quiet
  mount=""
}

if command -v brew >/dev/null 2>&1; then
  install_with_homebrew
else
  install_from_disk_image
fi

# --- 3. Make the first launch work -------------------------------------------

app="$APPDIR/$APP_NAME"
[ -d "$app" ] || app="$(brew --prefix 2>/dev/null)/Caskroom/hyperenv/*/$APP_NAME"
app="$(ls -d $app 2>/dev/null | head -1 || true)"
[ -n "$app" ] && [ -d "$app" ] || die "installed, but $APP_NAME was not found in $APPDIR"

step "Clearing the quarantine attribute"
info "releases are signed ad-hoc rather than with a paid Apple Developer ID,"
info "so macOS blocks the first launch until this attribute is removed"
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true

# --- 4. Done ------------------------------------------------------------------

version="$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")"

cat <<EOS

${green}${bold}HyperEnv $version is installed.${reset}

  ${bold}open -a HyperEnv${reset}

The app asks before it touches anything. It adds three lines to ~/.zprofile,
but only when you press "Install Hook", and it backs the file up first.

  Docs      https://github.com/$REPO
  Uninstall brew uninstall --cask hyperenv   (or drag it to the Trash)

EOS
