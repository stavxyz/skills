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
#        - the branch is behind the branch it tracks, or behind a branch of
#          the same name on any remote (another session pushed to it)
#        - the document changed on a remote's default branch after this branch
#          left it
#        - with --since, HEAD is no longer that commit
#      A remote that should not count is excluded with
#        git config --add validate.ignoreRemote <name>
#   2  UNVERIFIED: currency could not be established: no remote, a remote did
#      not answer within CHECK_CURRENCY_NET_TIMEOUT seconds (default 60) or
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

# Every git call below names its repository with -C. An inherited GIT_DIR (a
# hook, `git rebase --exec`) would override that and point them all elsewhere.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

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
# The repository the path as typed sits in. validate takes its HEAD from there,
# so a document that is a symlink into another repository would be checked
# against one repository and recorded against another.
typed_root="$(git -C "$(dirname "$doc")" rev-parse --show-toplevel 2>/dev/null)" || typed_root=""
[[ -n "$typed_root" ]] && typed_root="$(cd -P "$typed_root" && pwd -P)"
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
if [[ -n "$typed_root" && "$typed_root" != "$root" ]]; then
  echo "the document is a symlink into another repository ($root); run validate on the file itself" >&2
  exit 3
fi
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

# What this branch is configured to track. Read from the branch's config, not
# from a remote-tracking ref: a clone whose fetch refspec leaves a branch out
# (git clone --single-branch) has no tracking ref for it, and git then reports
# no upstream at all.
branch_ref="$(g symbolic-ref -q HEAD 2>/dev/null)" || branch_ref=""
branch_short="${branch_ref#refs/heads/}"
if [[ -z "$branch_short" ]]; then
  # Detached (or mid-rebase): which branch this is, and so which remote branch
  # another session might have pushed to, cannot be told.
  unknowns+=("HEAD is detached, so this checkout's branch on the remote could not be compared")
fi
up_remote=""
up_branch=""
if [[ -n "$branch_short" ]]; then
  up_remote="$(g config "branch.$branch_short.remote" 2>/dev/null)" || up_remote=""
  up_branch="$(g config "branch.$branch_short.merge" 2>/dev/null)" || up_branch=""
  if [[ -n "$up_branch" && "$up_branch" != refs/heads/* ]]; then
    unknowns+=("the branch's upstream is not a branch ($up_branch), so it was not compared")
    up_remote=""
    up_branch=""
  fi
  up_branch="${up_branch#refs/heads/}"
  if [[ "$up_remote" == "." || -z "$up_remote" || -z "$up_branch" ]]; then
    # Tracking a local branch, or nothing, says nothing about a remote.
    up_remote=""
    up_branch=""
  fi
fi

remote_names="$(g remote 2>/dev/null || true)"
has_remote() { grep -qxF -- "$1" <<<"$remote_names"; }
if [[ -n "$up_remote" ]] && ! has_remote "$up_remote"; then
  unknowns+=("the branch's upstream remote is not a configured remote: $up_remote")
  up_remote=""
  up_branch=""
fi

# Remotes to compare against: all of them. Which remote is the canonical
# repository is a convention, not a fact git records: a branch may track a fork
# while the document's history is on origin, and `gh repo fork` makes the fork
# origin and the parent "upstream". origin goes first only so the messages
# read the same way from run to run.
# A remote whose default branch should not count (a mirror, an unrelated
# project, a personal fork whose main runs ahead) is named in git config, once
# per remote:
#   git config --add validate.ignoreRemote <name>
# Only its default branch is left out. Its copy of this branch, and the branch
# this one tracks, are still compared: those are where another session pushes,
# and ignoring them would turn a stale checkout into a current one.
ignored="$(g config --get-all validate.ignoreRemote 2>/dev/null || true)"
is_ignored() { [[ -n "$ignored" ]] && grep -qxF -- "$1" <<<"$ignored"; }
remotes=()
has_remote origin && remotes+=(origin)
while IFS= read -r r; do
  [[ -n "$r" && "$r" != "origin" ]] && remotes+=("$r")
done < <(g remote)
[[ ${#remotes[@]} -gt 0 ]] || unknowns+=("no remote to compare against")

# Network calls. No prompt may block one, and none may run for ever: two of
# validate's three calls run unattended, and a remote that accepts a connection
# and then says nothing would otherwise hang the whole check. Each call gets a
# wall-clock limit, so a dead remote becomes one "could not tell" and the other
# remotes still decide. The ssh options are added to whatever ssh command this
# repository already uses; a bare "ssh" would bypass a configured
# core.sshCommand or GIT_SSH.
# 25 seconds a call keeps a run with two dead remotes inside the two minutes a
# caller commonly allows one command, so the verdict still prints.
net_timeout="${CHECK_CURRENCY_NET_TIMEOUT:-25}"
[[ "$net_timeout" =~ ^[0-9]+$ && "$net_timeout" -gt 0 ]] || net_timeout=25
ssh_cmd="${GIT_SSH_COMMAND:-$(g config core.sshCommand 2>/dev/null || true)}"
if [[ -z "$ssh_cmd" ]]; then
  # GIT_SSH is a program path, not a command line: quote it for the shell git
  # hands GIT_SSH_COMMAND to.
  if [[ -n "${GIT_SSH:-}" ]]; then ssh_cmd="$(printf '%q' "$GIT_SSH")"; else ssh_cmd=ssh; fi
fi
ssh_cmd="$ssh_cmd -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
# The limit is enforced on the whole process group. Killing git alone is not
# enough: its transport helper (git-remote-https, ssh) keeps running and keeps
# the output pipe open, so the caller would go on waiting for it. Because the
# group is its own, an interrupt aimed at this script would miss it, so the
# wrapper passes INT, TERM, and HUP on.
# shellcheck disable=SC2016  # a perl program, not shell
net_limit='my $t = shift; my $pid = fork(); defined $pid or exit 127;
if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127 }
$SIG{ALRM} = sub { kill "TERM", -$pid; select(undef, undef, undef, 0.5); kill "KILL", -$pid; exit 124 };
for my $sig (qw(INT TERM HUP)) { $SIG{$sig} = sub { kill "TERM", -$pid; exit 130 } }
alarm $t; waitpid($pid, 0);
exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);'
net() {
  if command -v perl >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true SSH_ASKPASS=true GIT_SSH_COMMAND="$ssh_cmd" \
      perl -e "$net_limit" "$net_timeout" \
      git -C "$root" -c core.askPass=true -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 "$@"
  else
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true SSH_ASKPASS=true GIT_SSH_COMMAND="$ssh_cmd" \
      git -C "$root" -c core.askPass=true -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 "$@"
  fi
}
command -v perl >/dev/null 2>&1 || notes+=("perl is not installed, so network calls had no time limit")
# git 2.29 and later can leave FETCH_HEAD alone.
fetch_quiet=(fetch --quiet --no-tags)
fetch_help="$(g fetch -h 2>&1 || true)"
grep -q -- "write-fetch-head" <<<"$fetch_help" && fetch_quiet+=(--no-write-fetch-head)
first_line() { head -n 1 <<<"$1"; }

# What to compare with. Each remote is asked what it holds now (ls-remote), and
# the branches that matter are fetched by name into refs/check-currency/<pid>/,
# which this run owns. The clone's own remote-tracking refs are not used: they
# are only as fresh as the configured refspec makes them, and a ref this
# script once created outside that refspec would never be updated again.
#
# Per remote, the branches that matter are:
#   - its default branch (the document rule, or strict if this branch has the
#     same name: main behind main is stale whatever it tracks);
#   - the branch this one is configured to track (strict: behind it is stale);
#   - a branch with this branch's own name (strict: it is the same branch,
#     where another session pushes, whether or not it is the configured
#     upstream).
# The refs live in a namespace of this run's own and are deleted on exit, along
# with any left by a run that died: a check should leave nothing behind, a
# leftover ref named like a branch would block fetching a later branch whose
# name nests under it (feat, then feat/x), and refs outside refs/remotes would
# travel with a `git push --mirror`.
ref_ns="refs/check-currency/$$"
# shellcheck disable=SC2329  # both are reached through the EXIT trap
drop_refs() { # delete every ref under the given prefix
  g for-each-ref --format='delete %(refname)' "$1" 2>/dev/null | g update-ref --stdin 2>/dev/null
}
# shellcheck disable=SC2329
cleanup_refs() {
  drop_refs "$ref_ns/"
  local ref pid
  while IFS= read -r ref; do
    pid="${ref#refs/check-currency/}"; pid="${pid%%/*}"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      kill -0 "$pid" 2>/dev/null || drop_refs "refs/check-currency/$pid/"
    else
      drop_refs "$ref"   # a ref from before runs had their own namespace
    fi
  done < <(g for-each-ref --format='%(refname)' refs/check-currency/ 2>/dev/null)
}
trap cleanup_refs EXIT

t_disp=()   # how the target is named in messages, e.g. origin/main
t_ref=()    # the private ref holding what was fetched
t_kind=()   # upstream | same | default
t_isdef=()  # 1 when it is its remote's default branch
t_remote=() # the remote's name (it may contain a slash, so it is not parsed back out)
if [[ ${#remotes[@]} -gt 0 ]]; then
  for r in "${remotes[@]}"; do
    if ! listing="$(net ls-remote --symref "$r" HEAD 'refs/heads/*' 2>&1)"; then
      unknowns+=("could not fetch $r: $(first_line "${listing:-no answer within ${net_timeout}s}")")
      continue
    fi
    dname="$(awk -F'\t' '$2 == "HEAD" && $1 ~ /^ref: refs\/heads\// { sub("^ref: refs/heads/", "", $1); print $1; exit }' <<<"$listing")"
    on_remote() { awk -F'\t' -v w="refs/heads/$1" '$2 == w { f = 1 } END { exit !f }' <<<"$listing"; }
    ign=""
    if is_ignored "$r"; then
      ign=1
      notes+=("the default branch of $r is ignored (validate.ignoreRemote)")
    fi
    if [[ -z "$dname" ]] || ! on_remote "$dname"; then
      [[ -n "$ign" ]] || unknowns+=("no remote default branch could be found on $r, so the document was not compared with it")
      dname=""
    fi
    want=()
    # An ignored remote's default branch is skipped, unless it is the very
    # branch this one tracks.
    if [[ -n "$dname" ]]; then
      if [[ -z "$ign" || ( "$r" == "$up_remote" && "$dname" == "$up_branch" ) ]]; then
        want+=("$dname")
      fi
    fi
    if [[ -n "$branch_short" && "$branch_short" != "$dname" ]] && on_remote "$branch_short"; then
      want+=("$branch_short")
    fi
    # On an ignored remote, a branch that shares its name with that remote's
    # default branch (main on a fork) IS the ignored default: skip it unless
    # it is the upstream. Any other own-name branch is still compared.
    if [[ "$r" == "$up_remote" && "$up_branch" != "$dname" && "$up_branch" != "$branch_short" ]]; then
      if on_remote "$up_branch"; then
        want+=("$up_branch")
      fi
    fi
    if [[ "$r" == "$up_remote" ]] && ! on_remote "$up_branch"; then
      unknowns+=("could not count commits behind $r/$up_branch: the branch is no longer on $r")
    fi
    [[ ${#want[@]} -gt 0 ]] || continue
    refspecs=()
    for n in "${want[@]}"; do refspecs+=("+refs/heads/$n:$ref_ns/$r/$n"); done
    if ! err="$(net "${fetch_quiet[@]}" "$r" "${refspecs[@]}" 2>&1)"; then
      unknowns+=("could not fetch $r: $(first_line "${err:-no answer within ${net_timeout}s}")")
      continue
    fi
    for n in "${want[@]}"; do
      if [[ "$n" == "$branch_short" ]]; then
        if [[ "$r" == "$up_remote" && "$n" == "$up_branch" ]]; then kind=upstream; else kind=same; fi
      elif [[ "$r" == "$up_remote" && "$n" == "$up_branch" && "$n" != "$dname" ]]; then
        kind=upstream
      else
        # The default branch. A feature branch created from it (git checkout
        # -b x origin/main) tracks it, and code-only drift there is ordinary,
        # so the document decides.
        kind=default
      fi
      t_disp+=("$r/$n")
      t_ref+=("$ref_ns/$r/$n")
      t_remote+=("$r")
      t_kind+=("$kind")
      if [[ "$n" == "$dname" ]]; then t_isdef+=(1); else t_isdef+=(0); fi
    done
  done
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

# Every target is compared before the verdict.
behind_default=0
upstream_disp=""
default_disps=""
i=0
while [[ $i -lt ${#t_ref[@]} ]]; do
  disp="${t_disp[$i]}"; ref="${t_ref[$i]}"; kind="${t_kind[$i]}"; isdef="${t_isdef[$i]}"; rname="${t_remote[$i]}"
  i=$((i + 1))
  [[ "$kind" == "upstream" ]] && upstream_disp="$disp"
  [[ "$isdef" == "1" ]] && default_disps="${default_disps:+$default_disps, }$disp"
  n="$(count_behind "$ref")"
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    unknowns+=("could not count commits behind $disp")
    continue
  fi
  [[ "$isdef" == "1" && "$n" -gt "$behind_default" ]] && behind_default="$n"
  [[ "$n" -gt 0 ]] || continue
  # No exception is made for a branch that was pushed from here and then
  # amended or rebased here, although that checkout is "behind" only its own
  # earlier push. Telling that case apart needs proof that every commit missing
  # here was pushed from this checkout, and git does not keep it: the branch's
  # reflog holds pulled and cloned commits exactly like local ones, a clone
  # leaves no entry in the tracking ref's reflog, and another worktree's push
  # is logged like this one's. Each rule tried on that evidence called some
  # checkout current that had dropped another session's commit. So the answer
  # is STALE, and the remedy is in the message: push the rewrite first.
  case "$kind" in
    upstream|same)
      if [[ "$kind" == "upstream" ]]; then
        reasons+=("behind: this branch is $n commit(s) behind $disp (pull it; or, if this checkout amended or rebased the branch after pushing it, push that first)")
      else
        if [[ "$isdef" == "1" ]]; then
          reasons+=("behind: branch $branch_short is $n commit(s) behind $disp, that remote's default branch (if it should not count, run: git config --add validate.ignoreRemote $rname)")
        else
          reasons+=("behind: branch $branch_short is $n commit(s) behind $disp, its own copy on that remote (pull it; or, if this checkout amended or rebased the branch after pushing it, push that first)")
        fi
      fi
      doc_changed "$ref"; rc=$?
      [[ $rc -eq 0 ]] && reasons+=("the document changed in those commits: $rel")
      [[ $rc -eq 2 ]] && reasons+=("could not tell whether the document changed in those commits: $rel")
      ;;
    default)
      doc_changed "$ref"; rc=$?
      case "$rc" in
        0) reasons+=("the document changed on $disp after this branch left it ($n commit(s) behind): $rel") ;;
        1) notes+=("$n commit(s) behind $disp; the document is unchanged there") ;;
        *) unknowns+=("could not tell whether the document changed on $disp (no common history, or this branch deleted a file that $disp then changed and the document is new here; rebasing onto $disp settles it)") ;;
      esac
      ;;
  esac
done
if [[ ${#t_ref[@]} -eq 0 && ${#unknowns[@]} -eq 0 ]]; then
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

if [[ -n "$upstream_disp" ]]; then
  echo "CURRENT: HEAD ${head_sha:0:12} is not behind $upstream_disp"
else
  echo "CURRENT: HEAD ${head_sha:0:12}; the document is unchanged on $default_disps"
fi
# For the caller to record: how far the code the reviewers read is behind a
# remote default branch.
echo "behind_default=$behind_default"
[[ ${#notes[@]} -gt 0 ]] && printf '  note: %s\n' "${notes[@]}"
exit 0
