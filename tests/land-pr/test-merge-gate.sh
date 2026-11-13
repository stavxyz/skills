#!/usr/bin/env bash
# test-merge-gate.sh: decision fixtures for skills/land-pr/merge-gate.sh.
#
# Exit 0 is what SKILL.md treats as "run gh pr merge", so every reading that
# must NOT reach it gets a fixture, and each look-alike that used to pass
# inline gets one by name: a merged PR whose mergeable is UNKNOWN, a head that
# moved after the bless, a stale base GitHub does not flag, and an empty or
# malformed reading.
#
# gh is replaced by a stub, so the gate runs with no network and no live PR.
# The stub does not hand the script ready-made fields. It builds the JSON that
# GitHub would return and runs the script's own --jq program over it with a
# real jq, so the field names, their order, and the null handling are under
# test too. A stub that printed the joined line itself left `.behind_by`
# swapped for `.ahead_by` green, which is the look-alike the script exists to
# rule out. `gh pr view` takes one scripted reading per call (the last
# repeats); `gh api .../compare/...` takes the scripted behind count, and
# always reports 7 commits AHEAD so that reading the wrong field is visible.
#
# Requires jq.
#
# Usage: tests/land-pr/test-merge-gate.sh
# Exit:  0 all passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../skills/land-pr" && pwd)
GATE="$SCRIPT_DIR/merge-gate.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

command -v jq >/dev/null 2>&1 || { echo "test-merge-gate.sh needs jq on PATH" >&2; exit 1; }

cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
sub=$1
jq_prog=""
prev=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && jq_prog=$a
  prev=$a
done
[ -n "$jq_prog" ] || { echo "stub: call carried no --jq program: $*" >&2; exit 9; }
case "$sub" in
  pr)
    n=$(cat "$GH_STUB_STATE" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$GH_STUB_STATE"
    line=$(sed -n "${n}p" "$GH_STUB_VIEWS")
    [ -z "$line" ] && line=$(tail -n 1 "$GH_STUB_VIEWS")
    case "$line" in
      ERROR) echo "could not resolve to a PullRequest" >&2; exit 1 ;;
      EMPTY) exit 0 ;;
    esac
    # A reading with exactly seven fields is a PR: turn it into the JSON gh
    # would fetch. Any other shape is a malformed response, passed through raw.
    IFS='|' read -r state draft head mergeable merge_state base merge_commit extra <<<"$line|END"
    if [ "$extra" != "END" ]; then
      printf '%s\n' "$line"
      exit 0
    fi
    if [ "$merge_commit" = "-" ]; then mc=null; else mc="{\"oid\":\"$merge_commit\"}"; fi
    jq -r -n --arg state "$state" --argjson draft "$draft" --arg head "$head" \
      --arg mergeable "$mergeable" --arg ms "$merge_state" --arg base "$base" --argjson mc "$mc" \
      '{state:$state, isDraft:$draft, headRefOid:$head, mergeable:$mergeable,
        mergeStateStatus:$ms, baseRefName:$base, mergeCommit:$mc}' | jq -r "$jq_prog"
    ;;
  api)
    echo "$2" >> "$GH_STUB_API_LOG"
    case "$GH_STUB_BEHIND" in
      ERROR) echo "HTTP 404: Not Found" >&2; exit 1 ;;
      EMPTY) exit 0 ;;
    esac
    jq -n --argjson behind "$GH_STUB_BEHIND" '{status:"diverged", ahead_by:7, behind_by:$behind}' | jq -r "$jq_prog"
    ;;
  *) echo "stub: unexpected gh subcommand: $1" >&2; exit 9 ;;
esac
STUB
chmod +x "$tmp/gh"

SHA=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222
MERGE=3333333333333333333333333333333333333333

# A reading is state|isDraft|head|mergeable|mergeStateStatus|base|mergeCommit.
ready="OPEN|false|$SHA|MERGEABLE|CLEAN|main|-"

pass=0
fail=0

# gate <behind> <views...> -- <gate args...>; sets $out and $got.
gate() {
  local behind=$1; shift
  local views=()
  while [ "$1" != "--" ]; do views+=("$1"); shift; done
  shift
  printf '%s\n' "${views[@]}" > "$tmp/views.txt"
  : > "$tmp/state"
  : > "$tmp/api.log"
  out=$(GH_STUB_STATE="$tmp/state" GH_STUB_VIEWS="$tmp/views.txt" \
        GH_STUB_BEHIND="$behind" GH_STUB_API_LOG="$tmp/api.log" \
        MERGE_GATE_GH="$tmp/gh" "$GATE" "$@" 2>&1)
  got=$?
}

# check <desc> <want-exit> [<want-substring>]
check() {
  local desc=$1 want=$2 want_out=${3:-}
  if [ "$got" = "$want" ] && { [ -z "$want_out" ] || grep -qF -- "$want_out" <<<"$out"; }; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  want exit %s%s\n  got exit %s, output:\n%s\n' \
      "$desc" "$want" "${want_out:+ and output containing: $want_out}" "$got" "$out"
  fi
}

# --- the one path to exit 0 --------------------------------------------------
gate 0 "$ready" -- 7 --sha "$SHA" --interval 0
check "open, blessed head, behind 0, mergeable, clean is READY" 0 "READY: PR #7 head $SHA"

gate 0 "OPEN|false|$SHA|MERGEABLE|UNSTABLE|main|-" -- 7 --sha "$SHA" --interval 0
check "UNSTABLE (a non-required check) does not block; the CI watcher rules on checks" 0

gate 0 "OPEN|false|$SHA|MERGEABLE|HAS_HOOKS|main|-" -- 7 --sha "$SHA" --interval 0
check "HAS_HOOKS is mergeable" 0

gate 0 "OPEN|false|$SHA|MERGEABLE|CLEAN|release/1.x|-" -- 7 --sha "$SHA" --interval 0
check "a base branch with a slash is READY" 0
if grep -qF "compare/release/1.x...$SHA" "$tmp/api.log"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL: compare call should name base...head, got: %s\n' "$(cat "$tmp/api.log")"
fi

# --- NOT READY: each reason by name -----------------------------------------
gate 0 "OPEN|false|$OTHER|MERGEABLE|CLEAN|main|-" -- 7 --sha "$SHA" --interval 0
check "a head that moved after the bless is NOT READY" 1 "head moved"

gate 3 "$ready" -- 7 --sha "$SHA" --interval 0
check "behind the base while GitHub says CLEAN is NOT READY" 1 "3 commit(s) behind main"

gate 0 "OPEN|false|$SHA|MERGEABLE|BEHIND|main|-" -- 7 --sha "$SHA" --interval 0
check "GitHub's own BEHIND is NOT READY" 1 "behind"

gate 0 "OPEN|true|$SHA|MERGEABLE|DRAFT|main|-" -- 7 --sha "$SHA" --interval 0
check "a draft is NOT READY" 1 "draft"

gate 0 "OPEN|false|$SHA|CONFLICTING|DIRTY|main|-" -- 7 --sha "$SHA" --interval 0
check "conflicts are NOT READY" 1 "conflicts"

gate 0 "OPEN|false|$SHA|MERGEABLE|BLOCKED|main|-" -- 7 --sha "$SHA" --interval 0
check "branch protection BLOCKED is NOT READY" 1 "blocked"

gate 0 "OPEN|false|$SHA|MERGEABLE|DIRTY|main|-" -- 7 --sha "$SHA" --interval 0
check "DIRTY alone is NOT READY" 1 "merge state is DIRTY"

gate 0 "OPEN|false|$SHA|CONFLICTING|DIRTY|main|-" -- 7 --sha "$SHA" --interval 0
if [ "$(grep -c 'conflicts' <<<"$out")" = "1" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL: CONFLICTING plus DIRTY should report conflicts once:\n%s\n' "$out"
fi

gate 2 "OPEN|true|$OTHER|CONFLICTING|DIRTY|main|-" -- 7 --sha "$SHA" --interval 0
check "several reasons are all reported, not just the first" 1 "head moved"
check "several reasons: draft also listed" 1 "draft"
check "several reasons: behind also listed" 1 "2 commit(s) behind"

gate 0 "$ready" -- 7 --interval 0
check "no --sha can never be READY, even on a clean PR" 1 "no blessed sha given"

# --- terminal states are decided before mergeability -------------------------
gate 0 "MERGED|false|$SHA|UNKNOWN|UNKNOWN|main|$MERGE" -- 7 --sha "$SHA" --interval 0 --retries 3
check "a merged PR is ALREADY MERGED, not retried as UNKNOWN" 4 "merge commit $MERGE"
check "a PR merged on the blessed head says so" 4 "merged head $SHA is the blessed sha"

gate 0 "MERGED|false|$OTHER|UNKNOWN|UNKNOWN|main|$MERGE" -- 7 --sha "$SHA" --interval 0
check "a PR merged on a different head than the blessed one is flagged" 4 "differs from the blessed sha $SHA"

gate 0 "MERGED|false|$SHA|UNKNOWN|UNKNOWN|main|$MERGE" -- 7 --interval 0
check "a merged PR probed without --sha reports its merged head" 4 "merged head $SHA"
if [ "$(cat "$tmp/state")" = "1" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL: merged PR should be read once, was read %s times\n' "$(cat "$tmp/state")"
fi

gate 0 "CLOSED|false|$SHA|UNKNOWN|UNKNOWN|main|-" -- 7 --sha "$SHA" --interval 0
check "a closed, unmerged PR exits 5" 5 "CLOSED"

# --- UNKNOWN is never a pass --------------------------------------------------
gate 0 "OPEN|false|$SHA|UNKNOWN|UNKNOWN|main|-" -- 7 --sha "$SHA" --interval 0 --retries 2
check "mergeability never computed is UNKNOWN" 2 "after 2 retries"
if [ "$(cat "$tmp/state")" = "3" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL: --retries 2 should read 3 times, read %s\n' "$(cat "$tmp/state")"
fi

gate 0 "OPEN|false|$SHA|UNKNOWN|UNKNOWN|main|-" "$ready" -- 7 --sha "$SHA" --interval 0
check "UNKNOWN that resolves on the next reading is READY" 0

gate 0 "OPEN|false|$SHA|MERGEABLE|UNKNOWN|main|-" "$ready" -- 7 --sha "$SHA" --interval 0
check "mergeStateStatus UNKNOWN alone is also retried" 0

gate 0 "OPEN|false|$SHA|UNKNOWN|UNKNOWN|main|-" "MERGED|false|$SHA|UNKNOWN|UNKNOWN|main|$MERGE" -- 7 --sha "$SHA" --interval 0
check "a PR merged by someone else during the retry is ALREADY MERGED" 4

gate 0 EMPTY -- 7 --sha "$SHA" --interval 0
check "an empty reading is UNKNOWN" 2 "unreadable PR state"

gate 0 "OPEN|false|$SHA|MERGEABLE" -- 7 --sha "$SHA" --interval 0
check "a short reading is UNKNOWN" 2 "unreadable PR state"

gate 0 "OPEN|false||MERGEABLE|CLEAN|main|-" -- 7 --sha "$SHA" --interval 0
check "an empty head field is UNKNOWN, not shifted into place" 2 "unreadable PR state"

gate 0 "OPEN|false|$SHA|MERGEABLE|CLEAN|main|-|surplus" -- 7 --sha "$SHA" --interval 0
check "a reading with a surplus field is UNKNOWN" 2 "unreadable PR state"

gate 0 "OPEN|false|$SHA|MAYBE|CLEAN|main|-" -- 7 --sha "$SHA" --interval 0
check "an unrecognized mergeable value is UNKNOWN" 2 "unrecognized mergeable"

gate 0 "OPEN|false|$SHA|MERGEABLE|NOVEL|main|-" -- 7 --sha "$SHA" --interval 0
check "an unrecognized mergeStateStatus is UNKNOWN" 2 "unrecognized mergeStateStatus"

gate 0 "REOPENED|false|$SHA|MERGEABLE|CLEAN|main|-" -- 7 --sha "$SHA" --interval 0
check "an unrecognized state is UNKNOWN" 2 "unrecognized PR state"

gate EMPTY "$ready" -- 7 --sha "$SHA" --interval 0
check "an empty behind count is UNKNOWN, not zero" 2 "unreadable behind count"

gate null "$ready" -- 7 --sha "$SHA" --interval 0
check "a non-numeric behind count is UNKNOWN" 2 "unreadable behind count"

# --- gh failures and usage ----------------------------------------------------
gate 0 ERROR -- 7 --sha "$SHA" --interval 0
check "gh pr view failing exits 3" 3 "gh pr view failed"

gate ERROR "$ready" -- 7 --sha "$SHA" --interval 0
check "gh api compare failing exits 3" 3 "gh api compare failed"

gate 0 "$ready" -- abc --sha "$SHA"
check "non-numeric PR number is a usage error" 3

gate 0 "$ready" -- 7 --sha 1111111
check "a short sha is refused" 3 "full 40-character"

gate 0 "$ready" -- 7 --sha
check "--sha without a value is a usage error" 3

gate 0 "$ready" -- 7 --sha "$SHA" --bogus
check "an unknown flag is a usage error" 3

out=$(MERGE_GATE_GH="$tmp/no-such-gh" "$GATE" 7 --sha "$SHA" 2>&1); got=$?
check "a missing gh exits 3" 3 "not installed"

out=$("$GATE" 2>&1); got=$?
check "no arguments is a usage error" 3

if [ "$fail" -eq 0 ]; then
  printf 'ok: %d gate cases passed\n' "$pass"
  exit 0
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
exit 1
