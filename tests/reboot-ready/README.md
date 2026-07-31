# reboot-ready tests

Automated checks for `skills/reboot-ready/census.sh`. Everything runs in a
`mktemp -d` sandbox — scratch repos are created and destroyed per run, and
`CLAUDE_DIR` is pointed at fixtures so the real `~/.claude` is never read.

Run:

```bash
bash tests/reboot-ready/test-census.sh
```

Exit 0 and `ALL PASS` on success. Covered: JSON validity, probe statuses
(`ran`/`unavailable`), background-job parsing (`state.json` → derived
transcript path), repo + linked-worktree discovery, dirty counts, ahead/
behind orientation (local-unpushed vs. fetched-not-merged, on a clone
against a bare origin), unpushed branches, read-only default (no refs
without `--park`), and the `--park` path: rescue ref created, tracked +
untracked content captured, `git status` byte-identical before/after
(zero-touch), unborn-HEAD repos degrading into `not_parked`, same-basename
checkouts getting collision-proof ref names, a `git status` failure
degrading to `dirty_count: null` (never silently "clean"), a `git worktree
list` discovery failure (unreadable `.git`) degrading into a `not_parked`
entry instead of vanishing, and a hostile checkout path (space + embedded
double quote) round-tripping through JSON unchanged.

The `chmod 000` based tests (unreadable index, unreadable `.git`) skip
themselves when run as root (`EUID -eq 0`), since root reads through those
permissions and the test's premise wouldn't hold.

These files live outside `skills/` so they are not distributed with the
installed plugin (same convention as `tests/validate-fixtures/`).
