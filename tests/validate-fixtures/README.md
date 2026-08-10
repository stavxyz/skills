# validate fixtures

Sample spec documents for exercising the `/validate` skill by hand. They live
here, outside `skills/`, so they are **not** distributed as part of the
installed plugin — they are development/test inputs only.

Each fixture is a minimal `type: spec` markdown file that drives a different
`/validate` code path:

| Fixture | Exercises |
| --- | --- |
| `fixture-clean.md` | A spec whose claims match the codebase — expect a clean bless with no findings. Because the bless is caveat-free, validate will then **auto-continue into `superpowers:writing-plans`** (the fixture is `type: spec`); stop there if you only meant to exercise validation. |
| `fixture-drift.md` | A spec containing stale/incorrect claims — expect fact-check findings. |
| `fixture-net-negative.md` | A spec whose design direction is net-negative — expect a SOLID/hygiene `net-negative` gate. |
| `fixture-citations.md` | One citation per verdict of `skills/validate/check-citations.py` — verified, anchor-moved, past-EOF, no-such-file, ambiguous bare filename, non-unique anchor, line-zero, unanchored, and an anchor that wrapped onto the next line (which is `unverifiable`, not bound). Unlike the others it is not run through `/validate` by hand: `tests/validate/test-citations.sh` asserts the verdict for each one, so the expected results are executable rather than described. Editing this file means updating the line numbers that test asserts. |
| `fixture-unverified-platform.md` | A spec whose design rests on a load-bearing claim about an external platform (launchd's missed-job semantics). Expect the fact-check reviewer to verify it against a primary source (docs fetch or probe) — yielding Critical if the source contradicts it, or Important with an `UNVERIFIED:` annotation as the correction if no primary source settles it. The in-repo claim (`tests/validate-fixtures/` exists) should verify clean. Added with issue #15 (the reboot-ready incident: an unverified platform inference passed two validations and shipped). |

To use one, point the validate skill at a copy inside a git repo (`/stavxyz:validate`
for a plugin install, or bare `/validate` for a user-skill install):

```text
/stavxyz:validate tests/validate-fixtures/fixture-drift.md
```
