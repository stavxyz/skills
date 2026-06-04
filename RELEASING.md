# Releasing

This repo is both a Claude Code **plugin** (`stavxyz`) and the **marketplace**
(`skills`) that serves it. Users install with:

```text
/plugin marketplace add stavxyz/skills
/plugin install stavxyz@skills
```

## The one rule: bump the version on every skill content change

**Any change to `skills/` content requires a patch version bump.** Bump these
two in lockstep:

- `.claude-plugin/plugin.json` → `"version"`
- `.claude-plugin/marketplace.json` → `metadata.version`

Use a **patch** bump (`0.1.1 → 0.1.2`) for content changes. Reserve minor/major
for larger shifts (new skills, breaking changes to a skill's interface).

### Why this matters

Claude Code caches each installed plugin under a **version-stamped** path:

```text
~/.claude/plugins/cache/skills/stavxyz/<version>/
```

If `skills/` content changes but the version string does **not**, users who run
`/plugin marketplace update skills` + `/plugin update` can keep serving the
cached (stale) content — the cache isn't reliably invalidated when the version
is unchanged. This is a known Claude Code behavior, tracked in
[#46081](https://github.com/anthropics/claude-code/issues/46081),
[#14061](https://github.com/anthropics/claude-code/issues/14061), and
[#17361](https://github.com/anthropics/claude-code/issues/17361).

Bumping the patch version changes the cache path, which forces a clean fetch.

> Note: PRs #1–#3 all shipped under `0.1.0`. `0.1.1` is the first bump; anyone
> who installed earlier likely has stale content until they update against a
> bumped version.

## Release checklist

1. Land the content change (e.g. an edit to a `skills/**/SKILL.md`).
2. Bump `plugin.json` **and** `marketplace.json` to the next patch.
3. Commit, push, open a PR (never push to `main` directly).
4. After merge, tell users to update:
   ```text
   /plugin marketplace update skills
   /plugin update
   ```
   Optionally `/reload-plugins` to pick it up live in the current session (no
   restart needed). Manual/symlink installers (see the README) just `git pull`.

## The pre-push guard

`.githooks/pre-push` enforces the rule locally. When `skills/` content changed
(relative to `origin/main`, falling back to local `main`) it blocks the push
unless **both** of these hold:

1. the plugin version was bumped (differs from the base commit's), and
2. `plugin.json` `version` and `marketplace.json` `metadata.version` agree.

Enable it once per clone:

```bash
git config core.hooksPath .githooks
```

Bypass intentionally (e.g. a docs-only change you've decided not to version)
with `git push --no-verify`.

**Known limits.** The guard is a best-effort *local* backstop, not server-side
enforcement (this repo intentionally has no CI):

- It only runs after you set `core.hooksPath` above, and `--no-verify` skips it.
  Edits made through the GitHub web UI never see it.
- It compares the checked-out `HEAD`, not the refs being pushed, so it assumes
  you push the branch you have checked out.
- On a fresh clone with no `origin/main` or `main` ref, it no-ops (won't block).

The real backstop remains PR review — keep an eye on the version bump there.
