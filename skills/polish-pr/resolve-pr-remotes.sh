#!/usr/bin/env bash
# resolve-pr-remotes.sh — map a PR to the local git remotes that host its base
# and head repositories, so polish-pr never hardcodes `origin`.
#
# Usage:
#   resolve-pr-remotes.sh <pr-number>
#   resolve-pr-remotes.sh <pr-number> --repo owner/repo
#   resolve-pr-remotes.sh --normalize <git-url>      # normalizer self-test hook
#
# Output (stdout), one KEY=value per line, safe to `eval`:
#   BASE_REPO=parconditio/grocerbot
#   HEAD_REPO=stavxyz/grocerbot
#   BASE_BRANCH=main
#   BASE_REMOTE=upstream
#   HEAD_REMOTE=origin
#   CROSS_REPOSITORY=true
#
# Exit codes:
#   0  — both remotes resolved
#   1  — no local remote hosts the base (or head) repo — a hard stop, never a guess
#   2  — ambiguous: more than one remote hosts the same repo
#   3  — usage error / `gh` missing / `gh` invocation failed / not a git repo
#
# Why this exists, and why it is a script rather than inline shell:
#
# polish-pr's base-currency gate must compare HEAD against the base branch of
# the repo the PR actually merges into. Hardcoding `origin` is wrong wherever
# the canonical remote is named something else — and silently so: on a repo
# where `origin` is a different repository that merely shares a name, the gate
# reports `behind: 0` unconditionally. A gate that cannot fail still gets
# trusted.
#
# The closing force-push has the mirror-image problem. It must target the
# remote hosting the PR's *head* branch, which on any fork PR is NOT the base
# remote. Pushing the head branch to the base repo exits 0, leaves a stray
# branch there, and never updates the PR — so an attribution sweep can "pass"
# while the attributed commits are still on the PR.
#
# Both need the same lookup, so it lives here once, next to
# wait-for-pr-checks.sh and for the same stated reason: that script exists
# because `gh pr checks`'s human-formatted output is not a stable contract.
# Neither is `git remote -v`. Two specific hazards:
#
#   1. `git remote -v` prints URLs with `url.<base>.insteadOf` rewrites already
#      applied, so a remote configured as `https://github.com/o/r` can display
#      as `ssh://git@github.com/o/r`. `git config --get-regexp` returns the
#      configured value and is the documented interface. We normalize every
#      form anyway, since a remote may legitimately be configured as ssh://.
#   2. Its columns are whitespace-split, so a local-path remote containing a
#      space breaks positional parsing.
#
# Comparison includes the host, so a GitHub Enterprise remote never matches a
# github.com PR, and is case-insensitive, since GitHub treats owner/repo names
# case-insensitively in clone URLs but returns canonical casing via the API.

set -uo pipefail

die() { printf '%s\n' "$*" >&2; exit 3; }

# Reduce any git URL to a comparable `host/owner/repo`, lowercased.
# Handles: scp-style (git@host:o/r[.git]), ssh:// and git:// (with optional
# user@ and :port), http(s):// (with optional credentials and :port), and
# trailing slashes. Local paths have no host and normalize to themselves,
# which simply fails to match — the correct outcome, surfaced as exit 1.
normalize_url() {
  printf '%s\n' "$1" | sed -E '
    s#/+$##
    s#\.git$##
    s#^[A-Za-z][A-Za-z0-9+.-]*://##
    s#^[^/@]*@##
    s#^([^/:]+):([0-9]+)/#\1/#
    s#^([^/:]+):#\1/#
  ' | tr '[:upper:]' '[:lower:]'
}

if [ "${1:-}" = "--normalize" ]; then
  [ $# -eq 2 ] || die "usage: $0 --normalize <git-url>"
  normalize_url "$2"
  exit 0
fi

PR="${1:-}"
[ -n "$PR" ] || die "usage: $0 <pr-number> [--repo owner/repo]"
shift

REPO_ARG=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ -n "${2:-}" ] || die "--repo needs a value"; REPO_ARG=(--repo "$2"); shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v gh >/dev/null 2>&1 || die "gh not found on PATH"
command -v git >/dev/null 2>&1 || die "git not found on PATH"
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

# One API call for everything we need.
META=$(gh pr view "$PR" "${REPO_ARG[@]+"${REPO_ARG[@]}"}" \
        --json url,baseRefName,headRepository,headRepositoryOwner,isCrossRepository \
        --template '{{.url}}
{{.baseRefName}}
{{.headRepositoryOwner.login}}/{{.headRepository.name}}
{{.isCrossRepository}}' 2>&1) || die "gh pr view $PR failed:
$META

If gh resolved the wrong repository, pass --repo <owner>/<repo> (this repo has
more than one remote, and gh may pick either). Note a same-numbered PR can
exist in both, so a result that looks plausible may still be the wrong repo."

PR_URL=$(printf '%s\n' "$META" | sed -n 1p)
BASE_BRANCH=$(printf '%s\n' "$META" | sed -n 2p)
HEAD_REPO=$(printf '%s\n' "$META" | sed -n 3p)
CROSS=$(printf '%s\n' "$META" | sed -n 4p)

# https://HOST/OWNER/REPO/pull/N  ->  HOST and OWNER/REPO
PR_HOST=$(printf '%s\n' "$PR_URL" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://([^/]+)/.*#\1#')
BASE_REPO=$(printf '%s\n' "$PR_URL" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://[^/]+/([^/]+/[^/]+)/pull/.*#\1#')

[ -n "$PR_HOST" ] && [ "$PR_HOST" != "$PR_URL" ] || die "could not parse host from PR url: $PR_URL"
[ -n "$BASE_REPO" ] && [ "$BASE_REPO" != "$PR_URL" ] || die "could not parse repo from PR url: $PR_URL"
[ -n "$BASE_BRANCH" ] || die "gh returned an empty base branch for PR $PR"

BASE_TARGET=$(printf '%s/%s\n' "$PR_HOST" "$BASE_REPO" | tr '[:upper:]' '[:lower:]')
HEAD_TARGET=$(printf '%s/%s\n' "$PR_HOST" "$HEAD_REPO" | tr '[:upper:]' '[:lower:]')

# Collect remotes from the stable config interface, not `git remote -v`.
REMOTE_NAMES=()
REMOTE_NORMS=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  key=${line%% *}
  url=${line#* }
  name=${key#remote.}
  name=${name%.url}
  REMOTE_NAMES+=("$name")
  REMOTE_NORMS+=("$(normalize_url "$url")")
done < <(git config --get-regexp '^remote\..*\.url$' || true)

[ ${#REMOTE_NAMES[@]} -gt 0 ] || die "this repository has no configured remotes"

# Find every remote matching a target; ambiguity is an error, not a coin flip —
# picking arbitrarily could aim the closing force-push at a read-only mirror.
match_remote() {
  local target=$1 role=$2 found=() i
  for i in "${!REMOTE_NAMES[@]}"; do
    [ "${REMOTE_NORMS[$i]}" = "$target" ] && found+=("${REMOTE_NAMES[$i]}")
  done
  if [ ${#found[@]} -eq 0 ]; then
    {
      printf 'no remote hosts the %s repo (%s)\n' "$role" "$target"
      printf 'configured remotes:\n'
      for i in "${!REMOTE_NAMES[@]}"; do
        printf '  %s -> %s\n' "${REMOTE_NAMES[$i]}" "${REMOTE_NORMS[$i]}"
      done
      printf 'Add a remote for it, or fix the one that should point there.\n'
      printf 'Refusing to guess: defaulting to origin is the bug this replaces.\n'
    } >&2
    return 1
  fi
  if [ ${#found[@]} -gt 1 ]; then
    printf 'ambiguous: %d remotes host the %s repo (%s): %s\n' \
      "${#found[@]}" "$role" "$target" "${found[*]}" >&2
    printf 'Remove or rename one so the intended target is unambiguous.\n' >&2
    return 2
  fi
  printf '%s\n' "${found[0]}"
}

BASE_REMOTE=$(match_remote "$BASE_TARGET" base) || exit $?
HEAD_REMOTE=$(match_remote "$HEAD_TARGET" head) || exit $?

printf 'BASE_REPO=%s\n' "$BASE_REPO"
printf 'HEAD_REPO=%s\n' "$HEAD_REPO"
printf 'BASE_BRANCH=%s\n' "$BASE_BRANCH"
printf 'BASE_REMOTE=%s\n' "$BASE_REMOTE"
printf 'HEAD_REMOTE=%s\n' "$HEAD_REMOTE"
printf 'CROSS_REPOSITORY=%s\n' "$CROSS"
