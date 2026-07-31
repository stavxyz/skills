---
type: plan
validated:
  sha: ae741bbf03671eadb6e5318199f119b534aba33c
  date: 2026-07-31T05:38:39Z
  reviewers: [fact-check, solid-hygiene]
  findings:
    critical: 2
    important: 1
    medium: 5
    low: 5
    nitpick: 1
  net_negative_remaining: 0
---

# /reboot-ready Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `/stavxyz:reboot-ready` skill that sweeps the machine before a reboot — running Claude Code sessions, dirty checkouts, unpushed branches — parks dirty state as zero-touch rescue refs, and writes a resume manifest.

**Architecture:** Two layers per the blessed spec (`docs/superpowers/specs/2026-07-30-reboot-ready-skill-design.md`): a deterministic bash script (`census.sh`) that emits one JSON document and optionally (`--park`) creates rescue refs via a temporary git index, and a SKILL.md judgment layer where Claude summarizes running sessions from transcripts and writes `~/.claude/reboot-manifest.md` + `.json`.

**Tech Stack:** bash (macOS 3.2-compatible), git plumbing (`read-tree`/`write-tree`/`commit-tree`/`update-ref`), `lsof`, `python3` (JSON parsing only), Claude Code plugin skill conventions from this repo.

## Global Constraints

- Scripts use `set -uo pipefail` and **never** `set -e` — spec requires degrade-don't-abort; per-item failures are recorded inside the JSON, exit code stays 0.
- macOS `/bin/bash` is 3.2: no bash-4 features (no associative arrays, no `${var,,}`); empty arrays under `set -u` must expand via `${arr[@]+"${arr[@]}"}`.
- `stat -f %m` (BSD) with `stat -c %Y` (GNU) fallback for mtimes.
- `python3` may be used for JSON parsing/assertions; `jq` must NOT be a dependency.
- Zero-touch invariant: any `census.sh` invocation leaves `git status --porcelain` output byte-identical in every swept checkout; the real index, working trees, and branches are never modified.
- Parking is opt-in via `--park`; refs go only under `refs/rescue/pre-reboot/`; nothing is ever pushed.
- Default sweep root `~/src` (`-maxdepth 2`); roots overridable as positional args; JSON echoes swept roots.
- `CLAUDE_DIR` env var overrides `~/.claude` (testability).
- The skill surfaces as `/stavxyz:reboot-ready` and is model-invocable (no `disable-model-invocation`).
- Conventional-commit messages; no Claude attribution lines in commits.
- Script headers follow the `skills/polish-pr/wait-for-pr-checks.sh` style: usage, exit codes, and a "why" note.

## File Structure

- `skills/reboot-ready/census.sh` — deterministic sweep (sessions census, checkout census, opt-in parking). One file, three clearly-marked sections; the only mutating code is inside the `--park` block.
- `skills/reboot-ready/SKILL.md` — model instructions: run the script, summarize sessions from transcripts, write manifests, print go/no-go.
- `tests/reboot-ready/test-census.sh` — automated bash test (sandboxed under `mktemp -d`; not distributed with the plugin, same as `tests/validate-fixtures/`).
- `tests/reboot-ready/README.md` — how to run the test.
- `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` — description strings enumerate skills (add reboot-ready to both), and versions must bump `0.1.6` → `0.1.7` per RELEASING.md (any `skills/` content change requires a patch bump; installed users never receive the new skill otherwise).
- `README.md` — skill count, table, invocation examples, and layout tree enumerate the skills; add reboot-ready.

---

### Task 1: census.sh — sessions census, probe statuses, JSON skeleton

**Files:**
- Create: `skills/reboot-ready/census.sh`
- Test: `tests/reboot-ready/test-census.sh`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `census.sh [--park] [ROOT ...]` CLI contract; JSON top-level shape `{generated_at, park, roots, probes: {jobs_scan, lsof}, sessions: {jobs, processes}, checkouts: [], not_parked: []}`; probe status enum `ran | unavailable | errored`; helper functions `json_escape`, `mtime_of`, `join_json` reused by Tasks 2–3. Job entry shape: `{id, mtime, session_id, cwd, transcript}`.

- [ ] **Step 1: Write the failing test**

Create `tests/reboot-ready/test-census.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/reboot-ready/test-census.sh`
Expected: FAIL lines / non-zero exit — `skills/reboot-ready/census.sh` does not exist yet (`bash: .../census.sh: No such file or directory`).

- [ ] **Step 3: Write the implementation**

Create `skills/reboot-ready/census.sh`:

```bash
#!/usr/bin/env bash
# census.sh — pre-reboot census of Claude Code sessions, repos, and worktrees.
#
# Usage:
#   census.sh [--park] [ROOT ...]
#
#   ROOT    directories swept for git repos (default: ~/src). Each root is
#           searched to -maxdepth 2 for .git directories/gitfiles.
#   --park  additionally create a rescue ref
#           (refs/rescue/pre-reboot/<name>-<timestamp>) for every dirty
#           checkout, built via a TEMPORARY index — the real index, working
#           tree, and branches are never touched. Without --park the run is
#           a pure read-only census.
#
# Output: one JSON document on stdout; diagnostics on stderr.
# Exit codes:
#   0 — census completed (per-item failures are recorded INSIDE the JSON)
#   2 — usage error
#
# Env:
#   CLAUDE_DIR — override ~/.claude (used by tests)
#
# Why `set -uo pipefail` and NOT -e: the spec requires degrade-don't-abort.
# A partial census before a reboot beats a crashed one, so failures land in
# the JSON (probe statuses, not_parked entries) instead of killing the sweep.
set -uo pipefail

usage() { echo "usage: census.sh [--park] [ROOT ...]" >&2; exit 2; }

# json_escape — the SINGLE encoder for all string fields in this script;
# every value that reaches the JSON output must pass through here. Control
# characters with no short JSON escape are deleted (paths and branch names
# should never contain them; deletion keeps the document parseable even if
# one sneaks in).
json_escape() {
  local s=${1-}
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# join_json <elem>... — comma-join pre-rendered JSON fragments
join_json() { local IFS=,; printf '%s' "$*"; }

PARK=0
ROOTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --park) PARK=1 ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) ROOTS+=("$1") ;;
  esac
  shift
done
[[ ${#ROOTS[@]} -gt 0 ]] || ROOTS=("$HOME/src")

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
TS=$(date +%Y%m%d-%H%M%S)

# --- sessions probe 1: background jobs (~/.claude/jobs) --------------------
# Both session probes live in this one block plus the lsof block below, so a
# Claude Code internals change (jobs dir relocated, binary renamed) is a
# one-place fix. Probe statuses: ran | unavailable | errored.
jobs_status="ran"
jobs_entries=()
if [[ -d "$CLAUDE_DIR/jobs" ]]; then
  for d in "$CLAUDE_DIR/jobs"/*/; do
    [[ -d "$d" ]] || continue
    id=$(basename "$d")
    mtime=$(mtime_of "$d")
    session_id=""
    job_cwd=""
    if [[ -f "$d/state.json" ]]; then
      # one parse for both fields: line 1 = sessionId, line 2 = cwd
      state_fields=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("sessionId","")); print(d.get("cwd",""))' "$d/state.json" 2>/dev/null) || { state_fields=""; jobs_status="errored"; }
      { IFS= read -r session_id; IFS= read -r job_cwd; } <<<"$state_fields"
    fi
    # Transcript path is DERIVED (verified 2026-07-31): job dirs hold
    # state.json, not a transcript; the transcript lives under
    # ~/.claude/projects/<slug>/<sessionId>.jsonl where <slug> is the cwd
    # with EVERY non-alphanumeric character replaced by '-' (dots and
    # slashes both become dashes; consecutive dashes are preserved).
    transcript=""
    if [[ -n "$session_id" && -n "$job_cwd" ]]; then
      slug=$(printf '%s' "$job_cwd" | tr -c 'A-Za-z0-9' '-')
      transcript="$CLAUDE_DIR/projects/$slug/$session_id.jsonl"
    fi
    jobs_entries+=("{\"id\":\"$(json_escape "$id")\",\"mtime\":$mtime,\"session_id\":\"$(json_escape "$session_id")\",\"cwd\":\"$(json_escape "$job_cwd")\",\"transcript\":\"$(json_escape "$transcript")\"}")
  done
else
  jobs_status="unavailable"
fi

# --- sessions probe 2: live claude processes (lsof) ------------------------
procs_status="ran"
proc_entries=()
proc_cwds=()
if command -v lsof >/dev/null 2>&1; then
  # -F pn emits "p<pid>", "fcwd", "n<cwd>" line groups per process; we key on
  # the p and n lines and ignore the f field line. macOS lsof exits 1 for
  # BOTH "no matches" and real errors, so the exit code alone distinguishes
  # nothing: capture stderr separately — silence there means a legitimately
  # empty result; output there means the probe itself failed.
  lsof_err=$(mktemp)
  lsof_out=$(lsof -a -d cwd -c claude -F pn 2>"$lsof_err")
  rc=$?
  if [[ $rc -ne 0 && -s "$lsof_err" ]]; then
    procs_status="errored"
  else
    pid=""
    while IFS= read -r line; do
      case "$line" in
        p*) pid=${line#p} ;;
        n*)
          cwd=${line#n}
          proc_entries+=("{\"pid\":${pid:-0},\"cwd\":\"$(json_escape "$cwd")\"}")
          proc_cwds+=("$cwd")
          ;;
      esac
    done <<<"$lsof_out"
  fi
  rm -f "$lsof_err"
else
  procs_status="unavailable"
fi

# --- checkouts (filled in by the repo/worktree sweep) -----------------------
checkout_entries=()
not_parked_entries=()

# --- emit -------------------------------------------------------------------
roots_json=()
for r in "${ROOTS[@]}"; do roots_json+=("\"$(json_escape "$r")\""); done
park_json=false
[[ $PARK -eq 1 ]] && park_json=true

printf '{'
printf '"generated_at":"%s",' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '"park":%s,' "$park_json"
printf '"roots":[%s],' "$(join_json ${roots_json[@]+"${roots_json[@]}"})"
printf '"probes":{"jobs_scan":"%s","lsof":"%s"},' "$jobs_status" "$procs_status"
printf '"sessions":{"jobs":[%s],"processes":[%s]},' \
  "$(join_json ${jobs_entries[@]+"${jobs_entries[@]}"})" \
  "$(join_json ${proc_entries[@]+"${proc_entries[@]}"})"
printf '"checkouts":[%s],' "$(join_json ${checkout_entries[@]+"${checkout_entries[@]}"})"
printf '"not_parked":[%s]' "$(join_json ${not_parked_entries[@]+"${not_parked_entries[@]}"})"
printf '}\n'
```

Then make both files executable:

```bash
chmod +x skills/reboot-ready/census.sh tests/reboot-ready/test-census.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/reboot-ready/test-census.sh`
Expected: `ALL PASS`, exit 0. (The `lsof` probe assertion accepts any enum value because live processes on the dev machine vary.)

- [ ] **Step 5: Commit**

```bash
git add skills/reboot-ready/census.sh tests/reboot-ready/test-census.sh
git commit -m "feat(reboot-ready): sessions census with probe statuses and JSON output"
```

> **Design note (2026-07-31):** JSON serialization stays in bash rather than adding a second python3 emit stage: python3 remains parse-only, and `json_escape` is the one trusted encoder every string field must pass through (now also stripping non-escapable control characters). One language owns the output pipeline; escaping correctness is concentrated at a single choke point.

---

### Task 2: census.sh — repo/worktree discovery, dirty state, live labeling

**Files:**
- Modify: `skills/reboot-ready/census.sh` (replace the `# --- checkouts` placeholder block)
- Test: `tests/reboot-ready/test-census.sh` (add `test_checkouts`)

**Interfaces:**
- Consumes: `json_escape`, `join_json`, `ROOTS`, `proc_cwds`, `checkout_entries`, `not_parked_entries` from Task 1.
- Produces: checkout entry shape used by Task 3 and by SKILL.md: `{path, primary, is_worktree, branch, dirty_count, ahead, behind, live, unpushed_branches, rescue_ref, park_error}` (`ahead`/`behind` are integers or `null` when no upstream; `unpushed_branches` is non-empty only on primary checkouts; `rescue_ref`/`park_error` are `""` until Task 3 fills them). Loop variable contract for Task 3: inside the per-checkout loop, `p` = checkout path, `dirty` = dirty count, `rescue_ref` and `park_error` are assigned immediately before the entry is rendered.

- [ ] **Step 1: Write the failing test**

In `tests/reboot-ready/test-census.sh`, insert after the `test_sessions_and_probes` function definition (before the `test_sessions_and_probes` call line):

```bash
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
```

And change the runner block at the bottom from:

```bash
test_sessions_and_probes
```

to:

```bash
test_sessions_and_probes
test_checkouts
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/reboot-ready/test-census.sh`
Expected: FAIL on `len(d["checkouts"]) == 2` (checkouts is still `[]`); earlier assertions still pass.

- [ ] **Step 3: Write the implementation**

In `skills/reboot-ready/census.sh`, replace this block:

```bash
# --- checkouts (filled in by the repo/worktree sweep) -----------------------
checkout_entries=()
not_parked_entries=()
```

with:

```bash
# --- checkouts: discover repos and their linked worktrees -------------------
checkout_entries=()
not_parked_entries=()
co_paths=()
co_primaries=()

# add_checkout <path> <primary> — dedupe on path (a worktree can be reached
# both by find and via `git worktree list` from its primary)
add_checkout() {
  local p
  for p in ${co_paths[@]+"${co_paths[@]}"}; do
    [[ "$p" == "$1" ]] && return 0
  done
  co_paths+=("$1")
  co_primaries+=("$2")
}

for root in "${ROOTS[@]}"; do
  if [[ ! -d "$root" ]]; then
    echo "census: root not found: $root" >&2
    continue
  fi
  while IFS= read -r gitpath; do
    repo=$(dirname "$gitpath")
    # worktree list from the primary catches nested .claude/worktrees/* that
    # -maxdepth 2 cannot see
    while IFS= read -r wtline; do
      case "$wtline" in
        "worktree "*) add_checkout "${wtline#worktree }" "$repo" ;;
      esac
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
  done < <(find "$root" -maxdepth 2 -name .git 2>/dev/null)
done

i=0
while [[ $i -lt ${#co_paths[@]} ]]; do
  p=${co_paths[$i]}
  primary=${co_primaries[$i]}
  i=$((i + 1))

  branch=$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch="(unknown)"
  dirty=$(git -C "$p" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

  ahead=null
  behind=null
  if git -C "$p" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    counts=$(git -C "$p" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null) || counts=""
    if [[ -n "$counts" ]]; then
      # output is "<behind><whitespace><ahead>" — strip on [[:space:]] so no
      # literal tab character has to survive copy/paste
      behind=${counts%%[[:space:]]*}
      ahead=${counts##*[[:space:]]}
    fi
  fi

  live=false
  for c in ${proc_cwds[@]+"${proc_cwds[@]}"}; do
    if [[ "$c" == "$p" || "$c" == "$p"/* ]]; then live=true; break; fi
  done

  is_worktree=true
  [[ "$p" == "$primary" ]] && is_worktree=false

  # unpushed local branches: reported once, on the primary checkout
  unpushed=()
  if [[ "$p" == "$primary" ]]; then
    while IFS=$'\t' read -r br up track; do
      if [[ -z "$up" || "$track" == *ahead* ]]; then
        unpushed+=("\"$(json_escape "$br")\"")
      fi
    done < <(git -C "$p" for-each-ref refs/heads --format='%(refname:short)%09%(upstream:short)%09%(upstream:track)' 2>/dev/null)
  fi

  rescue_ref=""
  park_error=""

  checkout_entries+=("{\"path\":\"$(json_escape "$p")\",\"primary\":\"$(json_escape "$primary")\",\"is_worktree\":$is_worktree,\"branch\":\"$(json_escape "$branch")\",\"dirty_count\":${dirty:-0},\"ahead\":$ahead,\"behind\":$behind,\"live\":$live,\"unpushed_branches\":[$(join_json ${unpushed[@]+"${unpushed[@]}"})],\"rescue_ref\":\"$(json_escape "$rescue_ref")\",\"park_error\":\"$(json_escape "$park_error")\"}")
done
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/reboot-ready/test-census.sh`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/reboot-ready/census.sh tests/reboot-ready/test-census.sh
git commit -m "feat(reboot-ready): checkout census — worktrees, dirty state, live labels, unpushed branches"
```

> **Design note (2026-07-31):** The 11-field checkout entry is assembled inline at the one site where all per-checkout data is in scope; every string field passes through `json_escape` (single-encoder rule, see the Task 1 design note). The bare-interpolated fields (`$is_worktree`, `$ahead`, `$behind`, `$live`, `${dirty:-0}`) are shell-computed booleans/numbers never sourced from repo content, so they cannot need escaping by construction.

---

### Task 3: census.sh — opt-in parking via temporary-index rescue refs

**Files:**
- Modify: `skills/reboot-ready/census.sh` (fill the `rescue_ref=""` / `park_error=""` slot inside the checkout loop)
- Test: `tests/reboot-ready/test-census.sh` (add `test_park`)

**Interfaces:**
- Consumes: the per-checkout loop from Task 2 (`p`, `dirty`, `not_parked_entries`), `PARK`, `TS`, `json_escape`.
- Produces: `park_checkout <path>` — the single mutating entry point, reporting via globals `PARK_REF` (ref name on success, else empty) and `PARK_ERROR` (failure reason, else empty). Rescue refs are named `refs/rescue/pre-reboot/<sanitized-basename>-<TS>`; `not_parked` JSON entries are `{path, error}`. SKILL.md (Task 4) relies on `rescue_ref` being non-empty exactly when parking succeeded.

- [ ] **Step 1: Write the failing test**

In `tests/reboot-ready/test-census.sh`, insert after the `test_checkouts` function definition:

```bash
test_park() {
  local root="$TMP/root3" repo out before after ref
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
```

And extend the runner block to:

```bash
test_sessions_and_probes
test_checkouts
test_park
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/reboot-ready/test-census.sh`
Expected: FAIL on "no rescue ref after --park" and the rescue-ref content assertions; the read-only and zero-touch checks pass trivially (nothing mutates yet).

- [ ] **Step 3: Write the implementation**

In `skills/reboot-ready/census.sh`, first insert this function immediately after the `add_checkout` function definition (before the `for root in` discovery loop) — parking gets a named boundary so the checkout loop stays pure reporting:

```bash
# park_checkout <path> — the ONLY mutating code in this script (--park only).
# Builds a rescue commit via a TEMPORARY index: the real index, working
# tree, branches, and `git status` output are byte-for-byte unchanged, so
# this is safe even on a checkout a live agent is editing. Never pushes;
# writes refs only, under refs/rescue/pre-reboot/.
# Results via globals: PARK_REF (ref name on success, else "") and
# PARK_ERROR (failure reason, else "").
park_checkout() {
  local p=$1 name ref tmpidx commit
  PARK_REF=""
  PARK_ERROR=""
  name=$(printf '%s' "$(basename "$p")" | tr -cs 'A-Za-z0-9._-' '-')
  ref="refs/rescue/pre-reboot/$name-$TS"
  if ! git -C "$p" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    PARK_ERROR="no commits yet (unborn HEAD)"
    return 0
  fi
  tmpidx=$(mktemp)
  # the subshell scopes GIT_INDEX_FILE so it cannot leak into later git
  # calls — do not "simplify" the export out of the subshell
  commit=$(
    export GIT_INDEX_FILE="$tmpidx"
    git -C "$p" read-tree HEAD 2>/dev/null &&
    git -C "$p" add -A 2>/dev/null &&
    tree=$(git -C "$p" write-tree 2>/dev/null) &&
    git -C "$p" commit-tree "$tree" -p HEAD -m "rescue: pre-reboot park $TS" 2>/dev/null
  )
  rm -f "$tmpidx"
  if [[ -n "$commit" ]] && git -C "$p" update-ref "$ref" "$commit" 2>/dev/null; then
    PARK_REF="$ref"
  else
    PARK_ERROR="rescue commit failed"
  fi
}
```

Then, inside the checkout loop, replace:

```bash
  rescue_ref=""
  park_error=""
```

with:

```bash
  rescue_ref=""
  park_error=""
  if [[ $PARK -eq 1 && ${dirty:-0} -gt 0 ]]; then
    park_checkout "$p"
    rescue_ref=$PARK_REF
    park_error=$PARK_ERROR
    if [[ -n "$park_error" ]]; then
      echo "census: NOT parked: $p — $park_error" >&2
      not_parked_entries+=("{\"path\":\"$(json_escape "$p")\",\"error\":\"$(json_escape "$park_error")\"}")
    fi
  fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/reboot-ready/test-census.sh`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 5: Sanity-run against the real machine (read-only)**

Run: `bash skills/reboot-ready/census.sh | python3 -m json.tool | head -40`
Expected: valid JSON; your real repos under `~/src` appear in `checkouts`; both probes report `ran`; **no** `refs/rescue/*` created anywhere (spot-check one repo with `git for-each-ref refs/rescue`).

- [ ] **Step 6: Commit**

```bash
git add skills/reboot-ready/census.sh tests/reboot-ready/test-census.sh
git commit -m "feat(reboot-ready): opt-in --park rescue refs via temporary index"
```

> **Design note (2026-07-31):** Parking lives behind the named `park_checkout` function instead of a block spliced into the reporting loop: the mutating code has one entry point, the loop reads as pure reporting, and the Task 2→Task 3 seam is a function signature rather than a shared-variable convention.

> **Design note (2026-07-31):** `not_parked` entries follow the single-encoder rule — both fields pass through `json_escape` — and are appended at the reporting site so `park_checkout` stays free of serialization concerns.

---

### Task 4: SKILL.md — judgment layer and manifests

**Files:**
- Create: `skills/reboot-ready/SKILL.md`

**Interfaces:**
- Consumes: `census.sh [--park] [ROOT ...]` CLI and the full JSON shape from Tasks 1–3 (`probes`, `sessions.jobs[].transcript`, `checkouts[].rescue_ref`, `not_parked`).
- Produces: the user-facing skill `/stavxyz:reboot-ready`; files `~/.claude/reboot-manifest.md` and `~/.claude/reboot-manifest.json`.

- [ ] **Step 1: Write SKILL.md**

Create `skills/reboot-ready/SKILL.md` with exactly this content:

````markdown
---
name: reboot-ready
description: Pre-reboot sweep of Claude Code sessions and git state. Use when the user says they are about to reboot, shut down, restart, or install an OS update — inventories running sessions, dirty worktrees, and unpushed branches, parks dirty checkouts as zero-touch rescue refs, and writes a resume manifest.
---

Prepare this machine for a reboot. A reboot kills running Claude Code
sessions and any in-flight tool calls; transcripts and files on disk
survive. Your job: census everything at risk, park dirty git state as
rescue refs, and leave a manifest so every session can be picked back up.

## Step 1 — resolve the skill directory and run the census

- **Plugin install:** if `$CLAUDE_PLUGIN_ROOT` is set, `SKILL_DIR="$CLAUDE_PLUGIN_ROOT/skills/reboot-ready"`.
- **Manual install:** otherwise `SKILL_DIR` is the directory containing this SKILL.md.

Run the deterministic sweep:

```bash
bash "$SKILL_DIR/census.sh" --park
```

- Pass `--park` for a real pre-reboot run (the default and normal case).
  Omit it ONLY if the user explicitly asked for a dry-run/report-only sweep.
- Default sweep root is `~/src`. If the user names other source roots,
  pass them as positional arguments after `--park`.
- The script is degrade-don't-abort: it exits 0 even when individual repos
  fail; per-item failures are inside the JSON. Exit 2 means you passed bad
  arguments — fix and re-run.

## Step 2 — persist the raw JSON

Save the script's stdout **verbatim** to `~/.claude/reboot-manifest.json`
(overwrite). This is the machine-readable record; do not edit or pretty-
print it.

## Step 3 — summarize what each running session was doing

For each entry in `sessions.jobs` whose repo/cwd matches a live process in
`sessions.processes` (compare `cwd` fields; prefix match counts), read the
LAST ~80 lines of its transcript (the `transcript` path in the JSON; it may
not exist — skip silently if absent) and write a one-line summary of what
that agent was actually doing (e.g. "implementing Task 3 of the auth plan;
last action: running tests"). Live processes with no matching job entry are
interactive sessions — list them by pid + cwd without a summary.

## Step 4 — write the manifest

Write `~/.claude/reboot-manifest.md` (overwrite each run):

```markdown
# Reboot manifest — <UTC timestamp>

## Verdict: <READY TO REBOOT | NOT READY — reasons below>

## Running sessions (will be killed by reboot)
### <job id or pid> — <one-line activity summary>
- Where: <checkout path> (branch `<branch>`, <N> dirty files)
- Rescue ref: `<rescue_ref>` (or "none — checkout clean")
- Resume: `claude --resume <session_id>` — then tell it to re-check its
  last step; in-flight tool calls do not auto-resume.

## Idle dirty checkouts (parked)
- <path> — branch `<branch>`, <N> dirty files → `<rescue_ref>`

## Unpushed branches (survive reboot on disk; push only if you want an off-machine copy)
- <repo>: <branch list>

## NOT parked (needs manual attention before reboot)
- <path> — <error>

## Probe health
- jobs scan: <ran|unavailable|errored>; lsof: <ran|unavailable|errored>
```

Omit any section with nothing to report, except `Probe health` (always
include it).

## Step 5 — verdict and terminal summary

Print a short summary to the user ending in a go/no-go verdict:

- **READY TO REBOOT** — every dirty checkout has a rescue ref, `not_parked`
  is empty, and both probes report `ran`.
- **NOT READY** — list exactly what is uncovered: each `not_parked` entry,
  and/or any probe that is `unavailable`/`errored` (say plainly: "the
  census could not see X, so an empty list there is not proof of nothing
  running").

Remind the user: files and transcripts survive reboot; running processes do
not; after reboot, walk the manifest and resume each session.

## Hard rules

- NEVER push anything anywhere. Rescue refs are local only.
- NEVER modify a working tree, index, or branch — the census script's
  `--park` writes refs only; you write only the two manifest files.
- NEVER stop, signal, or message running sessions.
- If `census.sh` is missing or unrunnable, STOP and tell the user the skill
  install is broken — do not improvise the sweep inline.
````

- [ ] **Step 2: Review SKILL.md against the spec's judgment-layer section**

Read `docs/superpowers/specs/2026-07-30-reboot-ready-skill-design.md` sections "`SKILL.md` — judgment layer" and "Error handling". Confirm: transcript-tail summaries (spec item 1) → Step 3; manifest `.md` + verbatim `.json` (spec item 2) → Steps 2 and 4; go/no-go verdict distinguishing "no sessions" from "couldn't look" (spec item 3 + probe-status design note) → Step 5. Fix any mismatch now.

- [ ] **Step 3: Verify the skill loads**

Run: `head -5 skills/reboot-ready/SKILL.md`
Expected: frontmatter opens with `---` and `name: reboot-ready`. (Full end-to-end skill invocation is exercised after plugin release; structural validity is what's checkable here.)

- [ ] **Step 4: Commit**

```bash
git add skills/reboot-ready/SKILL.md
git commit -m "feat(reboot-ready): SKILL.md judgment layer — manifests and go/no-go verdict"
```

---

### Task 5: Plugin metadata + test docs

**Files:**
- Modify: `.claude-plugin/plugin.json` (description string, version bump)
- Modify: `.claude-plugin/marketplace.json` (both description strings, version bump)
- Modify: `README.md` (skill count, table, invocation examples, layout tree)
- Create: `tests/reboot-ready/README.md`

**Interfaces:**
- Consumes: skill name `reboot-ready` from Task 4; test entry point `tests/reboot-ready/test-census.sh` from Tasks 1–3.
- Produces: accurate plugin metadata; developer docs.

- [ ] **Step 1: Update plugin.json description and bump the version**

In `.claude-plugin/plugin.json`, replace:

```json
  "description": "Multi-reviewer skills: /stavxyz:validate (fact-check + SOLID review of specs and plans) and /stavxyz:polish-pr (parallel review + fix sweep on a pull request)",
```

with:

```json
  "description": "Multi-reviewer and ops skills: /stavxyz:validate (fact-check + SOLID review of specs and plans), /stavxyz:polish-pr (parallel review + fix sweep on a pull request), and /stavxyz:reboot-ready (pre-reboot session census, rescue-ref parking, resume manifest)",
```

Then, per RELEASING.md (any change to `skills/` content requires a patch version bump — Claude Code caches installed plugins under a version-stamped path, so without a bump installed users never receive the new skill), replace:

```json
  "version": "0.1.6",
```

with:

```json
  "version": "0.1.7",
```

- [ ] **Step 2: Update marketplace.json descriptions and bump the version**

In `.claude-plugin/marketplace.json`, replace:

```json
      "description": "Multi-reviewer skills: /stavxyz:validate (fact-check + SOLID review of specs and plans) and /stavxyz:polish-pr (parallel review + fix sweep on a pull request)"
```

with:

```json
      "description": "Multi-reviewer and ops skills: /stavxyz:validate (fact-check + SOLID review of specs and plans), /stavxyz:polish-pr (parallel review + fix sweep on a pull request), and /stavxyz:reboot-ready (pre-reboot session census, rescue-ref parking, resume manifest)"
```

Also update the marketplace's own metadata block (its `description` enumerates the skills too, and its `version` must match the plugin bump). Replace:

```json
  "metadata": {
    "description": "stavxyz's Claude Code skills: spec/plan validation and PR polishing",
    "version": "0.1.6"
  },
```

with:

```json
  "metadata": {
    "description": "stavxyz's Claude Code skills: spec/plan validation, PR polishing, and pre-reboot sweeps",
    "version": "0.1.7"
  },
```

- [ ] **Step 3: Write tests/reboot-ready/README.md**

```markdown
# reboot-ready tests

Automated checks for `skills/reboot-ready/census.sh`. Everything runs in a
`mktemp -d` sandbox — scratch repos are created and destroyed per run, and
`CLAUDE_DIR` is pointed at fixtures so the real `~/.claude` is never read.

Run:

```bash
bash tests/reboot-ready/test-census.sh
```

Exit 0 and `ALL PASS` on success. Covered: JSON validity, probe statuses
(`ran`/`unavailable`), background-job parsing (`state.json` → derived
transcript path), repo + linked-worktree discovery, dirty counts, unpushed
branches, read-only default (no refs without `--park`), and the `--park`
path: rescue ref created, tracked + untracked content captured, `git
status` byte-identical before/after (zero-touch), unborn-HEAD repos
degrading into `not_parked`.

These files live outside `skills/` so they are not distributed with the
installed plugin (same convention as `tests/validate-fixtures/`).
```

- [ ] **Step 4: Update the repo README.md**

`README.md` enumerates the plugin's skills in four places; update each with a surgical replacement.

Replace:

```markdown
A small [Claude Code](https://claude.com/claude-code) plugin marketplace with two multi-reviewer skills:
```

with:

```markdown
A small [Claude Code](https://claude.com/claude-code) plugin marketplace with three skills:
```

Replace the polish-pr table row:

```markdown
| **polish-pr** | `/stavxyz:polish-pr <PR#>` | Rebases a PR, runs two independent code reviews in parallel, addresses **every** finding at every severity in-PR, updates docs, runs a test plan, and pushes. |
```

with the same row plus a new one:

```markdown
| **polish-pr** | `/stavxyz:polish-pr <PR#>` | Rebases a PR, runs two independent code reviews in parallel, addresses **every** finding at every severity in-PR, updates docs, runs a test plan, and pushes. |
| **reboot-ready** | `/stavxyz:reboot-ready` | Pre-reboot sweep: censuses running Claude Code sessions, dirty worktrees, and unpushed branches, parks dirty checkouts as zero-touch rescue refs, and writes a resume manifest to `~/.claude/reboot-manifest.md` + `.json`. |
```

Replace:

```markdown
they're invoked as `/stavxyz:validate` and `/stavxyz:polish-pr`.
```

with:

```markdown
they're invoked as `/stavxyz:validate`, `/stavxyz:polish-pr`, and `/stavxyz:reboot-ready`.
```

In the "Repository layout" tree, replace:

```text
│   └── polish-pr/
│       └── SKILL.md
```

with:

```text
│   ├── polish-pr/
│   │   └── SKILL.md
│   └── reboot-ready/
│       ├── SKILL.md
│       └── census.sh
```

and replace:

```text
    └── validate-fixtures/ # sample specs for exercising validate by hand
```

with:

```text
    ├── validate-fixtures/ # sample specs for exercising validate by hand
    └── reboot-ready/      # automated tests for census.sh
```

- [ ] **Step 5: Verify JSON validity of both metadata files**

Run: `python3 -m json.tool .claude-plugin/plugin.json >/dev/null && python3 -m json.tool .claude-plugin/marketplace.json >/dev/null && echo OK`
Expected: `OK`

- [ ] **Step 6: Run the full test suite one final time**

Run: `bash tests/reboot-ready/test-census.sh`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json README.md tests/reboot-ready/README.md
git commit -m "chore(reboot-ready): version bump, plugin metadata, README, and test docs"
```

> **Design note (2026-07-31):** `plugin.json` and `marketplace.json` carry hand-synced description/version pairs; this plan follows the existing convention rather than fixing it here. Future chore candidate: a check asserting the paired strings stay in sync, so a fourth skill can't silently drift them.
