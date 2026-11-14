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
#   0  READY: open, not a draft, head is still the blessed sha, not behind the
#      base (or behind only by commits that leave the merge result equal to
#      the head's tree, as after a merge-commit promotion), GitHub reports it mergeable and not blocked. Checks are
#      not read: run the CI watcher first.
#   1  NOT READY: one line per reason on stdout; the bless is void or the PR
#      needs work before it can merge
#   2  UNKNOWN: GitHub had not computed mergeability after every retry, or a
#      reading came back empty or malformed. Unknown is never a pass.
#   3  usage error, gh missing, or a gh invocation failure
#   4  ALREADY MERGED: stdout carries the merge commit and the merged head, and
#      says whether that head is the blessed sha; skip to post-merge work
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
    MERGED)
      # Someone else may have merged it, on a head that was never blessed.
      if [[ -z "$sha" ]]; then
        echo "ALREADY MERGED: PR #$pr merge commit $merge_commit, merged head $head"
      elif [[ "$head" == "$sha" ]]; then
        echo "ALREADY MERGED: PR #$pr merge commit $merge_commit, merged head $head is the blessed sha"
      else
        echo "ALREADY MERGED: PR #$pr merge commit $merge_commit, merged head $head differs from the blessed sha $sha"
      fi
      exit 4 ;;
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
# Behind is not always stale. What "behind" protects is that the merged result
# is the tree that was reviewed and tested, and that holds whenever merging
# changes nothing about the head. The standing case is a promotion flow that
# uses merge commits (dev into main): each promote leaves a merge commit on the
# base that the head never gets, so the head is "behind" by one more commit
# forever, and rebasing a shared branch to clear it is not an option.
#
# So when the head is behind, the property is checked itself, not a proxy for
# it: GitHub keeps a test merge of the PR (potentialMergeCommit). If that
# commit's parents are the base's current tip and this head, and its tree is
# the head's tree, the merge lands exactly what was reviewed. A hotfix made on
# the base and never brought back gives a different tree, and stops the merge
# as before. (A diff of what the base changed since the merge base is not
# enough: with a criss-cross history the diff against one merge base can be
# empty while the merge still changes the head's files.)
api() { "$GH_BIN" api "repos/{owner}/{repo}/$1" --jq "$2" 2>"$errfile"; }
api_or_exit() { # prints the answer; a gh failure is exit 3
  local out
  if ! out="$(api "$1" "$2")"; then
    echo "gh api $1 failed: $(cat "$errfile")" >&2
    exit 3
  fi
  printf '%s\n' "$out"
}
is_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

behind_note="behind 0"
# The test merge is read only when it can change the answer: a blessed sha was
# given and nothing else is already wrong. A probe, a moved head, a draft, or a
# conflict gets the plain reason at once.
if [[ "$behind" -gt 0 && ${#reasons[@]} -eq 0 && "$mergeable" == "MERGEABLE" ]]; then
  if ! test_merge="$("$GH_BIN" pr view "$pr" --json potentialMergeCommit --jq '.potentialMergeCommit.oid // "none"' 2>"$errfile")"; then
    echo "gh pr view failed: $(cat "$errfile")" >&2
    exit 3
  fi
  if ! is_sha "$test_merge"; then
    reasons+=("behind: head is $behind commit(s) behind $base, and GitHub has no test merge to show that merging changes nothing")
  else
    base_tip="$(api_or_exit "git/ref/heads/$base" '.object.sha')" || exit $?
    is_sha "$base_tip" || { echo "UNKNOWN: unreadable tip of $base from gh: '$base_tip'"; exit 2; }
    merged="$(api_or_exit "git/commits/$test_merge" '[.tree.sha, (.parents | map(.sha) | join(","))] | join("|")')" || exit $?
    IFS='|' read -r merged_tree merged_parents extra <<<"$merged"
    head_tree="$(api_or_exit "git/commits/$head" '.tree.sha')" || exit $?
    if ! is_sha "${merged_tree:-}" || ! is_sha "$head_tree" || [[ -z "${merged_parents:-}" || -n "${extra:-}" ]]; then
      echo "UNKNOWN: unreadable test merge from gh: '$merged' (head tree '$head_tree')"
      exit 2
    fi
    if [[ "$merged_parents" != "$base_tip,$head" ]]; then
      # GitHub often does not rebuild the test merge when the base moves, and
      # can leave it that way for a day. A test merge of an older base says
      # nothing about this merge, so this is the ordinary "behind": a feature
      # PR is rebased, and running the gate again would not change it.
      reasons+=("behind: head is $behind commit(s) behind $base, and GitHub's test merge is for a different base tip or head (stale test merge), so it cannot show that merging changes nothing")
    elif [[ "$merged_tree" == "$head_tree" ]]; then
      behind_note="behind $behind by commits that change nothing (the merge result is the head's tree)"
    else
      reasons+=("behind: head is $behind commit(s) behind $base, and merging would change the head's tree: $base has changes the head lacks")
    fi
  fi
elif [[ "$behind" -gt 0 ]]; then
  reasons+=("behind: head is $behind commit(s) behind $base")
fi

if [[ ${#reasons[@]} -gt 0 ]]; then
  echo "NOT READY: PR #$pr"
  printf '  %s\n' "${reasons[@]}"
  exit 1
fi

# READY says nothing about checks: the CI watcher rules on those, before this.
echo "READY: PR #$pr head $head base $base $behind_note mergeable $mergeable ($merge_state); checks not read here"
exit 0
