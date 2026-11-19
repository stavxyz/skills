#!/usr/bin/env bash
# test-tick-test-plan.sh: decision fixtures for skills/land-pr/tick-test-plan.py.
#
# The helper's failure mode is a quiet one: evidence recorded under the wrong
# box, or a box ticked twice, in a PR description that nobody rereads. So every
# case that must change nothing asserts that nothing was written back, and
# every case that changes something compares the whole description byte for
# byte, which also covers CRLF endings and a missing final newline.
#
# gh is replaced by a stub. `gh pr view` serves the scripted description as
# the JSON gh returns for `--json body`, and refuses a call that did not ask
# for that field; `gh pr edit` copies the --body-file it is given to a file the
# test reads. Every call is logged, so a case can assert that gh was never run.
#
# Usage: tests/land-pr/test-tick-test-plan.sh
# Exit:  0 all passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../skills/land-pr" && pwd)
TICK="$SCRIPT_DIR/tick-test-plan.py"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_STUB_LOG"
case "$1 $2" in
  "pr view")
    [ -n "${GH_STUB_FAIL_VIEW:-}" ] && { echo "GraphQL: Could not resolve to a PullRequest" >&2; exit 1; }
    json=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "--json" ] && json=$a
      prev=$a
    done
    [ "$json" = "body" ] || { echo "stub: pr view must ask for --json body, got: $*" >&2; exit 9; }
    python3 -c 'import json, sys; sys.stdout.write(json.dumps({"body": open(sys.argv[1], newline="", encoding="utf-8").read()}))' "$GH_STUB_BODY"
    ;;
  "pr edit")
    f=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && f=$a
      prev=$a
    done
    [ -n "$f" ] || { echo "stub: pr edit without --body-file: $*" >&2; exit 9; }
    cp "$f" "$GH_STUB_WRITTEN"
    ;;
  *) echo "stub: unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$tmp/gh"

pass=0
fail=0

ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2"; }

# tick <body-file> <args...>: runs the helper against the stub serving
# <body-file>; sets $out and $got, and leaves the written body (if any) in
# $tmp/written and the gh call log in $tmp/gh.log.
tick() {
  local body=$1; shift
  rm -f "$tmp/written"
  : > "$tmp/gh.log"
  out=$(GH_STUB_BODY="$body" GH_STUB_WRITTEN="$tmp/written" GH_STUB_LOG="$tmp/gh.log" \
        TICK_TEST_PLAN_GH="$tmp/gh" python3 "$TICK" "$@" 2>&1)
  got=$?
}

# check <desc> <want-exit> [<want-substring>]
check() {
  local desc=$1 want=$2 want_out=${3:-}
  if [ "$got" = "$want" ] && { [ -z "$want_out" ] || grep -qF -- "$want_out" <<<"$out"; }; then
    ok
  else
    bad "$desc" "  want exit $want${want_out:+ and output containing: $want_out}
  got exit $got, output:
$out"
  fi
}

# written_is <desc> <expected-file>: the body written back equals the file.
written_is() {
  if [ -f "$tmp/written" ] && cmp -s "$tmp/written" "$2"; then
    ok
  else
    bad "$1" "  expected:
$(cat -et "$2")
  written:
$( [ -f "$tmp/written" ] && cat -et "$tmp/written" || echo '(nothing written)')"
  fi
}

nothing_written() {
  if [ -f "$tmp/written" ] || grep -q '^pr edit' "$tmp/gh.log"; then
    bad "$1: nothing should have been written" "$(cat "$tmp/gh.log")"
  else
    ok
  fi
}

# --- the fixture description --------------------------------------------------
cat > "$tmp/body.md" <<'EOF'
## Summary

Example: the widget endpoint gains a retry.

## Test plan

### Pre-merge
- [ ] Run the suite: all tests pass
  - earlier note
  - second note
- [ ] Lint is clean
- [x] Already done box

### Post-merge [dev]
- [ ] Run the suite: all tests pass
- [ ] Example: the widget endpoint answers 200

```bash
# Not a heading: a comment inside a fence
- [ ] not a box inside a fence
```
EOF

# --- ticks the one matching box -----------------------------------------------
tick "$tmp/body.md" 7 --box "Lint is clean" --evidence "ruff check: clean at 2026-01-02 03:04 UTC"
check "a unique unticked box is ticked" 0
sed -e 's/^- \[ \] Lint is clean$/- [x] Lint is clean\
  - ruff check: clean at 2026-01-02 03:04 UTC/' "$tmp/body.md" > "$tmp/want1.md"
written_is "the box is ticked and the evidence sits beneath it, nothing else changes" "$tmp/want1.md"
if grep -q '^pr view 7 --json body' "$tmp/gh.log" && grep -q '^pr edit 7 --body-file ' "$tmp/gh.log"; then
  ok
else
  bad "gh is called as pr view <PR> --json body, then pr edit <PR> --body-file" "$(cat "$tmp/gh.log")"
fi
check "the summary counts ticked boxes" 0 "2 ticked"
check "the summary counts boxes left unticked" 0 "3 unticked"
check "the summary names a box left unticked" 0 "Example: the widget endpoint answers 200"

# --repo is forwarded to both calls.
tick "$tmp/body.md" 7 --repo example-org/example-repo --box "Lint is clean" --evidence "ok"
check "--repo run succeeds" 0
if [ "$(grep -c -- '--repo example-org/example-repo' "$tmp/gh.log")" = "2" ]; then
  ok
else
  bad "--repo is passed to pr view and pr edit" "$(cat "$tmp/gh.log")"
fi

# --- evidence goes after the box's own nested lines ---------------------------
tick "$tmp/body.md" 7 --under "Pre-merge" --box "Run the suite" --evidence "pytest: 12 passed"
check "--under picks the box under the named heading" 0
python3 - "$tmp/body.md" "$tmp/want2.md" <<'PY'
import sys
src = open(sys.argv[1], newline="").read()
old = "- [ ] Run the suite: all tests pass\n  - earlier note\n  - second note\n- [ ] Lint is clean"
new = "- [x] Run the suite: all tests pass\n  - earlier note\n  - second note\n  - pytest: 12 passed\n- [ ] Lint is clean"
assert src.count(old) == 1
open(sys.argv[2], "w", newline="").write(src.replace(old, new))
PY
written_is "evidence follows the existing nested lines and precedes the next box" "$tmp/want2.md"

tick "$tmp/body.md" 7 --under "Post-merge" --box "Run the suite" --evidence "dev: 12 passed"
check "--under picks the other box of the same text" 0
python3 - "$tmp/body.md" "$tmp/want3.md" <<'PY'
import sys
src = open(sys.argv[1], newline="").read()
old = "### Post-merge [dev]\n- [ ] Run the suite: all tests pass\n"
new = "### Post-merge [dev]\n- [x] Run the suite: all tests pass\n  - dev: 12 passed\n"
assert src.count(old) == 1
open(sys.argv[2], "w", newline="").write(src.replace(old, new))
PY
written_is "the post-merge box is the one ticked" "$tmp/want3.md"

# --- ambiguity and zero matches change nothing -------------------------------
tick "$tmp/body.md" 7 --box "Run the suite" --evidence "pytest: 12 passed"
check "two boxes with the same text and no --under is refused" 1 "ambiguous"
check "the first candidate is listed with its line number" 1 "8: - [ ] Run the suite: all tests pass"
check "the second candidate is listed with its line number" 1 "15: - [ ] Run the suite: all tests pass"
nothing_written "ambiguous match"

tick "$tmp/body.md" 7 --box "Deploy succeeded" --evidence "ok"
check "zero matches is refused" 1 "no box"
check "zero matches lists the boxes it considered" 1 "11: - [ ] Lint is clean"
nothing_written "zero matches"

# Tight negative for the prefix rule: the text appears later in the line.
tick "$tmp/body.md" 7 --box "the widget endpoint" --evidence "ok"
check "a box that merely contains the text later in the line does not match" 1 "no box"
nothing_written "contains-but-not-prefix"

tick "$tmp/body.md" 7 --box "not a box inside" --evidence "ok"
check "a box-shaped line inside a code fence is not a box" 1 "no box"
nothing_written "fenced line"

# --- an exact match wins ------------------------------------------------------
# A box whose whole text is the start of another box's text must still be
# selectable; when exactly one box's text equals --box, it is the one.
printf '## Test plan\n\n- [ ] Deploy\n- [ ] Deploy to prod\n' > "$tmp/exact.md"
tick "$tmp/exact.md" 7 --box "Deploy" --evidence "deployed"
check "an exact match is taken over a longer box that starts the same" 0
printf '## Test plan\n\n- [x] Deploy\n  - deployed\n- [ ] Deploy to prod\n' > "$tmp/want-exact.md"
written_is "the exactly matching box is ticked" "$tmp/want-exact.md"
tick "$tmp/exact.md" 7 --box "Deploy to" --evidence "deployed"
printf '## Test plan\n\n- [ ] Deploy\n- [x] Deploy to prod\n  - deployed\n' > "$tmp/want-exact2.md"
written_is "a prefix that only one box starts with still selects it" "$tmp/want-exact2.md"
printf '## Test plan\n\n- [ ] Deploy\n- [ ] Deploy\n- [ ] Deploy to prod\n' > "$tmp/exact2.md"
tick "$tmp/exact2.md" 7 --box "Deploy" --evidence "deployed"
check "two exact matches are still ambiguous" 1 "ambiguous"
nothing_written "two exact matches"

# --- already ticked, and --note-only ------------------------------------------
tick "$tmp/body.md" 7 --box "Already done" --evidence "again"
check "an already ticked box is refused without --note-only" 1 "already ticked"
nothing_written "already ticked"

tick "$tmp/body.md" 7 --box "Already done" --evidence "checked, not met as written: see the log" --note-only
check "--note-only annotates an already ticked box" 0
python3 - "$tmp/body.md" "$tmp/want4.md" <<'PY'
import sys
src = open(sys.argv[1], newline="").read()
old = "- [x] Already done box\n"
new = "- [x] Already done box\n  - checked, not met as written: see the log\n"
open(sys.argv[2], "w", newline="").write(src.replace(old, new))
PY
written_is "the ticked box keeps its mark and gains the note" "$tmp/want4.md"

tick "$tmp/body.md" 7 --box "Lint is clean" --evidence "ran it; two warnings remain" --note-only
check "--note-only on an unticked box succeeds" 0
python3 - "$tmp/body.md" "$tmp/want5.md" <<'PY'
import sys
src = open(sys.argv[1], newline="").read()
old = "- [ ] Lint is clean\n"
new = "- [ ] Lint is clean\n  - ran it; two warnings remain\n"
open(sys.argv[2], "w", newline="").write(src.replace(old, new))
PY
written_is "--note-only leaves an unticked box unticked" "$tmp/want5.md"

# --- batches ------------------------------------------------------------------
cat > "$tmp/batch-bad.json" <<'EOF'
[
  {"box": "Lint is clean", "evidence": "clean"},
  {"box": "Deploy succeeded", "evidence": "ok"}
]
EOF
tick "$tmp/body.md" 7 --from "$tmp/batch-bad.json"
check "a batch whose second entry does not resolve is refused" 1 "Deploy succeeded"
nothing_written "batch with an unresolved entry"

cat > "$tmp/batch-good.json" <<'EOF'
[
  {"box": "Lint is clean", "evidence": "clean"},
  {"box": "Run the suite", "under": "Post-merge", "evidence": "dev: green"},
  {"box": "Already done", "evidence": "note", "note_only": true}
]
EOF
tick "$tmp/body.md" 7 --from "$tmp/batch-good.json"
check "a batch that resolves fully is written once" 0
python3 - "$tmp/body.md" "$tmp/want6.md" <<'PY'
import sys
s = open(sys.argv[1], newline="").read()
for old, new in [
    ("- [ ] Lint is clean\n", "- [x] Lint is clean\n  - clean\n"),
    ("- [x] Already done box\n", "- [x] Already done box\n  - note\n"),
    ("### Post-merge [dev]\n- [ ] Run the suite: all tests pass\n",
     "### Post-merge [dev]\n- [x] Run the suite: all tests pass\n  - dev: green\n"),
]:
    assert s.count(old) == 1, old
    s = s.replace(old, new)
open(sys.argv[2], "w", newline="").write(s)
PY
written_is "every batch entry is applied" "$tmp/want6.md"
if [ "$(grep -c '^pr edit' "$tmp/gh.log")" = "1" ]; then ok; else bad "a batch writes once" "$(cat "$tmp/gh.log")"; fi

# --- dry run ------------------------------------------------------------------
tick "$tmp/body.md" 7 --box "Lint is clean" --evidence "clean" --dry-run
check "--dry-run exits 0" 0
check "--dry-run prints the ticked line as a diff" 0 "+- [x] Lint is clean"
check "--dry-run prints the evidence line as a diff" 0 "+  - clean"
nothing_written "dry run"

# --- line endings are preserved ----------------------------------------------
printf '## Test plan\n\n- [ ] First box\n- [ ] Last box' > "$tmp/nofinal.md"
tick "$tmp/nofinal.md" 7 --box "Last box" --evidence "done"
check "a description without a final newline is edited" 0
printf '## Test plan\n\n- [ ] First box\n- [x] Last box\n  - done' > "$tmp/want7.md"
written_is "no final newline is added" "$tmp/want7.md"

tick "$tmp/nofinal.md" 7 --box "First box" --evidence "done"
printf '## Test plan\n\n- [x] First box\n  - done\n- [ ] Last box' > "$tmp/want8.md"
written_is "an edit mid-file keeps the missing final newline" "$tmp/want8.md"

printf '## Test plan\r\n\r\n- [ ] First box\r\n- [ ] Last box\r\n\r\nTrailing text.\r\n' > "$tmp/crlf.md"
tick "$tmp/crlf.md" 7 --box "First box" --evidence "done"
check "a CRLF description is edited" 0
printf '## Test plan\r\n\r\n- [x] First box\r\n  - done\r\n- [ ] Last box\r\n\r\nTrailing text.\r\n' > "$tmp/want9.md"
written_is "CRLF endings are kept, and the evidence line uses them too" "$tmp/want9.md"

# --- --file mode never calls gh ----------------------------------------------
cp "$tmp/body.md" "$tmp/local.md"
tick "$tmp/body.md" --file "$tmp/local.md" --box "Lint is clean" --evidence "ruff check: clean at 2026-01-02 03:04 UTC"
check "--file edits a local description" 0
if cmp -s "$tmp/local.md" "$tmp/want1.md"; then ok; else bad "--file rewrites the file in place" "$(cat "$tmp/local.md")"; fi
if [ -s "$tmp/gh.log" ]; then bad "--file must never call gh" "$(cat "$tmp/gh.log")"; else ok; fi

# --- failures and usage -------------------------------------------------------
rm -f "$tmp/written"; : > "$tmp/gh.log"
out=$(GH_STUB_FAIL_VIEW=1 GH_STUB_BODY="$tmp/body.md" GH_STUB_WRITTEN="$tmp/written" GH_STUB_LOG="$tmp/gh.log" \
      TICK_TEST_PLAN_GH="$tmp/gh" python3 "$TICK" 7 --box "Lint is clean" --evidence ok 2>&1); got=$?
check "a failing gh pr view exits 3" 3 "Could not resolve"
nothing_written "failing gh pr view"

tick "$tmp/body.md" 7 --box "Lint is clean" --evidence "line one
line two"
check "multi-line evidence is refused" 3 "one line"
nothing_written "multi-line evidence"

tick "$tmp/body.md" 7 --box "Lint is clean" --evidence "   "
check "blank evidence is refused" 3 "empty"
nothing_written "blank evidence"

tick "$tmp/body.md" 7 --box "Lint is clean"
check "a missing --evidence is a usage error" 3

tick "$tmp/body.md" --box "Lint is clean" --evidence ok
check "neither a PR nor --file is a usage error" 3

tick "$tmp/body.md" 7 --help
check "--help lists the exit statuses" 0 "Exit statuses"

if [ "$fail" -eq 0 ]; then
  printf 'ok: %d tick-test-plan cases passed\n' "$pass"
  exit 0
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
exit 1
