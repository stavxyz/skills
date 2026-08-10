---
name: validate
description: Validate a spec or plan (a markdown design or implementation-plan
  doc) against the current codebase before building. Runs two reviewers in
  parallel — a fact-check pass (are the doc's claims about existing code true?)
  and a SOLID/hygiene pass (is the design direction sound?) — addresses the
  findings in-place, and on a clean, caveat-free bless auto-continues a spec to
  writing-plans and a plan to subagent-driven-development. Use when the user has
  a spec or plan and says things like "validate this spec," "check my plan
  against the codebase," "fact-check this design doc," or "review my plan before
  I build." Operates on .md spec/plan files (e.g. under docs/superpowers/specs/
  or docs/superpowers/plans/). Not for validating data, forms, schemas, or code
  output — only design specs and implementation plans.
disable-model-invocation: false
---

Validate the spec or plan at $ARGUMENTS.

This skill runs polish-pr-style multi-reviewer validation. Two reviewers run in parallel — fact-check (claims about existing code) and SOLID/hygiene (design direction) — with bespoke prompt templates inside this skill folder. Findings are addressed in-spec by default. Three gating conditions trigger user approval before edits proceed: (1) deferral candidates, (2) Critical fact-check findings (per-finding confirmation), (3) SOLID `net-negative` findings.

The canonical severity list is `Critical / Important / Medium / Low / Nitpick`. The reviewer prompts emit findings at exactly these levels; this workflow's parser expects exactly these levels. Adding or renaming a level is a coordinated change across all three files in this skill folder.

## Tuning constants

Adjust these after inaugural runs reveal real-world thresholds:

- `OVERLOAD_CRITICAL_IMPORTANT = 25` — if combined Critical+Important findings exceed this, abort before edits and report "spec drifted significantly."
- `OVERLOAD_TOTAL = 100` — same abort condition, total finding count.
- `DEDUPE_SIMILARITY = 0.8` — Levenshtein-style similarity threshold for treating two findings at the same location as duplicates. Above threshold = duplicate (keep more specific); below = independent.

Note: the reviewer templates' **repeated-pattern sweep** (see `fact-check-reviewer.md` / `solid-hygiene-reviewer.md`) deliberately emits one finding per location for a recurring anti-pattern, so a single systemic root cause can legitimately raise the counts above. Tripping the overload abort on such a pattern is defensible (a pattern at many sites *is* significant drift), but re-tune both `OVERLOAD_*` constants once real runs show how often the sweep pushes one genuine root cause past the threshold.

## Preconditions

Verify in order, exiting on the first failure:

1. `$ARGUMENTS` resolves to an existing file. Run `ls "$ARGUMENTS"` via Bash. If exit code is non-zero, report `⛔ validate: <path> does not exist.` and exit.
2. The path ends in `.md`. If not, report `⛔ validate: <path> is not a markdown file.` and exit.
3. The file's directory (or its nearest ancestor that is a git repo) is a git repository. Run `git -C "$(dirname "$ARGUMENTS")" rev-parse HEAD` via Bash and capture the SHA as `HEAD_SHA`. If the command fails, report `⛔ validate: not in a git repository (cannot fact-check against HEAD).` and exit.
4. Both reviewer template files exist alongside this `SKILL.md`. First resolve the skill directory into `SKILL_DIR`, supporting either install method:
   - **Plugin install:** if the `$CLAUDE_PLUGIN_ROOT` environment variable is set, `SKILL_DIR="$CLAUDE_PLUGIN_ROOT/skills/validate"`.
   - **Manual install:** otherwise `SKILL_DIR` is the directory containing this `SKILL.md` (e.g. `~/.claude/skills/validate` when symlinked into the user skills folder).

   Then run `ls "$SKILL_DIR/fact-check-reviewer.md" "$SKILL_DIR/solid-hygiene-reviewer.md" "$SKILL_DIR/check-citations.py"` via Bash. If any is missing, report `⛔ validate: reviewer template <filename> missing from skill folder. Reinstall the skill or restore from version control.` and exit.

   `check-citations.py` is hard-stopped alongside the templates on purpose. A missing deterministic check that merely warns would be skipped silently, and a citation check that runs on some invocations and not others is worse than none — the frontmatter bless would then mean two different things depending on what happened to be installed.
5. Capture `REPO_ROOT` via `git -C "$(dirname "$ARGUMENTS")" rev-parse --show-toplevel`.

## Detect kind

Apply heuristics in order; the first match wins. Frontmatter is authoritative — do not second-guess based on path or content if frontmatter says one thing.

1. **Frontmatter.** Read the first ~20 lines of the file. If the YAML frontmatter (between two `---` lines) has a `type:` field set to `spec` or `plan`, set `KIND` to that value and stop.
2. **Path.** If the file path includes `docs/superpowers/specs/` (case-sensitive), set `KIND = spec`. If it includes `docs/superpowers/plans/`, set `KIND = plan`.
3. **Content shape.** Read the file. If it contains the regex `^### Task \d+:` (a numbered Task heading), set `KIND = plan`. Otherwise, if it contains any of `## Architecture`, `## Components`, `## Data flow`, set `KIND = spec`.
4. **Tie-break.** If none of the above match, call AskUserQuestion: question = "Couldn't auto-detect whether `<path>` is a spec or a plan. Which is it?", header = "Kind", options = `[{label: "spec"}, {label: "plan"}]`. Set `KIND` to the user's answer.

## Capture mtime

Run via Bash, falling back gracefully across platforms:

```bash
INITIAL_MTIME=$(stat -f "%m" "$ARGUMENTS" 2>/dev/null || stat -c "%Y" "$ARGUMENTS" 2>/dev/null || echo "0")
```

Store `INITIAL_MTIME` for later use. The check is not load-bearing if it fails (the value will be `"0"` which compares unequal to any real mtime); the worst case is one false-positive abort, which is recoverable via re-running.

## Check citations (deterministic, before dispatch)

Run the bundled checker over the document:

```bash
python3 "$SKILL_DIR/check-citations.py" "<spec_path>" --repo-root "$REPO_ROOT"
```

It reads every `path/to/file.py:NN` citation in the document, resolves the path
against `REPO_ROOT`, and — where the citation carries an anchor, naming what the
line is expected to contain — asserts the cited lines actually contain that
symbol, reporting the corrected line number when they do not. The anchored form:

```text
`driver.py:73` (`state_mod.load`)
```

Findings print in this skill's own finding format, so they need no separate
parser. Capture stdout as `CITATION_RAW`.

**Why deterministic and why first.** A fact-check reviewer reads the cited file
and forms an impression; this reads the line and compares bytes. On the class of
finding they overlap on — "the spec says line 53 and it is line 61" — the
byte comparison is right by construction and cheaper by three orders of
magnitude, and it never reports a line number it did not read. Running it before
dispatch also means its corrections are in hand when the reviewers' claims about
the same locations arrive, so triage has the measured answer to compare against.

The exit code is 0 whether or not it found anything, because these are findings
for triage, not a gate — the gates are the three in "Triage findings" below. A
non-zero exit means the run itself failed (bad path, not a git repo); surface
that to the operator and continue with the two reviewers rather than aborting,
since a broken citation check does not invalidate a design review.

**Citations inside fenced code blocks are skipped**, since a document's code
samples name illustrative paths rather than asserting anything about the
repository — including, unavoidably, the example two paragraphs above. Inline
citations in prose are checked.

**Anchors are opt-in, and that is the adoption path.** A citation with no
anchor is reported as `unverifiable`, not as a finding, so this can be turned
on against documents written before it existed without producing a wall of
noise. Pass `--strict` to also emit those as Low findings — appropriate when
the operator is deliberately hardening one document's citations, not as the
default. Path resolution, ambiguity, and past-end-of-file are all checked with
or without an anchor.

## Dispatch reviewers in parallel

Read both prompt templates from disk (using `SKILL_DIR` resolved in precondition 4):

- `$SKILL_DIR/fact-check-reviewer.md`
- `$SKILL_DIR/solid-hygiene-reviewer.md`

For each, substitute these placeholders by literal find-and-replace (no templating engine — simple string replacement):

- `{spec_path}` → absolute path of `$ARGUMENTS` (resolve via `realpath` or `cd $(dirname) && pwd` if needed)
- `{repo_root}` → `$REPO_ROOT` from preconditions
- `{head_sha}` → `$HEAD_SHA` from preconditions
- `{kind}` → `$KIND` from kind detection

After substitution, verify no `{` followed by a known placeholder name remains in either template. If any placeholder substitution missed (typo in placeholder name, etc.), report `⛔ validate: prompt template <filename> has unfilled placeholder <name>. Aborting before dispatch.` and exit.

In a **single message**, dispatch BOTH reviewers via the Task tool. Both Task calls go in the same message (multiple tool_use blocks in one assistant message) so they execute concurrently:

- Task call 1: `subagent_type: general-purpose`, `prompt: <fact-check-reviewer.md content with placeholders filled in>`, `description: "Fact-check <kind> against codebase"`
- Task call 2: `subagent_type: general-purpose`, `prompt: <solid-hygiene-reviewer.md content with placeholders filled in>`, `description: "SOLID review of <kind> design"`

The `general-purpose` subagent type ships with the full tool set — Edit and Write are technically available, and Bash isn't filterable to specific commands. The reviewer prompts include hard rules forbidding Edit/Write and mutating Bash commands; enforcement is at the reviewer's discretion (the prompt's authority). If a reviewer disobeys (writes to disk or mutates the working tree), this would surface as unexpected file changes the operator would notice — a soft trust boundary, not a hard one.

Wait for both Task calls to complete. Capture each reviewer's output as `FACT_CHECK_RAW` and `SOLID_RAW`.

If either Task call fails (timeout, tool error), capture the partial output if any, and call AskUserQuestion: question = "Reviewer <X> failed: <error>. Re-dispatch just this reviewer, or proceed with surviving reviewer only?", header = "Dispatch failure", options = `[{label: "Re-dispatch failed reviewer"}, {label: "Proceed with surviving reviewer only (degraded mode)"}]`. If user picks degraded mode, log a clear warning in the final report; otherwise re-dispatch the failed Task call alone.

## Parse findings

Reviewers return Markdown structured per the templates' output format. Each finding is an `### <Severity>: <one-line summary>` block followed by labeled fields.

Parse each reviewer's raw output:

1. **Split by heading.** Use a regex `^### ` (multiline, case-sensitive) to split the output into blocks. Discard any prefix/suffix text (intros, "Suggestions" sections, etc.) — those don't contain findings.
2. **Per block, parse the heading.** Match `^### (Critical|Important|Medium|Low|Nitpick): (.+)$` to extract `severity` and `summary`. If the heading doesn't match (e.g., severity is not in the canonical list), mark this block as a parse failure: surface the raw block to the operator at report time with note "parse failure for this finding"; do NOT include in the structured findings list.
3. **Per block, extract labeled fields via regex.** For each labeled field (`Location`, `Claim`, `Reality`, `Suggested correction`, `Gate-status`, `Concern`, `Suggested direction`), match the regex `^\*\*(<field name>)\*\*:\s*(.+?)(?=^\*\*|\Z)` (with re.MULTILINE | re.DOTALL semantics) to extract the field value, trimming trailing whitespace.
4. **Build a finding record** as a structured dict:

```yaml
source: fact-check  # or solid-hygiene
severity: Critical | Important | Medium | Low | Nitpick
location: "<spec line:section>"
gate_status: advisory | net-negative   # solid-hygiene only; absent for fact-check
claim: "..."                            # fact-check only
reality: "..."                          # fact-check only
suggested_correction: "..."             # fact-check only
concern: "..."                          # solid-hygiene only
suggested_direction: "..."              # solid-hygiene only
```

5. **Per-finding fallback.** If a required field for a given finding is missing/malformed, surface only that block as raw text to the operator at report time; other findings parse normally. Per-finding fallback rather than whole-output fallback prevents one malformed reviewer block from poisoning the entire run.

6. **`CITATION_RAW` parses with the same code.** The checker emits the fact-check block shape (`### Important: …` with `Location`, `Claim`, `Reality`, `Suggested correction`), so run it through steps 1-5 unchanged and tag the resulting records `source: citations`. Under `--strict` it also emits `### Low:` blocks; those parse identically.

Combine all three sources' parsed findings into a single list, `FINDINGS`.

## Triage findings

### Dedupe

Two findings count as overlapping if:

1. They have different `source` (one fact-check, one solid-hygiene), AND
2. Their `location` strings match (after trimming whitespace), AND
3. The Levenshtein-style similarity between their `claim`/`concern` strings is ≥ `DEDUPE_SIMILARITY` (default 0.8).

**A `citations` finding always wins its pair.** Where a `citations` finding
overlaps one from either reviewer, keep the `citations` one and log the other in
`DEDUPE_FINDINGS` regardless of which reads as more specific. It carries a line
number read off disk this run; the reviewer's carries one the reviewer arrived
at. Applying both would also mean two Edits against the same text, the second of
which fails to match. Overlap here uses the same three conditions above.

For each remaining overlapping pair, keep the "more specific" finding — defined as: the finding whose `claim`/`concern` text contains a named symbol (function name, type name, file path) wins over a finding with only vague references. If tied, the longer text wins. Discard the loser; log the discarded finding's text in a `DEDUPED_FINDINGS` list for the report.

If two solid-hygiene findings (same source) share `location` and similar text, they're duplicates from one reviewer — keep one, log the other in `DEDUPED_FINDINGS`.

### Detect contradictions

Two findings count as contradictory if:

1. They have different `source` (one fact-check, one solid-hygiene), AND
2. Their `location` strings match (after trimming whitespace), AND
3. The Levenshtein-style similarity between their `claim`/`concern` strings is **below** `DEDUPE_SIMILARITY` (so they're NOT duplicates) AND below 0.4 (low similarity — they're describing different concerns at the same spec location).

Crossing the same location from different angles is normal (e.g., a fact-check finding about a file path AND a SOLID finding about the design at that same path); those proceed as independent findings. But low-similarity findings at the same location may indicate the reviewers disagree about the underlying premise (one assumes X is true, the other's design feedback assumes X is false).

For each contradictory pair, surface to the operator before triage. Call AskUserQuestion: question = "Reviewers disagree about <location>. Reviewer A (fact-check) says: <fact-check claim>. Reviewer B (SOLID) says: <SOLID concern>. Which finding should validate proceed with?", header = "Conflict", options = `[{label: "Apply fact-check finding (skip SOLID)"}, {label: "Apply SOLID finding (skip fact-check)"}, {label: "Skip both — manual triage"}]`. Apply only the chosen finding (or neither); log the choice in the report's "Conflict resolutions" subsection.

### Overload check

Compute:

- `CI_COUNT` = number of findings with `severity in (Critical, Important)`.
- `TOTAL_COUNT` = number of all findings (post-dedupe).

If `CI_COUNT > OVERLOAD_CRITICAL_IMPORTANT` OR `TOTAL_COUNT > OVERLOAD_TOTAL`, abort before any edits. Report:

```
⛔ validate: spec drifted significantly from the codebase. <CI_COUNT> Critical+Important findings, <TOTAL_COUNT> total. Consider rebasing the spec via brainstorming before re-running validate.
```

Then exit. Operator can take the spec back to brainstorming for a refresh, or re-run validate after manual triage.

### Gates: ask before deferring, before applying Critical, before SOLID-net-negative

Three gating conditions must be resolved via AskUserQuestion **before** any Edit calls.

**Gate 1 — Deferral candidates.** Identify findings that match the polish-pr deferral list:
- Genuinely additive scope (a new product surface, a new RPC endpoint with non-obvious shape).
- Multi-step migrations touching tables outside this spec's scope that need their own deploy ordering.
- Cross-cutting refactors affecting modules unrelated to this spec.

For each deferral candidate, call AskUserQuestion: question = "Finding looks like a deferral candidate per polish-pr's rules: <finding>. Defer to a follow-up, or address in this spec?", header = "Defer?", options = `[{label: "Address in this spec (recommended)"}, {label: "Defer to follow-up"}]`. Default disposition is `address`; do not unilaterally defer.

If user picks `defer`, the finding will not be applied as an edit; instead, the report will list it as deferred with the user's reasoning. The user is responsible for opening a GitHub issue if relevant (this skill does not auto-create issues).

**Gate 2 — SOLID `net-negative` findings.** For each finding with `source: solid-hygiene` AND `gate_status: net-negative`, call AskUserQuestion: question = "<finding's concern>. The reviewer flags this as net-negative — the spec actively makes the codebase worse. Address (re-design the section), accept (record explicit approval that design moves backward), or escalate (back to brainstorming)?", header = "Net-negative", options = `[{label: "Address (re-design section)"}, {label: "Accept (record approval)"}, {label: "Escalate (back to brainstorming)"}]`.

If user picks `Address`: continue to next gate; the edit phase will redesign the spec section.
If user picks `Accept`: record acceptance in the finding's metadata; the edit phase will append an "Accepted net-negative tradeoff" annotation to the spec section.
If user picks `Escalate`: see "Escalate path" below.

**Gate 3 — Critical fact-check findings.** For each finding with `source: fact-check` AND `severity: Critical`, call AskUserQuestion: question = "Critical fact-check finding: <finding's summary>. The reviewer says <claim> in the spec is incorrect; reality per the codebase is <reality>. Apply the suggested correction, skip this finding (treat as advisory), or abort the run?", header = "Critical fact-check", options = `[{label: "Apply suggested correction"}, {label: "Skip this finding (treat as advisory)"}, {label: "Abort validate"}]`.

If user picks `Apply`: proceed to edit phase, which will apply the correction.
If user picks `Skip`: the finding is downgraded to Low-severity advisory; no edit is applied.
If user picks `Abort`: report `⛔ validate aborted by operator at Critical fact-check gate.` and exit. Frontmatter is NOT updated.

### Escalate path

If user picks `Escalate` on any net-negative gate, validate aborts before edits. Steps:

1. Compute `SHORT_SHA` = first 8 chars of `HEAD_SHA`.
2. Compute `FINDINGS_PATH` = `<spec_path>.validate-findings-<SHORT_SHA>.md`.
3. Write the full findings list (both reviewers, all severities, all gate statuses) to `FINDINGS_PATH` as Markdown. Format: a header section explaining the file's purpose, then the structured findings, then a brief "next steps" section directing the operator to invoke `superpowers:brainstorming` with this file as context.
4. Report:
   ```
   ⛔ validate escalated <spec_path>: design needs re-brainstorming. Findings saved to <FINDINGS_PATH>.
   ```
5. Do NOT update the spec's frontmatter (no partial-validation trace).
6. Exit.

## Edit the spec in place

Before applying any Edit, re-stat the spec file and check for external modification:

```bash
CURRENT_MTIME=$(stat -f "%m" "$ARGUMENTS" 2>/dev/null || stat -c "%Y" "$ARGUMENTS" 2>/dev/null || echo "0")
```

If `CURRENT_MTIME != INITIAL_MTIME`, abort with:

```
⛔ validate: spec was modified externally during validation. Re-run validate after the changes settle.
```

After the first Edit call begins, validate's own writes will advance mtime — no further re-stats are meaningful.

For each finding to apply (after gating resolutions), apply this loop:

1. **Verify claim-text-in-spec.** Read the spec content. Search for the exact `claim` string verbatim. If not found:
   - The reviewer hallucinated a quote. Downgrade this finding to a Low-severity advisory.
   - Add to `HALLUCINATED_FINDINGS` list for the report.
   - Skip the Edit — do NOT proceed to step 2 for this finding.
2. **Apply the Edit.** Use the Edit tool with:
   - `file_path` = absolute path to spec
   - `old_string` = the verified claim text
   - `new_string` = the corrected text per the type below

   The corrected text depends on the finding type:

   - **Mechanical drift** (path moved, line range stale, function renamed): replace verbatim with the verified reality from the finding's `reality` field. No annotation needed.

   - **`source: citations` findings** are mechanical drift by construction — apply the `suggested_correction` verbatim in place of the `claim` text, with no annotation. Two of its verdicts have no mechanical correction to apply, because the right fix is a judgment call: an ambiguous bare filename (the checker cannot know which file was meant) and an anchor too short to verify anything (only the author knows what the line was supposed to say). For those two, surface the finding to the operator with the checker's suggestion rather than editing.

   - **Substantive drift** (claim about behavior was wrong): replace with verified reality, then append a one-line note explaining what changed about the design's premise. Format the appended note in italics: `*(Verified <date>: was incorrect — <one-line summary of change>.)*`. Use the date from `date +%Y-%m-%d`.

   - **Advisory SOLID findings** (`gate_status: advisory`): address by adding/revising design notes within the relevant section. Add a "Design note (<date>):" subsection at the end of the section explaining the improvement made in response to the SOLID concern. Format: `> **Design note (<date>):** <description of how the section was revised in response to the SOLID concern>`.

   - **Accepted net-negative findings** (gated as `Accept`): append an "Accepted net-negative tradeoff" annotation. Format: `> **Accepted net-negative tradeoff (<date>):** <reviewer's concern verbatim>. <user's reasoning if provided; otherwise "explicit operator approval">`.

3. **One Edit call per logical concern.** Don't batch unrelated findings into a single Edit. If a single finding requires multiple text replacements (e.g., the claim text appears in three places), use Edit's `replace_all: true` only if all instances are the same drift; otherwise issue one Edit per location.

Preserve the spec's voice — don't rewrite paragraphs you didn't have a finding about. The goal is targeted correction, not stylistic refresh.

## Verify net-positive

Deterministic re-scan of the post-edit spec. This is NOT a re-dispatch of the SOLID reviewer — it's a check that the user's gating choices were honored.

For each finding in `FINDINGS` after triage:

1. **Net-negative finding marked `Address`:**
   - Diff the spec's section at the finding's `location` between pre-edit and post-edit content (compare the section's text before and after the Edit phase).
   - If unchanged, block with:
     ```
     ⛔ validate blocked: <finding's concern>. User selected `address`, but the spec section at <location> is unchanged. Re-run validate after manually addressing this finding.
     ```
   - If changed, the user's choice was honored; continue.

2. **Net-negative finding marked `Accept`:**
   - Confirm the "Accepted net-negative tradeoff" annotation appears in the spec body at the finding's location.
   - If absent, block (same form as above; "annotation absent").

3. **Findings in `HALLUCINATED_FINDINGS`** (claim text not found verbatim):
   - Always block. Report:
     ```
     ⛔ validate: <count> findings could not be auto-edited because reviewer claims didn't match spec text. Manual triage required. See report below for the affected findings.
     ```

4. **All other findings (advisory, mechanical, substantive, Critical fact-check applied):**
   - No verification needed; the Edit call either succeeded (the spec was modified) or threw (the run already aborted). Trust that the Edit happened.

If all checks pass, the spec is BLESSED. Proceed to the report. If any block fires, the spec is NOT blessed; do NOT update the frontmatter `validated:` block.

## Report

### Print the structured banner

If verification passed (spec is blessed), print:

```
✅ validate blessed <spec_path> against <SHORT_SHA>
```

If verification failed (any block fired), print:

```
⛔ validate blocked <spec_path>: <description of the first block that fired>
```

### Print the counts table

```
Findings:
  Critical:    <X> (fact-check: <A>, solid: <B>)
  Important:   <X>
  Medium:      <X>
  Low:         <X>
  Nitpick:     <X>
  ---
  Total:       <X>
  Citations:   <N> found, <V> verified, <U> unverifiable, <B> broken
  Deduped:     <X> (kept more-specific in each pair)
  Hallucinated: <X> (claim text not in spec; surfaced for manual review)
  Net-negative: <X> (<Y> addressed, <Z> accepted, <W> remaining → BLOCKING)
```

Take the `Citations:` numbers from the `<!-- citations: … -->` comment on the first line of `CITATION_RAW`. Print the line even when all four numbers are zero: a run that found no citations and a run where the check never happened produce the same empty findings list, and only this line distinguishes them.

If any findings were deferred via Gate 1, list them under a "Deferred:" subsection with reasoning.
If any findings hallucinated quotes (in `HALLUCINATED_FINDINGS`), list each with the original claim text and the reviewer's intended `reality` so the operator can manually triage.

### Update the spec's frontmatter (only on bless)

If the spec is blessed, update the spec's frontmatter to add a `validated:` block. Use the Edit tool with:

- `file_path` = absolute path to spec
- `old_string` = the existing closing `---` of the frontmatter
- `new_string` = a `validated:` block immediately above the closing `---`, in this format:

```yaml
validated:
  sha: <HEAD_SHA>
  date: <ISO 8601 timestamp from `date -u +"%Y-%m-%dT%H:%M:%SZ"`>
  reviewers: [fact-check, solid-hygiene]
  findings:
    critical: <count>
    important: <count>
    medium: <count>
    low: <count>
    nitpick: <count>
  net_negative_remaining: <count of accepted net-negatives>
```

If a `validated:` block already exists from a prior validate run, replace it (the new block always reflects the most recent run).

### Persist the spec file

Check whether the spec's directory is gitignored:

```bash
git -C "$(dirname "$ARGUMENTS")" check-ignore "$ARGUMENTS"
```

Exit code 0 means gitignored.

- **If gitignored:** the spec file is already saved (Edits wrote to disk). Print: `Spec saved at <spec_path> (path is gitignored — no commit performed).`
- **If tracked:** create an atomic commit:
  ```bash
  git -C "$REPO_ROOT" add "$ARGUMENTS"
  git -C "$REPO_ROOT" commit -m "docs(spec): validate findings addressed for <topic>"
  ```
  Where `<topic>` is derived from the spec's filename (strip the date prefix and `-design.md` suffix; replace dashes with spaces). Print: `Spec committed: <commit_sha>.`

No Claude attribution in the commit message — never `Co-Authored-By` or `Generated with Claude Code` lines.

## Auto-continue on clean bless

This section runs ONLY after a successful bless. If any block fired during "Verify net-positive," the skill already stopped — there is no auto-continue. Auto-continue is strictly downstream of an already-successful bless and changes none of the reviewing, parsing, gating, or bless logic above.

### Define "clean bless" (maximum confidence)

A bless is **clean** only when the spec/plan is blessed AND every one of these caveat counts is zero (and both reviewers ran):

- Deferred findings (Gate 1 deferrals) = 0
- Accepted net-negatives (`net_negative_remaining`, from Gate 2 `Accept`) = 0
- Skipped Critical fact-checks (Gate 3 `Skip`, downgraded to advisory) = 0
- Hallucinated findings (`HALLUCINATED_FINDINGS`) = 0
- Parse failures = 0 — counting BOTH classes from "Parse findings": a `### ` block whose heading failed the `^### (Critical|Important|Medium|Low|Nitpick):` match, AND any finding surfaced as raw text because a required field was missing/malformed
- Reviewer contradictions that reached the contradiction gate ("Detect contradictions") = 0 — ANY operator resolution counts as a caveat, including picking a side (`Apply fact-check finding (skip SOLID)` / `Apply SOLID finding (skip fact-check)`), not only `Skip both — manual triage`. A triggered contradiction gate means the reviewers disagreed about an underlying premise and human judgment was required — that is less than maximal confidence regardless of how it was resolved.
- `KIND` was determined by frontmatter, path, or content shape — NOT by the tie-break AskUserQuestion ("Detect kind" step 4). A tie-broken kind means the artifact's identity was itself ambiguous; do not auto-continue (especially into implementation) off a guess.
- Both reviewers ran to completion — NOT degraded/single-reviewer mode (the dispatch-failure fallback was not taken)

If the bless is **not** clean (any caveat above is present), do NOT auto-continue. After the normal report, print one line recommending the next step and stop:

```
🟡 validate: blessed with caveats — recommend running the next stage manually after reviewing the deferred/accepted/skipped items above.
  Next stage: <superpowers:writing-plans if KIND==spec, else superpowers:subagent-driven-development>
```

The operator drives the next step by hand. This preserves a human checkpoint whenever confidence is anything less than maximal.

### On a clean bless, announce then proceed

No confirmation prompt — announce, then immediately invoke the next skill. But guard the handoff first: the auto-continue depends on the next-stage skill being model-invocable, and that is not guaranteed.

1. **Resolve the next-stage skill** from `KIND`. Two names refer to it: `<target>` is the fully-qualified, invocable skill id; `<next stage>` is its bare name (used only in the green banner).
   - `KIND == spec` → `<target>` = `superpowers:writing-plans`, `<next stage>` = `writing-plans`
   - `KIND == plan` → `<target>` = `superpowers:subagent-driven-development`, `<next stage>` = `subagent-driven-development`

2. **Confirm the target is model-invocable BEFORE announcing.** Base this on one observable fact: **does `<target>` appear in the list of skills you can invoke via the Skill tool (the model-invocable skills enumerated in your context)?** You cannot read other skills' frontmatter — you only see presence or absence. A skill is absent from that list when it isn't installed, or when its frontmatter sets `disable-model-invocation: true` (making it user-only); either way the Skill tool cannot call it. If `<target>` is **absent**, do NOT print the clean-bless banner and do NOT silently stop — take the **manual-fallback** path (below), then stop. Only the automatic handoff is skipped; the bless and frontmatter update are unaffected.

   **Manual-fallback (canonical).** Print this `🟡` line, substituting `<reason>`, then stop:

   ```
   🟡 validate: auto-continue unavailable (the bless itself is clean) — <reason>. Run the next stage yourself: invoke <target>, pointing it at <absolute path of the blessed file>.
   ```

   For the absent-target case, `<reason>` = `<target> isn't an invocable skill (not installed, or model-invocation disabled)`. This `🟡` is intentionally distinct from the "blessed with caveats" `🟡` earlier: that one means the bless had caveats; this one means the bless was clean but the handoff couldn't run. Keep the two separate — do not collapse them.

3. **If `<target>` is invocable, print the banner:**

   ```
   🟢 validate: clean bless, maximum confidence — auto-continuing to <next stage>.
   ```

4. **Invoke the next skill via the Skill tool.** For the skill's input, provide the blessed file's **resolved absolute path** — the same absolute path computed for `{spec_path}` during "Dispatch reviewers in parallel" (via `realpath` or `cd $(dirname) && pwd`), NOT the raw `$ARGUMENTS`, which may be relative — together with a one-line instruction telling the downstream skill to operate on that file (skills take free-form input text, not a path argument):

   - `KIND == spec` → invoke `superpowers:writing-plans` with input: the absolute spec path plus "build the implementation plan from this spec." The plan it produces can itself be re-validated by re-running this skill on the plan.
   - `KIND == plan` → invoke `superpowers:subagent-driven-development` with input: the absolute plan path plus "execute this plan, and when implementation is complete and green, ALWAYS finish by pushing the branch and opening a pull request — never merge, and never leave the work only on a local branch. Opening a PR is a hard requirement for any validate-driven auto-execution."

   Auto-continue proceeds whether the spec was committed (tracked path) or merely saved to disk (gitignored path) in "Persist the spec file" — in both cases a stable, blessed file is on disk for the downstream skill to read. If the invocation fails **after** the banner — the Skill call errors, the target isn't found, or it returns without acting on the input — take the **manual-fallback** path from step 2 with `<reason>` = `the handoff failed after it was announced`, so the run doesn't end in an ambiguous state.

### Plan→implementation override

On this clean-bless auto-continue path, validate goes STRAIGHT into `superpowers:subagent-driven-development` for a blessed plan. It does NOT present the usual "Subagent-Driven vs Direct Implementation" choice. This is a deliberate, scoped override of that default workflow ask: a clean bless on a plan is the explicit signal to proceed with subagent-driven execution. The ask still applies anywhere outside this auto-continue path (e.g., a blessed-with-caveats plan, where the operator drives the next step manually).

**Always finish with a PR.** Because this path runs autonomously end-to-end with no operator checkpoint before integration, the subagent-driven execution MUST conclude by pushing the branch and opening a pull request (via `superpowers:finishing-a-development-branch` / `gh pr create`). It must NEVER merge to the default branch and NEVER stop with the work only on a local branch. The operator reviews and merges the PR; auto-execution never merges. This holds even if the implementation, reviews, and tests are all green — green means "ready for a PR," not "ready to merge."

### Done

The skill exits after the report. Operator can re-run validate at any time; subsequent runs are stateless and re-scan against the current `HEAD`.
