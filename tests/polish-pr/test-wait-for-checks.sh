#!/usr/bin/env bash
# test-wait-for-checks.sh: decision fixtures for wait-for-pr-checks.sh.
#
# The verdict is the whole product: exit 0 is what SKILL.md treats as "open the
# browser, this is ready to merge". Every path that can reach exit 0 gets a
# fixture, and so does the race that used to reach it wrongly: an empty result
# right after a push, before the check runs are registered, is indistinguishable
# from a repo with no CI in a single reading.
#
# gh is replaced by a stub that emits a scripted sequence, one reading per line
# of a fixture file, so the loop runs with no network and no live PR.
#
# Usage: tests/polish-pr/test-wait-for-checks.sh
# Exit:  0 all passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../skills/polish-pr" && pwd)
WATCHER="$SCRIPT_DIR/wait-for-pr-checks.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The stub reads one "reading" per invocation from a script file. A reading is
# TSV rows, one of the two empty forms, or ERROR for a genuine gh failure.
#
# EMPTY reproduces what gh actually does, which is NOT what the obvious stub
# would do. Measured against gh 2.96.0 on a PR with no checks: it exits 1 and
# writes "no checks reported on the '<branch>' branch" to stderr. It does not
# exit 0. So the arm of the condition that fires in production is the stderr
# grep, and a stub that exits 0 silently exercises only the other arm. An
# earlier version of this file did exactly that, and deleting the grep arm left
# all of its cases green.
#
# EMPTY_RC0 keeps the rc=0 arm covered as well, since the script accepts both
# and a future gh may change which one it uses.
cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
state="$GH_STUB_STATE"
script="$GH_STUB_SCRIPT"
n=$(cat "$state" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$state"
line=$(sed -n "${n}p" "$script")
[ -z "$line" ] && line=$(tail -n 1 "$script")   # last reading repeats forever
case "$line" in
  EMPTY)     echo "no checks reported on the 'some-branch' branch" >&2; exit 1 ;;
  EMPTY_RC0) exit 0 ;;
  ERROR)     echo "some gh failure" >&2; exit 1 ;;
  *)         printf '%s\n' "$line" | tr '|' '\n' ;;
esac
STUB
chmod +x "$tmp/gh"

pass=0
fail=0

# run <desc> <want-exit> <readings...>
run() {
  local desc=$1 want=$2; shift 2
  local script="$tmp/script.txt"
  printf '%s\n' "$@" > "$script"
  : > "$tmp/state"
  local out got
  out=$(GH_STUB_STATE="$tmp/state" GH_STUB_SCRIPT="$script" \
        WAIT_FOR_PR_CHECKS_GH="$tmp/gh" \
        "$WATCHER" 1 --interval 0 --settle 0 --timeout 5 2>&1)
  got=$?
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  want exit: %s\n  got exit:  %s\n  output:\n%s\n' \
      "$desc" "$want" "$got" "$out"
  fi
}

# run_settle_output <desc> <want-exit> <want-substring> <settle> <timeout> <readings...>
run_settle_output() {
  local desc=$1 want=$2 want_out=$3 settle=$4 timeout=$5; shift 5
  local script="$tmp/script.txt"
  printf '%s\n' "$@" > "$script"
  : > "$tmp/state"
  local out got
  out=$(GH_STUB_STATE="$tmp/state" GH_STUB_SCRIPT="$script" \
        WAIT_FOR_PR_CHECKS_GH="$tmp/gh" \
        "$WATCHER" 1 --interval 0 --settle "$settle" --timeout "$timeout" 2>&1)
  got=$?
  if [ "$got" = "$want" ] && grep -qF "$want_out" <<<"$out"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  want exit %s and output containing %s\n  got exit %s, output:\n%s\n' \
      "$desc" "$want" "$want_out" "$got" "$out"
  fi
}

# run_settle_refute <desc> <forbidden-substring> <settle> <timeout> <readings...>
run_settle_refute() {
  local desc=$1 forbidden=$2 settle=$3 timeout=$4; shift 4
  local script="$tmp/script.txt"
  printf '%s\n' "$@" > "$script"
  : > "$tmp/state"
  local out
  out=$(GH_STUB_STATE="$tmp/state" GH_STUB_SCRIPT="$script" \
        WAIT_FOR_PR_CHECKS_GH="$tmp/gh" \
        "$WATCHER" 1 --interval 0 --settle "$settle" --timeout "$timeout" 2>&1)
  if grep -qF "$forbidden" <<<"$out"; then
    fail=$((fail + 1))
    printf 'FAIL: %s\n  output must NOT contain %s, but it did:\n%s\n' "$desc" "$forbidden" "$out"
  else
    pass=$((pass + 1))
  fi
}

# run_settle <desc> <want-exit> <settle> <timeout> <readings...>
run_settle() {
  local desc=$1 want=$2 settle=$3 timeout=$4; shift 4
  local script="$tmp/script.txt"
  printf '%s\n' "$@" > "$script"
  : > "$tmp/state"
  local out got
  out=$(GH_STUB_STATE="$tmp/state" GH_STUB_SCRIPT="$script" \
        WAIT_FOR_PR_CHECKS_GH="$tmp/gh" \
        "$WATCHER" 1 --interval 0 --settle "$settle" --timeout "$timeout" 2>&1)
  got=$?
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  want exit: %s\n  got exit:  %s\n  output:\n%s\n' \
      "$desc" "$want" "$got" "$out"
  fi
}

# run_usage <desc> <want-exit> <args...> -- validation runs before the loop, so
# these need no scripted reading.
run_usage() {
  local desc=$1 want=$2; shift 2
  local got
  WAIT_FOR_PR_CHECKS_GH="$tmp/gh" "$WATCHER" "$@" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  want exit: %s\n  got exit:  %s\n' "$desc" "$want" "$got"
  fi
}

# run_calls <desc> <want-gh-calls> <args...> <-- readings> -- asserts how many
# times gh was invoked, which is the only way to tell "believed at once" from
# "believed after a sleep".
run_calls() {
  local desc=$1 want=$2 args=$3; shift 3
  local script="$tmp/script.txt"
  printf '%s\n' "$@" > "$script"
  : > "$tmp/state"
  # shellcheck disable=SC2086
  GH_STUB_STATE="$tmp/state" GH_STUB_SCRIPT="$script" \
    WAIT_FOR_PR_CHECKS_GH="$tmp/gh" "$WATCHER" 1 $args >/dev/null 2>&1
  local got
  got=$(cat "$tmp/state" 2>/dev/null || echo 0)
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  want %s gh call(s)\n  got  %s\n' "$desc" "$want" "$got"
  fi
}

P=$'build\tpass'
F=$'build\tfail'
W=$'build\tpending'
C=$'build\tcancel'
S=$'build\tskipping'
MULTI="E2E (Playwright)"$'\t'"pending|Code Quality - Python"$'\t'"pass"

# Settled verdicts.
run "all pass"                       0 "$P"
run "a skipping check is not a fail" 0 "$S"
run "one failing check"              1 "$F"
run "a cancelled check"              1 "$C"
run "pending then pass"              0 "$W" "$P"
run "pending then fail"              1 "$W" "$F"
run "gh itself fails"                3 "ERROR"

# A multi-word check name must not be read as settled while it is pending.
# This is the failure the --json rewrite was for. The expected verdict is
# deliberately 1, not 0: a script that splits rows on whitespace reads
# "E2E (Playwright)" as a pass, settles on the FIRST reading, and exits 0
# before it ever sees the failure in the second. Asserting 0 here would pass
# against exactly that regression, which an earlier version of this file did.
run "multi-word name blocks settling"  1 "$MULTI" "$F"

# The race this file exists for. With --settle 0 the old behaviour is preserved
# for anyone who opts out; above 0, an empty reading must persist.
run "empty with --settle 0 is green" 0 "EMPTY"
run "the rc=0 empty form is also accepted" 0 "EMPTY_RC0"

run_settle "rc=0 empty form settles the same way" 0 1 30 "EMPTY_RC0"

# Exit 0 alone cannot distinguish "waited, then saw them pass" from "reported
# green before any check existed", so this one asserts on the output too.
run_settle_output "empty, then checks appear, must wait rather than shortcut" \
  0 "CI GREEN (all checks settled)" 5 30 \
  "EMPTY" "EMPTY" "$W" "$P"

run_settle_refute "empty, then checks appear, must not claim there is no CI" \
  "no checks on this PR" 5 30 \
  "EMPTY" "EMPTY" "$W" "$P"

run_settle "empty, then checks appear and one fails" 1 5 30 \
  "EMPTY" "EMPTY" "$F"

run_settle "empty throughout the settle window is genuinely no CI" 0 1 30 \
  "EMPTY"

run_settle "checks that never register hit the timeout, not green" 2 30 1 \
  "EMPTY"

# An empty reading AFTER checks have been seen must never reach the no-CI exit.
# Once a reading has returned rows, "this PR has no checks" is disproved by the
# run's own history, so the anomaly has to resolve or time out. These use a real
# --interval so wall-clock time actually accumulates; with --interval 0 the
# window can never close and the case would pass for the wrong reason.
run_settle_refute "checks then empty never claims there is no CI" \
  "no checks on this PR" 1 4 \
  "$W" "EMPTY"

run_settle "checks then empty forever times out rather than going green" 2 1 3 \
  "$W" "EMPTY"

run_settle "checks then empty then pass still settles green" 0 1 30 \
  "$W" "EMPTY" "$P"

run_settle_refute "an empty window before checks does not leak into a later one" \
  "no checks on this PR" 2 30 \
  "EMPTY" "$W" "EMPTY" "$P"

# The shipped default is the only value that reaches production, because
# SKILL.md invokes the script with no --settle flag. Without this case, changing
# the default back to 0 leaves every other fixture green, which is precisely the
# regression this file exists to prevent. A one-second timeout cannot outlast a
# 90-second window, so exit 2 proves the default is still in force; exit 0 would
# mean it was lost.
run_default_settle() {
  local desc=$1 want=$2; shift 2
  local script="$tmp/script.txt"
  printf '%s\n' "$@" > "$script"
  : > "$tmp/state"
  local got
  GH_STUB_STATE="$tmp/state" GH_STUB_SCRIPT="$script" \
    WAIT_FOR_PR_CHECKS_GH="$tmp/gh" "$WATCHER" 1 --interval 0 --timeout 1 >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  want exit: %s\n  got exit:  %s\n' "$desc" "$want" "$got"
  fi
}
run_default_settle "the shipped default settle is long enough to outlast 1s" 2 "EMPTY"

# A#4: --settle 0 must be believed on the spot, not after a sleep. Exit code
# alone cannot tell those apart; the gh call count can.
run_calls "--settle 0 believes the first empty reading" 1 "--interval 20 --settle 0" "EMPTY"

# The classic pending timeout, which predates this change and had no fixture.
run_settle "pending past the deadline times out" 2 0 0 "$W"

# Usage and validation. The --settle input is new in this change, so its
# rejection paths are this change's to cover.
run_usage "negative settle"        3 1 --settle -1
run_usage "non-numeric settle"     3 1 --settle abc
run_usage "settle with no value"   3 1 --settle
run_usage "non-numeric interval"   3 1 --interval abc
run_usage "missing pr number"      3
run_usage "unknown argument"       3 1 --nope

# The seam makes the "gh is missing" arm testable for the first time.
if WAIT_FOR_PR_CHECKS_GH=/nonexistent/gh "$WATCHER" 1 >/dev/null 2>&1; then
  fail=$((fail + 1)); printf 'FAIL: a missing gh binary should exit 3\n'
else
  [ $? -eq 3 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); printf 'FAIL: missing gh exited non-3\n'; }
fi

if [ "$fail" -eq 0 ]; then
  printf 'ok: %d verdict cases passed\n' "$pass"
  exit 0
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
exit 1
