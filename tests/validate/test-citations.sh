#!/usr/bin/env bash
# test-citations.sh — verdict fixtures for check-citations.py.
#
# The checker's failure mode is the quiet one: a citation it reports as
# verified while it actually compared nothing. `:0` indexing from the end of
# the file, a reversed range that iterates zero times, an anchor that appears
# on forty lines — each of those returns "ok" and each of them checks nothing.
# So this test asserts the VERDICT for one citation per class, not just that
# the script exits 0.
#
# Assertions are keyed on a citation's own text, not on its line number in
# `tests/validate-fixtures/fixture-citations.md`, so a case can be added to the
# fixture without renumbering every assertion below. Line numbers ARE asserted
# where the line number is the thing under test (fence offset preservation).
#
# Two assertions here were written wrong the first time and are worth naming,
# because both PASSED while testing nothing: one invoked `git` and never the
# checker at all, and one summed an empty stream to the expected `0` whenever
# the checker crashed. Both were caught by mutation testing, not by reading.
#
# Usage: tests/validate/test-citations.sh
# Exit:  0 all passed, 1 otherwise.

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CHECKER="$REPO_ROOT/skills/validate/check-citations.py"
FIXTURE="$REPO_ROOT/tests/validate-fixtures/fixture-citations.md"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

report() {
  local desc=$1 want=$2 got=$3
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$desc" "$want" "$got"
  fi
}

# Passes only if `$3` appears in `$2`. Used where the message is long and only
# its load-bearing clause matters.
contains() {
  local desc=$1 haystack=$2 needle=$3
  case "$haystack" in
    *"$needle"*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1))
       printf 'FAIL: %s\n  expected to contain: %s\n  in: %s\n' "$desc" "$needle" "$haystack" ;;
  esac
}

OUT=$(python3 "$CHECKER" "$FIXTURE" --repo-root "$REPO_ROOT" 2>&1)
rc=$?
report "exits 0 (findings are data, not a gate)" 0 "$rc"

STRICT=$(python3 "$CHECKER" "$FIXTURE" --repo-root "$REPO_ROOT" --strict 2>&1)

# --- the tally ------------------------------------------------------------
# `grep -o | wc -l` counts OCCURRENCES; `grep -c` counts matching LINES, which
# undercounts any line carrying two citations and read 6 for a fixture of 8.
named=$(grep -oE '`[A-Za-z0-9_./-]+\.[a-z]+:[0-9]+`' "$FIXTURE" | wc -l | tr -d ' ')
bare=$(grep -oE '`:[0-9]+`' "$FIXTURE" | wc -l | tr -d ' ')
report "counts every citation in the fixture, named and bare" \
  "$((named + bare))" \
  "$(printf '%s' "$OUT" | sed -n 's/^<!-- citations: \([0-9]*\) found.*/\1/p')"

report "three verified, two unverifiable, eight broken" \
  "3 verified, 2 unverifiable, 8 broken" \
  "$(printf '%s' "$OUT" | sed -n 's/^<!-- citations: [0-9]* found, \(.*\) -->/\1/p')"

# --- per-class verdicts ---------------------------------------------------
# `reality_for <claim-substring> <output>` prints the Reality of the finding
# whose Claim contains that text, or "" when nothing was reported for it.
reality_for() {
  printf '%s' "$2" | awk -v want="$1" '
    index($0, "**Claim:** ") == 1 { hit = index($0, want) > 0; next }
    hit && index($0, "**Reality:** ") == 1 { print substr($0, 14); exit }
  '
}
# Same, for the Suggested correction.
fix_for() {
  printf '%s' "$2" | awk -v want="$1" '
    index($0, "**Claim:** ") == 1 { hit = index($0, want) > 0; next }
    hit && index($0, "**Suggested correction:** ") == 1 { print substr($0, 27); exit }
  '
}

report "an anchored, unique, on-the-line citation is NOT a finding" \
  "" "$(reality_for 'resolve-pr-remotes.sh:1' "$STRICT")"

report "a bare continuation binds to the preceding named file" \
  "" "$(reality_for ':2` (`every check has settled`)' "$STRICT")"

contains "a moved anchor reports where it moved TO" \
  "$(reality_for 'resolve-pr-remotes.sh:2' "$OUT")" \
  'is at `skills/polish-pr/resolve-pr-remotes.sh:1`, not at 2.'

contains "an anchor absent from the file is a finding" \
  "$(reality_for 'zzz_absent_symbol_zzz' "$OUT")" \
  'does not appear anywhere in'

contains "a line past EOF names the real length" \
  "$(reality_for 'SKILL.md:99999' "$OUT")" \
  "has $(wc -l < "$REPO_ROOT/skills/validate/SKILL.md" | tr -d ' ') lines; the citation names line 99999."

report "a path that does not resolve is a finding" \
  "No file matching \`skills/validate/does-not-exist.md\` exists in the repository." \
  "$(reality_for 'does-not-exist.md:3' "$OUT")"

contains "an ambiguous bare filename is a finding, not a guess" \
  "$(reality_for '`SKILL.md:1` (`name:`)' "$OUT")" "is ambiguous"

# `resolve()` matches on a path COMPONENT: `remotes.sh` must not resolve
# against `resolve-pr-remotes.sh`. Stated in a comment; now pinned.
report "a filename that is a suffix of another does not resolve to it" \
  "No file matching \`remotes.sh\` exists in the repository." \
  "$(reality_for 'remotes.sh:1' "$OUT")"

# Uniqueness is MEASURED, not approximated by a length floor: this anchor is
# 14 characters and still identifies nothing, and the finding must name every
# line it is on. Expected line numbers come from grep — an independent oracle
# that does not go stale the next time SKILL.md is edited.
dupe_lines=$(grep -n 'OVERLOAD_TOTAL' "$REPO_ROOT/skills/validate/SKILL.md" \
  | cut -d: -f1 | paste -sd, - | sed 's/,/, /g')
dupe_count=$(grep -c 'OVERLOAD_TOTAL' "$REPO_ROOT/skills/validate/SKILL.md")
contains "a non-unique anchor names how many lines it is on" \
  "$(reality_for 'OVERLOAD_TOTAL' "$OUT")" \
  "appears on $dupe_count lines"
contains "...and lists those line numbers" \
  "$(reality_for 'OVERLOAD_TOTAL' "$OUT")" "($dupe_lines)"

report "line 0 does not silently read the last line" \
  "Line numbers start at 1." \
  "$(reality_for 'SKILL.md:0' "$OUT")"

report "an unanchored citation is a finding only under --strict" \
  "|carries no anchor" \
  "$(reality_for 'SKILL.md:3' "$OUT")|$(case "$(reality_for 'SKILL.md:3' "$STRICT")" in
     *"nothing records what"*) echo "carries no anchor" ;; *) echo "MISSING" ;; esac)"

# An anchor on the NEXT line is not this citation's anchor. Binding across the
# newline would fail correct unanchored citations that happen to be followed
# by a parenthetical — see the `[ \t]*` comment in the checker.
contains "a wrapped anchor is unverifiable, not bound" \
  "$(reality_for 'SKILL.md:33' "$STRICT")" "nothing records what"

# --- the [manual] marker, which decides whether validate EDITS -----------
# validate auto-applies corrections. A correction that is prose must say so,
# or the skill replaces a citation in the user's spec with an English sentence.
report "the anchor-moved correction is a drop-in replacement (no marker)" \
  "\`skills/polish-pr/resolve-pr-remotes.sh:1\` (\`usr/bin/env\`)" \
  "$(fix_for 'resolve-pr-remotes.sh:2' "$OUT")"

for claim in 'does-not-exist.md:3' 'SKILL.md:0' 'SKILL.md:99999' 'OVERLOAD_TOTAL' \
             'zzz_absent_symbol_zzz' '`SKILL.md:1` (`name:`)' 'remotes.sh:1'; do
  case "$(fix_for "$claim" "$OUT")" in
    "[manual] "*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1))
       printf 'FAIL: correction for %s must carry the [manual] marker\n  got: %s\n' \
         "$claim" "$(fix_for "$claim" "$OUT")" ;;
  esac
done

# --- boundaries, pinned from both sides ----------------------------------
# `:len` must verify and `:len+1` must break. Off-by-one in either direction
# survived the earlier suite, because the fixture only used `:99999`.
SK="$REPO_ROOT/skills/validate/SKILL.md"
eof=$(wc -l < "$SK" | tr -d ' ')
printf '`skills/validate/SKILL.md:%s` (`%s`)\n' "$eof" "$(tail -n1 "$SK")" > "$TMP/eof.md"
report "the last line of a file is in range" \
  "0 broken" \
  "$(python3 "$CHECKER" "$TMP/eof.md" --repo-root "$REPO_ROOT" \
     | sed -n 's/.*unverifiable, \([0-9]* broken\) -->/\1/p')"
printf '`skills/validate/SKILL.md:%s` (`zzz_absent_symbol_zzz`)\n' "$((eof + 1))" > "$TMP/past.md"
contains "one line past the last is out of range, and says so" \
  "$(python3 "$CHECKER" "$TMP/past.md" --repo-root "$REPO_ROOT")" \
  "has $eof lines; the citation names line $((eof + 1))."

# --- ranges ---------------------------------------------------------------
printf '`skills/validate/SKILL.md:40-20` (`validate`)\n' > "$TMP/reversed.md"
contains "a reversed range compares nothing, and says so" \
  "$(python3 "$CHECKER" "$TMP/reversed.md" --repo-root "$REPO_ROOT")" \
  "empty or reversed line range"

# The empty-range check must run BEFORE the anchor branch, or an unanchored
# `:58-42` sails through every check that follows.
printf '`skills/validate/SKILL.md:58-42` with no anchor at all.\n' > "$TMP/rev-bare.md"
contains "a reversed range is caught with no anchor present" \
  "$(python3 "$CHECKER" "$TMP/rev-bare.md" --repo-root "$REPO_ROOT")" \
  "empty or reversed line range"

# A reversed part inside a compound list used to be swallowed: `:5,3-1`
# flattened to `[5]`, so the part naming nothing was never reported.
printf '`skills/validate/SKILL.md:5,3-1` with no anchor.\n' > "$TMP/mixed.md"
contains "a reversed part inside a comma list is still caught" \
  "$(python3 "$CHECKER" "$TMP/mixed.md" --repo-root "$REPO_ROOT")" \
  "empty or reversed line range"

# --- the false positive that same-line anchoring exists to prevent ---------
printf 'The three phases are `skills/validate/SKILL.md:1`\n(`alpha`), then beta, then gamma.\n' \
  > "$TMP/parenthetical.md"
report "a following parenthetical is not bound as an anchor" \
  "0 broken" \
  "$(python3 "$CHECKER" "$TMP/parenthetical.md" --repo-root "$REPO_ROOT" \
     | sed -n 's/.*unverifiable, \([0-9]* broken\) -->/\1/p')"

# --- an orphan bare citation is reported, not silently dropped ------------
printf 'Orphan `:12-14` with no named citation before it.\n' > "$TMP/orphan.md"
contains "a bare citation with nothing to bind to is reported" \
  "$(python3 "$CHECKER" "$TMP/orphan.md" --repo-root "$REPO_ROOT")" \
  "no citation naming a file comes before it"

# --- resolution comes from git, asserted THROUGH the checker --------------
# The previous version of this test ran `git ls-files | grep -c` and never
# invoked the checker: it passed with `tracked()` replaced by a filesystem
# walk — the exact regression it was captioned to prevent. A real test needs
# an ignored decoy that a walk would trip over, and must ask the CHECKER.
SCRATCH="$TMP/scratch"
mkdir -p "$SCRATCH/real" "$SCRATCH/.venv/lib" "$SCRATCH/pkg"
git -C "$SCRATCH" init -q
printf 'target line one\n' > "$SCRATCH/real/thing.py"
printf 'decoy line one\n'  > "$SCRATCH/.venv/lib/thing.py"   # ignored shadow
printf 'suffix trap\n'     > "$SCRATCH/pkg/mything.py"       # `thing.py` must not match
printf '.venv/\n'          > "$SCRATCH/.gitignore"
git -C "$SCRATCH" add -A >/dev/null 2>&1
git -C "$SCRATCH" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1

printf '`thing.py:1` (`target line one`)\n' > "$SCRATCH/doc.md"
SCRATCH_OUT=$(python3 "$CHECKER" "$SCRATCH/doc.md" --repo-root "$SCRATCH")
report "an ignored shadow file is not a resolution candidate" \
  "1 verified" \
  "$(printf '%s' "$SCRATCH_OUT" | sed -n 's/.*found, \([0-9]* verified\).*/\1/p')"
contains "...and the ignored copy is never reported as ambiguous" \
  "$SCRATCH_OUT" "0 broken"

# A file that is new and NOT ignored must resolve, so a spec can cite
# something added in the same change.
printf 'fresh line\n' > "$SCRATCH/real/fresh.py"
printf '`fresh.py:1` (`fresh line`)\n' > "$SCRATCH/doc2.md"
report "an untracked but unignored file resolves" \
  "1 verified" \
  "$(python3 "$CHECKER" "$SCRATCH/doc2.md" --repo-root "$SCRATCH" \
     | sed -n 's/.*found, \([0-9]* verified\).*/\1/p')"

# `./` is root-anchored, so it disambiguates rather than merely stripping.
printf 'root\n' > "$SCRATCH/thing.py"
git -C "$SCRATCH" add -A >/dev/null 2>&1
printf '`./thing.py:1` (`root`)\n' > "$SCRATCH/doc3.md"
report "a ./-prefixed path anchors to the repo root" \
  "1 verified" \
  "$(python3 "$CHECKER" "$SCRATCH/doc3.md" --repo-root "$SCRATCH" \
     | sed -n 's/.*found, \([0-9]* verified\).*/\1/p')"
printf '`thing.py:1` (`root`)\n' > "$SCRATCH/doc4.md"
contains "...while the same path unanchored is ambiguous" \
  "$(python3 "$CHECKER" "$SCRATCH/doc4.md" --repo-root "$SCRATCH")" "is ambiguous"

# A tracked file removed from the worktree must not abort the whole run.
# Its own fully-qualified citation, so the assertion cannot be perturbed by
# files the earlier cases added to this scratch repo.
printf 'doomed\n' > "$SCRATCH/pkg/doomed.py"
git -C "$SCRATCH" add -A >/dev/null 2>&1
git -C "$SCRATCH" -c user.email=t@t -c user.name=t commit -qm doomed >/dev/null 2>&1
rm "$SCRATCH/pkg/doomed.py"
printf '`pkg/doomed.py:1` (`doomed`)\n' > "$SCRATCH/doc5.md"
contains "a tracked-but-missing file is a finding, not a traceback" \
  "$(python3 "$CHECKER" "$SCRATCH/doc5.md" --repo-root "$SCRATCH" 2>&1)" \
  "cannot be read"

# `/`-boundary, tested where the basename index cannot mask it. The fixture's
# `remotes.sh` case exercises the index (no such basename); this exercises the
# guard, with a basename that DOES exist under a different parent.
printf '`eal/thing.py:1` (`root`)\n' > "$SCRATCH/doc6.md"
report "a partial directory component does not match" \
  "No file matching \`eal/thing.py\` exists in the repository." \
  "$(python3 "$CHECKER" "$SCRATCH/doc6.md" --repo-root "$SCRATCH" \
     | sed -n 's/^\*\*Reality:\*\* //p')"

# An anchor that is only whitespace asserts nothing about the line.
printf '`pkg/mything.py:1` (` `)\n' > "$SCRATCH/doc7.md"
contains "a whitespace-only anchor is rejected" \
  "$(python3 "$CHECKER" "$SCRATCH/doc7.md" --repo-root "$SCRATCH")" \
  "asserts nothing about the line"

# Anchors compare with runs of whitespace collapsed, so re-indenting or
# re-spacing the target is not drift.
printf 'def  foo(a,   b):\n' > "$SCRATCH/pkg/spacing.py"
printf '`pkg/spacing.py:1` (`def foo(a, b):`)\n' > "$SCRATCH/doc8.md"
report "whitespace differences in the target are not drift" \
  "1 verified" \
  "$(python3 "$CHECKER" "$SCRATCH/doc8.md" --repo-root "$SCRATCH" \
     | sed -n 's/.*found, \([0-9]* verified\).*/\1/p')"

# A range is INCLUSIVE of its high end: an anchor on the last cited line
# verifies. Excluding it would silently report "moved" for a correct citation.
printf 'one\ntwo\nthree\n' > "$SCRATCH/pkg/three.py"
printf '`pkg/three.py:1-3` (`three`)\n' > "$SCRATCH/doc9.md"
report "a range includes its high end" \
  "1 verified" \
  "$(python3 "$CHECKER" "$SCRATCH/doc9.md" --repo-root "$SCRATCH" \
     | sed -n 's/.*found, \([0-9]* verified\).*/\1/p')"

# A submodule is ONE gitlink entry to `ls-files`, so without the
# `--recurse-submodules` pass every citation into it is confidently denied.
SUB="$TMP/submod"
mkdir -p "$SUB"
git -C "$SUB" init -q
printf 'sub line one\n' > "$SUB/inner.py"
git -C "$SUB" add -A >/dev/null 2>&1
git -C "$SUB" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
if git -C "$SCRATCH" -c protocol.file.allow=always submodule add -q "$SUB" vendor >/dev/null 2>&1; then
  printf '`vendor/inner.py:1` (`sub line one`)\n' > "$SCRATCH/doc10.md"
  report "a citation into a submodule resolves" \
    "1 verified" \
    "$(python3 "$CHECKER" "$SCRATCH/doc10.md" --repo-root "$SCRATCH" \
       | sed -n 's/.*found, \([0-9]* verified\).*/\1/p')"
else
  printf 'SKIP: submodule case (git refused file:// submodule add)\n'
fi

# --- fenced code blocks -----------------------------------------------------
# Two properties, and the second is the one that fails quietly: blanking the
# fence must PRESERVE offsets, or every citation after the first fence is
# reported at the wrong line — a finding that still looks like a finding.
printf 'prose\n\n```\n`skills/validate/SKILL.md:0` (`fenced`)\n```\n\n`skills/validate/SKILL.md:0` (`prose`) sits on line 7.\n' \
  > "$TMP/fenced.md"
FENCED=$(python3 "$CHECKER" "$TMP/fenced.md" --repo-root "$REPO_ROOT")

report "a citation inside a fence is not counted" \
  "1 found" \
  "$(printf '%s' "$FENCED" | sed -n 's/^<!-- citations: \([0-9]* found\).*/\1/p')"

report "blanking the fence preserves line numbers" \
  "fenced.md:7" \
  "$(printf '%s' "$FENCED" | sed -n 's/^\*\*Location:\*\* //p')"

printf -- '- item:\n\n  ```\n  `skills/validate/SKILL.md:0` (`fenced`)\n  ```\n' \
  > "$TMP/indented.md"
report "an indented fence is a fence" \
  "0 found" \
  "$(python3 "$CHECKER" "$TMP/indented.md" --repo-root "$REPO_ROOT" \
     | sed -n 's/^<!-- citations: \([0-9]* found\).*/\1/p')"

# Per CommonMark an unclosed fence runs to end of document.
printf 'prose\n\n```\n`skills/validate/SKILL.md:0` (`fenced`)\n' > "$TMP/unterm.md"
report "an unterminated fence runs to end of document" \
  "0 found" \
  "$(python3 "$CHECKER" "$TMP/unterm.md" --repo-root "$REPO_ROOT" \
     | sed -n 's/^<!-- citations: \([0-9]* found\).*/\1/p')"

# --- the Claim field must be the document's own bytes ---------------------
# validate searches the spec for the Claim text before editing; text that does
# not match byte-for-byte is classed as a hallucinated quote, which BLOCKS.
printf 'Spaced `skills/validate/SKILL.md:0`  (`Tuning`) here.\n' > "$TMP/spaced.md"
claim=$(python3 "$CHECKER" "$TMP/spaced.md" --repo-root "$REPO_ROOT" \
  | sed -n 's/^\*\*Claim:\*\* //p')
report "the emitted Claim appears verbatim in the document" \
  "1" \
  "$(grep -cF -- "$claim" "$TMP/spaced.md")"

# --- the checker's own docs are not exempt --------------------------------
# Counts the per-document tally lines as well as summing them: a crashing
# checker prints nothing, `sed` matches nothing, and `awk` would sum an empty
# stream to the expected 0 — passing while testing nothing.
docs=$(find "$REPO_ROOT/skills/validate" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
tallies=$(for doc in "$REPO_ROOT"/skills/validate/*.md; do
  python3 "$CHECKER" "$doc" --repo-root "$REPO_ROOT" \
    | sed -n 's/^<!-- citations: [0-9]* found, [0-9]* verified, [0-9]* unverifiable, \([0-9]*\) broken -->/\1/p'
done)
report "every skills/validate/*.md produced a tally (no silent crash)" \
  "$docs" "$(printf '%s\n' "$tallies" | grep -c '^[0-9][0-9]*$')"
report "skills/validate/*.md carry no broken citations" \
  "0" "$(printf '%s\n' "$tallies" | awk '{ n += $1 } END { print n + 0 }')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
