---
type: spec
validated:
  sha: 30f124ea8ab9730eaff2f6a603501b5618c41722
  date: 2026-07-31T05:10:00Z
  reviewers: [fact-check, solid-hygiene]
  findings:
    critical: 0
    important: 0
    medium: 2
    low: 4
    nitpick: 0
  net_negative_remaining: 0
---

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

**Triggers:** `/stavxyz:reboot-ready` (namespaced under this repo's plugin),
or the user saying they are about to reboot, shut down, or install an OS
update.

## `census.sh` — deterministic sweep

Read-only by default; `--park` opts into rescue-ref creation. Emits a
single JSON document on stdout with three sections. Diagnostic noise goes
to stderr.

### Sessions

- Background jobs: enumerate `~/.claude/jobs/*/` — job id, last-activity
  mtime, and `sessionId`/`cwd` from `state.json` (the transcript lives at
  `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`).
  *(Verified 2026-07-31: was incorrect — job dirs hold `state.json` /
  `timeline.jsonl`, not a transcript path; the transcript must be derived
  from `sessionId` + `cwd`.)*
- Live processes: `lsof -a -d cwd -c claude` — pid and cwd for every
  running claude process (background jobs, interactive tabs, desktop app).
  This is the full running-session census.
- The JSON records a per-probe status (`ran` / `unavailable` / `errored`)
  for the jobs-dir scan and the `lsof` sweep, so an empty sessions list is
  distinguishable from a probe that couldn't look. Both probes live in one
  clearly-marked block of the script, so a Claude Code internals change
  (jobs dir relocated, binary renamed) is a one-place fix.

> **Design note (2026-07-31):** Added probe-status provenance. The
> sessions census depends on two undocumented Claude Code internals; when
> either rots, the natural failure mode was an empty-but-well-formed list
> indistinguishable from "nothing running" — exactly the silent
> under-report this tool exists to prevent.

### Repos and worktrees

- Discover repos: sweep one or more search roots passed as positional
  arguments (default: `~/src`), via `find <root> -maxdepth 2 -name .git`
  (dirs and gitfiles). The JSON echoes back which roots were swept, so an
  omitted root is visible in the report rather than silently absent.

> **Design note (2026-07-31):** The search root was originally hardcoded
> to `~/src` — the one per-machine layout assumption in the design, baked
> into the script body. Made it a parameter with `~/src` as the documented
> default so layout changes are an invocation change, not a script edit.
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
git update-ref refs/rescue/pre-reboot/<worktree-name>-<pathhash>-<ts> "$commit"
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
- This section runs only when `--park` is passed; the default invocation
  is a pure read-only census. SKILL.md instructs Claude to pass `--park`
  on a real pre-reboot run.

> **Design note (2026-07-31):** The rescue ref name carries a path-derived
> `<pathhash>` component in addition to the worktree name and timestamp.
> Two checkouts can share a basename (a primary and a same-named worktree
> elsewhere, or two repos cloned under different roots) — without the
> uniquifier their rescue refs collide in the shared ref store and the
> second parking silently overwrites the first's ref.

> **Design note (2026-07-31):** Parking was originally the default with a
> `--no-park` escape hatch. Inverted to opt-in so the script's name
> (census) matches its default behavior, and the one mutating path — ref
> writes in every dirty repo on the machine — is always explicit in the
> invocation.

## `SKILL.md` — judgment layer

Claude's job, after running the script (passing `--park` for a real
pre-reboot run; omitting it for a dry-run report):

1. For each running background job, read the tail of its transcript and
   summarize in one line what the agent was actually doing.
2. Write the manifest to `~/.claude/reboot-manifest.md` (overwritten each
   run; timestamped in the header). One entry per session: what it was
   working on, repo/branch/worktree, dirty-state summary, rescue ref name,
   and the resume command (`claude --resume <session-id>`, plus the nudge
   "tell it to re-check its last step — in-flight tool calls don't
   auto-resume"). Save the census script's raw JSON verbatim alongside it
   as `~/.claude/reboot-manifest.json` — the machine-readable record any
   future consumer binds to; the `.md` is the human resume aid.

> **Design note (2026-07-31):** Originally only the model-written prose
> manifest survived the run, discarding the deterministic JSON. Persisting
> the JSON alongside keeps a machine-checkable record (e.g. to audit a
> rescue ref the prose misstates) and gives future tooling a stable
> contract instead of LLM output.
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
3. Run `census.sh --park`; assert:
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
