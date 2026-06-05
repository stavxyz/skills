---
name: polish-pr
description: Polish a pull request — rebase, run parallel reviews, address all findings, update docs, push
disable-model-invocation: true
---

Polish PR #$ARGUMENTS.

## Preconditions — verify before doing anything else

This skill REQUIRES both review systems to be installed and available. Before rebasing, before dispatching reviews, before any other work, **verify both**:

1. **pr-review-toolkit** — confirm at least one of these appears in your environment:
   - The `pr-review-toolkit:review-pr` skill in available user-invocable skills, OR
   - The `pr-review-toolkit:code-reviewer` agent in available subagent types.
2. **superpowers** — confirm at least one of these appears:
   - The `superpowers:requesting-code-review` skill in available user-invocable skills (superpowers 5.1.0+; the dispatched reviewer runs as a `general-purpose` subagent driven by the skill's prompt template), OR
   - The `superpowers:code-reviewer` agent in available subagent types (superpowers ≤ 5.0.7; deprecated form, still acceptable if present).

**If EITHER is missing, STOP IMMEDIATELY.** Do not proceed with rebasing, dispatching reviews, opening the PR in the browser, or any other polish-pr work. Report to the user:
- Exactly which dependency is missing.
- A pointer to install it (the plugin marketplace, the install command if you know it, or "ask the user where this plugin lives").
- That polish-pr will not run in degraded mode — a single-reviewer pass gives a false sense of coverage and regularly misses bugs the other reviewer catches.

The user's standing rule: polish-pr is non-optional before merge AND requires BOTH review systems running in parallel. The two reviewers surface meaningfully different concerns; running only one is worse than skipping polish-pr entirely because it produces unjustified confidence.

## Workflow

First make sure all local commits for this PR are updated and the branch is rebased and has latest upstream changes.

Run **two reviews in parallel** — one from each system — then address **ALL** findings at every severity level: critical, important, medium, low, nitpicks, test gaps, and suggestions.

**Reviewer A — pr-review-toolkit:**
- Prefer the `pr-review-toolkit:code-reviewer` subagent (Task tool, subagent_type=`pr-review-toolkit:code-reviewer`).
- Fall back to the `/pr-review-toolkit:review-pr` skill if only that's available.

**Reviewer B — superpowers:**
- On superpowers 5.1.0+: invoke the `superpowers:requesting-code-review` skill via the Skill tool. The skill's content directs you to dispatch a `general-purpose` subagent using the prompt template at `code-reviewer.md` inside that skill's directory. Fill in the template's placeholders with PR-specific context and dispatch the subagent in parallel with Reviewer A.
- On superpowers ≤ 5.0.7 (deprecated): use the `superpowers:code-reviewer` subagent directly via the Task tool.

The two reviews must be dispatched **in parallel** (single message, multiple Task tool uses) so they run concurrently.

## Default disposition: address every finding in this PR

Polish-pr is the last natural moment when a contributor has the relevant files in their head. Anything pushed to a follow-up issue typically becomes deferred forever — the cost of re-acquiring context exceeds the value of the polish, and the next person to touch the file rarely sees the issue. Bite the bullet now while context is warm.

The default for every review finding — at every severity, including suggestions and nitpicks — is "fix it in this PR." Do NOT propose deferrals as a normal mode of operation.

**Acceptable reasons to defer (require explicit user approval, not assumed):**
- Genuinely additive features needing separate design (new UI page, new RPC endpoint with non-obvious shape, new product surface).
- Multi-step schema migrations touching tables outside this PR's scope that need their own deploy ordering / data backfill plan.
- Cross-cutting refactors affecting modules unrelated to this PR's scope.

**Reasons that are NOT acceptable as deferrals — address in-PR:**
- "It's pre-existing tech debt." If the file is being touched, fix it.
- "It's stylistic / minor." Minor things are exactly what gets deferred forever.
- "It would touch many tests." The tests are also being touched in the PR.
- "It's defense-in-depth and might never matter." Still cheaper to add now than to rediscover later.
- "It's a small additive schema column." Add it.
- "Fixing it requires touching one more file than the original review finding." Touch the file.

## Gate: ask before deferring, not before fixing

If you have clarification questions about specific findings (interpretation, scope, what the reviewer meant), ask before proceeding. Use the same gate to flag any finding you believe falls into the acceptable-deferrals list above with concrete reasoning — do NOT unilaterally defer.

If a deferral IS approved by the user, both of the following are required:
1. Comprehensive TODO comments at the code site naming what's deferred and why.
2. A GitHub issue capturing the deferred work in enough detail that someone with no context can pick it up.

## Execution standards

Use software development best practices, be elegant, emphasize DRY and identify opportunities for breaking code down into reusable pieces. Don't get in a rush.

Ensure all repo documentation, README(s), PR title, PR description, and docstrings are fully updated. "Fact check" all documentation — ensure updates are thorough and complete and that all links work.

Use atomic commits and push to the PR when finished.

Any GitHub issues closed by this PR should be referred to in the PR description so that they automatically close when the PR gets merged. Once the PR is created/updated, monitor CI checks in the background to ensure they pass.

### How to monitor CI checks

Do NOT write an inline `awk` / `grep` watcher over `gh pr checks` — `gh pr checks` is **tab-delimited**, and any check name containing a space ("E2E (Playwright)", "Code Quality - Python", etc.) will be silently mis-parsed by `awk '{print $2}'` (which splits on whitespace, not tab). The mis-parsed status row gets read as "pass" when it's really "pending", and the watcher exits "green" while multi-word checks are still running — leading to a premature browser-open before CI has actually settled. This has bitten polish-pr runs more than once.

Use the bundled watcher script. From a Bash tool call inside this skill, run:

```bash
"$CLAUDE_PLUGIN_ROOT/skills/polish-pr/wait-for-pr-checks.sh" <PR_NUMBER>
```

If `$CLAUDE_PLUGIN_ROOT` is unset (some skill installations), resolve the skill's directory by reading the path of this SKILL.md file at invocation time and use the sibling `wait-for-pr-checks.sh`.

The script polls every 20s by default (override with `--interval N`), times out at 1800s (override with `--timeout N`), and exits:
- `0` — all checks settled, none failed (green)
- `1` — at least one check reported `fail` or `cancelled`
- `2` — timed out before all checks settled
- `3` — usage / `gh` invocation error

Run it with `run_in_background: true` so the harness notifies you on completion instead of blocking the conversation. Do not poll, do not chain sleeps — wait for the completion notification, then read the output file. When it exits 0, proceed to the browser-open gate; on non-zero, surface the failed-check list to the user before doing anything else.

## Mandatory attribution sweep — DO THIS, do not skip

The user's standing rule is **zero Claude attribution on any commit, ever.** No `Co-Authored-By: Claude` lines. No `🤖 Generated with Claude Code` footers. This applies to the polish-pr round's own commits AND every commit already on the branch (from earlier subagents, prior development, anything).

This is a separate enforcement step because the prose elsewhere in this skill is not enough — both polish-pr v1 rounds run on PR #141 missed 14 attributed commits because the rule lived in passive prose under "Execution standards." Treat this section as a hard gate, not a recommendation.

### Step 1 — Propagate the rule to every subagent you dispatch

Any subagent prompt that authorizes git commits (the implementer in `superpowers:subagent-driven-development`, ad-hoc Task subagents told to "fix and commit," etc.) MUST include this instruction verbatim:

> **No Claude attribution in commits.** Do not add `Co-Authored-By: Claude...` lines, `🤖 Generated with Claude Code` footers, or any other attribution to commit messages. The repo owner's standing rule is that commit history must look like normal human commits.

Subagents inherit Claude Code's default commit-template behavior, which adds `Co-Authored-By` lines on its own. The instruction above suppresses that default. **Adding this instruction to subagent prompts is non-optional; any commit-authorizing dispatch without it WILL produce attributed commits.**

### Step 2 — Sweep before the final push

Before the push that closes out polish-pr (the one that triggers the final CI run + browser-open), run this exact check:

```bash
git log --format="%H" $(git merge-base origin/main HEAD)..HEAD | while read sha; do
  body=$(git show -s --format=%B "$sha")
  if echo "$body" | grep -qE "Co-Authored-By: Claude|🤖 Generated with .*Claude|Generated with .*Claude Code"; then
    echo "ATTRIBUTED: $sha $(git show -s --format=%s $sha)"
  fi
done
```

If the output is empty, proceed to push.

If the output lists any SHAs, you MUST strip the attribution lines via `git filter-branch` and force-push. Do not push attributed commits "to be cleaned up later" — they will never be cleaned up later.

### Step 3 — Strip + force-push when attributions are found

```bash
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --msg-filter '
  sed -e "/^Co-Authored-By: Claude/d" \
      -e "/^🤖 Generated with/d" \
      -e "/^Generated with .* Claude/d"
' $(git merge-base origin/main HEAD)..HEAD
```

Re-run the Step 2 grep to confirm zero attributions. Then:

```bash
git push --force-with-lease origin <branch-name>
```

Force-push to the **feature branch** is acceptable and required here. Force-push to `main`/`master` is forbidden by CLAUDE.md and would never apply at this stage anyway.

### Step 4 — Browser-open gate

Do NOT call `gh pr view <N> --web` until Step 2 returns empty AND CI on the post-strip push is green. The browser-open signal tells the user "this is ready to merge"; opening it with attributed commits visible in the PR's commit list breaks the user's trust in the gate.

## Test plan — "kicking the tires"

Beyond CI, every PR needs a test plan that exercises the actual deployed change. CI only catches what its tests are written to catch; "kicking the tires" is the moment you exercise the *real* surface area in the *real* environment to catch what CI doesn't.

Build the plan into the PR description so it's a persistent, checkable artifact (not ephemeral conversation). The plan should cover both phases:

**While the PR is open** — items doable against a PR-preview, dev, or auto-deploy environment if the project has one. Claude should run these DIRECTLY via the relevant tool (curl, wrangler tail, gh, Playwright e2e, browser-via-`gh pr view`, etc.) when feasible. Run them BEFORE opening the PR in the user's browser, since browser-open signals "ready to merge."

**Post-merge** — items that exercise the production-deployed change after merge. Often manual (visual judgment, third-party system interaction) but Claude can sometimes automate (curl against prod, smoke scripts, screenshot diffs).

The exact items depend on the project AND the PR's surface area. Tailor accordingly. Examples:
- A schema migration → exercise the new columns/constraints with sample writes; verify rollback path on dev before promoting to prod.
- A worker / bundle bump → request the affected routes, compare rendered output against expected behavior.
- A UI change → drive the flow in a browser (Playwright if possible, manual screenshot diff if not).
- A bug fix → reproduce the original failure scenario; confirm the fix.
- Security hardening → exercise the bypass class with payloads (curl, browser DevTools).
- A CI / infrastructure change → smoke a fresh PR against the new config and verify the gate fires correctly.

**Prefer items Claude can run autonomously.** When a step genuinely requires human judgment (visual polish, third-party UX, cross-browser compatibility you can't automate), call it out as `[manual]` in the plan so the user knows what falls to them. Don't pad the plan with manual items just to have a longer list.

For each automatable item: do it, capture the evidence (curl output, screenshot, log line, test result), and update the PR description's Test plan section with the result inline. Mark items the user must do manually with `- [ ]` checkboxes; mark items you've already executed with `- [x]` plus a one-line evidence summary.

When CI is fully green (every required check has succeeded) AND every automatable test-plan item has been executed and documented AND the attribution sweep below returns empty, open the PR in the user's default browser via `gh pr view <number> --web` so they can review and merge it. Do this only after every required check has passed AND the test plan is populated AND the sweep is clean; do not open the browser while checks are still pending, any have failed, test-plan items remain undocumented, or attributed commits remain.

(Attribution rule lives in its own section — see "Mandatory attribution sweep" below. Do not skip that section.)

Provide a concise summary of work completed when finished.
