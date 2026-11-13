#!/usr/bin/env bash
# wait-for-pr-checks.sh: poll a PR's checks until every check has settled
# (none `pending`), exit non-zero if any check failed or was cancelled.
#
# Usage:
#   wait-for-pr-checks.sh <pr-number>
#   wait-for-pr-checks.sh <pr-number> --interval 30 --timeout 1800
#   wait-for-pr-checks.sh <pr-number> --settle 0      # no minimum wait (see below)
#
# Defaults: poll every 20s, give up after 1800s (30 min), and believe neither an
# empty result nor a green one until 90s have passed (see --settle below). The
# settle window is only evaluated at a poll boundary, so the real wait rounds up
# to the next interval: 100s at the default 20s interval.
#
# Exit codes:
#   0  all checks settled, none failed, the settle window has passed, and every
#      workflow run for the head commit is completed; or the PR has no checks
#      and an empty result held for the settle window (see --settle)
#   1  at least one check is in the `fail` or `cancel` bucket, or a workflow
#      run for the head commit ended in failure or awaiting approval without
#      producing any check row
#   2  timed out before all checks settled, including checks that never
#      registered at all, and checks that pass while a workflow run for the
#      head commit never completes (the message names the runs)
#   3  usage error, `gh` missing, or a `gh` invocation failure
#
# Output: a one-line status snapshot to stderr each poll; on exit, the final
# "<check name>\t<bucket>" rows to stdout so the caller can grep/parse them,
# then one last stdout line, "VERDICT: green|failed|timeout|error".
#
# Do not pipe this script (`... | tail`). A pipeline's status is its last
# command's, so the exit code is lost and a failure reads as 0. That is how a
# network error was once reported as "exit 0". Run it bare, or redirect to a
# file. The VERDICT line exists for a caller that has lost the exit code anyway,
# and is printed on every exit, usage errors included.
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
# it is believed. The same window is the minimum time before any green and the
# grace period for a cancel, so every run takes at least that long. --settle 0
# turns all three off: an empty list is "no CI" at once, green needs only the
# workflow-run check, and a cancel is a failure at once.
#
# Why green is checked three ways: a check list that is non-empty and has
# nothing pending is not the same as CI having finished. After a push GitHub
# registers workflows one at a time, so a fast workflow can register and pass
# while a slower one is not in the list yet (measured: one row, `pass`, with
# nine workflows still to appear; and a run held in its concurrency group for
# 80 seconds with no jobs). An expected number of checks cannot fix that,
# because path-filtered workflows make the number depend on what the PR
# touched. So before green is believed: (1) the settle window must have passed
# since this script started, which covers registration lag; (2) every workflow
# run GitHub lists for the PR's head commit must be completed, which catches a
# run that exists but has no jobs yet; and (3) a `cancel` seen inside the settle
# window is re-polled rather than called a failure, because a push cancels the
# superseded run and the list can briefly still describe it.

set -euo pipefail

# finish <exit-code> <word>: the last stdout line names the verdict, for a
# caller whose pipeline swallowed the exit code. Every exit goes through it,
# usage errors included. The EXIT trap covers an exit that did not: a command
# that `set -e` aborted on still ends the output with a verdict.
errfile=""
verdict_done=""
finish() { verdict_done=1; echo "VERDICT: $2"; exit "$1"; }
trap '[[ -n "$errfile" ]] && rm -f "$errfile"; [[ -n "$verdict_done" ]] || echo "VERDICT: error"' EXIT

usage() {
  echo "usage: wait-for-pr-checks.sh <pr-number> [--interval SECONDS] [--timeout SECONDS] [--settle SECONDS]" >&2
  finish 3 error
}

# WAIT_FOR_PR_CHECKS_GH overrides which gh answers, so the tests can drive the
# whole loop with a scripted stub instead of a live PR. Nothing but the tests
# should set it, and a non-default value is announced on stderr below.
GH_BIN="${WAIT_FOR_PR_CHECKS_GH:-gh}"

command -v "$GH_BIN" >/dev/null 2>&1 || { echo "gh is not installed or not on PATH" >&2; finish 3 error; }

[[ $# -ge 1 ]] || usage
pr="$1"; shift

interval=20
timeout=1800
settle=90

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) [[ $# -ge 2 ]] || { echo "--interval needs a value" >&2; finish 3 error; }; interval="$2"; shift 2 ;;
    --timeout)  [[ $# -ge 2 ]] || { echo "--timeout needs a value"  >&2; finish 3 error; }; timeout="$2";  shift 2 ;;
    --settle)   [[ $# -ge 2 ]] || { echo "--settle needs a value"   >&2; finish 3 error; }; settle="$2";   shift 2 ;;
    *) echo "unknown arg: $1" >&2; finish 3 error ;;
  esac
done

# Validate every numeric input up front (not just the PR number).
for pair in "pr-number:$pr" "interval:$interval" "timeout:$timeout" "settle:$settle"; do
  name="${pair%%:*}"; val="${pair#*:}"
  [[ "$val" =~ ^[0-9]+$ ]] || { echo "$name must be numeric, got: $val" >&2; finish 3 error; }
done

# An inherited or stray override silently redirects the merge-gate verdict to
# another binary, so say which one is answering.
[[ "$GH_BIN" != "gh" ]] && echo "[wait-for-pr-checks] using gh binary: $GH_BIN" >&2

started=$(date +%s)
deadline=$(( started + timeout ))
errfile="$(mktemp)"

# Emit the final name<TAB>bucket rows for the caller.
print_rows() { printf '%s\n' "$rows"; }

# read_head: print the PR's current head sha; non-zero if gh fails or the
# answer is not a sha.
read_head() {
  local h
  h="$("$GH_BIN" pr view "$pr" --json headRefOid --jq '.headRefOid' 2>"$errfile")" || return 1
  [[ "$h" =~ ^[0-9a-f]{40}$ ]] || { echo "unreadable head sha: '$h'" >"$errfile"; return 1; }
  echo "$h"
}

# The head this watch is about. The check rows and the head come from separate
# calls, so a push landing between them could pair the old head's passing rows
# with the new head's not-yet-registered runs. runs_blocking compares against
# this and starts the wait over when the head has moved.
if ! watch_head="$(read_head)"; then
  echo "gh pr view failed: $(cat "$errfile")" >&2
  finish 3 error
fi

# runs_blocking: sets $blocking to the reason green must wait, or to empty when
# every workflow run for the head commit is completed, and sets $run_failures
# to the runs that completed without passing. A run that fails before it has
# any job (a workflow file error, a fork PR awaiting approval) has no row in
# the check list, so the rows alone would read as green. `cancelled` is not in
# that set: push and pull_request triggers that share a concurrency group
# cancel one of the pair on purpose. Returns non-zero if a gh call fails or
# answers unreadably. Call it directly, never in $(...): it
# updates the watch state when the head has moved.
runs_blocking() {
  local head listed unfinished n
  blocking=""
  run_failures=""
  head="$(read_head)" || return 1
  if [[ "$head" != "$watch_head" ]]; then
    watch_head="$head"
    started=$(date +%s)
    empty_since=""
    checks_seen=""
    blocking="the PR's head moved to ${head:0:12}, so the settle window starts over"
    return 0
  fi
  listed="$("$GH_BIN" run list --commit "$head" --limit 100 --json name,status,conclusion \
        --jq '.[] | select(.status != "completed" or (.conclusion | IN("failure", "startup_failure", "timed_out", "action_required")))
              | [(if .status == "completed" then "ended" else "open" end), .name, (if .status == "completed" then .conclusion else .status end)] | @tsv' 2>"$errfile")" || return 1
  [[ -z "$listed" ]] && return 0
  if grep -qvE "^(ended|open)$(printf '\t')[^$(printf '\t')]*$(printf '\t')[a-z_]+\$" <<<"$listed"; then
    echo "unreadable run list: '$listed'" >"$errfile"
    return 1
  fi
  run_failures="$(awk -F'\t' '$1 == "ended" { printf "%s%s (%s)", (c++ ? ", " : ""), $2, $3 }' <<<"$listed")"
  unfinished="$(awk -F'\t' '$1 == "open" { print $2 "\t" $3 }' <<<"$listed")"
  [[ -z "$unfinished" ]] && return 0
  n="$(awk 'END { print NR }' <<<"$unfinished")"
  blocking="$n workflow run(s) for the head commit not completed: $(awk -F'\t' '{ printf "%s%s (%s)", (NR > 1 ? ", " : ""), $1, $2 }' <<<"$unfinished")"
}

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

  # No rows came back. The PR genuinely has no checks, the head was pushed so
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
      # Only a PR whose checks were NEVER seen can be called "no CI". Once a
      # reading has returned rows, that claim is disproved by this run's own
      # history, and an empty list afterwards is an anomaly (a force-push
      # landing mid-wait resets the head's check runs, a suite can be re-run,
      # and the API can simply blip). Exiting 0 there would open the merge gate
      # for a PR whose only observed check never passed, so the anomaly is left
      # to resolve or to reach the deadline as a timeout.
      # A run held in its concurrency group has no jobs, so it is not in the
      # check list either: "no checks" is only "no CI" when no workflow run for
      # the head is waiting.
      blocking=""
      if [[ -z "${checks_seen:-}" && $held -ge $settle ]]; then
        if ! runs_blocking; then
          echo "gh failed while confirming workflow runs: $(cat "$errfile")" >&2
          finish 3 error
        fi
        if [[ -n "$run_failures" ]]; then
          echo "=== CI FAILED (no checks, and workflow run(s) for the head commit ended without passing: $run_failures) ===" >&2
          finish 1 failed
        fi
        if [[ -z "$blocking" ]]; then
          echo "=== no checks on this PR after ${held}s, and no workflow run waiting: nothing to wait for (green) ===" >&2
          finish 0 green
        fi
      fi
      if [[ $now -ge $deadline ]]; then
        if [[ -n "${checks_seen:-}" ]]; then
          echo "=== TIMEOUT after ${timeout}s (checks were seen earlier, then the list went empty) ===" >&2
        else
          echo "=== TIMEOUT after ${timeout}s (no checks ever registered${blocking:+; $blocking}) ===" >&2
        fi
        finish 2 timeout
      fi
      if [[ -n "${checks_seen:-}" ]]; then
        echo "[wait-for-pr-checks] check list went empty after checks were seen, re-polling in ${interval}s" >&2
      else
        echo "[wait-for-pr-checks] no checks yet (${held}s of ${settle}s settle${blocking:+; $blocking}), sleeping ${interval}s" >&2
      fi
      sleep "$interval"
      continue
    fi
    echo "gh pr checks failed (rc=$rc): ${err:-unknown error}" >&2
    finish 3 error
  fi
  # Checks appeared, so any earlier empty readings were the registration lag and
  # not a repo without CI. This latch is what carries that knowledge: every use
  # of the settle window above is gated on it being unset, so once it is set no
  # empty reading can reach the no-CI exit no matter how long it persists.
  # Resetting empty_since here would be dead weight, because held is then
  # unreachable, and a test could not tell the reset from its absence.
  checks_seen=1

  # Rows present, so decide from the bucket column regardless of gh's exit code.
  now=$(date +%s)
  watched=$(( now - started ))
  failed="$(awk -F'\t' '$2 == "fail" || $2 == "cancel"' <<<"$rows" || true)"
  if [[ -n "$failed" ]]; then
    hard_failed="$(awk -F'\t' '$2 == "fail"' <<<"$rows" || true)"
    # Only cancels, and still inside the settle window: this may be the run the
    # push superseded. A cancel that is still there after the window is real.
    if [[ -z "$hard_failed" && $watched -lt $settle && $now -lt $deadline ]]; then
      echo "[wait-for-pr-checks] cancelled check(s) inside the settle window (${watched}s of ${settle}s), re-polling in ${interval}s" >&2
      sleep "$interval"
      continue
    fi
    echo "=== CI FAILED ===" >&2
    echo "$failed" >&2
    print_rows
    finish 1 failed
  fi

  pending_count="$(awk -F'\t' '$2 == "pending" { c++ } END { print c + 0 }' <<<"$rows")"
  if [[ "$pending_count" -gt 0 ]]; then
    if [[ $(date +%s) -ge $deadline ]]; then
      echo "=== TIMEOUT after ${timeout}s ($pending_count still pending) ===" >&2
      print_rows
      finish 2 timeout
    fi
    echo "[wait-for-pr-checks] $pending_count check(s) still pending, sleeping ${interval}s" >&2
    sleep "$interval"
    continue
  fi

  # Nothing pending and nothing failed. That is green only if the list is
  # complete: see "Why green is checked three ways" in the header.
  if [[ $watched -lt $settle ]]; then
    not_yet="registration window open (${watched}s of ${settle}s)"
  elif ! runs_blocking; then
    echo "gh failed while confirming workflow runs: $(cat "$errfile")" >&2
    finish 3 error
  elif [[ -n "$run_failures" ]]; then
    echo "=== CI FAILED (workflow run(s) for the head commit ended without passing and have no check row: $run_failures) ===" >&2
    print_rows
    finish 1 failed
  elif [[ -n "$blocking" ]]; then
    not_yet="$blocking"
  else
    count="$(awk 'END { print NR }' <<<"$rows")"
    echo "=== CI GREEN ($count check(s) settled, every workflow run for the head completed) ===" >&2
    print_rows
    finish 0 green
  fi
  if [[ $now -ge $deadline ]]; then
    echo "=== TIMEOUT after ${timeout}s (checks pass, but $not_yet) ===" >&2
    print_rows
    finish 2 timeout
  fi
  echo "[wait-for-pr-checks] checks pass, but $not_yet, re-polling in ${interval}s" >&2
  sleep "$interval"
done
