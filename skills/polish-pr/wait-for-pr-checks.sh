#!/usr/bin/env bash
# wait-for-pr-checks.sh — poll a PR's checks until every check has settled
# (none `pending`), exit non-zero if any check failed or was cancelled.
#
# Usage:
#   wait-for-pr-checks.sh <pr-number>
#   wait-for-pr-checks.sh <pr-number> --interval 30 --timeout 1800
#   wait-for-pr-checks.sh <pr-number> --settle 0      # accept "no checks" at once
#
# Defaults: poll every 20s, give up after 1800s (30 min), and require an empty
# result to hold for 90s before believing it (see --settle below).
#
# Exit codes:
#   0  — all checks settled and none failed (or the PR has no checks at all)
#   1  — at least one check is in the `fail` or `cancel` bucket
#   2  — timed out before all checks settled
#   3  — usage error / `gh` missing / `gh` invocation failed
#
# Output: a one-line status snapshot to stderr each poll; on exit, the final
# "<check name>\t<bucket>" rows to stdout so the caller can grep/parse them.
#
# Why this exists / why --json: the natural inline form
# (`gh pr checks N | awk '{print $2}' | grep pending`) parses gh's
# human-formatted output, which splits multi-word check names ("E2E
# (Playwright)") on whitespace and reads "green" while they're still pending.
# Rather than depend on that plain-text layout (not a stable contract) this
# script reads `--json bucket`, whose values are a documented, stable enum:
# pass | fail | pending | skipping | cancel. We poll (rather than use
# `gh pr checks --watch`) because the skill runs this with run_in_background
# and wants a custom wall-clock timeout, which `--watch` does not provide.
#
# Why --settle: an empty result from `gh pr checks` means one of two things and
# looks identical in both. Either the repo has no CI, or the head was pushed
# seconds ago and GitHub has not registered the check runs yet. Reporting green
# on the second is a false green at exactly the wrong moment, because SKILL.md
# calls this right after the closing push and treats exit 0 as the signal to
# open the browser for merge. Measured 2026-09-22 on a repo with five checks:
# after a push, `gh pr checks` returned "no checks reported" for 62 seconds
# while the workflows were still being queued, and this script exited green at
# second 0. An empty reading must therefore persist for --settle seconds before
# it is believed. A repo that genuinely has no CI pays that wait once.

set -euo pipefail

usage() {
  echo "usage: wait-for-pr-checks.sh <pr-number> [--interval SECONDS] [--timeout SECONDS] [--settle SECONDS]" >&2
  exit 3
}

# Overridable so the tests can drive the whole loop with a scripted stub instead
# of a live PR. Nothing but the tests should set it.
GH_BIN="${WAIT_FOR_PR_CHECKS_GH:-gh}"

command -v "$GH_BIN" >/dev/null 2>&1 || { echo "gh is not installed or not on PATH" >&2; exit 3; }

[[ $# -ge 1 ]] || usage
pr="$1"; shift

interval=20
timeout=1800
settle=90

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) [[ $# -ge 2 ]] || { echo "--interval needs a value" >&2; exit 3; }; interval="$2"; shift 2 ;;
    --timeout)  [[ $# -ge 2 ]] || { echo "--timeout needs a value"  >&2; exit 3; }; timeout="$2";  shift 2 ;;
    --settle)   [[ $# -ge 2 ]] || { echo "--settle needs a value"   >&2; exit 3; }; settle="$2";   shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 3 ;;
  esac
done

# Validate every numeric input up front (not just the PR number).
for pair in "pr-number:$pr" "interval:$interval" "timeout:$timeout" "settle:$settle"; do
  name="${pair%%:*}"; val="${pair#*:}"
  [[ "$val" =~ ^[0-9]+$ ]] || { echo "$name must be numeric, got: $val" >&2; exit 3; }
done

deadline=$(( $(date +%s) + timeout ))
errfile="$(mktemp)"
trap 'rm -f "$errfile"' EXIT

# Emit the final name<TAB>bucket rows for the caller.
print_rows() { printf '%s\n' "$rows"; }

while :; do
  # One structured call per poll. With --json, gh exits 0 whenever it
  # retrieved data (regardless of pass/fail/pending); it exits non-zero
  # mainly when the query itself can't run (no checks, auth, bad PR). jq
  # @tsv escapes any tab/newline inside a name, so field splitting is safe.
  if rows="$("$GH_BIN" pr checks "$pr" --json name,bucket --jq '.[] | [.name, .bucket] | @tsv' 2>"$errfile")"; then
    rc=0
  else
    rc=$?
  fi
  err="$(cat "$errfile")"

  # No rows came back — the PR genuinely has no checks, the head was pushed so
  # recently that none are registered yet, or gh actually failed. The first two
  # are indistinguishable in a single reading, so an empty result only counts as
  # "no CI" once it has held for --settle seconds.
  if [[ -z "$rows" ]]; then
    if grep -qi 'no checks reported' <<<"$err" || [[ $rc -eq 0 ]]; then
      now=$(date +%s)
      if [[ -z "${empty_since:-}" ]]; then
        empty_since=$now
      fi
      held=$(( now - empty_since ))
      if [[ $held -ge $settle ]]; then
        echo "=== no checks on this PR after ${held}s — nothing to wait for (green) ===" >&2
        exit 0
      fi
      if [[ $now -ge $deadline ]]; then
        echo "=== TIMEOUT after ${timeout}s (no checks ever registered) ===" >&2
        exit 2
      fi
      echo "[wait-for-pr-checks] no checks yet (${held}s of ${settle}s settle), sleeping ${interval}s" >&2
      sleep "$interval"
      continue
    fi
    echo "gh pr checks failed (rc=$rc): ${err:-unknown error}" >&2
    exit 3
  fi
  # Checks appeared, so the empty readings were the registration lag, not a
  # repo without CI. Forget them: a later empty reading starts its own window.
  empty_since=""

  # Rows present — decide from the bucket column regardless of gh's exit code.
  failed="$(awk -F'\t' '$2 == "fail" || $2 == "cancel"' <<<"$rows" || true)"
  if [[ -n "$failed" ]]; then
    echo "=== CI FAILED ===" >&2
    echo "$failed" >&2
    print_rows
    exit 1
  fi

  pending_count="$(awk -F'\t' '$2 == "pending" { c++ } END { print c + 0 }' <<<"$rows")"
  if [[ "$pending_count" -gt 0 ]]; then
    if [[ $(date +%s) -ge $deadline ]]; then
      echo "=== TIMEOUT after ${timeout}s ($pending_count still pending) ===" >&2
      print_rows
      exit 2
    fi
    echo "[wait-for-pr-checks] $pending_count check(s) still pending, sleeping ${interval}s" >&2
    sleep "$interval"
    continue
  fi

  echo "=== CI GREEN (all checks settled) ===" >&2
  print_rows
  exit 0
done
