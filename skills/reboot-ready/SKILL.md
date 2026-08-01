---
name: reboot-ready
description: Pre-reboot sweep of Claude Code sessions and git state. Use when the user says they are about to reboot, shut down, restart, or install an OS update — inventories running sessions, dirty worktrees, and unpushed branches, parks dirty checkouts as zero-touch rescue refs, and writes a resume manifest.
---

Prepare this machine for a reboot. A reboot kills the running *processes*
— any in-flight tool call dies mid-step — but the sessions themselves are
disk-backed and reappear in the agents list after restart (verified
2026-08-01: post-reboot, `~/.claude/jobs/*/state.json` files carried
`updatedAt` timestamps newer than boot). Transcripts and files on disk
survive too. Your job: census everything at risk, park dirty git state as
rescue refs, and leave a manifest recording what each session was doing —
the sessions come back on their own; knowing where each one left off, and
having the dirty state snapshotted, is what doesn't happen automatically.

## Step 1 — resolve the skill directory and run the census

- **Plugin install:** if `$CLAUDE_PLUGIN_ROOT` is set, `SKILL_DIR="$CLAUDE_PLUGIN_ROOT/skills/reboot-ready"`.
- **Manual install:** otherwise `SKILL_DIR` is the directory containing this SKILL.md.

Run the deterministic sweep, sending stdout and stderr to SEPARATE files.
The Bash tool returns stdout and stderr merged into one blob, so this is
the only way to get a verbatim, on-disk copy of just the JSON — capturing
the tool's combined output and trying to split it back apart after the
fact is not possible:

```bash
bash "$SKILL_DIR/census.sh" --park > ~/.claude/reboot-manifest.json 2> ~/.claude/reboot-census.log
```

- Pass `--park` for a real pre-reboot run (the default and normal case).
  Omit it ONLY if the user explicitly asked for a dry-run/report-only sweep.
- Default sweep root is `~/src`. If the user names other source roots,
  pass them as positional arguments after `--park`.
- The script is degrade-don't-abort: it exits 0 even when individual repos
  fail; per-item failures are inside the JSON. Exit 2 means you passed bad
  arguments — fix and re-run.

## Step 2 — read both files

`~/.claude/reboot-manifest.json` is already the verbatim, machine-readable
record of the run — do not edit it, re-run the script, or pretty-print over
it. Read it and `~/.claude/reboot-census.log` (diagnostics; may be empty)
before continuing; both feed Steps 3 and 5.

## Step 3 — summarize what each running session was doing

For each entry in `sessions.jobs` whose `state` field indicates it is
actually running (not a finished/idle job — most job entries on a typical
sweep are finished and must not be reported as running just because they
exist), read the LAST ~80 lines of its transcript (the `transcript` path in
the JSON; it may not exist — skip silently if absent) and write a one-line
summary of what that agent was actually doing (e.g. "implementing Task 3 of
the auth plan; last action: running tests"). Do NOT key this off matching
`cwd` against `sessions.processes` — background-job processes commonly run
under a daemon's own cwd (e.g. `/private/tmp/cc-daemon-*`), unrelated to the
job's actual working directory, so a cwd join under- and over-matches.

Separately, list every entry in `sessions.processes` by pid + cwd — these
are the interactive/desktop sessions. Cross-reference by `cwd` against
running job entries only to avoid double-listing a job's own worker
process; when in doubt, list both.

## Step 4 — write the manifest

Write `~/.claude/reboot-manifest.md` (overwrite each run):

```markdown
# Reboot manifest — <UTC timestamp>

## Verdict: <READY TO REBOOT | NOT READY — reasons below>

## Swept roots
- <root> (from the JSON's `roots`; state plainly if this list is empty or
  narrower than expected — "0 checkouts" must never read as green)

## Running sessions (interrupted by reboot; they reappear in the agents list afterward)
### <job id or pid> — <one-line activity summary>
- Where: <checkout path> (branch `<branch>`, <N> dirty files, or "dirty
  state unknown" when `dirty_count` is `null`)
- Rescue ref: `<rescue_ref>` (or "none — checkout clean")
- Pickup: the session returns natively after reboot — tell it to re-check
  its last step (in-flight tool calls die at shutdown and do not re-run).
  If it does not reappear: `claude --resume <session_id>`.

## Idle dirty checkouts (parked)
- <path> — branch `<branch>`, <N> dirty files (or "dirty state unknown" when
  `dirty_count` is `null`) → `<rescue_ref>`

## Unpushed branches (survive reboot on disk; push only if you want an off-machine copy)
- <repo>: <branch list>

## NOT parked (needs manual attention before reboot)
- <path> — <error>

## Probe health
- jobs scan: <ran|unavailable|errored>; lsof: <ran|unavailable|errored>
- census diagnostics (reboot-census.log): <empty | N line(s), quoted below>
```

Omit any section with nothing to report, except `Verdict`, `Swept roots`,
and `Probe health` (always include those three — an empty swept-roots list
is exactly the silent under-report this skill exists to catch).

`dirty_count: null` means the count could not be assessed (e.g. `git
status` failed) — render it as "dirty state unknown", never as "0" or
"None dirty files"; a checkout in this state is never parked either.
`ahead`/`behind` are JSON-only fields for future consumers of
`reboot-manifest.json` — the manifest's own "Unpushed branches" section is
driven by `unpushed_branches`, not by ahead/behind counts.

## Step 5 — verdict and terminal summary

Print a short summary to the user ending in a go/no-go verdict:

- **READY TO REBOOT** — every dirty checkout has a rescue ref, `not_parked`
  is empty, both probes report `ran`, AND `reboot-census.log` is empty.
- **NOT READY** — list exactly what is uncovered: each `not_parked` entry,
  any probe that is `unavailable`/`errored`, and every line of
  `reboot-census.log` if it is non-empty (quote each line verbatim as its
  own uncovered item — script-level diagnostics that never made it into the
  JSON are exactly the kind of gap a JSON-only verdict would miss). Say
  plainly: "the census could not see X, so an empty list there is not proof
  of nothing running."

Always state the swept roots in this summary too, even on a clean run — a
`READY TO REBOOT` with zero checkouts because the wrong root was swept is
not actually ready.

Remind the user: sessions are disk-backed and reappear in the agents list
after reboot; what dies is the running processes and any in-flight tool
calls. After reboot, walk the manifest and nudge each returned session to
re-check its last step — do not tell the user they must manually resume
everything.

## Hard rules

- NEVER push anything anywhere. Rescue refs are local only.
- NEVER modify a working tree, index, or branch — the census script's
  `--park` writes refs only; you write only the two manifest files.
- NEVER stop, signal, or message running sessions.
- If `census.sh` is missing or unrunnable, STOP and tell the user the skill
  install is broken — do not improvise the sweep inline.
