#!/usr/bin/env bash
# merge-gate.sh: decide, at the moment of merging, whether a PR may be merged
# on the commit that was polished and went green.
#
# Usage:
#   merge-gate.sh <pr-number> --sha <blessed-head-sha>
#   merge-gate.sh <pr-number>                      # state probe, never exits 0
#   merge-gate.sh <pr-number> --sha <sha> --retries 6 --interval 10
#
# Set GH_REPO=<owner>/<repo> when the checkout has more than one GitHub remote.
#
# Exit codes, one per action the caller takes:
#   0  READY: open, not a draft, head is still the blessed sha, zero commits
#      behind the base, GitHub reports it mergeable and not blocked
#   1  NOT READY: one line per reason on stdout; the bless is void or the PR
#      needs work before it can merge
#   2  UNKNOWN: GitHub had not computed mergeability after every retry, or a
#      reading came back empty or malformed. Unknown is never a pass.
#   3  usage error, gh missing, or a gh invocation failure
#   4  ALREADY MERGED: stdout carries the merge commit; skip to post-merge work
#   5  CLOSED without merging
#
# Why a script: these readings each have a look-alike that passes wrongly.
# `mergeable` is UNKNOWN for about a minute after a push and also on a PR that
# is already merged or closed, so a loop that waits for it to leave UNKNOWN
# spins forever on a PR someone else merged. A green CI run belongs to the sha
# it ran on, and the head can move after it. Commits AHEAD of the base and sync
# with the branch's own upstream both look like currency and detect nothing;
# only commits BEHIND the base does. An empty variable compared with a string
# reads as "not failing". Each of those has merged, or nearly merged, the wrong
# thing when written inline.

set -euo pipefail

usage() {
  echo "usage: merge-gate.sh <pr-number> [--sha HEAD_SHA] [--retries N] [--interval SECONDS]" >&2
  exit 3
}

# MERGE_GATE_GH overrides which gh answers, so the tests can script every
# reading. Nothing but the tests should set it.
GH_BIN="${MERGE_GATE_GH:-gh}"
command -v "$GH_BIN" >/dev/null 2>&1 || { echo "gh is not installed or not on PATH" >&2; exit 3; }

[[ $# -ge 1 ]] || usage
pr="$1"; shift

sha=""
retries=6
interval=10

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha)      [[ $# -ge 2 ]] || { echo "--sha needs a value" >&2; exit 3; };      sha="$2";      shift 2 ;;
    --retries)  [[ $# -ge 2 ]] || { echo "--retries needs a value" >&2; exit 3; };  retries="$2";  shift 2 ;;
    --interval) [[ $# -ge 2 ]] || { echo "--interval needs a value" >&2; exit 3; }; interval="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 3 ;;
  esac
done

for pair in "pr-number:$pr" "retries:$retries" "interval:$interval"; do
  name="${pair%%:*}"; val="${pair#*:}"
  [[ "$val" =~ ^[0-9]+$ ]] || { echo "$name must be numeric, got: $val" >&2; exit 3; }
done
# A short sha would prefix-match a different commit's bless, so require all 40.
if [[ -n "$sha" && ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "--sha must be a full 40-character commit sha, got: $sha" >&2
  exit 3
fi

[[ "$GH_BIN" != "gh" ]] && echo "[merge-gate] using gh binary: $GH_BIN" >&2

errfile="$(mktemp)"
trap 'rm -f "$errfile"' EXIT

# Fields are joined with "|" rather than tabs: tab is IFS whitespace, so `read`
# would collapse an empty field and shift every later one left.
read_pr() {
  "$GH_BIN" pr view "$pr" \
    --json state,isDraft,headRefOid,mergeable,mergeStateStatus,baseRefName,mergeCommit \
    --jq '[.state, (.isDraft|tostring), .headRefOid, .mergeable, .mergeStateStatus, .baseRefName, (.mergeCommit.oid // "-")] | join("|")' \
    2>"$errfile"
}

attempt=0
while :; do
  if ! line="$(read_pr)"; then
    echo "gh pr view failed: $(cat "$errfile")" >&2
    exit 3
  fi
  IFS='|' read -r state draft head mergeable merge_state base merge_commit extra <<<"$line"
  if [[ -z "${state:-}" || -z "${draft:-}" || -z "${head:-}" || -z "${mergeable:-}" \
        || -z "${merge_state:-}" || -z "${base:-}" || -z "${merge_commit:-}" || -n "${extra:-}" ]]; then
    echo "UNKNOWN: unreadable PR state from gh: '$line'"
    exit 2
  fi

  # Terminal states first. mergeable is UNKNOWN on a merged or closed PR, so
  # testing it before the state would retry on a PR that will never change.
  case "$state" in
    MERGED) echo "ALREADY MERGED: PR #$pr merge commit $merge_commit"; exit 4 ;;
    CLOSED) echo "CLOSED: PR #$pr was closed without merging"; exit 5 ;;
    OPEN)   ;;
    *)      echo "UNKNOWN: unrecognized PR state '$state'"; exit 2 ;;
  esac

  if [[ "$mergeable" == "UNKNOWN" || "$merge_state" == "UNKNOWN" ]]; then
    attempt=$((attempt + 1))
    if [[ $attempt -gt $retries ]]; then
      echo "UNKNOWN: GitHub has not computed mergeability for PR #$pr after $retries retries"
      exit 2
    fi
    echo "[merge-gate] mergeability not computed yet (try $attempt of $retries), sleeping ${interval}s" >&2
    sleep "$interval"
    continue
  fi
  break
done

reasons=()

[[ "$draft" == "true" ]] && reasons+=("draft: PR #$pr is a draft")

if [[ -z "$sha" ]]; then
  reasons+=("no blessed sha given: pass --sha with the head polish-pr blessed (current head is $head)")
elif [[ "$head" != "$sha" ]]; then
  reasons+=("head moved: blessed $sha, current head $head; commits after the bless are unreviewed")
fi

case "$mergeable" in
  MERGEABLE)   ;;
  CONFLICTING) reasons+=("conflicts: PR #$pr does not merge cleanly into $base") ;;
  *)           echo "UNKNOWN: unrecognized mergeable value '$mergeable'"; exit 2 ;;
esac

case "$merge_state" in
  CLEAN|HAS_HOOKS|UNSTABLE) ;;  # UNSTABLE: a non-required check is not passing; the CI watcher rules on checks
  BLOCKED) reasons+=("blocked: branch protection is not satisfied (required review or required check)") ;;
  BEHIND)  reasons+=("behind: GitHub reports the head is out of date with $base") ;;
  DIRTY)   [[ "$mergeable" == "CONFLICTING" ]] || reasons+=("conflicts: merge state is DIRTY") ;;
  DRAFT)   [[ "$draft" == "true" ]] || reasons+=("draft: merge state is DRAFT") ;;
  *)       echo "UNKNOWN: unrecognized mergeStateStatus '$merge_state'"; exit 2 ;;
esac

# Commits BEHIND the base is the load-bearing direction. GitHub only reports
# BEHIND above when the base requires up-to-date branches, so count it here for
# every repo. {owner}/{repo} are filled in by gh from GH_REPO or the checkout.
if ! behind="$("$GH_BIN" api "repos/{owner}/{repo}/compare/${base}...${head}" --jq '.behind_by' 2>"$errfile")"; then
  echo "gh api compare failed: $(cat "$errfile")" >&2
  exit 3
fi
if [[ ! "$behind" =~ ^[0-9]+$ ]]; then
  echo "UNKNOWN: unreadable behind count from gh: '$behind'"
  exit 2
fi
[[ "$behind" -gt 0 ]] && reasons+=("behind: head is $behind commit(s) behind $base")

if [[ ${#reasons[@]} -gt 0 ]]; then
  echo "NOT READY: PR #$pr"
  printf '  %s\n' "${reasons[@]}"
  exit 1
fi

echo "READY: PR #$pr head $head base $base behind 0 mergeable $mergeable ($merge_state)"
exit 0
