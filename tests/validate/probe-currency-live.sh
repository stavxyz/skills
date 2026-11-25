#!/usr/bin/env bash
# probe-currency-live.sh: run check-currency.sh against a real remote, in the
# three states a checkout is most often in. test-currency.sh covers the logic
# with local repositories; this is the check that the script also works over a
# real transport, with the real remote's branch layout.
#
# It was written after a merge: the fixtures all passed, and this probe showed
# a checkout reset one commit back being called current.
#
# Usage:
#   tests/validate/probe-currency-live.sh [--script PATH] [--remote URL] [--doc PATH]
#
#   --script  the check-currency.sh to run (default: this repository's copy;
#             pass an installed plugin's copy to check what is deployed)
#   --remote  the repository to clone (default: this checkout's origin URL)
#   --doc     a tracked file in it to treat as the document (default: README.md)
#
# It clones into a temp directory, which it deletes, and writes nowhere else.
# It needs network access to the remote, and may raise an ssh approval prompt.
#
# Exit: 0 all three states gave the expected verdict, 1 otherwise, 3 usage or
# clone failure.

set -uo pipefail

# An inherited GIT_DIR would make the resets below act on the caller's
# repository instead of the clone.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$ROOT/skills/validate/check-currency.sh"
remote=""
doc="README.md"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --script) [[ $# -ge 2 ]] || { echo "--script needs a value" >&2; exit 3; }; script="$2"; shift 2 ;;
    --remote) [[ $# -ge 2 ]] || { echo "--remote needs a value" >&2; exit 3; }; remote="$2"; shift 2 ;;
    --doc) [[ $# -ge 2 ]] || { echo "--doc needs a value" >&2; exit 3; }; doc="$2"; shift 2 ;;
    *) echo "usage: probe-currency-live.sh [--script PATH] [--remote URL] [--doc PATH]" >&2; exit 3 ;;
  esac
done
[[ -n "$remote" ]] || remote="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" || { echo "no origin remote; pass --remote" >&2; exit 3; }
[[ -f "$script" ]] || { echo "no such script: $script" >&2; exit 3; }
# Made absolute now: the probe changes directory before it runs the script.
script="$(cd "$(dirname "$script")" && pwd)/$(basename "$script")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git clone -q "$remote" "$tmp/c" || { echo "could not clone $remote" >&2; exit 3; }
cd "$tmp/c" || exit 3
[[ -f "$doc" ]] || { echo "no such file in the clone: $doc" >&2; exit 3; }
default="$(git symbolic-ref --short HEAD)"

fail=0
# expect <label> <want-exit> <want-substring>
expect() {
  local out rc
  out="$(bash "$script" "$doc" 2>&1)"; rc=$?
  if [[ "$rc" == "$2" ]] && grep -qF -- "$3" <<<"$out"; then
    echo "ok: $1"
  else
    fail=1
    printf 'FAIL: %s\n  want exit %s and output containing: %s\n  got exit %s:\n%s\n' "$1" "$2" "$3" "$rc" "$out"
  fi
}

expect "a fresh clone of $default is current" 0 "CURRENT"

git reset -q --hard HEAD~1 || { echo "the remote's $default has a single commit; the probe needs two" >&2; exit 3; }
expect "$default reset one commit back is stale" 1 "behind origin/$default"

git checkout -q -b probe-feature
if git diff --quiet HEAD "origin/$default" -- "$doc"; then
  expect "a feature branch behind $default in other files only is current, with the count" 0 "the document is unchanged there"
else
  expect "a feature branch whose document changed on $default is stale" 1 "the document changed on origin/$default"
fi

if [[ -z "$(git for-each-ref refs/check-currency/)" ]]; then
  echo "ok: no refs left behind"
else
  fail=1; echo "FAIL: refs left under refs/check-currency/"
fi
exit "$fail"
