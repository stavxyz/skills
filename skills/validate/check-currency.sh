#!/usr/bin/env bash
# check-currency.sh: is the checkout holding a spec or plan up to date with its
# remote, and has the document itself changed there?
#
# Usage:
#   check-currency.sh <path-to-doc.md>
#   check-currency.sh <path-to-doc.md> --since <sha>   # re-check later in a run
#
# Exit codes:
#   0  CURRENT: nothing below applies. Also prints behind_default=<n>, the
#      number of commits the checkout is behind the remote default branch
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

doc=""
since=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) [[ $# -ge 2 ]] || usage; since="$2"; shift 2 ;;
    --*) echo "unknown arg: $1" >&2; exit 3 ;;
    *) [[ -z "$doc" ]] || usage; doc="$1"; shift ;;
  esac
done
[[ -n "$doc" ]] || usage

[[ -f "$doc" ]] || { echo "not a file: $doc" >&2; exit 3; }
# A document that is a symlink is validated as the file it points at, so that
# is the path whose history matters.
hops=0
while [[ -L "$doc" ]]; do
  hops=$((hops + 1)); [[ $hops -le 20 ]] || { echo "too many symlinks: $doc" >&2; exit 3; }
  target="$(readlink "$doc")"
  case "$target" in
    /*) doc="$target" ;;
    *)  doc="$(dirname "$doc")/$target" ;;
  esac
done
dir="$(cd "$(dirname "$doc")" && pwd -P)" || exit 3
root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repository: $doc" >&2; exit 3; }
root="$(cd "$root" && pwd -P)"
rel="${dir#"$root"}"; rel="${rel#/}"
rel="${rel:+$rel/}$(basename "$doc")"

g() { git -C "$root" "$@"; }

# On a case-insensitive volume the path as typed can differ in case from the
# name git tracks, and a pathspec in the wrong case matches nothing: every
# "did the document change" question would then answer no.
if [[ "$(g config --type=bool core.ignorecase 2>/dev/null)" == "true" ]]; then
  tracked="$(g ls-files -- ":(icase,literal)$rel" 2>/dev/null | head -n 1)"
  [[ -n "$tracked" ]] && rel="$tracked"
fi

head_sha="$(g rev-parse HEAD 2>/dev/null)" || { echo "repository has no commits" >&2; exit 3; }

reasons=()
notes=()

if [[ -n "$since" ]]; then
  since_full="$(g rev-parse --verify --quiet "$since^{commit}")" || { echo "--since is not a commit: $since" >&2; exit 3; }
  [[ "$head_sha" == "$since_full" ]] || reasons+=("HEAD moved during the run: was ${since_full:0:12}, now ${head_sha:0:12}")
fi

# stale_or <exit> <message>: currency could not be established. Reasons already
# found still win: a run whose HEAD moved must not come back as merely
# "unverified", which the caller is allowed to continue past.
stale_or() {
  if [[ ${#reasons[@]} -gt 0 ]]; then
    echo "STALE:"
    printf '  %s\n' "${reasons[@]}"
    exit 1
  fi
  echo "UNVERIFIED: $2"
  exit "$1"
}

# The current branch's upstream and the remote it lives on. Asked of git, not
# parsed out of "remote/branch": a remote's name may contain a slash, and a
# branch may track a local branch, whose "remote" is ".".
branch_ref="$(g symbolic-ref -q HEAD 2>/dev/null)" || branch_ref=""
upstream=""
up_remote=""
if [[ -n "$branch_ref" ]]; then
  upstream="$(g for-each-ref --format='%(upstream:short)' "$branch_ref")"
  up_remote="$(g for-each-ref --format='%(upstream:remotename)' "$branch_ref")"
  if [[ "$up_remote" == "." || -z "$up_remote" ]]; then
    # Tracking a local branch says nothing about the remote.
    upstream=""
    up_remote=""
  fi
fi

has_remote() { g remote | grep -qxF -- "$1"; }

# Remotes to compare against: the upstream's, and origin. On a fork setup the
# branch tracks the fork while the document's real history is on origin, so
# looking only at the upstream's remote would call a stale checkout current.
remotes=()
[[ -n "$up_remote" ]] && remotes+=("$up_remote")
if has_remote origin && [[ "$up_remote" != "origin" ]]; then
  remotes+=(origin)
fi
if [[ ${#remotes[@]} -eq 0 && "$(g remote | wc -l | tr -d ' ')" == "1" ]]; then
  remotes+=("$(g remote)")
fi

[[ ${#remotes[@]} -gt 0 ]] || stale_or 2 "no upstream and no remote to compare against"

# No prompt may block this: two of validate's three calls run unattended,
# minutes after the operator last looked.
for r in "${remotes[@]}"; do
  if ! fetch_err="$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes -o ConnectTimeout=15" \
        git -C "$root" fetch --quiet "$r" 2>&1)"; then
    stale_or 2 "could not fetch $r: ${fetch_err:-unknown error}"
  fi
done

# The default branch: origin's if there is an origin, else the first remote's.
default=""
for r in origin "${remotes[@]}"; do
  has_remote "$r" || continue
  ref="$(g symbolic-ref --quiet "refs/remotes/$r/HEAD" 2>/dev/null)" || ref=""
  if [[ -n "$ref" ]]; then default="${ref#refs/remotes/}"; break; fi
  for cand in "$r/main" "$r/master"; do
    if g rev-parse --verify --quiet "refs/remotes/$cand" >/dev/null; then default="$cand"; break 2; fi
  done
done

# A feature branch created from the remote default branch (git checkout -b x
# origin/main) has the default branch as its upstream. It is still a feature
# branch: code-only drift on the default branch is ordinary there, so the
# default-branch rule applies, not "must be level with the upstream".
branch_short="${branch_ref#refs/heads/}"
if [[ -n "$upstream" && "$upstream" == "$default" && "${default#"$up_remote"/}" != "$branch_short" ]]; then
  upstream=""
fi

[[ -n "$upstream" || -n "$default" ]] || stale_or 2 "the branch has no upstream and no remote default branch is known to this clone"

count_behind() { # commits reachable from $1 and not from HEAD; empty on error
  g rev-list --count "HEAD..$1" 2>/dev/null
}

# doc_changed <ref>: did <ref> change the document since this branch left it?
# Returns 0 changed, 1 unchanged, 2 could not tell. The document is looked for
# under its current path and under the path it had at the branch point, so a
# document renamed on this branch is still matched with edits to its old name.
doc_changed() {
  local mb old rc
  mb="$(g merge-base HEAD "$1" 2>/dev/null)" || return 2
  old="$(g diff -M --name-status "$mb" HEAD 2>/dev/null | awk -F'\t' -v p="$rel" '$1 ~ /^R/ && $3 == p { print $2; exit }')"
  if [[ -n "$old" ]]; then
    g diff --quiet "$mb" "$1" -- ":(literal)$rel" ":(literal)$old" 2>/dev/null; rc=$?
  else
    g diff --quiet "$mb" "$1" -- ":(literal)$rel" 2>/dev/null; rc=$?
  fi
  case "$rc" in
    0) return 1 ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
}

if [[ -n "$upstream" ]]; then
  behind="$(count_behind "$upstream")"
  [[ "$behind" =~ ^[0-9]+$ ]] || stale_or 2 "could not count commits behind $upstream"
  if [[ "$behind" -gt 0 ]]; then
    reasons+=("behind: this branch is $behind commit(s) behind $upstream")
    doc_changed "$upstream"; rc=$?
    [[ $rc -eq 0 ]] && reasons+=("the document changed in those commits: $rel")
    [[ $rc -eq 2 ]] && reasons+=("could not tell whether the document changed in those commits: $rel")
  fi
fi

behind_default=0
if [[ -z "$default" ]]; then
  notes+=("no remote default branch is known to this clone, so only $upstream was compared")
fi
if [[ -n "$default" && "$default" != "$upstream" ]]; then
  behind_default="$(count_behind "$default")"
  [[ "$behind_default" =~ ^[0-9]+$ ]] || stale_or 2 "could not count commits behind $default"
  if [[ "$behind_default" -gt 0 ]]; then
    doc_changed "$default"; rc=$?
    case "$rc" in
      0) reasons+=("the document changed on $default after this branch left it ($behind_default commit(s) behind): $rel") ;;
      1) notes+=("$behind_default commit(s) behind $default; the document is unchanged there") ;;
      *) stale_or 2 "could not tell whether the document changed on $default" ;;
    esac
  fi
fi

if [[ ${#reasons[@]} -gt 0 ]]; then
  echo "STALE:"
  printf '  %s\n' "${reasons[@]}"
  exit 1
fi

if [[ -n "$upstream" ]]; then
  echo "CURRENT: HEAD ${head_sha:0:12} is not behind $upstream"
else
  echo "CURRENT: HEAD ${head_sha:0:12}; the document is unchanged on $default"
fi
# For the caller to record: how far the code the reviewers read is behind the
# default branch. Zero when the default branch is the upstream.
echo "behind_default=$behind_default"
[[ ${#notes[@]} -gt 0 ]] && printf '  note: %s\n' "${notes[@]}"
exit 0
