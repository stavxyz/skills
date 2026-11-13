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
#
# Only `gh pr checks` consumes a scripted reading. Before it believes green the
# watcher also asks for the PR's head (`gh pr view`) and for that commit's
# workflow runs (`gh run list`). The stub answers those from GH_STUB_HEAD and
# from GH_STUB_RUNS, a file with one line per call (the last repeats) holding
# comma-separated run statuses; it builds the JSON gh would return and runs the
# watcher's own --jq program over it, so the program is under test too.
# Defaults: a valid head, and one completed run. Requires jq.
command -v jq >/dev/null 2>&1 || { echo "test-wait-for-checks.sh needs jq on PATH" >&2; exit 1; }

cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
# Calls made without a scripted state (the usage cases) still need somewhere to
# keep the stub's own notes that is not the caller's working directory.
: "${GH_STUB_STATE:=$(dirname "$0")/state}"
jq_prog=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && jq_prog=$a; prev=$a; done
if [ "$1 $2" = "pr view" ]; then
  h="${GH_STUB_HEAD-1111111111111111111111111111111111111111}"
  # GH_STUB_HEADS: one head per call, the last repeats. The first call is the
  # watcher's startup reading.
  if [ -n "${GH_STUB_HEADS:-}" ]; then
    k=$(cat "$GH_STUB_HEADS.n" 2>/dev/null || echo 0); k=$((k + 1)); echo "$k" > "$GH_STUB_HEADS.n"
    h=$(sed -n "${k}p" "$GH_STUB_HEADS"); [ -z "$h" ] && h=$(tail -n 1 "$GH_STUB_HEADS")
  fi
  [ "$h" = "ERROR" ] && { echo "view failed" >&2; exit 1; }
  echo "$h" > "$GH_STUB_STATE.head"
  jq -n --arg h "$h" '{headRefOid:$h}' | jq -r "$jq_prog"
  exit 0
fi
if [ "$1 $2" = "run list" ]; then
  line="completed"
  if [ -n "${GH_STUB_RUNS:-}" ]; then
    k=$(cat "$GH_STUB_RUNS.n" 2>/dev/null || echo 0); k=$((k + 1)); echo "$k" > "$GH_STUB_RUNS.n"
    line=$(sed -n "${k}p" "$GH_STUB_RUNS"); [ -z "$line" ] && line=$(tail -n 1 "$GH_STUB_RUNS")
  fi
  # Like gh, list only the runs of the commit asked for: a watcher that passed
  # the wrong sha would get an empty list from GitHub and call it green.
  commit=""; prev=""
  for a in "$@"; do [ "$prev" = "--commit" ] && commit=$a; prev=$a; done
  [ "$commit" = "$(cat "$GH_STUB_STATE.head" 2>/dev/null)" ] || line="NONE"
  # A run is "status" or "completed:conclusion"; bare "completed" succeeded.
  case "$line" in
    ERROR)   echo "run list failed" >&2; exit 1 ;;
    GARBAGE) echo "not a run row" ;;
    NONE)    echo '[]' | jq -r "$jq_prog" ;;
    *)       jq -n --arg s "$line" '$s | split(",") | map(split(":") | {name: ("wf-" + .[0]), status: .[0],
               conclusion: (if .[0] == "completed" then (.[1] // "success") else null end)})' | jq -r "$jq_prog" ;;
  esac
  exit 0
fi
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
  0 "CI GREEN (1 check(s) settled" 5 30 \
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
run_missing_gh() {
  local got
  WAIT_FOR_PR_CHECKS_GH=/nonexistent/gh "$WATCHER" 1 >/dev/null 2>&1
  got=$?
  if [ "$got" = 3 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: a missing gh binary should exit 3, got %s\n' "$got"
  fi
}
run_missing_gh

# --- green needs more than "nothing pending" ----------------------------------
# with_env <desc> <want-exit> <want-substring> <settle> <timeout> <env...> -- <readings...>
with_env() {
  local desc=$1 want=$2 want_out=$3 settle=$4 timeout=$5; shift 5
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  printf '%s\n' "$@" > "$tmp/script.txt"
  : > "$tmp/state"
  rm -f "$tmp/runs.txt.n" "$tmp/heads.txt.n"
  local out got
  out=$(env GH_STUB_STATE="$tmp/state" GH_STUB_SCRIPT="$tmp/script.txt" \
        WAIT_FOR_PR_CHECKS_GH="$tmp/gh" ${envs[@]+"${envs[@]}"} \
        "$WATCHER" 1 --interval 0 --settle "$settle" --timeout "$timeout" 2>&1)
  got=$?
  if [ "$got" = "$want" ] && grep -qF -- "$want_out" <<<"$out"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  want exit %s and output containing: %s\n  got exit %s, output:\n%s\n' \
      "$desc" "$want" "$want_out" "$got" "$out" | tail -n 12
  fi
}

ONE=$'fast-workflow\tpass'
TEN=$'fast-workflow\tpass|slow-workflow\tpending'
TENF=$'fast-workflow\tpass|slow-workflow\tfail'

# One fast check passes before the slow workflow has registered: the old
# watcher exited green on the first reading.
with_env "a lone early pass is not green while the registration window is open" \
  1 "VERDICT: failed" 2 30 -- "$ONE" "$ONE" "$TEN" "$TENF"
with_env "a lone early pass, then the rest register and pass, is green after the window" \
  0 "VERDICT: green" 1 30 -- "$ONE" "$TEN" "$P"

# A run that exists but has no jobs yet is invisible to the check list.
printf '%s\n' "completed,queued" "completed,in_progress" "completed,completed" > "$tmp/runs.txt"
with_env "an unfinished workflow run for the head holds green back until it completes" \
  0 "workflow run(s) for the head commit not completed" 0 30 GH_STUB_RUNS="$tmp/runs.txt" -- "$P"
printf '%s\n' "completed,queued" > "$tmp/runs.txt"
with_env "a workflow run that never completes is a timeout, not green" \
  2 "VERDICT: timeout" 0 1 GH_STUB_RUNS="$tmp/runs.txt" -- "$P"
printf '%s\n' "NONE" > "$tmp/runs.txt"
with_env "checks from outside Actions, with no workflow runs at all, can be green" \
  0 "VERDICT: green" 0 30 GH_STUB_RUNS="$tmp/runs.txt" -- "$P"
printf '%s\n' "ERROR" > "$tmp/runs.txt"
with_env "gh failing on the run list is an error, never green" \
  3 "VERDICT: error" 0 30 GH_STUB_RUNS="$tmp/runs.txt" -- "$P"
with_env "gh failing on the head lookup is an error, never green" \
  3 "VERDICT: error" 0 30 GH_STUB_HEAD=ERROR -- "$P"
with_env "an unreadable head sha is an error, never green" \
  3 "unreadable head sha" 0 30 GH_STUB_HEAD= -- "$P"

printf '%s\n' "completed,queued" > "$tmp/runs.txt"
with_env "a timeout on an unfinished run names the run and its status" \
  2 "wf-queued (queued)" 0 1 GH_STUB_RUNS="$tmp/runs.txt" -- "$P"

# A run held in its concurrency group has no jobs, so the check list is empty
# too. "No checks" must not be called "no CI" while such a run is waiting.
printf '%s\n' "queued" > "$tmp/runs.txt"
with_env "an empty check list is not green while a workflow run for the head is queued" \
  2 "VERDICT: timeout" 0 1 GH_STUB_RUNS="$tmp/runs.txt" -- "EMPTY"
printf '%s\n' "queued" "completed" > "$tmp/runs.txt"
with_env "an empty check list goes green once the queued run completes with no checks" \
  0 "no workflow run waiting" 0 30 GH_STUB_RUNS="$tmp/runs.txt" -- "EMPTY"
printf '%s\n' "ERROR" > "$tmp/runs.txt"
with_env "gh failing on the run list is an error on the no-checks path too" \
  3 "VERDICT: error" 0 30 GH_STUB_RUNS="$tmp/runs.txt" -- "EMPTY"

# The rows and the head come from separate calls. A push between them must
# start the wait over, not pair the old head's passes with the new head's
# unregistered runs.
A=1111111111111111111111111111111111111111
B=2222222222222222222222222222222222222222
printf '%s\n' "$A" "$B" > "$tmp/heads.txt"
with_env "a head that moved during the watch restarts the settle window" \
  0 "head moved to 222222222222" 0 30 GH_STUB_HEADS="$tmp/heads.txt" -- "$P"
printf '%s\n' "$A" "$B" > "$tmp/heads.txt"
with_env "a head that moved is not green on that reading: the next rows decide" \
  1 "VERDICT: failed" 0 30 GH_STUB_HEADS="$tmp/heads.txt" -- "$P" "$F"
printf '%s\n' "$A" "ERROR" > "$tmp/heads.txt"
with_env "gh failing on the later head lookup is an error, never green" \
  3 "gh failed while confirming workflow runs" 0 30 GH_STUB_HEADS="$tmp/heads.txt" -- "$P"

# A run that failed before it had any job has no row in the check list.
for c in failure startup_failure timed_out action_required; do
  printf '%s\n' "completed,completed:$c" > "$tmp/runs.txt"
  with_env "a run that ended in $c with no check row is a failure, not green" \
    1 "wf-completed ($c)" 0 30 GH_STUB_RUNS="$tmp/runs.txt" -- "$P"
done
printf '%s\n' "completed:failure" > "$tmp/runs.txt"
with_env "a failed run with no checks at all is a failure, not 'no CI'" \
  1 "VERDICT: failed" 0 30 GH_STUB_RUNS="$tmp/runs.txt" -- "EMPTY"
printf '%s\n' "completed,completed:cancelled,completed:skipped,completed:neutral" > "$tmp/runs.txt"
with_env "cancelled, skipped, and neutral runs do not block green" \
  0 "VERDICT: green" 0 30 GH_STUB_RUNS="$tmp/runs.txt" -- "$P"
printf '%s\n' "GARBAGE" > "$tmp/runs.txt"
with_env "an unreadable run list is an error, never green" \
  3 "unreadable run list" 0 30 GH_STUB_RUNS="$tmp/runs.txt" -- "$P"

# A push cancels the superseded run; the list can briefly still show it.
with_env "a cancel inside the settle window is re-polled, and green follows" \
  0 "cancelled check(s) inside the settle window" 3 30 -- "$C" "$P"
with_env "a cancel that outlasts the settle window is a failure" \
  1 "VERDICT: failed" 1 30 -- "$C"
with_env "a fail is final even inside the settle window" \
  1 "VERDICT: failed" 30 30 -- "$F"

# refute_env <desc> <forbidden-substring> <settle> <timeout> <readings...>
refute_env() {
  local desc=$1 forbidden=$2 settle=$3 timeout=$4; shift 4
  printf '%s\n' "$@" > "$tmp/script.txt"
  : > "$tmp/state"
  local out
  out=$(GH_STUB_STATE="$tmp/state" GH_STUB_SCRIPT="$tmp/script.txt" WAIT_FOR_PR_CHECKS_GH="$tmp/gh" \
        "$WATCHER" 1 --interval 0 --settle "$settle" --timeout "$timeout" 2>&1)
  if grep -qF -- "$forbidden" <<<"$out"; then
    fail=$((fail + 1)); printf 'FAIL: %s\n  output must NOT contain: %s\n' "$desc" "$forbidden"
  else
    pass=$((pass + 1))
  fi
}
# Exit codes cannot tell "failed at once" from "re-polled until the deadline,
# then failed", so these two read the output.
refute_env "a fail is never re-polled as if it were a cancel" \
  "inside the settle window" 3 3 "$F"
refute_env "a cancel is not re-polled once the settle window has passed" \
  "(1s of 1s)" 1 3 "$C"

# The last stdout line names the verdict for a caller that lost the exit code.
with_env "a gh failure says VERDICT: error" 3 "VERDICT: error" 0 30 -- "ERROR"
with_env "the green line counts the checks it settled on" 0 "1 check(s) settled" 0 30 -- "$P"
piped=$(GH_STUB_STATE="$tmp/state" GH_STUB_SCRIPT="$tmp/script.txt" WAIT_FOR_PR_CHECKS_GH="$tmp/gh" \
        bash -c 'printf "ERROR\n" > "$GH_STUB_SCRIPT"; : > "$GH_STUB_STATE"; "$0" 1 --interval 0 --settle 0 2>/dev/null | tail -n 1' "$WATCHER")
for args in "--bogus" "abc" "--settle"; do
  # shellcheck disable=SC2086
  last=$(WAIT_FOR_PR_CHECKS_GH="$tmp/gh" "$WATCHER" 1 $args 2>/dev/null | tail -n 1)
  if [ "$last" = "VERDICT: error" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); printf 'FAIL: usage error (%s) piped through tail should end with the verdict, got: %s\n' "$args" "$last"
  fi
done
last=$(WAIT_FOR_PR_CHECKS_GH="$tmp/no-such-gh" "$WATCHER" 1 2>/dev/null | tail -n 1)
if [ "$last" = "VERDICT: error" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL: a missing gh piped through tail should end with the verdict, got: %s\n' "$last"
fi
# An exit the script did not plan (here `date` failing under set -e) still ends
# with a verdict, from the EXIT trap.
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/date"
chmod +x "$tmp/bin/date"
last=$(PATH="$tmp/bin:$PATH" WAIT_FOR_PR_CHECKS_GH="$tmp/gh" "$WATCHER" 1 --settle 0 --timeout 5 2>/dev/null | tail -n 1)
if [ "$last" = "VERDICT: error" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL: an unplanned abort should still end with the verdict, got: %s\n' "$last"
fi
if [ "$piped" = "VERDICT: error" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL: piped through tail, the last line should be the verdict, got: %s\n' "$piped"
fi

if [ "$fail" -eq 0 ]; then
  printf 'ok: %d verdict cases passed\n' "$pass"
  exit 0
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
exit 1
