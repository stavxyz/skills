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
#   2  UNVERIFIED: currency could not be established: no remote, a fetch
#      failed, a remote's default branch could not be found, a count failed,
#      there is no common history, or the document may have been renamed
#      beyond recognition. Never a pass: the caller records it as a caveat.
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

# Remotes to compare against: all of them. Which remote is the canonical
# repository is a convention, not a fact git records: a branch may track a fork
# while the document's history is on origin, and `gh repo fork` makes the fork
# origin and the parent "upstream". Looking at one remote would call a stale
# checkout current in one layout or the other. origin goes first only so the
# messages read the same way from run to run.
remotes=()
has_remote origin && remotes+=(origin)
while IFS= read -r r; do
  [[ -n "$r" && "$r" != "origin" ]] && remotes+=("$r")
done < <(g remote)
[[ ${#remotes[@]} -gt 0 ]] || unknowns+=("no remote to compare against")

# No prompt may block this: two of validate's three calls run unattended,
# minutes after the operator last looked. The ssh options are added to whatever
# ssh command this repository already uses; setting GIT_SSH_COMMAND to a bare
# "ssh" would silently bypass a configured core.sshCommand or GIT_SSH.
ssh_cmd="${GIT_SSH_COMMAND:-$(g config core.sshCommand 2>/dev/null || true)}"
ssh_cmd="${ssh_cmd:-${GIT_SSH:-ssh}}"
gnet() {
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$ssh_cmd -o BatchMode=yes -o ConnectTimeout=15" \
    git -C "$root" "$@"
}

fetched=()
if [[ ${#remotes[@]} -gt 0 ]]; then
  for r in "${remotes[@]}"; do
    if fetch_err="$(gnet fetch --quiet "$r" 2>&1)"; then
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

# find_default <remote>: print "<remote>/<branch>" for the remote's default
# branch. The remote is asked first: the local refs/remotes/<r>/HEAD is a
# record of what the default was when it was last set, and after the remote
# renames master to main a plain fetch leaves it pointing at the old, frozen
# branch. A branch this clone does not have (a single-branch clone) is fetched.
# The local record and the usual names are used only when the remote does not
# say.
find_default() {
  local r=$1 ref cand name
  name="$(gnet ls-remote --symref "$r" HEAD 2>/dev/null \
          | awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2; exit }')"
  if [[ -n "$name" ]]; then
    if ! g rev-parse --verify --quiet "refs/remotes/$r/$name" >/dev/null; then
      gnet fetch --quiet "$r" "+refs/heads/$name:refs/remotes/$r/$name" >/dev/null 2>&1 || return 1
    fi
    echo "$r/$name"
    return 0
  fi
  ref="$(g symbolic-ref --quiet "refs/remotes/$r/HEAD" 2>/dev/null)" || ref=""
  if [[ -n "$ref" ]] && g rev-parse --verify --quiet "$ref" >/dev/null; then
    echo "${ref#refs/remotes/}"
    return 0
  fi
  for cand in main master; do
    if g rev-parse --verify --quiet "refs/remotes/$r/$cand" >/dev/null; then
      echo "$r/$cand"
      return 0
    fi
  done
  return 1
}

# One default branch per remote that answered.
defaults=()
strict_default=""
if [[ ${#fetched[@]} -gt 0 ]]; then
  for r in "${fetched[@]}"; do
    if d="$(find_default "$r")" && [[ -n "$d" ]]; then
      defaults+=("$d")
      # A branch named like a default branch (main, on any remote) is not a
      # feature branch: behind a default branch at all is stale.
      [[ "${d#"$r"/}" == "$branch_short" ]] && strict_default=1
    else
      unknowns+=("no remote default branch could be found on $r, so the document was not compared with it")
    fi
  done
fi
is_default() {
  local d
  [[ ${#defaults[@]} -gt 0 ]] || return 1
  for d in "${defaults[@]}"; do [[ "$d" == "$1" ]] && return 0; done
  return 1
}

# A feature branch created from a default branch (git checkout -b x
# origin/main) has it as its upstream. Code-only drift there is ordinary, so
# only the document decides, which the loop over default branches handles.
if [[ -n "$upstream" && -z "$strict_default" ]] && is_default "$upstream"; then
  upstream=""
fi
upstream_unfetched=""
if [[ -n "$upstream" ]] && ! was_fetched "$up_remote"; then
  upstream_unfetched=1
fi

count_behind() { # commits reachable from $1 and not from HEAD; empty on error
  g rev-list --count "HEAD..$1" 2>/dev/null
}

# doc_changed <ref>: did <ref> change the document since this branch left it?
# Returns 0 changed, 1 unchanged, 2 could not tell.
#  - With several merge bases (criss-cross history) it is unchanged only if it
#    is unchanged against every one of them.
#  - The document is looked for under its current path and under the path it
#    had at the merge base, so a document renamed on this branch is matched
#    with edits to its old name.
#  - git only pairs a rename when the two files are still alike. A document
#    that was moved and largely rewritten shows as one file added and another
#    deleted. If the document did not exist at the merge base, and <ref>
#    changed a path this branch deleted, that may be the document's old name:
#    could not tell.
doc_changed() {
  local ref=$1 bases mb old status a b rc saw_change="" unsure=""
  local deleted
  bases="$(g merge-base --all HEAD "$ref" 2>/dev/null)" || return 2
  [[ -n "$bases" ]] || return 2
  for mb in $bases; do
    old=""
    deleted=()
    # -z: names arrive unquoted, NUL-separated: "R<score>" old new, or
    # a one-letter status and one path.
    while IFS= read -r -d '' status; do
      case "$status" in
        R*|C*) IFS= read -r -d '' a || break; IFS= read -r -d '' b || break
               [[ "$status" == R* && "$b" == "$rel" ]] && old="$a" ;;
        D)     IFS= read -r -d '' a || break; deleted+=(":(literal)$a") ;;
        *)     IFS= read -r -d '' a || break ;;
      esac
    done < <(g diff -M -z --name-status "$mb" HEAD 2>/dev/null)
    if [[ -n "$old" ]]; then
      g diff --quiet "$mb" "$ref" -- ":(literal)$rel" ":(literal)$old" 2>/dev/null; rc=$?
    else
      g diff --quiet "$mb" "$ref" -- ":(literal)$rel" 2>/dev/null; rc=$?
    fi
    case "$rc" in
      0) ;;
      1) saw_change=1 ;;
      *) return 2 ;;
    esac
    if [[ $rc -eq 0 && -z "$old" && ${#deleted[@]} -gt 0 ]] && ! g cat-file -e "$mb:$rel" 2>/dev/null; then
      g diff --quiet "$mb" "$ref" -- "${deleted[@]}" 2>/dev/null || unsure=1
    fi
  done
  [[ -n "$saw_change" ]] && return 0
  [[ -n "$unsure" ]] && return 2
  return 1
}

behind=""
if [[ -n "$upstream" && -z "$upstream_unfetched" ]]; then
  behind="$(count_behind "$upstream")"
  if [[ ! "$behind" =~ ^[0-9]+$ ]]; then
    unknowns+=("could not count commits behind $upstream")
    behind=""
  elif [[ "$behind" -gt 0 ]]; then
    reasons+=("behind: this branch is $behind commit(s) behind $upstream")
    doc_changed "$upstream"; rc=$?
    [[ $rc -eq 0 ]] && reasons+=("the document changed in those commits: $rel")
    [[ $rc -eq 2 ]] && reasons+=("could not tell whether the document changed in those commits: $rel")
  fi
fi

# Every remote's default branch is compared. behind_default is the largest
# distance found.
behind_default=0
if [[ ${#defaults[@]} -gt 0 ]]; then
  for d in "${defaults[@]}"; do
    if [[ "$d" == "$upstream" ]]; then
      # Already compared above, as the upstream.
      [[ -n "$behind" && "$behind" -gt "$behind_default" ]] && behind_default="$behind"
      continue
    fi
    n="$(count_behind "$d")"
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then
      unknowns+=("could not count commits behind $d")
      continue
    fi
    [[ "$n" -gt "$behind_default" ]] && behind_default="$n"
    [[ "$n" -gt 0 ]] || continue
    doc_changed "$d"; rc=$?
    case "$rc" in
      0) reasons+=("the document changed on $d after this branch left it ($n commit(s) behind): $rel") ;;
      1) if [[ -n "$strict_default" ]]; then
           reasons+=("behind: branch $branch_short is $n commit(s) behind $d")
         else
           notes+=("$n commit(s) behind $d; the document is unchanged there")
         fi ;;
      *) unknowns+=("could not tell whether the document changed on $d") ;;
    esac
  done
fi
if [[ -z "$upstream" && ${#defaults[@]} -eq 0 && ${#unknowns[@]} -eq 0 ]]; then
  unknowns+=("nothing to compare against")
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
  echo "CURRENT: HEAD ${head_sha:0:12}; the document is unchanged on ${defaults[*]}"
fi
# For the caller to record: how far the code the reviewers read is behind a
# remote default branch.
echo "behind_default=$behind_default"
[[ ${#notes[@]} -gt 0 ]] && printf '  note: %s\n' "${notes[@]}"
exit 0
