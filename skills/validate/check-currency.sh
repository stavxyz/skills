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
dir="$(cd -P "$(dirname "$doc")" && pwd -P)" || exit 3
root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repository: $doc" >&2; exit 3; }
root="$(cd -P "$root" && pwd -P)"
rel="${dir#"$root"}"; rel="${rel#/}"
rel="${rel:+$rel/}$(basename "$doc")"

g() { git -C "$root" "$@"; }

# On a case-insensitive volume the path as typed can differ in case from the
# name git tracks, and a pathspec in the wrong case matches nothing: every
# "did the document change" question would then answer no. The exact spelling
# wins when it is tracked (two tracked files may differ only in case), and the
# lookup reads a NUL-terminated name, because git quotes a path that holds
# non-ASCII or a quote when it prints it any other way.
if ! g ls-files --error-unmatch -- ":(literal)$rel" >/dev/null 2>&1 \
   && [[ "$(g config --type=bool core.ignorecase 2>/dev/null)" == "true" ]]; then
  tracked=""
  IFS= read -r -d '' tracked < <(g ls-files -z -- ":(icase,literal)$rel" 2>/dev/null) || true
  [[ -n "$tracked" ]] && rel="$tracked"
fi

head_sha="$(g rev-parse HEAD 2>/dev/null)" || { echo "repository has no commits" >&2; exit 3; }

# Three lists decide the verdict, and nothing exits before every check has run:
# an early "could not tell" must not skip the check that would have found the
# document changed. reasons -> STALE. unknowns (and no reasons) -> UNVERIFIED.
reasons=()
unknowns=()
notes=()

if [[ -n "$since" ]]; then
  since_full="$(g rev-parse --verify --quiet "$since^{commit}")" || { echo "--since is not a commit: $since" >&2; exit 3; }
  [[ "$head_sha" == "$since_full" ]] || reasons+=("HEAD moved during the run: was ${since_full:0:12}, now ${head_sha:0:12}")
fi

# The current branch's upstream and the remote it lives on. Asked of git, not
# parsed out of "remote/branch": a remote's name may contain a slash, and a
# branch may track a local branch, whose "remote" is ".".
branch_ref="$(g symbolic-ref -q HEAD 2>/dev/null)" || branch_ref=""
branch_short="${branch_ref#refs/heads/}"
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
[[ ${#remotes[@]} -gt 0 ]] || unknowns+=("no upstream and no remote to compare against")

# No prompt may block this: two of validate's three calls run unattended,
# minutes after the operator last looked. The ssh options are added to whatever
# ssh command this repository already uses; setting GIT_SSH_COMMAND to a bare
# "ssh" would silently bypass a configured core.sshCommand or GIT_SSH.
ssh_cmd="${GIT_SSH_COMMAND:-$(g config core.sshCommand 2>/dev/null || true)}"
ssh_cmd="${ssh_cmd:-${GIT_SSH:-ssh}}"
gfetch() {
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$ssh_cmd -o BatchMode=yes -o ConnectTimeout=15" \
    git -C "$root" fetch --quiet "$@" 2>&1
}

fetched=()
if [[ ${#remotes[@]} -gt 0 ]]; then
  for r in "${remotes[@]}"; do
    if fetch_err="$(gfetch "$r")"; then
      fetched+=("$r")
    else
      unknowns+=("could not fetch $r: ${fetch_err:-unknown error}")
    fi
  done
fi
was_fetched() {
  local f
  [[ ${#fetched[@]} -gt 0 ]] || return 1
  for f in "${fetched[@]}"; do [[ "$f" == "$1" ]] && return 0; done
  return 1
}

# The default branch: origin's if origin answered, else another fetched
# remote's. A clone that tracks one branch only does not have it locally, so
# as a last step the remote is asked which branch its HEAD names, and that
# branch is fetched.
default=""
default_remote=""
find_default() {
  local r=$1 ref cand name
  ref="$(g symbolic-ref --quiet "refs/remotes/$r/HEAD" 2>/dev/null)" || ref=""
  if [[ -n "$ref" ]] && g rev-parse --verify --quiet "$ref" >/dev/null; then
    default="${ref#refs/remotes/}"; default_remote="$r"; return 0
  fi
  for cand in main master; do
    if g rev-parse --verify --quiet "refs/remotes/$r/$cand" >/dev/null; then
      default="$r/$cand"; default_remote="$r"; return 0
    fi
  done
  name="$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$ssh_cmd -o BatchMode=yes -o ConnectTimeout=15" \
          git -C "$root" ls-remote --symref "$r" HEAD 2>/dev/null \
          | awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2; exit }')"
  [[ -n "$name" ]] || return 1
  gfetch "$r" "+refs/heads/$name:refs/remotes/$r/$name" >/dev/null || return 1
  default="$r/$name"; default_remote="$r"
}
if [[ ${#fetched[@]} -gt 0 ]]; then
  for r in origin "${fetched[@]}"; do
    was_fetched "$r" || continue
    find_default "$r" && break
  done
fi
default_name="${default#"$default_remote"/}"

# What the branch must be level with, and what only the document decides.
#  - A branch named like the default branch (main, on any remote) is not a
#    feature branch: behind the default branch at all is stale.
#  - A feature branch created from the default branch (git checkout -b x
#    origin/main) has the default branch as its upstream. Code-only drift there
#    is ordinary, so only the document decides.
strict_default=""
if [[ -n "$default" && "$branch_short" == "$default_name" ]]; then
  strict_default=1
fi
if [[ -n "$upstream" && "$upstream" == "$default" && -z "$strict_default" ]]; then
  upstream=""
fi
if [[ -n "$upstream" ]] && ! was_fetched "$up_remote"; then
  upstream_unfetched=1
else
  upstream_unfetched=""
fi

count_behind() { # commits reachable from $1 and not from HEAD; empty on error
  g rev-list --count "HEAD..$1" 2>/dev/null
}

# doc_changed <ref>: did <ref> change the document since this branch left it?
# Returns 0 changed, 1 unchanged, 2 could not tell. The document is looked for
# under its current path and under the path it had at the branch point, so a
# document renamed on this branch is still matched with edits to its old name.
# With several merge bases (criss-cross history) it is unchanged if it is
# unchanged against any one of them.
doc_changed() {
  local ref=$1 bases mb old status a b rc saw_change=""
  bases="$(g merge-base --all HEAD "$ref" 2>/dev/null)" || return 2
  [[ -n "$bases" ]] || return 2
  for mb in $bases; do
    old=""
    # -z: names arrive unquoted, NUL-separated, as "R<score>" old new.
    while IFS= read -r -d '' status; do
      case "$status" in
        R*|C*) IFS= read -r -d '' a || break; IFS= read -r -d '' b || break
               [[ "$status" == R* && "$b" == "$rel" ]] && old="$a" ;;
        *)     IFS= read -r -d '' a || break ;;
      esac
    done < <(g diff -M -z --name-status "$mb" HEAD 2>/dev/null)
    if [[ -n "$old" ]]; then
      g diff --quiet "$mb" "$ref" -- ":(literal)$rel" ":(literal)$old" 2>/dev/null; rc=$?
    else
      g diff --quiet "$mb" "$ref" -- ":(literal)$rel" 2>/dev/null; rc=$?
    fi
    case "$rc" in
      0) return 1 ;;
      1) saw_change=1 ;;
      *) return 2 ;;
    esac
  done
  [[ -n "$saw_change" ]] && return 0
  return 2
}

if [[ -n "$upstream" && -z "$upstream_unfetched" ]]; then
  behind="$(count_behind "$upstream")"
  if [[ ! "$behind" =~ ^[0-9]+$ ]]; then
    unknowns+=("could not count commits behind $upstream")
  elif [[ "$behind" -gt 0 ]]; then
    reasons+=("behind: this branch is $behind commit(s) behind $upstream")
    doc_changed "$upstream"; rc=$?
    [[ $rc -eq 0 ]] && reasons+=("the document changed in those commits: $rel")
    [[ $rc -eq 2 ]] && reasons+=("could not tell whether the document changed in those commits: $rel")
  fi
fi

behind_default=""
if [[ -z "$default" ]]; then
  [[ ${#fetched[@]} -gt 0 ]] && unknowns+=("no remote default branch could be found, so the document was not compared with one")
elif [[ "$default" == "$upstream" ]]; then
  behind_default="${behind:-}"
else
  behind_default="$(count_behind "$default")"
  if [[ ! "$behind_default" =~ ^[0-9]+$ ]]; then
    unknowns+=("could not count commits behind $default")
    behind_default=""
  elif [[ "$behind_default" -gt 0 ]]; then
    doc_changed "$default"; rc=$?
    case "$rc" in
      0) reasons+=("the document changed on $default after this branch left it ($behind_default commit(s) behind): $rel") ;;
      1) if [[ -n "$strict_default" ]]; then
           reasons+=("behind: branch $branch_short is $behind_default commit(s) behind $default")
         else
           notes+=("$behind_default commit(s) behind $default; the document is unchanged there")
         fi ;;
      *) unknowns+=("could not tell whether the document changed on $default") ;;
    esac
  fi
fi

if [[ ${#reasons[@]} -gt 0 ]]; then
  echo "STALE:"
  printf '  %s\n' "${reasons[@]}"
  exit 1
fi
if [[ ${#unknowns[@]} -gt 0 ]]; then
  echo "UNVERIFIED:"
  printf '  %s\n' "${unknowns[@]}"
  exit 2
fi

if [[ -n "$upstream" ]]; then
  echo "CURRENT: HEAD ${head_sha:0:12} is not behind $upstream"
else
  echo "CURRENT: HEAD ${head_sha:0:12}; the document is unchanged on $default"
fi
# For the caller to record: how far the code the reviewers read is behind the
# default branch.
echo "behind_default=$behind_default"
[[ ${#notes[@]} -gt 0 ]] && printf '  note: %s\n' "${notes[@]}"
exit 0
