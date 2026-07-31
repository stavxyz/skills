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
