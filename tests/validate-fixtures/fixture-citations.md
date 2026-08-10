---
type: spec
---

# Citation fixture

Exercises `skills/validate/check-citations.py`. Every citation below is
deliberate; `tests/validate/test-citations.sh` asserts the verdict each one
should get, keyed on the citation's own text rather than on its line number —
so cases can be added here without renumbering every assertion.

## Verified

The remote normalizer's shebang is at
`skills/polish-pr/resolve-pr-remotes.sh:1` (`usr/bin/env`) — an anchored
citation that resolves, is unique in the file, and sits on the cited line.

## Verified: a bare continuation binds to the preceding named file

The watcher's shebang is at `skills/polish-pr/wait-for-pr-checks.sh:1` (`usr/bin/env`),
and `:2` (`every check has settled`) continues it — a bare `:NN` refers to the
nearest citation naming a file BEFORE it, which is a real form in these
documents and one a naive sweep drops entirely.

## Broken: the anchor moved

Off by one, and the checker should say where it really is:
`skills/polish-pr/resolve-pr-remotes.sh:2` (`usr/bin/env`).

## Broken: the anchor is not in the file at all

`skills/validate/SKILL.md:1` (`zzz_absent_symbol_zzz`) resolves and is in
range, but names something the file does not contain — the ordinary shape of a
renamed or deleted symbol, and the most common real drift.

## Broken: past the end of the file

`skills/validate/SKILL.md:99999` (`## Preconditions`) names a line the file
does not have.

## Broken: no such file

`skills/validate/does-not-exist.md:3` (`anything`) points at nothing.

## Broken: ambiguous bare filename

`SKILL.md:1` (`name:`) is ambiguous — several skills each ship one, and a bare
filename that resolves in range against the wrong one returns plausible
content.

## Broken: a filename that is a suffix of another file

`remotes.sh:1` (`usr/bin/env`) must NOT resolve against
`skills/polish-pr/resolve-pr-remotes.sh`. Matching on a bare suffix rather
than a path component would follow the wrong file confidently.

## Broken: an anchor that is not unique

`skills/validate/SKILL.md:28` (`OVERLOAD_TOTAL`) sits on the cited line, but
the same text is on another line too, so it cannot tell the cited line from
that one. If the constant moves, the other occurrence lands here and the
citation still passes.

## Broken: line zero

`skills/validate/SKILL.md:0` (`Tuning`) — line numbers start at 1, and left
alone `body[0 - 1]` reads the LAST line of the file.

## Unverifiable: no anchor

`skills/validate/SKILL.md:3` carries no anchor, so drift cannot be detected.
It resolves and is in range, so it is not a finding unless `--strict`.

## Unverifiable: an anchor that wrapped is not an anchor

The three phases are `skills/validate/SKILL.md:33`
(`## Preconditions`), then beta, then gamma.

An anchor must sit on the citation's own line. Binding across the newline
would catch the genuinely-reflowed case, but it would equally bind an ordinary
parenthetical that merely follows an unanchored citation — failing a correct
citation for text it never opted into. This citation is therefore
`unverifiable`, not `ok` and not a finding, even though the wrapped text
happens to name line 33 correctly.
