#!/usr/bin/env bash
# test-citations.sh — verdict fixtures for check-citations.py.
#
# The checker's failure mode is the quiet one: a citation it reports as
# verified while it actually compared nothing. `:0` indexing from the end of
# the file, a reversed range that iterates zero times, a one-character anchor
# that matches every line — each of those returns "ok" and each of them checks
# nothing. So this test asserts the VERDICT for one citation per class, not
# just that the script exits 0.
#
# `tests/validate-fixtures/fixture-citations.md` carries one citation per
# class, at the line numbers asserted below. Editing that file means updating
# the expected line numbers here — that coupling is deliberate: it is what
# makes the assertions specific enough to fail.
#
# Usage: tests/validate/test-citations.sh
# Exit:  0 all passed, 1 otherwise.

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CHECKER="$REPO_ROOT/skills/validate/check-citations.py"
FIXTURE="$REPO_ROOT/tests/validate-fixtures/fixture-citations.md"

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

OUT=$(python3 "$CHECKER" "$FIXTURE" --repo-root "$REPO_ROOT" 2>&1)
rc=$?
report "exits 0 (findings are data, not a gate)" 0 "$rc"

STRICT=$(python3 "$CHECKER" "$FIXTURE" --repo-root "$REPO_ROOT" --strict 2>&1)

# --- the tally ------------------------------------------------------------
# Asserted from the fixture rather than hardcoded, so adding a case to the
# fixture cannot leave this number quietly stale.
# `grep -o | wc -l` counts OCCURRENCES; `grep -c` counts matching LINES, which
# undercounts any line carrying two citations and read 6 for a fixture of 8.
want_total=$(grep -oE '`[A-Za-z0-9_./-]+\.[a-z]+:[0-9]+`' "$FIXTURE" | wc -l | tr -d ' ')
got_total=$(printf '%s' "$OUT" | sed -n 's/^<!-- citations: \([0-9]*\) found.*/\1/p')
report "counts every citation in the fixture" "$want_total" "$got_total"

report "one verified, one unverifiable, six broken" \
  "1 verified, 1 unverifiable, 6 broken" \
  "$(printf '%s' "$OUT" | sed -n 's/^<!-- citations: [0-9]* found, \(.*\) -->/\1/p')"

# --- per-class verdicts ---------------------------------------------------
# `finding_at <line>` prints the Reality of the finding anchored at that
# fixture line, or the empty string when the checker reported nothing there.
finding_at() {
  printf '%s' "$2" | awk -v loc="**Location:** fixture-citations.md:$1" '
    $0 == loc { hit = 1; next }
    hit && /^\*\*Reality:\*\* / { sub(/^\*\*Reality:\*\* /, ""); print; exit }
  '
}

report "an anchored citation that matches is NOT a finding" \
  "" "$(finding_at 12 "$STRICT")"

report "a moved anchor reports where it moved TO" \
  'usr/bin/env` is at `skills/polish-pr/wait-for-pr-checks.sh:1`, not at 2.' \
  "$(finding_at 17 "$OUT" | sed 's/^`//')"

report "a line past EOF names the real length" \
  "skills/validate/SKILL.md\` has $(wc -l < "$REPO_ROOT/skills/validate/SKILL.md" | tr -d ' ') lines; the citation names line 99999." \
  "$(finding_at 22 "$OUT" | sed 's/^`//')"

report "a path that does not resolve is a finding" \
  "No file matching \`skills/validate/does-not-exist.md\` exists in the repository." \
  "$(finding_at 27 "$OUT")"

report "an ambiguous bare filename is a finding, not a guess" \
  "yes" \
  "$(case "$(finding_at 31 "$OUT")" in *"is ambiguous"*) echo yes ;; *) echo no ;; esac)"

# The three that would silently "verify" while comparing nothing.
report "a one-character anchor verifies nothing" \
  "yes" \
  "$(case "$(finding_at 37 "$OUT")" in *"verifies nothing"*) echo yes ;; *) echo no ;; esac)"

report "line 0 does not silently read the last line" \
  "Line numbers start at 1." \
  "$(finding_at 41 "$OUT")"

report "an unanchored citation is a finding only under --strict" \
  "|carries no anchor" \
  "$(finding_at 46 "$OUT")|$(case "$(finding_at 46 "$STRICT")" in *"nothing records what"*) echo "carries no anchor" ;; *) echo "MISSING" ;; esac)"

# --- reversed range, checked directly -------------------------------------
# Not in the fixture: a reversed range in a checked-in document would be a
# defect in the document. The empty-iteration bug it guards against is real,
# so it gets its own throwaway input.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '`skills/validate/SKILL.md:40-20` (`validate`)\n' > "$TMP/reversed.md"
report "a reversed range compares nothing, and says so" \
  "yes" \
  "$(case "$(python3 "$CHECKER" "$TMP/reversed.md" --repo-root "$REPO_ROOT")" in
       *"empty or reversed line range"*) echo yes ;; *) echo no ;;
     esac)"

# --- fenced code blocks -----------------------------------------------------
# Two properties, and the second is the one that fails quietly: blanking the
# fence must PRESERVE offsets, or every citation after the first fence is
# reported at the wrong line — a finding that still looks like a finding.
# Kept out of the fixture so the fixture's grep-based total stays honest.
printf 'prose\n\n```\n`skills/validate/SKILL.md:0` (`fenced`)\n```\n\n`skills/validate/SKILL.md:0` (`prose`) sits on line 7.\n' \
  > "$TMP/fenced.md"
FENCED=$(python3 "$CHECKER" "$TMP/fenced.md" --repo-root "$REPO_ROOT")

report "a citation inside a fence is not counted" \
  "1 found" \
  "$(printf '%s' "$FENCED" | sed -n 's/^<!-- citations: \([0-9]* found\).*/\1/p')"

report "blanking the fence preserves line numbers" \
  "fenced.md:7" \
  "$(printf '%s' "$FENCED" | sed -n 's/^\*\*Location:\*\* //p')"

# Same fence indented into a list item — a real shape in these documents, and
# a column-0-anchored pattern reads it as prose.
printf -- '- item:\n\n  ```\n  `skills/validate/SKILL.md:0` (`fenced`)\n  ```\n' \
  > "$TMP/indented.md"
report "an indented fence is a fence" \
  "0 found" \
  "$(python3 "$CHECKER" "$TMP/indented.md" --repo-root "$REPO_ROOT" \
     | sed -n 's/^<!-- citations: \([0-9]* found\).*/\1/p')"

# --- the checker's own docs are not exempt --------------------------------
report "skills/validate/*.md carry no broken citations" \
  "0" \
  "$(for doc in "$REPO_ROOT"/skills/validate/*.md; do
       python3 "$CHECKER" "$doc" --repo-root "$REPO_ROOT" \
         | sed -n 's/^<!-- citations: [0-9]* found, [0-9]* verified, [0-9]* unverifiable, \([0-9]*\) broken -->/\1/p'
     done | awk '{ n += $1 } END { print n + 0 }')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
