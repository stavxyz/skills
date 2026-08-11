# stavxyz/skills

A small [Claude Code](https://claude.com/claude-code) plugin marketplace with three skills:

| Skill | Command | What it does |
| --- | --- | --- |
| **validate** | `/stavxyz:validate <path-to-spec-or-plan.md>` | Checks a spec's `file.py:NN` citations deterministically, then runs two reviewers in parallel against your codebase — a **fact-check** pass (are the spec's claims about existing code true?) and a **SOLID / hygiene** pass (is the design direction sound?) — and addresses the findings in-spec, with gates for deferrals, Critical corrections, and net-negative design. |
| **polish-pr** | `/stavxyz:polish-pr <PR#>` | Rebases a PR, runs two independent code reviews in parallel, addresses **every** finding at every severity in-PR, updates docs, runs a test plan, and pushes. |
| **reboot-ready** | `/stavxyz:reboot-ready` | Pre-reboot sweep: censuses running Claude Code sessions, dirty worktrees, and unpushed branches, parks dirty checkouts as zero-touch rescue refs, and writes a resume manifest to `~/.claude/reboot-manifest.md` + `.json`. |

## Install

```text
/plugin marketplace add stavxyz/skills
/plugin install stavxyz@skills
```

The first command registers this repo as a marketplace named `skills`; the second installs the `stavxyz` plugin from it. Plugin skills are namespaced by the plugin name, so after installing they're invoked as `/stavxyz:validate`, `/stavxyz:polish-pr`, and `/stavxyz:reboot-ready`.

To update later:

```text
/plugin marketplace update skills
/plugin update
```

Updates aren't automatic — run those when a new version ships. Because Claude
Code caches plugins under a version-stamped path, every change to shipped skill
content (`skills/`) ships with a version bump; see [RELEASING.md](RELEASING.md)
for the why and the contributor workflow.

## The skills

### `/stavxyz:validate`

```text
/stavxyz:validate docs/specs/2026-05-31-my-feature-design.md
```

Validates a **spec or plan** markdown file against the current `HEAD` of its git repo, from three sources:

- **citations** — a deterministic pass, run before the reviewers. Reads every `path/to/file.py:NN` citation in the document, resolves the path, and checks the line. Where the citation names what it expects to find —

  ```text
  `driver.py:73` (`state_mod.load`)
  ```

  — it asserts that symbol is unique in the file and sits on a cited line, and reports the line it is really on when it does not. Uniqueness is measured rather than approximated by a minimum anchor length: `return None` is eleven characters and identifies nothing. Only that one verdict produces a correction validate can apply as an edit; the rest are marked `[manual]` and surfaced to you instead. A citation it *proves* wrong blocks a clean bless; one it merely can't resolve — an ambiguous bare filename, say — is reported without gating, unless you pass `--strict`, which promotes every unresolvable citation to a blocker. To make that the default everywhere, set `CHECK_CITATIONS_STRICT=1` in `~/.claude/settings.json` under `env`; `--no-strict` opts a single run back out. Note what that implies: every unanchored citation then gates, so documents written before anchors existed will not clean-bless until they are anchored. Anchors are opt-in, so it can be turned on against existing documents without a mass rewrite; an unanchored citation is `unverifiable`, not a finding, and path resolution, ambiguity, and past-end-of-file are checked either way.
- **fact-check** — a `general-purpose` subagent verifying claims the spec makes about existing code (paths, symbols, behavior) against the real codebase.
- **solid-hygiene** — a `general-purpose` subagent auditing the design direction for SOLID/hygiene problems, flagging anything **net-negative** (a change that would make the codebase worse).

The two subagents are dispatched in parallel using the bespoke reviewer prompts shipped alongside the skill. All three sources emit the same finding format, so they are parsed, deduped, and applied by one code path — and where the citation check and a reviewer disagree about a line number, the measured one wins.

Findings are deduped, triaged, and addressed in-place in the spec. Three conditions gate on your approval before edits proceed: deferral candidates, Critical fact-check findings, and net-negative design findings. On success the spec's frontmatter gets a `validated:` block recording the SHA, date, and finding counts.

On a **clean bless** — blessed with zero caveats (e.g. no deferrals, accepted net-negatives, skipped Critical fact-checks, hallucinated quotes, unapplied **`Important`** `[manual]` citation corrections, parse failures, or reviewer contradictions; both reviewers ran; and the spec/plan kind wasn't a tie-break guess) — validate auto-continues to the next stage of the pipeline: a blessed **spec** flows straight into `superpowers:writing-plans`, and a blessed **plan** flows straight into `superpowers:subagent-driven-development`. It announces this with a banner and proceeds without a prompt. If the bless carries any caveat — or the next-stage skill isn't available to invoke (not installed, or model-invocation disabled) — validate stops and recommends the next step for you to run by hand. The skill's "Auto-continue on clean bless" section holds the authoritative caveat list.

### `/stavxyz:polish-pr`

```text
/stavxyz:polish-pr 142
```

The last-mile pass before a PR merges. It rebases onto the latest upstream, runs **two** code reviews in parallel (from `pr-review-toolkit` and `superpowers`), and fixes every finding in-PR rather than deferring. It also updates all docs, builds a test plan into the PR description, sweeps the branch for stray AI-attribution lines, and pushes.

**`/stavxyz:polish-pr` has prerequisites.** It hard-requires both review systems to be installed and refuses to run in degraded (single-reviewer) mode:

- [`pr-review-toolkit`](https://github.com/anthropics/claude-plugins-public/tree/main/plugins/pr-review-toolkit) — provides the `pr-review-toolkit:code-reviewer` agent / `review-pr` skill.
- [`superpowers`](https://github.com/obra/superpowers) — provides `superpowers:requesting-code-review` (5.1.0+).

Both are available from Anthropic's official plugin marketplace:

```text
/plugin marketplace add anthropics/claude-plugins-official
/plugin install pr-review-toolkit@claude-plugins-official
/plugin install superpowers@claude-plugins-official
```

If either is missing, `/stavxyz:polish-pr` stops and tells you what to install.

## Compatibility

These skills target **Claude Code**. Two layers are worth distinguishing:

- The **packaging** (`.claude-plugin/marketplace.json` + `/plugin install`) is Claude Code's plugin format. Some other agentic CLIs are converging on compatible plugin/skill formats, but support and exact semantics vary by tool — verify against your tool's own docs before assuming portability.
- The **skill content** uses Claude-Code-specific tool names (`Task`, `AskUserQuestion`, `Edit`/`Write`, the `general-purpose` subagent type) and frontmatter (`disable-model-invocation`). Running these under another agent would require the tool-mapping shims that ecosystems like [superpowers](https://github.com/obra/superpowers) ship.

In short: out of the box, use these with Claude Code. Other tools may need adaptation.

## Manual install (without the plugin system)

If you'd rather not use the marketplace, symlink the skills into your user skills folder:

```bash
git clone https://github.com/stavxyz/skills.git
# The clone creates ./skills (the repo), and the skills themselves live under
# its skills/ subdirectory — hence the intentional skills/skills/ below.
ln -s "$PWD/skills/skills/validate"  ~/.claude/skills/validate
ln -s "$PWD/skills/skills/polish-pr" ~/.claude/skills/polish-pr
```

Installed this way they are **user skills**, which are not namespaced — so you invoke them by bare name (`/validate`, `/polish-pr`) rather than the `/stavxyz:` prefix used for the plugin install. `validate` resolves its reviewer templates relative to the installed skill directory, so it works under either install method.

> **Recommended for development.** The symlinks point at your live working tree, so editing a skill and running `/reload-plugins` (or starting a new session) picks the change up instantly — no version bump, no `/plugin marketplace update`. Reserve the versioned plugin/marketplace flow (see [RELEASING.md](RELEASING.md)) for distributing to others.

## Repository layout

```text
.
├── .claude-plugin/
│   ├── marketplace.json   # registers this repo as the "skills" marketplace
│   └── plugin.json        # defines the "stavxyz" plugin
├── .githooks/
│   └── pre-push           # blocks pushes that change skills/ without a version bump
├── RELEASING.md           # versioning rule + contributor release checklist
├── skills/                # distributed to installers
│   ├── validate/
│   │   ├── SKILL.md
│   │   ├── check-citations.py
│   │   ├── fact-check-reviewer.md
│   │   └── solid-hygiene-reviewer.md
│   ├── polish-pr/
│   │   ├── SKILL.md
│   │   ├── resolve-pr-remotes.sh
│   │   └── wait-for-pr-checks.sh
│   └── reboot-ready/
│       ├── SKILL.md
│       └── census.sh
└── tests/                 # dev-only, not part of the installed plugin
    ├── validate/          # automated tests for check-citations.py
    ├── validate-fixtures/ # sample specs for exercising validate by hand
    ├── polish-pr/         # automated tests for resolve-pr-remotes.sh
    └── reboot-ready/      # automated tests for census.sh
```

Contributing: enable the release guard once per clone with
`git config core.hooksPath .githooks`. See [RELEASING.md](RELEASING.md).
