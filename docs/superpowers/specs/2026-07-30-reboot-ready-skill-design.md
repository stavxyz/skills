# /reboot-ready skill — design

**Date:** 2026-07-30
**Status:** Approved (brainstormed with Claude; approach B of three)

## Problem

Rebooting the machine kills every running Claude Code session: background
jobs, interactive tabs, and the desktop app. Conversation transcripts and
files on disk survive, but in-flight work stops silently, and there is no
single place to see what was running, what state each worktree was in, or
what to resume afterward. Before a reboot (or OS update), the user wants a
one-command sweep that inventories everything at risk, parks dirty state
safely, and leaves behind a checklist for picking work back up.

## Shape

A skill in this repo: `skills/reboot-ready/` containing:

- `SKILL.md` — the model-facing instructions (judgment layer)
- `census.sh` — a deterministic sweep script (mechanical layer)

**Triggers:** `/reboot-ready`, or the user saying they are about to reboot,
shut down, or install an OS update.

## `census.sh` — deterministic sweep

Runs with no arguments (or `--no-park`). Emits a single JSON document on
stdout with three sections. Diagnostic noise goes to stderr.

### Sessions

- Background jobs: enumerate `~/.claude/jobs/*/` — job id, last-activity
  mtime, transcript path if present.
- Live processes: `lsof -a -d cwd -c claude` — pid and cwd for every
  running claude process (background jobs, interactive tabs, desktop app).
  This is the full running-session census.

### Repos and worktrees

- Discover repos: `find ~/src -maxdepth 2 -name .git` (dirs and gitfiles).
- From each primary checkout, `git worktree list --porcelain` to catch all
  linked worktrees (including `.claude/worktrees/*`).
- Per checkout: branch, dirty file count (tracked + untracked), ahead/behind
  upstream, and any local branches with no upstream or unpushed commits.
- Each worktree is labeled **live** (some census process's cwd is inside
  it) or **idle**. The label is informational only — it never gates any
  action.

### Parking (rescue refs)

For each dirty checkout, build a rescue commit **without touching anything
user-visible**:

```
export GIT_INDEX_FILE=$(mktemp)
git read-tree HEAD          # seed temp index from HEAD
git add -A                  # stage tracked changes AND untracked files
tree=$(git write-tree)
commit=$(git commit-tree "$tree" -p HEAD -m "rescue: pre-reboot park <ts>")
git update-ref refs/rescue/pre-reboot/<worktree-name>-<ts> "$commit"
```

Properties:

- Captures untracked files (plain `git stash create` misses them).
- The real index, working tree, branch, and `git status` output are
  byte-for-byte unchanged — safe to run even on a checkout a live agent is
  actively editing (worst case, the snapshot catches a half-finished edit,
  which is harmless for a backup).
- Local refs only. **No pushing** — disk survives reboot, so local refs
  cover the reboot case, and auto-pushing `rescue/*` refs would pollute
  shared remotes. The report lists unpushed branches so the user can push
  anything they want off-machine.
- `--no-park` skips this section (report-only run).

## `SKILL.md` — judgment layer

Claude's job, after running the script:

1. For each running background job, read the tail of its transcript and
   summarize in one line what the agent was actually doing.
2. Write the manifest to `~/.claude/reboot-manifest.md` (overwritten each
   run; timestamped in the header). One entry per session: what it was
   working on, repo/branch/worktree, dirty-state summary, rescue ref name,
   and the resume command (`claude --resume <session-id>`, plus the nudge
   "tell it to re-check its last step — in-flight tool calls don't
   auto-resume").
3. Print a terminal summary ending in a go/no-go verdict: **ready to
   reboot** (everything parked, manifest written) or a short list of what
   is not covered.

## Error handling

- Any per-repo failure (no commits yet, no upstream, permission error,
  `lsof` unavailable) degrades to a report line — the sweep never aborts.
  A partial manifest before reboot beats a crashed one.
- Rescue-ref failures are surfaced in an explicit "NOT parked" section of
  both the JSON and the manifest. Nothing fails silently.

## Testing

A test under `tests/` in this repo:

1. Build a scratch repo with a primary checkout and one linked worktree.
2. Dirty the worktree with a tracked edit and an untracked file.
3. Run `census.sh`; assert:
   - stdout parses as JSON,
   - the rescue ref exists and its tree contains both the tracked edit and
     the untracked file,
   - `git status --porcelain` output is byte-identical before and after
     (the zero-touch guarantee).

## Out of scope (YAGNI)

- Pausing, messaging, or stopping live sessions.
- Pushing rescue refs to remotes.
- Auto-resuming sessions after reboot (the manifest is the resume aid; a
  future skill could consume it).
- Cleaning up old rescue refs (they are cheap; revisit if they accumulate).

## Approaches considered

- **A. Pure SKILL.md** — model does the whole sweep each run. Rejected:
  slow, token-hungry, nondeterministic on exactly the task that should be
  identical every time.
- **B. SKILL.md + bundled census script** — **chosen.** Deterministic where
  it matters, intelligent where it helps (transcript summaries, manifest),
  testable.
- **C. Plain script in ~/bin** — rejected: loses the "what was each agent
  doing" summaries and the judgment layer, half the manifest's value.
