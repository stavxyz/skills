# stavxyz/skills

A small [Claude Code](https://claude.com/claude-code) plugin marketplace with two multi-reviewer skills:

| Skill | Command | What it does |
| --- | --- | --- |
| **validate** | `/validate <path-to-spec-or-plan.md>` | Runs two reviewers in parallel against your codebase — a **fact-check** pass (are the spec's claims about existing code true?) and a **SOLID / hygiene** pass (is the design direction sound?) — then addresses the findings in-spec, with gates for deferrals, Critical corrections, and net-negative design. |
| **polish-pr** | `/polish-pr <PR#>` | Rebases a PR, runs two independent code reviews in parallel, addresses **every** finding at every severity in-PR, updates docs, runs a test plan, and pushes. |

## Install

```text
/plugin marketplace add stavxyz/skills
/plugin install skills@stavxyz
```

The first command registers this repo as a marketplace named `stavxyz`; the second installs the `skills` plugin from it. After installing, `/validate` and `/polish-pr` are available as slash commands.

To update later:

```text
/plugin marketplace update stavxyz
```

## The skills

### `/validate`

```text
/validate docs/specs/2026-05-31-my-feature-design.md
```

Validates a **spec or plan** markdown file against the current `HEAD` of its git repo. It dispatches two `general-purpose` subagents in parallel using the bespoke reviewer prompts shipped alongside the skill:

- **fact-check** — verifies claims the spec makes about existing code (paths, symbols, behavior) against the real codebase.
- **solid-hygiene** — audits the design direction for SOLID/hygiene problems and flags anything **net-negative** (a change that would make the codebase worse).

Findings are deduped, triaged, and addressed in-place in the spec. Three conditions gate on your approval before edits proceed: deferral candidates, Critical fact-check findings, and net-negative design findings. On success the spec's frontmatter gets a `validated:` block recording the SHA, date, and finding counts.

### `/polish-pr`

```text
/polish-pr 142
```

The last-mile pass before a PR merges. It rebases onto the latest upstream, runs **two** code reviews in parallel (from `pr-review-toolkit` and `superpowers`), and fixes every finding in-PR rather than deferring. It also updates all docs, builds a test plan into the PR description, sweeps the branch for stray AI-attribution lines, and pushes.

**`/polish-pr` has prerequisites.** It hard-requires both review systems to be installed and refuses to run in degraded (single-reviewer) mode:

- [`pr-review-toolkit`](https://github.com/anthropics/claude-code) — provides the `pr-review-toolkit:code-reviewer` agent / `review-pr` skill.
- [`superpowers`](https://github.com/obra/superpowers) — provides `superpowers:requesting-code-review` (5.1.0+).

If either is missing, `/polish-pr` stops and tells you what to install.

## Compatibility

These skills target **Claude Code**. Two layers are worth distinguishing:

- The **packaging** (`.claude-plugin/marketplace.json` + `/plugin install`) is Claude Code's plugin format. GitHub Copilot CLI reads the same format, and Gemini CLI / Codex can consume skills via tool-name mapping.
- The **skill content** uses Claude-Code-specific tool names (`Task`, `AskUserQuestion`, `Edit`/`Write`, the `general-purpose` subagent type) and frontmatter (`disable-model-invocation`). Running these under another agent would require the tool-mapping shims that ecosystems like [superpowers](https://github.com/obra/superpowers) ship.

In short: out of the box, use these with Claude Code (or Copilot CLI). Other tools need adaptation.

## Manual install (without the plugin system)

If you'd rather not use the marketplace, symlink the skills into your user skills folder:

```bash
git clone https://github.com/stavxyz/skills.git
ln -s "$PWD/skills/skills/validate"  ~/.claude/skills/validate
ln -s "$PWD/skills/skills/polish-pr" ~/.claude/skills/polish-pr
```

`/validate` resolves its reviewer templates relative to the installed skill directory, so it works under either install method.

## Repository layout

```text
.
├── .claude-plugin/
│   ├── marketplace.json   # registers this repo as the "stavxyz" marketplace
│   └── plugin.json        # defines the "skills" plugin
└── skills/
    ├── validate/
    │   ├── SKILL.md
    │   ├── fact-check-reviewer.md
    │   ├── solid-hygiene-reviewer.md
    │   └── __fixtures__/
    └── polish-pr/
        └── SKILL.md
```
