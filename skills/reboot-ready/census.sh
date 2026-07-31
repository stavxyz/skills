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
PARK_REF=""
PARK_ERROR=""
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
          # macOS lsof can suffix an unreadable cwd with " (stat: Permission
          # denied)" — trim it so the JSON cwd stays a clean path and the
          # live-prefix match below keeps working.
          cwd=${cwd%% (stat:*}
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

# park_checkout <path> — the ONLY mutating code in this script (--park only).
# Builds a rescue commit via a TEMPORARY index: the real index, working
# tree, branches, and `git status` output are byte-for-byte unchanged, so
# this is safe even on a checkout a live agent is editing. Never pushes;
# writes refs only, under refs/rescue/pre-reboot/.
# Results via globals: PARK_REF (ref name on success, else "") and
# PARK_ERROR (failure reason, else "").
park_checkout() {
  local p=$1 name uniq ref tmpidx commit
  PARK_REF=""
  PARK_ERROR=""
  name=$(printf '%s' "$(basename "$p")" | tr -cs 'A-Za-z0-9._-' '-')
  # Two checkouts can share a basename (a primary checkout and a same-named
  # worktree elsewhere, or two repos cloned under different roots) — a
  # path-derived uniquifier keeps their rescue refs from colliding and
  # silently overwriting each other in the shared ref store. cksum is
  # POSIX/bash-3.2-safe.
  uniq=$(printf '%s' "$p" | cksum | cut -d' ' -f1)
  ref="refs/rescue/pre-reboot/$name-$uniq-$TS"
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

for root in "${ROOTS[@]}"; do
  if [[ ! -d "$root" ]]; then
    echo "census: root not found: $root" >&2
    continue
  fi
  while IFS= read -r gitpath; do
    # pwd -P canonicalizes symlinks; mktemp paths on macOS are /var (symlink) but
    # git worktree list returns /private/var (real path), so both must resolve the same way
    dir=$(cd "$(dirname "$gitpath")" 2>/dev/null && pwd -P) || { echo "census: cannot resolve $gitpath" >&2; continue; }
    # worktree list from the primary catches nested .claude/worktrees/* that
    # -maxdepth 2 cannot see; git always lists MAIN worktree first
    primary=""
    wt_out=$(git -C "$dir" worktree list --porcelain 2>/dev/null)
    if [[ $? -ne 0 || -z "$wt_out" ]]; then
      echo "census: worktree list failed for $dir" >&2
    fi
    while IFS= read -r wtline; do
      case "$wtline" in
        "worktree "*)
          path="${wtline#worktree }"
          if [[ -z "$primary" ]]; then
            primary="$path"
          fi
          add_checkout "$path" "$primary"
          ;;
      esac
    done <<<"$wt_out"
  done < <(find "$root" -maxdepth 2 -name .git 2>/dev/null)
done

i=0
while [[ $i -lt ${#co_paths[@]} ]]; do
  p=${co_paths[$i]}
  primary=${co_primaries[$i]}
  i=$((i + 1))

  branch=$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch="(unknown)"
  # Capture git's own exit status directly (no pipe in between) so a
  # failure — e.g. an unreadable index — can't be swallowed by `wc -l`
  # counting 0 lines of empty output and reading as "clean". A failure
  # degrades to dirty_count:null (like ahead/behind) plus a not_parked
  # entry and a stderr line; it never falls through to parking.
  status_out=$(git -C "$p" status --porcelain 2>/dev/null)
  status_rc=$?
  if [[ $status_rc -ne 0 ]]; then
    echo "census: git status failed for $p" >&2
    dirty="null"
    not_parked_entries+=("{\"path\":\"$(json_escape "$p")\",\"error\":\"git status failed (checkout unreadable)\"}")
  elif [[ -z "$status_out" ]]; then
    dirty=0
  else
    # re-add the trailing newline that $(...) stripped so wc -l counts the
    # last porcelain line too
    dirty=$(printf '%s\n' "$status_out" | wc -l | tr -d ' ')
  fi

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
  # Gate parking on dirty being numeric first — dirty is the literal string
  # "null" when `git status` failed above, and `-gt 0` on that would blow
  # up arithmetic. An unassessable checkout is never parked.
  if [[ $PARK -eq 1 && "$dirty" =~ ^[0-9]+$ && $dirty -gt 0 ]]; then
    park_checkout "$p"
    rescue_ref=$PARK_REF
    park_error=$PARK_ERROR
    if [[ -n "$park_error" ]]; then
      echo "census: NOT parked: $p — $park_error" >&2
      not_parked_entries+=("{\"path\":\"$(json_escape "$p")\",\"error\":\"$(json_escape "$park_error")\"}")
    fi
  fi

  checkout_entries+=("{\"path\":\"$(json_escape "$p")\",\"primary\":\"$(json_escape "$primary")\",\"is_worktree\":$is_worktree,\"branch\":\"$(json_escape "$branch")\",\"dirty_count\":$dirty,\"ahead\":$ahead,\"behind\":$behind,\"live\":$live,\"unpushed_branches\":[$(join_json ${unpushed[@]+"${unpushed[@]}"})],\"rescue_ref\":\"$(json_escape "$rescue_ref")\",\"park_error\":\"$(json_escape "$park_error")\"}")
done

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
