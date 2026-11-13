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

fresh
git -C "$W" remote set-url origin "$TMP/gone.git"
check "a fetch that fails is UNVERIFIED, not current" 2 "could not fetch origin" "$CHECK" "$W/docs/plan.md"

fresh
git -C "$W" remote set-url origin "$TMP/gone.git"
start=$(git -C "$W" rev-parse HEAD)
echo "x" > "$W/src/x.py"; git -C "$W" add -A; git -C "$W" commit -q -m x
check "a failed fetch does not hide that HEAD moved" \
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
