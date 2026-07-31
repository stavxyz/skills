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

# make_repo <path> — init a repo with one commit, identity preset
make_repo() {
  git init -q "$1"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

test_checkouts() {
  local root="$TMP/root2" repo out
  mkdir -p "$root"
  repo="$root/demo"
  make_repo "$repo"
  printf '.claude/\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m gitignore
  git -C "$repo" worktree add -q "$repo/.claude/worktrees/wt1" -b wt1
  echo dirty > "$repo/.claude/worktrees/wt1/file.txt"

  out=$(CLAUDE_DIR="$TMP/does-not-exist" bash "$CENSUS" "$root") || fail "census exited non-zero (checkouts)"
  py_assert "$out" 'len(d["checkouts"]) == 2'
  py_assert "$out" 'sorted(c["is_worktree"] for c in d["checkouts"]) == [False, True]'
  py_assert "$out" '[c["dirty_count"] for c in d["checkouts"] if c["is_worktree"]] == [1]'
  py_assert "$out" '[c["dirty_count"] for c in d["checkouts"] if not c["is_worktree"]] == [0]'
  py_assert "$out" '[c["branch"] for c in d["checkouts"] if c["is_worktree"]] == ["wt1"]'
  py_assert "$out" 'all(c["live"] in (True, False) for c in d["checkouts"])'
  py_assert "$out" 'all(c["ahead"] is None and c["behind"] is None for c in d["checkouts"])'
  # no remote → every local branch counts as unpushed, on the primary only
  py_assert "$out" '"wt1" in [b for c in d["checkouts"] if not c["is_worktree"] for b in c["unpushed_branches"]]'
  py_assert "$out" '[c["unpushed_branches"] for c in d["checkouts"] if c["is_worktree"]] == [[]]'
  py_assert "$out" 'all(c["rescue_ref"] == "" and c["park_error"] == "" for c in d["checkouts"])'
}

test_checkouts_sibling() {
  local root="$TMP/root3" repo out
  mkdir -p "$root"
  repo="$root/sib"
  make_repo "$repo"
  printf '.claude/\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m gitignore
  # Create sibling worktree (not nested under .claude/), within find's -maxdepth 2 reach
  git -C "$repo" worktree add -q "$root/sib-wt" -b sibwt
  echo dirty > "$root/sib-wt/file.txt"

  out=$(CLAUDE_DIR="$TMP/does-not-exist" bash "$CENSUS" "$root") || fail "census exited non-zero (sibling)"
  py_assert "$out" 'len(d["checkouts"]) == 2'
  py_assert "$out" '[c["is_worktree"] for c in d["checkouts"] if c["path"].endswith("/sib")] == [False]'
  py_assert "$out" '[c["is_worktree"] for c in d["checkouts"] if c["path"].endswith("/sib-wt")] == [True]'
  # unpushed_branches on primary (/sib), empty on worktree (/sib-wt)
  py_assert "$out" '[c["unpushed_branches"] for c in d["checkouts"] if c["path"].endswith("/sib")] != [[]]'
  py_assert "$out" '[c["unpushed_branches"] for c in d["checkouts"] if c["path"].endswith("/sib-wt")] == [[]]'
}

test_sessions_and_probes
test_checkouts
test_checkouts_sibling

echo
if [[ $FAILS -eq 0 ]]; then echo "ALL PASS"; exit 0; else echo "$FAILS failure(s)"; exit 1; fi
