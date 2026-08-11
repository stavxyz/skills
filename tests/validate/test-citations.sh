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
#
# This oracle counts single line numbers only, and counts citations inside
# fenced blocks that the checker skips. So the fixture must contain no fenced
# citation and no range (`:12-14`) — those shapes are exercised by throwaway
# documents further down instead. Adding either here breaks this assertion for
# a reason that is not obvious from the failure.
named=$(grep -oE '`[A-Za-z0-9_./-]+\.[a-z]+:[0-9]+`' "$FIXTURE" | wc -l | tr -d ' ')
bare=$(grep -oE '`:[0-9]+`' "$FIXTURE" | wc -l | tr -d ' ')
report "counts every citation in the fixture, named and bare" \
  "$((named + bare))" \
  "$(printf '%s' "$OUT" | sed -n 's/^<!-- citations: \([0-9]*\) found.*/\1/p')"

report "three verified, four unverifiable, six broken" \
  "3 verified, 4 unverifiable, 6 broken" \
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
# The `### <Severity>:` heading of the finding whose Claim contains $1.
severity_for() {
  printf '%s' "$2" | awk -v want="$1" '
    index($0, "### ") == 1 { head = $0; next }
    index($0, "**Claim:** ") == 1 && index($0, want) > 0 {
      sub(/^### /, "", head); sub(/:.*/, "", head); print head; exit
    }
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
  "$(reality_for '`skills/validate/SKILL.md:3`' "$OUT")|$(case "$(reality_for '`skills/validate/SKILL.md:3`' "$STRICT")" in
     *"nothing records what"*) echo "carries no anchor" ;; *) echo "MISSING" ;; esac)"

# An anchor on the NEXT line is not this citation's anchor. Binding across the
# newline would fail correct unanchored citations that happen to be followed
# by a parenthetical — see the `[ \t]*` comment in the checker.
contains "a wrapped anchor is unverifiable, not bound" \
  "$(reality_for '`skills/validate/SKILL.md:33`' "$STRICT")" "nothing records what"

# --- the [manual] marker, which decides whether validate EDITS -----------
# validate auto-applies corrections. A correction that is prose must say so,
# or the skill replaces a citation in the user's spec with an English sentence.
report "the anchor-moved correction is a drop-in replacement (no marker)" \
  "\`skills/polish-pr/resolve-pr-remotes.sh:1\` (\`usr/bin/env\`)" \
  "$(fix_for 'resolve-pr-remotes.sh:2' "$OUT")"

wants_marker() {  # $1 desc, $2 correction text
  case "$2" in
    "[manual] "*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1))
       printf 'FAIL: correction for %s must carry the [manual] marker\n  got: %s\n' "$1" "$2" ;;
  esac
}

for claim in 'does-not-exist.md:3' 'SKILL.md:0' 'SKILL.md:99999' 'OVERLOAD_TOTAL' \
             'zzz_absent_symbol_zzz' '`SKILL.md:1` (`name:`)' 'remotes.sh:1'; do
  wants_marker "$claim" "$(fix_for "$claim" "$OUT")"
done

# The --strict correction is a TEMPLATE containing the literal token `SYMBOL`.
# Applied verbatim it writes that token into the spec, and the citation then
# fails on the next run for an anchor the author never chose — the checker
# manufacturing the drift it exists to detect. It needs the marker most of all,
# and the loop above never looked at --strict output.
wants_marker "the --strict unanchored template" "$(fix_for '`skills/validate/SKILL.md:3`' "$STRICT")"
contains "...and it warns that it is a placeholder" \
  "$(fix_for '`skills/validate/SKILL.md:3`' "$STRICT")" "would write the placeholder"

# --- severity is the gate ---------------------------------------------------
# `Important` = the checker PROVED the citation wrong. `Low` = it could not
# determine. Only Important becomes a clean-bless caveat, because on one real
# repository 55 of 57 findings were could-not-determine, and gating on those
# meant no document ever blessed clean.
report "a proved-wrong citation is Important" \
  "Important" "$(severity_for 'SKILL.md:99999' "$OUT")"
report "an absent anchor is proved wrong, so Important" \
  "Important" "$(severity_for 'zzz_absent_symbol_zzz' "$OUT")"
report "an ambiguous path is could-not-determine, so Low" \
  "Low" "$(severity_for '`SKILL.md:1` (`name:`)' "$OUT")"
report "a non-unique anchor is could-not-determine, so Low" \
  "Low" "$(severity_for 'OVERLOAD_TOTAL' "$OUT")"

# --strict is where "every citation must resolve" is enforced: it promotes
# every could-not-determine finding to Important, so they all gate.
report "--strict promotes an ambiguous path to Important" \
  "Important" "$(severity_for '`SKILL.md:1` (`name:`)' "$STRICT")"
report "--strict promotes a non-unique anchor to Important" \
  "Important" "$(severity_for 'OVERLOAD_TOTAL' "$STRICT")"
report "--strict leaves a proved-wrong citation Important" \
  "Important" "$(severity_for 'SKILL.md:99999' "$STRICT")"
report "--strict emits no Low findings at all" \
  "0" "$(printf '%s' "$STRICT" | grep -c '^### Low:')"

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
REV=$(python3 "$CHECKER" "$TMP/reversed.md" --repo-root "$REPO_ROOT")
contains "a reversed range compares nothing, and says so" \
  "$REV" "empty or reversed line range"
wants_marker "the reversed-range correction" "$(fix_for 'SKILL.md:40-20' "$REV")"

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
ORPHAN=$(python3 "$CHECKER" "$TMP/orphan.md" --repo-root "$REPO_ROOT")
contains "a bare citation with nothing to bind to is reported" \
  "$ORPHAN" "no citation naming a file comes before it"
wants_marker "the orphan-continuation correction" "$(fix_for ':12-14' "$ORPHAN")"

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
AMBIG=$(python3 "$CHECKER" "$SCRATCH/doc4.md" --repo-root "$SCRATCH")
contains "...while the same path unanchored is ambiguous" "$AMBIG" "is ambiguous"
# The suggestion must not echo the citation it just rejected: with a root-level
# `thing.py` present, advising "e.g. `thing.py:1`" for `thing.py:1` is no advice.
# `alpha.py` sorts BEFORE `zz/alpha.py`, so a naive `candidates[0]` suggests
# the very path it just rejected — "Qualify the path, e.g. `alpha.py:1`".
mkdir -p "$SCRATCH/zz"
printf 'a\n' > "$SCRATCH/alpha.py"
printf 'a\n' > "$SCRATCH/zz/alpha.py"
git -C "$SCRATCH" add -A >/dev/null 2>&1
printf '`alpha.py:1` (`a`)\n' > "$SCRATCH/doc15.md"
report "the ambiguity suggestion never echoes the rejected path" \
  "[manual] Qualify the path, e.g. \`zz/alpha.py:1\`" \
  "$(fix_for 'alpha.py:1' "$(python3 "$CHECKER" "$SCRATCH/doc15.md" --repo-root "$SCRATCH")")"

# A tracked file removed from the worktree must not abort the whole run.
# Its own fully-qualified citation, so the assertion cannot be perturbed by
# files the earlier cases added to this scratch repo.
printf 'doomed\n' > "$SCRATCH/pkg/doomed.py"
git -C "$SCRATCH" add -A >/dev/null 2>&1
git -C "$SCRATCH" -c user.email=t@t -c user.name=t commit -qm doomed >/dev/null 2>&1
rm "$SCRATCH/pkg/doomed.py"
printf '`pkg/doomed.py:1` (`doomed`)\n' > "$SCRATCH/doc5.md"
MISSING=$(python3 "$CHECKER" "$SCRATCH/doc5.md" --repo-root "$SCRATCH" 2>&1)
contains "a tracked-but-missing file is a finding, not a traceback" \
  "$MISSING" "cannot be read"
wants_marker "the unreadable-file correction" "$(fix_for 'pkg/doomed.py:1' "$MISSING")"

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
BLANKANCHOR=$(python3 "$CHECKER" "$SCRATCH/doc7.md" --repo-root "$SCRATCH")
contains "a whitespace-only anchor is rejected" \
  "$BLANKANCHOR" "asserts nothing about the line"
wants_marker "the empty-anchor correction" "$(fix_for 'pkg/mything.py:1' "$BLANKANCHOR")"

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
  git -C "$SCRATCH" submodule deinit -f vendor >/dev/null 2>&1
  DEINIT=$(python3 "$CHECKER" "$SCRATCH/doc10.md" --repo-root "$SCRATCH")
  contains "an uninitialised submodule is not denied as a missing file" \
    "$DEINIT" "submodule with no contents checked out"
  wants_marker "the uninitialised-submodule correction" \
    "$(fix_for 'vendor/inner.py:1' "$DEINIT")"
  report "...and it is reported without --strict" \
    "1 unverifiable" \
    "$(printf '%s' "$DEINIT" | sed -n 's/.*verified, \([0-9]* unverifiable\).*/\1/p')"
  git -C "$SCRATCH" -c protocol.file.allow=always submodule update --init vendor >/dev/null 2>&1
else
  printf 'SKIP: submodule case (git refused file:// submodule add)\n'
fi

# Absolute paths normalise to repo-relative. Also through a SYMLINK to the
# repo, since `--repo-root` is resolved and the cited path was not — on macOS
# `/tmp` is a symlink to `/private/tmp`, so this is the common case, not exotic.
printf '`%s/pkg/three.py:1` (`one`)\n' "$SCRATCH" > "$SCRATCH/doc11.md"
report "an absolute path inside the repo resolves" \
  "1 verified" \
  "$(python3 "$CHECKER" "$SCRATCH/doc11.md" --repo-root "$SCRATCH" \
     | sed -n 's/.*found, \([0-9]* verified\).*/\1/p')"
# `thing.py` exists at the root AND at `real/thing.py`, so an absolute path to
# the root one is only unambiguous if it is treated as root-ANCHORED, not
# merely stripped to a basename.
printf 'root\n' > "$SCRATCH/real/thing.py"
git -C "$SCRATCH" add -A >/dev/null 2>&1
printf '`%s/thing.py:1` (`root`)\n' "$SCRATCH" > "$SCRATCH/doc14.md"
report "an absolute path is root-anchored, not just stripped" \
  "1 verified" \
  "$(python3 "$CHECKER" "$SCRATCH/doc14.md" --repo-root "$SCRATCH" \
     | sed -n 's/.*found, \([0-9]* verified\).*/\1/p')"

ln -s "$SCRATCH" "$TMP/alias"
printf '`%s/pkg/three.py:1` (`one`)\n' "$TMP/alias" > "$SCRATCH/doc12.md"
report "an absolute path through a symlinked root still resolves" \
  "1 verified" \
  "$(python3 "$CHECKER" "$SCRATCH/doc12.md" --repo-root "$SCRATCH" \
     | sed -n 's/.*found, \([0-9]* verified\).*/\1/p')"

# The candidate list is truncated at four, and must say when it truncated:
# "3 files match: a, b, c, d" reads as complete when it is not.
mkdir -p "$SCRATCH"/d1 "$SCRATCH"/d2 "$SCRATCH"/d3 "$SCRATCH"/d4 "$SCRATCH"/d5
for i in 1 2 3 4 5; do printf 'x\n' > "$SCRATCH/d$i/many.py"; done
printf '`many.py:1` (`x`)\n' > "$SCRATCH/doc13.md"
contains "a truncated candidate list says how many it omitted" \
  "$(python3 "$CHECKER" "$SCRATCH/doc13.md" --repo-root "$SCRATCH")" \
  "and 1 more"

# A repo git cannot read is a RUN failure (exit 2, stderr), not a document
# full of "no such file" findings.
notrepo="$TMP/notrepo"; mkdir -p "$notrepo"
err=$(python3 "$CHECKER" "$FIXTURE" --repo-root "$notrepo" 2>&1 >/dev/null); rc2=$?
report "a non-repo --repo-root is a run failure, not findings" \
  "2|git ls-files failed" \
  "$rc2|$(printf '%s' "$err" | sed -n 's/.*\(git ls-files failed\).*/\1/p')"

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
report "the emitted Claim is the document's own bytes, two spaces and all" \
  '`skills/validate/SKILL.md:0`  (`Tuning`)' \
  "$claim"

# --- the location key, which SKILL.md's dedupe depends on -------------------
# SKILL.md compares findings from three sources by a key EXTRACTED from each
# `Location`. That rule is prose an LLM executes, so it has no harness — but
# both halves of it are checkable here: that the checker emits a location the
# rule can extract from, and that the rule as specified actually collapses the
# real shapes the other two sources emit.
#
# The predecessor rule ("reduce any leading path to its basename") passed review
# three times and could not match ANY real reviewer output, because the noise is
# on both ends. These strings are verbatim from the run that caught it.
# F10: `key()` is a faithful transcription of the documented rule, INCLUDING
# its fallback ("the key is the whole string, trimmed"). An earlier version
# echoed nothing on no-match, which silently made every section-only location
# equal to every other — universal false-matching, the exact opposite of the
# property the assertion below claims.
SPEC_BASE="fixture-citations.md"
key() {  # the <file>:<line> pair naming the DOCUMENT, else the whole string
  local hit
  # The character class excludes `/`, so a match is already `basename:line` —
  # the rule's "reduced to basename:line" needs no separate step here. Said
  # explicitly because a redundant `${hit##*/}` looked like coverage and was a
  # no-op: mutating it away changed nothing.
  hit=$(printf '%s' "$1" | grep -oE '[A-Za-z0-9_.-]+:[0-9]+' \
        | grep -E "^${SPEC_BASE//./\\.}:[0-9]+$" | tail -1)
  if [ -n "$hit" ]; then printf '%s' "$hit"; else printf '%s' "$1"; fi
}

# F11: assert extractability THROUGH the helper. The previous glob accepted
# `Makefile:12`, from which the helper extracts nothing.
loc=$(printf '%s' "$OUT" | sed -n 's/^\*\*Location:\*\* //p' | head -1)
report "the checker emits a Location the key can be extracted from" \
  "$loc" "$(key "$loc")"

# F8: comparing two key() outputs for equality passed when BOTH were empty —
# `[ "" = "" ]`. A dead regex satisfied it. Assert each side against the
# literal instead, which is the fourth instance of this anti-pattern in this
# PR series and the first one introduced by the change that documents it.
report "the checker spelling keys to basename:line" \
  "$SPEC_BASE:17" "$(key "$SPEC_BASE:17")"
report "the fact-check spelling keys to the same thing" \
  "$SPEC_BASE:17" "$(key "\`docs/superpowers/specs/$SPEC_BASE:17\` (Components)")"
report "...and is not fooled by a path component that looks like the file" \
  "$SPEC_BASE:17" "$(key "\`docs/$SPEC_BASE.bak/$SPEC_BASE:17\` (Components)")"

# F1/F9: the rule keys to the pair naming the DOCUMENT, never to a source file
# the finding also cites. Taking the last pair instead — the obvious reading —
# keys a design finding to `driver.py:42`, which leaves dedupe dead for the
# SOLID reviewer and collapses findings its own template forbids collapsing.
# Nothing exercised this before; `head -1` vs `tail -1` survived the suite.
report "a trailing source-file citation does not capture the key" \
  "$SPEC_BASE:17" "$(key "$SPEC_BASE:17 (see src/app/driver.py:42)")"
report "a section location that cites a source file keys to the whole string" \
  '"Components" (src/app/driver.py:42)' \
  "$(key '"Components" (src/app/driver.py:42)')"

report "a section-only location keys to itself, matching only an identical one" \
  '"Components" (lines 17-22)' \
  "$(key '"Components" (lines 17-22)')"

# --- pin the suite to the artifact, not to its own restatement -------------
# `key()` above is a bash reimplementation of a prose rule an LLM executes.
# Testing it proves the semantics are well-defined; it proves NOTHING about
# what ships, and mutation showed exactly that: reverting SKILL.md's rule to
# the broken prefix-strip it replaced — or deleting the rule block outright —
# left this suite green. These assertions couple the two, so a prose edit that
# diverges from `key()` fails here instead of silently shipping.
RULE=$(cat "$REPO_ROOT/skills/validate/SKILL.md")

contains "SKILL.md keys on the DOCUMENT, not on position in the string" \
  "$RULE" "basename equals the basename of"
contains "SKILL.md still specifies the whole-string fallback key() implements" \
  "$RULE" "the key is the whole string, trimmed"
contains "SKILL.md still explains why the last pair is the wrong key" \
  "$RULE" "Keying on the last pair would key a design finding"

# The rule this replaced, in its own words. If it comes back, the bug is back.
case "$RULE" in
  *"reducing any leading path to its basename"*)
    fail=$((fail + 1))
    printf 'FAIL: SKILL.md has reverted to the prefix-strip rule that could never match\n' ;;
  *) pass=$((pass + 1)) ;;
esac

# The supersession test must stay decisive. A location-key proxy classified an
# invented quote as superseded whenever anything else touched the same line,
# and superseded neither blocks nor caveats the bless.
contains "SKILL.md gates on severity, not on the [manual] marker alone" \
  "$RULE" "Low\`-severity \`[manual]\` findings do NOT gate"
contains "SKILL.md still explains why could-not-determine does not gate" \
  "$RULE" "55 of 57 findings were that class"

contains "supersession is decided from the pre-edit bytes, not a location key" \
  "$RULE" "present in the pre-edit content, absent now"

# The `[manual]` guard must run BEFORE claim verification, or a marked finding
# whose text was overtaken is reclassified superseded and slips past the
# MANUAL_FINDINGS clean-bless caveat.
# Compare the STEP NUMBERS, not the byte positions: an LLM executes the list by
# its numbering, so renumbering alone reorders it. A position-only check passed
# with the guard renumbered to step 9.
guard=$(printf '%s' "$RULE" | sed -n 's/^\([0-9]*\)\. \*\*Skip first, if the correction is marked.*/\1/p')
verify=$(printf '%s' "$RULE" | sed -n 's/^\([0-9]*\)\. \*\*Verify claim-text-in-spec.*/\1/p')
report "the [manual] guard is numbered before claim verification" \
  "yes" \
  "$([ -n "$guard" ] && [ -n "$verify" ] && [ "$guard" -lt "$verify" ] && echo yes || echo no)"

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

# A conditional case (the submodule one) means "0 failed" could otherwise hide
# a silently smaller run. Counted outside `report` so this check cannot count
# itself; bump it deliberately when you add an assertion.
EXPECTED_ASSERTIONS=87
ran=$((pass + fail))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  fail=$((fail + 1))
  printf 'FAIL: expected %d assertions, %d ran — a conditional block was skipped,\n' \
    "$EXPECTED_ASSERTIONS" "$ran"
  printf '      or a new assertion was added without updating EXPECTED_ASSERTIONS.\n'
fi

printf '\n%d passed, %d failed (%d assertions)\n' "$pass" "$fail" "$ran"
[ "$fail" -eq 0 ]
