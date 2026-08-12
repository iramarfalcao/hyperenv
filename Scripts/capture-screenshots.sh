#!/bin/bash
# Captures the app window in light and dark appearance for the site.
#
# Needs Screen Recording permission for whichever terminal runs it:
#   System Settings → Privacy & Security → Screen & System Audio Recording
# Grant it, then quit and reopen the terminal — the permission is read at launch,
# so an already-running process keeps being denied until it restarts.
#
# The window is captured by its window ID rather than by cropping the screen, so
# the result is exactly the window with its shadow and nothing else — no desktop,
# no other apps, no coordinates to get wrong.
#
# Usage: Scripts/capture-screenshots.sh [path/to/HyperEnv.app]

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/site/assets"
APP="${1:-/Applications/HyperEnv.app}"

[ -d "$APP" ] || { echo "No app at $APP"; exit 1; }
mkdir -p "$OUT"

# Fail early and clearly rather than producing empty files.
probe="$(mktemp -t hyperenv-probe).png"
trap 'rm -f "$probe"' EXIT
if ! screencapture -x -o "$probe" 2>/dev/null || [ ! -s "$probe" ]; then
  cat <<'EOS'
Screen Recording permission is not granted to this terminal.

  System Settings → Privacy & Security → Screen & System Audio Recording
  → enable your terminal → quit it completely → reopen → run this again.

EOS
  exit 1
fi

original="$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo Light)"
restore() {
  if [ "$original" = "Dark" ]; then
    osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to true' >/dev/null 2>&1 || true
  else
    osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to false' >/dev/null 2>&1 || true
  fi
}
trap 'restore; rm -f "$probe"' EXIT

window_id() {
  # The frontmost on-screen window belonging to HyperEnv. Printed by a helper
  # because there is no shell command that reports window IDs.
  osascript -l JavaScript <<'JXA' 2>/dev/null
ObjC.import('CoreGraphics');
ObjC.import('Foundation');
const info = $.CFBridgingRelease(
  $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0));
const list = ObjC.deepUnwrap(info);
for (const w of list) {
  if (w.kCGWindowOwnerName === 'HyperEnv' && w.kCGWindowLayer === 0 &&
      w.kCGWindowBounds.Height > 300) {
    console.log(String(w.kCGWindowNumber));
    break;
  }
}
JXA
}

shoot() { # shoot <appearance> <output>
  local mode="$1" file="$2"

  if [ "$mode" = "dark" ]; then
    osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to true' >/dev/null
  else
    osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to false' >/dev/null
  fi

  open -a "$APP"
  sleep 3   # the window redraws its materials after an appearance change

  local id
  id="$(window_id)"
  [ -n "$id" ] || { echo "Could not find a HyperEnv window. Is it open?"; exit 1; }

  screencapture -x -o -l "$id" "$file"
  [ -s "$file" ] || { echo "Capture produced nothing for $mode"; exit 1; }
  echo "  $mode: $file ($(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ {printf "%s ", $2}'))"
}

echo "==> Capturing"
shoot light "$OUT/screenshot-light.png"
shoot dark "$OUT/screenshot-dark.png"

echo
echo "Update the width and height on the hero <img> in site/index.html to match:"
sips -g pixelWidth -g pixelHeight "$OUT/screenshot-light.png" | tail -2
