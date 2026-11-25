#!/usr/bin/env bash
# test-currency.sh: verdict fixtures for skills/validate/check-currency.sh.
#
# Exit 0 is what lets validate dispatch reviewers and later write a bless, so
# each way of being stale gets a fixture, and so does each look-alike that must
# NOT pass as current: a branch that is only ahead, a clean `git status`, and a
# document that is untouched locally because nobody pulled.
#
# Everything runs in a mktemp sandbox: a bare "origin", a clone that plays the
# other session and pushes to it, and the checkout under test. No network.
#
# Usage: tests/validate/test-currency.sh
# Exit:  0 all passed, 1 otherwise.

set -uo pipefail

# An inherited GIT_DIR would point the sandbox's git commands at the caller's
# repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../skills/validate" && pwd)/check-currency.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Keep the operator's git config (signing, hooks, templates) out of the sandbox.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

pass=0
fail=0

# check <desc> <want-exit> <want-substring> <cmd...>
check() {
  local desc=$1 want=$2 want_out=$3; shift 3
  local out got
  out=$("$@" 2>&1); got=$?
  if [ "$got" = "$want" ] && { [ -z "$want_out" ] || grep -qF -- "$want_out" <<<"$out"; }; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  want exit %s%s\n  got exit %s, output:\n%s\n' \
      "$desc" "$want" "${want_out:+ and output containing: $want_out}" "$got" "$out"
  fi
}

# fresh: a bare origin with one commit on main holding docs/plan.md and
# src/code.py, a checkout under test ($W), and a second clone ($O) to push from.
fresh() {
  rm -rf "$TMP/origin.git" "$TMP/w" "$TMP/o" "$TMP/seed"
  git init -q --bare -b main "$TMP/origin.git"
  git init -q -b main "$TMP/seed"
  mkdir -p "$TMP/seed/docs" "$TMP/seed/src"
  echo "plan v1" > "$TMP/seed/docs/plan.md"
  echo "code v1" > "$TMP/seed/src/code.py"
  git -C "$TMP/seed" add -A
  git -C "$TMP/seed" commit -q -m seed
  git -C "$TMP/seed" push -q "$TMP/origin.git" main
  git clone -q "$TMP/origin.git" "$TMP/w"
  git clone -q "$TMP/origin.git" "$TMP/o"
  W="$TMP/w"; O="$TMP/o"
}

# other_pushes <branch> <file> <text>: the other session lands a commit.
other_pushes() {
  git -C "$O" checkout -q "$1"
  git -C "$O" pull -q --ff-only origin "$1" 2>/dev/null
  echo "$3" > "$O/$2"
  git -C "$O" add -A
  git -C "$O" commit -q -m "other: $2"
  git -C "$O" push -q origin "$1"
}

# --- current ------------------------------------------------------------------
fresh
check "a fresh clone is current" 0 "CURRENT" "$CHECK" "$W/docs/plan.md"

echo "local work" > "$W/src/new.py"; git -C "$W" add -A; git -C "$W" commit -q -m local
check "a branch that is only AHEAD of its upstream is current" 0 "CURRENT" "$CHECK" "$W/docs/plan.md"

echo "plan v1 edited" > "$W/docs/plan.md"
check "an uncommitted local edit to the document is not staleness" 0 "CURRENT" "$CHECK" "$W/docs/plan.md"

# --- behind the upstream ------------------------------------------------------
fresh
other_pushes main src/code.py "code v2"
check "behind the upstream, with an untouched and clean working copy, is STALE" \
  1 "1 commit(s) behind origin/main" "$CHECK" "$W/docs/plan.md"
out=$("$CHECK" "$W/docs/plan.md" 2>&1)
if grep -qF "the document changed" <<<"$out"; then
  fail=$((fail + 1)); printf 'FAIL: only code changed upstream; the document must not be named:\n%s\n' "$out"
else
  pass=$((pass + 1))
fi

fresh
other_pushes main docs/plan.md "plan v2"
check "behind the upstream where the document itself changed names the document" \
  1 "the document changed in those commits: docs/plan.md" "$CHECK" "$W/docs/plan.md"

# Ahead AND behind: the ahead count must not hide the behind count.
fresh
other_pushes main src/code.py "code v2"
echo "local" > "$W/src/local.py"; git -C "$W" add -A; git -C "$W" commit -q -m local
check "diverged (ahead and behind) is STALE" 1 "behind origin/main" "$CHECK" "$W/docs/plan.md"

# --- feature branches ---------------------------------------------------------
fresh
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
check "an unpushed feature branch level with the default branch is current" \
  0 "CURRENT" "$CHECK" "$W/docs/plan.md"

other_pushes main src/code.py "code v2"
check "a feature branch behind the default branch only in code is current, with a note" \
  0 "1 commit(s) behind origin/main; the document is unchanged there" "$CHECK" "$W/docs/plan.md"

other_pushes main docs/plan.md "plan v2"
check "a feature branch whose document changed on the default branch is STALE" \
  1 "the document changed on origin/main after this branch left it" "$CHECK" "$W/docs/plan.md"

fresh
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u origin feature
git -C "$O" fetch -q origin
git -C "$O" checkout -q -b feature origin/feature
other_pushes feature src/code.py "code from a teammate"
check "a pushed feature branch behind its own upstream is STALE" \
  1 "behind origin/feature" "$CHECK" "$W/docs/plan.md"

# A fork setup: the branch tracks the fork, the document's history is on origin.
fresh
git init -q --bare -b main "$TMP/fork.git"
git -C "$W" remote add fork "$TMP/fork.git"
git -C "$W" push -q fork main
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u fork feature
check "a branch tracking a fork, level with origin, is current" 0 "CURRENT" "$CHECK" "$W/docs/plan.md"
other_pushes main docs/plan.md "plan v2"
check "a branch tracking a fork is STALE when origin's default branch changed the document" \
  1 "the document changed on origin/main after this branch left it" "$CHECK" "$W/docs/plan.md"
rm -rf "$TMP/fork.git"

# A remote whose name contains a slash.
fresh
git -C "$W" remote rename origin team/up
other_pushes main src/code.py "code v2"
check "a remote named with a slash is still fetched and compared" \
  1 "behind team/up/main" "$CHECK" "$W/docs/plan.md"

# A branch tracking a LOCAL branch has no remote upstream; origin still counts.
fresh
git -C "$W" checkout -q -b local-child --track main
other_pushes main docs/plan.md "plan v2"
check "a branch tracking a local branch is still compared with origin's default" \
  1 "the document changed on origin/main" "$CHECK" "$W/docs/plan.md"

# Being behind a LOCAL upstream says nothing about the remote.
fresh
git -C "$W" checkout -q -b local-child --track main
git -C "$W" checkout -q main
echo "m" > "$W/src/m.py"; git -C "$W" add -A; git -C "$W" commit -q -m "local main moves"
git -C "$W" checkout -q local-child
check "a branch behind its local upstream, level with the remote, is current" \
  0 "CURRENT" "$CHECK" "$W/docs/plan.md"

# The document was renamed on this branch; the default branch edited the old name.
fresh
git -C "$W" checkout -q -b feature
git -C "$W" mv docs/plan.md docs/plan2.md; git -C "$W" commit -q -m rename
other_pushes main docs/plan.md "plan v2"
check "a document renamed on this branch is matched with edits to its old path" \
  1 "the document changed on origin/main" "$CHECK" "$W/docs/plan2.md"

# A path with a space and glob characters is one literal file, not a pattern.
fresh
mkdir -p "$O/docs/my plans"; echo "p" > "$O/docs/my plans/a[1]*.md"; echo "q" > "$O/docs/my plans/a1x.md"
git -C "$O" add -A; git -C "$O" commit -q -m docs; git -C "$O" push -q origin main
git -C "$W" pull -q --ff-only origin main
git -C "$W" checkout -q -b feature
other_pushes main "docs/my plans/a1x.md" "q2"
check "a sibling file matching the document's name as a glob is not the document" \
  0 "the document is unchanged there" "$CHECK" "$W/docs/my plans/a[1]*.md"
other_pushes main "docs/my plans/a[1]*.md" "p2"
check "a document with spaces and glob characters in its path is found" \
  1 "the document changed on origin/main" "$CHECK" "$W/docs/my plans/a[1]*.md"

# Detached HEAD: which remote branch is this checkout's own cannot be told, so
# level with the default branch is UNVERIFIED, never current. A document
# change on the default branch is still STALE.
fresh
git -C "$W" checkout -q --detach
check "a detached HEAD level with everything is UNVERIFIED, not current" \
  2 "HEAD is detached" "$CHECK" "$W/docs/plan.md"
other_pushes main docs/plan.md "plan v2"
check "a detached HEAD behind origin's default branch is STALE" \
  1 "the document changed on origin/main" "$CHECK" "$W/docs/plan.md"

# The branch edited its own document; the default branch moved only in code.
# (Two dots in place of three would call this a change on the default branch.)
fresh
git -C "$W" checkout -q -b feature
echo "plan v1, edited here" > "$W/docs/plan.md"; git -C "$W" add -A; git -C "$W" commit -q -m edit
other_pushes main src/code.py "code v2"
check "a branch that edited its own document, with only code moved on the default, is current" \
  0 "behind_default=1" "$CHECK" "$W/docs/plan.md"

# A feature branch created FROM origin/main has origin/main as its upstream.
fresh
git -C "$W" checkout -q -b feature origin/main
other_pushes main src/code.py "code v2"
check "a feature branch tracking the default branch is not stopped for code-only drift" \
  0 "the document is unchanged there" "$CHECK" "$W/docs/plan.md"
other_pushes main docs/plan.md "plan v2"
check "a feature branch tracking the default branch is STALE when the document changed there" \
  1 "the document changed on origin/main" "$CHECK" "$W/docs/plan.md"

# origin/HEAD unset: the main/master fallback finds the default branch.
fresh
git -C "$W" checkout -q -b feature
git -C "$W" config remote.origin.followRemoteHEAD never
git -C "$W" remote set-head origin --delete
other_pushes main docs/plan.md "plan v2"
check "with origin/HEAD unset, origin/main is still used as the default branch" \
  1 "the document changed on origin/main" "$CHECK" "$W/docs/plan.md"

# A single remote that is not named origin.
fresh
git -C "$W" remote rename origin upstream
git -C "$W" checkout -q -b feature
other_pushes main docs/plan.md "plan v2"
check "a single remote not named origin is used" \
  1 "the document changed on upstream/main" "$CHECK" "$W/docs/plan.md"

# No upstream and no default branch this clone can name.
fresh
git -C "$O" checkout -q -b trunk; git -C "$O" push -q origin trunk
git -C "$W" config remote.origin.followRemoteHEAD never
git -C "$W" fetch -q origin
git -C "$W" checkout -q -b feature origin/trunk --no-track
git -C "$W" remote set-head origin --delete
git -C "$W" update-ref -d refs/remotes/origin/main
git -C "$W" config remote.origin.fetch '+refs/heads/trunk:refs/remotes/origin/trunk'
check "a default branch this clone does not have is learned from the remote and fetched" \
  0 "the document is unchanged on origin/main" "$CHECK" "$W/docs/plan.md"
other_pushes main docs/plan.md "plan v2"
check "and a document change on that learned default branch is STALE" \
  1 "the document changed on origin/main" "$CHECK" "$W/docs/plan.md"
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/gone
check "a remote whose default branch cannot be found is UNVERIFIED, not current" \
  2 "no remote default branch could be found" "$CHECK" "$W/docs/plan.md"

# A clone that tracks one branch only (git clone --single-branch) and has an
# upstream: the default branch must still be consulted.
fresh
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u origin feature
rm -rf "$TMP/single"
git clone -q --single-branch --branch feature "$TMP/origin.git" "$TMP/single"
other_pushes main docs/plan.md "plan v2"
check "a single-branch clone still compares the document with the default branch" \
  1 "the document changed on origin/main" "$CHECK" "$TMP/single/docs/plan.md"

# The same clone, run twice. The first run must not leave behind a snapshot of
# the default branch that the second run then trusts: validate's own first
# call would freeze what its later re-checks compare with.
fresh
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u origin feature
rm -rf "$TMP/single"
git clone -q --single-branch --branch feature "$TMP/origin.git" "$TMP/single"
check "single-branch clone, first run, nothing has moved" 0 "CURRENT" "$CHECK" "$TMP/single/docs/plan.md"
start=$(git -C "$TMP/single" rev-parse HEAD)
other_pushes main docs/plan.md "plan v2"
check "single-branch clone, second run sees the default branch move after the first" \
  1 "the document changed on origin/main" "$CHECK" "$TMP/single/docs/plan.md" --since "$start"

# The branch tracks a branch that the clone's fetch refspec leaves out, so git
# reports no upstream ref at all. The configured upstream still counts.
fresh
rm -rf "$TMP/single"
git clone -q --single-branch --branch main "$TMP/origin.git" "$TMP/single"
git -C "$TMP/single" checkout -q -b feature
echo "f" > "$TMP/single/src/f.py"; git -C "$TMP/single" add -A; git -C "$TMP/single" commit -q -m f
git -C "$TMP/single" push -q -u origin feature
git -C "$O" fetch -q origin; git -C "$O" checkout -q -b feature origin/feature
other_pushes feature docs/plan.md "plan from a teammate"
check "an upstream outside the fetch refspec is still compared" \
  1 "behind origin/feature" "$CHECK" "$TMP/single/docs/plan.md"

# A local branch that tracks a remote branch with a different name.
fresh
git -C "$O" checkout -q -b shared main; git -C "$O" push -q origin shared
git -C "$W" fetch -q origin
git -C "$W" checkout -q -b mine --track origin/shared
other_pushes shared src/code.py "code from a teammate"
check "a branch tracking a differently named remote branch is compared with it" \
  1 "this branch is 1 commit(s) behind origin/shared" "$CHECK" "$W/docs/plan.md"

# The branch was pushed without -u, or tracks the default branch: its own copy
# on the remote is where another session pushes, and it is not the upstream.
fresh
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q origin feature
git -C "$O" fetch -q origin; git -C "$O" checkout -q -b feature origin/feature
other_pushes feature docs/plan.md "plan from a teammate"
check "a branch pushed without -u is compared with its own copy on the remote" \
  1 "branch feature is 1 commit(s) behind origin/feature" "$CHECK" "$W/docs/plan.md"

fresh
git -C "$W" checkout -q -b feature origin/main
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q origin feature
git -C "$O" fetch -q origin; git -C "$O" checkout -q -b feature origin/feature
other_pushes feature src/code.py "code from a teammate"
check "a branch tracking the default branch is still compared with its own copy on the remote" \
  1 "branch feature is 1 commit(s) behind origin/feature" "$CHECK" "$W/docs/plan.md"

# A remote that accepts the connection and then says nothing. Without a time
# limit the whole check hangs; with one it is a single "could not tell", and
# the other remotes still decide.
if command -v python3 >/dev/null 2>&1 && command -v perl >/dev/null 2>&1; then
  fresh
  python3 - "$TMP/port" <<'PY' &
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
conns = []
end = time.time() + 120
s.settimeout(1)
while time.time() < end:
    try: conns.append(s.accept()[0])
    except OSError: pass
PY
  listener=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/port" ] && break; perl -e 'select(undef,undef,undef,0.2)'; done
  # The port is this run's own, so process matches below cannot hit another
  # copy of this suite running on the same machine.
  silent_url="http://127.0.0.1:$(cat "$TMP/port")/x.git"
  git -C "$W" remote add silent "$silent_url"
  git -C "$W" checkout -q -b feature
  began=$(date +%s)
  check "a remote that never answers is UNVERIFIED within the time limit" \
    2 "could not fetch silent" env CHECK_CURRENCY_NET_TIMEOUT=3 "$CHECK" "$W/docs/plan.md"
  took=$(( $(date +%s) - began ))
  if [ "$took" -le 15 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: the silent remote took ${took}s with a 3s limit per call"; fi
  other_pushes main docs/plan.md "plan v2"
  check "a remote that never answers does not hide a document change on origin" \
    1 "the document changed on origin/main" env CHECK_CURRENCY_NET_TIMEOUT=3 "$CHECK" "$W/docs/plan.md"
  # An interrupt aimed at the script reaches the network call it started.
  git -C "$W" remote remove origin
  ( CHECK_CURRENCY_NET_TIMEOUT=60 perl -e 'setpgrp(0,0); exec @ARGV' "$CHECK" "$W/docs/plan.md" >/dev/null 2>&1 & echo $! > "$TMP/checkpid" )
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    pgrep -f "$silent_url" >/dev/null 2>&1 && break
    perl -e 'select(undef,undef,undef,0.3)'
  done
  if pgrep -f "$silent_url" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: the interrupt fixture never saw the network call start"; fi
  # TERM, not INT: a shell started in the background ignores INT, and that is
  # inherited, which would test the shell and not the script.
  kill -TERM -- "-$(cat "$TMP/checkpid")" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    pgrep -f "$silent_url" >/dev/null 2>&1 || break
    perl -e 'select(undef,undef,undef,0.3)'
  done
  if pgrep -f "$silent_url" >/dev/null 2>&1; then
    fail=$((fail + 1)); echo "FAIL: a signal to the script left the network call running"
    pkill -f "$silent_url" 2>/dev/null
  else
    pass=$((pass + 1))
  fi
  kill "$listener" 2>/dev/null; wait "$listener" 2>/dev/null
  rm -f "$TMP/port" "$TMP/checkpid"
else
  echo "skip: silent-remote fixture (needs python3 and perl)"
fi

# A branch named like the default branch is not a feature branch, whatever it tracks.
fresh
git init -q --bare -b main "$TMP/fork.git"
git -C "$W" remote add fork "$TMP/fork.git"
git -C "$W" push -q -u fork main
other_pushes main src/code.py "code v2"
check "main tracking a fork's main is STALE when origin's main moved, even in code only" \
  1 "branch main is 1 commit(s) behind origin/main" "$CHECK" "$W/docs/plan.md"
rm -rf "$TMP/fork.git"

# One of two remotes is unreachable: the other is still compared.
fresh
git init -q --bare -b main "$TMP/fork.git"
git -C "$W" remote add fork "$TMP/fork.git"
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u fork feature
rm -rf "$TMP/fork.git"
check "an unreachable fork alone is UNVERIFIED" 2 "could not fetch fork" "$CHECK" "$W/docs/plan.md"
other_pushes main docs/plan.md "plan v2"
check "an unreachable fork does not hide a document change on origin" \
  1 "the document changed on origin/main" "$CHECK" "$W/docs/plan.md"

# Names git quotes when it prints them: non-ASCII, a double quote, a backslash.
for name in 'plän.md' 'pl"an.md' 'pl\\an.md'; do
  fresh
  echo "p" > "$O/docs/$name"; git -C "$O" add -A; git -C "$O" commit -q -m odd; git -C "$O" push -q origin main
  git -C "$W" pull -q --ff-only origin main
  git -C "$W" config core.ignorecase true
  git -C "$W" checkout -q -b feature
  other_pushes main "docs/$name" "p2"
  check "a document named $name is found when it changed on the default branch" \
    1 "the document changed on origin/main" "$CHECK" "$W/docs/$name"
done

# Renamed on this branch TO a name git quotes; the default branch edited the old name.
for name in 'plän.md' 'pl\\an.md'; do
  fresh
  git -C "$W" checkout -q -b feature
  git -C "$W" mv docs/plan.md "docs/$name"; git -C "$W" commit -q -m rename
  other_pushes main docs/plan.md "plan v2"
  check "a document renamed to $name is matched with edits to its old path" \
    1 "the document changed on origin/main" "$CHECK" "$W/docs/$name"
done

# Two tracked files that differ only in case: the path as typed wins.
fresh
blob=$(echo "upper" | git -C "$O" hash-object -w --stdin)
git -C "$O" update-index --add --cacheinfo 100644,"$blob",docs/PLAN.md
git -C "$O" commit -q -m "add PLAN.md"; git -C "$O" push -q origin main
git -C "$O" checkout -q -- . 2>/dev/null
git -C "$W" fetch -q origin; git -C "$W" reset -q origin/main   # index and HEAD, not the working tree
git -C "$W" config core.ignorecase true
git -C "$W" checkout -q -b feature
git -C "$O" checkout -q main
echo "plan v2" | git -C "$O" hash-object -w --stdin > "$TMP/blob2"
git -C "$O" update-index --cacheinfo 100644,"$(cat "$TMP/blob2")",docs/plan.md
git -C "$O" commit -q -m "edit lowercase"; git -C "$O" push -q origin main
check "with PLAN.md and plan.md both tracked, the path as typed is the one compared" \
  1 "the document changed on origin/main after this branch left it (1 commit(s) behind): docs/plan.md" "$CHECK" "$W/docs/plan.md"

# A wrong-case path to a document whose tracked name git would quote.
fresh
echo "p" > "$O/docs/plän.md"; git -C "$O" add -A; git -C "$O" commit -q -m odd; git -C "$O" push -q origin main
git -C "$W" pull -q --ff-only origin main
git -C "$W" checkout -q -b feature
other_pushes main "docs/plän.md" "p2"
if [ -f "$W/docs/Plän.md" ]; then
  git -C "$W" config core.ignorecase true
  check "a wrong-case path to a non-ASCII name finds the tracked document" \
    1 "the document changed on origin/main" "$CHECK" "$W/docs/Plän.md"
else
  echo "skip: wrong-case non-ASCII fixture (this volume is case-sensitive)"
fi

# A symlink with an absolute target, sitting outside the repository.
fresh
ln -s "$W/docs/plan.md" "$TMP/abs-link.md"
git -C "$W" checkout -q -b feature
other_pushes main docs/plan.md "plan v2"
check "a symlink with an absolute target resolves to the tracked document" \
  1 "the document changed on origin/main" "$CHECK" "$TMP/abs-link.md"
rm -f "$TMP/abs-link.md"

# A symlinked file whose target climbs out with "..", reached through a
# symlinked directory: resolve physically, not by trimming the text.
fresh
mkdir -p "$O/other"; echo "decoy" > "$O/plan.md"
ln -s ../plan.md "$O/other/link.md"
git -C "$O" add -A; git -C "$O" commit -q -m link; git -C "$O" push -q origin main
git -C "$W" pull -q --ff-only origin main
mkdir -p "$TMP/elsewhere/deep"; ln -s "$W/other" "$TMP/elsewhere/deep/o"
git -C "$W" checkout -q -b feature
other_pushes main plan.md "decoy v2"
check "a relative symlink target is resolved from the link's real directory" \
  1 "the document changed on origin/main after this branch left it (1 commit(s) behind): plan.md" "$CHECK" "$TMP/elsewhere/deep/o/link.md"

# The default branch was replaced by unrelated history: no merge base.
fresh
git -C "$W" checkout -q -b feature
git -C "$O" checkout -q --orphan fresh-root; echo "new world" > "$O/docs/plan.md"
git -C "$O" add -A; git -C "$O" commit -q -m "unrelated root"; git -C "$O" push -q -f origin fresh-root:main
check "a default branch with no common history is UNVERIFIED, never current" \
  2 "could not tell whether the document changed on origin/main" "$CHECK" "$W/docs/plan.md"

# A repository that reaches its remote through core.sshCommand keeps doing so.
fresh
cat > "$TMP/fake-ssh" <<'SSH'
#!/bin/sh
# Stands in for ssh: record the call, then run the remote command locally.
echo "$*" >> "$FAKE_SSH_LOG"
for last; do :; done
exec sh -c "$last"
SSH
chmod +x "$TMP/fake-ssh"
git -C "$W" remote set-url origin "ssh://example.invalid$TMP/origin.git"
git -C "$W" config core.sshCommand "$TMP/fake-ssh"
: > "$TMP/ssh.log"
other_pushes main docs/plan.md "plan v2"
FAKE_SSH_LOG="$TMP/ssh.log" check "a configured core.sshCommand is used for the fetch, not bypassed" \
  1 "the document changed in those commits" env FAKE_SSH_LOG="$TMP/ssh.log" "$CHECK" "$W/docs/plan.md"
if grep -q -- "BatchMode=yes" "$TMP/ssh.log" && grep -q -- "ConnectTimeout=15" "$TMP/ssh.log"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL: the fetch should pass BatchMode and ConnectTimeout to ssh, log:\n%s\n' "$(cat "$TMP/ssh.log")"
fi

# A document that is itself a symlink to a tracked file.
fresh
ln -s plan.md "$O/docs/current.md"; git -C "$O" add -A; git -C "$O" commit -q -m link; git -C "$O" push -q origin main
git -C "$W" pull -q --ff-only origin main
git -C "$W" checkout -q -b feature
other_pushes main docs/plan.md "plan v2"
check "a symlinked document is checked as the file it points at" \
  1 "docs/plan.md" "$CHECK" "$W/docs/current.md"

# A path typed in a different case from the tracked name, where the volume
# allows it.
fresh
git -C "$W" checkout -q -b feature
other_pushes main docs/plan.md "plan v2"
if [ -f "$W/docs/PLAN.md" ]; then
  git -C "$W" config core.ignorecase true
  check "a path typed in another case still finds the tracked document" \
    1 "the document changed on origin/main" "$CHECK" "$W/docs/PLAN.md"
else
  echo "skip: case-insensitive path fixture (this volume is case-sensitive)"
fi

# Flags may come before the document.
fresh
check "--since before the document path is accepted" \
  0 "CURRENT" "$CHECK" --since "$(git -C "$W" rev-parse HEAD)" "$W/docs/plan.md"

# `gh repo fork` layout: origin is the fork, and the parent is "upstream".
fresh
git init -q --bare -b main "$TMP/fork.git"
git -C "$W" push -q "$TMP/fork.git" main
git -C "$W" remote rename origin upstream
git -C "$W" remote add origin "$TMP/fork.git"
git -C "$W" fetch -q origin
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u origin feature
check "gh-fork layout, level with the parent, is current" 0 "CURRENT" "$CHECK" "$W/docs/plan.md"
other_pushes main docs/plan.md "plan v2"
check "gh-fork layout: a feature branch is STALE when the parent's default branch changed the document" \
  1 "the document changed on upstream/main after this branch left it" "$CHECK" "$W/docs/plan.md"
git -C "$W" checkout -q main
git -C "$W" branch -q --set-upstream-to=origin/main
check "gh-fork layout: main tracking the fork is STALE when the parent's main moved" \
  1 "upstream/main" "$CHECK" "$W/docs/plan.md"
rm -rf "$TMP/fork.git"

# The remote renamed its default branch. A plain fetch leaves origin/HEAD
# pointing at the old name and leaves the old branch in place, frozen.
fresh
git -C "$W" checkout -q -b feature
git -C "$O" checkout -q -b trunk; git -C "$O" push -q origin trunk
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/trunk
git -C "$W" config remote.origin.followRemoteHEAD never
other_pushes trunk docs/plan.md "plan v2"
check "a renamed default branch is learned from the remote, not from a stale origin/HEAD" \
  1 "the document changed on origin/trunk" "$CHECK" "$W/docs/plan.md"
if [ "$(git -C "$W" symbolic-ref refs/remotes/origin/HEAD)" = "refs/remotes/origin/main" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL: the rename fixture needs origin/HEAD to still name main, got %s\n' "$(git -C "$W" symbolic-ref refs/remotes/origin/HEAD)"
fi

# Criss-cross: two merge bases. Against one of them the default branch shows no
# change to the document, while the document here and there differ.
fresh
git -C "$O" checkout -q -b m1 main; echo "code m1" > "$O/src/m1.py"; git -C "$O" add -A; git -C "$O" commit -q -m m1
git -C "$O" checkout -q -b m2 main; echo "plan v1b" > "$O/docs/plan.md"; git -C "$O" add -A; git -C "$O" commit -q -m m2
git -C "$O" push -q origin m1 m2
git -C "$W" fetch -q origin
git -C "$W" checkout -q -b feature origin/m1 --no-track
git -C "$W" merge -q origin/m2 -m "feature merges m2"
git -C "$O" checkout -q main; git -C "$O" merge -q --no-ff m2 -m "main merges m2"; git -C "$O" merge -q --no-ff m1 -m "main merges m1"
echo "plan v1" > "$O/docs/plan.md"; git -C "$O" add -A; git -C "$O" commit -q -m "main reverts the document"
git -C "$O" push -q origin main
if [ "$(git -C "$W" fetch -q origin; git -C "$W" merge-base --all HEAD origin/main | wc -l | tr -d ' ')" = "2" ]; then
  check "with two merge bases, a document change seen from either one is STALE" \
    1 "the document changed on origin/main" "$CHECK" "$W/docs/plan.md"
else
  fail=$((fail + 1)); echo "FAIL: the criss-cross fixture did not produce two merge bases"
fi

# Moved and largely rewritten on this branch: git sees an add and a delete, not
# a rename. The default branch edited the old path.
fresh
printf 'one\ntwo\nthree\nfour\n' > "$O/docs/plan.md"; git -C "$O" add -A; git -C "$O" commit -q -m long; git -C "$O" push -q origin main
git -C "$W" pull -q --ff-only origin main
git -C "$W" checkout -q -b feature
git -C "$W" rm -q docs/plan.md; mkdir -p "$W/docs"; printf 'uno\ndos\ntres\nfour\n' > "$W/docs/plan-v2.md"
git -C "$W" add -A; git -C "$W" commit -q -m "move and rewrite"
other_pushes main docs/plan.md "$(printf 'one\ntwo\nthree\nfour\nfive')"
check "a moved and rewritten document, with its old path edited on the default, is UNVERIFIED" \
  2 "could not tell whether the document changed on origin/main" "$CHECK" "$W/docs/plan-v2.md"

# A brand-new document on a branch that deleted nothing is still current.
fresh
git -C "$W" checkout -q -b feature
echo "new" > "$W/docs/new.md"; git -C "$W" add -A; git -C "$W" commit -q -m new
other_pushes main src/code.py "code v2"
check "a brand-new document on a branch that deleted nothing is current" \
  0 "the document is unchanged there" "$CHECK" "$W/docs/new.md"

# This branch deleted an unrelated file that the default branch then edited.
# The document existed at the branch point, so it is not a rename candidate.
fresh
git -C "$W" checkout -q -b feature
git -C "$W" rm -q src/code.py; git -C "$W" commit -q -m "delete code"
other_pushes main src/code.py "code v2"
check "deleting an unrelated file does not make a tracked document unverifiable" \
  0 "the document is unchanged there" "$CHECK" "$W/docs/plan.md"

# A fork whose main runs ahead of the canonical main blocks a checkout of
# main, and pulling cannot clear it. Naming the remote as ignored does.
fresh
git init -q --bare -b main "$TMP/fork.git"
git -C "$W" remote add fork "$TMP/fork.git"
git -C "$W" push -q fork main
git clone -q "$TMP/fork.git" "$TMP/forkclone"
echo "fork only" > "$TMP/forkclone/src/forkonly.py"; git -C "$TMP/forkclone" add -A
git -C "$TMP/forkclone" commit -q -m "fork runs ahead"; git -C "$TMP/forkclone" push -q origin main
check "a fork whose main runs ahead blocks main, and the message names the remedy" \
  1 "git config --add validate.ignoreRemote fork" "$CHECK" "$W/docs/plan.md"
git -C "$W" config --add validate.ignoreRemote fork
check "an ignored remote is not compared, and the note says so" \
  0 "the default branch of fork is ignored" "$CHECK" "$W/docs/plan.md"
other_pushes main docs/plan.md "plan v2"
check "ignoring one remote does not stop the others from deciding" \
  1 "behind origin/main" "$CHECK" "$W/docs/plan.md"
rm -rf "$TMP/fork.git" "$TMP/forkclone"

# Ignoring a remote leaves out its default branch only. The remedy the script
# prints for a fork's main must not be usable to hide another session's pushes
# to this branch's own copy.
fresh
git init -q --bare -b main "$TMP/parent.git"
git -C "$W" push -q "$TMP/parent.git" main
git -C "$W" remote add upstream "$TMP/parent.git"
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q origin feature
git -C "$O" fetch -q origin; git -C "$O" checkout -q -b feature origin/feature
other_pushes feature docs/plan.md "plan from a teammate"
out=$("$CHECK" "$W/docs/plan.md" 2>&1)
if grep -q "its own copy on that remote (pull it" <<<"$out" && ! grep -q "ignoreRemote" <<<"$out"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL: a stale own-branch copy should say pull, and not offer ignoreRemote:\n%s\n' "$out"
fi
git -C "$W" config --add validate.ignoreRemote origin
check "ignoring a remote does not hide another session's pushes to this branch on it" \
  1 "branch feature is 1 commit(s) behind origin/feature" "$CHECK" "$W/docs/plan.md"
rm -rf "$TMP/parent.git"

# The remote answers ls-remote, and then the fetch fails. Nothing was fetched,
# so nothing may be compared: UNVERIFIED, never current.
fresh
git -C "$W" checkout -q -b feature
other_pushes main docs/plan.md "plan v2"
find "$TMP/origin.git/objects" -type f -delete
check "a fetch that fails after ls-remote answered is UNVERIFIED" \
  2 "could not fetch origin" "$CHECK" "$W/docs/plan.md"

# Pushed from here, then amended here: the remote holds this checkout's own
# earlier push. Git keeps no proof of that (see the comment in the script), so
# it is STALE until the rewrite is pushed, and the message says so.
fresh
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u origin feature
git -C "$W" commit -q --amend -m "f, reworded"
check "a branch amended after its own push is STALE, and the message says to push first" \
  1 "if this checkout amended or rebased the branch after pushing it, push that first with \`git push --force-with-lease\`" "$CHECK" "$W/docs/plan.md"
git -C "$W" push -q -f origin feature
check "and current once the rewrite has been pushed" 0 "is not behind origin/feature" "$CHECK" "$W/docs/plan.md"
git -C "$W" commit -q --amend -m "f, reworded again"
git -C "$O" fetch -q origin; git -C "$O" checkout -q -b feature origin/feature
other_pushes feature src/code.py "code from a teammate"
check "but another session's push on top of it is STALE" \
  1 "behind origin/feature" "$CHECK" "$W/docs/plan.md"

# The remote's tip is in the local reflog for the opposite reason: this
# checkout was AT that tip and was then reset back (or pulled and reset). It
# is plainly behind, and the reflog must not excuse it.
fresh
other_pushes main src/code.py "code v2"
git -C "$W" pull -q --ff-only origin main
git -C "$W" reset -q --hard HEAD~1
check "a checkout reset back from the remote's tip is STALE, whatever its reflog holds" \
  1 "behind origin/main" "$CHECK" "$W/docs/plan.md"

fresh
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u origin feature
git -C "$O" fetch -q origin; git -C "$O" checkout -q -b feature origin/feature
other_pushes feature docs/plan.md "plan from a teammate"
git -C "$W" pull -q --ff-only origin feature
git -C "$W" reset -q --hard HEAD~1
check "a feature branch reset back past a teammate's push is STALE" \
  1 "the document changed in those commits" "$CHECK" "$W/docs/plan.md"

# Diverged, with the remote tip in the reflog, but the rewrite dropped a
# teammate's change to the document: pulled their commit, reset it away, and
# committed something else.
fresh
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u origin feature
git -C "$O" fetch -q origin; git -C "$O" checkout -q -b feature origin/feature
other_pushes feature docs/plan.md "plan from a teammate"
git -C "$W" pull -q --ff-only origin feature
git -C "$W" reset -q --hard HEAD~1
echo "mine" > "$W/src/mine.py"; git -C "$W" add -A; git -C "$W" commit -q -m mine
check "a rewrite that dropped a teammate's change to the document is STALE" \
  1 "the document changed in those commits" "$CHECK" "$W/docs/plan.md"

# Amending a commit that itself edited the document, after pushing it.
fresh
git -C "$W" checkout -q -b feature
echo "plan, my edit" > "$W/docs/plan.md"; git -C "$W" add -A; git -C "$W" commit -q -m "edit plan"
git -C "$W" push -q -u origin feature
git -C "$W" commit -q --amend -m "edit plan, reworded"
check "amending a pushed commit that edited the document is STALE until it is pushed" \
  1 "push that first" "$CHECK" "$W/docs/plan.md"

# A teammate's CODE-only commit, pulled and then dropped by a local rewrite.
# The document is untouched, and the checkout has diverged, but the commit it
# lacks was never pushed from here.
fresh
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u origin feature
git -C "$O" fetch -q origin; git -C "$O" checkout -q -b feature origin/feature
other_pushes feature src/code.py "code from a teammate"
git -C "$W" pull -q --ff-only origin feature
git -C "$W" reset -q --hard HEAD~1
echo "mine" > "$W/src/mine.py"; git -C "$W" add -A; git -C "$W" commit -q -m mine
check "a teammate's code commit, pulled and then reset away, is STALE" \
  1 "behind origin/feature" "$CHECK" "$W/docs/plan.md"

# The same on main itself.
fresh
other_pushes main src/code.py "code from a teammate"
git -C "$W" pull -q --ff-only origin main
git -C "$W" reset -q --hard HEAD~1
echo "mine" > "$W/src/mine.py"; git -C "$W" add -A; git -C "$W" commit -q -m mine
check "main with a teammate's commit pulled and then reset away is STALE" \
  1 "behind origin/main" "$CHECK" "$W/docs/plan.md"

# A fresh clone of a branch never pushed anything: its tip arrived by clone.
fresh
git -C "$O" checkout -q -b feature main; echo "t" > "$O/src/t.py"; git -C "$O" add -A; git -C "$O" commit -q -m t
git -C "$O" push -q origin feature
rm -rf "$TMP/single"; git clone -q -b feature "$TMP/origin.git" "$TMP/single"
git -C "$TMP/single" reset -q --hard HEAD~1
echo "mine" > "$TMP/single/src/mine.py"; git -C "$TMP/single" add -A; git -C "$TMP/single" commit -q -m mine
check "a fresh clone that rewrote away a commit it never pushed is STALE" \
  1 "behind origin/feature" "$CHECK" "$TMP/single/docs/plan.md"

# Pulled a teammate's commit, pushed on top of it, then dropped THEIR commit
# locally: the remote's tip was pushed from here, but one missing commit was not.
fresh
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u origin feature
git -C "$O" fetch -q origin; git -C "$O" checkout -q -b feature origin/feature
other_pushes feature src/code.py "code from a teammate"
git -C "$W" pull -q --ff-only origin feature
echo "mine" > "$W/src/mine.py"; git -C "$W" add -A; git -C "$W" commit -q -m mine
git -C "$W" push -q origin feature
git -C "$W" reset -q --hard HEAD~2
echo "again" > "$W/src/again.py"; git -C "$W" add -A; git -C "$W" commit -q -m again
check "dropping a teammate's commit from under one's own push is STALE" \
  1 "behind origin/feature" "$CHECK" "$W/docs/plan.md"

# Pushed a code commit, then amended it to also edit the document.
fresh
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u origin feature
echo "plan, edited after the push" > "$W/docs/plan.md"; git -C "$W" add -A; git -C "$W" commit -q --amend --no-edit
check "amending a pushed commit to also edit the document is STALE until it is pushed" \
  1 "push that first" "$CHECK" "$W/docs/plan.md"

# Pushed from here, then reset back: behind this checkout's own push. The
# document it would edit is older than the one it pushed, so that is stale.
fresh
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
echo "g" > "$W/src/g.py"; git -C "$W" add -A; git -C "$W" commit -q -m g
git -C "$W" push -q -u origin feature
git -C "$W" reset -q --hard HEAD~1
check "a checkout reset back behind its own push is STALE" \
  1 "behind origin/feature" "$CHECK" "$W/docs/plan.md"

# Checked out from a teammate's branch and rebased onto main here: every
# commit on the remote copy came from there, not from a push made here, so the
# rewrite is not excused. Pushing it makes it this checkout's own.
fresh
git -C "$O" checkout -q -b theirs main; echo "t" > "$O/src/t.py"; git -C "$O" add -A; git -C "$O" commit -q -m t
git -C "$O" push -q origin theirs
other_pushes main src/code.py "code v2"
git -C "$W" fetch -q origin
git -C "$W" checkout -q -b theirs origin/theirs
git -C "$W" rebase -q origin/main
check "a teammate's branch rebased here but not yet pushed is STALE" \
  1 "push that first" "$CHECK" "$W/docs/plan.md"
git -C "$W" push -q -f origin theirs
check "and current once it has been pushed" 0 "CURRENT" "$CHECK" "$W/docs/plan.md"

# A fresh clone leaves no entry in the tracking ref's reflog, so "nothing here
# arrived by a pull" proves nothing: a teammate's commit that came with the
# clone, pushed along under one's own commit and then dropped.
fresh
git -C "$O" checkout -q -b feature main; echo "t" > "$O/src/t.py"; git -C "$O" add -A; git -C "$O" commit -q -m "teammate"
git -C "$O" push -q origin feature
rm -rf "$TMP/single"; git clone -q -b feature "$TMP/origin.git" "$TMP/single"
echo "m" > "$TMP/single/src/m.py"; git -C "$TMP/single" add -A; git -C "$TMP/single" commit -q -m mine
git -C "$TMP/single" push -q origin feature
git -C "$TMP/single" reset -q --hard HEAD~2
echo "again" > "$TMP/single/src/again.py"; git -C "$TMP/single" add -A; git -C "$TMP/single" commit -q -m again
check "a cloned teammate commit, pushed along and then dropped, is STALE" \
  1 "behind origin/feature" "$CHECK" "$TMP/single/docs/plan.md"

# Another worktree of the same clone pushed a change to the document; this
# worktree then amended its own commit.
fresh
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u origin feature
rm -rf "$TMP/wt2"; git -C "$W" worktree add -q --detach "$TMP/wt2" feature
echo "plan from the other worktree" > "$TMP/wt2/docs/plan.md"
git -C "$TMP/wt2" add -A; git -C "$TMP/wt2" commit -q -m "other worktree"; git -C "$TMP/wt2" push -q origin HEAD:feature
git -C "$W" commit -q --amend -m "f, reworded"
check "another worktree's push to this branch is not this checkout's own rewrite" \
  1 "the document changed in those commits" "$CHECK" "$W/docs/plan.md"
git -C "$W" worktree remove --force "$TMP/wt2" 2>/dev/null

# The upstream's remote is not a configured remote.
fresh
git -C "$W" checkout -q -b feature
git -C "$W" config branch.feature.remote gone
git -C "$W" config branch.feature.merge refs/heads/feature
check "an upstream on a remote that is not configured is UNVERIFIED" \
  2 "not a configured remote: gone" "$CHECK" "$W/docs/plan.md"

# An upstream that is not a branch.
fresh
git -C "$W" checkout -q -b feature
git -C "$W" config branch.feature.remote origin
git -C "$W" config branch.feature.merge refs/pull/1/head
check "an upstream that is not a branch is UNVERIFIED, and says so" \
  2 "upstream is not a branch (refs/pull/1/head)" "$CHECK" "$W/docs/plan.md"

# origin itself ignored: its default branch is left out and the note says so,
# but the branch this one tracks on it is still compared.
fresh
git init -q --bare -b main "$TMP/parent.git"
git -C "$W" push -q "$TMP/parent.git" main
git -C "$W" remote add upstream "$TMP/parent.git"
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u origin feature
git -C "$W" config --add validate.ignoreRemote origin
other_pushes main docs/plan.md "plan v2"
check "an ignored origin's default branch is not compared, and the note says so" \
  0 "the default branch of origin is ignored" "$CHECK" "$W/docs/plan.md"
git -C "$O" fetch -q origin; git -C "$O" checkout -q -b feature origin/feature
other_pushes feature src/code.py "code from a teammate"
check "the upstream on an ignored remote is still compared" \
  1 "this branch is 1 commit(s) behind origin/feature" "$CHECK" "$W/docs/plan.md"
rm -rf "$TMP/parent.git"

# A remote whose name has a slash is named whole in the remedy.
fresh
git init -q --bare -b main "$TMP/fork.git"
git -C "$W" remote add my/fork "$TMP/fork.git"
git -C "$W" push -q my/fork main
git clone -q "$TMP/fork.git" "$TMP/forkclone"
echo "x" > "$TMP/forkclone/src/x.py"; git -C "$TMP/forkclone" add -A
git -C "$TMP/forkclone" commit -q -m ahead; git -C "$TMP/forkclone" push -q origin main
check "the remedy names a remote with a slash in full" \
  1 "git config --add validate.ignoreRemote my/fork)" "$CHECK" "$W/docs/plan.md"
rm -rf "$TMP/fork.git" "$TMP/forkclone"

# A remote that wants credentials: no askpass program is run, whatever the
# environment and config name, and the answer is UNVERIFIED at once.
if command -v python3 >/dev/null 2>&1; then
  fresh
  python3 - "$TMP/port401" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="x"'); self.end_headers()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.timeout = 1
import time
end = time.time() + 60
while time.time() < end: srv.handle_request()
PY
  srv401=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/port401" ] && break; perl -e 'select(undef,undef,undef,0.2)'; done
  printf '#!/bin/sh\necho called >> "%s"\necho nobody\n' "$TMP/askpass.log" > "$TMP/askpass"; chmod +x "$TMP/askpass"
  : > "$TMP/askpass.log"
  git -C "$W" remote add needsauth "http://127.0.0.1:$(cat "$TMP/port401")/x.git"
  git -C "$W" config core.askPass "$TMP/askpass"
  git -C "$W" checkout -q -b feature
  check "a remote that wants credentials is UNVERIFIED" \
    2 "could not fetch needsauth" env GIT_ASKPASS="$TMP/askpass" SSH_ASKPASS="$TMP/askpass" "$CHECK" "$W/docs/plan.md"
  if [ -s "$TMP/askpass.log" ]; then
    fail=$((fail + 1)); echo "FAIL: an askpass program was run"
  else
    pass=$((pass + 1))
  fi
  kill "$srv401" 2>/dev/null; wait "$srv401" 2>/dev/null
  rm -f "$TMP/port401" "$TMP/askpass" "$TMP/askpass.log"
else
  echo "skip: credentials fixture (needs python3)"
fi

# An ssh remote that hangs (an agent waiting on an approval nobody gives): the
# message says what that usually is, since the stopped call left no output.
if command -v perl >/dev/null 2>&1; then
  fresh
  printf '#!/bin/sh\nsleep 60\n' > "$TMP/hang-ssh"; chmod +x "$TMP/hang-ssh"
  git -C "$W" remote add slow "ssh://git@example.invalid/x.git"
  git -C "$W" config core.sshCommand "$TMP/hang-ssh"
  git -C "$W" remote set-url origin "ssh://git@example.invalid$TMP/origin.git"
  check "an ssh remote that hangs is UNVERIFIED, and the message names the usual cause" \
    2 "an ssh agent waiting on an approval" env CHECK_CURRENCY_NET_TIMEOUT=2 "$CHECK" "$W/docs/plan.md"

  # The same when the listing answers and the fetch is what hangs, over an
  # scp-style address with no user (host:path).
  fresh
  cat > "$TMP/hang-later-ssh" <<'SSH'
#!/bin/sh
# Stands in for ssh: the first call runs the remote command, later ones hang.
if [ -e "$HANG_MARK" ]; then sleep 60; fi
: > "$HANG_MARK"
for last; do :; done
exec sh -c "$last"
SSH
  chmod +x "$TMP/hang-later-ssh"
  git -C "$W" remote set-url origin "example.invalid:$TMP/origin.git"
  git -C "$W" config core.sshCommand "$TMP/hang-later-ssh"
  other_pushes main docs/plan.md "plan v2"
  rm -f "$TMP/hang.mark"
  check "a fetch that hangs over an scp-style address names the usual cause too" \
    2 "could not fetch origin: no answer within 2s (an ssh remote that hangs" \
    env HANG_MARK="$TMP/hang.mark" CHECK_CURRENCY_NET_TIMEOUT=2 "$CHECK" "$W/docs/plan.md"

  # A remote that is not ssh gets the plain message, even with an @ and a
  # colon in its URL: an https remote that hangs is not an agent's doing.
  if command -v python3 >/dev/null 2>&1; then
    fresh
    python3 -c 'import socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(8)
open(sys.argv[1],"w").write(str(s.getsockname()[1]))
time.sleep(60)' "$TMP/port" &
    listener=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/port" ] && break; sleep 0.2; done
    git -C "$W" remote set-url origin "http://user:pw@127.0.0.1:$(cat "$TMP/port")/x.git"
    got_out="$(CHECK_CURRENCY_NET_TIMEOUT=2 "$CHECK" "$W/docs/plan.md" 2>&1)"; got_rc=$?
    kill "$listener" 2>/dev/null; wait "$listener" 2>/dev/null
    if [ "$got_rc" = 2 ] && grep -q "no answer within 2s" <<<"$got_out" && ! grep -q "ssh agent" <<<"$got_out"; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1)); printf 'FAIL: an http remote that hangs is UNVERIFIED without the ssh hint (exit %s):\n%s\n' "$got_rc" "$got_out"
    fi
  fi
fi

# The check leaves no refs behind, and a leftover from a run that died does not
# block a later branch whose name nests under it (feat, then feat/x).
fresh
git -C "$W" checkout -q -b feat
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u origin feat
check "first run on branch feat" 0 "CURRENT" "$CHECK" "$W/docs/plan.md"
if [ -z "$(git -C "$W" for-each-ref refs/check-currency/)" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL: refs left behind after a run:\n%s\n' "$(git -C "$W" for-each-ref refs/check-currency/)"
fi
git -C "$W" update-ref refs/check-currency/origin/feat HEAD        # the old, flat layout
git -C "$W" update-ref refs/check-currency/999999/origin/feat HEAD # a run that died
git -C "$W" checkout -q main
git -C "$W" push -q origin --delete feat
git -C "$W" branch -q -D feat
git -C "$W" checkout -q -b feat/x
git -C "$W" push -q -u origin feat/x
check "a leftover ref named feat does not block checking feat/x" 0 "is not behind origin/feat/x" "$CHECK" "$W/docs/plan.md"
if [ -z "$(git -C "$W" for-each-ref refs/check-currency/)" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL: leftover refs were not cleared:\n%s\n' "$(git -C "$W" for-each-ref refs/check-currency/)"
fi

# A STALE or UNVERIFIED exit clears its refs too.
fresh
other_pushes main docs/plan.md "plan v2"
check "a stale run" 1 "behind origin/main" "$CHECK" "$W/docs/plan.md"
if [ -z "$(git -C "$W" for-each-ref refs/check-currency/)" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: refs left behind after a STALE exit"
fi

# A document that is a symlink into another repository.
fresh
rm -rf "$TMP/otherrepo"; git init -q -b main "$TMP/otherrepo"
ln -s "$W/docs/plan.md" "$TMP/otherrepo/linked.md"
check "a symlink into another repository is refused" \
  3 "symlink into another repository" "$CHECK" "$TMP/otherrepo/linked.md"
rm -rf "$TMP/otherrepo"

# --- --since ------------------------------------------------------------------
fresh
start=$(git -C "$W" rev-parse HEAD)
check "--since the current HEAD is current" 0 "CURRENT" "$CHECK" "$W/docs/plan.md" --since "$start"
echo "x" > "$W/src/x.py"; git -C "$W" add -A; git -C "$W" commit -q -m x
check "--since an earlier HEAD reports that HEAD moved" \
  1 "HEAD moved during the run" "$CHECK" "$W/docs/plan.md" --since "$start"
check "--since something that is not a commit is a usage error" 3 "--since is not a commit" "$CHECK" "$W/docs/plan.md" --since nonsense

fresh
start=$(git -C "$W" rev-parse HEAD)
other_pushes main docs/plan.md "plan v2"
check "the remote moving during the run is caught by the re-check" \
  1 "the document changed in those commits" "$CHECK" "$W/docs/plan.md" --since "$start"

# --- unverified is never a pass ----------------------------------------------
fresh
git -C "$W" remote remove origin
check "no remote at all is UNVERIFIED" 2 "no remote to compare against" "$CHECK" "$W/docs/plan.md"
out=$("$CHECK" "$W/docs/plan.md" --since "$(git -C "$W" rev-parse HEAD~0)" 2>&1)
git -C "$W" commit -q --allow-empty -m moved
out=$("$CHECK" "$W/docs/plan.md" --since "$(git -C "$W" rev-parse HEAD~1)" 2>&1); got=$?
if [ "$got" = "1" ] && ! grep -q "UNVERIFIED" <<<"$out"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL: STALE output must not also say UNVERIFIED, got exit %s:\n%s\n' "$got" "$out"
fi

fresh
git -C "$W" remote set-url origin "$TMP/gone.git"
check "a fetch that fails is UNVERIFIED, not current" 2 "could not fetch origin" "$CHECK" "$W/docs/plan.md"

fresh
git -C "$W" remote set-url origin "$TMP/gone.git"
start=$(git -C "$W" rev-parse HEAD)
echo "x" > "$W/src/x.py"; git -C "$W" add -A; git -C "$W" commit -q -m x
check "a failed fetch does not hide that HEAD moved" \
  1 "HEAD moved during the run" "$CHECK" "$W/docs/plan.md" --since "$start"

# The upstream branch was deleted on the remote and pruned: the count fails.
# HEAD having moved must still come back as STALE, which stops the run, and not
# as UNVERIFIED, which the caller may continue past.
fresh
git -C "$W" checkout -q -b feature
echo "f" > "$W/src/f.py"; git -C "$W" add -A; git -C "$W" commit -q -m f
git -C "$W" push -q -u origin feature
start=$(git -C "$W" rev-parse HEAD)
git -C "$O" push -q origin --delete feature
git -C "$W" config fetch.prune true
check "a pruned upstream alone is UNVERIFIED" 2 "could not count commits behind origin/feature" "$CHECK" "$W/docs/plan.md"
other_pushes main docs/plan.md "plan v2"
check "a pruned upstream does not skip the default-branch document check" \
  1 "the document changed on origin/main" "$CHECK" "$W/docs/plan.md"
git -C "$W" merge -q origin/main -m sync 2>/dev/null
start=$(git -C "$W" rev-parse HEAD)
echo "x" > "$W/src/x.py"; git -C "$W" add -A; git -C "$W" commit -q -m x
check "a pruned upstream does not hide that HEAD moved" \
  1 "HEAD moved during the run" "$CHECK" "$W/docs/plan.md" --since "$start"

# --- usage --------------------------------------------------------------------
check "no arguments is a usage error" 3 "" "$CHECK"
check "a missing file is a usage error" 3 "not a file" "$CHECK" "$TMP/w/docs/nope.md"
mkdir -p "$TMP/plain"; echo x > "$TMP/plain/doc.md"
check "a file outside any repository is a usage error" 3 "not in a git repository" "$CHECK" "$TMP/plain/doc.md"
check "an unknown flag is a usage error" 3 "unknown arg" "$CHECK" "$W/docs/plan.md" --bogus

# A path given relative to another directory resolves to the same document.
fresh
other_pushes main docs/plan.md "plan v2"
out=$(cd "$W/docs" && "$CHECK" plan.md 2>&1); got=$?
if [ "$got" = "1" ] && grep -qF "docs/plan.md" <<<"$out"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL: a relative path should resolve to docs/plan.md, got exit %s:\n%s\n' "$got" "$out"
fi

if [ "$fail" -eq 0 ]; then
  printf 'ok: %d currency cases passed\n' "$pass"
  exit 0
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
exit 1
