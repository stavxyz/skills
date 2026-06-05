#!/usr/bin/env bash
# wait-for-pr-checks.sh — poll `gh pr checks <N>` until every check has
# settled (no `pending`), exit non-zero if any check fails or cancels.
#
# Usage:
#   wait-for-pr-checks.sh <pr-number>
#   wait-for-pr-checks.sh <pr-number> --interval 30 --timeout 1800
#
# Defaults: poll every 20s, give up after 1800s (30 min).
#
# Exit codes:
#   0  — all required checks settled and none failed
#   1  — at least one check reported `fail` or `cancelled`
#   2  — timed out before all checks settled
#   3  — usage error / `gh` invocation failed
#
# Output: streams a one-line status snapshot each poll to stderr, then on
# exit prints the final "<check name>\t<status>" rows to stdout so the
# caller can grep/parse them.
#
# Why this exists: the natural inline form (`gh pr checks N | awk '{print
# $2}' | grep pending`) silently mis-parses check names that contain
# spaces (e.g. "E2E (Playwright)"), exiting "green" while the multi-word
# checks are still pending. `gh pr checks` is tab-delimited; this script
# splits on tab, not whitespace.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: wait-for-pr-checks.sh <pr-number> [--interval SECONDS] [--timeout SECONDS]" >&2
  exit 3
fi

pr="$1"
shift

interval=20
timeout=1800

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) interval="$2"; shift 2 ;;
    --timeout)  timeout="$2";  shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 3 ;;
  esac
done

if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
  echo "pr-number must be numeric, got: $pr" >&2
  exit 3
fi

deadline=$(( $(date +%s) + timeout ))

while :; do
  if ! out=$(gh pr checks "$pr" 2>&1); then
    # `gh pr checks` exits non-zero when ANY check has failed OR while
    # any are still pending. We rely on parsing rather than the exit
    # code; only treat a real invocation failure (missing PR, auth, etc.)
    # as fatal — those produce text that doesn't match the tab-delimited
    # row format.
    if ! echo "$out" | awk -F'\t' '{print $2}' | grep -qE "^(pass|fail|pending|skipping|cancelled|neutral|action_required)$"; then
      echo "gh pr checks failed: $out" >&2
      exit 3
    fi
  fi

  # Tab-delimited parsing — check names may contain spaces.
  failed=$(echo "$out" | awk -F'\t' '$2 == "fail" || $2 == "cancelled"' || true)
  if [[ -n "$failed" ]]; then
    echo "=== CI FAILED ===" >&2
    echo "$failed" >&2
    echo "$out" | awk -F'\t' '{print $1 "\t" $2}'
    exit 1
  fi

  if echo "$out" | awk -F'\t' '{print $2}' | grep -qE "^pending$"; then
    pending_count=$(echo "$out" | awk -F'\t' '$2 == "pending"' | wc -l | tr -d ' ')
    echo "[wait-for-pr-checks] $pending_count check(s) still pending, sleeping ${interval}s" >&2
    if [[ $(date +%s) -ge $deadline ]]; then
      echo "=== TIMEOUT after ${timeout}s ===" >&2
      echo "$out" | awk -F'\t' '{print $1 "\t" $2}'
      exit 2
    fi
    sleep "$interval"
    continue
  fi

  echo "=== CI GREEN (all checks settled) ===" >&2
  echo "$out" | awk -F'\t' '{print $1 "\t" $2}'
  exit 0
done
