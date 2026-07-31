#!/usr/bin/env bash
# test-census.sh — automated checks for skills/reboot-ready/census.sh.
#
# Run: bash tests/reboot-ready/test-census.sh
# Exit: 0 all assertions pass, 1 otherwise. Sandboxed in mktemp -d; never
# touches real repos or ~/.claude (census.sh honors CLAUDE_DIR).
set -uo pipefail

CENSUS="$(cd "$(dirname "$0")/../.." && pwd)/skills/reboot-ready/census.sh"
FAILS=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }

# py_assert <json> <python-expr>  — expr sees the parsed JSON as `d`
py_assert() {
  if printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); assert ($2), d" 2>/dev/null; then
    pass "$2"
  else
    fail "$2"
  fi
}

test_sessions_and_probes() {
  local cdir="$TMP/claude" root="$TMP/empty-root" out
  mkdir -p "$cdir/jobs/job1" "$root"
  printf '{"sessionId":"sess-abc","cwd":"/Users/nobody/.claude/worktrees/proj"}' > "$cdir/jobs/job1/state.json"

  out=$(CLAUDE_DIR="$cdir" bash "$CENSUS" "$root") || fail "census exited non-zero"
  py_assert "$out" 'd["probes"]["jobs_scan"] == "ran"'
  py_assert "$out" 'd["probes"]["lsof"] in ("ran","unavailable","errored")'
  py_assert "$out" "d[\"roots\"] == [\"$root\"]"
  py_assert "$out" 'd["park"] == False'
  py_assert "$out" 'd["checkouts"] == [] and d["not_parked"] == []'
  py_assert "$out" 'd["sessions"]["jobs"][0]["id"] == "job1"'
  py_assert "$out" 'd["sessions"]["jobs"][0]["session_id"] == "sess-abc"'
  py_assert "$out" 'd["sessions"]["jobs"][0]["transcript"].endswith("projects/-Users-nobody--claude-worktrees-proj/sess-abc.jsonl")'
  py_assert "$out" 'isinstance(d["sessions"]["jobs"][0]["mtime"], int)'
  py_assert "$out" 'isinstance(d["sessions"]["processes"], list)'

  # jobs dir missing entirely → probe reports unavailable, not an empty "ran"
  out=$(CLAUDE_DIR="$TMP/does-not-exist" bash "$CENSUS" "$root") || fail "census exited non-zero (no jobs dir)"
  py_assert "$out" 'd["probes"]["jobs_scan"] == "unavailable"'
  py_assert "$out" 'd["sessions"]["jobs"] == []'
}

test_sessions_and_probes

echo
if [[ $FAILS -eq 0 ]]; then echo "ALL PASS"; exit 0; else echo "$FAILS failure(s)"; exit 1; fi
