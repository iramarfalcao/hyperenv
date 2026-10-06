#!/bin/bash
# Proves the `hyperenv` command against a throwaway store.
#
# The store is redirected with --store, so the app's real projects are never
# read or written. Apply, un-apply and the hook are NOT exercised here: they
# would write the real ~/.zprofile, and the engine suite already proves them
# against an in-memory filesystem. What this covers is the door the editor
# plugins depend on: the grammar, the JSON envelope, and every create / read /
# update / delete path.
#
# Usage: Tests/run-cli-checks.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$WORK" in
  "$HOME"|"$HOME"/*) echo "REFUSING: work dir is inside \$HOME"; exit 1 ;;
esac

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "building the command..."
"$REPO/Scripts/build-cli.sh" check "$WORK/hyperenv" >/dev/null
CLI="$WORK/hyperenv"
STORE="$WORK/store/checks.store"

pass=0
fail=0
check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL %s\n     expected: %q\n     actual:   %q\n' "$1" "$3" "$2"
  fi
}

# Runs a command in JSON mode and prints one field (a jq-ish path) from it.
# Exit status of the command is available as $status afterwards.
status=0
run() { # run <python-expression-on-doc> <args...>
  local expr="$1"; shift
  local raw
  set +e
  raw="$("$CLI" --json --store "$STORE" "$@" 2>&1)"
  status=$?
  set -e
  python3 -c '
import json, sys
try:
    doc = json.loads(sys.argv[1])
except Exception as e:
    print("NOT JSON: " + sys.argv[1][:200]); sys.exit(0)
d = doc
try:
    print(eval(sys.argv[2]))
except Exception as e:
    print("EVAL ERROR " + repr(e) + " on " + json.dumps(doc)[:200])
' "$raw" "$expr"
}

echo "--- grammar and envelope ---"
check "no arguments prints usage, exit 0" "$("$CLI" --store "$STORE" | head -1)" "hyperenv — the command behind the HyperEnv app and its editor plugins"
check "version is machine-readable" "$(run 'd["data"]["version"]' version)" "check"
check "unknown command is an error envelope" "$(run 'd["ok"]' nonsense)" "False"
set +e; "$CLI" --json --store "$STORE" nonsense >/dev/null 2>&1; code=$?; set -e
check "…with exit status 1" "$code" "1"
check "…and an error message" "$(run '"unknown command" in d["error"]' nonsense)" "True"

echo "--- empty store ---"
check "no projects yet" "$(run 'len(d["data"])' projects)" "0"
# Codable leaves a nil field out rather than writing null; plugins read it with .get().
check "status: nothing applied is absent, not an error" "$(run 'd["ok"] and d["data"].get("applied") is None' status)" "True"
check "status names the store it opened" "$(run 'd["data"]["store"]' status)" "$STORE"

echo "--- create project ---"
check "created with trimmed name" "$(run 'd["data"]["name"]' project create "  payments  ")" "payments"
PID="$(run 'd["data"][0]["id"]' projects)"
check "listed afterwards" "$(run 'd["data"][0]["name"]' projects)" "payments"
check "blank name is refused" "$(run 'd["ok"]' project create "   ")" "False"
check "still one project" "$(run 'len(d["data"])' projects)" "1"
check "project can be found by id" "$(run 'd["data"]["name"]' profile create --project "$PID" --name dev --kind dev)" "dev"

echo "--- create profile (environment) ---"
check "found by project name too" "$(run 'd["data"]["name"]' profile create --project payments --name prd --kind prd)" "prd"
check "kind defaults to custom" "$(run 'd["data"]["kind"]' profile create --project payments --name scratch)" "custom"
check "bad kind is refused" "$(run 'd["ok"]' profile create --project payments --name x --kind default)" "False"
check "missing name is refused" "$(run 'd["ok"]' profile create --project payments)" "False"
check "unknown project is refused" "$(run 'd["ok"]' profile create --project nope --name dev)" "False"
check "three profiles, in creation order" "$(run '[p["name"] for p in d["data"][0]["profiles"]]' projects)" "['dev', 'prd', 'scratch']"
check "a new profile can be applied" "$(run 'd["data"][0]["profiles"][0]["canBeApplied"]' projects)" "True"

echo "--- variables ---"
check "set creates" "$(run 'd["data"]["key"] + "=" + d["data"]["value"]' var set --project payments --profile dev API_URL=https://api.example.test)" "API_URL=https://api.example.test"
check "value may contain =" "$(run 'd["data"]["value"]' var set --project payments --profile dev QUERY=a=b=c)" "a=b=c"
check "set again updates in place" "$(run 'd["data"]["value"]' var set --project payments --profile dev API_URL=https://staging.example.test)" "https://staging.example.test"
check "…without creating a second row" "$(run 'len([v for v in d["data"] if v["key"]=="API_URL"])' vars --project payments --profile dev)" "1"
check "secret flag sticks" "$(run 'd["data"]["isSecret"]' var set --project payments --profile dev --secret TOKEN=s3cr3t)" "True"
check "disabled flag sticks" "$(run 'd["data"]["isEnabled"]' var set --project payments --profile dev --disabled OFF=1)" "False"
check "note sticks" "$(run 'd["data"]["note"]' var set --project payments --profile dev --note "why" WHY=1)" "why"
check "invalid name is refused" "$(run 'd["ok"]' var set --project payments --profile dev 1BAD=x)" "False"
check "missing = is refused" "$(run 'd["ok"]' var set --project payments --profile dev JUSTKEY)" "False"
check "vars lists in order" "$(run '[v["key"] for v in d["data"]]' vars --project payments --profile dev)" "['API_URL', 'QUERY', 'TOKEN', 'OFF', 'WHY']"
check "enabled count excludes the disabled one" "$(run 'd["data"][0]["profiles"][0]["enabledCount"]' projects)" "4"
check "disable" "$(run 'd["data"]["isEnabled"]' var disable --project payments --profile dev WHY)" "False"
check "enable" "$(run 'd["data"]["isEnabled"]' var enable --project payments --profile dev WHY)" "True"
check "unknown key is refused" "$(run 'd["ok"]' var enable --project payments --profile dev NOPE)" "False"
check "delete" "$(run 'd["data"]["deleted"]' var delete --project payments --profile dev QUERY)" "QUERY"
check "gone from the list" "$(run '[v["key"] for v in d["data"]]' vars --project payments --profile dev)" "['API_URL', 'TOKEN', 'OFF', 'WHY']"
check "text mode masks a secret" "$("$CLI" --store "$STORE" vars --project payments --profile dev | grep TOKEN)" "on  TOKEN=••••••"

echo "--- duplicate ---"
check "copy is named" "$(run 'd["data"]["name"]' profile duplicate --project payments --profile dev)" "dev copy"
check "copy carries every variable" "$(run 'len(d["data"])' vars --project payments --profile "dev copy")" "4"
check "copy is independent" "$(run 'd["data"]["value"]' var set --project payments --profile "dev copy" API_URL=changed)" "changed"
check "…original untouched" "$(run '[v["value"] for v in d["data"] if v["key"]=="API_URL"][0]' vars --project payments --profile dev)" "https://staging.example.test"

echo "--- ambiguity is an error, never a guess ---"
run '0' profile create --project payments --name twin >/dev/null
run '0' profile create --project payments --name twin >/dev/null
check "two profiles with one name: refused by name" "$(run 'd["ok"]' vars --project payments --profile twin)" "False"
check "…the error says to use the id" "$(run '"use the id" in d["error"]' vars --project payments --profile twin)" "True"
TWIN="$(run '[p["id"] for p in d["data"][0]["profiles"] if p["name"]=="twin"][0]' projects)"
check "…and the id works" "$(run 'd["ok"]' vars --project payments --profile "$TWIN")" "True"

echo "--- delete ---"
check "delete profile" "$(run 'd["data"]["deleted"]' profile delete --project payments --profile scratch)" "payments/scratch"
check "unknown profile is refused" "$(run 'd["ok"]' profile delete --project payments --profile scratch)" "False"
run '0' project create other >/dev/null
check "delete project" "$(run 'd["data"]["deleted"]' project delete --project other)" "other"
check "cascade: deleting the project removes its profiles" "$(run 'd["ok"]' project delete --project payments)" "True"
check "store is empty again" "$(run 'len(d["data"])' projects)" "0"

echo "--- the real store is never touched ---"
check "status still reports the throwaway store" "$(run 'd["data"]["store"] == "'"$STORE"'"' status)" "True"

echo
echo "passed: $pass"
if [ "$fail" -gt 0 ]; then echo "failed: $fail"; exit 1; fi
echo "ALL CLI CHECKS PASSED"
