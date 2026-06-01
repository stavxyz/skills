---
type: spec
---

# Net-negative fixture — synthetic test for /validate

**Status:** Synthetic test fixture for /validate prompt regression.
**Date:** 2026-05-08

## Goal

This fixture proposes a design choice that actively makes the codebase worse. The SOLID/hygiene reviewer should flag it as `net-negative`, triggering /validate's gate.

## Architecture

The existing function `parseChange(detail: unknown)` in `admin/shared/sentinel-render/parse.ts` (planned in the Sentinel coherent-rendering spec) takes one argument and returns a discriminated union. To support an upcoming feature, we will extend it as follows:

1. Add a third boolean parameter `legacyMode` to `parseChange`.
2. Add a fourth boolean parameter `discordEmbed`.
3. Add a fifth boolean parameter `inferCosmetic`.

These three booleans will be passed by every caller, with most callers passing `false` for all three. The function body will branch on each combination of the three flags (8 branches total) to produce different output shapes depending on which combination is set.

This is the right design because:
- It avoids creating new functions for each variant.
- All variant logic stays in one file, easy to find.
- Callers can pick the behavior they need by setting flags.

## Components

- `admin/shared/sentinel-render/parse.ts` — entry point. `parseChange(detail, legacyMode, discordEmbed, inferCosmetic)` after this change.

## Expected SOLID feedback

This fixture is intentionally net-negative. The SOLID reviewer should flag at least one finding with `gate-status: net-negative` because:

- Single Responsibility violation: one function handling 8 distinct behaviors via boolean flags.
- Open/Closed violation: every new feature requires another boolean parameter.
- Coupling proliferation: every caller becomes coupled to the function's internal flag-meaning.
- The pattern is a known anti-pattern ("flag arguments"); future work will have to undo it rather than build on it.

Note: `parseChange` doesn't exist at the referenced path yet (the Sentinel coherent-rendering spec proposes it). The fact-check reviewer is expected to flag this as drift. That's a side effect of the fixture being synthetic; the primary signal here is the SOLID lens catching the boolean-flag-explosion as `net-negative`.
