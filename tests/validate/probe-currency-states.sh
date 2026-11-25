#!/usr/bin/env bash
# probe-currency-states.sh: a table of checkout states for check-currency.sh,
# one line of output per state, each checked against the verdict written in
# its label.
#
# test-currency.sh pins individual verdicts with reasons. This is the wide
# view: every way a checkout was found to come to differ from its remote
# (teammate pushed, pulled then reset away, amended, rebased, cloned, pushed
# from another worktree, pulled by URL, reflogs gone), run in one pass. It
# began as a reviewer's scratch table and found two wrong verdicts that the
# fixtures of the day passed. Run it after any change to how the script
# decides what is stale.
#
# Usage: tests/validate/probe-currency-states.sh [path/to/check-currency.sh]
#        (default: this repository's copy). Local scratch repositories only.
# Output: "<n> rc=<exit> <first line> | <label>", and FAIL lines for mismatches.
# Exit:  0 every state gave the verdict its label names, 1 otherwise.
#
# A label ends in the expected verdict in brackets: [want CURRENT],
# [want STALE], [want UNVERIFIED], or [STALE by design: ...] for a checkout
# that amended or rebased a branch after pushing it. Git keeps no proof that
# the commits missing there were this checkout's own, so the script answers
# STALE and tells the user to push first.

set -uo pipefail
default_check="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/skills/validate/check-currency.sh"
set -- "${1:-$default_check}"
CHECK=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=a GIT_AUTHOR_EMAIL=a@x GIT_COMMITTER_NAME=a GIT_COMMITTER_EMAIL=a@x
unset GIT_DIR GIT_WORK_TREE
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
W=$TMP/w; O=$TMP/o
fresh() {
  rm -rf "${TMP:?}"/*; git init -q --bare -b main "$TMP/origin.git"
  git clone -q "$TMP/origin.git" "$O" 2>/dev/null
  (cd "$O" || exit; git checkout -q -b main 2>/dev/null; mkdir docs src; echo plan >docs/plan.md; echo c1 >src/code.py; git add -A; git commit -qm c1; echo c2 >src/code.py; git commit -qam c2; git push -q origin main)
  git clone -q "$TMP/origin.git" "$W"
}
c() { echo "$RANDOM$RANDOM" > "$1/src/$2"; git -C "$1" add -A; git -C "$1" commit -qm "$3"; }
mate() { # teammate commits a file on a branch and pushes
  git -C "$O" fetch -q origin; git -C "$O" checkout -q -B "$1" "origin/$1"; c "$O" "${2:-team.py}" "${3:-teammate}"; git -C "$O" push -q ${4:-} origin "$1"; }
feat() { git -C "$W" checkout -q -b feature; c "$W" f.py f; git -C "$W" push -q -u origin feature; }
n=0
bad=0
r() {
  n=$((n+1)); out=$(bash "$CHECK" "${2:-$W}/docs/plan.md" 2>&1); rc=$?
  printf '%2d rc=%s %s | %s\n' "$n" "$rc" "$(head -n1 <<<"$out" | sed -E 's/[0-9a-f]{12}/SHA/g')" "$1"
  case "$1" in
    *"[want CURRENT]")     want=0 ;;
    *"[want STALE]"|*"[STALE by design: "*"]") want=1 ;;
    *"[want UNVERIFIED]")  want=2 ;;
    *) want="?" ;;
  esac
  if [[ "$rc" != "$want" ]]; then bad=1; echo "   FAIL: wanted exit $want"; sed 's/^/      /' <<<"$out"; fi
  if [[ -n "${V:-}" ]]; then sed 's/^/      /' <<<"$out"; fi
}
G() { git -C "$W" "$@"; }

fresh; r "main: fresh clone [want CURRENT]"
fresh; G reset -q --hard HEAD~1; r "main: reset one back [want STALE]"
fresh; mate main; r "main: teammate pushed code, not pulled [want STALE]"
fresh; mate main; c "$W" mine.py mine; r "main: teammate pushed, never fetched, one local commit [want STALE]"
fresh; mate main; G pull -q; G reset -q --hard HEAD~1; c "$W" mine.py mine; r "main: pulled T, reset it away, own commit [want STALE]"
fresh; feat; r "feature: pushed, in sync [want CURRENT]"
fresh; feat; G commit -q --amend -m reworded; r "feature: pushed, amend reword [STALE by design: push first]"
fresh; feat; echo edited >"$W/docs/plan.md"; G add -A; G commit -q --amend --no-edit; r "feature: pushed, amend adds doc edit [STALE by design: push first]"
fresh; G checkout -q -b feature; echo e1 >"$W/docs/plan.md"; G commit -qam d; G push -q -u origin feature; echo e2 >"$W/docs/plan.md"; G commit -qa --amend --no-edit; r "feature: pushed doc edit, amend with further doc edit [STALE by design: push first]"
fresh; feat; mate main; G fetch -q; G rebase -q origin/main; r "feature: pushed, rebased onto newer main [STALE by design: push first]"
fresh; feat; mate feature; r "feature: teammate pushed, not fetched [want STALE]"
fresh; feat; mate feature; c "$W" mine.py mine; r "feature: teammate pushed, not fetched, one local commit [want STALE]"
fresh; feat; mate feature; G fetch -q; c "$W" mine.py mine; r "feature: teammate pushed, fetched not merged, one local commit [want STALE]"
fresh; feat; mate feature; G pull -q; G reset -q --hard HEAD~1; c "$W" mine.py mine; r "feature: pulled T, reset away, own commit [want STALE]"
fresh; feat; mate feature; G pull -q; c "$W" mine.py mine; G push -q; G reset -q --hard HEAD~2; c "$W" again.py again; r "feature: pulled T, pushed M on it, dropped both [want STALE]"
fresh; feat; mate feature; G pull -q; G commit -q --amend -m "teammate, reworded"; r "feature: pulled T, amend-reworded it, content kept [STALE by design: no evidence]"
fresh; mate main; (cd "$O" || exit; git checkout -q -b theirs HEAD~1; c "$O" t.py t; git push -q origin theirs); G fetch -q; G checkout -q -b theirs origin/theirs; G rebase -q origin/main; r "theirs: created from origin/theirs, rebased onto main [STALE by design: no evidence]"
fresh; feat; c "$W" g.py g; G push -q; G reset -q --hard HEAD~1; r "feature: pushed, reset one back [want STALE]"
fresh; feat; c "$W" g.py g; G push -q; G reset -q --hard HEAD~1; c "$W" h.py h; r "feature: pushed, dropped own last commit, new commit [STALE by design: push first]"
fresh; feat; c "$W" g.py g; G push -q; G reset -q --soft HEAD~2; G commit -qm squashed; r "feature: pushed two, squashed them [STALE by design: push first]"
fresh; feat; (git -C "$O" fetch -q; git -C "$O" checkout -q -b feature origin/feature; git -C "$O" commit -q --amend -m X; git -C "$O" push -q -f origin feature); r "feature: teammate force-pushed over my push, not fetched [want STALE]"
fresh; feat; (git -C "$O" fetch -q; git -C "$O" checkout -q -b feature origin/feature; git -C "$O" commit -q --amend -m X; git -C "$O" push -q -f origin feature); G fetch -q; r "feature: teammate force-pushed over my push, fetched [want STALE]"
fresh; G checkout -q -b feature; c "$W" f.py f; r "feature: never pushed, no upstream [want CURRENT]"
fresh; feat; mate main; r "feature: behind main in code only [want CURRENT]"
fresh; feat; (cd "$O" || exit; git checkout -q main; echo changed >docs/plan.md; git commit -qam docchange; git push -q origin main); r "feature: document changed on main [want STALE]"
# 26: cloned a branch whose tip T is a teammate's, pushed M on top, then dropped T and M
fresh; (cd "$O" || exit; git checkout -q -b feature; c "$O" t.py T; git push -q origin feature); rm -rf "$W"; git clone -q -b feature "$TMP/origin.git" "$W"; c "$W" m.py M; G push -q; G reset -q --hard HEAD~2; c "$W" again.py again; r "feature: CLONED with teammate's T, pushed M on it, dropped both [want STALE]"
# 27: another worktree of the same clone pushes to this branch
fresh; feat; git -C "$W" worktree add -q "$TMP/wt" -b side origin/feature; c "$TMP/wt" x.py X; git -C "$TMP/wt" push -q origin side:feature; c "$W" mine.py mine; r "feature: another worktree of this clone pushed X to it; here one local commit [want STALE]"
fresh; G config core.logAllRefUpdates false; feat; G commit -q --amend -m reworded; r "feature: reflogs disabled, pushed, amended [STALE by design: no evidence]"
fresh; feat; G reflog expire --expire=all --all; G commit -q --amend -m reworded; r "feature: reflog expired, pushed, amended [STALE by design: no evidence]"
fresh; G checkout -q -b feature; c "$W" f.py f; G push -q "$TMP/origin.git" feature; G commit -q --amend -m reworded; r "feature: pushed by URL (no tracking ref), amended [STALE by design: no evidence]"
# extras
fresh; G checkout -q -b feature; c "$W" f.py f; G push -q origin HEAD:feature; G commit -q --amend -m reworded; r "x1 feature: pushed without -u (kind same), amended [STALE by design: push first]"
fresh; feat; mate feature; G pull -q; c "$W" m.py M; G push -q; G reflog expire --expire=all refs/remotes/origin/feature; : ; r "x2 (control) pulled T, pushed M, reflog fully expired, in sync [want CURRENT]"
fresh; feat; mate feature; G pull -q --rebase; G reset -q --hard HEAD~1; c "$W" mine.py mine; r "x3 feature: pull --rebase T, reset away, own commit [want STALE]"
fresh; G remote rename origin team/origin; G checkout -q -b feature; c "$W" f.py f; G push -q -u team/origin feature; G commit -q --amend -m reworded; r "x4 remote named team/origin: pushed, amended [STALE by design: push first]"
fresh; G remote rename origin team/origin; G checkout -q -b feature; c "$W" f.py f; G push -q -u team/origin feature; (git -C "$O" fetch -q; git -C "$O" checkout -q -b feature origin/feature; c "$O" team.py T; git -C "$O" push -q origin feature); G pull -q; G reset -q --hard HEAD~1; c "$W" mine.py mine; r "x5 remote named team/origin: pulled T, reset away [want STALE]"
fresh; feat; G commit -q --amend -m reworded; G checkout -q --detach; r "x6 detached after amend [want UNVERIFIED]"
# x7: pulled T by URL (tracking ref never saw T as a fetch), pushed M, dropped both
fresh; feat; mate feature; G pull -q "$TMP/origin.git" feature; c "$W" m.py M; G push -q; G reset -q --hard HEAD~2; c "$W" again.py again; r "x7 feature: pulled T by URL, pushed M on it, dropped both [want STALE]"
# x8: pull entry expired, push entry kept (simulated by deleting the oldest reflog lines)
fresh; feat; mate feature; G pull -q; c "$W" m.py M; G push -q; tail -n +3 "$W/.git/logs/refs/remotes/origin/feature" > "$TMP/log" && cp "$TMP/log" "$W/.git/logs/refs/remotes/origin/feature"; G reset -q --hard HEAD~2; c "$W" again.py again; r "x8 feature: pulled T, pushed M, older reflog entries gone, dropped both [want STALE]"
# x9: main, cloned, pushed own commit on top of history, then reset far back and recommitted
fresh; c "$W" m.py M; G push -q; G reset -q --hard HEAD~2; c "$W" again.py again; r "x9 main: cloned, pushed M, then dropped M and a cloned commit c2 [want STALE]"

exit "$bad"
