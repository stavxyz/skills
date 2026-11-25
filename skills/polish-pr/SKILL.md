---
name: polish-pr
description: "Polish a feature pull request: rebase, run parallel reviews, address all findings, update docs, push, and land it when the run ends blessed"
disable-model-invocation: false
---

Polish PR #$ARGUMENTS.

The arguments above are the PR number, optionally followed by `--repo <owner>/<repo>` (passed to `resolve-pr-remotes.sh`, and the `GH_REPO` for every `gh` call) and by `--no-land`. A PR that
this run blesses is landed by the `land-pr` skill with no further prompt:
merged, verified where it runs, and announced to the project's other sessions,
after which `land-pr` fixes leftovers in a follow-up PR and starts the next
piece of work (see "Verdict and what happens next"). That applies when the user
typed this polish request, or when `land-pr` started it. `--no-land` stops at
the bless instead and leaves the merge to the user. So do the user's own words
against merging ("polish it but don't merge", "just polish"), with or without
the flag.

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

### A promotion PR is not polished here — check this before anything else

A PR is a promotion PR when its head is a long-lived branch of the base repository: the repo's default branch, or a branch the repo's docs name as an integration or environment branch (`dev`, `staging`, or a release branch). A PR from a fork is never one, whatever its branch is called, and neither is a feature branch that happens to have another PR stacked on it. Read the
head with `GH_REPO=<owner>/<repo> gh pr view <PR_NUMBER> --json headRefName,baseRefName,isCrossRepository` and the default branch with `GH_REPO=<owner>/<repo> gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`.

If the head is in the base repository, is not the default branch, and the docs do not name it, but pull requests have been merged into it (`GH_REPO=<owner>/<repo> gh pr list --base <head branch> --state merged --limit 1` prints one), it may be an integration branch nobody wrote down: stop and ask the user which it is before anything rebases it.

If it is one, stop now, before the base-currency gate and before dispatching
reviewers. This skill's fix loop and its attribution sweep commit and push to
the PR's head, and nothing may be pushed straight onto a shared branch or
rewrite it. Report that it is a promotion PR, and do not invoke `land-pr`
yourself: landing a promotion is its own request. Print the command that does
it, `/stavxyz:land-pr <PR_NUMBER>`, whose step 2 says what a promotion needs.
Verdict: `NOT BLESSED: promotion PR, see land-pr`.

Everything below is for a feature PR.

### Base-currency gate — DO THIS FIRST, with these exact commands

The branch MUST be fully up to date with the branch the PR merges into
(the PR's BASE branch, usually main) before any reviewer is dispatched, or
behind only in a way that leaves the merge result unchanged (the second case
below).
Prose like "make sure the branch is rebased" is not enough — a controller
once "verified" currency by counting commits AHEAD of the base and checking
sync with the branch's own upstream, neither of which detects being BEHIND.
Learned the hard way (2026-08-01, on a private repo): the base had moved 3
days earlier (two PRs), polish-pr certified a green run on the stale
combination, and the staleness was only caught at merge time — the
reviewers never saw the code that would actually land.

Run this exact check (not a paraphrase of it):

```bash
OUT=$("$CLAUDE_PLUGIN_ROOT/skills/polish-pr/resolve-pr-remotes.sh" <PR_NUMBER>) || exit 1
eval "$OUT"

git fetch "$BASE_REMOTE"
BEHIND=$(git rev-list --count "HEAD..$BASE_REMOTE/$BASE_BRANCH")
echo "base=$BASE_REMOTE/$BASE_BRANCH head=$HEAD_REMOTE behind=$BEHIND"
```

`resolve-pr-remotes.sh` maps the PR to the local remotes hosting its base and
head repositories and sets `BASE_REMOTE`, `HEAD_REMOTE`, `BASE_BRANCH`,
`BASE_REPO`, `HEAD_REPO`, `CROSS_REPOSITORY`. (If `$CLAUDE_PLUGIN_ROOT` is
unset, resolve this SKILL.md's directory and use the sibling script — same as
`wait-for-pr-checks.sh`.) It **hard-stops instead of guessing**: exit 1 when no
remote hosts the repo, 2 when more than one does, 3 on a usage or `gh` error.
Do not paper over a non-zero exit by falling back to `origin` — that is the bug
this replaces. Add `--repo <owner>/<repo>` when the repo has several remotes and
`gh` might resolve the wrong one. Note that a same-numbered PR can exist in both
repos, so a plausible-looking result can still be the wrong repo; pass `--repo`
whenever you are not certain.

Both bundled scripts read the PR over GitHub's REST API when `gh`'s GraphQL
calls are refused, which is how Claude Code's cloud sessions answer every
`gh pr view --json` and `gh pr checks --json` (a 403 from the GitHub proxy,
whatever the token). The switch is announced once on stderr, and the
scripts behave the same (REST can list a check run gh leaves out, and is never
less strict), so run the scripts there rather than replacing them with
hand-rolled `git` and `gh api` polling. Pass `--repo <owner>/<repo>` to the
resolver and set `GH_REPO` for the watcher there, so the REST calls know the
repository. The resolver still needs a local remote whose URL is the
repository's github.com address: where there is none it exits 1 ("no remote
hosts the base repo"), and adding one (`git remote add`) is the remedy. The watcher's two
transports are compared on live PRs by
`tests/polish-pr/probe-rest-fallback-live.sh`, which refuses GraphQL with a
wrapper; neither script has yet been run inside a cloud session.

**Why a script and not inline shell:** exactly the reason given below for
`wait-for-pr-checks.sh`. `git remote -v` is human-formatted output, not a
stable contract — it applies `insteadOf` rewrites (so a remote configured as
`https://github.com/o/r` can print as `ssh://git@github.com/o/r`) and it
whitespace-splits, so a local path containing a space breaks positional
parsing. The script reads `git config --get-regexp` instead, compares host as
well as owner/repo so an enterprise remote never matches a github.com PR, and
folds case. `tests/polish-pr/test-resolve.sh` locks the URL dialects in.

**`BASE_REMOTE` and `HEAD_REMOTE` are different remotes on a fork PR**, and
each has one correct use: fetch and compare against `BASE_REMOTE`, but push the
branch to `HEAD_REMOTE`. The PR's head branch lives in the fork; pushing it to
the base repo exits 0, creates a stray branch there, and never updates the PR.

**Write the resolved values down.** Shell state does NOT survive between tool
calls, so `$BASE_REMOTE` is empty in any later block and
`git merge-base "$BASE_REMOTE/$BASE_BRANCH" HEAD` silently degrades to
`git merge-base "/main" HEAD` — which lists zero commits and reads as a pass.
Later commands write them as `<BASE_REMOTE>`, `<HEAD_REMOTE>` and
`<BASE_BRANCH>` placeholders; substitute the literal values you just resolved,
the same way you would `<PR_NUMBER>`.

The same applies to `GH_REPO`: it is shell state too. Prefix it on each `gh`
invocation individually (`GH_REPO=<owner>/<repo> gh pr view …`) or run
`gh repo set-default` once — do not set it in one block and expect a later one
to see it.

- `BEHIND` = 0 → proceed to dispatch reviewers.
- `BEHIND` > 0, and merging would change nothing about this branch → proceed,
  and say so in the summary. Check it with:

  ```bash
  T=$(git rev-parse 'HEAD^{tree}') && [ -n "$T" ] && [ "$(git merge-tree --write-tree <BASE_REMOTE>/<BASE_BRANCH> HEAD 2>/dev/null)" = "$T" ] && echo "merge changes nothing"
  ```

  That prints only when the merge result is exactly this branch's tree, so the
  reviewers are reading what will land: the base gained commits that add
  nothing this branch lacks (merge commits of work the branch already has, or
  a commit and its revert). A conflict, an error, or a git too old for
  `merge-tree --write-tree` (before 2.38) prints nothing, which is the case
  below.
- `BEHIND` > 0 otherwise → STOP. Rebase onto `<BASE_REMOTE>/<BASE_BRANCH>` (resolve conflicts;
  if a conflict resolution is non-mechanical, surface it to the user before
  continuing), re-run the project's test suite and linters on the rebased
  result, push the feature branch with a lease on the PR head as it was
  before the rebase (`git push --force-with-lease=<branch>:<that sha>
  <HEAD_REMOTE> HEAD:<branch>`; a bare `--force-with-lease` after a fetch
  would overwrite a commit someone pushed meanwhile), and only then
  dispatch reviewers — they must review the combination that will actually
  merge.

**Re-run the same check before the verdict** (the base can move
during the polish round itself). If the re-run lands in the STOP case, handle
it as above, re-run the suite, and wait for CI again. Never give a BLESSED
verdict, which is the ready-to-merge signal, on a branch in the STOP case.

`git rev-list --count HEAD..<BASE_REMOTE>/<BASE_BRANCH>` (commits BEHIND) is the
load-bearing direction. `<BASE_REMOTE>/<BASE_BRANCH>..HEAD` (commits ahead) and
`git status -sb` (sync with the feature branch's own upstream) are the two
look-alike checks that do NOT detect staleness — do not substitute them.


Before dispatching the reviewers, re-derive every number in the PR description from its source (a count, a rate, a duration, a test total): re-run the query or command that produced it, and correct or remove any figure you cannot reproduce. A reviewer reads the diff and takes the description's numbers on trust. Do it again before the verdict: the fix loop changes test totals and counts.

Run **two reviews in parallel**, one from each system (two reviewers per system when the change is large; see below), then address **ALL** findings at every severity level: critical, important, medium, low, nitpicks, test gaps, and suggestions.

**Reviewer A — pr-review-toolkit:**
- Prefer the `pr-review-toolkit:code-reviewer` subagent (Task tool, subagent_type=`pr-review-toolkit:code-reviewer`).
- Fall back to the `/pr-review-toolkit:review-pr` skill if only that's available.

**Reviewer B — superpowers:**
- On superpowers 5.1.0+: invoke the `superpowers:requesting-code-review` skill via the Skill tool. The skill's content directs you to dispatch a `general-purpose` subagent using the prompt template at `code-reviewer.md` inside that skill's directory. Fill in the template's placeholders with PR-specific context and dispatch the subagent in parallel with Reviewer A.
- On superpowers ≤ 5.0.7 (deprecated): use the `superpowers:code-reviewer` subagent directly via the Task tool.

All reviews must be dispatched **in parallel** (single message, multiple Task tool uses, in the background where the harness offers the choice) so they run concurrently and the controller is free while they do.

Give each reviewer the change once: the git range, or the files, not both, and never a patch file that repeats code it can read from the repository. A reviewer handed the same code twice over has gone silent on it. When the change is large (over about 2,000 changed lines, insertions plus deletions, by `git diff --shortstat <BASE_REMOTE>/<BASE_BRANCH>...HEAD`, or files of that length that must be read whole), give each system two reviewers split by question (for example, state and exit paths; reporting and tests), each with the whole range to read. Every reviewer counts toward its system's review, and all of them report before the fix loop ends.

A reviewer that has written nothing for 15 minutes is stuck, and nothing notifies you of that. So when you first dispatch, also start one background `sleep 900`. When it finishes, and whenever another reviewer reports, look at the modification time of each running reviewer's output file (the dispatch result names it), not at its content. If a reviewer is still running when the timer finishes, start another `sleep 900`, and keep one running until the last reviewer, replacements included, reports. Neither the look nor the timer is the polling and chained sleeps the CI section forbids; that rule is about the checks watcher. Stop a reviewer whose file is more than 15 minutes old (the `TaskStop` tool in Claude Code, or your harness's equivalent), and split its brief between two new reviewers of the same system that together cover everything the stopped one was given, so no part of the change loses that system's review.

### Append these two blocks to every reviewer dispatch

Polish-pr's controller does NOT own the reviewer prompt templates (they live inside `pr-review-toolkit` and `superpowers:requesting-code-review`). It DOES own the prompt envelope it sends to each reviewer. When dispatching either reviewer, append the block below (copy it exactly as written) to the prompt envelope:

<!-- Repeated-pattern sweep: the core invariant (don't stop at the first instance; one finding per location, at the same severity; no inflation, no collapsing) is intentionally duplicated in skills/polish-pr/SKILL.md, skills/validate/fact-check-reviewer.md, and skills/validate/solid-hygiene-reviewer.md. The examples and grep target ("the diff" here vs "the spec/plan {kind}" in validate) are deliberately tailored per reviewer; keep the invariant in sync across all three when editing any one. -->

> **Repeated-pattern sweep — REQUIRED.** When you identify a finding that names an anti-pattern (e.g., "imports from wrong path," "uses wrong API option," "mounts on root app instead of sub-router," "redeclared regex that already exists upstream"), do NOT stop at the first instance. **Grep the rest of the diff for the same anti-pattern and emit one finding per location, at the same severity.** Operators apply fixes surgically (one Edit per finding); if N locations exhibit the same bug and you report only one, the surgical fix covers only the named site and the other N-1 ship broken. Each location must be named explicitly so it gets its own Edit. If the anti-pattern appears once, that's one finding — no inflation. If it appears N times, that's N findings — no collapsing.

Why this exists: a polish-pr v2 run caught a mount-point anti-pattern at one task site but missed three other sites in the same diff with the identical bug. The surgical fix shipped, the siblings did not, and a follow-up validate caught the rest. The sweep instruction makes the reviewer responsible for enumerating every instance up front so the operator's first round of edits covers all of them.

Apply the sweep block to every reviewer of both systems, in whatever form each is dispatched: the `pr-review-toolkit:code-reviewer` Task prompt, the `general-purpose` subagent prompt you assemble from `superpowers:requesting-code-review`'s template, or (deprecated path) the `superpowers:code-reviewer` Task prompt. It composes with whatever finding format their internal templates already prescribe: it asks the reviewer to multiply findings, not to change the format.

Append this second block to every reviewer dispatch as well, copied exactly:

> **Probe without side effects (REQUIRED).** You may run tests and try mutations to check a claim, but nothing you run may reach a real service: a job queue, a database that is not a scratch one, a message bus, a webhook, a mail or payment API, or a deploy. Code under review often connects to whatever is listening on its default local address. Before running it, mutated or not, point its connections at a fake or an in-memory stand-in, or patch the client, and say in your report what you ran and what you stubbed. The project's own test suite counts as isolated only once you have checked where it connects. If you cannot isolate something, do not run it: reason from the source and say so.

A report that does not say what was run and what was stubbed is incomplete: ask that reviewer for it before acting on its findings.

Why this exists: a reviewer probing tests with in-memory mutations pushed four real jobs onto a job server that happened to be running on the developer's machine, because the code under test connected to its default address.

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

A review finding about a commit message (a wrong subject, a stale claim in a body) is fixed with `reword-commits.py`, the sibling of this SKILL.md. Write the edits to a JSON file, a list of objects with `old` and `new` and optionally `subject_prefix` and `every`; each entry must match exactly one commit unless it sets `"every": true`. Record the PR's head first, so the push command the helper prints leases against what the remote holds, then run the helper with `--dry-run`, read the diff, and run it again without `--dry-run`:

```bash
REMOTE_TIP=$(GH_REPO=<owner>/<repo> gh pr view <PR_NUMBER> --json headRefOid --jq .headRefOid)
python3 "$CLAUDE_PLUGIN_ROOT/skills/polish-pr/reword-commits.py" \
  --base "$(git merge-base <BASE_REMOTE>/<BASE_BRANCH> HEAD)" \
  --remote-tip "$REMOTE_TIP" \
  --replace <file.json> --dry-run
```

When a later message in the range cites one of the rewritten commits by sha, the helper lists it ("cites 1a2b3c4 (now 5d6e7f8)"): every commit from the first changed one onward gets a new sha, so before pushing, run the helper again with `--replace` entries for the listed mentions, and repeat until it lists none (a message that cites a commit fixed in the second pass needs a third).

The helper changes messages, not content: every commit keeps its tree, author, and author date, the committer becomes whoever runs it, and signatures are made again only when `commit.gpgsign` is set. Push with the command it prints, as in Step 3 of the attribution sweep below, which also says what a refused push means.

Any GitHub issues closed by this PR should be referred to in the PR description so that they automatically close when the PR gets merged. Once the PR is created/updated, monitor CI checks in the background to ensure they pass.

### How to monitor CI checks

Do NOT write an inline `awk` / `grep` watcher over the default `gh pr checks` output. That output is human-formatted text (not a stable contract), and a naive `awk` that prints the second whitespace-separated field splits any check name containing a space ("E2E (Playwright)", "Code Quality - Python", etc.) on whitespace, reading the status column wrong — a row that's really "pending" gets read as "pass", and the watcher exits "green" while multi-word checks are still running, triggering a premature browser-open before CI has settled. This has bitten polish-pr runs more than once. The bundled script avoids the problem entirely by reading `gh pr checks --json bucket` (a documented, stable enum) instead of parsing columns.

Use the bundled watcher script. From a Bash tool call inside this skill, run:

```bash
GH_REPO=<owner>/<repo> "$CLAUDE_PLUGIN_ROOT/skills/polish-pr/wait-for-pr-checks.sh" <PR_NUMBER>
```

If `$CLAUDE_PLUGIN_ROOT` is unset (some skill installations), resolve the skill's directory by reading the path of this SKILL.md file at invocation time and use the sibling `wait-for-pr-checks.sh`.

The script polls every 20s by default (override with `--interval N`), times out at 1800s (override with `--timeout N`), and exits:
- `0`: all checks settled, none failed, the settle window has passed since the script started, and every workflow run GitHub lists for the head commit is completed (green), **or** the PR has no checks at all and an empty result held for the settle window (nothing to wait for, so proceed)
- `1`: at least one check is in the `fail` or `cancel` bucket, or a workflow run for the head commit ended in failure or awaiting approval without producing any check row (a workflow file error, a fork PR's unapproved run)
- `2`: timed out before all checks settled, including checks that never registered at all, and checks that pass while a workflow run for the head commit never completes (a run waiting on an approval, for example; the message names the runs)
- `3`: usage error, `gh` missing, or a real `gh` invocation failure (auth, bad PR, network)

**Do not pipe it** (`... | tail -20`). A pipeline's exit status is its last command's, so the script's exit code is lost and a failure reads as 0; a network error was once reported as green that way. Run it bare, and read its output file afterwards. Its last stdout line is always `VERDICT: green`, `VERDICT: failed`, `VERDICT: timeout`, or `VERDICT: error`, so a caller that has lost the exit code can still tell.

**Why "nothing pending" is not believed immediately either.** After a push GitHub registers workflows one at a time, so one fast check can be listed and passing while the others are not in the list yet (observed: a single passing row with nine workflows still to appear, and a run held in its concurrency group for 80 seconds with no jobs). No expected number of checks fixes that, because path-filtered workflows make the number depend on what the PR touched. So the script calls green only after the settle window has passed since it started, and only when every workflow run for the head commit is completed. A `cancel` seen inside the settle window is re-polled, since a push cancels the superseded run; a `fail` is final at once. If the PR's head moves while the script is watching, it starts the settle window over for the new head. The cost is that every run takes at least the settle window.

**Why an empty result is not believed immediately.** `gh pr checks` reports "no
checks reported" both for a repo without CI and for a head pushed seconds ago
whose check runs GitHub has not registered yet, and a single reading cannot tell
them apart. Since this skill calls the script right after the closing push, the
second case is the likely one, and treating it as green opens the
ready-to-merge gate before a single check has started. Measured 2026-09-22 on a
repo with five checks: the empty reading lasted 62 seconds. An empty result must
therefore hold for `--settle N` seconds (default 90) before it counts as "no
CI"; pass `--settle 0` to remove the wait, which also removes the minimum wait before green and the grace period for a cancelled check described above. The window is
evaluated at poll boundaries, so the real wait rounds up to the next interval:
about 100s at the default 20s interval. A repo that genuinely has no CI pays
that wait on every run, this one included, since it has no CI of its own.
`tests/polish-pr/test-wait-for-checks.sh` locks the verdicts in.

Run it with `run_in_background: true` so the harness notifies you on completion instead of blocking the conversation. Do not poll, do not chain sleeps: wait for the completion notification, then read the output file. When it exits 0, proceed to the verdict; on non-zero, surface the failed-check list to the user before doing anything else. **When no step ran.** If a failed job has no steps at all, or the failed run lists no jobs, nothing was tested and there is no log to read (`gh run view <run-id> --log-failed` prints "log not found"). Elapsed time does not tell this apart from a setup step that failed at once, which has a log and is an ordinary failure. Look: `GH_REPO=<owner>/<repo> gh run list --commit <head sha> --json databaseId,name,conclusion` lists the head's runs with their ids, and `GH_REPO=<owner>/<repo> gh run view <run-id> --json jobs --jq '.jobs[] | [.databaseId, .name, .conclusion, (.steps | length)] | @tsv'` lists one run's jobs with their step counts. For a failed job with zero steps, the reason is in its check run's annotations: `GH_REPO=<owner>/<repo> gh api "repos/{owner}/{repo}/check-runs/<databaseId>/annotations" --jq '.[].message'`. A job the host refused to start (a billing or spending limit is the case this was written for) is not a failing test, and no change to the PR fixes it. Re-run once in case it was momentary: `GH_REPO=<owner>/<repo> gh run rerun <run-id> --failed`, then the watcher again. If the jobs start this time, judge that run like any other. If they are refused again, report the annotation's words and stop, because it is the owner's to fix. For a run with no jobs there is no annotation: `GH_REPO=<owner>/<repo> gh run view <run-id>` prints gh's guess at the reason (a workflow file error, for example). If this PR's diff touches that run's workflow file (`GH_REPO=<owner>/<repo> gh api "repos/{owner}/{repo}/actions/runs/<run-id>" --jq .path`) or a workflow it calls, treat it as a bug in the PR and fix it, which means another review round. Otherwise re-run it once the same way (if gh will not re-run a run that has no jobs, skip the re-run), and if the re-run was skipped or its run is jobless too, report gh's line, as a guess, and stop.

## Mandatory attribution sweep — DO THIS, do not skip

The user's standing rule is **zero Claude attribution on any commit, ever.** No `Co-Authored-By: Claude` lines. No `🤖 Generated with Claude Code` footers. This applies to the polish-pr round's own commits AND every commit already on the branch (from earlier subagents, prior development, anything).

This is a separate enforcement step because the prose elsewhere in this skill is not enough — both polish-pr v1 rounds run on PR #141 missed 14 attributed commits because the rule lived in passive prose under "Execution standards." Treat this section as a hard gate, not a recommendation.

### Step 1 — Propagate the rule to every subagent you dispatch

Any subagent prompt that authorizes git commits (the implementer in `superpowers:subagent-driven-development`, ad-hoc Task subagents told to "fix and commit," etc.) MUST include this instruction verbatim:

> **No Claude attribution in commits.** Do not add `Co-Authored-By: Claude...` lines, `🤖 Generated with Claude Code` footers, or any other attribution to commit messages. The repo owner's standing rule is that commit history must look like normal human commits.

Subagents inherit Claude Code's default commit-template behavior, which adds `Co-Authored-By` lines on its own. The instruction above suppresses that default. **Adding this instruction to subagent prompts is non-optional; any commit-authorizing dispatch without it WILL produce attributed commits.**

### Step 2 — Sweep before the final push

Before the push that closes out polish-pr (the one that triggers the final CI run and the verdict), run this exact check:

```bash
git log --format="%H" $(git merge-base <BASE_REMOTE>/<BASE_BRANCH> HEAD)..HEAD | while read sha; do
  body=$(git show -s --format=%B "$sha")
  if printf '%s\n' "$body" | grep -qiE \
      -e '^ *([-*+] +)?Co-Authored-By: Claude' \
      -e '^ *🤖 Generated with .*Claude' \
      -e '^ *Generated with .*Claude Code'; then
    echo "ATTRIBUTED: $sha $(git show -s --format=%s $sha)"
  fi
done
```

The patterns match an attribution only where it stands as a line of its own (leading spaces allowed, and a list marker before the co-author trailer), in any letter case, so git's lowercase `Co-authored-by:` is caught and a sentence that merely mentions the rule is not. Step 3 removes lines with these same three patterns; change them in both places or in neither. They use only syntax that `grep -E` on macOS and Linux and Python's `re` read the same way, which is why leading whitespace is written as spaces.

If the output is empty, proceed to push.

If the output lists any SHAs, you MUST strip the attribution lines with the helper in Step 3 and force-push. Do not push attributed commits "to be cleaned up later": they will never be cleaned up later.

### Step 3 — Strip + force-push when attributions are found

First record the head the PR has on GitHub, which is what the remote branch holds:

```bash
REMOTE_TIP=$(GH_REPO=<owner>/<repo> gh pr view <PR_NUMBER> --json headRefOid --jq .headRefOid)
```

Then run `reword-commits.py` (beside this SKILL.md; `$CLAUDE_PLUGIN_ROOT/skills/polish-pr/` under the plugin install) with one `--drop-lines` per pattern the Step 2 check looks for:

```bash
python3 "$CLAUDE_PLUGIN_ROOT/skills/polish-pr/reword-commits.py" \
  --base "$(git merge-base <BASE_REMOTE>/<BASE_BRANCH> HEAD)" \
  --remote-tip "$REMOTE_TIP" --ignore-case \
  --drop-lines '^ *([-*+] +)?Co-Authored-By: Claude' \
  --drop-lines '^ *🤖 Generated with .*Claude' \
  --drop-lines '^ *Generated with .*Claude Code'
```

Run it with `--dry-run` added first and read the diff: every removed line must be an attribution, and nothing else. Then run it without `--dry-run`.

It rewrites the messages through `git commit-tree`: every commit keeps its tree, author, and author date, the committer becomes whoever runs it, signatures are made again only when `commit.gpgsign` is set (it prints a note when a signature is dropped), the working tree and index are not touched, and the old tip is parked at the `refs/rescue/reword/...` ref it names, created in the same transaction that moves the branch. It refuses (exit 1, nothing changed) a detached HEAD, a merge commit in the range, or a pattern that would delete a subject line; a subject that carries an attribution is fixed with `--replace` instead. When it refuses a merge commit, rebase onto `<BASE_REMOTE>/<BASE_BRANCH>` first, which makes the branch linear, re-run the project's test suite, and run the helper again.

Re-run the Step 2 grep to confirm zero attributions. Then push with the command the helper printed:

```bash
git push --force-with-lease=<branch-name>:<REMOTE_TIP> <HEAD_REMOTE> HEAD:<branch-name>
```

The lease names what the remote was last seen to hold, the PR head recorded above, not the local tip before the rewrite: commits of this round that were never pushed would make the local tip a sha the remote has never had, and the push would be refused as stale. A bare `--force-with-lease` after a fetch would accept, and overwrite, a commit someone pushed to the PR in the meantime (land-pr names its lease for the same reason). If the push is refused, the head moved: stop and look at what was pushed. Never retry with a bare `--force`.

Force-push to the **feature branch** is acceptable and required here. Force-push to `main`/`master`, or to any long-lived head as defined at the top of this workflow, is forbidden: this skill stops before reaching this step on such a PR, and if attributed commits are found on a shared branch anyway, report them and do not rewrite it.

Push to `<HEAD_REMOTE>`, not `<BASE_REMOTE>`. On a fork PR they differ, and
pushing the head branch at the base repo succeeds silently: it lands a stray
branch on the upstream, leaves the PR's head untouched, fires no new CI, and
lets the re-run grep report clean — so the sweep "passes" with the attributed
commits still on the PR.

### Step 4 — Browser-open gate

Do NOT call `GH_REPO=<owner>/<repo> gh pr view <N> --web` until Step 2 returns empty AND CI on the post-strip push is green, and then only in the case where "Verdict and what happens next" says to open it. A blessed PR that is about to be landed is not opened in the browser. The browser-open signal tells the user "this is ready to merge"; opening it with attributed commits visible in the PR's commit list breaks the user's trust in the gate.

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

For each automatable item: do it, capture the evidence (curl output, screenshot, log line, test result), and record it in the PR description's Test plan section. Write every item as an unticked `- [ ]` box, including the ones you are about to run. Once an item has run, record it with `tick-test-plan.py` from the land-pr skill (`"$CLAUDE_PLUGIN_ROOT/skills/land-pr/tick-test-plan.py"`, or the `land-pr` directory beside this one under a symlink install; land-pr's step 5 gives the command, with its arguments in single quotes so the shell leaves the evidence alone). It ticks the box and adds the one-line evidence as a nested line beneath it, and it refuses a box that is already ticked, so do not tick it by hand first. Items the user must do manually stay unticked and are marked `[manual]`.

When CI is fully green (every required check has succeeded) AND every automatable test-plan item has been executed and documented AND the attribution sweep below returns empty AND "Verdict and what happens next" says this is a case that opens the browser (blessed, and not being landed), open the PR in the user's default browser via `GH_REPO=<owner>/<repo> gh pr view <number> --web` so they can review and merge it. Do this only after every required check has passed AND the test plan is populated AND the sweep is clean; do not open the browser while checks are still pending, any have failed, test-plan items remain undocumented, or attributed commits remain.

(Attribution rule lives in its own section — see "Mandatory attribution sweep" below. Do not skip that section.)

## Verdict and what happens next

End every run with exactly one verdict line, so that a caller (the user, or the
`land-pr` skill) has one thing to act on:

```text
polish-pr verdict: BLESSED <full 40-character head sha>
polish-pr verdict: NOT BLESSED: <each unmet condition, by number>
```

The verdict is BLESSED only when all six hold. Check each one; do not infer any
of them from the others.

1. Every reviewer dispatched, or its replacement, ran to completion and said
   what it ran and what it stubbed; both systems covered the whole change; and
   every finding is fixed in the PR. A
   deferral the user approved (with its TODO and issue) counts as handled. A
   deferral or a question still waiting on the user does not.
2. Every commit made after the reviewers ran is a fix for a named finding, a
   documentation update, or a rebase. Anything else added after the review is
   unreviewed, and needs the reviewers run again.
3. The base-currency check, re-run after the final push, reads `BEHIND` = 0,
   or `BEHIND` > 0 with "merge changes nothing" printed.
4. `wait-for-pr-checks.sh` exited 0 on the final push.
5. The attribution sweep (Step 2) is empty.
6. Every automatable open-PR item in the test plan was executed, passed, and is
   recorded in the PR description, and every number the description states was
   re-derived from its source after the last fix.

The sha in the verdict is the PR's head at that moment: `git rev-parse HEAD`,
which must equal `GH_REPO=<owner>/<repo> gh pr view <PR_NUMBER> --json headRefOid --jq .headRefOid`.
If they differ, the push did not land where the PR reads from: NOT BLESSED.

The bless is for that commit on that base. Any later commit ends it. A movement
of the base ends it too, with two exceptions: a base that moved without
changing the merge result (the "merge changes nothing" case above), and, in
`land-pr`, a conflict-free rebase that passes the carry-over conditions in
that skill's step 2.

Then, by case:

- **BLESSED**, and either the user typed this polish request in this
  conversation or `land-pr` started this run: do not open the browser; the
  verdict takes the place of that signal. Say so in one line ("Blessed at
  <sha>, continuing to land") and continue without asking: return to the
  `land-pr` skill at its step 3 if it started this run, otherwise invoke
  `land-pr` through the Skill tool with the PR number, and with
  `--repo <owner>/<repo>` if this run was given one. `land-pr` reads the repository's own rules before it merges and
  stops there if they require the user's word. If `land-pr` is not available to
  invoke, fall back to the next case and say why.
- **BLESSED, with `--no-land`**, or blessed in a run that something other than
  the user started (a peer session's message, another skill): a bless is not
  permission to merge there. Open the PR in the browser (the gate above),
  and end the summary with the command that merges and finishes it:
  `/stavxyz:land-pr <PR_NUMBER>` (`/land-pr <PR_NUMBER>` under a symlink
  install).
- **NOT BLESSED:** do not open the browser and do not merge. List what remains,
  and who it is waiting on.

Provide a concise summary of work completed when finished, with the verdict line
last.
