#!/bin/bash
# Exercises the generated scripts with a REAL zsh, in an isolated ZDOTDIR.
#
# This is the check that matters: the Core unit tests prove the strings are
# built correctly, but only a real shell proves that sourcing them produces the
# environment we promised — and that un-applying puts the previous values back.
#
# The user's own ~/.zprofile is never read or written. ZDOTDIR redirects zsh to
# a temporary directory instead.
#
# Usage: Tests/run-shell-integration.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/hyperenv/Core"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Refuse to run anywhere near the real home directory.
case "$WORK" in
  "$HOME"|"$HOME"/*) echo "REFUSING: work dir is inside \$HOME"; exit 1 ;;
esac

pass=0
fail=0
check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n     expected: %q\n     actual:   %q\n' "$1" "$3" "$2"
  fi
}

echo "building fixtures..."
xcrun swiftc -swift-version 6 -o "$WORK/renderfixtures" \
  "$SRC"/*.swift "$REPO/Tests/RenderFixtures/main.swift" >/dev/null
"$WORK/renderfixtures" "$WORK" >/dev/null

# A login zsh reads $ZDOTDIR/.zprofile, so this fully isolates the test.
run_zsh() { ZDOTDIR="$WORK" HOME="$WORK" zsh -l -c "$1"; }

echo "--- applied state ---"
check "override wins over the user's earlier export" \
  "$(run_zsh 'printf %s "$PRE_EXISTING"')" "applied value"
check "new variable is present" \
  "$(run_zsh 'printf %s "$BRAND_NEW"')" "hello world"
# ANSI-C quoting: no parameter expansion, and \' is a literal apostrophe.
TRICKY_EXPECTED=$'it\'s got $DOLLAR and #hash'
check "values with quotes, \$ and # survive the shell" \
  "$(run_zsh 'printf %s "$TRICKY"')" "$TRICKY_EXPECTED"
check "unrelated variable is untouched" \
  "$(run_zsh 'printf %s "$UNTOUCHED"')" "leave me alone"
check "empty variable can be given a value" \
  "$(run_zsh 'printf %s "$EMPTY_ONE"')" "now set"

echo "--- bypass guard ---"
check "HYPERENV_DISABLE makes the session file a no-op" \
  "$(HYPERENV_DISABLE=1 ZDOTDIR="$WORK" HOME="$WORK" zsh -l -c 'printf %s "$PRE_EXISTING"')" \
  "original value"
check "bypass leaves new variables unset" \
  "$(HYPERENV_DISABLE=1 ZDOTDIR="$WORK" HOME="$WORK" zsh -l -c 'printf %s "${BRAND_NEW-UNSET}"')" \
  "UNSET"

echo "--- un-apply restores, not just unsets ---"
check "overridden variable returns to its ORIGINAL value" \
  "$(run_zsh 'source '"$WORK"'/unsession.zsh; printf %s "$PRE_EXISTING"')" "original value"
check "added variable is fully unset, not blanked" \
  "$(run_zsh 'source '"$WORK"'/unsession.zsh; printf %s "${BRAND_NEW-UNSET}"')" "UNSET"
check "a variable that WAS empty returns to empty, not unset" \
  "$(run_zsh 'source '"$WORK"'/unsession.zsh; printf %s "${EMPTY_ONE-UNSET}"')" ""
check "un-apply leaves unrelated variables alone" \
  "$(run_zsh 'source '"$WORK"'/unsession.zsh; printf %s "$UNTOUCHED"')" "leave me alone"

echo "--- dotfile integrity ---"
check "removing the block restores the file byte for byte" \
  "$(cmp -s "$WORK/zprofile.restored" "$WORK/zprofile.original" && echo same || echo different)" \
  "same"
check "PATH is not altered by applying" \
  "$(run_zsh 'printf %s "$PATH"')" \
  "$(HYPERENV_DISABLE=1 ZDOTDIR="$WORK" HOME="$WORK" zsh -l -c 'printf %s "$PATH"')"

echo
echo "passed: $pass"
if [ "$fail" -gt 0 ]; then
  echo "failed: $fail"
  exit 1
fi
echo "ALL SHELL CHECKS PASSED"
