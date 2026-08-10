---
type: spec
---

# Citation fixture

Exercises `skills/validate/check-citations.py`. Every citation below is
deliberate; the test asserts the verdict each one should get.

## Verified

The normalizer lives at `skills/polish-pr/resolve-pr-remotes.sh:1`
(`usr/bin/env`) — an anchored citation that resolves and matches.

## Broken: the anchor moved

The watcher's shebang is at `skills/polish-pr/wait-for-pr-checks.sh:2`
(`usr/bin/env`) — off by one, and the checker should say where it really is.

## Broken: past the end of the file

`skills/validate/SKILL.md:99999` (`Preconditions`) names a line the file does
not have.

## Broken: no such file

`skills/validate/does-not-exist.md:3` (`anything`) points at nothing.

## Broken: ambiguous bare filename

`SKILL.md:1` (`name:`) is ambiguous — several skills each ship one, and a bare
filename that resolves in range against the wrong one returns plausible
content.

## Broken: an anchor too short to verify anything

`skills/validate/SKILL.md:1` (`-`) matches almost any line.

## Broken: line zero

`skills/validate/SKILL.md:0` (`name`) — line numbers start at 1, and left
alone `body[0 - 1]` reads the LAST line of the file.

## Unverifiable: no anchor

`skills/validate/SKILL.md:1` carries no anchor, so drift cannot be detected.
It resolves and is in range, so it is not a finding unless `--strict`.
