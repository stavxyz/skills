---
name: reboot-ready
description: Pre-reboot sweep of Claude Code sessions and git state. Use when the user says they are about to reboot, shut down, restart, or install an OS update — inventories running sessions, dirty worktrees, and unpushed branches, parks dirty checkouts as zero-touch rescue refs, and writes a resume manifest.
---

Prepare this machine for a reboot. A reboot kills running Claude Code
sessions and any in-flight tool calls; transcripts and files on disk
survive. Your job: census everything at risk, park dirty git state as
rescue refs, and leave a manifest so every session can be picked back up.

## Step 1 — resolve the skill directory and run the census

- **Plugin install:** if `$CLAUDE_PLUGIN_ROOT` is set, `SKILL_DIR="$CLAUDE_PLUGIN_ROOT/skills/reboot-ready"`.
- **Manual install:** otherwise `SKILL_DIR` is the directory containing this SKILL.md.

Run the deterministic sweep:

```bash
bash "$SKILL_DIR/census.sh" --park
```

- Pass `--park` for a real pre-reboot run (the default and normal case).
  Omit it ONLY if the user explicitly asked for a dry-run/report-only sweep.
- Default sweep root is `~/src`. If the user names other source roots,
  pass them as positional arguments after `--park`.
- The script is degrade-don't-abort: it exits 0 even when individual repos
  fail; per-item failures are inside the JSON. Exit 2 means you passed bad
  arguments — fix and re-run.

## Step 2 — persist the raw JSON

Save the script's stdout **verbatim** to `~/.claude/reboot-manifest.json`
(overwrite). This is the machine-readable record; do not edit or pretty-
print it.

## Step 3 — summarize what each running session was doing

For each entry in `sessions.jobs` whose repo/cwd matches a live process in
`sessions.processes` (compare `cwd` fields; prefix match counts), read the
LAST ~80 lines of its transcript (the `transcript` path in the JSON; it may
not exist — skip silently if absent) and write a one-line summary of what
that agent was actually doing (e.g. "implementing Task 3 of the auth plan;
last action: running tests"). Live processes with no matching job entry are
interactive sessions — list them by pid + cwd without a summary.

## Step 4 — write the manifest

Write `~/.claude/reboot-manifest.md` (overwrite each run):

```markdown
# Reboot manifest — <UTC timestamp>

## Verdict: <READY TO REBOOT | NOT READY — reasons below>

## Running sessions (will be killed by reboot)
### <job id or pid> — <one-line activity summary>
- Where: <checkout path> (branch `<branch>`, <N> dirty files)
- Rescue ref: `<rescue_ref>` (or "none — checkout clean")
- Resume: `claude --resume <session_id>` — then tell it to re-check its
  last step; in-flight tool calls do not auto-resume.

## Idle dirty checkouts (parked)
- <path> — branch `<branch>`, <N> dirty files → `<rescue_ref>`

## Unpushed branches (survive reboot on disk; push only if you want an off-machine copy)
- <repo>: <branch list>

## NOT parked (needs manual attention before reboot)
- <path> — <error>

## Probe health
- jobs scan: <ran|unavailable|errored>; lsof: <ran|unavailable|errored>
```

Omit any section with nothing to report, except `Probe health` (always
include it).

## Step 5 — verdict and terminal summary

Print a short summary to the user ending in a go/no-go verdict:

- **READY TO REBOOT** — every dirty checkout has a rescue ref, `not_parked`
  is empty, and both probes report `ran`.
- **NOT READY** — list exactly what is uncovered: each `not_parked` entry,
  and/or any probe that is `unavailable`/`errored` (say plainly: "the
  census could not see X, so an empty list there is not proof of nothing
  running").

Remind the user: files and transcripts survive reboot; running processes do
not; after reboot, walk the manifest and resume each session.

## Hard rules

- NEVER push anything anywhere. Rescue refs are local only.
- NEVER modify a working tree, index, or branch — the census script's
  `--park` writes refs only; you write only the two manifest files.
- NEVER stop, signal, or message running sessions.
- If `census.sh` is missing or unrunnable, STOP and tell the user the skill
  install is broken — do not improvise the sweep inline.
