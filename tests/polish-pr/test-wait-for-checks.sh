#!/usr/bin/env bash
# test-wait-for-checks.sh — behaviour fixtures for wait-for-pr-checks.sh.
#
# The part that silently returns a wrong answer here is a GREEN that is not
# green. Three shapes of it, all observed live:
#
#   * empty because the push has not registered yet, read as "no checks"
#     (backsight #153: exit 0 seconds after a force-push, 17 checks and 3
#     pending moments later);
#   * empty AFTER checks were seen, because a rebase moved the head SHA
#     mid-wait - the same bug one force-push later;
#   * every visible check settled while the rest of the matrix has not
#     registered (backsight #202: a table of all-pass printed while
#     `analyzers-tests (3.14)` was in the fail bucket).
#
# Assertions read STDOUT and STDERR separately. Merging them (`2>&1`) is how an
# earlier cut of this file ended up with four cases that could not fail: the
# documented "<name>\t<bucket>" rows go to stdout, and every assertion was
# matching banner text on stderr instead, so mutating the script to mangle
# every check name - or to print no rows at all - left the suite green.
#
# `gh` is stubbed, so this is deterministic and uses no network.
#
# Usage: tests/polish-pr/test-wait-for-checks.sh
# Exit:  0 all passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../skills/polish-pr" && pwd)
WAIT="$SCRIPT_DIR/wait-for-pr-checks.sh"

BIN=$(mktemp -d)
STATE=$(mktemp -d)
OUT=$(mktemp -d)
trap 'rm -rf "$BIN" "$STATE" "$OUT"' EXIT
export PATH="$BIN:$PATH"

pass=0
fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n%s\n' "$1" "${2:-}"; }

# Write a stub `gh`. $1 is the body; it may use $STATE. %q so a temp path
# containing a space (routine on Windows) still produces a runnable stub.
stub_gh() {
  { echo '#!/usr/bin/env bash'
    printf 'STATE=%q\n' "$STATE"
    printf '%s\n' "$1"
  } > "$BIN/gh"
  chmod +x "$BIN/gh"
}

# `gh pr checks` when nothing is registered: exit 1, message on stderr.
NO_CHECKS='echo "no checks reported on the '"'"'x'"'"' branch" >&2; exit 1'

# Run the script, capturing the two streams apart. Sets $rc, $sout, $serr.
run_wait() {
  "$WAIT" "$@" >"$OUT/stdout" 2>"$OUT/stderr"
  rc=$?
  sout=$(cat "$OUT/stdout")
  serr=$(cat "$OUT/stderr")
}

expect() { # expect <desc> <want_rc> [-- args...]
  local desc=$1 want=$2; shift 3
  run_wait "$@"
  [ "$rc" = "$want" ] || {
    bad "$desc" "  want rc=$want, got rc=$rc
  stderr: $(printf '%s' "$serr" | tail -3 | sed 's/^/    /')"
    return 1
  }
  ok
}

# --------------------------------------------------------------------------
# 1. Empty because the run has not registered yet.
# --------------------------------------------------------------------------
echo 0 > "$STATE/n"
stub_gh 'n=$(cat "$STATE/n"); echo $((n+1)) > "$STATE/n"
if [ "$n" -lt 1 ]; then '"$NO_CHECKS"'; fi
printf "lint\tfail\nbuild\tpass\n"'
expect "a check that appears late and FAILS is not called green" 1 -- 1 --interval 1
printf '%s' "$serr" | grep -qF 'CI FAILED' || bad "the failure is announced" "$serr"
# the documented row contract, on stdout, not the banner on stderr
printf '%s' "$sout" | grep -qF "$(printf 'lint\tfail')" \
  && ok || bad "the failing row reaches stdout" "stdout: $sout"

echo 0 > "$STATE/n"
stub_gh 'n=$(cat "$STATE/n"); echo $((n+1)) > "$STATE/n"
if [ "$n" -lt 2 ]; then '"$NO_CHECKS"'; fi
printf "lint\tpass\nbuild\tpass\n"'
expect "checks that appear late are waited for" 0 -- 1 --interval 1
printf '%s' "$serr" | grep -qF 'nothing to wait for' \
  && bad "it declared 'no checks' before they appeared" "$serr" || ok

# --------------------------------------------------------------------------
# 2. Empty AFTER checks were seen: a rebase moved the head SHA mid-wait.
#    This must never be read as "the PR has no checks".
# --------------------------------------------------------------------------
echo 0 > "$STATE/n"
stub_gh 'n=$(cat "$STATE/n"); echo $((n+1)) > "$STATE/n"
if [ "$n" -lt 1 ]; then printf "lint\tpending\nbuild\tpass\n"; exit 0; fi
'"$NO_CHECKS"
expect "checks seen, then gone, times out rather than going green" 2 \
       -- 1 --interval 1 --timeout 4 --empty-grace 2
printf '%s' "$serr" | grep -qF 'not calling it green' \
  && ok || bad "it says why it is still waiting" "$serr"
printf '%s' "$serr" | grep -qF 'nothing to wait for' \
  && bad "it called a vanished check set 'no checks'" "$serr" || ok

# The grace clock is cleared when checks appear, so a LATER gap gets a full
# fresh grace rather than inheriting a spent one. Without the `unset`, this
# run ends early; the mutation that removes it must fail here.
echo 0 > "$STATE/n"
stub_gh 'n=$(cat "$STATE/n"); echo $((n+1)) > "$STATE/n"
case "$n" in
  0|1) '"$NO_CHECKS"' ;;
  2)   printf "lint\tpending\n"; exit 0 ;;
  *)   '"$NO_CHECKS"' ;;
esac'
start=$(date +%s)
run_wait 1 --interval 1 --timeout 8 --empty-grace 3
elapsed=$(( $(date +%s) - start ))
# 2 empty (grace running) + 1 pending + then vanished-forever to the deadline
if [ "$rc" = 2 ] && [ "$elapsed" -ge 6 ]; then ok; else
  bad "a gap after checks appear does not inherit the first gap's clock" \
      "  rc=$rc elapsed=${elapsed}s (want rc=2, >=6s)"
fi

# --------------------------------------------------------------------------
# 3. All VISIBLE checks settled is not all checks settled.
# --------------------------------------------------------------------------
echo 0 > "$STATE/n"
stub_gh 'n=$(cat "$STATE/n"); echo $((n+1)) > "$STATE/n"
if [ "$n" -lt 1 ]; then printf "lint\tpass\n"; exit 0; fi
printf "lint\tpass\npython (3.14)\tfail\npython (3.11)\tcancel\n"'
expect "a matrix job that registers late is not missed" 1 -- 1 --interval 1
printf '%s' "$sout" | grep -qF "$(printf 'python (3.14)\tfail')" \
  && ok || bad "the late failing row reaches stdout" "stdout: $sout"

# --------------------------------------------------------------------------
# 4. A PR that genuinely has no checks is still green - just not instantly.
# --------------------------------------------------------------------------
stub_gh "$NO_CHECKS"
start=$(date +%s)
expect "a PR with genuinely no checks is green after the grace" 0 \
       -- 1 --interval 1 --empty-grace 3
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -ge 3 ] && ok || bad "the grace is actually waited out" \
                                  "  returned in ${elapsed}s, grace was 3s"

# --------------------------------------------------------------------------
# 5. The timeout contract holds on every waiting branch, not just pending.
# --------------------------------------------------------------------------
stub_gh "$NO_CHECKS"
start=$(date +%s)
expect "the timeout is honoured while waiting on an empty result" 2 \
       -- 1 --interval 1 --timeout 2 --empty-grace 60
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 20 ] && ok || bad "it timed out near the deadline" \
                                   "  took ${elapsed}s for --timeout 2"

stub_gh 'printf "lint\tpending\n"'
expect "the timeout is honoured while checks are pending" 2 \
       -- 1 --interval 1 --timeout 2
printf '%s' "$sout" | grep -qF "$(printf 'lint\tpending')" \
  && ok || bad "the pending rows reach stdout on timeout" "stdout: $sout"

# --------------------------------------------------------------------------
# 6. Multi-word check names - the reason this script reads --json at all.
#    Asserted on the ROWS, so mangling a name fails here.
# --------------------------------------------------------------------------
echo 0 > "$STATE/n"
stub_gh 'n=$(cat "$STATE/n"); echo $((n+1)) > "$STATE/n"
if [ "$n" -lt 2 ]; then printf "lint\tpass\nE2E (Playwright)\tpending\n"; exit 0; fi
printf "lint\tpass\nE2E (Playwright)\tpass\n"'
expect "a multi-word pending check is waited for" 0 -- 1 --interval 1
printf '%s' "$sout" | grep -qF "$(printf 'E2E (Playwright)\tpass')" \
  && ok || bad "the multi-word name survives intact to stdout" "stdout: $sout"

stub_gh 'printf "Code Quality - Python\tfail\nlint\tpass\n"'
expect "a multi-word failing check is detected" 1 -- 1 --interval 1
printf '%s' "$sout" | grep -qF "$(printf 'Code Quality - Python\tfail')" \
  && ok || bad "the multi-word failing name survives intact" "stdout: $sout"

# --------------------------------------------------------------------------
# 7. A real gh failure is not an empty result - but a transient one is not
#    fatal either.
# --------------------------------------------------------------------------
stub_gh 'echo "gh: authentication required" >&2; exit 4'
start=$(date +%s)
expect "a persistent gh failure exits 3" 3 -- 1 --interval 1 --empty-grace 60
elapsed=$(( $(date +%s) - start ))
printf '%s' "$serr" | grep -qF 'authentication required' \
  && ok || bad "it reports what gh actually said" "$serr"
[ "$elapsed" -lt 30 ] && ok || bad "it does not burn the grace on a gh error" \
                                   "  waited ${elapsed}s"

echo 0 > "$STATE/n"
stub_gh 'n=$(cat "$STATE/n"); echo $((n+1)) > "$STATE/n"
if [ "$n" -lt 2 ]; then echo "HTTP 502: Bad gateway" >&2; exit 1; fi
printf "lint\tpass\n"'
expect "a transient gh failure is retried, not fatal" 0 -- 1 --interval 1

# --------------------------------------------------------------------------
# 8. Argument validation.
# --------------------------------------------------------------------------
stub_gh 'exit 0'
expect "--empty-grace must be numeric"  3 -- 1 --empty-grace abc
expect "--empty-grace needs a value"    3 -- 1 --empty-grace
expect "--interval must be numeric"     3 -- 1 --interval abc
expect "--timeout must be numeric"      3 -- 1 --timeout abc
# a zero interval busy-loops the very API being waited on
expect "--interval 0 is refused"        3 -- 1 --interval 0
printf '%s' "$serr" | grep -qF 'at least 1 second' \
  && ok || bad "it says why zero is refused" "$serr"

if [ "$fail" -eq 0 ]; then
  printf 'ok — %d wait-for-checks cases passed\n' "$pass"
  exit 0
fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit 1
