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

# Detached HEAD has no upstream; origin's default branch still decides.
fresh
git -C "$W" checkout -q --detach
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
git -C "$W" update-ref -d refs/remotes/origin/main
other_pushes main docs/plan.md "plan v2"
check "and a document change on that learned default branch is STALE" \
  1 "the document changed on origin/main" "$CHECK" "$W/docs/plan.md"
git -C "$W" update-ref -d refs/remotes/origin/main
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

# --- --since ------------------------------------------------------------------
fresh
start=$(git -C "$W" rev-parse HEAD)
check "--since the current HEAD is current" 0 "CURRENT" "$CHECK" "$W/docs/plan.md" --since "$start"
echo "x" > "$W/src/x.py"; git -C "$W" add -A; git -C "$W" commit -q -m x
check "--since an earlier HEAD reports that HEAD moved" \
  1 "HEAD moved during the run" "$CHECK" "$W/docs/plan.md" --since "$start"
check "--since something that is not a commit is a usage error" 3 "" "$CHECK" "$W/docs/plan.md" --since nonsense

fresh
start=$(git -C "$W" rev-parse HEAD)
other_pushes main docs/plan.md "plan v2"
check "the remote moving during the run is caught by the re-check" \
  1 "the document changed in those commits" "$CHECK" "$W/docs/plan.md" --since "$start"

# --- unverified is never a pass ----------------------------------------------
fresh
git -C "$W" remote remove origin
check "no remote at all is UNVERIFIED" 2 "no upstream and no remote to compare against" "$CHECK" "$W/docs/plan.md"
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
