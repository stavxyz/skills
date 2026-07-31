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

# park_checkout's commit-tree call has no -c user.name/user.email of its own
# (it shells out to plain `git commit-tree`), so it falls back to git's
# configured identity. Export it here rather than relying on the machine
# having one set — a fresh/CI machine with no global git identity would
# otherwise fail every parking assertion in this file for a reason that has
# nothing to do with census.sh's correctness.
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

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

test_park() {
  local root="$TMP/root4" repo out before after ref
  mkdir -p "$root"
  repo="$root/parkme"
  make_repo "$repo"
  echo tracked-orig > "$repo/tracked.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m add-tracked
  echo tracked-edit > "$repo/tracked.txt"
  echo untracked > "$repo/untracked.txt"

  # default run is read-only: no refs created
  out=$(CLAUDE_DIR="$TMP/does-not-exist" bash "$CENSUS" "$root") || fail "census exited non-zero (pre-park)"
  if [[ -z "$(git -C "$repo" for-each-ref refs/rescue)" ]]; then
    pass "no rescue refs without --park"
  else
    fail "rescue refs created without --park"
  fi

  # --park run: ref created, zero-touch, both files captured
  before=$(git -C "$repo" status --porcelain)
  out=$(CLAUDE_DIR="$TMP/does-not-exist" bash "$CENSUS" --park "$root") || fail "census exited non-zero (--park)"
  after=$(git -C "$repo" status --porcelain)
  if [[ "$before" == "$after" ]]; then pass "zero-touch: status identical"; else fail "git status changed across --park"; fi

  ref=$(git -C "$repo" for-each-ref --format='%(refname)' refs/rescue/pre-reboot | head -1)
  if [[ -n "$ref" ]]; then pass "rescue ref exists"; else fail "no rescue ref after --park"; fi
  if [[ "$(git -C "$repo" show "$ref:tracked.txt" 2>/dev/null)" == "tracked-edit" ]]; then
    pass "rescue ref captured tracked edit"
  else
    fail "tracked edit missing from rescue ref"
  fi
  if [[ "$(git -C "$repo" show "$ref:untracked.txt" 2>/dev/null)" == "untracked" ]]; then
    pass "rescue ref captured untracked file"
  else
    fail "untracked file missing from rescue ref"
  fi
  py_assert "$out" '[c for c in d["checkouts"] if c["dirty_count"] > 0][0]["rescue_ref"].startswith("refs/rescue/pre-reboot/")'
  py_assert "$out" 'd["park"] == True'

  # clean checkout: parking skipped even with --park
  py_assert "$out" 'all(c["rescue_ref"] == "" for c in d["checkouts"] if c["dirty_count"] == 0)'

  # dirty LINKED WORKTREE parks too (spec's canonical test case): the temp
  # index must work when -C points at a worktree, not just a primary
  git -C "$repo" worktree add -q "$repo/.claude/worktrees/wtpark" -b wtpark
  echo wt-tracked-edit > "$repo/.claude/worktrees/wtpark/tracked.txt"
  echo wt-untracked > "$repo/.claude/worktrees/wtpark/wtfile.txt"
  before=$(git -C "$repo/.claude/worktrees/wtpark" status --porcelain)
  out=$(CLAUDE_DIR="$TMP/does-not-exist" bash "$CENSUS" --park "$root") || fail "census exited non-zero (worktree park)"
  after=$(git -C "$repo/.claude/worktrees/wtpark" status --porcelain)
  if [[ "$before" == "$after" ]]; then pass "zero-touch on worktree"; else fail "worktree status changed across --park"; fi
  ref=$(git -C "$repo" for-each-ref --format='%(refname)' 'refs/rescue/pre-reboot/wtpark-*' | head -1)
  if [[ -n "$ref" ]]; then pass "worktree rescue ref exists"; else fail "no rescue ref for dirty worktree"; fi
  if [[ "$(git -C "$repo" show "$ref:wtfile.txt" 2>/dev/null)" == "wt-untracked" ]]; then
    pass "worktree rescue ref captured untracked file"
  else
    fail "untracked file missing from worktree rescue ref"
  fi
  if [[ "$(git -C "$repo" show "$ref:tracked.txt" 2>/dev/null)" == "wt-tracked-edit" ]]; then
    pass "worktree rescue ref captured tracked edit"
  else
    fail "tracked edit missing from worktree rescue ref"
  fi

  # unborn HEAD (repo with no commits) degrades into not_parked
  git init -q "$root/unborn"
  echo x > "$root/unborn/f.txt"
  out=$(CLAUDE_DIR="$TMP/does-not-exist" bash "$CENSUS" --park "$root") || fail "census exited non-zero (unborn)"
  py_assert "$out" 'any("unborn" in n["error"] for n in d["not_parked"])'
  py_assert "$out" '[c["park_error"] for c in d["checkouts"] if c["path"].endswith("/unborn")] != [""]'
}

# same-basename primary + linked worktree, both dirty: rescue ref names must
# be collision-proof (path-derived uniquifier), or the second park silently
# overwrites the first's ref in the shared ref store.
test_park_ref_collision() {
  local root="$TMP/root5" repo wt out refs nrefs primary_ref wt_ref r
  mkdir -p "$root/otherdir"
  repo="$root/proj"
  make_repo "$repo"
  echo primary-orig > "$repo/f.txt"
  git -C "$repo" add f.txt
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m add-f
  echo primary-edit > "$repo/f.txt"

  wt="$root/otherdir/proj"
  git -C "$repo" worktree add -q "$wt" -b projwt
  echo wt-edit > "$wt/f.txt"

  out=$(CLAUDE_DIR="$TMP/does-not-exist" bash "$CENSUS" --park "$root") || fail "census exited non-zero (ref collision)"

  refs=$(git -C "$repo" for-each-ref --format='%(refname)' 'refs/rescue/pre-reboot/proj-*')
  nrefs=$(printf '%s\n' "$refs" | grep -c .)
  if [[ "$nrefs" -eq 2 ]]; then
    pass "two distinct rescue refs for same-basename checkouts"
  else
    fail "expected 2 rescue refs for same-basename checkouts, got $nrefs: $refs"
  fi

  primary_ref=""
  wt_ref=""
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    case "$(git -C "$repo" show "$r:f.txt" 2>/dev/null)" in
      primary-edit) primary_ref="$r" ;;
      wt-edit) wt_ref="$r" ;;
    esac
  done <<<"$refs"

  if [[ -n "$primary_ref" ]]; then pass "a ref contains the primary's own content"; else fail "no ref contains primary-edit content"; fi
  if [[ -n "$wt_ref" ]]; then pass "a ref contains the worktree's own content"; else fail "no ref contains wt-edit content"; fi
  if [[ -n "$primary_ref" && -n "$wt_ref" && "$primary_ref" != "$wt_ref" ]]; then
    pass "same-basename checkouts got distinct refs"
  else
    fail "same-basename checkouts collapsed onto the same ref"
  fi

  py_assert "$out" '[c["rescue_ref"] for c in d["checkouts"] if c["path"].endswith("/proj")][0].startswith("refs/rescue/pre-reboot/proj-")'
  py_assert "$out" '[c["rescue_ref"] for c in d["checkouts"] if c["path"].endswith("otherdir/proj")][0].startswith("refs/rescue/pre-reboot/proj-")'
}

# `git status` failure (unreadable index) must degrade — never read as clean.
test_git_status_failure() {
  local root="$TMP/root6" repo out errfile err
  # root reads through chmod 000 (CAP_DAC_OVERRIDE / superuser), so this
  # assertion's premise ("unreadable index") doesn't hold when run as root.
  [[ $EUID -eq 0 ]] && { echo "skip: running as root, chmod 000 is not enforced"; return; }
  mkdir -p "$root"
  repo="$root/broken"
  make_repo "$repo"
  errfile="$TMP/root6-stderr"
  chmod 000 "$repo/.git/index"

  out=$(CLAUDE_DIR="$TMP/does-not-exist" bash "$CENSUS" "$root" 2>"$errfile") || fail "census exited non-zero (status failure)"
  err=$(cat "$errfile" 2>/dev/null)

  py_assert "$out" '[c["dirty_count"] for c in d["checkouts"] if c["path"].endswith("/broken")] == [None]'
  py_assert "$out" 'any(n["path"].endswith("/broken") for n in d["not_parked"])'
  case "$err" in
    *"git status failed"*"$repo"*) pass "stderr reports the git status failure" ;;
    *) fail "stderr missing git status failure message; got: $err" ;;
  esac

  chmod 644 "$repo/.git/index"
}

# ahead/behind orientation: a checkout with LOCAL commits not yet pushed
# (ahead) and a REMOTE commit fetched-but-not-merged (behind) must report
# each count on its own side — a swapped left/right in the rev-list format
# string would silently transpose these and no other assertion catches it.
test_ahead_behind() {
  local root="$TMP/root7" bare work other out
  mkdir -p "$root"
  bare="$root/origin.git"
  git init -q --bare "$bare"
  work="$root/work"
  git clone -q "$bare" "$work"
  git -C "$work" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$work" push -q -u origin HEAD

  # a second clone simulates another contributor pushing a commit to origin
  # that "work" has not seen yet
  other="$TMP/ahead-behind-other"
  git clone -q "$bare" "$other"
  git -C "$other" -c user.email=t@t -c user.name=t commit -q --allow-empty -m remote-only
  git -C "$other" push -q origin HEAD

  # 2 local unpushed commits in "work", then fetch (never merge) the
  # remote-only commit — this is the canonical diverged-branch shape
  git -C "$work" -c user.email=t@t -c user.name=t commit -q --allow-empty -m local-1
  git -C "$work" -c user.email=t@t -c user.name=t commit -q --allow-empty -m local-2
  git -C "$work" fetch -q origin

  out=$(CLAUDE_DIR="$TMP/does-not-exist" bash "$CENSUS" "$root") || fail "census exited non-zero (ahead/behind)"
  py_assert "$out" '[c["ahead"] for c in d["checkouts"] if c["path"].endswith("/work")] == [2]'
  py_assert "$out" '[c["behind"] for c in d["checkouts"] if c["path"].endswith("/work")] == [1]'
}

# discovery failure: an unreadable .git dir must degrade into a not_parked
# entry, not vanish silently from the census.
test_discovery_failure() {
  local root="$TMP/root8" repo out
  # root reads through chmod 000, so the premise doesn't hold as superuser.
  [[ $EUID -eq 0 ]] && { echo "skip: running as root, chmod 000 is not enforced"; return; }
  mkdir -p "$root"
  repo="$root/lockedout"
  make_repo "$repo"
  chmod 000 "$repo/.git"

  out=$(CLAUDE_DIR="$TMP/does-not-exist" bash "$CENSUS" "$root" 2>/dev/null) || fail "census exited non-zero (discovery failure)"
  py_assert "$out" 'any("worktree list failed" in n["error"] for n in d["not_parked"])'

  chmod 755 "$repo/.git"
}

# hostile path: a checkout dir containing a space AND a double quote must
# round-trip through JSON exactly — this is the one case json_escape's
# quote-escaping exists for.
test_hostile_path() {
  local root="$TMP/root9" repo out
  mkdir -p "$root"
  repo="$root/we\"ird dir"
  make_repo "$repo"

  out=$(CLAUDE_DIR="$TMP/does-not-exist" bash "$CENSUS" "$root") || fail "census exited non-zero (hostile path)"
  py_assert "$out" 'any(c["path"].endswith("we\"ird dir") for c in d["checkouts"])'
}

test_sessions_and_probes
test_checkouts
test_checkouts_sibling
test_park
test_park_ref_collision
test_git_status_failure
test_ahead_behind
test_discovery_failure
test_hostile_path

echo
if [[ $FAILS -eq 0 ]]; then echo "ALL PASS"; exit 0; else echo "$FAILS failure(s)"; exit 1; fi
