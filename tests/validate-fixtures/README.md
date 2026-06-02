# validate fixtures

Sample spec documents for exercising the `/validate` skill by hand. They live
here, outside `skills/`, so they are **not** distributed as part of the
installed plugin — they are development/test inputs only.

Each fixture is a minimal `type: spec` markdown file that drives a different
`/validate` code path:

| Fixture | Exercises |
| --- | --- |
| `fixture-clean.md` | A spec whose claims match the codebase — expect a clean bless with no findings. |
| `fixture-drift.md` | A spec containing stale/incorrect claims — expect fact-check findings. |
| `fixture-net-negative.md` | A spec whose design direction is net-negative — expect a SOLID/hygiene `net-negative` gate. |

To use one, point the validate skill at a copy inside a git repo (`/stavxyz:validate`
for a plugin install, or bare `/validate` for a user-skill install):

```text
/stavxyz:validate tests/validate-fixtures/fixture-drift.md
```
