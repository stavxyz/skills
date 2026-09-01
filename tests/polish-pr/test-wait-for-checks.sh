#!/usr/bin/env bash
# test-wait-for-checks.sh — behaviour fixtures for wait-for-pr-checks.sh.
#
# The part that silently returns a wrong answer here is the EMPTY result.
# "this PR has no checks" and "the checks have not been registered yet" look
# identical over the API, and the script used to read both as green and exit 0.
# A caller that pushes and then waits is exactly the caller that hits the
# second case, so the failure mode was: push, get told the run is green before
# it has started, and open the merge gate on an unfinished run. Observed on
# backsight PR #153 (2026-09-01), seconds after a force-push.
#
# `gh` is stubbed so every branch is deterministic and no network is used.
#
# Usage: tests/polish-pr/test-wait-for-checks.sh
# Exit:  0 all passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../skills/polish-pr" && pwd)
WAIT="$SCRIPT_DIR/wait-for-pr-checks.sh"

BIN=$(mktemp -d)
STATE=$(mktemp -d)
trap 'rm -rf "$BIN" "$STATE"' EXIT
export PATH="$BIN:$PATH"

pass=0
fail=0

ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); printf 'FAIL: %s\n%s\n' "$1" "${2:-}"; }

# Write a stub `gh`. $1 is the body after the shebang; it may use $STATE.
stub_gh() {
  { echo '#!/usr/bin/env bash'; echo "STATE=$STATE"; printf '%s\n' "$1"; } > "$BIN/gh"
  chmod +x "$BIN/gh"
}

# `gh pr checks` when nothing is registered: exit 1, message on stderr.
NO_CHECKS='echo "no checks reported on the '"'"'x'"'"' branch" >&2; exit 1'

run() { # run <desc> <want_rc> <want_substr> -- <args...>
  local desc=$1 want_rc=$2 want=$3; shift 4
  local out rc
  out=$("$WAIT" "$@" 2>&1); rc=$?
  # `--` before the pattern: an expectation that starts with a dash (the
  # argument-validation cases) is a pattern, not a grep option.
  if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -qF -- "$want"; then
    ok
  else
    bad "$desc" "  want rc=$want_rc containing '$want'
  got  rc=$rc:
$(printf '%s' "$out" | sed 's/^/    /')"
  fi
}

# --------------------------------------------------------------------------
# The regression. Same stub, same flags the caller actually uses: the checks
# are simply not registered on the first poll, and the one that appears has
# FAILED. Before the grace period this exited 0 on the empty first poll.
# --------------------------------------------------------------------------
echo 0 > "$STATE/n"
stub_gh 'n=$(cat "$STATE/n"); echo $((n+1)) > "$STATE/n"
if [ "$n" -lt 1 ]; then '"$NO_CHECKS"'; fi
printf "lint\tfail\nbuild\tpass\n"'
run "a check that appears late and FAILS is not reported green" 1 "CI FAILED" -- 1 --interval 1

# The same shape, but the late checks pass: it must wait for them rather than
# calling the empty first poll green.
echo 0 > "$STATE/n"
stub_gh 'n=$(cat "$STATE/n"); echo $((n+1)) > "$STATE/n"
if [ "$n" -lt 2 ]; then '"$NO_CHECKS"'; fi
printf "lint\tpass\nbuild\tpass\n"'
out=$("$WAIT" 1 --interval 1 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "CI GREEN" \
   && ! printf '%s' "$out" | grep -qF "nothing to wait for"; then
  ok
else
  bad "checks that appear late are waited for, not called 'no checks'" "$out"
fi

# --------------------------------------------------------------------------
# A PR that genuinely has no checks still exits 0 — just not instantly.
# --------------------------------------------------------------------------
stub_gh "$NO_CHECKS"
start=$(date +%s)
run "a PR with genuinely no checks is green after the grace" \
    0 "nothing to wait for" -- 1 --interval 1 --empty-grace 3
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -ge 3 ]; then ok; else
  bad "the grace period is actually waited out" "  returned in ${elapsed}s, grace was 3s"
fi

# --------------------------------------------------------------------------
# A real gh failure is not an empty result: fail fast, do not burn the grace.
# --------------------------------------------------------------------------
stub_gh 'echo "gh: authentication required" >&2; exit 4'
start=$(date +%s)
run "a real gh failure exits 3 immediately" \
    3 "authentication required" -- 1 --interval 1 --empty-grace 30
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -lt 5 ]; then ok; else
  bad "an auth error does not wait out the grace" "  waited ${elapsed}s"
fi

# --------------------------------------------------------------------------
# The original reason this script exists: a multi-word check name must not be
# split, and pending must be waited for.
# --------------------------------------------------------------------------
echo 0 > "$STATE/n"
stub_gh 'n=$(cat "$STATE/n"); echo $((n+1)) > "$STATE/n"
if [ "$n" -lt 2 ]; then printf "lint\tpass\nE2E (Playwright)\tpending\n"; exit 0; fi
printf "lint\tpass\nE2E (Playwright)\tpass\n"'
run "a multi-word pending check is waited for" 0 "CI GREEN" -- 1 --interval 1

# A failing multi-word check is still read from the bucket column, not by
# whitespace position.
stub_gh 'printf "Code Quality - Python\tfail\nlint\tpass\n"; exit 0'
run "a multi-word failing check is detected" 1 "CI FAILED" -- 1 --interval 1

# --------------------------------------------------------------------------
# Argument validation.
# --------------------------------------------------------------------------
stub_gh 'exit 0'
run "--empty-grace must be numeric" 3 "empty-grace must be numeric" -- 1 --empty-grace abc
run "--empty-grace needs a value"   3 "--empty-grace needs a value" -- 1 --empty-grace

if [ "$fail" -eq 0 ]; then
  printf 'ok — %d wait-for-checks cases passed\n' "$pass"
  exit 0
fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit 1
