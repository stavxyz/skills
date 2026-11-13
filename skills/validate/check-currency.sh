#!/usr/bin/env bash
# check-currency.sh: is the checkout holding a spec or plan up to date with its
# remote, and has the document itself changed there?
#
# Usage:
#   check-currency.sh <path-to-doc.md>
#   check-currency.sh <path-to-doc.md> --since <sha>   # re-check later in a run
#
# Exit codes:
#   0  CURRENT: nothing below applies
#   1  STALE: one line per reason on stdout. Any of:
#        - the branch is behind its upstream
#        - the document changed on the remote default branch after this branch
#          left it
#        - with --since, HEAD is no longer that commit
#   2  UNVERIFIED: currency could not be established (no upstream and no
#      remote default branch, or the fetch failed). Never a pass: the caller
#      records it as a caveat.
#   3  usage error, not a git repository, or the document is not in the repo
#
# Why this exists: validate's reviewers read the working copy. If that copy is
# behind, they verify claims against code that is no longer current, and the
# edits validate then applies revert whatever landed on the remote in the
# meantime. The mtime check cannot see it: a file that is stale because nobody
# pulled has not been touched. One run blessed a plan this way while another
# session had merged a correction to that same plan.
#
# Commits BEHIND is the direction that matters. Commits ahead, and `git status
# -sb`, both look like currency checks and detect nothing.
#
# On a feature branch, being behind the default branch is ordinary and does not
# stop the run; it is reported as a count. It stops the run only when the
# document itself changed on the default branch since the branch point, because
# then validate would be editing an outdated copy of it.

set -uo pipefail

usage() {
  echo "usage: check-currency.sh <path-to-doc.md> [--since SHA]" >&2
  exit 3
}

[[ $# -ge 1 ]] || usage
doc="$1"; shift
since=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) [[ $# -ge 2 ]] || usage; since="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 3 ;;
  esac
done

[[ -f "$doc" ]] || { echo "not a file: $doc" >&2; exit 3; }
dir="$(cd "$(dirname "$doc")" && pwd -P)" || exit 3
root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repository: $doc" >&2; exit 3; }
root="$(cd "$root" && pwd -P)"
rel="${dir#"$root"}"; rel="${rel#/}"
rel="${rel:+$rel/}$(basename "$doc")"

g() { git -C "$root" "$@"; }

head_sha="$(g rev-parse HEAD 2>/dev/null)" || { echo "repository has no commits" >&2; exit 3; }

reasons=()
notes=()

if [[ -n "$since" ]]; then
  since_full="$(g rev-parse --verify --quiet "$since^{commit}")" || { echo "--since is not a commit: $since" >&2; exit 3; }
  [[ "$head_sha" == "$since_full" ]] || reasons+=("HEAD moved during the run: was ${since_full:0:12}, now ${head_sha:0:12}")
fi

# The upstream of the current branch, if it has one.
upstream="$(g rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || upstream=""
# The remote to fetch: the upstream's, else origin, else the only remote.
if [[ -n "$upstream" ]]; then
  remote="${upstream%%/*}"
elif g remote | grep -qx origin; then
  remote=origin
elif [[ "$(g remote | wc -l | tr -d ' ')" == "1" ]]; then
  remote="$(g remote)"
else
  remote=""
fi

if [[ -z "$remote" ]]; then
  echo "UNVERIFIED: no upstream and no remote to compare against"
  [[ ${#reasons[@]} -gt 0 ]] && { echo "STALE:"; printf '  %s\n' "${reasons[@]}"; exit 1; }
  exit 2
fi

if ! fetch_err="$(g fetch --quiet "$remote" 2>&1)"; then
  [[ ${#reasons[@]} -gt 0 ]] && { echo "STALE:"; printf '  %s\n' "${reasons[@]}"; exit 1; }
  echo "UNVERIFIED: could not fetch $remote: ${fetch_err:-unknown error}"
  exit 2
fi

# The remote's default branch, as the local clone records it.
default_ref="$(g symbolic-ref --quiet "refs/remotes/$remote/HEAD" 2>/dev/null)" || default_ref=""
default="${default_ref#refs/remotes/}"
if [[ -z "$default" ]]; then
  for cand in "$remote/main" "$remote/master"; do
    if g rev-parse --verify --quiet "$cand" >/dev/null; then default="$cand"; break; fi
  done
fi

if [[ -z "$upstream" && -z "$default" ]]; then
  [[ ${#reasons[@]} -gt 0 ]] && { echo "STALE:"; printf '  %s\n' "${reasons[@]}"; exit 1; }
  echo "UNVERIFIED: the branch has no upstream and $remote has no default branch this clone knows"
  exit 2
fi

count_behind() { # commits reachable from $1 and not from HEAD; empty on error
  g rev-list --count "HEAD..$1" 2>/dev/null
}

if [[ -n "$upstream" ]]; then
  behind="$(count_behind "$upstream")"
  if [[ ! "$behind" =~ ^[0-9]+$ ]]; then
    echo "UNVERIFIED: could not count commits behind $upstream"
    exit 2
  fi
  if [[ "$behind" -gt 0 ]]; then
    reasons+=("behind: this branch is $behind commit(s) behind $upstream")
    if ! g diff --quiet "HEAD...$upstream" -- "$rel" 2>/dev/null; then
      reasons+=("the document changed in those commits: $rel")
    fi
  fi
fi

if [[ -n "$default" && "$default" != "$upstream" ]]; then
  behind_default="$(count_behind "$default")"
  if [[ ! "$behind_default" =~ ^[0-9]+$ ]]; then
    echo "UNVERIFIED: could not count commits behind $default"
    exit 2
  fi
  if [[ "$behind_default" -gt 0 ]]; then
    # Three dots: what the default branch changed since this branch left it.
    if ! g diff --quiet "HEAD...$default" -- "$rel" 2>/dev/null; then
      reasons+=("the document changed on $default after this branch left it ($behind_default commit(s) behind): $rel")
    else
      notes+=("$behind_default commit(s) behind $default; the document is unchanged there")
    fi
  fi
fi

if [[ ${#reasons[@]} -gt 0 ]]; then
  echo "STALE:"
  printf '  %s\n' "${reasons[@]}"
  exit 1
fi

echo "CURRENT: HEAD ${head_sha:0:12} is not behind ${upstream:-$default}"
[[ ${#notes[@]} -gt 0 ]] && printf '  note: %s\n' "${notes[@]}"
exit 0
