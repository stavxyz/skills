#!/usr/bin/env bash
# probe-merge-gate-live.sh: run merge-gate.sh, read-only, against real pull
# requests, and check each answer against GitHub's own data.
#
# test-merge-gate.sh covers the gate's decisions with a stubbed gh. This runs
# the gate against the real API and checks two things: that it never answers
# UNKNOWN or fails (exit 2 or 3) for a real PR, and that every READY is
# confirmed by a second read of GitHub's data. It prints each verdict so a
# person can see that a promotion PR behind its base by merge commits reads
# READY and a behind feature PR reads NOT READY; it does not know which a PR
# should be, so it cannot fail on a wrong NOT READY.
#
# The second read uses the same endpoints the gate uses. It catches a race or
# a slip in how the gate handles the answers. It cannot catch the gate's rule
# being wrong: for that, compare `git merge-tree --write-tree <base> <head>`
# with the head's tree in a clone, as land-pr's step 2 does.
#
# Usage:
#   tests/land-pr/probe-merge-gate-live.sh [--script PATH] <owner/repo#N>...
#   tests/land-pr/probe-merge-gate-live.sh [--script PATH] --search [--limit N]
#
#   --script  the merge-gate.sh to run (default: this repository's copy; pass
#             an installed plugin's copy to check what is deployed)
#   --search  find open PRs shaped like promotions (head develop or dev, base
#             main or master) with `gh search prs`, up to --limit (default 10)
#             for each of three head and base pairs
#
# It only reads: `gh pr view`, `gh api` GETs, and `gh search prs`. It merges
# nothing and writes nothing. Each PR is gated with its current head as --sha.
#
# For every READY it reads again: when the gate says the head is behind by
# commits that change nothing, the PR's test merge must have the base's tip
# and the head as its parents and the head's tree as its tree; when the gate
# says behind 0, the compare API must agree.
#
# Exit: 0 every answer checked out; 1 a READY could not be confirmed, the gate
# returned 2 or 3 for some PR, a target could not be read, or nothing was
# probed; 3 usage.

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$ROOT/skills/land-pr/merge-gate.sh"
search=""
limit=10
targets=()
# The header from "Usage:" to its end; usage errors print the part before
# "It only reads", -h prints all of it.
help_text() { awk '/^# Usage:/{on=1} on && !/^#/{exit} on' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
usage() { help_text | awk '/^It only reads/{exit} {print}' >&2; exit 3; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --script) [[ $# -ge 2 ]] || usage; script="$2"; shift 2 ;;
    --limit)  [[ $# -ge 2 ]] || usage; limit="$2"; shift 2 ;;
    --search) search=1; shift ;;
    -h|--help) help_text; exit 0 ;;
    -*) usage ;;
    *) targets+=("$1"); shift ;;
  esac
done
[[ -f "$script" ]] || { echo "no such script: $script" >&2; exit 3; }
[[ "$limit" =~ ^[0-9]+$ ]] || usage
script="$(cd "$(dirname "$script")" && pwd)/$(basename "$script")"

if [[ -n "$search" ]]; then
  for pair in develop:main dev:main develop:master; do
    if ! found="$(gh search prs --state open --head "${pair%%:*}" --base "${pair##*:}" --limit "$limit" \
          --json number,repository --jq '.[] | "\(.repository.nameWithOwner)#\(.number)"')"; then
      echo "gh search failed (see above); nothing was probed" >&2
      exit 1
    fi
    while IFS= read -r t; do [[ -n "$t" ]] && targets+=("$t"); done <<<"$found"
  done
  [[ ${#targets[@]} -gt 0 ]] || { echo "the search found no open PRs; nothing was probed" >&2; exit 1; }
fi
[[ ${#targets[@]} -gt 0 ]] || usage

bad=0
for t in "${targets[@]}"; do
  if [[ ! "$t" =~ ^[^#/]+/[^#/]+#[0-9]+$ ]]; then echo "not owner/repo#N: $t" >&2; usage; fi
done
seen=" "
for t in "${targets[@]}"; do
  case "$seen" in *" $t "*) continue ;; esac   # the searches overlap
  seen="$seen$t "
  repo="${t%%#*}"; n="${t##*#}"
  head="$(GH_REPO="$repo" gh pr view "$n" --json headRefOid --jq .headRefOid 2>/dev/null)" || head=""
  if [[ -z "$head" ]]; then bad=1; echo "FAIL: cannot read $t"; continue; fi
  out="$(GH_REPO="$repo" bash "$script" "$n" --sha "$head" --retries 1 --interval 5 2>&1)"; rc=$?
  line="$(grep -m1 -E '^(READY|NOT READY|UNKNOWN|ALREADY MERGED|CLOSED)' <<<"$out" || head -n 1 <<<"$out")"
  case "$rc" in
    0)
      base="$(GH_REPO="$repo" gh pr view "$n" --json baseRefName --jq .baseRefName)"
      if grep -q 'by commits that change nothing' <<<"$out"; then
        tm="$(GH_REPO="$repo" gh pr view "$n" --json potentialMergeCommit --jq '.potentialMergeCommit.oid // ""')"
        tip="$(GH_REPO="$repo" gh api "repos/$repo/git/ref/heads/$base" --jq .object.sha 2>/dev/null)"
        got="$(GH_REPO="$repo" gh api "repos/$repo/git/commits/$tm" --jq '[.tree.sha, (.parents | map(.sha) | join(","))] | join(" ")' 2>/dev/null)"
        want="$(GH_REPO="$repo" gh api "repos/$repo/git/commits/$head" --jq .tree.sha 2>/dev/null) $tip,$head"
        if [[ -n "$tm" && "$got" == "$want" ]]; then
          echo "ok   $t: READY while behind; the test merge has the head's tree"
        elif [[ "$(GH_REPO="$repo" gh pr view "$n" --json state,headRefOid --jq '.state + " " + .headRefOid')" != "OPEN $head" ]]; then
          # Merged, closed, or pushed to between the gate's read and this one:
          # the second read describes a different PR state, so it proves nothing.
          echo "ok   $t: READY, then the PR changed during the probe; run it again for this PR"
        else
          bad=1; echo "FAIL $t: READY while behind, but the test merge is '$got', wanted '$want'"
        fi
      else
        behind="$(GH_REPO="$repo" gh api "repos/$repo/compare/$base...$head" --jq .behind_by 2>/dev/null)"
        if [[ "$behind" == "0" ]]; then echo "ok   $t: READY, behind 0"; else bad=1; echo "FAIL $t: READY, but the compare API says behind '$behind'"; fi
      fi ;;
    1)     echo "ok   $t: NOT READY: $(sed -n '2p' <<<"$out" | sed 's/^ *//' | cut -c1-110)" ;;
    4|5)   echo "ok   $t: $(cut -c1-110 <<<"$line")" ;;
    *)     bad=1; echo "FAIL $t: exit $rc: $line" ;;
  esac
done
exit "$bad"
